//////////////////////////////////////////////////////////////////
// 文件名：TaskBlackboardManager.swift
// 文件说明：适用于 macOS 14+ 的 Agent 强类型状态图引擎与工件工作台 (V5 终极版 - Swift 6 Ready)
// 核心架构：
// 1. 
//////////////////////////////////////////////////////////////////

import SwiftUI
import AppKit
import Combine

// MARK: - ==================== 1. 强类型状态机数据模型 ====================

/// 图节点类型 (Node Schema)
public enum GraphNodeType: String, Codable, CaseIterable, Sendable {
    case tool = "tool"               // 物理工具操作 (键鼠/Shell/API)
    case reasoning = "reasoning"     // 纯文本分析、推理或回答
    case subAgent = "subagent"       // 专家子智能体委派
    case humanApproval = "human"     // 人工确认/授权节点
}

/// 图节点状态
public enum GraphNodeStatus: String, Codable, CaseIterable, Sendable {
    case pending = "等待中"
    case running = "执行中"
    case success = "已完成"
    case failed = "失败"
    case blocked = "需介入"
    
    public init(fromFlexibleString statusStr: String) {
        self = BlackboardGrammar.parseStatus(from: statusStr)
    }
    
    public var sfSymbol: String {
        switch self {
        case .pending: return "circle.dashed"
        case .running: return "arrow.triangle.2.circlepath.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .blocked: return "hand.raised.fill"
        }
    }
    
    public var color: Color {
        switch self {
        case .pending: return .secondary.opacity(0.5)
        case .running: return Color(hex: "#007786")
        case .success: return Color(hex: "#00E676")
        case .failed: return Color(hex: "#FF5252")
        case .blocked: return Color(hex: "#FFAB00")
        }
    }
}

/// 产出工件实体 (Artifact Canvas Model)
public struct AgentArtifact: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var type: ArtifactType
    public var content: String
    public var fileURL: URL?
    public var fileURLString: String?
    
    public enum ArtifactType: String, Codable, Sendable {
        case text = "text"
        case code = "code"   // 🌟 补齐代码片段工件类型
        case file = "file"
        case image = "image"
        case url = "url"
        case diff = "diff"   // 物理核验差分工件
    }
    
    public init(
        id: String = UUID().uuidString,
        name: String,
        type: ArtifactType = .text,
        content: String = "",
        fileURL: URL? = nil,
        fileURLString: String? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.content = content
        self.fileURL = fileURL ?? fileURLString.flatMap(URL.init(string:))
        self.fileURLString = fileURLString ?? fileURL?.absoluteString
    }
}

/// V5 强类型状态图节点模型 (全量 Codable / Sendable / 旧字段无损兼容版)
public struct AgentGraphNode: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var nodeType: GraphNodeType
    public var status: GraphNodeStatus
    public var memo: String?
    public var artifacts: [AgentArtifact]?
    public var currentRetry: Int = 0
    public var maxRetries: Int = 3  // 🌟 补齐最大重试预算上限
    public var subNodes: [AgentGraphNode]?
    
    public var validationState: MilestoneValidationState? = nil
    public var contract: VerificationContract? = nil
    
    public init(
        id: String,
        title: String,
        nodeType: GraphNodeType = .tool,
        status: GraphNodeStatus = .pending,
        memo: String? = nil,
        artifacts: [AgentArtifact]? = nil,
        currentRetry: Int = 0,
        maxRetries: Int = 3,
        subNodes: [AgentGraphNode]? = nil,
        validationState: MilestoneValidationState? = nil,
        contract: VerificationContract? = nil
    ) {
        self.id = id
        self.title = title
        self.nodeType = nodeType
        self.status = status
        self.memo = memo
        self.artifacts = artifacts
        self.currentRetry = currentRetry
        self.maxRetries = maxRetries
        self.subNodes = subNodes
        self.validationState = validationState
        self.contract = contract
    }
}

// MARK: - ==================== 2. 核心业务逻辑与流转引擎 ====================

public final class TaskBlackboardManager: Sendable {
    public static let shared = TaskBlackboardManager()
    private init() {}
    
    /// 🧠 启发式探针 (Swift 6 安全：标记 nonisolated 以便从 Decodable 任意线程中同步调用)
    nonisolated public static func inferNodeType(from text: String) -> GraphNodeType {
        BlackboardGrammar.inferNodeType(from: text)
    }
    
    nonisolated public func parsePlan(_ jsonString: String?) -> [AgentGraphNode] {
        guard var str = jsonString?.trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty else {
            return []
        }
        
        // 过滤大模型可能包裹的 ```json ... ``` 标记
        if str.hasPrefix("```") {
            let lines = str.components(separatedBy: .newlines)
            let filtered = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            str = filtered.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        guard str.hasPrefix("["), let data = str.data(using: .utf8) else {
            return []
        }
        
        do {
            return try JSONDecoder().decode([AgentGraphNode].self, from: data)
        } catch {
            return []
        }
    }
    
    nonisolated public func encodePlan(_ tasks: [AgentGraphNode]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(tasks) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
    nonisolated public func findNextActionableTask(in tasks: [AgentGraphNode]) -> AgentGraphNode? {
        for task in tasks {
            if task.status == .pending || task.status == .running {
                if let sub = task.subNodes, !sub.isEmpty {
                    if let actionableSub = findNextActionableTask(in: sub) { return actionableSub }
                } else {
                    return task
                }
            }
        }
        return nil
    }
    
    nonisolated public func hasUnfinishedTasks(planString: String?) -> Bool {
        let tasks = parsePlan(planString)
        return findNextActionableTask(in: tasks) != nil
    }
    
    nonisolated public func extractAllArtifacts(from planString: String?) -> [AgentArtifact] {
        let nodes = parsePlan(planString)
        var list: [AgentArtifact] = []
        func traverse(_ itemList: [AgentGraphNode]) {
            for item in itemList {
                if let arts = item.artifacts { list.append(contentsOf: arts) }
                if let subs = item.subNodes { traverse(subs) }
            }
        }
        traverse(nodes)
        return list
    }
    
    nonisolated public func generateExecutionPrompt(planString: String?) -> String {
        let tasks = parsePlan(planString)
        guard !tasks.isEmpty else { return "" }
        
        // 仅在存在活动节点（pending/running）时生成运行时状态快照；若全部完结则返回空字符串，避免阻断后续工具调用
        guard let nextNode = findNextActionableTask(in: tasks) else {
            return ""
        }
        
        var prompt = "\n=========================\n"
        
        let activeArtifacts = extractAllArtifacts(from: planString)
        if !activeArtifacts.isEmpty {
            prompt += "📦 【已产出工件 (Artifact Canvas)】:\n"
            for art in activeArtifacts.suffix(5) {
                prompt += "- [\(art.type.rawValue.uppercased())] \(art.name): \(art.content.prefix(80))...\n"
            }
            prompt += "\n"
        }
        
        prompt += "🎯 【当前聚焦节点】: [\(nextNode.title)] (target_task_id: \"\(nextNode.id)\")\n"
        prompt += "🏷️ 节点类型: [\(nextNode.nodeType.rawValue.uppercased())]\n"
        
        if nextNode.nodeType == .reasoning {
            prompt += "💡 【执行指引】: 该节点为分析/总结交付节点，请输出自然语言解答，系统将自动推进下一步骤。\n"
        } else if nextNode.nodeType == .tool {
            prompt += "💡 【执行指引】: 该节点为物理操作节点，请通过 Tool Call 发送结构化参数推进任务。\n"
        }
        
        if nextNode.currentRetry > 0 {
            prompt += "⚠️ 【自愈重试中】: 第 \(nextNode.currentRetry)/\(nextNode.maxRetries) 次重试。前次反馈: \(nextNode.memo ?? "无")\n"
        }
        
        prompt += "========================="
        return prompt
    }
    
    nonisolated public func autoAdvanceTaskToSuccess(
        planString: String?,
        resultMemo: String,
        newArtifacts: [AgentArtifact]? = nil
    ) -> (updatedJson: String?, sysMessage: String) {
        var tasks = parsePlan(planString)
        guard !tasks.isEmpty else { return (nil, "黑板为空") }
        
        if markNodeSuccess(in: &tasks, resultMemo: resultMemo, newArtifacts: newArtifacts) {
            let updatedStr = encodePlan(tasks)
            let hasNext = findNextActionableTask(in: tasks) != nil
            let nextPrompt = hasNext ? "👉 状态节点已归档为成功，已自动切入下一步骤。" : "🎉 所有计划任务已完成！请调用 finish_task 交卷。"
            return (updatedStr, "✅ 节点已成功推进！\n\(nextPrompt)")
        }
        return (planString, "黑板状态未发生流转。")
    }
    
    private func markNodeSuccess(in nodes: inout [AgentGraphNode], resultMemo: String, newArtifacts: [AgentArtifact]?) -> Bool {
        for i in 0..<nodes.count {
            if nodes[i].status == .running || nodes[i].status == .pending {
                if nodes[i].subNodes != nil && !nodes[i].subNodes!.isEmpty {
                    if markNodeSuccess(in: &nodes[i].subNodes!, resultMemo: resultMemo, newArtifacts: newArtifacts) {
                        if nodes[i].subNodes!.allSatisfy({ $0.status == .success }) { nodes[i].status = .success }
                        return true
                    }
                } else {
                    nodes[i].status = .success
                    nodes[i].memo = resultMemo
                    if let arts = newArtifacts {
                        if nodes[i].artifacts == nil { nodes[i].artifacts = [] }
                        nodes[i].artifacts?.append(contentsOf: arts)
                    }
                    return true
                }
            }
        }
        return false
    }
    
    nonisolated public func updateTaskStatus(
        planString: String?,
        taskId: String,
        newStatusStr: String,
        resultMemo: String? = nil,
        artifacts: [AgentArtifact]? = nil,
        hasPhysicalError: Bool = false
    ) -> String? {
        var tasks = parsePlan(planString)
        let targetStatus = BlackboardGrammar.parseStatus(from: newStatusStr)
        
        // 分析 result_memo 是否为主动探错、核实或纠偏闭环
        let isIntentionalProbeResolution: Bool = {
            guard let memo = resultMemo?.lowercased() else { return false }
            return memo.contains("确认") || memo.contains("验证") || memo.contains("不存在") ||
                   memo.contains("已捕获") || memo.contains("纠偏") || memo.contains("无需") ||
                   memo.contains("核实") || memo.contains("失败原因")
        }()
        
        func traverseAndUpdate(nodes: inout [AgentGraphNode]) -> Bool {
            for i in 0..<nodes.count {
                if nodes[i].id == taskId {
                    // 若存在物理报错，但本次更新属于明确的探错/核实结论，予以放行成功
                    if hasPhysicalError && !isIntentionalProbeResolution && targetStatus == .success {
                        nodes[i].status = .running
                        nodes[i].currentRetry += 1
                    } else {
                        nodes[i].status = targetStatus
                        if targetStatus == .success {
                            nodes[i].validationState = .verifiedSuccess
                        }
                    }
                    
                    if let memo = resultMemo, !memo.isEmpty {
                        nodes[i].memo = memo
                    }
                    
                    if let newArts = artifacts, !newArts.isEmpty {
                        var existing = nodes[i].artifacts ?? []
                        existing.append(contentsOf: newArts)
                        nodes[i].artifacts = existing
                    }
                    return true
                }
                
                if nodes[i].subNodes != nil && !nodes[i].subNodes!.isEmpty {
                    if traverseAndUpdate(nodes: &nodes[i].subNodes!) {
                        return true
                    }
                }
            }
            return false
        }
        
        if traverseAndUpdate(nodes: &tasks) {
            return encodePlan(tasks)
        }
        return planString
    }
    
    private func updateStatus(
        in tasks: inout [AgentGraphNode],
        taskId: String,
        newStatusStr: String,
        resultMemo: String? = nil,
        artifacts: [AgentArtifact]? = nil,
        hasError: Bool = false
    ) -> Bool {
        for i in 0..<tasks.count {
            if tasks[i].id == taskId {
                let s = newStatusStr.lowercased()
                if hasError {
                    tasks[i].status = .running
                    tasks[i].currentRetry += 1
                } else if s.contains("成功") || s.contains("success") || s.contains("完成") {
                    tasks[i].status = .success
                } else if s.contains("失败") || s.contains("failed") {
                    tasks[i].status = .failed
                } else if s.contains("执行中") || s.contains("running") {
                    tasks[i].status = .running
                } else {
                    tasks[i].status = .pending
                }
                
                if let rm = resultMemo { tasks[i].memo = rm }
                if let art = artifacts { tasks[i].artifacts = art }
                return true
            }
            if tasks[i].subNodes != nil && !tasks[i].subNodes!.isEmpty {
                if updateStatus(in: &tasks[i].subNodes!, taskId: taskId, newStatusStr: newStatusStr, resultMemo: resultMemo, artifacts: artifacts, hasError: hasError) {
                    let allSubsCompleted = tasks[i].subNodes!.allSatisfy { $0.status == .success }
                    if allSubsCompleted && tasks[i].status == .running { tasks[i].status = .success }
                    return true
                }
            }
        }
        return false
    }
    
    nonisolated public func appendSubtasks(planString: String?, parentTaskId: String, newSubtasks: [AgentGraphNode]) -> String? {
        var tasks = parsePlan(planString)
        if injectSubtasks(in: &tasks, targetId: parentTaskId, newSubs: newSubtasks) {
            return encodePlan(tasks)
        }
        return planString
    }
    
    private func injectSubtasks(in tasks: inout [AgentGraphNode], targetId: String, newSubs: [AgentGraphNode]) -> Bool {
        for i in 0..<tasks.count {
            if tasks[i].id == targetId {
                if tasks[i].subNodes == nil { tasks[i].subNodes = [] }
                tasks[i].subNodes?.append(contentsOf: newSubs)
                if tasks[i].status == .success { tasks[i].status = .running }
                return true
            }
            if tasks[i].subNodes != nil && !tasks[i].subNodes!.isEmpty {
                if injectSubtasks(in: &tasks[i].subNodes!, targetId: targetId, newSubs: newSubs) { return true }
            }
        }
        return false
    }
    
    /// 当模型下发 finish_task 时，自动将黑板中残留的所有未完成节点强行平仓打标为 success
    nonisolated public func markAllTasksSuccess(planString: String?, resultMemo: String = "任务已由 finish_task 全量归档完结") -> String? {
        var tasks = parsePlan(planString)
        guard !tasks.isEmpty else { return planString }
        
        func markAll(in nodes: inout [AgentGraphNode]) {
            for i in 0..<nodes.count {
                if nodes[i].status == .pending || nodes[i].status == .running {
                    nodes[i].status = .success
                    if nodes[i].memo == nil || nodes[i].memo?.isEmpty == true {
                        nodes[i].memo = resultMemo
                    }
                }
                if nodes[i].subNodes != nil {
                    markAll(in: &nodes[i].subNodes!)
                }
            }
        }
        
        markAll(in: &tasks)
        return encodePlan(tasks)
    }
    
    // MARK: - 超弹性任务入参解析与清洗引擎 (消除 99% 的大模型参数构造异常)
    nonisolated public func sanitizeAndEncodeTasks(from rawTasks: Any?) -> String? {
        guard let raw = rawTasks else { return nil }
        var parsedNodes: [AgentGraphNode] = []
        
        // 1. 字典数组形态：[[String: Any]]
        if let dictArray = raw as? [[String: Any]] {
            for (idx, dict) in dictArray.enumerated() {
                let id = (dict["id"] as? String) ?? (dict["id"] as? Int).map(String.init) ?? "\(idx + 1)"
                let text = (dict["text"] as? String) ?? (dict["title"] as? String) ?? (dict["name"] as? String) ?? "步骤 \(idx + 1)"
                let statusStr = (dict["status"] as? String) ?? "等待中"
                parsedNodes.append(AgentGraphNode(
                    id: id,
                    title: text,
                    nodeType: TaskBlackboardManager.inferNodeType(from: text),
                    status: GraphNodeStatus(fromFlexibleString: statusStr)
                ))
            }
        }
        // 2. 字符串数组形态：可能是 JSON 字符串列表或纯文本步骤列表
        else if let strArray = raw as? [String] {
            for (idx, item) in strArray.enumerated() {
                let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let id = (dict["id"] as? String) ?? (dict["id"] as? Int).map(String.init) ?? "\(idx + 1)"
                    let text = (dict["text"] as? String) ?? (dict["title"] as? String) ?? (dict["name"] as? String) ?? "步骤 \(idx + 1)"
                    let statusStr = (dict["status"] as? String) ?? "等待中"
                    parsedNodes.append(AgentGraphNode(
                        id: id,
                        title: text,
                        nodeType: TaskBlackboardManager.inferNodeType(from: text),
                        status: GraphNodeStatus(fromFlexibleString: statusStr)
                    ))
                } else {
                    // 纯文本步骤提取，如 "1. 获取应用列表"
                    var cleanTitle = trimmed
                    if let dotIdx = cleanTitle.firstIndex(of: ".") {
                        let prefix = cleanTitle[..<dotIdx].trimmingCharacters(in: .whitespaces)
                        if Int(prefix) != nil {
                            cleanTitle = String(cleanTitle[cleanTitle.index(after: dotIdx)...]).trimmingCharacters(in: .whitespaces)
                        }
                    }
                    parsedNodes.append(AgentGraphNode(
                        id: "\(idx + 1)",
                        title: cleanTitle,
                        nodeType: TaskBlackboardManager.inferNodeType(from: cleanTitle),
                        status: .pending
                    ))
                }
            }
        }
        // 3. 单一 JSON 字符串形态
        else if let jsonStr = raw as? String {
            let parsed = parsePlan(jsonStr)
            return parsed.isEmpty ? nil : encodePlan(parsed)
        }
        
        if !parsedNodes.isEmpty {
            return encodePlan(parsedNodes)
        }
        return nil
    }
    
    /// 更新指定节点的验收门禁状态与契约
    nonisolated public func updateValidationState(
        planString: String?,
        taskId: String,
        validationState: MilestoneValidationState,
        contract: VerificationContract? = nil,
        resultMemo: String? = nil,
        artifacts: [AgentArtifact]? = nil
    ) -> String? {
        var tasks = parsePlan(planString)
        
        func traverseAndUpdate(nodes: inout [AgentGraphNode]) -> Bool {
            for i in 0..<nodes.count {
                if nodes[i].id == taskId {
                    nodes[i].validationState = validationState
                    if let c = contract { nodes[i].contract = c }
                    if let rm = resultMemo { nodes[i].memo = rm }
                    if let arts = artifacts {
                        var existing = nodes[i].artifacts ?? []
                        existing.append(contentsOf: arts)
                        nodes[i].artifacts = existing
                    }
                    
                    // 若物理核验通过，同步驱动节点状态为 success
                    if validationState == .verifiedSuccess {
                        nodes[i].status = .success
                    } else if validationState == .verifying || validationState == .discrepancyFound {
                        nodes[i].status = .running
                    }
                    return true
                }
                if nodes[i].subNodes != nil && !nodes[i].subNodes!.isEmpty {
                    if traverseAndUpdate(nodes: &nodes[i].subNodes!) {
                        return true
                    }
                }
            }
            return false
        }
        
        if traverseAndUpdate(nodes: &tasks) {
            return encodePlan(tasks)
        }
        return planString
    }
    
    /// 当任务完结时，将黑板中所有非终态节点严格按最终状态平仓
    nonisolated public func finalizeRemainingTasks(
        planString: String?,
        finalStatusStr: String,
        finalAnswer: String? = nil
    ) -> String? {
        var tasks = parsePlan(planString)
        guard !tasks.isEmpty else { return planString }
        
        let normalizedStatus = finalStatusStr.lowercased()
        let isSuccess = normalizedStatus == "success" || normalizedStatus.contains("成功")
        let targetStatus: GraphNodeStatus = isSuccess ? .success : .failed
        let defaultMemo = isSuccess ? "任务已随整体流程交付" : "因前置依赖未就绪或上游任务受阻，级联终止"
        
        func finalizeNodes(nodes: inout [AgentGraphNode]) {
            for i in 0..<nodes.count {
                // 仅对未进入终态（等待中/执行中）的节点进行收敛平仓
                if nodes[i].status == .pending || nodes[i].status == .running {
                    nodes[i].status = targetStatus
                    
                    if !isSuccess {
                        nodes[i].validationState = .discrepancyFound
                    } else {
                        nodes[i].validationState = .verifiedSuccess
                    }
                    
                    if nodes[i].memo == nil || nodes[i].memo?.isEmpty == true || nodes[i].memo?.contains("finish_task") == true {
                        nodes[i].memo = defaultMemo
                    }
                }
                
                if nodes[i].subNodes != nil && !nodes[i].subNodes!.isEmpty {
                    finalizeNodes(nodes: &nodes[i].subNodes!)
                }
            }
        }
        
        finalizeNodes(nodes: &tasks)
        return encodePlan(tasks)
    }
}

// MARK: - ==================== 3. V6 拟态全景流与穿透检查器 UI ====================

// MARK: - 3.1 顶部全景流动胶囊条 (AgentFlowRibbonView)

public struct AgentFlowRibbonView: View {
    public let planString: String?
    public var isExecuting: Bool
    public var isInteractive: Bool
    public var onContinueExecution: (() -> Void)?
    public var onClearPlan: (() -> Void)?
    
    @State private var isExpanded: Bool = false
    @State private var selectedNode: AgentGraphNode? = nil
    @State private var isHovered: Bool = false
    
    // 全参数兼容构造器：同时支持 planContent / planString 传参及执行控制闭包
    public init(
        planContent: String? = nil,
        planString: String? = nil,
        isExecuting: Bool = false,
        isInteractive: Bool = true,
        onContinueExecution: (() -> Void)? = nil,
        onClearPlan: (() -> Void)? = nil
    ) {
        self.planString = planContent ?? planString
        self.isExecuting = isExecuting
        self.isInteractive = isInteractive
        self.onContinueExecution = onContinueExecution
        self.onClearPlan = onClearPlan
    }
    
    private var nodes: [AgentGraphNode] {
        TaskBlackboardManager.shared.parsePlan(planString)
    }
    
    private var completedCount: Int {
        nodes.filter { $0.status == .success }.count
    }
    
    public var body: some View {
        if !nodes.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // 1. 顶层主操作栏
                ribbonHeaderBar
                
                // 2. 展开的垂直任务详情抽屉
                if isExpanded {
                    Divider().opacity(0.4)
                    ribbonDrawerList
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isExecuting ? Color.purple.opacity(0.3) : Color.primary.opacity(0.08),
                        lineWidth: 1
                    )
            )
            .popover(item: $selectedNode) { node in
                GraphNodeInspectorView(
                    node: node,
                    allNodes: nodes,
                    onClose: { selectedNode = nil }
                )
            }
        }
    }
    
    // MARK: - 子视图：顶栏操作条
    private var ribbonHeaderBar: some View {
        HStack(spacing: 8) {
            Button(action: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 6) {
                    if isExecuting {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.65)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "checklist")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.purple)
                    }
                    
                    Text("动态任务黑板")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.primary)
                    
                    Text("\(completedCount)/\(nodes.count)")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.primary.opacity(0.05))
                        .cornerRadius(4)
                }
            }
            .buttonStyle(.plain)
            
            Divider()
                .frame(height: 12)
                .padding(.horizontal, 2)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                        Button(action: { selectedNode = node }) {
                            FlowCapsuleItemView(
                                node: node,
                                stepIndex: index + 1,
                                isSelected: selectedNode?.id == node.id
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
            
            Spacer(minLength: 4)
            
            // 推进操作按钮
            if let onContinue = onContinueExecution, !isExecuting, completedCount < nodes.count {
                Button(action: onContinue) {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill").font(.system(size: 8))
                        Text("推进").font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundColor(.purple)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(Color.purple.opacity(0.08))
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
            
            // 清空黑板按钮
            if let onClear = onClearPlan, !isExecuting {
                Button(action: onClear) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.7))
                        .padding(3)
                }
                .buttonStyle(.plain)
                .help("清空当前任务黑板")
            }
            
            Button(action: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 4) {
                    Text(isExpanded ? "收起清单" : "展开清单")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary.opacity(0.8))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .onHover { h in isHovered = h }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
    
    // MARK: - 子视图：垂直清单容器
    private var ribbonDrawerList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                Button(action: { selectedNode = node }) {
                    RibbonDrawerRowView(node: node, index: index)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: - 独立抽屉列表单行项 (解耦视图层级)
struct RibbonDrawerRowView: View {
    let node: AgentGraphNode
    let index: Int
    
    // 物理核验独立色彩通道
    private var validationColor: Color {
        guard let vState = node.validationState else { return node.status.color }
        switch vState {
        case .verifying: return Color.orange
        case .verifiedSuccess: return Color.teal  // 物理核验通过统一采用宝石青蓝
        case .discrepancyFound: return Color.red
        case .unverified: return node.status.color
        }
    }
    
    var body: some View {
        HStack(spacing: 8) {
            // 1. 状态图标：保持流程推进态（绿/红/灰），与右侧青蓝徽章互不干扰
            statusIconView
            
            // 2. 步骤信息
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("\(index + 1). \(node.title)")
                        .font(.system(size: 11.5, weight: node.status == .running ? .bold : .medium))
                        .foregroundColor(node.status == .pending ? .secondary : .primary)
                        .lineLimit(1)
                    
                    Text(node.nodeType.rawValue.uppercased())
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundColor(node.nodeType == .reasoning ? Color.purple : Color.teal)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background((node.nodeType == .reasoning ? Color.purple : Color.teal).opacity(0.1))
                        .cornerRadius(3)
                    
                    if let vState = node.validationState, vState != .unverified {
                        Text(vState.badgeTitle)
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundColor(validationColor)
                            .padding(.horizontal, 4.5)
                            .padding(.vertical, 1.2)
                            .background(validationColor.opacity(0.14))
                            .cornerRadius(3)
                    }
                }
                
                if let memo = node.memo, !memo.isEmpty {
                    Text(memo)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            if let arts = node.artifacts, !arts.isEmpty {
                HStack(spacing: 2) {
                    Image(systemName: "paperclip").font(.system(size: 8))
                    Text("\(arts.count) 个工件").font(.system(size: 8.5))
                }
                .foregroundColor(Color.purple)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Color.purple.opacity(0.1))
                .cornerRadius(4)
            }
            
            Image(systemName: "chevron.right")
                .font(.system(size: 9))
                .foregroundColor(.secondary.opacity(0.4))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(node.status == .running ? Color.teal.opacity(0.08) : Color.primary.opacity(0.02))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(node.status == .running ? Color.teal.opacity(0.25) : Color.primary.opacity(0.04), lineWidth: 1)
        )
    }
    
    @ViewBuilder
    private var statusIconView: some View {
        if node.validationState == .verifying {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.7)
                .frame(width: 14)
        } else if node.validationState == .discrepancyFound {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Color.red)
                .frame(width: 14)
        } else {
            Image(systemName: node.status.sfSymbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(node.status.color)
                .frame(width: 14)
        }
    }
}

// MARK: - 3.2 单个流动胶囊组件 (FlowCapsuleItemView)

struct FlowCapsuleItemView: View {
    let node: AgentGraphNode
    let stepIndex: Int
    let isSelected: Bool
    var borderRotation: Double = 0.0
    
    @State private var isHovered: Bool = false
    
    private var visualColor: Color {
        if let vState = node.validationState {
            switch vState {
            case .verifying: return Color.orange        // 晨曦橙 (反查中)
            case .verifiedSuccess: return Color.teal    // 宝石青蓝 (真实生效)
            case .discrepancyFound: return Color.red    // 品红警示 (数据差异)
            case .unverified: return node.status.color
            }
        }
        return node.status.color
    }
    
    private var visualSymbol: String {
        if let vState = node.validationState {
            switch vState {
            case .verifying: return "magnifyingglass"
            case .verifiedSuccess: return "checkmark.shield.fill"
            case .discrepancyFound: return "exclamationmark.triangle.fill"
            case .unverified: return node.status.sfSymbol
            }
        }
        return node.status.sfSymbol
    }
    
    var body: some View {
        HStack(spacing: 5) {
            if node.validationState == .verifying {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
                    .frame(width: 10, height: 10)
            } else {
                Image(systemName: visualSymbol)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(visualColor)
            }
            
            Text("\(stepIndex). \(node.title)")
                .font(.system(size: 11, weight: node.status == .running ? .bold : .medium))
                .foregroundColor(node.status == .pending ? .secondary : .primary)
                .lineLimit(1)
            
            if let vState = node.validationState, vState != .unverified {
                Text(vState.badgeTitle)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(visualColor)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(visualColor.opacity(0.14))
                    .cornerRadius(3)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(node.status == .running ? visualColor.opacity(0.08) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isSelected ? visualColor : (node.status == .running ? visualColor.opacity(0.4) : Color.clear),
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        .contentShape(Rectangle())
        .onHover { h in isHovered = h }
    }
}

// MARK: - 3.3 节点穿透式下钻检查器 (GraphNodeInspectorView)

public struct GraphNodeInspectorView: View {
    public let node: AgentGraphNode
    public let allNodes: [AgentGraphNode]
    public var onClose: () -> Void
    
    @State private var isSnapshotExpanded: Bool = false
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 1. 顶栏标题与状态
            HStack(spacing: 8) {
                Image(systemName: node.status.sfSymbol)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(node.status.color)
                
                Text(node.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)
                
                Spacer()
                
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            
            Divider().opacity(0.4)
            
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 10) {
                    // 物理真值核验证据卡片 (RAW Evidence Card)
                    if let contract = node.contract {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: "shield.lefthalf.filled")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(node.validationState == .verifiedSuccess ? Color.teal : Color.orange)
                                
                                Text("物理真值核验证据")
                                    .font(.system(size: 11.5, weight: .bold))
                                    .foregroundColor(.primary)
                                
                                Spacer()
                                
                                if let vState = node.validationState {
                                    Text(vState.badgeTitle)
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(vState == .verifiedSuccess ? Color.teal : Color.orange)
                                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                                        .background((vState == .verifiedSuccess ? Color.teal : Color.orange).opacity(0.14))
                                        .cornerRadius(4)
                                }
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 4) {
                                    Text("断言特征:").font(.system(size: 10.5)).foregroundColor(.secondary)
                                    Text(contract.expectedMutationKey)
                                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                        .foregroundColor(.primary)
                                    
                                    Text("• 资源 ID:").font(.system(size: 10.5)).foregroundColor(.secondary)
                                    Text(contract.targetResourceId)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                
                                HStack(spacing: 4) {
                                    Text("反查探针:").font(.system(size: 10.5)).foregroundColor(.secondary)
                                    Text(contract.probeCommandTemplate)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(Color.teal)
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(Color.teal.opacity(0.08))
                                        .cornerRadius(3)
                                }
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.03))
                            .cornerRadius(6)
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill((node.validationState == .verifiedSuccess ? Color.teal : Color.orange).opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke((node.validationState == .verifiedSuccess ? Color.teal : Color.orange).opacity(0.25), lineWidth: 1)
                        )
                    }
                    
                    // 3. 产出工件与 Diff 证据快照
                    if let artifacts = node.artifacts, !artifacts.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("产出证据工件 (\(artifacts.count))")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.secondary)
                            
                            ForEach(artifacts) { art in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Image(systemName: art.type == .diff ? "arrow.left.arrow.right" : "doc.text")
                                            .font(.system(size: 10))
                                            .foregroundColor(Color(hex: "#7000FF"))
                                        
                                        Text(art.name)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(.primary)
                                        
                                        Spacer()
                                        
                                        Text(art.type.rawValue.uppercased())
                                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                                            .foregroundColor(Color(hex: "#7000FF"))
                                            .padding(.horizontal, 4).padding(.vertical, 1)
                                            .background(Color(hex: "#7000FF").opacity(0.1))
                                            .cornerRadius(3)
                                    }
                                    
                                    if !art.content.isEmpty {
                                        Text(art.content)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.secondary.opacity(0.9))
                                            .lineSpacing(2)
                                            .padding(6)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color.primary.opacity(0.03))
                                            .cornerRadius(4)
                                    }
                                }
                                .padding(6)
                                .background(Color.primary.opacity(0.02))
                                .cornerRadius(6)
                            }
                        }
                    }
                    
                    // 4. 执行状态备忘
                    if let memo = node.memo, !memo.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("执行状态备忘")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.secondary)
                            
                            Text(memo)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.primary.opacity(0.85))
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.03))
                                .cornerRadius(6)
                        }
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .padding(14)
        .frame(width: 380)
        .background(VisualEffectView(material: .popover, blendingMode: .withinWindow))
    }
}

// MARK: - 3.4 内联工件展示卡片 (InlineArtifactCardView)

struct InlineArtifactCardView: View {
    let artifact: AgentArtifact
    @State private var isCopied: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: artifactIcon(for: artifact.type))
                        .font(.system(size: 10, weight: .bold))
                    Text(artifact.name)
                        .font(.system(size: 11.5, weight: .bold))
                }
                .foregroundColor(Color(hex: "#7000FF"))
                
                Spacer()
                
                // 打开物理文件
                if let urlStr = artifact.fileURLString, let url = URL(string: urlStr), FileManager.default.fileExists(atPath: url.path) {
                    Button(action: { NSWorkspace.shared.open(url) }) {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.up.forward.square")
                            Text("定位")
                        }
                        .font(.system(size: 9.5))
                        .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 4)
                }
                
                // 拷贝内容
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(artifact.content, forType: .string)
                    withAnimation { isCopied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { isCopied = false } }
                }) {
                    HStack(spacing: 2) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        Text(isCopied ? "已复制" : "复制")
                    }
                    .font(.system(size: 9.5))
                    .foregroundColor(isCopied ? .green : .secondary)
                }
                .buttonStyle(.plain)
            }
            
            // 内容预览框
            Text(artifact.content)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(.primary.opacity(0.8))
                .lineLimit(4)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.textBackgroundColor).opacity(0.6))
                .cornerRadius(6)
        }
        .padding(8)
        .background(Color(hex: "#7000FF").opacity(0.04))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: "#7000FF").opacity(0.15), lineWidth: 1))
    }
    
    private func artifactIcon(for type: AgentArtifact.ArtifactType) -> String {
        switch type {
        case .code: return "curlybraces"
        case .image: return "photo.fill"
        case .file: return "doc.fill"
        case .text: return "text.alignleft"
        case .url: return "link"
        case .diff: return "arrow.left.arrow.right"
        }
    }
}
