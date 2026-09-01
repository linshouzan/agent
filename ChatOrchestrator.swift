//////////////////////////////////////////////////////////////////
// 文件名：ChatOrchestrator.swift
// 文件说明：适用于 macOS 14+ 的 Agent 全局业务编排与 UI 交互中枢 (Swift 6 Ready)
//
// 核心解构架构拓扑 (Domain-Driven Architecture):
// ├── 1. OrchestratorModels       : Agent 推演步骤事件 (AgentStep) 与上下文载荷容器
// ├── 2. OrchestratorProtocols    : 上下文装配器 (ChatContextEnricher) 与后置钩子协议
// ├── 3. OrchestratorPlugins      : 核心私域记忆唤醒与滑动历史窗口上下文插件
// ├── 4. OrchestratorNormalizer   : 流式净化网关 (统一提取 <think>，过滤噪声标签)
// ├── 5. OrchestratorHooks        : 分身心智增量沉淀与会话状态落盘后置钩子
// └── 6. ChatOrchestrator         : 响应式主交互 Presenter (驱动 AiChatStore，对接 AgentManager)
//////////////////////////////////////////////////////////////////

import SwiftUI
import Foundation
import AppKit

// MARK: - ==================== 1. OrchestratorModels & Protocols (通信协议与实体) ====================

enum AgentStep: Equatable, Sendable {
    case status(String)
    case ragResult(logString: String)
    case textDelta(String)
    case reasoningDelta(String)
    case reasoningDone
    case toolCallConfirmation(id: String, name: String, args: [String: Any])
    case toolCallInfo(id: String, name: String, args: [String: Any], thoughtSignature: String?)
    case toolCallResult(name: String, result: String)
    case pausedForHuman(id: String, reason: String, suggestedActions: [String])
    case usageUpdate(Int)
    case error(String)
    case done
    
    static func == (lhs: AgentStep, rhs: AgentStep) -> Bool {
        switch (lhs, rhs) {
        case (.status(let a), .status(let b)): return a == b
        case (.textDelta(let a), .textDelta(let b)): return a == b
        case (.reasoningDelta(let a), .reasoningDelta(let b)): return a == b
        case (.reasoningDone, .reasoningDone): return true
        case (.done, .done): return true
        case (.error(let a), .error(let b)): return a == b
        case (.toolCallConfirmation(let i1, let n1, _), .toolCallConfirmation(let i2, let n2, _)): return i1 == i2 && n1 == n2
        case (.toolCallInfo(let i1, let n1, _, _), .toolCallInfo(let i2, let n2, _, _)): return i1 == i2 && n1 == n2
        case (.toolCallResult(let n1, let r1), .toolCallResult(let n2, let r2)): return n1 == n2 && r1 == r2
        case (.pausedForHuman(let i1, let r1, _), .pausedForHuman(let i2, let r2, _)): return i1 == i2 && r1 == r2
        case (.ragResult(let l1), .ragResult(let l2)): return l1 == l2
        case (.usageUpdate(let u1), .usageUpdate(let u2)): return u1 == u2
        default: return false
        }
    }
}

/// 上下文装配载荷容器
struct ContextEnrichmentPayload: Sendable {
    let query: String
    let currentAgent: AgentProfile
    let activeSkills: [AgentSkill]
    let personaID: UUID?
    let sliceIndex: Int
    let maxTokens: Int
    var messages: [ChatMessage]
    var sharedContext: [String: String]
}

/// 上下文装配插件协议 (Context Enricher Plugin)
@MainActor
protocol ChatContextEnricher: Sendable {
    var priority: Int { get }
    func enrich(payload: ContextEnrichmentPayload, messages: inout [ContextMessage], totalTokens: inout Int) async
}

/// 对话执行后置钩子协议 (Post Execution Hook)
@MainActor
protocol PostExecutionHook: Sendable {
    func onCompleted(fullText: String, targetMessageID: UUID, personaID: UUID?) async
}

/// 工具调用徽标轻量载荷
public struct ToolBadgeItem: Sendable, Equatable {
    public let callId: String
    public let name: String
    public let displayName: String
    public var status: String // "waiting" | "running" | "success" | "failed"
    
    public init(callId: String, name: String, displayName: String, status: String = "running") {
        self.callId = callId
        self.name = name
        self.displayName = displayName
        self.status = status
    }
}

// MARK: - ==================== 2. OrchestratorPlugins (上下文装配插件集群) ====================

@MainActor
struct StickyPrivateQAEnricher: ChatContextEnricher {
    let priority: Int = 20
    init() {}
    
    func enrich(payload: ContextEnrichmentPayload, messages: inout [ContextMessage], totalTokens: inout Int) async {
        let historicalUserQueries = payload.messages
            .filter { $0.isUser }
            .map { ChatOrchestrator.sanitizeUserMessage($0.text) }
            .joined(separator: "\n")
            .lowercased()
        
        let fullScan = historicalUserQueries + "\n" + payload.query.lowercased()
        let store = AiChatStore.shared
        
        for qa in payload.currentAgent.privateQA where qa.isEnabled {
            if fullScan.contains(qa.keyword.lowercased()) {
                if !store.activatedPrivateQAIDs.contains(qa.id) {
                    store.activatedPrivateQAIDs.insert(qa.id)
                    LogManager.shared.success("🧠 私域长效记忆唤醒", detail: "知识点 [\(qa.keyword)] 已自动固化。")
                }
            }
        }
        
        let activatedQAs = payload.currentAgent.privateQA.filter { store.activatedPrivateQAIDs.contains($0.id) }
        if !activatedQAs.isEmpty {
            var stickyContext = "\n【核心私域记忆注入】:\n"
            for qa in activatedQAs {
                stickyContext += "● [\(qa.keyword)]: \(qa.content)\n"
            }
            messages.append(.system(stickyContext))
            totalTokens += Int(Double(stickyContext.count) * 1.5)
        }
    }
}

@MainActor
struct HistorySlidingWindowEnricher: ChatContextEnricher {
    let priority: Int = 100
    init() {}
    
    func enrich(payload: ContextEnrichmentPayload, messages: inout [ContextMessage], totalTokens: inout Int) async {
        guard AiChatStore.shared.isContextEnabled else { return }
        
        let safeSliceIndex = min(payload.sliceIndex, payload.messages.count)
        let historyToConsider = payload.messages.prefix(upTo: safeSliceIndex).reversed()
        var validHistoryMsgs: [ContextMessage] = []
        
        for msg in historyToConsider {
            var tempMsgs: [ContextMessage] = []
            var msgTokenCost = 0
            
            if msg.isUser {
                let cleanText = ChatOrchestrator.sanitizeUserMessage(msg.text)
                tempMsgs.append(.user(cleanText))
                msgTokenCost += Int(Double(cleanText.count) * 1.5)
            } else {
                let cleanText = msg.text.filterStopTokens().filterTHINK().filterMARKDOWN().trimmingCharacters(in: .whitespacesAndNewlines)
                if !msg.skillLogs.isEmpty {
                    for (index, log) in msg.skillLogs.enumerated() {
                        let stableCallId = log.confirmationId ?? "call_\(log.id.uuidString.prefix(8))"
                        let argString = (try? JSONSerialization.data(withJSONObject: log.args)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        let toolCall = LLMToolCall(id: stableCallId, name: log.skillName, arguments: argString)
                        
                        let hintText = index == 0 ? (cleanText.isEmpty ? "" : "正在执行任务...") : ""
                        tempMsgs.append(.assistant(text: hintText, toolCalls: [toolCall]))
                        
                        let rawToolResult = log.resultOutput
                        tempMsgs.append(.tool(id: stableCallId, name: log.skillName, result: rawToolResult))
                        
                        msgTokenCost += TokenEstimationEngine.estimateTextTokens(argString) + TokenEstimationEngine.estimateTextTokens(rawToolResult) + 16
                        
                        if index == msg.skillLogs.count - 1 {
                            let textToAppend = cleanText.isEmpty ? "以上是执行结果。" : cleanText
                            tempMsgs.append(.assistant(text: textToAppend))
                            msgTokenCost += TokenEstimationEngine.estimateTextTokens(textToAppend) + 4
                        }
                    }
                } else if !cleanText.isEmpty {
                    tempMsgs.append(.assistant(text: cleanText))
                    msgTokenCost += Int(Double(cleanText.count) * 1.5)
                }
            }
            
            if totalTokens + msgTokenCost > payload.maxTokens {
                break
            }
            totalTokens += msgTokenCost
            validHistoryMsgs.insert(contentsOf: tempMsgs, at: 0)
        }
        
        messages.append(contentsOf: validHistoryMsgs)
    }
}

// MARK: - ==================== 3. OrchestratorNormalizer (流式净化过滤网关) ====================

struct UnifiedStreamNormalizer: Sendable {
    static func formatFullText(
        reasoning: String,
        text: String,
        isReasoningActive: Bool,
        activeRoundToolBadges: [ToolBadgeItem] = []
    ) -> String {
        var result = ""
        if !reasoning.isEmpty {
            let cleanReasoning = reasoning
                .replacingOccurrences(of: "<think>", with: "")
                .replacingOccurrences(of: "</think>", with: "")
            result += "<think>\n" + cleanReasoning
            if !isReasoningActive {
                result += "\n</think>\n\n"
            }
        }
        
        var cleanStreamText = text
        
        // 1. 过滤数字分身心智增量标签
        if let deltaRange = cleanStreamText.range(of: "<persona_delta") {
            cleanStreamText = String(cleanStreamText[..<deltaRange.lowerBound])
        }
        
        // 2. 过滤内部状态备忘标签
        if cleanStreamText.contains("<result_memo>") {
            cleanStreamText = cleanStreamText.replacingOccurrences(
                of: #"(?s)<result_memo>.*?(</result_memo>|$)"#,
                with: "",
                options: .regularExpression
            )
        }
        
        // 3. 过滤模型拟态伪造的 <finish_task> 标签
        if cleanStreamText.contains("<finish_task>") {
            let pattern = #"(?s)<finish_task>(.*?)(?:</finish_task>|$)"#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: cleanStreamText, range: NSRange(cleanStreamText.startIndex..., in: cleanStreamText)),
               let rawRange = Range(match.range(at: 1), in: cleanStreamText) {
                let inner = String(cleanStreamText[rawRange])
                var extractedAnswer = inner
                if let ansRange = inner.range(of: "final_answer:") {
                    extractedAnswer = String(inner[ansRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                cleanStreamText = regex.stringByReplacingMatches(
                    in: cleanStreamText,
                    range: NSRange(cleanStreamText.startIndex..., in: cleanStreamText),
                    withTemplate: extractedAnswer
                )
            }
        }
        
        // 4. 过滤模型散落的自述过渡噪音
        if cleanStreamText.contains("【已执行动作总结】") || cleanStreamText.contains("【待总结】") || cleanStreamText.contains("我将调用") {
            cleanStreamText = cleanStreamText.replacingOccurrences(
                of: #"(?s)【已执行动作总结】[：:]?.*?(?=【|$|\n\n)"#,
                with: "",
                options: .regularExpression
            )
            cleanStreamText = cleanStreamText.replacingOccurrences(
                of: #"(?s)【待总结】[：:]?.*?(?=\n\n|$)"#,
                with: "",
                options: .regularExpression
            )
            cleanStreamText = cleanStreamText.replacingOccurrences(
                of: #"(?m)^我将调用\s+\S+\s+(结束|推进|执行).*?$"#,
                with: "",
                options: .regularExpression
            )
        }
        
        // 5. 过滤伪任务清单与裸露推演段落
        if cleanStreamText.contains("思考推演") || cleanStreamText.contains("【任务清单】") {
            cleanStreamText = cleanStreamText.replacingOccurrences(
                of: #"(?s)思考推演[：:]?\s*(?:\d+\.\s*[^：\n]+[：:][^\n]*\n*)+"#,
                with: "",
                options: .regularExpression
            )
            cleanStreamText = cleanStreamText.replacingOccurrences(
                of: #"(?s)【任务清单】[：:]?(\s*[\d\-•]+\.\s*\[[^\]]+\][^\n]*)+"#,
                with: "",
                options: .regularExpression
            )
        }
        
        var trimmedText = cleanStreamText.trimmingCharacters(in: .whitespacesAndNewlines)
                
        // 生成标准化的通用 Action 徽标链接
        if !activeRoundToolBadges.isEmpty && !trimmedText.isEmpty {
            let badges = activeRoundToolBadges.map { item -> String in
                let statusIcon: String
                switch item.status {
                case "success": statusIcon = "✓"
                case "failed": statusIcon = "✕"
                case "waiting": statusIcon = "⏸"
                default: statusIcon = "⚡︎"
                }
                let encodedName = item.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? item.name
                let encodedCallId = item.callId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? item.callId
                return " [\(statusIcon) \(item.displayName)](action://inspect_tool/\(encodedName)?call_id=\(encodedCallId)&status=\(item.status))"
            }.joined(separator: "")
            
            if !trimmedText.hasSuffix(badges) {
                trimmedText += "\(badges)"
            }
        }
        
        result += trimmedText
        return result
    }
}

// MARK: - ==================== 4. OrchestratorHooks (后置状态固化钩子) ====================

@MainActor
struct PersonaMentalDeltaHook: PostExecutionHook {
    init() {}
    func onCompleted(fullText: String, targetMessageID: UUID, personaID: UUID?) async {
        guard let pID = personaID,
              let deltaJSON = fullText.extractPersonaDelta() else { return }
        PersonaManager.shared.applyMentalDelta(for: pID, deltaJSON: deltaJSON)
    }
}

@MainActor
struct SessionPersistenceHook: PostExecutionHook {
    init() {}
    func onCompleted(fullText: String, targetMessageID: UUID, personaID: UUID?) async {
        AiChatStore.shared.saveCurrentState()
    }
}

// MARK: - ==================== 5. ChatOrchestrator (Presenter 交互编排中心) ====================

@MainActor
@Observable
final class ChatOrchestrator {
    var store: AiChatStore = .shared
    var agentVM: AgentViewModel
    var knowledgeVM: KnowledgeViewModel
    var currentTask: Task<Void, Never>?
    
    var postHooks: [PostExecutionHook] = [
        PersonaMentalDeltaHook(),
        SessionPersistenceHook()
    ]
    
    init(agentVM: AgentViewModel, knowledgeVM: KnowledgeViewModel) {
        self.agentVM = agentVM
        self.knowledgeVM = knowledgeVM
    }
    
    func registerPostHook(_ hook: PostExecutionHook) {
        postHooks.append(hook)
    }
    
    static func sanitizeUserMessage(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("@") else { return text }
        
        let allProfiles = ConfigManager.shared.app.agentProfiles
        let sortedProfiles = allProfiles.sorted { $0.name.count > $1.name.count }
        
        for profile in sortedProfiles {
            let mentionTag = "@\(profile.name)"
            if trimmed.hasPrefix(mentionTag) {
                let instructionIndex = trimmed.index(trimmed.startIndex, offsetBy: mentionTag.count)
                let rawInstruction = String(trimmed[instructionIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return rawInstruction.isEmpty ? "请根据你的专业人设，接管并继续当前会话。" : rawInstruction
            }
        }
        return text
    }
    
    private func parseAgentMention(from query: String) -> (targetAgent: AgentProfile?, cleanInstruction: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("@") else { return (nil, query) }
        
        let allProfiles = ConfigManager.shared.app.agentProfiles
        let sortedProfiles = allProfiles.sorted { $0.name.count > $1.name.count }
        
        for profile in sortedProfiles {
            let mentionTag = "@\(profile.name)"
            if trimmed.hasPrefix(mentionTag) {
                let cleanInstruction = Self.sanitizeUserMessage(query)
                return (profile, cleanInstruction)
            }
        }
        return (nil, query)
    }
    
    func send(text: String, images: [NSImage], files: [URL]) async {
        let trimmedText = text.trimmingCharacters(in: .whitespaces)
        guard !trimmedText.isEmpty || !images.isEmpty || !files.isEmpty else { return }
        
        let (mentionedAgent, cleanQuery) = parseAgentMention(from: trimmedText)
        let targetAgent = mentionedAgent ?? store.currentAgent
        
        let compressedImages = await Task.detached(priority: .userInitiated) {
            images.map { $0.resizedAndCompressedForAI(maxDimension: 1024, compressionQuality: 0.7) }
        }.value
        
        let userMsg = ChatMessage(isUser: true, text: trimmedText, images: compressedImages, fileURLs: files)
        let aiMsg = ChatMessage(isUser: false, text: "")
        let targetId = aiMsg.id
        let historySnapshot = store.messages
        let historyCount = historySnapshot.count
        
        withAnimation(.easeOut(duration: 0.2)) {
            store.messages.append(contentsOf: [userMsg, aiMsg])
            store.isLoading = true
            store.selectedImages.removeAll()
            store.selectedFiles.removeAll()
        }
        
        let sessionLogID = LogManager.shared.startSession(
            query: cleanQuery,
            agentName: targetAgent.name
        )
        
        let request = AgentExecutionRequest(
            prompt: cleanQuery,
            agentID: targetAgent.id,
            personaID: store.selectedPersonaID,
            images: compressedImages,
            fileURLs: files,
            historyMessages: historySnapshot,
            sliceIndex: historyCount,
            sharedContext: agentVM.sharedContext,
            callerTag: "ChatUI",
            autoApproveConfirmation: false,
            sessionLogID: sessionLogID
        )
        
        currentTask = Task {
            store.currentGenerationTask = self.currentTask
            
            var isSessionSuccess = false
            var sessionErrorMsg: String? = nil
            var finalDeliveredFullText = ""
            
            defer {
                self.store.isLoading = false
                if let plan = self.agentVM.sharedContext["AGENT_BLACKBOARD_PLAN"] {
                    self.store.blackboardPlan = plan
                }
                self.store.updateMessage(id: targetId) { msg in
                    let clean = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if clean.isEmpty && msg.skillLogs.isEmpty && msg.ragHits.isEmpty {
                        msg.text = "> ⚠️ **无响应**: 模型未返回任何有效内容。"
                    }
                }
                self.store.saveCurrentState()
                
                LogManager.shared.endSession(
                    sessionID: sessionLogID,
                    isSuccess: isSessionSuccess,
                    detail: isSessionSuccess ? (finalDeliveredFullText.isEmpty ? "（已交付回复）" : finalDeliveredFullText) : sessionErrorMsg
                )
            }
            
            var accumulatedReasoning = ""
            var accumulatedText = ""
            var currentRoundPendingText = ""
            var currentRoundToolBadges: [ToolBadgeItem] = []
            var isReasoningActive = false
            var lastUIUpdateTime = Date()
            
            do {
                let stream = AgentManager.shared.executeStream(request: request)
                
                for try await step in stream {
                    if Task.isCancelled { break }
                    
                    switch step {
                    case .status:
                        break
                        
                    case .ragResult(let logString):
                        let hits = AgentStreamParser.parse(logString).ragHits
                        if !hits.isEmpty {
                            store.updateMessage(id: targetId) { msg in
                                msg.ragHits = hits
                            }
                        }
                        
                    case .reasoningDelta(let r):
                        isReasoningActive = true
                        accumulatedReasoning += r
                        
                    case .reasoningDone:
                        isReasoningActive = false
                        
                    case .textDelta(let t):
                        isReasoningActive = false
                        currentRoundPendingText += t
                        
                    case .toolCallConfirmation(let id, let name, let args):
                        let targetSkill = self.agentVM.skills.first(where: { $0.name == name })
                        let displayName = targetSkill?.displayName ?? name
                        if let idx = currentRoundToolBadges.firstIndex(where: { $0.callId == id }) {
                            currentRoundToolBadges[idx].status = "waiting"
                        } else {
                            currentRoundToolBadges.append(ToolBadgeItem(callId: id, name: name, displayName: displayName, status: "waiting"))
                        }
                        updateToolLog(messageID: targetId, name: name, args: args, output: "等待授权...", callID: id)
                        syncBlackboardToStore()
                        
                    case .toolCallInfo(let id, let name, let args, _):
                        let targetSkill = self.agentVM.skills.first(where: { $0.name == name })
                        let displayName = targetSkill?.displayName ?? name
                        if let idx = currentRoundToolBadges.firstIndex(where: { $0.callId == id }) {
                            currentRoundToolBadges[idx].status = "running"
                        } else {
                            currentRoundToolBadges.append(ToolBadgeItem(callId: id, name: name, displayName: displayName, status: "running"))
                        }
                        updateToolLog(messageID: targetId, name: name, args: args, output: "执行中...", callID: id)
                        syncBlackboardToStore()
                        
                    case .toolCallResult(let name, let result):
                        let isFailed = PhysicalTruthVerifier.isExecutionFailed(toolName: name, output: result)
                        let finalStatus = isFailed ? "failed" : "success"
                        
                        if let idx = currentRoundToolBadges.firstIndex(where: { $0.name == name && ($0.status == "running" || $0.status == "waiting") }) {
                            currentRoundToolBadges[idx].status = finalStatus
                        } else if let idx = currentRoundToolBadges.lastIndex(where: { $0.name == name }) {
                            currentRoundToolBadges[idx].status = finalStatus
                        } else {
                            let targetSkill = self.agentVM.skills.first(where: { $0.name == name })
                            let displayName = targetSkill?.displayName ?? name
                            currentRoundToolBadges.append(ToolBadgeItem(callId: UUID().uuidString, name: name, displayName: displayName, status: finalStatus))
                        }
                        
                        if !currentRoundPendingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !currentRoundToolBadges.isEmpty {
                            let roundFormatted = UnifiedStreamNormalizer.formatFullText(
                                reasoning: "",
                                text: currentRoundPendingText,
                                isReasoningActive: false,
                                activeRoundToolBadges: currentRoundToolBadges
                            )
                            if !roundFormatted.isEmpty {
                                accumulatedText += (accumulatedText.isEmpty ? "" : "\n\n") + roundFormatted
                            }
                            currentRoundPendingText = ""
                            currentRoundToolBadges.removeAll()
                        }
                        
                        updateToolLogResult(messageID: targetId, name: name, output: result)
                        syncBlackboardToStore()
                        
                    case .pausedForHuman:
                        isReasoningActive = false
                        syncBlackboardToStore()
                        
                    case .usageUpdate(let count):
                        self.store.currentContextTokenCount = count
                        self.agentVM.sharedContext["AGENT_TOTAL_TOKENS"] = "\(count)"
                        
                    case .error(let errorMsg):
                        sessionErrorMsg = errorMsg
                        currentRoundPendingText += "\n\n> ❌ **异常**: \(errorMsg)"
                        
                    case .done:
                        isReasoningActive = false
                        syncBlackboardToStore()
                    }
                    
                    // 实时组合历史固化轮次文本与当前活跃轮次文本
                    var streamingCombinedText = accumulatedText
                    if !currentRoundPendingText.isEmpty || !currentRoundToolBadges.isEmpty {
                        let activeRoundFormatted = UnifiedStreamNormalizer.formatFullText(
                            reasoning: "",
                            text: currentRoundPendingText,
                            isReasoningActive: false,
                            activeRoundToolBadges: currentRoundToolBadges
                        )
                        if !activeRoundFormatted.isEmpty {
                            streamingCombinedText += (streamingCombinedText.isEmpty ? "" : "\n\n") + activeRoundFormatted
                        }
                    }
                    
                    let currentFullText = UnifiedStreamNormalizer.formatFullText(
                        reasoning: accumulatedReasoning,
                        text: streamingCombinedText,
                        isReasoningActive: isReasoningActive,
                        activeRoundToolBadges: []
                    )
                    
                    let now = Date()
                    if now.timeIntervalSince(lastUIUpdateTime) > 0.04 {
                        lastUIUpdateTime = now
                        store.updateMessage(id: targetId) { $0.text = currentFullText }
                        syncBlackboardToStore()
                    }
                }
                
                // 将剩余的最后一轮内容闭环并入
                if !currentRoundPendingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !currentRoundToolBadges.isEmpty {
                    let finalRoundFormatted = UnifiedStreamNormalizer.formatFullText(
                        reasoning: "",
                        text: currentRoundPendingText,
                        isReasoningActive: false,
                        activeRoundToolBadges: currentRoundToolBadges
                    )
                    if !finalRoundFormatted.isEmpty {
                        accumulatedText += (accumulatedText.isEmpty ? "" : "\n\n") + finalRoundFormatted
                    }
                }
                
                if let targetMsg = store.messages.first(where: { $0.id == targetId }),
                   let finishLog = targetMsg.skillLogs.last(where: { $0.skillName == "finish_task" }),
                   let fallbackAns = finishLog.args["final_answer"] as? String,
                   !fallbackAns.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    accumulatedText = fallbackAns
                }

                let finalFullText = UnifiedStreamNormalizer.formatFullText(
                    reasoning: accumulatedReasoning,
                    text: accumulatedText,
                    isReasoningActive: false,
                    activeRoundToolBadges: []
                )
                let sanitizedDisplay = finalFullText.filterPersonaDelta()
                store.updateMessage(id: targetId) { $0.text = sanitizedDisplay }
                finalDeliveredFullText = sanitizedDisplay

                if !Task.isCancelled {
                    isSessionSuccess = true
                }
                
                for hook in postHooks {
                    await hook.onCompleted(fullText: finalFullText, targetMessageID: targetId, personaID: store.selectedPersonaID)
                }
                
            } catch {
                if !(error is CancellationError) {
                    sessionErrorMsg = error.localizedDescription
                    isSessionSuccess = false
                    store.updateMessage(id: targetId) { $0.text += "\n\n> ❌ **执行中断**: \(error.localizedDescription)" }
                }
            }
        }
    }
    
    private func syncBlackboardToStore() {
        let latestPlan = AgentManager.shared.agentVM.sharedContext["AGENT_BLACKBOARD_PLAN"]
        if store.blackboardPlan != latestPlan {
            store.blackboardPlan = latestPlan
        }
    }
    
    func cancelCurrentTask() {
        currentTask?.cancel()
        store.currentGenerationTask?.cancel()
        store.isLoading = false
    }
    
    private func updateToolLog(messageID: UUID, name: String, args: [String: Any], output: String, callID: String) {
        let targetSkill = agentVM.skills.first(where: { $0.name == name })
        let displayName = targetSkill?.displayName ?? name
        let uiTemplate = targetSkill?.uiTemplate ?? ""
        
        store.updateMessage(id: messageID) { msg in
            if let idx = msg.skillLogs.firstIndex(where: { $0.confirmationId == callID || ($0.skillName == name && $0.resultOutput == "等待授权...") }) {
                msg.skillLogs[idx].resultOutput = output
                msg.skillLogs[idx].args = args
                msg.skillLogs[idx].confirmationId = callID
            } else {
                msg.skillLogs.append(SkillExecutionLog(
                    skillName: name,
                    displayName: displayName,
                    args: args,
                    resultOutput: output,
                    confirmationId: callID,
                    uiTemplate: uiTemplate
                ))
            }
        }
    }
    
    private func updateToolLogResult(messageID: UUID, name: String, output: String) {
        store.updateMessage(id: messageID) { msg in
            if let idx = msg.skillLogs.lastIndex(where: { $0.skillName == name && ($0.resultOutput == "执行中..." || $0.resultOutput == "等待授权...") }) {
                msg.skillLogs[idx].resultOutput = output
            }
        }
    }
}
