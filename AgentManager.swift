//////////////////////////////////////////////////////////////////
// 文件名：AgentManager.swift
// 文件说明：适用于 macOS 14+ 的 Agent 智能体编排、模型原生自主内省与 AI 引擎配置中心 (Swift 6 Ready)
//
// 核心架构与运行逻辑说明：
// 1. 模型原生自主内省与轻量名录架构 (Model-Native Autonomous Introspection):
//    - 释放大模型原生深度思考 (Deep Thinking) 能力，通过动态生成 <available_skills_directory> 引导自主检索。
//    - 默认装配静态核心元工具箱：read_skill_manual（支持渐进式多级文档查阅与沙盒安全防线）与 execute_skill（通用具身动态执行代理）。
// 2. 长短任务兼顾机制 (Dual Lifecycle):
//    - 短任务与简单问答采用自然语言直接交付；长任务则由外部工作区及领域专属规范流驱动。
// 3. 抗脆弱性防御与物理真值核验 (Anti-fragile & Safeguards):
//    - 内置周期震荡死循环熔断器 (Oscillating Loop Breaker)、多工具并发执行 (TaskGroup)、网络抖动指数退避自愈、参数类型动态 Coerce 与无头公证员对账机制。
// 4. 正向逻辑规约设计 (Positive Framing):
//    - 系统指引全面采用正向行为边界规范，确保语义纯净度并维持模型最佳执行状态。
// 5. 阶段化装配工坊与 Facade 门面模式:
//    - AgentViewModel 统一封装技能池、模型调度与团队协作白皮书 (Team Manifest)。
//    - 拟物化 5 阶段卡片式流水线配置面板（身份 → 指令 → 推理 → 记忆 → 武器库）。
// 6. 提示词缓存保护 (Prompt Cache Optimization):
//    - 静态 System Prompt 保持 100% 不变，动态技能名录作为独立系统消息头部注入，最大化命中大模型底层 KV Cache。
//////////////////////////////////////////////////////////////////

import SwiftUI
import AppKit
import Combine
import Foundation

// MARK: - ==================== 1. AgentExecutionModels (调度与指标模型域) ====================

/// Agent 调度请求统一载荷
struct AgentExecutionRequest: Sendable {
    var prompt: String
    var agentID: UUID?
    var personaID: UUID?
    var images: [NSImage]
    var fileURLs: [URL]
    var historyMessages: [ChatMessage]
    var sliceIndex: Int
    var sharedContext: [String: String]
    var callerTag: String
    var autoApproveConfirmation: Bool
    var sessionLogID: UUID?

    init(
        prompt: String,
        agentID: UUID? = nil,
        personaID: UUID? = nil,
        images: [NSImage] = [],
        fileURLs: [URL] = [],
        historyMessages: [ChatMessage] = [],
        sliceIndex: Int = 0,
        sharedContext: [String: String] = [:],
        callerTag: String = "Global",
        autoApproveConfirmation: Bool = false,
        sessionLogID: UUID? = nil
    ) {
        self.prompt = prompt
        self.agentID = agentID
        self.personaID = personaID
        self.images = images
        self.fileURLs = fileURLs
        self.historyMessages = historyMessages
        self.sliceIndex = sliceIndex
        self.sharedContext = sharedContext
        self.callerTag = callerTag
        self.autoApproveConfirmation = autoApproveConfirmation
        self.sessionLogID = sessionLogID
    }
}

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

// MARK: - ==================== 3. AgentToolDispatcher (物理工具分发与公证沙盒) ====================

enum AgentToolDispatcher {
    
    /// 单个工具物理执行中枢 (支持参数动态 Coerce、HITL 拦截、多模态解析与安全截断)
    @MainActor
    static func executeSingleTool(
        tc: (id: String, name: String, args: [String: Any], thoughtSignature: String?),
        currentAgent: AgentProfile,
        dynamicActiveSkills: [AgentSkill],
        originalUserPrompt: String,
        autoApprove: Bool,
        agentVM: AgentViewModel,
        continuation: AsyncThrowingStream<AgentStep, Error>.Continuation
    ) async -> (id: String, name: String, result: String, image: NSImage?, fileURL: URL?, isFinished: Bool) {
        let invokedToolId = tc.id
        let invokedToolName = tc.name
        let invokedToolArgs = tc.args
        let invokedThoughtSignature = tc.thoughtSignature
        
        // 1. Sub-Agent 专家团队委派分支
        if invokedToolName == "call_sub_agent" {
            let targetAgentName = invokedToolArgs["agent_name"] as? String ?? ""
            let taskInstruction = invokedToolArgs["task_instruction"] as? String ?? ""
            let allowedAgents = ConfigManager.shared.app.agentProfiles.filter { currentAgent.allowedSubAgentIDs.contains($0.id) }
            
            if let subProfile = allowedAgents.first(where: { $0.name.localizedCaseInsensitiveContains(targetAgentName) }) {
                continuation.yield(.status("正在移交专家 [\(subProfile.name)] 协作处理..."))
                let subResult = await runSubAgentSandbox(profile: subProfile, taskInstruction: taskInstruction, agentVM: agentVM, continuation: continuation)
                return (invokedToolId, invokedToolName, subResult, nil, nil, false)
            } else {
                return (invokedToolId, invokedToolName, "{\"error\": \"指定的下属专家不存在\"}", nil, nil, false)
            }
        }
        
        // 2. 数字分身角色扮演隔离推演分支
        if invokedToolName == "call_digital_persona" {
            let targetPersonaName = invokedToolArgs["persona_name"] as? String ?? ""
            let dialogueInput = invokedToolArgs["dialogue_input"] as? String ?? ""
            let sceneContext = invokedToolArgs["scene_context"] as? String ?? ""
            
            let personaResult = await runPersonaSandbox(
                personaName: targetPersonaName,
                dialogueInput: dialogueInput,
                sceneContext: sceneContext,
                allowedPersonaIDs: currentAgent.allowedPersonaIDs,
                continuation: continuation
            )
            return (invokedToolId, invokedToolName, personaResult, nil, nil, false)
        }
        
        // 3. 终态结单与无头公证员纯逻辑对账 (Proof-Carrying Gate)
        if invokedToolName == "finish_task" {
            let finalAnswer = (invokedToolArgs["final_answer"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? (invokedToolArgs["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "任务已顺利完成。"
            let evidence = (invokedToolArgs["verification_evidence"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            
            continuation.yield(.status("🔍 正在拉起无头公证员进行交付物逻辑对账..."))
            
            let (isVerified, discrepancyReason) = await verifyClaimWithHeadlessCritic(
                originalPrompt: originalUserPrompt,
                evidence: evidence,
                model: currentAgent.baseModel
            )
            
            if isVerified {
                continuation.yield(.textDelta(finalAnswer))
                agentVM.sharedContext["LAST_TOOL_HAS_ERROR"] = "false"
                return (invokedToolId, invokedToolName, "{\"status\": \"ok\", \"message\": \"公证核验通过，任务已结单归档\"}", nil, nil, true)
            } else {
                let rejectFeedback = """
                【无头公证员核验未通过】:
                - 缺失项诊断: \(discrepancyReason)
                - 指引建议: 请调用相关物理工具补齐上述缺失配置，执行物理读回命令获取真实数据证据后，再次调用 finish_task 提交结单。
                """
                LogManager.shared.warning("🛑 交付物未通过无头公证员对账", detail: rejectFeedback, parentID: LogManager.shared.activeContextID)
                return (invokedToolId, invokedToolName, rejectFeedback, nil, nil, false)
            }
        }
        
        // 4. 匹配物理工具实体（自适应名称兼容与容错映射）
        var matchedSkill: AgentSkill? = dynamicActiveSkills.first(where: {
            $0.name.lowercased() == invokedToolName.lowercased()
        })

        let equippedSkills = agentVM.skills.filter { skill in
            skill.isEnabled && currentAgent.equippedSkillIDs.contains(skill.id)
        }

        if matchedSkill == nil {
            let normalizedName = invokedToolName.lowercased()
                .replacingOccurrences(of: "-", with: "_")
                .replacingOccurrences(of: "skill_", with: "")
            
            matchedSkill = equippedSkills.first(where: {
                let sName = $0.name.lowercased()
                    .replacingOccurrences(of: "-", with: "_")
                    .replacingOccurrences(of: "skill_", with: "")
                return sName == normalizedName || $0.displayName.localizedCaseInsensitiveContains(invokedToolName)
            })
            
            if let fallback = matchedSkill {
                LogManager.shared.info(
                    "🪄 [智能容错] 模型直接调用了已勾选的技能实体 [\(invokedToolName)]，已自动映射至 [\(fallback.name)] 物理执行",
                    parentID: LogManager.shared.activeContextID
                )
            }
        }

        guard let skill = matchedSkill else {
            let isConfiguredInGlobal = agentVM.skills.contains(where: {
                let sName = $0.name.lowercased().replacingOccurrences(of: "-", with: "_")
                let iName = invokedToolName.lowercased().replacingOccurrences(of: "-", with: "_")
                return sName == iName || sName == "skill_\(iName)" || iName == "skill_\(sName)"
            })
            
            if isConfiguredInGlobal {
                return (invokedToolId, invokedToolName, "{\"error\": \"技能 [\(invokedToolName)] 未在当前智能体分身中勾选配备。请先在分身配置面板中勾选该技能。\"}", nil, nil, false)
            } else {
                return (invokedToolId, invokedToolName, "{\"error\": \"未找到工具 [\(invokedToolName)]。请调用 read_skill_manual 核对可用技能名录。\"}", nil, nil, false)
            }
        }
        
        // 参数自适应 Coerce 装配
        var rawArgs = invokedToolArgs
        if (skill.type == .cli || skill.type == .shell) && rawArgs["raw_command"] == nil && rawArgs["command"] == nil {
            if let inputStr = (rawArgs["input"] as? String) ?? (rawArgs["action"] as? String) {
                rawArgs["command"] = inputStr
                rawArgs["raw_command"] = inputStr
            }
        }
        let safeArgs = coerceArguments(args: rawArgs, skill: skill)
        
        // 5. 人类在环授权拦截 (HITL)
        if skill.requiresConfirmation && !autoApprove {
            continuation.yield(.toolCallConfirmation(id: invokedToolId, name: invokedToolName, args: safeArgs))
            let isAllowed = await UserInteractionManager.shared.requestPermission(id: invokedToolId)
            if !isAllowed {
                return (invokedToolId, invokedToolName, "{\"error\": \"User Denied Permission\"}", nil, nil, false)
            }
        }
        
        // 6. UI 语义解包与状态通知
        var displayToolName = skill.name
        if (invokedToolName == "execute_skill"),
           let realSkillName = (invokedToolArgs["skill_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !realSkillName.isEmpty {
            displayToolName = realSkillName
        }
        
        continuation.yield(.toolCallInfo(id: invokedToolId, name: displayToolName, args: safeArgs, thoughtSignature: invokedThoughtSignature))
        
        // 7. 执行底层引擎并解析 Base64 多模态负载
        let rawResult = await agentVM.executeTool(skill: skill, args: safeArgs, skipConfirmation: true)
        let (processedResult, extractedImg, savedURL) = rawResult.processBase64ImagePayload()

        let isMetaTool = ["finish_task", "read_skill_manual", "execute_skill", "call_sub_agent", "skill_memory_manager"].contains(invokedToolName)

        if !isMetaTool {
            let isExecutionFailed = PhysicalTruthVerifier.hasPhysicalError(output: processedResult)
            agentVM.sharedContext["LAST_TOOL_HAS_ERROR"] = isExecutionFailed ? "true" : "false"
        }
        
        // 8. 安全截断保护（头尾保真压缩）
        let maxSafeChars = 30_000
        let execResult: String
        if processedResult.count > maxSafeChars {
            let headLen = 18_000
            let tailLen = 12_000
            let head = processedResult.prefix(headLen)
            let tail = processedResult.suffix(tailLen)
            execResult = "\(head)\n\n...[⚠️ 输出内容过长，已执行头尾保真压缩，原始共 \(processedResult.count) 字符]...\n\n\(tail)"
        } else {
            execResult = processedResult
        }
        
        return (invokedToolId, displayToolName, execResult, extractedImg, savedURL, execResult.hasPrefix("[AGENT_PIPELINE_TERMINATE]:"))
    }
    
    /// 无头公证员纯逻辑对账机制 (Zero-Tool Critic Agent)
    static func verifyClaimWithHeadlessCritic(
        originalPrompt: String,
        evidence: String,
        model: String
    ) async -> (passed: Bool, reason: String) {
        let cleanEvidence = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if cleanEvidence.isEmpty || cleanEvidence == "{}" || cleanEvidence == "[]" {
            return (false, "缺少真实物理依据，请先调用相关查询指令提取系统真实反馈数据，再提交公证。")
        }
        
        let lowerEvidence = cleanEvidence.lowercased()
        if lowerEvidence.contains("blocked_by_quota") || lowerEvidence.contains("error") || lowerEvidence.contains("failed") || lowerEvidence.contains("exception") {
            return (false, "物理证据显示底层执行遭遇异常，请处理报错并重新验证后再提交。")
        }
        
        let criticInstruction = """
        你是一名极其严谨的企业级交付质量公证员（Verifier）。
        请对照【用户原始需求】与提供的【物理读回证据数据】，客观评判需求是否真正达成。
        
        【公证原则】：
        - 请关注证据的“真实系统特征”（如环境特有的字段结构、非自然语言编排的冗余数据），若证据表现为高度概括的总结性话语或过于工整却缺乏特征的假 JSON，请判定为未通过。
        - 仅依据物理证据中的客观字段/ID 进行对账验证。
        - 请严格遵循以下 JSON 格式输出结果：
        {"passed": true/false, "reason": "通过评价或具体的驳回原因与修正指引"}
        """
        
        let criticPrompt = """
        【用户原始需求】:
        \(originalPrompt)
        
        【物理读回证据数据】:
        \(cleanEvidence)
        """
        
        do {
            let stream = LLMService.shared.ask(
                messages: [.user(criticPrompt)],
                model: model,
                images: [],
                fileURLs: [],
                instruction: criticInstruction,
                activeSkills: []
            )
            
            var criticResponse = ""
            for try await step in stream {
                if case .textDelta(let t) = step { criticResponse += t }
            }
            
            let cleanJSON = criticResponse.extractJSON() ?? criticResponse
            if let data = cleanJSON.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let passed = dict["passed"] as? Bool {
                let reason = dict["reason"] as? String ?? "核验完成"
                return (passed, reason)
            }
            
            let isPassed = criticResponse.contains("\"passed\": true") || (criticResponse.contains("通过") && !criticResponse.contains("未通过"))
            return (isPassed, isPassed ? "公证核验通过" : criticResponse)
        } catch {
            return (true, "公证通道网络波动，降级放行")
        }
    }
    
    /// Sub-Agent 专家沙盒独立推演
    @MainActor
    static func runSubAgentSandbox(
        profile: AgentProfile,
        taskInstruction: String,
        agentVM: AgentViewModel,
        continuation: AsyncThrowingStream<AgentStep, Error>.Continuation
    ) async -> String {
        let subSkills = agentVM.skills.filter { skill in skill.isEnabled && profile.equippedSkillIDs.contains(skill.id) }
        let initialInstruction = profile.systemPrompt + "\n【执行要求】：完成后请输出详尽解答。"
        var subMessages: [ContextMessage] = [.user("【专家委派任务】:\n\(taskInstruction)")]
        
        let maxIterations = profile.enableAutonomy ? min(profile.maxSteps, 8) : 1
        var currentIteration = 0
        var finalResult = ""
        var isTaskFinished = false
        
        while currentIteration < maxIterations && !isTaskFinished {
            if Task.isCancelled { return "⚠️ 专家任务已取消" }
            currentIteration += 1
            
            let stream = LLMService.shared.ask(
                messages: subMessages,
                model: profile.baseModel,
                images: [],
                fileURLs: [],
                instruction: initialInstruction,
                activeSkills: subSkills
            )
            
            var roundText = ""
            var bgToolName = ""
            var bgToolArgs: [String: Any] = [:]
            var hasTool = false
            
            do {
                for try await step in stream {
                    if Task.isCancelled { break }
                    switch step {
                    case .textDelta(let t), .reasoningDelta(let t):
                        roundText += t
                    case .toolCallInfo(_, let name, let args, _):
                        hasTool = true
                        bgToolName = name
                        bgToolArgs = args
                    default: break
                    }
                }
            } catch {
                return "❌ 专家沙盒执行失败: \(error.localizedDescription)"
            }
            
            if hasTool {
                if bgToolName == "finish_task" {
                    finalResult = bgToolArgs["final_answer"] as? String ?? "专家已交付任务"
                    isTaskFinished = true
                    continue
                }
                if let targetSkill = subSkills.first(where: { $0.name == bgToolName }) {
                    let res = await agentVM.executeTool(skill: targetSkill, args: bgToolArgs, skipConfirmation: true)
                    let jsonArgs = (try? JSONSerialization.data(withJSONObject: bgToolArgs)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    subMessages.append(.assistant(text: "\(roundText)\n[调用动作: \(bgToolName), 参数: \(jsonArgs)]\n[反馈]: \(res)"))
                }
            } else {
                finalResult = roundText
                isTaskFinished = true
            }
        }
        return finalResult.isEmpty ? "专家已完成处理" : finalResult
    }
    
    /// 数字分身隔离心智演进沙盒
    static func runPersonaSandbox(
        personaName: String,
        dialogueInput: String,
        sceneContext: String,
        allowedPersonaIDs: [UUID],
        continuation: AsyncThrowingStream<AgentStep, Error>.Continuation
    ) async -> String {
        let cleanName = personaName.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard let persona = PersonaManager.shared.personas.first(where: {
            allowedPersonaIDs.contains($0.id) &&
            ($0.name.localizedCaseInsensitiveContains(cleanName) || cleanName.localizedCaseInsensitiveContains($0.name))
        }) else {
            return "{\"error\": \"分身「\(personaName)」未被当前智能体授权或不存在，请检查配置。\"}"
        }
        
        continuation.yield(.status("正在唤醒分身 [\(persona.name)] 入戏推演..."))
        
        var compiledPrompt = PersonaManager.shared.compilePersonaPrompt(for: persona.id, query: dialogueInput)
        if !sceneContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            compiledPrompt += "\n【🎭 即时情境】:\n\(sceneContext)\n"
        }
        
        let sandboxMessages: [ContextMessage] = [
            .system(compiledPrompt),
            .user(dialogueInput)
        ]
        
        let fallbackModel = ConfigManager.shared.app.agentProfiles.first?.baseModel ?? "gemini-2.0-flash"
        let stream = LLMService.shared.ask(
            messages: sandboxMessages,
            model: fallbackModel,
            images: [],
            fileURLs: [],
            instruction: compiledPrompt,
            activeSkills: []
        )
        
        var accumulatedResponse = ""
        do {
            for try await step in stream {
                if Task.isCancelled { break }
                if case .textDelta(let t) = step {
                    accumulatedResponse += t
                }
            }
        } catch {
            return "❌ 分身沙盒通信异常: \(error.localizedDescription)"
        }
        
        if let deltaJSON = accumulatedResponse.extractPersonaDelta() {
            PersonaManager.shared.applyMentalDelta(for: persona.id, deltaJSON: deltaJSON)
        }
        PersonaManager.shared.recordInteraction(personaID: persona.id)
        
        let cleanDialogue = accumulatedResponse.filterPersonaDelta().trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanDialogue.isEmpty ? "（\(persona.name) 凝视着你，未作言语）" : cleanDialogue
    }
    
    private static func coerceArguments(args: [String: Any], skill: AgentSkill) -> [String: Any] {
        var corrected = args
        for param in skill.parameters {
            guard let val = args[param.name] else { continue }
            switch param.type {
            case .number:
                if let s = val as? String { corrected[param.name] = Int(s) ?? Double(s) ?? val }
            case .boolean:
                if let s = val as? String { corrected[param.name] = (s.lowercased() == "true" || s == "1") }
            case .string:
                if let dict = val as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: dict), let str = String(data: data, encoding: .utf8) { corrected[param.name] = str }
            default: break
            }
        }
        return corrected
    }
}

// MARK: - ==================== 4. AgentAutonomyEngine (多轮推演核心状态机) ====================

enum AgentAutonomyEngine {
    
    /// 执行端到端推理流水线：基于多轮推演进行动态名录装配与原生自主推演
    @MainActor
    static func runPipeline(
        request: AgentExecutionRequest,
        agentManager: AgentManager,
        continuation: AsyncThrowingStream<AgentStep, Error>.Continuation
    ) async throws {
        let cleanPrompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPrompt.isEmpty || !request.images.isEmpty || !request.fileURLs.isEmpty else {
            return
        }
        
        for (k, v) in request.sharedContext {
            agentManager.agentVM.sharedContext[k] = v
        }
        
        // 1. 解析当前唤醒的 Agent 实体
        let currentAgent: AgentProfile
        if let pID = request.personaID,
           let persona = PersonaManager.shared.personas.first(where: { $0.id == pID }) {
            let fallbackModel = ConfigManager.shared.app.agentProfiles.first?.baseModel ?? "gemini-2.0-flash"
            let hostEquippedIDs = request.agentID.flatMap { aID in
                ConfigManager.shared.app.agentProfiles.first(where: { $0.id == aID })
            }?.equippedSkillIDs ?? []
            
            let mergedSkillIDs = Array(Set(persona.equippedSkillIDs + hostEquippedIDs))
            currentAgent = AgentProfile(
                name: persona.name,
                icon: "theatermasks.fill",
                baseModel: fallbackModel,
                systemPrompt: PersonaManager.shared.compileStaticPersonaPrompt(for: persona.id),
                bindKnowledgeCategory: persona.bindDedicatedCategory ?? "",
                equippedSkillIDs: mergedSkillIDs,
                enableAutonomy: true,
                executionMode: .interactive,
                maxSteps: 8,
                maxAutoRuns: 3,
                enableCircuitBreaker: true,
                maxRepetitions: 3
            )
        } else if let aID = request.agentID,
                  let agent = ConfigManager.shared.app.agentProfiles.first(where: { $0.id == aID }) {
            currentAgent = agent
        } else {
            currentAgent = ConfigManager.shared.app.agentProfiles.first ?? AgentProfile(
                name: "默认助手",
                baseModel: "gemini-2.0-flash",
                systemPrompt: "你是由系统调用的专家，请直接输出高质量专业解答。"
            )
        }

        // 2. 静态常驻元工具装配 (100% 保护 Prompt Cache)
        let allConfiguredSkills = agentManager.agentVM.skills.filter { skill in
            skill.isEnabled && currentAgent.equippedSkillIDs.contains(skill.id)
        }

        let skillsBasePath = ConfigManager.shared.skillsPath?.path ?? ""
        var dynamicActiveSkills: [AgentSkill] = []
        
        dynamicActiveSkills.removeAll(where: { $0.name == "call_digital_persona" })
        let boundPersonas = PersonaManager.shared.personas.filter { currentAgent.allowedPersonaIDs.contains($0.id) }
        if !boundPersonas.isEmpty {
            dynamicActiveSkills.append(Skill_CallPersona(boundPersonas: boundPersonas))
        }
        
        dynamicActiveSkills.sort { $0.name.lowercased() < $1.name.lowercased() }

        // 3. 构造轻量可用技能名录
        let hasExecuteSkill = allConfiguredSkills.contains(where: { $0.name == "execute_skill" })
        let staticMetaNames: Set<String> = ["read_skill_manual", "execute_skill", "finish_task", "call_digital_persona", "call_sub_agent"]
        let equippedBusinessSkills = allConfiguredSkills.filter { !staticMetaNames.contains($0.name) }
        
        var lightweightCatalog = ""
        if hasExecuteSkill && !equippedBusinessSkills.isEmpty {
            if let manualSkill = agentManager.agentVM.skills.first(where: { $0.name == "read_skill_manual" }) {
                dynamicActiveSkills.append(manualSkill)
            } else {
                dynamicActiveSkills.append(Skill_ReadManual(skillsBasePath: skillsBasePath))
            }
            
            if let execSkill = agentManager.agentVM.skills.first(where: { $0.name == "execute_skill" }) {
                dynamicActiveSkills.append(execSkill)
            } else {
                dynamicActiveSkills.append(Skill_ExecuteSkill())
            }
            
            if let finishSkill = agentManager.agentVM.skills.first(where: { $0.name == "finish_task" }) {
                dynamicActiveSkills.append(finishSkill)
            }
            
            lightweightCatalog = AgentContextOrchestrator.buildLightweightCatalog(for: equippedBusinessSkills)
        } else {
            dynamicActiveSkills = equippedBusinessSkills
        }
        
        let activeModelConfig = ConfigManager.shared.app.aiConfigs.first(where: { $0.models.contains(currentAgent.baseModel) })
        let maxContextTokens = activeModelConfig?.maxContextTokens ?? 32000
        
        let (enrichedMsgs, totalTokens) = await AgentContextOrchestrator.buildEnrichedContext(
            request: request,
            currentAgent: currentAgent,
            activeSkills: dynamicActiveSkills,
            maxTokens: maxContextTokens,
            enrichers: agentManager.enrichers,
            sharedContext: agentManager.agentVM.sharedContext
        )
        agentManager.agentVM.sharedContext["AGENT_TOTAL_TOKENS"] = "\(totalTokens)"
        var loopMessages = enrichedMsgs
        
        if !lightweightCatalog.isEmpty {
            loopMessages.insert(.system(lightweightCatalog), at: 0)
        }
        
        // 4. 纯净静态系统指令注入
        var systemInstruction = currentAgent.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !systemInstruction.contains("<autonomous_protocol>") && hasExecuteSkill && !equippedBusinessSkills.isEmpty {
            systemInstruction += AgentContextOrchestrator.buildAutonomousProtocol()
        }
        
        // 5. 初始化推演状态机
        let initialStepBudget = currentAgent.enableAutonomy ? max(1, currentAgent.maxSteps) : 1
        var maxIterations = initialStepBudget
        var currentIteration = 0
        var autoExtensionCount = 0
        var isTaskFinished = false
        var textOnlyRounds = 0
        var consecutiveErrors = 0
        var currentRoundImages: [NSImage] = request.images
        var historicalToolExecutionMap: [String: [String: String]] = [:]
        let parentSessionID = request.sessionLogID ?? LogManager.shared.activeContextID
        
        // 6. 多轮自主推演核心循环
        while currentIteration < maxIterations && !isTaskFinished {
            try Task.checkCancellation()
            currentIteration += 1
            
            let roundLogID = LogManager.shared.startGroup(
                title: "🌀 [Agent 迭代 \(currentIteration)/\(maxIterations)]",
                detail: nil,
                level: .info,
                parentID: parentSessionID
            )
            LogManager.shared.setContext(roundLogID)
            
            var currentRoundMessages = loopMessages
            
            if currentAgent.enableCompaction {
                currentRoundMessages = AgentContextOrchestrator.compactContext(
                    messages: currentRoundMessages,
                    keepRecentTurns: currentAgent.keepRecentTurns,
                    maxObservationLength: currentAgent.maxObservationLength
                )
            }
            
            let requestStartTime = Date()
            var isFirstTokenReceived = false
            var firstTokenLatency: TimeInterval = 0.0

            let stream = LLMService.shared.ask(
                messages: currentRoundMessages,
                model: currentAgent.baseModel,
                images: currentRoundImages,
                fileURLs: currentIteration == 1 ? request.fileURLs : [],
                instruction: systemInstruction,
                activeSkills: dynamicActiveSkills
            )
            
            var hasToolCallInThisRound = false
            var roundResponseText = ""
            var roundReasoningText = ""
            var currentToolCalls: [(id: String, name: String, args: [String: Any], thoughtSignature: String?)] = []
            
            do {
                for try await step in stream {
                    try Task.checkCancellation()
                    
                    switch step {
                    case .textDelta(let t):
                        if !isFirstTokenReceived {
                            isFirstTokenReceived = true
                            firstTokenLatency = Date().timeIntervalSince(requestStartTime)
                            LogManager.shared.info(
                                "⚡️ 收到首字响应 (TTFT: \(String(format: "%.2f", firstTokenLatency))s)",
                                detail: "大模型连接正常，流式交付正文...",
                                parentID: roundLogID
                            )
                        }
                        roundResponseText += t
                        continuation.yield(.textDelta(t))
                        
                    case .reasoningDelta(let r):
                        if !isFirstTokenReceived {
                            isFirstTokenReceived = true
                            firstTokenLatency = Date().timeIntervalSince(requestStartTime)
                            LogManager.shared.info(
                                "⚡️ 收到首字响应 (TTFT: \(String(format: "%.2f", firstTokenLatency))s)",
                                detail: "大模型连接顺畅，正在进行深度推演 (<think>)...",
                                parentID: roundLogID
                            )
                        }
                        roundReasoningText += r
                        continuation.yield(.reasoningDelta(r))
                        
                    case .reasoningDone:
                        continuation.yield(.reasoningDone)
                        
                    case .toolCallInfo(let id, let name, let args, let thoughtSig):
                        hasToolCallInThisRound = true
                        let safeId = id.isEmpty ? "call_\(UUID().uuidString.prefix(6))" : id
                        currentToolCalls.append((id: safeId, name: name, args: args, thoughtSignature: thoughtSig))
                        
                    case .usageUpdate(let count):
                        continuation.yield(.usageUpdate(count))
                        LogManager.shared.updateTokens(nodeID: roundLogID, tokens: count)
                        
                    default: break
                    }
                }
                consecutiveErrors = 0
            } catch {
                let errorMsg = error.localizedDescription
                let nsError = error as NSError
                let lowerError = errorMsg.lowercased()
                
                LogManager.shared.error("❌ 模型响应异常", detail: errorMsg, parentID: roundLogID)
                
                if error is CancellationError { throw error }
                
                // 429 账户额度耗尽 / 欠费拦截
                let isQuotaExceeded = lowerError.contains("quota") || lowerError.contains("billing") || lowerError.contains("exceeded your current quota") || lowerError.contains("insufficient_quota")
                if isQuotaExceeded {
                    let quotaNotice = """
                    
                    > ❌ **API 账户额度耗尽 / 配额超限 (HTTP 429)**:
                    > 当前服务商 API Key 的可用额度已耗尽或已达到计费上限。
                    > 请前往对应模型服务商后台充值或检查账单与配额设置。任务推演已安全终止。
                    """
                    continuation.yield(.textDelta(quotaNotice))
                    LogManager.shared.error("🛑 触发账户额度硬上限，终止推演", detail: errorMsg, parentID: roundLogID)
                    break
                }
                
                // 502/503/504 服务端瞬时过载或并发限流自动指数退避重试
                let isRateLimit = lowerError.contains("rate limit") || lowerError.contains("resource_exhausted") || lowerError.contains("429")
                let isServerOverload = errorMsg.contains("503") || errorMsg.contains("502") || errorMsg.contains("504") || lowerError.contains("overloaded") || (nsError.domain == "HTTPError" && [429, 502, 503, 504].contains(nsError.code))
                
                if isServerOverload || isRateLimit {
                    consecutiveErrors += 1
                    if consecutiveErrors >= 5 {
                        let timeoutNotice = "\n\n> ❌ **服务端高负载 / 速率限制重试超时**: 多次自动重试未恢复 (\(errorMsg))，推演已停止。"
                        continuation.yield(.textDelta(timeoutNotice))
                        break
                    }
                    
                    let retryDelaySeconds = 2.0 * pow(1.5, Double(consecutiveErrors - 1))
                    continuation.yield(.status("⏳ 服务端限流或瞬时过载，将在 \(String(format: "%.1f", retryDelaySeconds))s 后自动重试 (第 \(consecutiveErrors)/5 次)..."))
                    
                    try? await Task.sleep(nanoseconds: UInt64(retryDelaySeconds * 1_000_000_000))
                    currentIteration -= 1
                    continue
                }
                
                // Gemini thought_signature 丢失容错重试
                if errorMsg.contains("thought_signature") || (nsError.domain == "HTTPError" && nsError.code == 400) {
                    consecutiveErrors += 1
                    if consecutiveErrors >= 3 {
                        continuation.yield(.textDelta("\n\n> ❌ **模型交互协议异常**: 无法建立上下文签名 (\(errorMsg))。"))
                        break
                    }
                    loopMessages.append(.assistant(text: "我已感知到系统状态，正在重新规划方案。"))
                    currentIteration -= 1
                    continue
                }
                
                consecutiveErrors += 1
                if consecutiveErrors >= 3 {
                    continuation.yield(.textDelta("\n\n> ❌ **模型通信中断**: 连续重试失败: \(errorMsg)"))
                    break
                }
                
                let retryDelay = UInt64(1.0 * 1_000_000_000)
                try? await Task.sleep(nanoseconds: retryDelay)
                currentIteration -= 1
                continue
            }
            
            let rawCleanText = roundResponseText.filterTHINK().filterStopTokens().trimmingCharacters(in: .whitespacesAndNewlines)
            if !hasToolCallInThisRound && rawCleanText.isEmpty && !roundReasoningText.isEmpty {
                LogManager.shared.warning("⚠️ 检测到推演完成但正文为空且无动作，触发正向自愈", parentID: roundLogID)
                loopMessages.append(.system("【系统指引】: 逻辑推演已就绪，请通过标准 Tool Call 接口调用物理工具，或直接在正文中输出解答。"))
                continue
            }
            
            let totalRoundDuration = Date().timeIntervalSince(requestStartTime)
            let streamingDuration = max(0, totalRoundDuration - firstTokenLatency)
            let metricsSummary = String(
                format: "首字: %.2fs · 生成: %.1fs · 总计: %.1fs",
                firstTokenLatency,
                streamingDuration,
                totalRoundDuration
            )
            
            var decisionSummary = "【耗时指标】: \(metricsSummary)\n\n"
            if !roundReasoningText.isEmpty {
                decisionSummary += "【思考过程】:\n\(roundReasoningText.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
            }
            if !roundResponseText.isEmpty {
                decisionSummary += "【模型回答】:\n\(roundResponseText.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
            }
            if !currentToolCalls.isEmpty {
                let callList = currentToolCalls.map { tc in
                    let argStr = (try? JSONSerialization.data(withJSONObject: tc.args)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    return "● 动作 [\(tc.name)]: \(argStr)"
                }.joined(separator: "\n")
                decisionSummary += "【决定下发动作】:\n\(callList)"
            }
            
            LogManager.shared.info(
                currentToolCalls.isEmpty ? "🧠 模型推理与正文交付 (\(metricsSummary))" : "🧠 模型推理与动作决策 (\(metricsSummary))",
                detail: decisionSummary.isEmpty ? "(本轮无文本输出)" : decisionSummary,
                parentID: roundLogID
            )
            
            if hasToolCallInThisRound {
                textOnlyRounds = 0
                
                let llmToolCalls = currentToolCalls.map { tc in
                    let argStr = (try? JSONSerialization.data(withJSONObject: tc.args)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    return LLMToolCall(id: tc.id, name: tc.name, arguments: argStr, thoughtSignature: tc.thoughtSignature)
                }
                loopMessages.append(.assistant(text: roundResponseText.isEmpty ? nil : roundResponseText, toolCalls: llmToolCalls))
                
                let executionResults = await withTaskGroup(of: (id: String, name: String, result: String, image: NSImage?, fileURL: URL?, isFinished: Bool).self) { group in
                    for tc in currentToolCalls {
                        group.addTask { @MainActor in
                            return await AgentToolDispatcher.executeSingleTool(
                                tc: tc,
                                currentAgent: currentAgent,
                                dynamicActiveSkills: dynamicActiveSkills,
                                originalUserPrompt: cleanPrompt,
                                autoApprove: request.autoApproveConfirmation,
                                agentVM: agentManager.agentVM,
                                continuation: continuation
                            )
                        }
                    }
                    var collected: [(id: String, name: String, result: String, image: NSImage?, fileURL: URL?, isFinished: Bool)] = []
                    for await res in group { collected.append(res) }
                    return collected
                }
                
                var newlyCapturedImages: [NSImage] = []
                for res in executionResults {
                    let isManualRead = (res.name == "read_skill_manual")
                    let isExecutionFailed: Bool
                    if isManualRead {
                        isExecutionFailed = res.result.hasPrefix("❌") || res.result.hasPrefix("● 执行诊断：")
                    } else {
                        isExecutionFailed = res.result.hasPrefix("❌")
                            || res.result.contains("⚠️ CLI 命令异常退出")
                            || res.result.contains("⚠️ Shell 脚本异常退出")
                            || res.result.hasPrefix("● 执行诊断：")
                    }

                    var prunedResultText: String
                    if isExecutionFailed {
                        let diagnostic = ToolExecutionDiagnostic.analyze(errorMessage: res.result)
                        let matchedLessons = await MemoryManager.shared.getToolLessons(for: [res.name], topKPerTool: 2)
                        var reflection = diagnostic.structuredHealingPrompt
                        
                        // 确保原始报错未在 healingPrompt 中出现时进行安全补全保真
                        if !reflection.contains(res.result) && !res.result.isEmpty {
                            reflection = "⚠️ 执行报错:\n\(res.result)\n\n\(reflection)"
                        }
                        
                        if !matchedLessons.isEmpty {
                            reflection += "\n\n💡 知识库历史调用规范参考:\n\(matchedLessons)"
                        }
                        prunedResultText = reflection
                    } else {
                        prunedResultText = res.result
                    }
                    
                    let toolName = res.name
                    let trimmedResult = prunedResultText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let currentArgsDict = currentToolCalls.first(where: { $0.id == res.id })?.args ?? [:]
                    let currentArgsSummary = (try? JSONSerialization.data(withJSONObject: currentArgsDict, options: [.sortedKeys]))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "\(currentArgsDict)"

                    if hasExecuteSkill && !trimmedResult.isEmpty && !isExecutionFailed {
                        if let previousInput = historicalToolExecutionMap[toolName]?[trimmedResult] {
                            prunedResultText = """
                            【系统强阻断 · 状态一致与命令未命中】:
                            你下发的指令 [\(currentArgsSummary)] 产生的结果与历史调用 [\(previousInput)] 完全相同（返回了通用帮助或重复数据），表明当前命令或参数系凭空猜测，未命中有效物理功能。

                            【强制行动指引】:
                            1. 立即停止下发 execute_skill 尝试盲猜命令。
                            2. 你的下一个 Tool Call 必须调用 `read_skill_manual(target_skill_name: "\(toolName)", doc_path: "...")` 精读对应业务子文档。
                            3. 掌握手册中记载的真实子命令与参数格式后，方可继续下发物理执行。
                            """
                            LogManager.shared.warning(
                                "🛑 捕捉到工具 [\(toolName)] 盲猜并重复输出，已注入强阻断深潜指令",
                                parentID: roundLogID
                            )
                        } else {
                            if historicalToolExecutionMap[toolName] == nil { historicalToolExecutionMap[toolName] = [:] }
                            historicalToolExecutionMap[toolName]?[trimmedResult] = currentArgsSummary
                        }
                    }
                    
                    loopMessages.append(.tool(id: res.id, name: res.name, result: prunedResultText))
                    continuation.yield(.toolCallResult(name: res.name, result: res.result))
                    
                    LogManager.shared.log(
                        level: isExecutionFailed ? .error : .success,
                        title: "⚡️ 动作执行 [\(res.name)]",
                        detail: "【执行反馈】:\n\(res.result)",
                        parentID: roundLogID
                    )
                    
                    if res.isFinished { isTaskFinished = true }
                    if let img = res.image { newlyCapturedImages.append(img) }
                }
                
                if !newlyCapturedImages.isEmpty {
                    loopMessages.append(.user("【视觉感知】: 以下是动作捕获的实况图像，请结合图像继续推进下一步："))
                    currentRoundImages = newlyCapturedImages
                } else {
                    currentRoundImages = []
                }
                
            } else {
                textOnlyRounds += 1
                let cleanRound = roundResponseText.filterTHINK().filterStopTokens().trimmingCharacters(in: .whitespacesAndNewlines)
                let isExplicitGivingUp = cleanRound.contains("无法继续") || cleanRound.contains("已终止") || cleanRound.contains("放弃任务")
                
                if isExplicitGivingUp && textOnlyRounds >= 2 {
                    isTaskFinished = true
                    LogManager.shared.info("🛑 检测到模型明确表达终止意图，平仓退出推演", parentID: roundLogID)
                } else if currentAgent.enableAutonomy && currentIteration < maxIterations && textOnlyRounds <= 2 && hasExecuteSkill {
                    let isFailedLast = isExecutionFailedInLastRound(loopMessages)
                    let promptGuidance = isFailedLast
                        ? "【系统纠偏指引】: 前序命令未命中有效功能。请调用 read_skill_manual 精读对应子文档获取确切语法后，再下发 Tool Call 推进。"
                        : "【系统推进指引】: 规划与阶段探查已就绪，请继续通过 Tool Call 下发确切的物理执行或读回验证命令。"
                    
                    let lastMessageContent = loopMessages.last?.content ?? ""
                    if !lastMessageContent.contains("系统推进指引") && !lastMessageContent.contains("系统纠偏指引") {
                        loopMessages.append(.system(promptGuidance))
                        LogManager.shared.info("🔄 拦截到纯文本停顿，已注入单次推进指令驱动模型继续执行", parentID: roundLogID)
                    }
                    continue
                } else {
                    isTaskFinished = true
                }
            }
            
            // 步数预算调度
            if currentIteration >= maxIterations && !isTaskFinished {
                let stepBudget = max(1, currentAgent.maxSteps)
                
                if currentAgent.executionMode == .fullyAuto && autoExtensionCount < currentAgent.maxAutoRuns {
                    autoExtensionCount += 1
                    maxIterations += stepBudget
                    let autoNotice = "⚡️ 步数已达预算上限，自动闭环机制已静默追加 \(stepBudget) 步推演 (第 \(autoExtensionCount)/\(currentAgent.maxAutoRuns) 轮)..."
                    continuation.yield(.status(autoNotice))
                    LogManager.shared.info("🔁 自动闭环静默续跑", detail: autoNotice, parentID: roundLogID)
                } else {
                    let pauseID = UUID().uuidString
                    let isHardCapReached = currentAgent.executionMode == .fullyAuto && autoExtensionCount >= currentAgent.maxAutoRuns
                    let stepExhaustedNotice = isHardCapReached
                        ? "智能体已完成 \(autoExtensionCount) 轮自动续跑（累计 \(currentIteration) 步），已达安全上限，请人工复核进度。"
                        : "智能体已完成 \(maxIterations) 步自主推演，任务流程尚未结单。"
                    
                    continuation.yield(.status("⏳ 等待人工确认下一步指示..."))
                    continuation.yield(.pausedForHuman(
                        id: pauseID,
                        reason: stepExhaustedNotice,
                        suggestedActions: ["追加 \(stepBudget) 步推演", "交付当前结论"]
                    ))
                    LogManager.shared.warning("⏳ 触发人工接管挂起", detail: stepExhaustedNotice, parentID: roundLogID)
                    
                    let humanInput = await AgentInterventionUI.requestGuidance(
                        agentName: currentAgent.name,
                        reason: stepExhaustedNotice,
                        suggestedActions: ["追加 \(stepBudget) 步推演", "交付当前结论"]
                    )
                    
                    if let input = humanInput, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        loopMessages.append(.user("【用户追加指示】: \(input)\n请继续推进并完成后续任务。"))
                        maxIterations += stepBudget
                        autoExtensionCount = 0
                    } else {
                        isTaskFinished = true
                    }
                }
            }
            
            LogManager.shared.setContext(parentSessionID)
        }
    }
    
    private static func isExecutionFailedInLastRound(_ messages: [ContextMessage]) -> Bool {
        guard let lastMsg = messages.last(where: { $0.role == .tool }) else { return false }
        let content = lastMsg.content ?? ""
        return content.contains("❌") || content.contains("⚠️") || content.contains("未就绪") || content.contains("No such file") || content.contains("error")
    }
}

// MARK: - ==================== 5. AgentManager (全局通用无头调度门面) ====================

@Observable
@MainActor
final class AgentManager: Sendable {
    static let shared = AgentManager()
    
    var agentVM: AgentViewModel
    var knowledgeVM: KnowledgeViewModel
    
    var enrichers: [ChatContextEnricher] = [
        StickyPrivateQAEnricher(),
        HistorySlidingWindowEnricher()
    ]
    
    private init() {
        self.agentVM = AgentViewModel()
        self.knowledgeVM = KnowledgeViewModel()
    }
    
    /// 打开并置前 Agent 智能体配置中心独立窗口
    func show() {
        AgentWindowManager.shared.show()
    }
    
    func registerEnricher(_ enricher: ChatContextEnricher) {
        enrichers.append(enricher)
        enrichers.sort { $0.priority < $1.priority }
    }
    
    func executeStream(request: AgentExecutionRequest) -> AsyncThrowingStream<AgentStep, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await AgentAutonomyEngine.runPipeline(
                        request: request,
                        agentManager: self,
                        continuation: continuation
                    )
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    if !(error is CancellationError) {
                        continuation.yield(.error(error.localizedDescription))
                    }
                    continuation.finish(throwing: error)
                }
            }
            
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}

@MainActor
final class AgentWindowManager: NSObject, NSWindowDelegate {
    static let shared = AgentWindowManager()
    private var window: NSWindow?
    
    var isVisible: Bool {
        guard let w = window else { return false }
        return w.isVisible && !w.isMiniaturized
    }
    
    private override init() {
        super.init()
    }
    
    func show() {
        if let existingWindow = window {
            if existingWindow.isMiniaturized {
                existingWindow.deminiaturize(nil)
            }
            existingWindow.makeKeyAndOrderFront(nil)
            existingWindow.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let view = AgentManagerView(
            agentVM: AgentManager.shared.agentVM,
            knowledgeVM: AgentManager.shared.knowledgeVM
        )
        
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1020, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Agent 配置中心"
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self
        newWindow.isOpaque = false
        newWindow.backgroundColor = .clear
        newWindow.hasShadow = true
        newWindow.titlebarAppearsTransparent = true
        newWindow.titleVisibility = .hidden
        newWindow.contentView = NSHostingView(rootView: view)
        
        self.window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        newWindow.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        MainWindowManager.syncDockIconPolicy()
    }
    
    func windowWillClose(_ notification: Notification) {
        window = nil
        MainWindowManager.syncDockIconPolicy()
    }
}

// MARK: - ==================== 6. AgentViewModel & Legacy (视图门面与推理适配器) ====================

@Observable
@MainActor
class AgentViewModel {
    var skillManager: SkillManager
    
    var sharedContext: [String: String] {
        get { skillManager.sharedContext }
        set { skillManager.sharedContext = newValue }
    }
    
    var skills: [AgentSkill] {
        get { skillManager.skills }
        set { skillManager.skills = newValue }
    }
    
    init() {
        self.skillManager = SkillManager()
    }
    
    func loadSkills() {
        skillManager.loadSkills()
    }
    
    func getActiveSkills(for agentID: UUID? = nil) -> [AgentSkill] {
        return skillManager.getActiveSkills(for: agentID)
    }
    
    func executeTool(skill: AgentSkill, args: [String: Any], skipConfirmation: Bool = false) async -> String {
        return await skillManager.executeTool(skill: skill, args: args, skipConfirmation: skipConfirmation)
    }
    
    func generateTeamManifest(for mainAgent: AgentProfile) -> String {
        return skillManager.generateTeamManifest(for: mainAgent)
    }
}

@Observable
@MainActor
class AgentExecutionEngine {
    var currentStep: Int = 0
    init() {}
    
    func runAgentLoop(initialPrompt: String, config: AgentProfile, tools: [AgentSkill], agentViewModel: AgentViewModel) async -> String {
        let request = AgentExecutionRequest(
            prompt: initialPrompt,
            agentID: config.id,
            sharedContext: agentViewModel.sharedContext,
            callerTag: "ExecutionEngine",
            autoApproveConfirmation: true
        )
        
        var fullAnswer = ""
        do {
            let stream = AgentManager.shared.executeStream(request: request)
            for try await step in stream {
                if case .textDelta(let delta) = step {
                    fullAnswer += delta
                }
            }
        } catch {
            return "❌ Agent 执行异常: \(error.localizedDescription)"
        }
        return fullAnswer.isEmpty ? "任务执行完毕（无文本输出）" : fullAnswer
    }
}

// MARK: - ==================== 7. AgentUI Components (拟真装配工坊与模型面板) ====================

/// 全局通用的左对齐表单标签行组件
@MainActor
struct LeftAlignedRow<Content: View>: View {
    let title: String
    let alignment: VerticalAlignment
    let content: Content
    
    init(_ title: String, alignment: VerticalAlignment = .firstTextBaseline, @ViewBuilder content: () -> Content) {
        self.title = title
        self.alignment = alignment
        self.content = content()
    }
    
    var body: some View {
        HStack(alignment: alignment, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 75, alignment: .leading)
                .foregroundStyle(.secondary)
            content
        }
    }
}

@MainActor
struct AgentManagerView: View {
    @State private var selectedTab: Int? = 0
    var agentVM: AgentViewModel
    var knowledgeVM: KnowledgeViewModel
    
    init(agentVM: AgentViewModel, knowledgeVM: KnowledgeViewModel) {
        self.agentVM = agentVM
        self.knowledgeVM = knowledgeVM
    }
    
    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                Label("智能体", systemImage: "person.crop.square.fill").tag(0)
                Label("数字分身", systemImage: "theatermasks.fill").tag(10)
                Label("AI 模型引擎", systemImage: "server.rack").tag(1)
                Label("Skills 技能", systemImage: "wrench.and.screwdriver.fill").tag(2)
                Label("MCP 协议网络", systemImage: "network.badge.shield.half.filled").tag(9)
                Label("知识库语料", systemImage: "books.vertical.fill").tag(3)
                Label("长效记忆区", systemImage: "brain.head.profile").tag(4)
                Label("自动化触发器", systemImage: "bolt.badge.automatic.fill").tag(5)
                Label("系统提示词", systemImage: "quote.bubble.fill").tag(6)
                Label("对话记录", systemImage: "clock.arrow.2.circlepath").tag(7)
                Label("运行日志", systemImage: "list.bullet.rectangle").tag(8)
            }
            .listStyle(SidebarListStyle())
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
            .scrollContentBackground(.hidden)
        } detail: {
            if selectedTab == 0 { AgentProfilesPanel(agentVM: agentVM, knowledgeVM: knowledgeVM) }
            else if selectedTab == 10 { PersonaManagementPanel(manager: .shared) }
            else if selectedTab == 1 { AiModelConfigPanel() }
            else if selectedTab == 2 { SkillManagementPanel(viewModel: agentVM.skillManager) }
            else if selectedTab == 9 { MCPManagementPanel(viewModel: agentVM.skillManager) }
            else if selectedTab == 3 { KnowledgeBasePanel(viewModel: knowledgeVM) }
            else if selectedTab == 4 { MemoryManagementPanel() }
            else if selectedTab == 5 { AutomationManagementPanel() }
            else if selectedTab == 7 { ChatHistoryManagementPanel() }
            else if selectedTab == 8 { LogPanelWindow() }
            else {
                VStack(spacing: 12) {
                    Image(systemName: "cpu.fill").font(.system(size: 48)).foregroundStyle(.tertiary)
                    Text("请在左侧选择要管理的模块").font(.title3).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 920, minHeight: 640)
        .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow).ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SwitchAgentManagerTab"))) { notification in
            if let tab = notification.object as? Int {
                self.selectedTab = tab
            }
        }
    }
}

@MainActor
struct AgentProfilesPanel: View {
    @Bindable var agentVM: AgentViewModel
    @Bindable var knowledgeVM: KnowledgeViewModel
    
    @State private var profiles: [AgentProfile] = ConfigManager.shared.app.agentProfiles
    @State private var selectedProfileID: UUID?
    @State private var isCreating: Bool = false
    @State private var defaultAgentID: UUID? = ConfigManager.shared.app.generalConfig.defaultAgentID
    
    init(agentVM: AgentViewModel, knowledgeVM: KnowledgeViewModel) {
        self.agentVM = agentVM
        self.knowledgeVM = knowledgeVM
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: "person.crop.square.fill").foregroundColor(.blue)
                        Text("智能体分身流水线工坊").font(.headline)
                    }
                    Text("以阶段化流水线组装核心身份、认知中枢、执行策略、私域记忆与武器协作矩阵").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                
                Button {
                    guard !isCreating else { return }; isCreating = true
                    let fallbackModel = ConfigManager.shared.app.aiConfigs.flatMap { $0.models }.first ?? ""
                    let newAgent = AgentProfile(name: "新建智能体", baseModel: fallbackModel, systemPrompt: "你是一个高效、严谨的智能助手。请使用中文提供简洁、结构化且可执行的解答。")
                    withAnimation {
                        profiles.append(newAgent)
                        saveProfiles()
                        selectedProfileID = newAgent.id
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { isCreating = false }
                } label: {
                    Label("创建新分身", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color.clear)
            
            ModernDivider(style: .fade(0.15))
            
            HSplitView {
                List(selection: $selectedProfileID) {
                    ForEach(profiles) { profile in
                        HStack(spacing: 10) {
                            Image(systemName: profile.icon)
                                .font(.system(size: 15))
                                .foregroundColor(selectedProfileID == profile.id ? .white : .blue)
                                .frame(width: 20)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(profile.name)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(selectedProfileID == profile.id ? .white : .primary)
                                    if defaultAgentID == profile.id {
                                        Image(systemName: "crown.fill")
                                            .font(.system(size: 10))
                                            .foregroundColor(selectedProfileID == profile.id ? .yellow : .orange)
                                    }
                                }
                                Text("模型: \(profile.baseModel)")
                                    .font(.system(size: 10))
                                    .foregroundColor(selectedProfileID == profile.id ? .white.opacity(0.8) : .secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 4)
                        .tag(profile.id)
                        .contextMenu {
                            Button("设为全局默认分身") { setDefaultAgent(profile.id) }
                            Divider()
                            Button("删除此分身", role: .destructive) { deleteProfile(profile.id) }
                        }
                    }
                }
                .listStyle(.sidebar)
                .frame(minWidth: 160, idealWidth: 190, maxWidth: 230)
                .scrollContentBackground(.hidden)
                .forceHideScrollbars()
                
                ZStack(alignment: .topLeading) {
                    if let idx = profiles.firstIndex(where: { $0.id == selectedProfileID }) {
                        AgentProfileEditor(
                            profile: $profiles[idx],
                            isDefault: defaultAgentID == profiles[idx].id,
                            aiConfigs: ConfigManager.shared.app.aiConfigs,
                            availableCategories: knowledgeVM.categories,
                            dedicatedCategories: knowledgeVM.dedicatedCategories,
                            availableSkills: agentVM.skills,
                            onMakeDefault: { setDefaultAgent(profiles[idx].id) },
                            onSave: saveProfiles
                        )
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.dashed").font(.system(size: 40)).foregroundStyle(.tertiary)
                            Text("请在左侧选择或创建一个智能体进行深入配置").foregroundColor(.secondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                .background(.ultraThinMaterial)
            }
        }
        .onAppear {
            self.profiles = ConfigManager.shared.app.agentProfiles
            if selectedProfileID == nil { selectedProfileID = profiles.first?.id }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("AgentProfilesExternallyUpdated"))) { _ in
            self.profiles = ConfigManager.shared.app.agentProfiles
        }
    }
    
    private func deleteProfile(_ id: UUID) {
        withAnimation {
            profiles.removeAll { $0.id == id }
            saveProfiles()
            selectedProfileID = profiles.first?.id
        }
    }
    
    private func setDefaultAgent(_ id: UUID) {
        withAnimation {
            defaultAgentID = id
            ConfigManager.shared.app.generalConfig.defaultAgentID = id
            ConfigManager.shared.saveConfig()
        }
    }
    
    private func saveProfiles() {
        ConfigManager.shared.app.agentProfiles = profiles
        ConfigManager.shared.saveConfig()
    }
}

@MainActor
struct AgentProfileEditor: View {
    @Binding var profile: AgentProfile
    var isDefault: Bool
    
    let aiConfigs: [AiConfig]
    let availableCategories: [String]
    let dedicatedCategories: [String]
    let availableSkills: [AgentSkill]
    
    let onMakeDefault: () -> Void
    let onSave: () -> Void
    
    @State private var showQAManagerSheet = false
    private let icons = ["sparkles", "brain.head.profile", "wrench.and.screwdriver", "terminal", "doc.text.magnifyingglass", "globe", "chart.bar.doc.horizontal", "theatermasks.fill", "cpu", "network", "lock.shield.fill", "paintpalette.fill"]
    
    init(profile: Binding<AgentProfile>, isDefault: Bool, aiConfigs: [AiConfig], availableCategories: [String], dedicatedCategories: [String], availableSkills: [AgentSkill], onMakeDefault: @escaping () -> Void, onSave: @escaping () -> Void) {
        self._profile = profile
        self.isDefault = isDefault
        self.aiConfigs = aiConfigs
        self.availableCategories = availableCategories
        self.dedicatedCategories = dedicatedCategories
        self.availableSkills = availableSkills
        self.onMakeDefault = onMakeDefault
        self.onSave = onSave
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                editorHeroHeader
                
                // STAGE 1：核心身份与引擎底座
                assemblyStageCard(
                    stageBadge: "STAGE 1",
                    stageTitle: "核心身份与引擎底座",
                    stageSubtitle: "定义智能体的唯一称号、专属视觉锚点与驱动大模型",
                    themeColor: .blue
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        LeftAlignedRow("分身名称") {
                            TextField("例如: 代码重构专家 / 决策分析师", text: $profile.name)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 320)
                        }
                        
                        LeftAlignedRow("专属图标") {
                            HStack(spacing: 6) {
                                ForEach(icons, id: \.self) { icon in
                                    let isSelected = profile.icon == icon
                                    Button {
                                        withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { profile.icon = icon }
                                    } label: {
                                        Image(systemName: icon)
                                            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                                            .frame(width: 26, height: 26)
                                            .foregroundColor(isSelected ? .white : .primary)
                                            .background(isSelected ? Color.blue : Color(NSColor.controlBackgroundColor))
                                            .cornerRadius(6)
                                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Color.blue : Color(NSColor.separatorColor).opacity(0.3), lineWidth: 1))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .frame(height: 28)
                        }
                        
                        LeftAlignedRow("驱动模型") {
                            HStack(spacing: 12) {
                                Picker("", selection: $profile.baseModel) {
                                    if aiConfigs.isEmpty {
                                        Text("⚠️ 暂无可用模型配置").tag(profile.baseModel)
                                    } else {
                                        let allAvailableModels = aiConfigs.flatMap { $0.models }
                                        if !allAvailableModels.contains(profile.baseModel) && !profile.baseModel.isEmpty {
                                            Text("未知游离模型: \(profile.baseModel)").tag(profile.baseModel)
                                            Divider()
                                        }
                                        
                                        ForEach(aiConfigs) { config in
                                            let groupName = config.name.isEmpty ? config.protocolType.uppercased() : config.name
                                            Section(header: Text(groupName)) {
                                                if config.models.isEmpty {
                                                    Text("无可用模型").font(.caption).tag("_\(config.id)_empty")
                                                } else {
                                                    ForEach(config.models, id: \.self) { model in
                                                        Text(model).tag(model)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 220)
                                
                                if let matchedConfig = aiConfigs.first(where: { $0.models.contains(profile.baseModel) }) {
                                    Text(matchedConfig.protocolType.uppercased())
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Color.blue.opacity(0.75).gradient)
                                        .cornerRadius(4)
                                        .help("当前大模型底座使用的底层通信协议")
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                        }
                    }
                }
                
                // STAGE 2：认知中枢与系统指令
                assemblyStageCard(
                    stageBadge: "STAGE 2",
                    stageTitle: "认知中枢与系统指令",
                    stageSubtitle: "编排智能体的系统级 Prompt",
                    themeColor: .orange
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .center) {
                            Text("System Prompt 核心指令").font(.system(size: 11, weight: .bold)).foregroundColor(.orange)
                            Spacer()
                        }
                        
                        TextEditor(text: $profile.systemPrompt)
                            .frame(height: 120)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(4)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor), lineWidth: 1))
                        
                        Text("💡 提示：系统会自动提取首行作为【路由说明】(对主控公开)，请在首行简述其核心能力。底层执行纪律请在第二行之后书写。")
                            .font(.caption)
                            .foregroundColor(.blue)
                            .padding(.top, 2)
                        
                        ActionChipSyntaxGuideView()
                    }
                }
                
                // STAGE 3：自主推理与安全策略
                assemblyStageCard(
                    stageBadge: "STAGE 3",
                    stageTitle: "自主推理与安全策略",
                    stageSubtitle: "设定自主推演意图模式、步数预算与底层防御体系",
                    themeColor: .red
                ) {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle(isOn: $profile.enableAutonomy) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("开启多轮自主推演 (Autonomy Loop)")
                                    .font(.system(size: 13, weight: .medium))
                                Text("开启后智能体可连续调用工具推导；纯问答场景建议关闭以节省 Token。")
                                    .font(.system(size: 10.5))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        
                        if profile.enableAutonomy {
                            ModernDivider(style: .fade(0.12))
                            
                            VStack(alignment: .leading, spacing: 6) {
                                Text("推演调度模式")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.secondary)
                                
                                Picker("", selection: $profile.executionMode) {
                                    ForEach(AutonomyExecutionMode.allCases, id: \.self) { mode in
                                        Text(mode.rawValue).tag(mode)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .onChange(of: profile.executionMode) { _, newMode in
                                    if newMode == .fullyAuto {
                                        profile.enableCircuitBreaker = true
                                    }
                                }
                                
                                Text(profile.executionMode == .interactive ? "💬 步数耗尽或遇到死循环时，主动弹出原生悬浮窗等待人工指示。" : "⚡️ 步数耗尽后自动续跑，全程不打扰；强制锁定防死循环熔断以保护 Token。")
                                    .font(.system(size: 10.5))
                                    .foregroundColor(profile.executionMode == .fullyAuto ? .orange : .blue)
                                    .padding(.top, 2)
                            }
                            
                            HStack {
                                Text("⚡️ 单轮推演预算")
                                    .font(.system(size: 11.5, weight: .semibold))
                                Spacer()
                                Text("\(profile.maxSteps) 步")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(.red)
                                Stepper("", value: $profile.maxSteps, in: 1...30)
                                    .labelsHidden()
                                    .controlSize(.small)
                            }
                            .padding(8)
                            .background(Color.red.opacity(0.05))
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.red.opacity(0.15), lineWidth: 1))
                            
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 4) {
                                                Text("防死循环熔断")
                                                    .font(.system(size: 11, weight: .semibold))
                                                if profile.executionMode == .fullyAuto {
                                                    Text("🔒 自动闭环已锁定")
                                                        .font(.system(size: 9, weight: .bold))
                                                        .foregroundColor(.green)
                                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                                        .background(Color.green.opacity(0.12))
                                                        .cornerRadius(3)
                                                }
                                            }
                                            Text("连续执行相同动作时阻断推演")
                                                .font(.system(size: 10))
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        Toggle("", isOn: $profile.enableCircuitBreaker)
                                            .labelsHidden()
                                            .toggleStyle(.switch)
                                            .controlSize(.small)
                                            .disabled(profile.executionMode == .fullyAuto)
                                    }
                                    
                                    if profile.enableCircuitBreaker {
                                        HStack {
                                            Text("最大容忍重复次数")
                                                .font(.system(size: 11))
                                                .foregroundColor(.secondary)
                                            Spacer()
                                            Stepper(value: $profile.maxRepetitions, in: 2...6) {
                                                Text("\(profile.maxRepetitions) 次").fontDesign(.monospaced).font(.system(size: 11))
                                            }
                                        }
                                    }
                                    
                                    if profile.executionMode == .fullyAuto {
                                        HStack {
                                            Text("自动续跑最大硬顶")
                                                .font(.system(size: 11))
                                                .foregroundColor(.secondary)
                                            Spacer()
                                            Stepper(value: $profile.maxAutoRuns, in: 1...5) {
                                                Text("最多 \(profile.maxAutoRuns) 轮").fontDesign(.monospaced).font(.system(size: 11))
                                            }
                                        }
                                    }
                                    
                                    Divider().opacity(0.3)
                                    
                                    Toggle(isOn: $profile.enableCompaction) {
                                        Text("长上下文滑动智能压缩")
                                            .font(.system(size: 11, weight: .semibold))
                                    }
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                    
                                    if profile.enableCompaction {
                                        HStack {
                                            Text("近 \(profile.keepRecentTurns) 轮无损保留 · 超 \(profile.maxObservationLength) 字折叠")
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(.secondary)
                                            Spacer()
                                            Stepper("", value: $profile.keepRecentTurns, in: 4...20)
                                                .labelsHidden()
                                                .controlSize(.mini)
                                        }
                                    }
                                }
                                .padding(10)
                                .background(Color.primary.opacity(0.03))
                                .cornerRadius(6)
                                .padding(.top, 4)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "gearshape")
                                        .font(.system(size: 10))
                                    Text("高级防御与上下文压缩参数")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                
                // STAGE 4：知识图谱与私域记忆
                assemblyStageCard(
                    stageBadge: "STAGE 4",
                    stageTitle: "知识图谱与私域记忆",
                    stageSubtitle: "绑定私域向量语料分类或挂载 100% 精确匹配的 KV/QA 知识引擎",
                    themeColor: .cyan
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        LeftAlignedRow("语料检索范围") {
                            Picker("", selection: $profile.bindKnowledgeCategory) {
                                Text("🚫 无 (不挂载知识库)").tag("")
                                Text("📚 全部知识 (全局通用)").tag("全部")
                                Divider()
                                
                                ForEach(availableCategories.filter { $0 != "全部" && $0 != "" && $0 != "默认" }, id: \.self) { cat in
                                    Text("📂 通用: \(cat)").tag(cat)
                                }
                                
                                if !dedicatedCategories.isEmpty {
                                    Divider()
                                    ForEach(dedicatedCategories, id: \.self) { cat in
                                        Text("🔒 专用: \(cat)").tag(cat)
                                    }
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 220)
                        }
                        
                        Text("💡 限制分类能大幅提高专业问答的精准度并节省 Token；“无”将彻底关闭主动向量召回。")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                            .padding(.leading, 87)
                        
                        if dedicatedCategories.contains(profile.bindKnowledgeCategory) {
                            ModernDivider(style: .glow(.purple, 0.25))
                            
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "lock.doc.fill").foregroundColor(.purple).font(.system(size: 11))
                                        Text("已解锁专用私域 KV/QA 知识引擎").font(.system(size: 11, weight: .bold)).foregroundColor(.purple)
                                    }
                                    Text("基于精准关键字召回，不经向量化稀释，适合严苛业务规范。").font(.system(size: 10.5)).foregroundColor(.secondary)
                                }
                                Spacer()
                                Button(action: { showQAManagerSheet = true }) {
                                    Label("管理私域数据 (\(profile.privateQA.count))", systemImage: "text.book.closed.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.purple)
                                .controlSize(.small)
                            }
                        }
                    }
                }
                
                // STAGE 5：武器库挂载与团队协作矩阵
                assemblyStageCard(
                    stageBadge: "STAGE 5",
                    stageTitle: "武器库挂载与团队协作矩阵",
                    stageSubtitle: "配备主动技能 (Tools)、指派专家智能体并绑定可对戏的数字分身",
                    themeColor: .purple
                ) {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("配备技能链 (Tools)").font(.system(size: 11, weight: .bold)).foregroundColor(.purple)
                                Spacer()
                                Text("已挂载 \(profile.equippedSkillIDs.count) 项技能")
                                    .font(.system(size: 10.5, weight: .semibold)).foregroundColor(.purple)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 10)], alignment: .leading, spacing: 10) {
                                ForEach(availableSkills.filter { $0.name != "call_digital_persona" }) { skill in
                                    skillCard(skill: skill)
                                }
                            }
                        }
                        
                        ModernDivider(style: .fade(0.12))
                        
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("专家团队协作矩阵 (Sub-Agents)").font(.system(size: 11, weight: .bold)).foregroundColor(.indigo)
                                Spacer()
                                Text("已分配 \(profile.allowedSubAgentIDs.count) 名专家")
                                    .font(.system(size: 10.5, weight: .semibold)).foregroundColor(.indigo)
                            }
                            let availableExperts = ConfigManager.shared.app.agentProfiles.filter { $0.id != profile.id }
                            if !availableExperts.isEmpty {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 10)], alignment: .leading, spacing: 10) {
                                    ForEach(availableExperts) { expert in
                                        expertCard(expert: expert)
                                    }
                                }
                            }
                        }
                        
                        ModernDivider(style: .fade(0.12))
                        
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                HStack(spacing: 5) {
                                    Image(systemName: "theatermasks.fill").foregroundColor(.pink).font(.system(size: 11))
                                    Text("数字分身对戏矩阵 (Digital Personas)").font(.system(size: 11, weight: .bold)).foregroundColor(.pink)
                                }
                                Spacer()
                                Text("已绑定 \(profile.allowedPersonaIDs.count) 个分身")
                                    .font(.system(size: 10.5, weight: .semibold)).foregroundColor(.pink)
                            }
                            
                            let allPersonas = PersonaManager.shared.personas
                            if allPersonas.isEmpty {
                                Text("当前未创建任何数字分身，可前往「数字分身工坊」添加。")
                                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 12)
                                    .background(RoundedRectangle(cornerRadius: 6).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(.separator))
                            } else {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 10)], alignment: .leading, spacing: 10) {
                                    ForEach(allPersonas) { persona in
                                        personaCard(persona: persona)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(18)
        }
        .scrollContentBackground(.hidden)
        .forceOverlayScrollbars()
        .onChange(of: profile) { _, _ in onSave() }
        .sheet(isPresented: $showQAManagerSheet) {
            PrivateQAManagerSheet(qaList: $profile.privateQA, onClose: { showQAManagerSheet = false })
        }
    }
    
    @ViewBuilder
    private func assemblyStageCard<Content: View>(
        stageBadge: String,
        stageTitle: String,
        stageSubtitle: String,
        themeColor: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(stageBadge)
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundColor(themeColor)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(themeColor.opacity(0.12))
                    .cornerRadius(4)
                
                Text(stageTitle)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)
                
                Spacer()
                
                Text(stageSubtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.primary.opacity(0.02))
            
            ModernDivider(style: .glow(themeColor, 0.28))
            
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(14)
        }
        .background(.ultraThinMaterial)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(themeColor.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.03), radius: 4, x: 0, y: 2)
    }
    
    @ViewBuilder
    private var editorHeroHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.25), Color.purple.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 42, height: 42)
                
                Image(systemName: profile.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.name.isEmpty ? "未命名智能体" : profile.name)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    
                    if isDefault {
                        Text("👑 全局默认")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.12))
                            .cornerRadius(4)
                    }
                }
                
                Text("底层驱动引擎: \(profile.baseModel.isEmpty ? "未指定模型" : profile.baseModel)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if !isDefault {
                Button(action: onMakeDefault) {
                    Label("设为默认唤醒分身", systemImage: "crown")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
    
    private func skillCard(skill: AgentSkill) -> some View {
        let isEquipped = profile.equippedSkillIDs.contains(skill.id)
        return Button(action: {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                if isEquipped {
                    profile.equippedSkillIDs.removeAll(where: { $0 == skill.id })
                } else {
                    profile.equippedSkillIDs.append(skill.id)
                }
            }
        }) {
            HStack(spacing: 10) {
                Image(systemName: isEquipped ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: isEquipped ? .bold : .regular))
                    .foregroundColor(isEquipped ? .purple : .secondary.opacity(0.35))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isEquipped ? .primary : .secondary)
                        .lineLimit(1)
                    Text(skill.type.rawValue)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(isEquipped ? .purple.opacity(0.85) : .secondary.opacity(0.7))
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isEquipped ? Color.purple.opacity(0.1) : Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(7)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isEquipped ? Color.purple.opacity(0.35) : Color(NSColor.separatorColor).opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
    
    private func expertCard(expert: AgentProfile) -> some View {
        let isSelected = profile.allowedSubAgentIDs.contains(expert.id)
        return Button(action: {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                if isSelected {
                    profile.allowedSubAgentIDs.removeAll(where: { $0 == expert.id })
                } else {
                    profile.allowedSubAgentIDs.append(expert.id)
                }
            }
        }) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "person.2.badge.gearshape.fill" : "person.2")
                    .font(.system(size: 14, weight: isSelected ? .bold : .regular))
                    .foregroundColor(isSelected ? .indigo : .secondary.opacity(0.35))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(expert.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .lineLimit(1)
                    
                    if !expert.equippedSkillIDs.isEmpty {
                        Text("\(expert.equippedSkillIDs.count) 项核心工具")
                            .font(.system(size: 9.5))
                            .foregroundColor(isSelected ? .indigo.opacity(0.85) : .secondary)
                    } else {
                        Text("纯推理专家")
                            .font(.system(size: 9.5))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isSelected ? Color.indigo.opacity(0.1) : Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(7)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isSelected ? Color.indigo.opacity(0.35) : Color(NSColor.separatorColor).opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
    
    private func personaCard(persona: DigitalPersona) -> some View {
        let isSelected = profile.allowedPersonaIDs.contains(persona.id)
        let state = PersonaManager.shared.getOrCreateRuntimeState(for: persona.id)
        
        return Button(action: {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                if isSelected {
                    profile.allowedPersonaIDs.removeAll(where: { $0 == persona.id })
                } else {
                    profile.allowedPersonaIDs.append(persona.id)
                }
            }
        }) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: isSelected ? .bold : .regular))
                    .foregroundColor(isSelected ? .pink : .secondary.opacity(0.35))
                
                Image(systemName: persona.avatarIcon)
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? .pink : .secondary)
                    .frame(width: 18)
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(persona.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isSelected ? .primary : .secondary)
                            .lineLimit(1)
                        
                        Text(persona.roleTag)
                            .font(.system(size: 9.5))
                            .foregroundColor(isSelected ? .pink.opacity(0.85) : .secondary.opacity(0.6))
                            .lineLimit(1)
                    }
                    
                    Text("羁绊: \(state.bondMilestone.rawValue) (\(state.affinityScore)) · \(state.currentEmotion)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.7))
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isSelected ? Color.pink.opacity(0.08) : Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(7)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isSelected ? Color.pink.opacity(0.35) : Color(NSColor.separatorColor).opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

@MainActor
struct AiModelConfigPanel: View {
    @State private var aiConfigs: [AiConfig] = ConfigManager.shared.app.aiConfigs
    @State private var expandedStates: [UUID: Bool] = [:]
    
    private let protocols = ["openai", "gemini", "chatgpt", "anthropic", "ollama"]
    
    init() {}
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI 模型引擎库").font(.headline)
                    Text("配置全局可用的大模型 API 通道，Agent 将从这里的列表中挑选其大脑引擎").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    withAnimation(.spring()) {
                        let newConfig = AiConfig(name: "新建配置节点")
                        aiConfigs.append(newConfig)
                        expandedStates[newConfig.id] = true
                    }
                } label: {
                    Label("添加新通道", systemImage: "plus")
                }.buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(.thinMaterial)
            
            ModernDivider(style: .fade(0.18))
            
            ScrollView {
                if aiConfigs.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "server.rack").font(.system(size: 48)).foregroundStyle(.tertiary)
                        Text("暂无任何底层模型配置，请点击右上角添加").foregroundColor(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.top, 100)
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach($aiConfigs) { $config in
                            modelConfigCard(config: $config)
                        }
                    }
                    .padding(20)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.ultraThinMaterial)
            .scrollContentBackground(.hidden)
            .forceOverlayScrollbars()
        }
        .onChange(of: aiConfigs) { _, newValue in
            ConfigManager.shared.app.aiConfigs = newValue
            ConfigManager.shared.saveConfig()
        }
    }
    
    @ViewBuilder
    private func modelConfigCard(config: Binding<AiConfig>) -> some View {
        let isExpanded = expandedStates[config.id] ?? false
        
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "network")
                    .foregroundColor(config.wrappedValue.name.isEmpty ? .gray : .blue)
                    .font(.system(size: 18))
                
                Text(config.wrappedValue.name.isEmpty ? "未命名配置" : config.wrappedValue.name)
                    .font(.system(size: 15, weight: .semibold))
                
                Spacer()
                
                Text(config.wrappedValue.protocolType.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.blue.opacity(0.7))
                    .cornerRadius(6)
                
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundColor(.secondary)
                    .padding(.leading, 8)
            }
            .padding(16)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    expandedStates[config.id] = !isExpanded
                }
            }
            
            if isExpanded {
                ModernDivider(style: .fade(0.1))
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 16) {
                        LeftAlignedRow("节点名称") {
                            TextField("如 Local / OpenAI / DeepSeek", text: config.name).textFieldStyle(.roundedBorder)
                        }
                        LeftAlignedRow("通讯协议") {
                            Picker("", selection: config.protocolType) {
                                ForEach(protocols, id: \.self) { p in Text(p.uppercased()).tag(p) }
                            }.pickerStyle(.menu).frame(width: 120)
                        }
                    }
                    
                    LeftAlignedRow("主机地址") {
                        TextField("Host URL (如 https://api.openai.com)", text: config.host)
                            .textFieldStyle(.roundedBorder)
                            .fontDesign(.monospaced)
                    }
                    
                    LeftAlignedRow("API Key") {
                        TextField("通信鉴权秘钥 (本地化部署请留空)", text: config.apikey)
                            .textFieldStyle(.roundedBorder)
                            .fontDesign(.monospaced)
                    }
                    
                    LeftAlignedRow("上下文限制") {
                        HStack(spacing: 8) {
                            TextField("如: 32000", value: config.maxContextTokens, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .fontDesign(.monospaced)
                                .frame(width: 90)
                            
                            Text("Tokens")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                            
                            Spacer()
                            
                            Text("超限将自动截断最早期对话以防止内存溢出")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    
                    HStack(spacing: 32) {
                        Toggle("原生支持推导思考链 (Think)", isOn: config.isthink).toggleStyle(.switch).controlSize(.small)
                        Toggle("外部独立 Agent 通道", isOn: config.isagent).toggleStyle(.switch).controlSize(.small)
                    }.padding(.leading, 87)
                    
                    if config.wrappedValue.isagent {
                        LeftAlignedRow("代理地址") {
                            TextField("Agent Host", text: config.agenthost)
                                .textFieldStyle(.roundedBorder)
                                .fontDesign(.monospaced)
                        }
                    }
                    
                    ModernDivider(style: .fade(0.1))
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "cpu").foregroundColor(.secondary)
                            Text("承载的模型阵列 (用英文逗号分隔)").font(.system(size: 13, weight: .medium))
                        }
                        TextField("例如: gpt-4o, gpt-3.5-turbo", text: Binding<String>(
                            get: { config.wrappedValue.models.joined(separator: ", ") },
                            set: { newValue in
                                config.wrappedValue.models = newValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .fontDesign(.monospaced)
                        Text("此处填写的模型名称，将会在配置分身时作为下拉菜单提供选择。").font(.caption).foregroundColor(.secondary)
                    }
                    .padding(.leading, 8)
                    .padding(.top, 4)
                    
                    HStack {
                        Spacer()
                        Button(role: .destructive) {
                            withAnimation {
                                let idToDelete = config.id
                                aiConfigs.removeAll { $0.id == idToDelete }
                                expandedStates.removeValue(forKey: idToDelete)
                            }
                        } label: {
                            Label("删除此配置节点", systemImage: "trash").font(.system(size: 12))
                        }.buttonStyle(.plain).foregroundColor(.red)
                    }.padding(.top, 8)
                }
                .padding(16)
                .background(Color(NSColor.textBackgroundColor).opacity(0.15))
            }
        }
        .background(.thinMaterial)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.05), radius: 2, y: 1)
    }
}

@MainActor
struct ActionChipSyntaxGuideView: View {
    @State private var isCopied: Bool = false
    @State private var isExpanded: Bool = false
    
    init() {}
    
    private let promptTemplate = """
    【交互按钮语法】
    你可以在回复中结合 Markdown 超链接语法生成快捷按钮：
    1. 引导追问：[按钮显示的文字](action://ask/实际要问的问题)
       - 如果显示文字与问题相同，可简写为：[实际要问的问题](action://ask)
    2. 推荐技能：[按钮显示的文字](action://skill/技能ID)

    【高亮排版语法】
    为了优化阅读体验，请在关键信息上使用以下符号进行文本高亮：
    - 强调信息：==需要强调的文字==
    - 警告/错误：!!危险警告文字!!
    - 重要提示：??提示性文字??
    - 成功/完结：++处理成功文字++
    - 注释信息：~~注释文字~~
    - 卡片：<card>卡片内容</card>
    """
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "lightbulb.fill").foregroundColor(.orange)
                    Text("高级语法指南：交互筹码与高亮标记").font(.system(size: 11, weight: .bold)).foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "chevron.right").rotationEffect(.degrees(isExpanded ? 90 : 0)).font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text("在系统提示词中要求 AI 使用特定语法，对话框将自动渲染为可点击按钮或高亮色块：")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .lineSpacing(3)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "hand.tap.fill").font(.system(size: 9)).foregroundColor(.blue)
                                Text("A. 交互筹码 (Action Chips)").font(.system(size: 10.5, weight: .bold)).foregroundColor(.primary)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text("引导普通追问：\(Text(verbatim: "[按钮名称](action://ask/要发送的文字)").font(.system(size: 10.5, design: .monospaced)).foregroundColor(.cyan))")
                                    .font(.system(size: 10.5)).foregroundColor(.secondary)
                                Text("简写形式：\(Text(verbatim: "[要发送的文字](action://ask)").font(.system(size: 10.5, design: .monospaced)).foregroundColor(.cyan))")
                                    .font(.system(size: 10.5)).foregroundColor(.secondary)
                                Text("引导调用技能：\(Text(verbatim: "[按钮名称](action://skill/技能ID)").font(.system(size: 10.5, design: .monospaced)).foregroundColor(.purple))")
                                    .font(.system(size: 10.5)).foregroundColor(.secondary)
                            }.padding(.leading, 14)
                        }
                        
                        ModernDivider(style: .fade(0.1))
                        
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "paintpalette.fill").font(.system(size: 9)).foregroundColor(.pink)
                                Text("B. 语义化色彩标记 (Semantic Colors)").font(.system(size: 10.5, weight: .bold)).foregroundColor(.primary)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(verbatim: "==强调文字==").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).frame(width: 75, alignment: .leading)
                                    Image(systemName: "arrow.right").font(.system(size: 8)).foregroundColor(.secondary)
                                    Text("强调文字").font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundColor(.orange).padding(.horizontal, 5).padding(.vertical, 1).background(Color.orange.opacity(0.15)).cornerRadius(3)
                                }
                                HStack {
                                    Text(verbatim: "!!警告文字!!").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).frame(width: 75, alignment: .leading)
                                    Image(systemName: "arrow.right").font(.system(size: 8)).foregroundColor(.secondary)
                                    Text("警告文字").font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundColor(.red).padding(.horizontal, 5).padding(.vertical, 1).background(Color.red.opacity(0.12)).cornerRadius(3)
                                }
                                HStack {
                                    Text(verbatim: "??提示文字??").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).frame(width: 75, alignment: .leading)
                                    Image(systemName: "arrow.right").font(.system(size: 8)).foregroundColor(.secondary)
                                    Text("提示文字").font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundColor(.blue).padding(.horizontal, 5).padding(.vertical, 1).background(Color.blue.opacity(0.12)).cornerRadius(3)
                                }
                                HStack {
                                    Text(verbatim: "++成功文字++").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).frame(width: 75, alignment: .leading)
                                    Image(systemName: "arrow.right").font(.system(size: 8)).foregroundColor(.secondary)
                                    Text("成功文字").font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundColor(.green).padding(.horizontal, 5).padding(.vertical, 1).background(Color.green.opacity(0.12)).cornerRadius(3)
                                }
                                HStack {
                                    Text(verbatim: "~~注释文字~~").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).frame(width: 75, alignment: .leading)
                                    Image(systemName: "arrow.right").font(.system(size: 8)).foregroundColor(.secondary)
                                    Text("注释").font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundColor(.purple).padding(.horizontal, 5).padding(.vertical, 1).background(Color.purple.opacity(0.12)).cornerRadius(3)
                                }
                                HStack {
                                    Text(verbatim: "<card>卡片内容</card>").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).frame(width: 140, alignment: .leading)
                                }
                            }.padding(.leading, 14)
                        }
                    }
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor).opacity(0.4))
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.08), lineWidth: 1))
                    
                    HStack {
                        Spacer()
                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(promptTemplate, forType: .string)
                            withAnimation { isCopied = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { isCopied = false } }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                Text(isCopied ? "已复制模板" : "复制完整提示词模板")
                            }
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(isCopied ? .green : .blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(isCopied ? Color.green.opacity(0.15) : Color.blue.opacity(0.1))
                            .cornerRadius(5)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
        .cornerRadius(7)
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}
