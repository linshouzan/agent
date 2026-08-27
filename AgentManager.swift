//////////////////////////////////////////////////////////////////
// 文件名：AgentManager.swift
// 文件说明：适用于 macOS 14+ 的 Agent 智能体编排与 AI 引擎配置中心 (Swift 6 Ready)
//
// 核心架构与运行逻辑说明：
// 1. 全局通用无头 Agent 调度中枢 (Headless Core Engine)：
//    - 承载全系统的多轮自主推理 (Autonomy Loop)、工具并发执行 (TaskGroup)、
//      动作指纹死循环熔断、HTTP 指数退避重试、Gemini 协议自愈与黑板状态机自推进。
// 2. 阶段化心智装配架构 (Stage-based Mental Pipeline)：
//    - STAGE 1 [蓝色] · 核心身份与引擎底座
//    - STAGE 2 [橙色] · 认知中枢与系统指令
//    - STAGE 3 [红色] · 自主推理与安全熔断
//    - STAGE 4 [青色] · 知识图谱与私域记忆
//    - STAGE 5 [紫色] · 武器库与协作矩阵
// 3. Facade 外观门面：
//    - `AgentViewModel` 作为统一管理门面，封装技能池与团队白皮书 (Team Manifest)。
//////////////////////////////////////////////////////////////////

import SwiftUI
import AppKit
import Combine
import Foundation

// MARK: - ==================== 0. 全局通用无头 Agent 调度中枢 (Core Engine) ====================

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

/// 全局通用的无头 Agent 调度与执行管理器
@Observable
@MainActor
final class AgentManager: Sendable {
    static let shared = AgentManager()
    
    var agentVM: AgentViewModel
    var knowledgeVM: KnowledgeViewModel
    
    // 插件化上下文装配器
    var enrichers: [ChatContextEnricher] = [
        StickyPrivateQAEnricher(),
        BlackboardContextEnricher(),
        HistorySlidingWindowEnricher()
    ]
    
    private init() {
        self.agentVM = AgentViewModel()
        self.knowledgeVM = KnowledgeViewModel()
    }
    
    func registerEnricher(_ enricher: ChatContextEnricher) {
        enrichers.append(enricher)
        enrichers.sort { $0.priority < $1.priority }
    }
    
    /// 核心公共调用入口：拉起标准 Agent 流式执行管道
    func executeStream(request: AgentExecutionRequest) -> AsyncThrowingStream<AgentStep, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runPipeline(request: request, continuation: continuation)
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
    
    // MARK: - 内部私有执行流水线 (集成工具避坑先验知识与去重执行协议)
    private func runPipeline(
        request: AgentExecutionRequest,
        continuation: AsyncThrowingStream<AgentStep, Error>.Continuation
    ) async throws {
        let cleanPrompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPrompt.isEmpty || !request.images.isEmpty || !request.fileURLs.isEmpty else { return }

        // 1. 合并请求上下文与共享黑板
        for (k, v) in request.sharedContext {
            agentVM.sharedContext[k] = v
        }

        // 2. 解析当前执行主体
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
                maxSteps: 6,
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
                systemPrompt: "你是由系统调用的专业助手，请直接输出清晰、高质量的业务解答。"
            )
        }

        // 3. 动态装配物理技能
        var dynamicActiveSkills = agentVM.skills.filter { skill in
            skill.isEnabled && currentAgent.equippedSkillIDs.contains(skill.id)
        }

        // 数字分身对戏工具装配
        dynamicActiveSkills.removeAll(where: { $0.name == "call_digital_persona" })
        let boundPersonas = PersonaManager.shared.personas.filter { currentAgent.allowedPersonaIDs.contains($0.id) }
        if !boundPersonas.isEmpty {
            dynamicActiveSkills.append(Skill_CallPersona(boundPersonas: boundPersonas))
        }

        // 4. 精准门禁判定：简单 Agent / 检索 Agent vs 长任务黑板 Agent
        let hasBlackboardSkill = dynamicActiveSkills.contains(where: { $0.name == "task_planner" })
        let isBlackboardActive = currentAgent.enableAutonomy && hasBlackboardSkill

        if isBlackboardActive {
            if !dynamicActiveSkills.contains(where: { $0.name == "finish_task" }) {
                if let finishSkill = agentVM.skills.first(where: { $0.name == "finish_task" }) {
                    dynamicActiveSkills.append(finishSkill)
                }
            }
        }

        dynamicActiveSkills.sort { $0.name.lowercased() < $1.name.lowercased() }

        let activeModelConfig = ConfigManager.shared.app.aiConfigs.first(where: { $0.models.contains(currentAgent.baseModel) })
        let maxContextTokens = activeModelConfig?.maxContextTokens ?? 32000

        var loopMessages = await buildEnrichedContext(
            request: request,
            currentAgent: currentAgent,
            activeSkills: dynamicActiveSkills,
            maxTokens: maxContextTokens
        )

        // 5. 知识库单轮/轻量增强注入
        if !currentAgent.enableAutonomy && !currentAgent.bindKnowledgeCategory.isEmpty {
            continuation.yield(.status("正在检索知识库 [\(currentAgent.bindKnowledgeCategory)]..."))
            let ragResult = await knowledgeVM.injectedRag(query: cleanPrompt, category: currentAgent.bindKnowledgeCategory, currentModel: currentAgent.baseModel)
            if !ragResult.context.isEmpty {
                if let lastUserIdx = loopMessages.lastIndex(where: { $0.role == .user }) {
                    loopMessages.insert(.system("【知识库检索结果】:\n\(ragResult.context)"), at: lastUserIdx)
                } else {
                    loopMessages.append(.system("【知识库检索结果】:\n\(ragResult.context)"))
                }
                continuation.yield(.ragResult(logString: ragResult.logString))
            }
        }

        // 6. 避坑经验注入 (仅在有多轮工具时按需装载)
        if isBlackboardActive {
            let activeSkillNames = Set(dynamicActiveSkills.map { $0.name })
            let toolLessons = await MemoryManager.shared.getToolLessons(for: activeSkillNames, topKPerTool: 2)
            if !toolLessons.isEmpty {
                let lessonSegment = "【工具调用规范参考】:\n\(toolLessons)"
                if let lastUserIdx = loopMessages.lastIndex(where: { $0.role == .user }) {
                    loopMessages.insert(.system(lessonSegment), at: lastUserIdx)
                } else {
                    loopMessages.append(.system(lessonSegment))
                }
            }
        }

        // 7. 正向系统指令编排 (简单 Agent 零污染，长任务 Agent 注入高效协同规则)
        var systemInstruction = currentAgent.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if isBlackboardActive && !systemInstruction.contains("<execution_protocol>") {
            systemInstruction += """

            <execution_protocol>
            1. 意图先行：下发 Tool Call 时，在正文中同步输出 1 句当前操作意图说明。
            2. 数据继承：后续任务在下发具体参数时，优先读取前置步骤沉淀在备忘录中的关键字段与 ID。
            3. 状态闭环：所有实体步骤完成后，调用 finish_task 提交结构化总结报告并结单。
            </execution_protocol>
            """
        }

        // 8. 循环预算分配 (简单 Agent 严格单轮直出)
        let initialStepBudget = currentAgent.enableAutonomy ? max(1, currentAgent.maxSteps) : 1
        var maxIterations = initialStepBudget
        var currentIteration = 0
        var autoExtensionCount = 0
        var isTaskFinished = false
        var textOnlyRounds = 0
        var consecutiveErrors = 0
        var currentRoundImages: [NSImage] = request.images
        var actionHistory: [String] = []
        let parentSessionID = request.sessionLogID ?? LogManager.shared.activeContextID

        // 9. 推演执行循环
        while currentIteration < maxIterations && !isTaskFinished {
            try Task.checkCancellation()
            currentIteration += 1

            let roundLogID = LogManager.shared.startGroup(
                title: isBlackboardActive ? "🌀 [任务迭代 \(currentIteration)/\(maxIterations)]" : "💬 [AI 响应]",
                detail: nil,
                level: .info,
                parentID: parentSessionID
            )
            LogManager.shared.setContext(roundLogID)

            var currentRoundMessages = loopMessages

            // 仅长任务 Agent 动态注入阶段微指令与黑板快照
            if isBlackboardActive {
                let currentPlan = agentVM.sharedContext["AGENT_BLACKBOARD_PLAN"]
                let currentMemo = agentVM.sharedContext["AGENT_GLOBAL_MEMO"]

                var activePlanReminder = TaskBlackboardManager.shared.generateExecutionPrompt(planString: currentPlan)
                if let memo = currentMemo, !memo.isEmpty { activePlanReminder += "\n\n【全局备忘录事实】:\n\(memo)" }
                if !activePlanReminder.isEmpty {
                    currentRoundMessages.append(.system("【系统黑板状态快照】:\n" + activePlanReminder))
                }

                if let stageMicroPrompt = AgentStagePromptEngine.resolveStageMicroPrompt(
                    isAutonomy: currentAgent.enableAutonomy,
                    hasBlackboard: isBlackboardActive,
                    blackboardPlan: currentPlan
                ) {
                    currentRoundMessages.append(.system(stageMicroPrompt))
                }
            }

            // 上下文压缩
            if currentAgent.enableCompaction && isBlackboardActive {
                currentRoundMessages = Self.compactContext(
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
                        }
                        roundResponseText += t
                        continuation.yield(.textDelta(t))

                    case .reasoningDelta(let r):
                        if !isFirstTokenReceived {
                            isFirstTokenReceived = true
                            firstTokenLatency = Date().timeIntervalSince(requestStartTime)
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
                LogManager.shared.error("❌ 模型响应异常", detail: errorMsg, parentID: roundLogID)

                if error is CancellationError { throw error }

                consecutiveErrors += 1
                if consecutiveErrors >= 3 {
                    continuation.yield(.textDelta("\n\n> ❌ **模型交互中断**: \(errorMsg)"))
                    break
                }
                let healingAdvice = "【系统环境提示】: 网络或模型网关暂时抖动，已自动排队准备重试。"
                loopMessages.append(.system(healingAdvice))
                continue
            }

            // 动作执行与状态机联动
            if hasToolCallInThisRound {
                textOnlyRounds = 0

                let llmToolCalls = currentToolCalls.map { tc in
                    let argStr = (try? JSONSerialization.data(withJSONObject: tc.args)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    return LLMToolCall(id: tc.id, name: tc.name, arguments: argStr, thoughtSignature: tc.thoughtSignature)
                }
                loopMessages.append(.assistant(text: roundResponseText.isEmpty ? nil : roundResponseText, toolCalls: llmToolCalls))

                // 死循环震荡检测
                if currentAgent.enableCircuitBreaker {
                    for tc in currentToolCalls {
                        let argData = (try? JSONSerialization.data(withJSONObject: tc.args, options: .sortedKeys)) ?? Data()
                        let argStr = String(data: argData, encoding: .utf8) ?? ""
                        actionHistory.append("\(tc.name)|\(argStr)")
                    }
                    let (isLoopDetected, loopPattern) = Self.detectOscillatingLoop(
                        history: actionHistory,
                        maxRepetitions: currentAgent.maxRepetitions
                    )
                    if isLoopDetected {
                        let pauseID = UUID().uuidString
                        let patternDesc = loopPattern.map { $0.components(separatedBy: "|").first ?? $0 }.joined(separator: " -> ")
                        let circuitNotice = "智能体触发重复调用保护 [\(patternDesc)]，已挂起请求人工指示。"
                        continuation.yield(.pausedForHuman(id: pauseID, reason: circuitNotice, suggestedActions: ["继续执行", "交付当前结论"]))
                        let humanGuidance = await AgentInterventionUI.requestGuidance(agentName: currentAgent.name, reason: circuitNotice, suggestedActions: ["继续执行", "交付当前结论"])
                        if let guidance = humanGuidance, !guidance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            loopMessages.append(.user("【人工指示】: \(guidance)"))
                            actionHistory.removeAll()
                        } else {
                            isTaskFinished = true
                            break
                        }
                    }
                }

                // 执行工具调用
                let executionResults = await withTaskGroup(of: (id: String, name: String, result: String, image: NSImage?, fileURL: URL?, isFinished: Bool).self) { group in
                    for tc in currentToolCalls {
                        group.addTask { @MainActor in
                            return await self.executeSingleTool(
                                tc: tc,
                                currentAgent: currentAgent,
                                dynamicActiveSkills: dynamicActiveSkills,
                                autoApprove: request.autoApproveConfirmation,
                                continuation: continuation
                            )
                        }
                    }
                    var collected: [(id: String, name: String, result: String, image: NSImage?, fileURL: URL?, isFinished: Bool)] = []
                    for await res in group { collected.append(res) }
                    return collected
                }

                for res in executionResults {
                    loopMessages.append(.tool(id: res.id, name: res.name, result: res.result))
                    continuation.yield(.toolCallResult(name: res.name, result: res.result))
                    if res.isFinished { isTaskFinished = true }
                }

            } else {
                textOnlyRounds += 1
                let cleanRound = roundResponseText.filterTHINK().filterStopTokens().trimmingCharacters(in: .whitespacesAndNewlines)
                let hasUnfinished = agentVM.sharedContext["AGENT_BLACKBOARD_PLAN"].flatMap { TaskBlackboardManager.shared.hasUnfinishedTasks(planString: $0) } ?? false

                if isBlackboardActive && hasUnfinished && textOnlyRounds < 3 {
                    loopMessages.append(.system("【系统流程提示】: 检测到黑板中仍有待推进任务，请调用对应工具推进当前节点到达物理终态。"))
                    continue
                } else {
                    isTaskFinished = true
                }
            }

            LogManager.shared.setContext(parentSessionID)
        }
    }
    
    // MARK: - 结构化诊断式自愈提示构建器 (正向指导协议)
    private static func detectOscillatingLoop(history: [String], maxRepetitions: Int) -> (isLoop: Bool, pattern: [String]) {
        guard history.count >= maxRepetitions else { return (false, []) }
        
        // 1. 单动作死循环: A -> A -> A
        let suffix1 = Array(history.suffix(maxRepetitions))
        if suffix1.allSatisfy({ $0 == suffix1.first }) {
            return (true, [suffix1.first ?? ""])
        }
        
        // 2. 双动作震荡: A -> B -> A -> B
        let cycle2Len = max(2, maxRepetitions) * 2
        if history.count >= cycle2Len {
            let suffix2 = Array(history.suffix(cycle2Len))
            let p = Array(suffix2.prefix(2))
            var isOscillating = true
            for i in stride(from: 0, to: cycle2Len, by: 2) {
                if Array(suffix2[i..<i+2]) != p {
                    isOscillating = false
                    break
                }
            }
            if isOscillating { return (true, p) }
        }
        
        // 3. 三动作震荡: A -> B -> C -> A -> B -> C
        let cycle3Len = 2 * 3
        if history.count >= cycle3Len {
            let suffix3 = Array(history.suffix(cycle3Len))
            let p = Array(suffix3.prefix(3))
            var isOscillating = true
            for i in stride(from: 0, to: cycle3Len, by: 3) {
                if Array(suffix3[i..<i+3]) != p {
                    isOscillating = false
                    break
                }
            }
            if isOscillating { return (true, p) }
        }
        
        return (false, [])
    }
    
    // MARK: - 结构化诊断式自愈提示构建器
    private static func buildStructuredSelfHealingPrompt(
        errorMsg: String,
        toolName: String,
        args: [String: Any] = [:]
    ) -> String {
        let lower = errorMsg.lowercased()
        var guidance = "【系统自愈指导】: 动作 [\(toolName)] 上一次执行未达预期。"
        
        if lower.contains("未找到命令") || lower.contains("command not found") || lower.contains("找不到可执行") {
            guidance += "\n- 诊断：可执行命令不存在或环境 PATH 尚未就绪。\n- 建议：调用 read_skill_manual 核对工具名称，或换用 Python/Shell 原生代码实现。"
        } else if lower.contains("参数校验失败") || lower.contains("缺少必填参数") || lower.contains("json") {
            guidance += "\n- 诊断：入参不满足工具要求。\n- 建议：检查参数定义中的必填字段，修正参数结构后重试。"
        } else if lower.contains("找不到原始文件") || lower.contains("no such file") || lower.contains("不存在") {
            guidance += "\n- 诊断：目标路径不存在。\n- 建议：先调用目录或文件检索工具核准物理路径。"
        } else if lower.contains("权限") || lower.contains("denied") || lower.contains("permission") {
            guidance += "\n- 诊断：访问受限或触发安全拦截。\n- 建议：切换至沙盒或用户下载目录。"
        } else {
            guidance += "\n- 报错摘要：\(errorMsg.prefix(240))\n- 建议：根据报错原因调整推演分支，避免下发相同参数。"
        }
        return guidance
    }
    
    // MARK: - 升级 tc 为 4 元组声明并完整透传签名
    private func executeSingleTool(
        tc: (id: String, name: String, args: [String: Any], thoughtSignature: String?),
        currentAgent: AgentProfile,
        dynamicActiveSkills: [AgentSkill],
        autoApprove: Bool,
        continuation: AsyncThrowingStream<AgentStep, Error>.Continuation
    ) async -> (id: String, name: String, result: String, image: NSImage?, fileURL: URL?, isFinished: Bool) {
        let invokedToolId = tc.id
        let invokedToolName = tc.name
        let invokedToolArgs = tc.args
        let invokedThoughtSignature = tc.thoughtSignature

        // 1. Sub-Agent 专家委派分支 (目标驱动 + 事实继承 + 契约约束)
        if invokedToolName == "call_sub_agent" {
            let targetAgentName = invokedToolArgs["agent_name"] as? String ?? ""
            let rawInstruction = (invokedToolArgs["task_instruction"] as? String) ?? (invokedToolArgs["objective"] as? String) ?? ""

            // 自动继承主黑板中的全局事实备忘
            let globalFacts = agentVM.sharedContext["AGENT_GLOBAL_MEMO"] ?? ""
            var structuredPayload = rawInstruction
            if !globalFacts.isEmpty && !rawInstruction.contains("【继承前置事实】") {
                structuredPayload = """
                【继承前置事实】:
                \(globalFacts)

                【任务指引与交付契约】:
                \(rawInstruction)
                """
            }

            let allowedAgents = ConfigManager.shared.app.agentProfiles.filter { currentAgent.allowedSubAgentIDs.contains($0.id) }
            let matchedProfile = allowedAgents.first(where: { $0.name.localizedCaseInsensitiveContains(targetAgentName) })

            continuation.yield(.status("正在移交子智能体 [\(targetAgentName.isEmpty ? "通用专家" : targetAgentName)] 处理..."))
            let subResult = await runSubAgentSandbox(
                profile: matchedProfile,
                targetName: targetAgentName,
                taskInstruction: structuredPayload,
                continuation: continuation
            )
            return (invokedToolId, invokedToolName, subResult, nil, nil, false)
        }

        // 2. 数字分身角色扮演分支
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

        // 3. 终态结单平仓分支
        if invokedToolName == "finish_task" {
            let finalStatus = (invokedToolArgs["status"] as? String)?.lowercased() ?? "success"
            let finalAnswer = (invokedToolArgs["final_answer"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? (invokedToolArgs["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "任务已顺利完成。"

            if !finalAnswer.isEmpty {
                continuation.yield(.textDelta(finalAnswer))
            }

            let latestPlan = agentVM.sharedContext["AGENT_BLACKBOARD_PLAN"]
            if let cp = latestPlan {
                if let reconciledPlan = TaskBlackboardManager.shared.finalizeRemainingTasks(
                    planString: cp,
                    finalStatusStr: finalStatus,
                    finalAnswer: finalAnswer
                ) {
                    agentVM.sharedContext["AGENT_BLACKBOARD_PLAN"] = reconciledPlan
                }
            }
            agentVM.sharedContext["LAST_TOOL_HAS_ERROR"] = "false"
            return (invokedToolId, invokedToolName, "{\"status\": \"ok\", \"message\": \"任务已结单平仓\"}", nil, nil, true)
        }

        // 4. 物理工具匹配与执行 (自动由 SkillManager.executeTool 进行 Plan A Schema 强校验)
        guard let skill = dynamicActiveSkills.first(where: { $0.name == invokedToolName }) else {
            return (invokedToolId, invokedToolName, "{\"error\": \"未找到工具 [\(invokedToolName)]\"}", nil, nil, false)
        }

        let safeArgs = coerceArguments(args: invokedToolArgs, skill: skill)

        if skill.requiresConfirmation && !autoApprove {
            continuation.yield(.toolCallConfirmation(id: invokedToolId, name: invokedToolName, args: safeArgs))
            let isAllowed = await UserInteractionManager.shared.requestPermission(id: invokedToolId)
            if !isAllowed {
                return (invokedToolId, invokedToolName, "{\"error\": \"用户拒绝了操作授权\"}", nil, nil, false)
            }
        }

        continuation.yield(.toolCallInfo(id: invokedToolId, name: invokedToolName, args: safeArgs, thoughtSignature: invokedThoughtSignature))
        let rawResult = await agentVM.executeTool(skill: skill, args: safeArgs, skipConfirmation: true)
        let (processedResult, extractedImg, savedURL) = rawResult.processBase64ImagePayload()

        // 5. 沉淀物理事实到共享备忘录
        let isMetaTool = ["task_planner", "finish_task", "read_skill_manual", "call_sub_agent", "skill_memory_manager"].contains(invokedToolName)
        if !isMetaTool && !processedResult.contains("❌") {
            let snippet = "\(invokedToolName): " + String(processedResult.prefix(120)).replacingOccurrences(of: "\n", with: " ")
            let oldMemo = agentVM.sharedContext["AGENT_GLOBAL_MEMO"] ?? ""
            agentVM.sharedContext["AGENT_GLOBAL_MEMO"] = oldMemo.isEmpty ? snippet : "\(oldMemo)\n- \(snippet)"
        }

        return (invokedToolId, invokedToolName, processedResult, extractedImg, savedURL, processedResult.hasPrefix("[AGENT_PIPELINE_TERMINATE]:"))
    }
    
    private func runSubAgentSandbox(
        profile: AgentProfile?,
        targetName: String = "",
        taskInstruction: String,
        continuation: AsyncThrowingStream<AgentStep, Error>.Continuation
    ) async -> String {
        let subSkills: [AgentSkill]
        let baseModel: String
        let systemInstruction: String

        if let p = profile {
            subSkills = agentVM.skills.filter { skill in skill.isEnabled && p.equippedSkillIDs.contains(skill.id) }
            baseModel = p.baseModel
            systemInstruction = p.systemPrompt + "\n【协同规范】：请依据任务目标、继承事实与交付契约执行，任务完成后直接输出结论。"
        } else {
            subSkills = agentVM.skills.filter { $0.isEnabled && $0.name != "call_sub_agent" }
            baseModel = ConfigManager.shared.app.agentProfiles.first?.baseModel ?? "gemini-2.0-flash"
            systemInstruction = """
            你是由系统派生的临时无头执行专家 [\(targetName.isEmpty ? "领域执行者" : targetName)]。
            【执行准则】: 请严格依据给定的【继承前置事实】与【阶段目标】调度物理工具，闭环后直接向主控提交【交付契约】中要求的数据与摘要。
            """
        }

        var subMessages: [ContextMessage] = [.user("【子智能体委派任务】:\n\(taskInstruction)")]
        let maxIterations = (profile?.enableAutonomy ?? true) ? min(profile?.maxSteps ?? 6, 8) : 1
        var currentIteration = 0
        var finalResult = ""
        var isTaskFinished = false

        while currentIteration < maxIterations && !isTaskFinished {
            if Task.isCancelled { return "⚠️ 子智能体任务已取消" }
            currentIteration += 1

            let stream = LLMService.shared.ask(
                messages: subMessages,
                model: baseModel,
                images: [],
                fileURLs: [],
                instruction: systemInstruction,
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
                return "❌ 子智能体沙盒通信异常: \(error.localizedDescription)"
            }

            if hasTool {
                if bgToolName == "finish_task" {
                    finalResult = (bgToolArgs["final_answer"] as? String) ?? "子任务已完成"
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
        return finalResult.isEmpty ? "子任务已执行完毕。" : finalResult
    }

    // MARK: - 阶段动态微提示词生成器 (纯正向逻辑引导，无负向词汇)
    struct AgentStagePromptEngine {
        static func resolveStageMicroPrompt(
            isAutonomy: Bool,
            hasBlackboard: Bool,
            blackboardPlan: String?
        ) -> String? {
            guard isAutonomy && hasBlackboard else { return nil }

            let hasNoPlan = (blackboardPlan == nil || blackboardPlan!.isEmpty || blackboardPlan == "[]")

            // 阶段 1：未挂载黑板 -> 引导理清实体并创建任务清单
            if hasNoPlan {
                return "【当前阶段：目标规划】请在正文中简要同步意图，并调用 task_planner(action: 'create', tasks: [...]) 创建阶段业务里程碑。"
            }

            let nodes = TaskBlackboardManager.shared.parsePlan(blackboardPlan!)

            // 阶段 2：存在活动节点 -> 引导继承备忘事实推进节点
            if let activeNode = TaskBlackboardManager.shared.findNextActionableTask(in: nodes) {
                return "【当前阶段：节点推进】请聚焦推进【\(activeNode.title)】。下发工具时请结合前置备忘录事实，完成后通过 result_memo 沉淀产出数据。"
            }

            // 阶段 3：所有任务节点均已达成 -> 引导三段式报告结单
            if !TaskBlackboardManager.shared.hasUnfinishedTasks(planString: blackboardPlan!) {
                return "【当前阶段：成果交付】所有阶段任务已成功闭环，请调用 finish_task 提交结构化交付报告并归档。"
            }

            return nil
        }
    }
    
    // MARK: - 数字分身隔离心智演进沙盒
    private func runPersonaSandbox(
        personaName: String,
        dialogueInput: String,
        sceneContext: String,
        allowedPersonaIDs: [UUID],
        continuation: AsyncThrowingStream<AgentStep, Error>.Continuation
    ) async -> String {
        let cleanName = personaName.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 严格鉴权：必须在已勾选允许的分身池中
        guard let persona = PersonaManager.shared.personas.first(where: {
            allowedPersonaIDs.contains($0.id) &&
            ($0.name.localizedCaseInsensitiveContains(cleanName) || cleanName.localizedCaseInsensitiveContains($0.name))
        }) else {
            return "{\"error\": \"分身「\(personaName)」未被当前智能体授权或不存在，请检查配置。\"}"
        }
        
        continuation.yield(.status("正在唤醒分身 [\(persona.name)] 入戏推演..."))
        
        // 1. 动态编译包含 Ebbinghaus 记忆、世界观、防出戏与羁绊阶梯的专属 Prompt
        var compiledPrompt = PersonaManager.shared.compilePersonaPrompt(for: persona.id, query: dialogueInput)
        if !sceneContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            compiledPrompt += "\n【🎭 即时情境】:\n\(sceneContext)\n"
        }
        
        // 2. 纯隔离会话流（不注入主控任务黑板与工具，严防穿模）
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
        
        // 3. 解析增量差分反哺心智状态（好感/情绪惯性/即时事实）
        if let deltaJSON = accumulatedResponse.extractPersonaDelta() {
            PersonaManager.shared.applyMentalDelta(for: persona.id, deltaJSON: deltaJSON)
        }
        PersonaManager.shared.recordInteraction(personaID: persona.id)
        
        let cleanDialogue = accumulatedResponse.filterPersonaDelta().trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanDialogue.isEmpty ? "（\(persona.name) 凝视着你，未作言语）" : cleanDialogue
    }
    
    private func buildEnrichedContext(
        request: AgentExecutionRequest,
        currentAgent: AgentProfile,
        activeSkills: [AgentSkill],
        maxTokens: Int
    ) async -> [ContextMessage] {
        let sanitizedQuery = ChatOrchestrator.sanitizeUserMessage(request.prompt)
        let payload = ContextEnrichmentPayload(
            query: sanitizedQuery,
            currentAgent: currentAgent,
            activeSkills: activeSkills,
            personaID: request.personaID,
            sliceIndex: request.sliceIndex,
            maxTokens: maxTokens,
            messages: request.historyMessages,
            sharedContext: agentVM.sharedContext
        )
        
        var contextMsgs: [ContextMessage] = []
        var totalTokens = TokenEstimationEngine.estimateTextTokens(sanitizedQuery)
        
        for enricher in enrichers.sorted(by: { $0.priority < $1.priority }) {
            await enricher.enrich(payload: payload, messages: &contextMsgs, totalTokens: &totalTokens)
        }
        
        // 若为数字分身，将动态心智状态（时钟、情绪、羁绊、已知事实）作为末尾环境封包注入
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
        agentVM.sharedContext["AGENT_TOTAL_TOKENS"] = "\(accurateTotal)"
        return contextMsgs
    }
    
    private func estimateTokens(for text: String) -> Int {
        text.isEmpty ? 0 : Int(Double(text.count) * 1.5)
    }
    
    private func coerceArguments(args: [String: Any], skill: AgentSkill) -> [String: Any] {
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
    
    static func compactContext(
        messages: [ContextMessage],
        keepRecentTurns: Int,
        maxObservationLength: Int
    ) -> [ContextMessage] {
        // 最近 N 轮的交互（Assistant + Tool 对）保持高保真无损
        let protectedMessageCount = max(2, keepRecentTurns * 2)
        guard messages.count > protectedMessageCount else { return messages }
        
        var compacted: [ContextMessage] = []
        let cutoffIndex = messages.count - protectedMessageCount
        
        for (index, msg) in messages.enumerated() {
            var newMsg = msg
            if index < cutoffIndex {
                // 对超出阈值的远期 Tool 结果采用 6:4 头尾保真折叠，保留核心定义与返回 ID
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
    
    /// 执行变异写操作后的物理反查探针与数据对账
    private func executePostMutationVerification(
        contract: VerificationContract,
        currentAgent: AgentProfile,
        dynamicActiveSkills: [AgentSkill],
        continuation: AsyncThrowingStream<AgentStep, Error>.Continuation
    ) async -> (isVerified: Bool, artifact: AgentArtifact?, diagnostic: String?) {
        continuation.yield(.status("🔍 正在执行物理状态反查核验 [\(contract.expectedMutationKey)]..."))
        
        // 1. 查找匹配的探针工具
        guard let probeSkill = dynamicActiveSkills.first(where: { $0.name == contract.probeToolName }) else {
            return (false, nil, "未找到指定的验收探针工具 [\(contract.probeToolName)]")
        }
        
        // 2. 构造探针执行参数
        let probeArgs: [String: Any] = ["cmd": contract.probeCommandTemplate, "command": contract.probeCommandTemplate]
        let safeProbeArgs = coerceArguments(args: probeArgs, skill: probeSkill)
        
        // 3. 静默下发探针工具执行
        let rawProbeResult = await agentVM.executeTool(skill: probeSkill, args: safeProbeArgs, skipConfirmation: true)
        let (cleanProbeResult, _, _) = rawProbeResult.processBase64ImagePayload()
        
        // 4. 物理真值校验与特征断言 (Diff Assertion)
        let hasError = PhysicalTruthVerifier.hasPhysicalError(output: cleanProbeResult)
        if hasError {
            return (false, nil, "探针反查物理接口返回异常: \(cleanProbeResult.prefix(150))")
        }
        
        // 核验目标变异键是否已真实写入物理系统
        let isKeyPresent = cleanProbeResult.contains(contract.expectedMutationKey)
        
        if isKeyPresent {
            let diffDesc = "已核验物理实体 [ID: \(contract.targetResourceId)] 成功挂载 [\(contract.expectedMutationKey)]"
            let artifact = AgentArtifact(
                name: "物理核验证据_\(contract.expectedMutationKey)",
                type: .diff,
                content: "【反查探针】: \(contract.probeCommandTemplate)\n【生效断言】: 属性 [\(contract.expectedMutationKey)] 真实存在且结构有效\n【数据快照】:\n\(cleanProbeResult.prefix(800))"
            )
            return (true, artifact, diffDesc)
        } else {
            return (false, nil, "物理反查未发现预期属性 [\(contract.expectedMutationKey)]，系统数据尚未生效")
        }
    }
}

// MARK: - ==================== 0.1 精准 Token 计量与多模态估算引擎 ====================

struct TokenEstimationEngine {
    /// 精准多模态与结构化上下文 Token 估算
    static func estimateTokens(
        messages: [ContextMessage],
        systemInstruction: String = "",
        images: [NSImage] = [],
        activeSkills: [AgentSkill] = [],
        protocolType: String = "openai"
    ) -> Int {
        var total = 0
        
        // 1. 系统指令与元数据开销
        if !systemInstruction.isEmpty {
            total += estimateTextTokens(systemInstruction) + 12
        }
        
        // 2. 消息体 Token 统计 (中英/代码/结构加权)
        for msg in messages {
            total += 4 // 角色标记与边界开销
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
        
        // 3. 多模态视觉补偿 (按厂商真实计费标准)
        for _ in images {
            if protocolType.lowercased() == "gemini" {
                total += 258 // Gemini 官方固定图片 Token 消耗
            } else {
                total += 765 // OpenAI / 通用高清切片均值
            }
        }
        
        // 4. Tool Schema 声明结构体开销
        for skill in activeSkills {
            total += skill.name.count / 3 + skill.description.count / 3 + 24
            for param in skill.parameters {
                total += param.name.count / 3 + param.description.count / 3 + 16
            }
        }
        
        return total
    }
    
    /// 启发式分词计量：对 CJK 汉字、英文词组、代码标点符号分别加权
    static func estimateTextTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var cjkCount = 0
        var asciiPunctCount = 0
        var otherAsciiCount = 0
        
        for scalar in text.unicodeScalars {
            let v = scalar.value
            // CJK 统一表意文字、平假名、片假名、韩文字符
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
        
        // CJK: ~1.25 T/字; ASCII 词组: ~1 T / 3.6 字母; 代码/标点: ~0.6 T/符号
        let cjkTokens = Double(cjkCount) * 1.25
        let wordTokens = Double(otherAsciiCount) / 3.6
        let punctTokens = Double(asciiPunctCount) * 0.6
        
        return max(1, Int(ceil(cjkTokens + wordTokens + punctTokens)))
    }
}

// MARK: - ==================== 0.2 阶段动态微提示词生成器 ====================

// MARK: - 阶段动态微提示词生成器 (Stage-Aware Micro-Prompt Engine)
struct AgentStagePromptEngine {
    static func resolveStageMicroPrompt(
        isAutonomy: Bool,
        hasBlackboard: Bool,
        blackboardPlan: String?
    ) -> String? {
        guard isAutonomy && hasBlackboard else { return nil }
        
        let hasNoPlan = (blackboardPlan == nil || blackboardPlan!.isEmpty || blackboardPlan == "[]")
        
        // 阶段 1 & 2：未创建黑板 -> 引导快速定位实体、同步输出意图并创建规划
        if hasNoPlan {
            return "【当前阶段：探索与规划】下发工具时请在正文中同步 1 句意图说明。定位到目标实体后，请调用 task_planner(action: 'create', tasks: [...]) 创建具体任务节点。"
        }
        
        let nodes = TaskBlackboardManager.shared.parsePlan(blackboardPlan!)
        
        // 阶段 3：存在待推进活动节点 -> 引导单步对账
        if let activeNode = TaskBlackboardManager.shared.findNextActionableTask(in: nodes) {
            return "【当前阶段：单步推进与契约核验】请同步正文意图并推进实体节点【\(activeNode.title)】。执行后核对数据契约，通过 result_memo 沉淀核心参数并流转状态。"
        }
        
        // 阶段 4：全部实体节点已成功闭环 -> 引导总结结单
        if !TaskBlackboardManager.shared.hasUnfinishedTasks(planString: blackboardPlan!) {
            return "【当前阶段：终态交付】所有实体任务已成功闭环，请调用 finish_task 提交三段式标准化总结报告并结单。"
        }
        
        return nil
    }
}

// MARK: - ==================== 1. Agent 核心业务与状态管理器 (Facade 门面模式) ====================

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

// MARK: - ==================== 2. 后台物理推理引擎 (完全桥接 AgentManager) ====================

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

// MARK: - ==================== 3. 基础视图与布局扩展 ====================

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

// MARK: - ==================== 4. 独立窗口管理器与主容器 ====================

@MainActor
class AgentWindowManager: NSObject, NSWindowDelegate {
    static let shared = AgentWindowManager()
    private var window: NSWindow?
    var isVisible: Bool { return window != nil }
    private override init() { super.init() }
    
    func show() {
        if let window = window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
            return
        }
        
        let view = AgentManagerView(agentVM: AgentManager.shared.agentVM, knowledgeVM: AgentManager.shared.knowledgeVM)
        let newWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
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
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        MainWindowManager.syncDockIconPolicy()
    }
    
    func windowWillClose(_ notification: Notification) {
        window = nil
        MainWindowManager.syncDockIconPolicy()
    }
}

@MainActor
struct AgentManagerView: View {
    @State private var selectedTab: Int? = 0
    var agentVM: AgentViewModel
    var knowledgeVM: KnowledgeViewModel
    
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

// MARK: - ==================== 5. Agent 档案核心编排面板 ====================

@MainActor
struct AgentProfilesPanel: View {
    @Bindable var agentVM: AgentViewModel
    @Bindable var knowledgeVM: KnowledgeViewModel
    
    @State private var profiles: [AgentProfile] = ConfigManager.shared.app.agentProfiles
    @State private var selectedProfileID: UUID?
    @State private var isCreating: Bool = false
    @State private var defaultAgentID: UUID? = ConfigManager.shared.app.generalConfig.defaultAgentID
    
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
                    let newAgent = AgentProfile(name: "新建智能体", baseModel: fallbackModel, systemPrompt: "你是一个高效、严谨的智能助手。请使用中文提供简洁、结构化且可执行的解答，拒绝废话与臆测。")
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

// MARK: - ==================== 6. 拟人化 Stage 阶段卡片式编辑器 ====================

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
    @State private var showSaveToManagerPopover = false
    
    private let icons = ["sparkles", "brain.head.profile", "wrench.and.screwdriver", "terminal", "doc.text.magnifyingglass", "globe", "chart.bar.doc.horizontal", "theatermasks.fill", "cpu", "network", "lock.shield.fill", "paintpalette.fill"]
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                editorHeroHeader
                
                // 🔷 STAGE 1：核心身份与引擎底座
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
                
                // 🔶 STAGE 2：认知中枢与系统指令
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
                        
                        Text("💡 提示：系统会自动提取首行作为【路由说明】(对主控公开)，请在首行简述其核心能力。底层执行纪律请在第二行之后书写，以免污染主控。")
                            .font(.caption)
                            .foregroundColor(.blue)
                            .padding(.top, 2)
                        
                        ActionChipSyntaxGuideView()
                    }
                }
                
                // 🔴 STAGE 3：自主推理与安全策略 (意图驱动收敛设计)
                assemblyStageCard(
                    stageBadge: "STAGE 3",
                    stageTitle: "自主推理与安全策略",
                    stageSubtitle: "设定自主推演意图模式、步数预算与底层防御体系",
                    themeColor: .red
                ) {
                    VStack(alignment: .leading, spacing: 14) {
                        // 1. 主控推演开关
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
                            
                            // 2. 核心调度意图分段器
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
                                    // 自动闭环模式下强制激活熔断器
                                    if newMode == .fullyAuto {
                                        profile.enableCircuitBreaker = true
                                    }
                                }
                                
                                Text(profile.executionMode == .interactive ? "💬 步数耗尽或遇到死循环时，主动弹出原生悬浮窗等待人工指示。" : "⚡️ 步数耗尽后自动续跑，全程不打扰；强制锁定防死循环熔断以保护 Token。")
                                    .font(.system(size: 10.5))
                                    .foregroundColor(profile.executionMode == .fullyAuto ? .orange : .blue)
                                    .padding(.top, 2)
                            }
                            
                            // 3. 单轮步数预算调节
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
                            
                            // 4. 高级防御与上下文折叠 (渐进式抽屉)
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 12) {
                                    // 熔断保护设置
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
                                    
                                    // 自动闭环续跑硬顶
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
                                    
                                    // 上下文滑动压缩设置
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
                
                // 🟢 STAGE 4：知识图谱与私域记忆
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
                
                // 🟣 STAGE 5：武器库挂载与团队协作矩阵
                assemblyStageCard(
                    stageBadge: "STAGE 5",
                    stageTitle: "武器库挂载与团队协作矩阵",
                    stageSubtitle: "配备主动技能 (Tools)、指派专家智能体并绑定可对戏的数字分身",
                    themeColor: .purple
                ) {
                    VStack(alignment: .leading, spacing: 14) {
                        
                        // 1. 物理技能链
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
                        
                        // 2. 专家智能体协作
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
                        
                        // 3. 数字分身角色扮演矩阵
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

// MARK: - ==================== 7. 全局 AI 模型引擎管理中心 ====================

@MainActor
struct AiModelConfigPanel: View {
    @State private var aiConfigs: [AiConfig] = ConfigManager.shared.app.aiConfigs
    @State private var expandedStates: [UUID: Bool] = [:]
    
    private let protocols = ["openai", "gemini", "chatgpt", "anthropic", "ollama"]
    
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

// MARK: - ==================== 8. 高级语法指引视图 ====================

@MainActor
struct ActionChipSyntaxGuideView: View {
    @State private var isCopied: Bool = false
    @State private var isExpanded: Bool = false
    
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
