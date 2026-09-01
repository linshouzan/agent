//////////////////////////////////////////////////////////////////
// 文件名：AgentContextMemory.swift
// 文件说明：Agent 上下文与记忆统一管理层 (Swift 6 Ready)
//
// 职责域（同一文件内三项职责互补）：
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
        
        contextMsgs.append(.user(sanitizedQuery))
        
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
        2. 查阅手册：调用 read_skill_manual(target_skill_name: "技能名") 查阅具体命令与参数规范。
        3. 具身执行：你可以直接调用该技能名称下发指令，或通过 execute_skill(skill_name: "技能名", input: "具体命令或参数") 进行物理执行。
        </available_skills_directory>
        """
        return catalog
    }
    
    /// 构造纯净正向的自主推演协议
    static func buildAutonomousProtocol() -> String {
        return """
        
        <autonomous_protocol>
        为确保长任务推演的确定性与过程透明度，请严格遵循以下工作流：
        1. 意图表达与过程透明 (Process Transparency)：
           - 每次下发工具调用前，请务必先在正文中用一两句话简述你的推演逻辑或即将执行的动作意图。请始终保持“先说明，后调用”的习惯，以让用户及时知晓当前进度。
        2. 强制内省与文档探索 (Explore & Read)：
           - 在下发执行指令前，请优先调用 `read_skill_manual` 查阅工具说明。
           - 若返回结果提示存在子文档 (doc_path) 索引，请务必继续调用 `read_skill_manual` 深入读取对应的子文档，直到获取到该命令的确切参数结构。
        3. 忠实于手册的执行 (Faithful Execution)：
           - 仅基于手册中明确给出的示例与语法结构来下发 `execute_skill` 参数。
           - 若命令规范要求通过文件传递数据（如 `@data.json`），请直接将完整的 JSON 数据作为字符串形式写入执行参数，底层运行时会自动完成文件的桥接与替换。
        4. 闭环物理核验 (Physical Verification)：
           - 在完成写入、修改或创建操作后，请追加一步“读操作”（如 info, list, status 查询），提取最新系统状态以供客观看待。
        5. 证据链交付 (Evidence-Based Completion)：
           - 调用 `finish_task` 时，请将前序“读操作”返回的真实物理数据（原文或原始 JSON）填入 `verification_evidence` 字段，以供公证系统逻辑对账。
        </autonomous_protocol>
        """
    }
}

enum AgentLongTermMemory {

    // MARK: - 常量
    static let scratchpadKey = "AGENT_SCRATCHPAD"
    /// Scratchpad 自身长度硬上限（字符），超出则截断而非重新调用模型
    static let maxScratchpadChars = 3000
    /// Token 预算触发的软水位：loopMessages 估算超过模型窗口该比例即强制蒸馏
    static let budgetTriggerRatio: Double = 0.6

    // MARK: - 主入口：周期触发蒸馏

    /// 由 runPipeline 主循环每轮调用。判断是否命中触发条件，命中则调用廉价模型重写累计记忆。
    /// - Parameters:
    ///   - loopMessages: 当前轮完整上下文（已压缩后）
    ///   - evicting: 本轮即将被折叠/淘汰的早期消息（compactContext 的"早期"部分）
    ///   - round: 当前迭代轮次（从 1 开始）
    ///   - agent: 当前智能体配置
    ///   - summarizerModel: 用于蒸馏的模型（默认与主模型同 provider，避免硬编码）
    ///   - sharedContext: 共享上下文的当前快照（传值，不跨 await 借用 inout）
    /// - Returns: 若本轮回写沉淀出新的摘要则返回该字符串，否则返回 nil（调用方据此写回）。
    ///   采用"传值 + 返回值"而非 `inout`，以规避 actor 隔离属性无法跨 async 调用传递 inout 的限制。
    @MainActor
    static func maybeCondense(
        loopMessages: [ContextMessage],
        evicting: [ContextMessage],
        round: Int,
        agent: AgentProfile,
        summarizerModel: String,
        modelMaxTokens: Int,
        sharedContext: [String: String]
    ) async -> String? {
        guard agent.enableCompaction else { return nil }

        let threshold = max(2, agent.summarizeEveryNRounds)
        let shouldByRound = (round > 0 && round % threshold == 0)

        // Token 预算触发：loopMessages 估算超模型窗口水位
        let modelMax = max(1, modelMaxTokens)
        let estTokens = TokenEstimationEngine.estimateTokens(
            messages: loopMessages,
            systemInstruction: agent.systemPrompt,
            protocolType: agent.baseModel
        )
        let shouldByBudget = Double(estTokens) > Double(modelMax) * Self.budgetTriggerRatio

        // 仅当确实有待淘汰的实质内容时才触发，避免空转浪费
        let hasEvictable = evicting.contains { ($0.content ?? "").count > 200 }

        guard (shouldByRound || shouldByBudget), hasEvictable else { return nil }

        let existing = sharedContext[Self.scratchpadKey] ?? ""
        let evictText = evicting.compactMap { $0.content }.joined(separator: "\n---\n")

        let condensed = await summarize(existing: existing, evicting: evictText, model: summarizerModel)
        if !condensed.isEmpty {
            // 自身再压缩：超过上限则截断（不重新调用模型，避免无限递归）
            let final = condensed.count > Self.maxScratchpadChars
                ? String(condensed.prefix(Self.maxScratchpadChars))
                : condensed
            LogManager.shared.info("🧠 长期记忆已蒸馏并沉淀 (轮次 \(round))", detail: "摘要长度 \(final.count) 字符 · 触发: \(shouldByRound ? "轮次" : "")\(shouldByRound && shouldByBudget ? "+" : "")\(shouldByBudget ? "Token预算" : "")")
            return final
        }
        return nil
    }

    // MARK: - 蒸馏器：调用廉价模型产出有界结构化摘要

    /// 调用模型产出结构化摘要；任何异常返回空串（fail-open，不抛错中断主任务）。
    @MainActor
    private static func summarize(existing: String, evicting: String, model: String) async -> String {
        let instruction = """
        你是企业级 Agent 的长期记忆压缩器。下面给出【即将被丢弃的早期执行记录】与【现有记忆摘要】。
        请产出一份不超过 1500 token 的新摘要，必须覆盖以下固定段落（无对应内容则写"无"）：
        ## 已达成目标
        ## 关键实体（必须带真实 ID / 字段值，仅来自证据原文，禁止编造）
        ## 已做决策与原因
        ## 待办 / 待验证
        ## 已排除的死路（避免重复盲猜，注明曾返回的错误信息）
        ## 当前指针（下一步应执行什么）
        规则：只基于证据原文，禁止编造；若早期记录为空则继承并精简现有摘要；只输出摘要本身，不要解释或包裹代码块。
        """

        let prompt = """
        【现有记忆摘要】:
        \(existing.isEmpty ? "(空)" : existing)

        【即将被丢弃的早期执行记录】:
        \(evicting)
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
        return "[长期记忆 SCRATCHPAD · 系统蒸馏，非模型自述]:\n\(pad)"
    }

    /// 新会话开始时清空记忆（可选）。返回清除了记忆条目的新上下文快照。
    static func reset(sharedContext: [String: String]) -> [String: String] {
        var copy = sharedContext
        copy.removeValue(forKey: Self.scratchpadKey)
        return copy
    }
}
