//////////////////////////////////////////////////////////////////
// 文件名：AgentContextMemory.swift
// 文件说明：Agent 上下文与记忆统一管理层 (Swift 6 Ready)
//
// 核心解构架构拓扑 (Domain-Driven Architecture):
// 1. TokenEstimationEngine — 高精度 Token 预算计量，驱动压缩与记忆蒸馏的触发水位。
// 2. AgentContextOrchestrator — 上下文装配流水线、滑动智能压缩（头尾保真，折叠早期巨型观察）。
// 3. AgentLongTermMemory — 长任务系统侧长期记忆 (Scratchpad) 蒸馏与注入中枢；
//    把即将被 compactContext 淘汰的早期执行记录蒸馏为结构化摘要，跨轮持久，避免后期失忆。
// 与 AGENT_BLACKBOARD_PLAN（模型自维护计划）分工：本文件是系统基于真实 tool I/O 蒸馏的"事实记忆"。
//////////////////////////////////////////////////////////////////

import Foundation
import AppKit

/// 高精度 Token 计量引擎 (全局统一标准：支持 CJK 字符、ASCII 单词与多模态图片预估)
enum TokenEstimationEngine {
    
    /// 估算全量上下文与消息载荷的 Token 总量
    static func estimateTokens(
        messages: [ContextMessage],
        systemInstruction: String = "",
        images: [NSImage] = [],
        activeSkills: [AgentSkill] = [],
        protocolType: String = "openai"
    ) -> Int {
        var total = 0
        if !systemInstruction.isEmpty {
            total += estimateTextTokens(systemInstruction) + 12
        }
        for msg in messages {
            total += 4
            if let text = msg.content, !text.isEmpty {
                total += estimateTextTokens(text)
            }
            if let toolCalls = msg.toolCalls {
                for call in toolCalls {
                    total += call.name.count / 3 + 12
                    total += estimateTextTokens(call.arguments)
                }
            }
        }
        for _ in images {
            total += protocolType.lowercased() == "gemini" ? 258 : 765
        }
        for skill in activeSkills {
            total += skill.name.count / 3 + skill.description.count / 3 + 24
            for param in skill.parameters {
                total += param.name.count / 3 + param.description.count / 3 + 16
            }
        }
        return total
    }
    
    /// 测算单段文本的高精度 Token 消耗 (CJK: 1.25x, ASCII 单词: 1/3.6, 标点: 0.6)
    static func estimateTextTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var cjkCount = 0
        var asciiPunctCount = 0
        var otherAsciiCount = 0
        
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (v >= 0x4E00 && v <= 0x9FFF) || (v >= 0x3040 && v <= 0x30FF) || (v >= 0xAC00 && v <= 0xD7AF) {
                cjkCount += 1
            } else if scalar.properties.isASCIIHexDigit || (v >= 0x20 && v <= 0x7E) {
                if "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".contains(Character(scalar)) {
                    asciiPunctCount += 1
                } else {
                    otherAsciiCount += 1
                }
            } else {
                cjkCount += 1
            }
        }
        let cjkTokens = Double(cjkCount) * 1.25
        let wordTokens = Double(otherAsciiCount) / 3.6
        let punctTokens = Double(asciiPunctCount) * 0.6
        return max(1, Int(ceil(cjkTokens + wordTokens + punctTokens)))
    }
}

// MARK: - ==================== 2. AgentContextOrchestrator (上下文编排与压缩) ====================

enum AgentContextOrchestrator {
    
    /// 上下文装配流水线：通过安全传值与返回值消除跨 async 的 inout 隔离冲突
    static func buildEnrichedContext(
        request: AgentExecutionRequest,
        currentAgent: AgentProfile,
        activeSkills: [AgentSkill],
        maxTokens: Int,
        enrichers: [ChatContextEnricher],
        sharedContext: [String: String]
    ) async -> (messages: [ContextMessage], totalTokens: Int) {
        let sanitizedQuery = ChatOrchestrator.sanitizeUserMessage(request.prompt)
        let payload = ContextEnrichmentPayload(
            query: sanitizedQuery,
            currentAgent: currentAgent,
            activeSkills: activeSkills,
            personaID: request.personaID,
            sliceIndex: request.sliceIndex,
            maxTokens: maxTokens,
            messages: request.historyMessages,
            sharedContext: sharedContext
        )
        
        var contextMsgs: [ContextMessage] = []
        var totalTokens = TokenEstimationEngine.estimateTextTokens(sanitizedQuery)
        
        for enricher in enrichers.sorted(by: { $0.priority < $1.priority }) {
            await enricher.enrich(payload: payload, messages: &contextMsgs, totalTokens: &totalTokens)
        }
        
        if let pID = request.personaID {
            let dynamicContext = PersonaManager.shared.compileDynamicRuntimeContext(for: pID, query: sanitizedQuery)
            if !dynamicContext.isEmpty {
                contextMsgs.append(.system(dynamicContext))
            }
        }
        
        // 若本轮请求携带有物理文件，直接将文件元数据清单合并进用户 Prompt
        var finalUserPrompt = sanitizedQuery
        if !request.fileURLs.isEmpty {
            let fileDescriptor = FileUtil.formatAttachmentDescriptor(for: request.fileURLs)
            finalUserPrompt += (finalUserPrompt.isEmpty ? "" : "\n\n") + fileDescriptor
            totalTokens += TokenEstimationEngine.estimateTextTokens(fileDescriptor)
        }
        
        contextMsgs.append(.user(finalUserPrompt))
        
        let accurateTotal = TokenEstimationEngine.estimateTokens(
            messages: contextMsgs,
            systemInstruction: currentAgent.systemPrompt,
            images: request.images,
            activeSkills: activeSkills,
            protocolType: currentAgent.baseModel
        )
        return (contextMsgs, accurateTotal)
    }
    
    /// 长上下文滑动智能压缩（头尾保真，折叠早期巨型观察输出）
    static func compactContext(
        messages: [ContextMessage],
        keepRecentTurns: Int,
        maxObservationLength: Int
    ) -> [ContextMessage] {
        let protectedMessageCount = max(2, keepRecentTurns * 2)
        guard messages.count > protectedMessageCount else { return messages }
        
        var compacted: [ContextMessage] = []
        let cutoffIndex = messages.count - protectedMessageCount
        
        for (index, msg) in messages.enumerated() {
            var newMsg = msg
            if index < cutoffIndex {
                if msg.role == .tool, let content = msg.content, content.count > maxObservationLength {
                    let headLen = Int(Double(maxObservationLength) * 0.6)
                    let tailLen = maxObservationLength - headLen
                    let head = content.prefix(headLen)
                    let tail = content.suffix(tailLen)
                    newMsg.content = "\(head)\n\n...[早期数据已折叠，原始共 \(content.count) 字符]...\n\n\(tail)"
                }
            }
            compacted.append(newMsg)
        }
        return compacted
    }
    
    /// 构建轻量可用技能名录（独立上下文注入，保护 System Prompt 缓存）
    static func buildLightweightCatalog(for skills: [AgentSkill]) -> String {
        guard !skills.isEmpty else { return "" }
        var catalog = "<available_skills_directory>\n"
        for s in skills {
            catalog += "• \(s.name): \(s.description)\n"
        }
        catalog += """
        使用指引：
        1. 思考发现：在思考阶段自主识别所需技能。
        2. 专有业务调用：若需操作上述名录中的业务技能，必须先调用 read_skill_manual 获取规范，再调用 execute_skill(skill_name: "...", input: "...") 物理执行。绝不可使用 system_terminal 盲猜拼凑业务命令。
        3. 基础系统杂务：遇到单纯的文件解压、文本合并、Python 临时运算等无预置技能的通用需求时，方可使用 system_terminal 执行原生 bash 脚本。
        </available_skills_directory>
        """
        return catalog
    }
    
    /// 构造纯净正向的自主推演协议
    static func buildAutonomousProtocol() -> String {
        return """
        
        <autonomous_protocol>
        为确保任务推演的确定性与过程透明度，请严格遵循以下工作流：
        1. 意图表达与过程透明 (Process Transparency)：
           - 每次下发工具调用前，在正文中简述前序步骤已确认的客观事实，并用一两句话说明当前执行意图，保持执行流清晰连贯。
        2. 渐进式手册内省 (Progressive Reading)：
           - 遇到未掌握确切参数格式的工具时，调用 `read_skill_manual` 查阅手册。若返回结果包含子文档索引 (doc_path)，继续查阅目标子文档，直至获取到完整的参数契约。
        3. 事实对齐的参数构建 (Truth-Grounded Parameters)：
           - 仅使用已验证的手册语法下发参数。
           - 若命令规范要求通过外部文件传递数据（如 `@data.json`），直接将完整的 JSON 数据作为字符串写入执行参数，底层运行时会自动完成文件转存与路径桥接。
        4. 通用与专用通道物理隔离 (Channel Isolation)：
           - 业务专属工具必须通过 `execute_skill` 代理下发。
           - `system_terminal` 仅作为宿主操作系统层面的通用杂务工具（如文件操作、解包编译等），严禁越权将其用于调用封装好的业务模块 CLI。
        5. 闭环物理核验与交付 (Verification & Delivery)：
           - 写入或配置动作完成后，紧随一步读回检查，提取系统真实物理回包。
           - 结单时将未经加工的真实读回原文或原始 JSON 填入 `finish_task` 的 `verification_evidence` 作为公证凭据。
        </autonomous_protocol>
        """
    }
}

// MARK: - ==================== 3. AgentLongTermMemory (系统侧物理真值长效记忆引擎) ====================

enum AgentLongTermMemory {

    // MARK: - 常量配置
    static let scratchpadKey = "AGENT_SCRATCHPAD"
    /// Scratchpad 自身长度硬上限（字符），超出则截断而非重新调用模型
    static let maxScratchpadChars = 3000
    /// Token 预算触发的软水位：loopMessages 估算超过模型窗口该比例即强制蒸馏
    static let budgetTriggerRatio: Double = 0.6
    static let structuredSlotsJsonKey = "AGENT_STRUCTURED_SLOTS_JSON"

    // MARK: - 内部数据结构
    
    /// 物理执行因果对账审计载荷
    private struct ExecutionTruthAudit: Sendable {
        var originalUserQuery: String = ""   // 用户初始核心业务意图 (闭环对账唯一判据)
        var verifiedCommands: [String] = []  // 控制台物理执行成功且有实质回显的白名单命令
        var failedCommands: [String] = []    // 明确报错、退出码非0或返回通用帮助的无效指令
        var auditTraceText: String = ""      // 配对后的因果推演对账流水文本
    }

    // MARK: - 主入口：周期触发蒸馏

    /// 由 runPipeline 主循环每轮调用。判断是否命中触发条件，命中则调用蒸馏模型重写累计记忆。
    /// - Parameters:
    ///   - loopMessages: 当前轮完整上下文（包含未折叠的真实业务回显）
    ///   - round: 当前迭代轮次（从 1 开始，进入第 N 轮头部）
    ///   - agent: 当前智能体配置
    ///   - summarizerModel: 用于蒸馏的模型
    ///   - modelMaxTokens: 模型上下文窗口硬顶
    ///   - sharedContext: 共享上下文的当前快照
    /// - Returns: 若本轮回写沉淀出新的摘要则返回该字符串，否则返回 nil。
    @MainActor
    static func maybeCondense(
        loopMessages: [ContextMessage],
        round: Int,
        agent: AgentProfile,
        summarizerModel: String,
        modelMaxTokens: Int,
        sharedContext: [String: String]
    ) async -> String? {
        guard agent.enableCompaction else { return nil }

        let threshold = max(2, agent.summarizeEveryNRounds)
        let completedTurns = max(0, round - 1)
        let shouldByRound = (completedTurns > 0 && completedTurns % threshold == 0)

        let modelMax = max(1, modelMaxTokens)
        let estTokens = TokenEstimationEngine.estimateTokens(
            messages: loopMessages,
            systemInstruction: agent.systemPrompt,
            protocolType: agent.baseModel
        )
        let shouldByBudget = Double(estTokens) > Double(modelMax) * Self.budgetTriggerRatio

        let existing = sharedContext[Self.scratchpadKey] ?? ""
        let shouldCatchUp = (completedTurns >= threshold && existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let hasToolExecution = loopMessages.contains { $0.role == .tool }
        let hasStructuredTag = loopMessages.contains { ($0.content ?? "").contains("<card") || ($0.content ?? "").contains("<state") }

        guard (shouldByRound || shouldByBudget || shouldCatchUp), (hasToolExecution || hasStructuredTag) else { return nil }
        
        // 1. 优先提取通用结构化标签块（零 LLM 调用消耗）
        let tagRegistry = extractGenericTags(from: loopMessages)

        // 2. 扫描控制台真实物理执行指令
        let audit = extractExecutionTruthAudit(from: loopMessages)

        // 3. 纯标签状态场景（如文学沙盒或通用状态机）：直接输出格式化白板，免去额外 LLM 开销
        if !hasToolExecution && !tagRegistry.isEmpty {
            LogManager.shared.info("🧠 通用结构化标签已归集入长效记忆", detail: "已提取并持久化状态槽位")
            return tagRegistry.formattedMarkdown()
        }

        // 4. 长任务运维/代码 Agent：执行常规指令蒸馏并融合结构化状态槽
        let condensed = await summarize(
            existing: existing,
            audit: audit,
            model: summarizerModel
        )
        
        var combined = condensed
        if !tagRegistry.isEmpty {
            combined = tagRegistry.formattedMarkdown() + "\n\n" + condensed
        }

        if !combined.isEmpty {
            let final = combined.count > Self.maxScratchpadChars
                ? String(combined.prefix(Self.maxScratchpadChars))
                : combined
            LogManager.shared.info(
                "🧠 长期记忆已蒸馏并沉淀 (已完成 \(completedTurns) 轮)",
                detail: "摘要长度 \(final.count) 字符 · 白名单命令 \(audit.verifiedCommands.count) 项"
            )
            return final
        }
        return nil
    }

    // MARK: - 内部引擎：物理真值硬核扫描器

    /// 从上下文序列中提纯工具调用配对关系、净化白名单指令并锁定初始意图
    private static func extractExecutionTruthAudit(from messages: [ContextMessage]) -> ExecutionTruthAudit {
        var audit = ExecutionTruthAudit()
        var traceLines: [String] = []
        
        var pendingCalls: [String: (name: String, rawInput: String)] = [:]
        
        for msg in messages {
            switch msg.role {
            case .user:
                if let text = msg.content, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // 精确捕获用户的初始核心需求，作为目标闭环对账唯一信源
                    if audit.originalUserQuery.isEmpty {
                        audit.originalUserQuery = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    traceLines.append("【用户意图】: \(text.prefix(300))")
                }
                
            case .assistant:
                if let text = msg.content, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let clean = text.filterStopTokens().filterTHINK().trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty {
                        traceLines.append("【阶段推演】: \(clean.prefix(300))")
                    }
                }
                if let calls = msg.toolCalls {
                    for call in calls {
                        var normalizedInput = call.arguments
                        if let data = call.arguments.data(using: .utf8),
                           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            // 针对通用执行代理与脚手架工具进行智能解包与参数脱敏
                            if let inputCmd = (dict["input"] as? String) ?? (dict["command"] as? String) {
                                normalizedInput = inputCmd
                            } else if call.name == "read_skill_manual" {
                                let target = dict["target_skill_name"] as? String ?? ""
                                let doc = (dict["doc_path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                                if let subDoc = doc, !subDoc.isEmpty {
                                    normalizedInput = "\(target): \(subDoc)"
                                } else {
                                    normalizedInput = target
                                }
                            }
                        }
                        pendingCalls[call.id] = (name: call.name, rawInput: normalizedInput)
                    }
                }
                
            case .tool:
                let callId = msg.toolCallId ?? ""
                let toolName = msg.name ?? ""
                let toolOutput = msg.content ?? ""
                
                let callMeta = pendingCalls[callId]
                let executedCommand = callMeta?.rawInput ?? "参数未知"
                let actualToolName = callMeta?.name ?? toolName
                
                let isFailed = PhysicalTruthVerifier.isExecutionFailed(toolName: actualToolName, output: toolOutput)
                
                if isFailed {
                    let failSummary = "\(actualToolName) [\(executedCommand)]"
                    if !audit.failedCommands.contains(failSummary) {
                        audit.failedCommands.append(failSummary)
                    }
                    traceLines.append("【动作下发 · 执行失败】: \(actualToolName) -> \(executedCommand)\n【报错反馈】: \(toolOutput.cutContent(maxChars: 350))")
                } else {
                    // 白名单收录格式统一净化，杜绝长句 _action_intent 污染记忆空间
                    if actualToolName != "finish_task" && !executedCommand.isEmpty {
                        let successSummary: String
                        if actualToolName == "read_skill_manual" {
                            successSummary = "read_skill_manual(\(executedCommand))"
                        } else if actualToolName == "execute_skill" || actualToolName.contains("cli") {
                            successSummary = executedCommand
                        } else {
                            successSummary = "\(actualToolName)(\(executedCommand))"
                        }
                        
                        if !audit.verifiedCommands.contains(successSummary) {
                            audit.verifiedCommands.append(successSummary)
                        }
                    }
                    traceLines.append("【动作下发 · 执行成功】: \(actualToolName) -> \(executedCommand)\n【真实回显】: \(toolOutput.cutContent(maxChars: 350))")
                }
                
            default:
                break
            }
        }
        
        audit.auditTraceText = traceLines.joined(separator: "\n\n")
        return audit
    }

    // MARK: - 蒸馏器：全正向强契约结构化摘要生成

    @MainActor
    private static func summarize(
        existing: String,
        audit: ExecutionTruthAudit,
        model: String
    ) async -> String {
        let verifiedCommandsBlock = audit.verifiedCommands.isEmpty
            ? "（暂无控制台物理执行成功的命令）"
            : audit.verifiedCommands.map { "- `\($0)`" }.joined(separator: "\n")
            
        let failedCommandsBlock = audit.failedCommands.isEmpty
            ? "（暂无报错记录）"
            : audit.failedCommands.map { "- `\($0)`" }.joined(separator: "\n")

        let instruction = """
        你是一名企业级长任务长期记忆（Scratchpad）架构师。
        你的职责是从推演流水中提炼客观事实资产与决策路径，帮助智能体维持清晰、准确且收敛的上下文指针。

        【执行规则（强制有效性与收敛门禁）】：
        1. 真实命令准入铁律：
           - 【已验证有效命令】分区，必须且只能从下方提供的【物理执行成功的真实命令白名单】中收录原型。
           - 任何尚未在白名单中出现的设想指令、参数猜测或预期命令，一律丢弃，绝不可写入记忆。
        2. 待办目标与命令语法解耦：
           - 【宏观业务待办与探索方向】分区，仅允许使用自然语言陈述宏观业务意图与待探查实体对象（例如：“检索应用 78 包含的模型与表单”）。
           - 待办事项中采用纯自然语言意图描述，避免编写具体命令行字符串（如避免写具体 CLI 语法），具体命令由后续执行轮次查阅手册后动态生成。
        3. 目标闭环与收敛导向（Goal Completion Awareness）：
           - 对照【用户原始核心目标】：若用户需求为只读查询（如查询、查看、列出、核验），且关键数据已在执行回显中完整呈现，【当前指针】与【宏观业务待办】必须明确导向整理成果并调用 `finish_task` 交付结单，避免自行衍生扩充写入、提交等超出用户提问范围的后续步骤。
        4. 语言规范与客观陈述：
           - 全文采用客观事实陈述句记录结论。
           - 避免使用“严禁”、“禁止”、“不得”等负面词汇；对于执行失败的命令，客观记录于【已证伪与排除路径】中，说明报错现象与替代方向。

        【输出格式必须严格覆盖以下段落（无内容写"无"）】：
        ## 已确认事实与有效资产
        ## 关键物理实体（记录真实 ID、表名等客观标识）
        ## 已做决策与原因
        ## 已验证有效命令（仅从白名单中收录）
        ## 已证伪与排除路径（记录报错/未命中指令及根因）
        ## 宏观业务待办与探索方向（仅限自然语言意图描述，不写具体命令行）
        ## 当前指针（下一步客观推演方向）
        """

        let prompt = """
        【用户原始核心目标】:
        \(audit.originalUserQuery.isEmpty ? "（未捕获到明确意图）" : audit.originalUserQuery)

        【现有记忆摘要】:
        \(existing.isEmpty ? "(空)" : existing)

        【物理执行成功的真实命令白名单 (唯一合法命令来源)】:
        \(verifiedCommandsBlock)

        【历史已报错或未命中的指令清单】:
        \(failedCommandsBlock)

        【实际执行因果流水】:
        \(audit.auditTraceText.isEmpty ? "(本轮无额外流水，请继承现有摘要)" : audit.auditTraceText)
        """

        do {
            let stream = LLMService.shared.ask(
                messages: [.user(prompt)],
                model: model,
                images: [],
                fileURLs: [],
                instruction: instruction,
                activeSkills: []
            )
            var out = ""
            for try await step in stream {
                if case .textDelta(let t) = step { out += t }
            }
            let cleaned = out
                .replacingOccurrences(of: "```markdown", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned
        } catch {
            LogManager.shared.warning("⚠️ 长期记忆蒸馏失败，跳过本轮摘要（主任务不受影响）", detail: error.localizedDescription)
            return ""
        }
    }

    // MARK: - 注入与清理

    /// 构建注入用的系统消息文本；无有效记忆时返回 nil。
    static func buildInjectionBlock(sharedContext: [String: String]) -> String? {
        guard let pad = sharedContext[Self.scratchpadKey],
              !pad.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return "\n\n[长期记忆 SCRATCHPAD · 系统蒸馏，非模型自述]:\n\(pad)"
    }

    /// 新会话开始时清空记忆。返回清除了记忆条目的新上下文快照。
    static func reset(sharedContext: [String: String]) -> [String: String] {
        var copy = sharedContext
        copy.removeValue(forKey: Self.scratchpadKey)
        return copy
    }
    
    /// 扫描上下文提取通用结构化标签块
    static func extractGenericTags(from messages: [ContextMessage]) -> GenericTagBlockRegistry {
        var registry = GenericTagBlockRegistry()
        for msg in messages {
            guard let text = msg.content, text.contains("<") else { continue }
            registry.ingest(text: text)
        }
        return registry
    }
}
