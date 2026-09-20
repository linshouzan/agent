//////////////////////////////////////////////////////////////////
// 文件名：LogManager.swift
// 文件说明：适用于 macOS 14+ 的全局独立时间轴日志面板 (V8.5 严格保序与大模型语义化排版版)
//
// 核心解构架构拓扑 (Domain-Driven Architecture):
// ├── 1. LogModels             : 会话门类、日志级别、执行状态与不可变一维节点快照 (Sendable)
// ├── 2. LogPayloadFormatter   : 大模型请求/响应载荷 (Gemini/OpenAI/XML/JSON) 深度解构与格式化引擎
// ├── 3. LogEngine (Actor)     : 100% 脱离主线程的独立后台日志计算引擎 (严格 FIFO 串行通道/Token级联)
// ├── 4. LogExportBridge       : 纯文本结构化导出与剪贴板桥接器
// ├── 5. LogManager (Facade)   : 面向前台 UI 绑定的响应式调度门面 (@Observable @MainActor)
// ├── 6. LogWindowManager      : 原生独立的日志监控窗口生命周期控制器 (NSWindowDelegate)
// ├── 7. FastLogTextView       : 禁用昂贵文本系统的轻量级 NSTextView 包装器
// └── 8. LogUI Components      : 时间轴主面板、三模载荷查看器与分级树状分支视图
//////////////////////////////////////////////////////////////////

import SwiftUI
import AppKit
import Combine
import Foundation

// MARK: - ==================== 1. LogModels (数据模型与不可变快照) ====================

enum SessionCategory: String, Codable, Sendable {
    case agent = "Agent 智能体"
    case singleLLM = "LLM 单次请求"
    case memoryDistill = "心智记忆提炼"
    case system = "系统服务"
    
    var color: Color {
        switch self {
        case .agent: return .purple
        case .singleLLM: return .cyan
        case .memoryDistill: return .indigo
        case .system: return .orange
        }
    }
    
    var icon: String {
        switch self {
        case .agent: return "brain.head.profile"
        case .singleLLM: return "bolt.horizontal.circle.fill"
        case .memoryDistill: return "wand.and.stars"
        case .system: return "gearshape.2.fill"
        }
    }
}

enum LogLevel: String, CaseIterable, Codable, Sendable {
    case info = "信息"
    case success = "成功"
    case warning = "警告"
    case error = "错误"
    
    var color: Color {
        switch self {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
    
    var icon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}

enum SessionState: String, Codable, Sendable {
    case executing = "推演中"
    case completed = "已完成"
    case failed = "异常"
    
    var themeColor: Color {
        switch self {
        case .executing: return .blue
        case .completed: return .green
        case .failed: return .red
        }
    }
}

/// 后台内存树内部维护节点实体 (运行于 LogEngine Actor 内部)
final class InternalLogNode: @unchecked Sendable {
    let id: UUID
    let timestamp: Date
    var level: LogLevel
    var title: String
    var detail: String?
    var isExpanded: Bool
    
    var isSessionRoot: Bool = false
    var sessionCategory: SessionCategory = .agent
    var sessionState: SessionState = .executing
    var agentName: String?
    var startTime: Date?
    var duration: TimeInterval?
    
    let file: String
    let function: String
    let line: Int
    
    var children: [InternalLogNode] = []
    weak var parent: InternalLogNode?
    
    var tokens: Int = 0
    var totalTokens: Int = 0
    var detailLineCount: Int = 1
    
    var fileName: String { (file as NSString).lastPathComponent }
    
    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: LogLevel,
        title: String,
        detail: String? = nil,
        isExpanded: Bool = false,
        isSessionRoot: Bool = false,
        sessionCategory: SessionCategory = .agent,
        agentName: String? = nil,
        file: String,
        function: String,
        line: Int
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.title = title
        self.detail = detail
        self.isExpanded = isExpanded
        self.isSessionRoot = isSessionRoot
        self.sessionCategory = sessionCategory
        self.agentName = agentName
        self.startTime = isSessionRoot ? Date() : nil
        self.file = file
        self.function = function
        self.line = line
        
        if let d = detail {
            self.detailLineCount = max(1, d.filter { $0 == "\n" }.count + 1)
        }
    }
    
    func updateSelfTokens(_ newTokens: Int, onTotalDelta: (Int) -> Void) {
        let delta = newTokens - self.tokens
        self.tokens = newTokens
        self.addTokens(delta, onTotalDelta: onTotalDelta)
    }
    
    func addTokens(_ delta: Int, onTotalDelta: (Int) -> Void) {
        if delta == 0 { return }
        self.totalTokens += delta
        onTotalDelta(delta)
        self.parent?.addTokens(delta, onTotalDelta: { _ in })
    }
}

/// 纯不可变、线程安全的视图渲染扁平快照 (100% Sendable)
struct FlatLogNode: Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let title: String
    let detail: String?
    let isExpanded: Bool
    let isSessionRoot: Bool
    let sessionCategory: SessionCategory
    let sessionState: SessionState
    let agentName: String?
    let duration: TimeInterval?
    let fileName: String
    let line: Int
    let tokens: Int
    let totalTokens: Int
    let depth: Int
    let isLast: Bool
    let ancestorMask: UInt64
    let hasChildren: Bool
    
    static func == (lhs: FlatLogNode, rhs: FlatLogNode) -> Bool {
        lhs.id == rhs.id &&
        lhs.depth == rhs.depth &&
        lhs.isLast == rhs.isLast &&
        lhs.ancestorMask == rhs.ancestorMask &&
        lhs.isExpanded == rhs.isExpanded &&
        lhs.sessionState == rhs.sessionState &&
        lhs.totalTokens == rhs.totalTokens &&
        lhs.duration == rhs.duration &&
        lhs.detail == rhs.detail
    }
}

// MARK: - ==================== 2. LogPayloadFormatter (深度语义化解构引擎) ====================

struct LogPayloadFormatter: Sendable {
    
    /// 语义化解构与排版（支持 Gemini / OpenAI / Claude / 通用 JSON）
    static func formatSemantic(rawText: String) -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        
        // 提取 JSON 载荷主体与前置文本（例如 "【发起网络请求】:\n{...}"）
        let (prefix, jsonObject) = extractJSON(from: trimmed)
        guard let jsonObject = jsonObject else {
            return unescapeString(rawText)
        }
        
        // 若为字典对象，尝试执行专有 LLM 语义排版
        if let dict = jsonObject as? [String: Any] {
            if let semanticLLM = formatLLMRequestDict(dict) {
                return (prefix.isEmpty ? "" : "\(prefix)\n\n") + semanticLLM
            }
        }
        
        // 通用 JSON 深度美化并还原内嵌换行
        if let prettyData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .withoutEscapingSlashes]),
           let prettyStr = String(data: prettyData, encoding: .utf8) {
            return (prefix.isEmpty ? "" : "\(prefix)\n\n") + unescapeString(prettyStr)
        }
        
        return rawText
    }
    
    /// 标准美化 JSON（保留完整键值对缩进）
    static func formatJSON(rawText: String) -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        
        let (prefix, jsonObject) = extractJSON(from: trimmed)
        guard let jsonObject = jsonObject else { return rawText }
        
        if let prettyData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .withoutEscapingSlashes]),
           let prettyStr = String(data: prettyData, encoding: .utf8) {
            return (prefix.isEmpty ? "" : "\(prefix)\n\n") + prettyStr
        }
        return rawText
    }
    
    // MARK: - 私有解析辅助
    
    private static func extractJSON(from text: String) -> (prefix: String, object: Any?) {
        guard let firstBrace = text.firstIndex(of: "{"),
              let lastBrace = text.lastIndex(of: "}") else {
            if let firstBracket = text.firstIndex(of: "["),
               let lastBracket = text.lastIndex(of: "]") {
                let prefix = String(text[..<firstBracket]).trimmingCharacters(in: .whitespacesAndNewlines)
                let sub = String(text[firstBracket...lastBracket])
                let obj = sub.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0, options: []) }
                return (prefix, obj)
            }
            return ("", nil)
        }
        
        let prefix = String(text[..<firstBrace]).trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonSub = String(text[firstBrace...lastBrace])
        let obj = jsonSub.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0, options: []) }
        return (prefix, obj)
    }
    
    private static func formatLLMRequestDict(_ dict: [String: Any]) -> String? {
        var sections: [String] = []
        
        // 1. 系统指令解构 (System Instruction)
        if let sysInst = dict["systemInstruction"] as? [String: Any],
           let parts = sysInst["parts"] as? [[String: Any]] {
            let partTexts = parts.compactMap { $0["text"] as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let sysText = partTexts.joined(separator: "\n\n")
            if !sysText.isEmpty {
                sections.append("╔════════════════════════════════════════════════════════════════╗\n║ 👑 SYSTEM INSTRUCTION (系统提示词指令)                          ║\n╚════════════════════════════════════════════════════════════════╝\n\(sysText)")
            }
        } else if let sys = dict["system"] as? String, !sys.isEmpty {
            sections.append("╔════════════════════════════════════════════════════════════════╗\n║ 👑 SYSTEM INSTRUCTION (系统提示词指令)                          ║\n╚════════════════════════════════════════════════════════════════╝\n\(sys.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        
        // 2. 工具声明解构 (Tools & Functions)
        if let tools = dict["tools"] as? [[String: Any]], !tools.isEmpty {
            var toolLines: [String] = ["╔════════════════════════════════════════════════════════════════╗\n║ 🛠 TOOLS & FUNCTION DEFINITIONS (可用工具函数声明)              ║\n╚════════════════════════════════════════════════════════════════╝"]
            for tool in tools {
                if let declarations = tool["functionDeclarations"] as? [[String: Any]] {
                    for decl in declarations {
                        let name = decl["name"] as? String ?? "未命名函数"
                        let desc = decl["description"] as? String ?? "无描述"
                        toolLines.append("● [工具: \(name)]\n  描述: \(desc)")
                        if let params = decl["parameters"] as? [String: Any],
                           let props = params["properties"] as? [String: [String: Any]] {
                            let required = (params["required"] as? [String]) ?? []
                            for (pName, pDict) in props {
                                let pDesc = pDict["description"] as? String ?? ""
                                let pType = pDict["type"] as? String ?? "string"
                                let reqTag = required.contains(pName) ? " [必需]" : " [可选]"
                                toolLines.append("    └─ 参数 \(pName) (\(pType))\(reqTag): \(pDesc)")
                            }
                        }
                    }
                }
            }
            if toolLines.count > 1 {
                sections.append(toolLines.joined(separator: "\n\n"))
            }
        }
        
        // 3. 多轮对话流解构 (Gemini contents / OpenAI messages)
        if let contents = dict["contents"] as? [[String: Any]], !contents.isEmpty {
            var msgBlock = "╔════════════════════════════════════════════════════════════════╗\n║ 💬 CONVERSATION TURNS (多轮会话交互流 - 共 \(contents.count) 轮)                  ║\n╚════════════════════════════════════════════════════════════════╝"
            
            for (idx, turn) in contents.enumerated() {
                let role = (turn["role"] as? String)?.uppercased() ?? "USER"
                let roleIcon = (role == "USER") ? "👤" : (role == "MODEL" || role == "ASSISTANT") ? "🤖" : "⚙️"
                
                var turnPartsText: [String] = []
                if let parts = turn["parts"] as? [[String: Any]] {
                    for part in parts {
                        if let text = part["text"] as? String, !text.isEmpty {
                            turnPartsText.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                        
                        // 提取函数调用 (Tool Call)
                        if let call = part["functionCall"] as? [String: Any] {
                            let callName = call["name"] as? String ?? "unknown"
                            var argsStr = "{}"
                            if let args = call["args"] as? [String: Any],
                               let argsData = try? JSONSerialization.data(withJSONObject: args, options: [.prettyPrinted, .withoutEscapingSlashes]),
                               let s = String(data: argsData, encoding: .utf8) {
                                argsStr = s
                            }
                            turnPartsText.append("⚡️ [下发动作 Tool Call: \(callName)]:\n\(argsStr)")
                        }
                        
                        // 提取函数响应 (Tool Response & RAG 知识切片)
                        if let resp = part["functionResponse"] as? [String: Any] {
                            let respName = resp["name"] as? String ?? "unknown"
                            var resBody = ""
                            if let responseObj = resp["response"] as? [String: Any] {
                                if let resultStr = responseObj["result"] as? String {
                                    resBody = resultStr.trimmingCharacters(in: .whitespacesAndNewlines)
                                } else if let rData = try? JSONSerialization.data(withJSONObject: responseObj, options: [.prettyPrinted, .withoutEscapingSlashes]),
                                          let s = String(data: rData, encoding: .utf8) {
                                    resBody = s
                                }
                            }
                            turnPartsText.append("📦 [动作反馈 Tool Response: \(respName)]:\n\(resBody)")
                        }
                    }
                }
                
                let joinedParts = turnPartsText.joined(separator: "\n\n")
                msgBlock += "\n\n┌── [Turn \(idx + 1)] \(roleIcon) \(role)\n\(joinedParts.indentLines(spaces: 2))\n└──"
            }
            sections.append(msgBlock)
        } else if let messages = dict["messages"] as? [[String: Any]], !messages.isEmpty {
            var msgBlock = "╔════════════════════════════════════════════════════════════════╗\n║ 💬 CONVERSATION TURNS (多轮会话交互流 - 共 \(messages.count) 轮)                  ║\n╚════════════════════════════════════════════════════════════════╝"
            
            for (idx, msg) in messages.enumerated() {
                let role = (msg["role"] as? String)?.uppercased() ?? "USER"
                let roleIcon = (role == "USER") ? "👤" : (role == "ASSISTANT") ? "🤖" : (role == "SYSTEM") ? "👑" : "⚙️"
                let content = (msg["content"] as? String) ?? ""
                
                msgBlock += "\n\n┌── [Turn \(idx + 1)] \(roleIcon) \(role)\n\(content.trimmingCharacters(in: .whitespacesAndNewlines).indentLines(spaces: 2))\n└──"
            }
            sections.append(msgBlock)
        }
        
        guard !sections.isEmpty else { return nil }
        return sections.joined(separator: "\n\n")
    }
    
    private static func unescapeString(_ str: String) -> String {
        return str
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "  ")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\/", with: "/")
    }
}

private extension String {
    func indentLines(spaces: Int) -> String {
        let indent = String(repeating: " ", count: spaces)
        return self.components(separatedBy: "\n").map { "\(indent)\($0)" }.joined(separator: "\n")
    }
}

// MARK: - ==================== 3. LogEngine (后台严格 FIFO 串行日志引擎) ====================

fileprivate enum LogAction: Sendable {
    case startSession(id: UUID, query: String, agentName: String, category: SessionCategory, file: String, function: String, line: Int)
    case endSession(sessionID: UUID, isSuccess: Bool, detail: String?)
    case setContext(id: UUID?)
    case log(id: UUID, level: LogLevel, title: String, detail: String?, parentID: UUID?, expandDefault: Bool, file: String, function: String, line: Int)
    case updateTokens(nodeID: UUID, tokens: Int)
    case updateDetail(nodeID: UUID, detail: String)
    case appendDetail(nodeID: UUID, textDelta: String)
    case toggleExpand(nodeID: UUID)
    case expandAll
    case collapseAll
    case clearLogs
    case forceSync
}

actor LogEngine {
    static let shared = LogEngine()
    
    private var rootLogs: [InternalLogNode] = []
    private var nodeMap: [UUID: InternalLogNode] = [:]
    private var sessionTotalTokens: Int = 0
    private var activeContextID: UUID? = nil
    
    private let maxLogCount = 500
    private var isSyncScheduled = false
    private var pendingLastAddedID: UUID? = nil
    
    // 不可变 Sendable 常量 continuation：保证 nonisolated 绝对安全读取与 FIFO 入队
    private let continuation: AsyncStream<LogAction>.Continuation
    
    private init() {
        let (stream, cont) = AsyncStream.makeStream(of: LogAction.self)
        self.continuation = cont
        
        Task.detached(priority: .userInitiated) { [weak self] in
            for await action in stream {
                guard let self = self else { break }
                await self.processAction(action)
            }
        }
    }
    
    fileprivate nonisolated func enqueue(_ action: LogAction) {
        continuation.yield(action)
    }
    
    // MARK: - 串行执行核心
    
    private func processAction(_ action: LogAction) {
        switch action {
        case .startSession(let id, let query, let agentName, let category, let file, let function, let line):
            for root in rootLogs where root.isSessionRoot {
                root.isExpanded = false
            }
            let sessionNode = InternalLogNode(
                id: id,
                timestamp: Date(),
                level: .info,
                title: query.trimmingCharacters(in: .whitespacesAndNewlines),
                detail: nil,
                isExpanded: true,
                isSessionRoot: true,
                sessionCategory: category,
                agentName: agentName,
                file: file,
                function: function,
                line: line
            )
            nodeMap[id] = sessionNode
            rootLogs.append(sessionNode)
            
            while rootLogs.count > maxLogCount {
                let removed = rootLogs.removeFirst()
                removeNodeFromMap(removed)
            }
            activeContextID = id
            scheduleThrottledSync(lastAddedID: id)
            
        case .endSession(let sessionID, let isSuccess, let detail):
            guard let sessionNode = nodeMap[sessionID] else { return }
            if let start = sessionNode.startTime {
                sessionNode.duration = Date().timeIntervalSince(start)
            }
            sessionNode.sessionState = isSuccess ? .completed : .failed
            sessionNode.level = isSuccess ? .success : .error
            if let d = detail, !d.isEmpty {
                sessionNode.detail = d
                sessionNode.detailLineCount = max(1, d.filter { $0 == "\n" }.count + 1)
            }
            if activeContextID == sessionID {
                activeContextID = nil
            }
            scheduleThrottledSync(lastAddedID: sessionID)
            
        case .setContext(let id):
            self.activeContextID = id
            
        case .log(let id, let level, let title, let detail, let parentID, let expandDefault, let file, let function, let line):
            let node = InternalLogNode(
                id: id,
                timestamp: Date(),
                level: level,
                title: title,
                detail: detail,
                isExpanded: expandDefault,
                file: file,
                function: function,
                line: line
            )
            nodeMap[id] = node
            
            // 严格上下文归属判定：显式父节点 > 当前活跃上下文 > 最新顶级会话
            let effectiveParentID = parentID ?? self.activeContextID ?? rootLogs.last(where: { $0.isSessionRoot })?.id
            
            if let pid = effectiveParentID, let parentNode = nodeMap[pid] {
                node.parent = parentNode
                parentNode.children.append(node)
                parentNode.addTokens(node.totalTokens, onTotalDelta: { self.sessionTotalTokens += $0 })
                if level == .error { parentNode.isExpanded = true }
            } else {
                rootLogs.append(node)
                while rootLogs.count > maxLogCount {
                    let removedNode = rootLogs.removeFirst()
                    removeNodeFromMap(removedNode)
                }
            }
            scheduleThrottledSync(lastAddedID: id)
            
        case .updateTokens(let nodeID, let tokens):
            if let node = nodeMap[nodeID] {
                node.updateSelfTokens(tokens, onTotalDelta: { self.sessionTotalTokens += $0 })
                scheduleThrottledSync()
            }
            
        case .updateDetail(let nodeID, let detail):
            if let node = nodeMap[nodeID] {
                node.detail = detail
                node.detailLineCount = max(1, detail.filter { $0 == "\n" }.count + 1)
                scheduleThrottledSync()
            }
            
        case .appendDetail(let nodeID, let textDelta):
            guard !textDelta.isEmpty else { return }
            if let node = nodeMap[nodeID] {
                if node.detail == nil { node.detail = "" }
                node.detail! += textDelta
                node.detailLineCount += textDelta.filter { $0 == "\n" }.count
                scheduleThrottledSync()
            }
            
        case .toggleExpand(let nodeID):
            if let node = nodeMap[nodeID] {
                node.isExpanded.toggle()
                scheduleThrottledSync(force: true)
            }
            
        case .expandAll:
            for node in nodeMap.values { node.isExpanded = true }
            scheduleThrottledSync(force: true)
            
        case .collapseAll:
            for node in nodeMap.values { node.isExpanded = false }
            scheduleThrottledSync(force: true)
            
        case .clearLogs:
            rootLogs.removeAll()
            nodeMap.removeAll()
            sessionTotalTokens = 0
            activeContextID = nil
            scheduleThrottledSync(force: true)
            
        case .forceSync:
            scheduleThrottledSync(force: true)
        }
    }
    
    func exportLogs() -> String {
        return LogExportBridge.formatLogs(rootLogs: rootLogs)
    }
    
    private func removeNodeFromMap(_ node: InternalLogNode) {
        nodeMap.removeValue(forKey: node.id)
        for child in node.children { removeNodeFromMap(child) }
    }
    
    // MARK: - 扁平快照合批渲染
    
    private func scheduleThrottledSync(lastAddedID: UUID? = nil, force: Bool = false) {
        if let id = lastAddedID { pendingLastAddedID = id }
        guard !isSyncScheduled || force else { return }
        isSyncScheduled = true
        
        Task {
            if !force {
                try? await Task.sleep(nanoseconds: 35_000_000) // 35ms 平滑帧率
            }
            self.isSyncScheduled = false
            
            let snapshot = self.buildFlatSnapshot()
            let totalTokens = self.sessionTotalTokens
            let lastID = self.pendingLastAddedID
            self.pendingLastAddedID = nil
            
            await LogManager.shared.applyBackgroundSnapshot(
                flatLogs: snapshot,
                sessionTotalTokens: totalTokens,
                lastAddedID: lastID
            )
        }
    }
    
    private func buildFlatSnapshot() -> [FlatLogNode] {
        var result: [FlatLogNode] = []
        result.reserveCapacity(nodeMap.count + 20)
        
        func traverse(_ nodes: [InternalLogNode], depth: Int, ancestorMask: UInt64) {
            for (index, node) in nodes.enumerated() {
                let isLast = index == nodes.count - 1
                
                let flat = FlatLogNode(
                    id: node.id,
                    timestamp: node.timestamp,
                    level: node.level,
                    title: node.title,
                    detail: node.detail,
                    isExpanded: node.isExpanded,
                    isSessionRoot: node.isSessionRoot,
                    sessionCategory: node.sessionCategory,
                    sessionState: node.sessionState,
                    agentName: node.agentName,
                    duration: node.duration,
                    fileName: node.fileName,
                    line: node.line,
                    tokens: node.tokens,
                    totalTokens: node.totalTokens,
                    depth: depth,
                    isLast: isLast,
                    ancestorMask: ancestorMask,
                    hasChildren: !node.children.isEmpty
                )
                result.append(flat)
                
                if node.isExpanded && !node.children.isEmpty {
                    var nextMask = ancestorMask
                    if !isLast && depth < 63 {
                        nextMask |= (1 << depth)
                    }
                    traverse(node.children, depth: depth + 1, ancestorMask: nextMask)
                }
            }
        }
        traverse(rootLogs, depth: 0, ancestorMask: 0)
        return result
    }
}

// MARK: - ==================== 4. LogExportBridge (纯文本导出桥接器) ====================

struct LogExportBridge: Sendable {
    static func formatLogs(rootLogs: [InternalLogNode]) -> String {
        var lines: [String] = []
        for node in rootLogs {
            lines.append(contentsOf: formatNodeForExport(node, indentLevel: 0))
        }
        return lines.joined(separator: "\n")
    }
    
    private static func formatNodeForExport(_ node: InternalLogNode, indentLevel: Int) -> [String] {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let indent = String(repeating: "  ", count: indentLevel)
        let timeStr = formatter.string(from: node.timestamp)
        let tokenStr = node.totalTokens > 0 ? " [\(node.totalTokens) T]" : ""
        let agentTag = node.agentName != nil ? " [\(node.agentName!)]" : ""
        
        var lines = ["\(indent)[\(timeStr)]\(agentTag) [\(node.level.rawValue)]\(tokenStr) [\(node.fileName):\(node.line)] \(node.title)"]
        if let detail = node.detail, !detail.isEmpty {
            lines.append("\(indent)    ↳ " + detail.replacingOccurrences(of: "\n", with: "\n\(indent)    "))
        }
        for child in node.children {
            lines.append(contentsOf: formatNodeForExport(child, indentLevel: indentLevel + 1))
        }
        return lines
    }
}

// MARK: - ==================== 5. LogManager (前台门面与状态分发) ====================

@MainActor
class LogManager: NSObject, ObservableObject {
    static let shared = LogManager()
    
    @Published var flatLogs: [FlatLogNode] = []
    @Published var lastAddedLogID: UUID? = nil
    @Published var sessionTotalTokens: Int = 0
    @Published var activeContextID: UUID? = nil
    
    private override init() {
        super.init()
    }
    
    // MARK: - 核心业务调用入口 (完全零阻塞 + 严格 FIFO 顺序入队)
    
    @discardableResult
    nonisolated func startSession(
        query: String,
        agentName: String,
        category: SessionCategory = .agent,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) -> UUID {
        let sessionID = UUID()
        LogEngine.shared.enqueue(.startSession(
            id: sessionID,
            query: query,
            agentName: agentName,
            category: category,
            file: file,
            function: function,
            line: line
        ))
        Task { @MainActor in self.activeContextID = sessionID }
        return sessionID
    }
    
    nonisolated func endSession(sessionID: UUID, isSuccess: Bool = true, detail: String? = nil) {
        LogEngine.shared.enqueue(.endSession(sessionID: sessionID, isSuccess: isSuccess, detail: detail))
        Task { @MainActor in
            if self.activeContextID == sessionID { self.activeContextID = nil }
        }
    }
    
    nonisolated func setContext(_ id: UUID?) {
        LogEngine.shared.enqueue(.setContext(id: id))
        Task { @MainActor in self.activeContextID = id }
    }
    
    @discardableResult
    nonisolated func startGroup(
        title: String,
        detail: String? = nil,
        level: LogLevel = .info,
        parentID: UUID? = nil,
        expandDefault: Bool = false,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) -> UUID {
        return log(level: level, title: title, detail: detail, parentID: parentID, expandDefault: expandDefault, file: file, function: function, line: line)
    }
    
    nonisolated func updateTokens(nodeID: UUID, tokens: Int) {
        LogEngine.shared.enqueue(.updateTokens(nodeID: nodeID, tokens: tokens))
    }
    
    nonisolated func updateLogDetail(nodeID: UUID, detail: String) {
        LogEngine.shared.enqueue(.updateDetail(nodeID: nodeID, detail: detail))
    }
    
    nonisolated func appendLogDetail(nodeID: UUID, textDelta: String) {
        guard !textDelta.isEmpty else { return }
        LogEngine.shared.enqueue(.appendDetail(nodeID: nodeID, textDelta: textDelta))
    }
    
    @discardableResult
    nonisolated func log(
        level: LogLevel = .info,
        title: String,
        detail: String? = nil,
        parentID: UUID? = nil,
        expandDefault: Bool = false,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) -> UUID {
        let newID = UUID()
        LogEngine.shared.enqueue(.log(
            id: newID,
            level: level,
            title: title,
            detail: detail,
            parentID: parentID,
            expandDefault: expandDefault,
            file: file,
            function: function,
            line: line
        ))
        return newID
    }
    
    nonisolated func info(_ title: String, detail: String? = nil, parentID: UUID? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        log(level: .info, title: title, detail: detail, parentID: parentID, file: file, function: function, line: line)
    }
    
    nonisolated func success(_ title: String, detail: String? = nil, parentID: UUID? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        log(level: .success, title: title, detail: detail, parentID: parentID, file: file, function: function, line: line)
    }
    
    nonisolated func warning(_ title: String, detail: String? = nil, parentID: UUID? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        log(level: .warning, title: title, detail: detail, parentID: parentID, file: file, function: function, line: line)
    }
    
    nonisolated func error(_ title: String, detail: String? = nil, parentID: UUID? = nil, expand: Bool = true, file: String = #file, function: String = #function, line: Int = #line) {
        log(level: .error, title: title, detail: detail, parentID: parentID, expandDefault: expand, file: file, function: function, line: line)
    }
    
    // MARK: - UI 控制
    
    func toggleExpand(for nodeID: UUID) {
        LogEngine.shared.enqueue(.toggleExpand(nodeID: nodeID))
    }
    
    func expandAll() {
        LogEngine.shared.enqueue(.expandAll)
    }
    
    func collapseAll() {
        LogEngine.shared.enqueue(.collapseAll)
    }
    
    func clearLogs() {
        self.flatLogs.removeAll()
        self.sessionTotalTokens = 0
        LogEngine.shared.enqueue(.clearLogs)
    }
    
    func refreshLogs() {
        LogEngine.shared.enqueue(.forceSync)
    }
    
    func exportLogs() async -> String {
        return await LogEngine.shared.exportLogs()
    }
    
    func show() {
        LogWindowManager.shared.show()
    }
    
    func applyBackgroundSnapshot(flatLogs: [FlatLogNode], sessionTotalTokens: Int, lastAddedID: UUID?) {
        self.flatLogs = flatLogs
        self.sessionTotalTokens = sessionTotalTokens
        if let newID = lastAddedID {
            self.lastAddedLogID = newID
        }
    }
}

// MARK: - ==================== 6. LogWindowManager (窗口生命周期控制器) ====================

@MainActor
final class LogWindowManager: NSObject, NSWindowDelegate {
    static let shared = LogWindowManager()
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
            if existingWindow.isMiniaturized { existingWindow.deminiaturize(nil) }
            existingWindow.makeKeyAndOrderFront(nil)
            existingWindow.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            LogManager.shared.refreshLogs()
            return
        }
        
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Agent 核心执行树"
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        newWindow.contentView = NSHostingView(rootView: LogPanelWindow())
        newWindow.makeKeyAndOrderFront(nil)
        newWindow.delegate = self
        self.window = newWindow
        
        NSApp.activate(ignoringOtherApps: true)
        MainWindowManager.syncDockIconPolicy()
        LogManager.shared.refreshLogs()
    }
    
    func windowWillClose(_ notification: Notification) {
        window = nil
        MainWindowManager.syncDockIconPolicy()
    }
}

// MARK: - ==================== 7. FastLogTextView (轻量滚动文本视图) ====================

struct FastLogTextView: NSViewRepresentable {
    var text: String
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = NSColor.labelColor.withAlphaComponent(0.88)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        
        if let textContainer = textView.textContainer {
            textContainer.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
            textContainer.widthTracksTextView = true
        }
        
        textView.layoutManager?.allowsNonContiguousLayout = true
        scrollView.documentView = textView
        return scrollView
    }
    
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? NSTextView else { return }
        
        if text.count > tv.string.count && text.hasPrefix(tv.string) {
            let newPart = String(text.dropFirst(tv.string.count))
            let attrStr = NSAttributedString(string: newPart, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.88)
            ])
            tv.textStorage?.append(attrStr)
            tv.scrollToEndOfDocument(nil)
        } else if tv.string != text {
            tv.string = text
        }
    }
}

// MARK: - ==================== 8. LogUI Components (时间轴与面板视图) ====================

enum LogDetailDisplayMode: String, CaseIterable, Identifiable {
    case semantic = "排版"
    case json = "JSON"
    case raw = "原始"
    
    var id: String { self.rawValue }
}

@MainActor
struct LogPanelWindow: View {
    @ObservedObject private var manager = LogManager.shared
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "network").foregroundColor(.blue).font(.system(size: 14, weight: .bold))
                    Text("智能体执行树").font(.system(size: 13, weight: .bold))
                }
                
                Spacer()
                
                HStack(spacing: 2) {
                    Button(action: { manager.collapseAll() }) {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.right.2").font(.system(size: 9, weight: .bold))
                            Text("全部折叠").font(.system(size: 10.5))
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                    
                    Divider().frame(height: 10)
                    
                    Button(action: { manager.expandAll() }) {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.down.2").font(.system(size: 9, weight: .bold))
                            Text("全部展开").font(.system(size: 10.5))
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                }
                .background(Color.primary.opacity(0.04))
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.08), lineWidth: 0.8))
                
                if manager.sessionTotalTokens > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.horizontal.circle.fill").foregroundColor(.orange)
                        Text("\(manager.sessionTotalTokens) T")
                    }
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.orange.opacity(0.12))
                    .cornerRadius(6)
                }
                
                Button(action: {
                    Task {
                        let text = await manager.exportLogs()
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(text, forType: .string)
                        Util.message("树状日志已全量复制")
                    }
                }) {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("全量导出日志")
                
                Button(action: { withAnimation { manager.clearLogs() } }) {
                    Image(systemName: "trash").foregroundColor(.red.opacity(0.85)).font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("清空日志")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.thinMaterial)
            
            ModernDivider(style: .fade(0.15))
            
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let flatData = manager.flatLogs
                        if flatData.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "tray").font(.system(size: 32)).foregroundColor(.secondary.opacity(0.4))
                                Text("等待会话推演执行...").font(.system(size: 13)).foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 120)
                        } else {
                            ForEach(flatData) { item in
                                LogTreeView(item: item)
                            }
                        }
                    }
                    .padding(.vertical, 12).padding(.horizontal, 16)
                }
                .background(Color(NSColor.textBackgroundColor).opacity(0.2))
                .onChange(of: manager.lastAddedLogID) { _, newID in
                    if let targetID = newID {
                        proxy.scrollTo(targetID, anchor: .bottom)
                    }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear {
            manager.refreshLogs()
        }
    }
}

struct LogTreeView: View {
    let item: FlatLogNode
    
    @State private var isHovered: Bool = false
    @State private var displayMode: LogDetailDisplayMode = .semantic
    @State private var semanticDetail: String? = nil
    @State private var jsonDetail: String? = nil
    
    var body: some View {
        if item.isSessionRoot {
            sessionCardView
                .padding(.top, 8)
                .padding(.bottom, item.isExpanded ? 4 : 8)
        } else {
            standardNodeRowView
        }
    }
    
    @ViewBuilder
    var sessionCardView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                chevronIndicator
                stateBadgeView
                sessionTitleView
                Spacer()
                sessionMetricsView
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(isHovered ? 0.06 : 0.03))
            .contentShape(Rectangle())
            .onTapGesture {
                LogManager.shared.toggleExpand(for: item.id)
            }
            .onHover { h in isHovered = h }
            
            if item.isExpanded && item.detail != nil {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("📝 最终交付正文")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        displayModePicker
                        
                        Button(action: copyDetailToClipboard) {
                            Image(systemName: "doc.on.clipboard").font(.system(size: 9.5))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8).padding(.top, 6)
                    
                    FastLogTextView(text: currentTextToDisplay)
                        .frame(height: 220)
                        .padding(.horizontal, 4).padding(.bottom, 6)
                }
                .background(Color(NSColor.textBackgroundColor).opacity(0.3))
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor).opacity(0.2), lineWidth: 0.8))
                .padding(.horizontal, 8).padding(.bottom, 8)
            }
        }
        .background(.ultraThinMaterial)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .task(id: item.detail) {
            parsePayloadAsync()
        }
    }
    
    private var chevronIndicator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.secondary)
            .rotationEffect(.degrees(item.isExpanded ? 90 : 0))
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: item.isExpanded)
            .frame(width: 14)
    }
    
    private var stateBadgeView: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(item.sessionState.themeColor)
                .frame(width: 7, height: 7)
            Text(item.sessionState.rawValue)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundColor(item.sessionState.themeColor)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(item.sessionState.themeColor.opacity(0.12))
        .cornerRadius(4)
    }
    
    @ViewBuilder
    var sessionTitleView: some View {
        HStack(spacing: 4) {
            Image(systemName: item.sessionCategory.icon)
                .font(.system(size: 8.5))
            Text(item.sessionCategory.rawValue)
                .font(.system(size: 9.5, weight: .bold))
        }
        .foregroundColor(item.sessionCategory.color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(item.sessionCategory.color.opacity(0.12))
        .cornerRadius(4)
        
        if let aName = item.agentName, !aName.isEmpty {
            Text("[\(aName)]")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(.primary.opacity(0.85))
        }
        
        Text(item.title)
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(.primary)
            .lineLimit(1)
    }
    
    @ViewBuilder
    private var sessionMetricsView: some View {
        if let dur = item.duration {
            Text(String(format: "%.1fs", dur))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
        }
        
        if item.totalTokens > 0 {
            Text("\(item.totalTokens) T")
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundColor(.cyan)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.cyan.opacity(0.12))
                .cornerRadius(4)
        }
        
        Text(timeString(from: item.timestamp))
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(.secondary)
    }
    
    @ViewBuilder
    private var standardNodeRowView: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<item.depth, id: \.self) { d in
                let hasGuideLine = (item.ancestorMask & (1 << d)) != 0
                ZStack(alignment: .leading) {
                    if hasGuideLine {
                        Rectangle()
                            .fill(Color(NSColor.separatorColor).opacity(0.45))
                            .frame(width: 1.5)
                            .padding(.leading, 8)
                            .frame(maxHeight: .infinity)
                    }
                }.frame(width: 28)
            }
            
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(item.level.color.opacity(0.18)).frame(width: 16, height: 16)
                    Image(systemName: item.level.icon).foregroundColor(item.level.color).font(.system(size: 8.5))
                }.padding(.top, 4)
                
                if !item.isLast || (item.isExpanded && item.hasChildren) {
                    Rectangle()
                        .fill(Color(NSColor.separatorColor).opacity(0.45))
                        .frame(width: 1.5)
                        .padding(.top, 3)
                        .frame(maxHeight: .infinity)
                } else { Spacer() }
            }.frame(width: 16)
            
            Spacer().frame(width: 10)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 6) {
                    if item.hasChildren || item.detail != nil {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(item.isExpanded ? 90 : 0))
                            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: item.isExpanded)
                            .frame(width: 10)
                    } else { Spacer().frame(width: 10) }
                    
                    Text(timeString(from: item.timestamp))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(.secondary)
                    
                    if item.totalTokens > 0 {
                        Text("\(item.totalTokens) T")
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .foregroundColor(.cyan)
                            .padding(.horizontal, 3.5).padding(.vertical, 0.5)
                            .background(Color.cyan.opacity(0.12))
                            .cornerRadius(3)
                    }
                    
                    Text(item.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    Spacer(minLength: 8)
                    
                    HStack(spacing: 6) {
                        if item.detail != nil {
                            displayModePicker
                            
                            Button(action: copyDetailToClipboard) {
                                Image(systemName: "doc.on.clipboard").font(.system(size: 10)).foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .opacity(isHovered ? 1.0 : 0.6)
                        }
                        
                        Text("\(item.fileName):\(item.line)")
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    LogManager.shared.toggleExpand(for: item.id)
                }
                
                if item.isExpanded && item.detail != nil {
                    FastLogTextView(text: currentTextToDisplay)
                        .frame(height: 180)
                        .background(Color.clear)
                        .cornerRadius(5)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(NSColor.separatorColor).opacity(0.25), lineWidth: 0.8))
                }
            }
            .padding(.bottom, 6)
        }
        .onHover { hovering in isHovered = hovering }
        .task(id: item.detail) {
            parsePayloadAsync()
        }
    }
    
    @ViewBuilder
    private var displayModePicker: some View {
        HStack(spacing: 2) {
            ForEach(LogDetailDisplayMode.allCases) { mode in
                Button(action: { displayMode = mode }) {
                    Text(mode.rawValue)
                        .font(.system(size: 8.5, weight: displayMode == mode ? .bold : .regular))
                        .foregroundColor(displayMode == mode ? .blue : .secondary)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(displayMode == mode ? Color.blue.opacity(0.15) : Color.clear)
                        .cornerRadius(3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(1)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(4)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.08), lineWidth: 0.8))
    }
    
    private var currentTextToDisplay: String {
        switch displayMode {
        case .semantic:
            return semanticDetail ?? item.detail ?? ""
        case .json:
            return jsonDetail ?? item.detail ?? ""
        case .raw:
            return item.detail ?? ""
        }
    }
    
    private func timeString(from date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: date)
    }
    
    private func copyDetailToClipboard() {
        let text = currentTextToDisplay
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
    
    private func parsePayloadAsync() {
        guard let rawText = item.detail, !rawText.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            let semantic = LogPayloadFormatter.formatSemantic(rawText: rawText)
            let prettyJSON = LogPayloadFormatter.formatJSON(rawText: rawText)
            await MainActor.run {
                self.semanticDetail = semantic
                self.jsonDetail = prettyJSON
            }
        }
    }
}
