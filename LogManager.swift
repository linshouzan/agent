//////////////////////////////////////////////////////////////////
// 文件名：LogManager.swift
// 文件说明：适用于 macOS 14+ 的全局独立时间轴日志面板 (V6 会话卡片与树状降维性能版)
// 核心架构：
// 1. 会话级聚合容器 (Session Grouping)：每次对话独立生成顶级卡片，新对话自动折叠历史会话。
// 2. 状态与指标可视化：顶部卡片集成状态圆点、推演耗时统计、Token 实时汇总与 Agent 徽标。
// 3. 树状一维降维引擎：继承 UInt64 Bitmask 导引线算法，O(0) 内存分配绘制多层缩进。
// 4. 便捷折叠总控：工具栏提供「全部折叠 / 全部展开」与「快速清理」快捷控制。
//////////////////////////////////////////////////////////////////

import SwiftUI
import AppKit
import Combine

// MARK: - 1. 数据模型与枚举

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

// 一维化扁平视图结构，切断 SwiftUI 深层递归追踪
struct FlatLogNode: Identifiable, Equatable {
    var id: UUID { node.id }
    let node: LogNode
    let depth: Int
    let isLast: Bool
    let ancestorMask: UInt64 // 位运算掩码：用于 O(1) 计算深层缩进的参考线
    
    static func == (lhs: FlatLogNode, rhs: FlatLogNode) -> Bool {
        lhs.node.id == rhs.node.id &&
        lhs.depth == rhs.depth &&
        lhs.isLast == rhs.isLast &&
        lhs.ancestorMask == rhs.ancestorMask &&
        lhs.node.isExpanded == rhs.node.isExpanded &&
        lhs.node.sessionState == rhs.node.sessionState &&
        lhs.node.totalTokens == rhs.node.totalTokens &&
        lhs.node.duration == rhs.node.duration
    }
}

@MainActor
@Observable
class LogNode: Identifiable, Equatable {
    static func == (lhs: LogNode, rhs: LogNode) -> Bool { lhs.id == rhs.id }
    
    let id: UUID
    let timestamp: Date
    var level: LogLevel
    var title: String
    var detail: String?
    var isExpanded: Bool
    
    // 会话级元数据
    var isSessionRoot: Bool = false
    var sessionCategory: SessionCategory = .agent // [Added]
    var sessionState: SessionState = .executing
    var agentName: String?
    var startTime: Date?
    var duration: TimeInterval?
    
    let file: String
    let function: String
    let line: Int
    
    var children: [LogNode] = []
    
    @ObservationIgnored weak var parent: LogNode?
    
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
    
    func updateSelfTokens(_ newTokens: Int) {
        let delta = newTokens - self.tokens
        self.tokens = newTokens
        self.addTokens(delta)
    }
    
    func addTokens(_ delta: Int) {
        if delta == 0 { return }
        self.totalTokens += delta
        self.parent?.addTokens(delta)
        LogManager.shared.sessionTotalTokens += delta
    }
}

// MARK: - 2. 全局日志管理器 (业务层调用入口)

@MainActor
class LogManager: NSObject, NSWindowDelegate, ObservableObject {
    static let shared = LogManager()
    
    @Published var rootLogs: [LogNode] = []
    @Published var flatLogs: [FlatLogNode] = []
    
    @Published var lastAddedLogID: UUID? = nil
    @Published var sessionTotalTokens: Int = 0
    
    private var nodeMap: [UUID: LogNode] = [:]
    private let maxLogCount = 400
    
    @Published var activeContextID: UUID? = nil
    
    private var logWindow: NSWindow?
    var isVisible: Bool { return logWindow != nil }
    
    private var rebuildTask: Task<Void, Never>?
    
    private override init() { super.init() }
    
    /// 开启单次独立会话分组（自动折叠历史旧会话）
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
        Task { @MainActor in
            for root in self.rootLogs where root.isSessionRoot {
                root.isExpanded = false
            }
            
            let sessionNode = LogNode(
                id: sessionID,
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
            
            self.nodeMap[sessionID] = sessionNode
            self.rootLogs.append(sessionNode)
            
            while self.rootLogs.count > self.maxLogCount {
                let removed = self.rootLogs.removeFirst()
                self.removeNodeFromMap(removed)
            }
            
            self.activeContextID = sessionID
            self.lastAddedLogID = sessionID
            self.rebuildFlatData()
        }
        return sessionID
    }
    
    /// 结束会话并固化状态与总耗时
    nonisolated func endSession(sessionID: UUID, isSuccess: Bool = true, detail: String? = nil) {
        Task { @MainActor in
            guard let sessionNode = self.nodeMap[sessionID] else { return }
            if let start = sessionNode.startTime {
                sessionNode.duration = Date().timeIntervalSince(start)
            }
            sessionNode.sessionState = isSuccess ? .completed : .failed
            sessionNode.level = isSuccess ? .success : .error
            
            if let d = detail, !d.isEmpty {
                sessionNode.detail = d
                sessionNode.detailLineCount = max(1, d.filter { $0 == "\n" }.count + 1)
            }
            
            if self.activeContextID == sessionID {
                self.activeContextID = nil
            }
            self.rebuildFlatData()
        }
    }
    
    // MARK: - 🚀 V6 扁平化重建引擎
    
    func setNeedsRebuildFlatData() {
        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms 节流窗口
            guard !Task.isCancelled else { return }
            self.rebuildFlatData()
        }
    }
    
    func rebuildFlatData() {
        var result: [FlatLogNode] = []
        result.reserveCapacity(self.flatLogs.count + 50)
        
        func traverse(_ nodes: [LogNode], depth: Int, ancestorMask: UInt64) {
            for (index, node) in nodes.enumerated() {
                let isLast = index == nodes.count - 1
                result.append(FlatLogNode(node: node, depth: depth, isLast: isLast, ancestorMask: ancestorMask))
                
                if node.isExpanded && !node.children.isEmpty {
                    var nextMask = ancestorMask
                    if isLast && depth < 63 { nextMask |= (1 << depth) }
                    traverse(node.children, depth: depth + 1, ancestorMask: nextMask)
                }
            }
        }
        traverse(self.rootLogs, depth: 0, ancestorMask: 0)
        self.flatLogs = result
    }
    
    func toggleExpand(for nodeID: UUID) {
        if let node = nodeMap[nodeID] {
            node.isExpanded.toggle()
            rebuildFlatData()
        }
    }
    
    func expandAll() {
        for node in nodeMap.values { node.isExpanded = true }
        rebuildFlatData()
    }
    
    func collapseAll() {
        for node in nodeMap.values { node.isExpanded = false }
        rebuildFlatData()
    }
    
    // MARK: - 常规调用入口
    
    func show() {
        if let existingWindow = logWindow, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Agent 核心执行树"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LogPanelWindow())
        window.makeKeyAndOrderFront(nil)
        window.delegate = self
        self.logWindow = window
        
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        MainWindowManager.syncDockIconPolicy()
    }
    
    func windowWillClose(_ notification: Notification) {
        logWindow = nil
        MainWindowManager.syncDockIconPolicy()
    }
    
    nonisolated func setContext(_ id: UUID?) {
        Task { @MainActor in self.activeContextID = id }
    }
    
    @discardableResult
    nonisolated func startGroup(
        title: String, detail: String? = nil, level: LogLevel = .info, parentID: UUID? = nil,
        expandDefault: Bool = false, file: String = #file, function: String = #function, line: Int = #line
    ) -> UUID {
        return log(level: level, title: title, detail: detail, parentID: parentID, expandDefault: expandDefault, file: file, function: function, line: line)
    }
    
    nonisolated func updateTokens(nodeID: UUID, tokens: Int) {
        Task { @MainActor in if let node = self.nodeMap[nodeID] { node.updateSelfTokens(tokens) } }
    }
    
    nonisolated func updateLogDetail(nodeID: UUID, detail: String) {
        Task { @MainActor in
            if let node = self.nodeMap[nodeID] {
                node.detail = detail
                node.detailLineCount = max(1, detail.filter { $0 == "\n" }.count + 1)
            }
        }
    }
    
    nonisolated func appendLogDetail(nodeID: UUID, textDelta: String) {
        guard !textDelta.isEmpty else { return }
        Task { @MainActor in
            if let node = self.nodeMap[nodeID] {
                if node.detail == nil { node.detail = "" }
                node.detail! += textDelta
                node.detailLineCount += textDelta.filter { $0 == "\n" }.count
            }
        }
    }
    
    @discardableResult
    nonisolated func log(
        level: LogLevel = .info, title: String, detail: String? = nil, parentID: UUID? = nil,
        expandDefault: Bool = false, file: String = #file, function: String = #function, line: Int = #line
    ) -> UUID {
        let newID = UUID()
        Task { @MainActor in
            let node = LogNode(id: newID, timestamp: Date(), level: level, title: title, detail: detail, isExpanded: expandDefault, file: file, function: function, line: line)
            self.nodeMap[newID] = node
            
            let effectiveParentID = parentID ?? self.activeContextID
            
            if let pid = effectiveParentID, let parentNode = self.nodeMap[pid] {
                node.parent = parentNode
                parentNode.children.append(node)
                parentNode.addTokens(node.totalTokens)
                
                if level == .error { parentNode.isExpanded = true }
                self.setNeedsRebuildFlatData()
            } else {
                self.rootLogs.append(node)
                while self.rootLogs.count > self.maxLogCount {
                    let removedNode = self.rootLogs.removeFirst()
                    self.removeNodeFromMap(removedNode)
                }
                self.setNeedsRebuildFlatData()
            }
            self.lastAddedLogID = newID
        }
        return newID
    }
    
    private func removeNodeFromMap(_ node: LogNode) {
        nodeMap.removeValue(forKey: node.id)
        for child in node.children { removeNodeFromMap(child) }
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
    
    func clearLogs() {
        self.rootLogs.removeAll()
        self.flatLogs.removeAll()
        self.nodeMap.removeAll()
        self.sessionTotalTokens = 0
    }
    
    func exportLogs() -> String {
        var lines: [String] = []
        for node in rootLogs { lines.append(contentsOf: formatNodeForExport(node, indentLevel: 0)) }
        return lines.joined(separator: "\n")
    }
    
    private func formatNodeForExport(_ node: LogNode, indentLevel: Int) -> [String] {
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

// MARK: - 3. UI 视图渲染 (时间轴面板)

struct LogPanelWindow: View {
    @StateObject private var manager = LogManager.shared
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部精致工具栏
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "network").foregroundColor(.blue).font(.system(size: 14, weight: .bold))
                    Text("智能体执行树").font(.system(size: 13, weight: .bold))
                }
                
                Spacer()
                
                // 折叠总控快捷胶囊
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
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(manager.exportLogs(), forType: .string)
                    Util.message("树状日志已全量复制")
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
                            }.frame(maxWidth: .infinity, alignment: .center).padding(.top, 120)
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
        .frame(minWidth: 720, minHeight: 480)
    }
}

// MARK: - 4. 树状一维渲染节点组件 (含顶级会话卡片)

struct LogTreeView: View {
    let item: FlatLogNode
    var node: LogNode { item.node }
    
    @State private var isHovered: Bool = false
    @State private var formattedDetail: String? = nil
    
    var body: some View {
        if node.isSessionRoot {
            // 🌟 顶级会话卡片呈现
            sessionCardView
                .padding(.top, 8)
                .padding(.bottom, node.isExpanded ? 4 : 8)
        } else {
            // 递归子步骤呈现
            standardNodeRowView
        }
    }
    
    // MARK: - 顶级会话卡片视图
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
                LogManager.shared.toggleExpand(for: node.id)
                if node.isExpanded && formattedDetail == nil { formatLogDetailAsync() }
            }
            .onHover { h in isHovered = h }
            
            // 展开会话卡片时，呈现最终交付的 Markdown 回复全文
            if node.isExpanded && node.detail != nil {
                let textToDisplay = formattedDetail ?? node.detail ?? ""
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("📝 最终交付正文")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(action: copyDetailToClipboard) {
                            Image(systemName: "doc.on.clipboard").font(.system(size: 9.5))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8).padding(.top, 6)
                    
                    FastLogTextView(text: textToDisplay)
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
    }
    
    private var chevronIndicator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.secondary)
            .rotationEffect(.degrees(node.isExpanded ? 90 : 0))
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: node.isExpanded)
            .frame(width: 14)
    }
    
    private var stateBadgeView: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(node.sessionState.themeColor)
                .frame(width: 7, height: 7)
            Text(node.sessionState.rawValue)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundColor(node.sessionState.themeColor)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(node.sessionState.themeColor.opacity(0.12))
        .cornerRadius(4)
    }
    
    @ViewBuilder
    var sessionTitleView: some View {
        // 1. 类型标签 (智能体 / 单次LLM / 记忆提炼)
        HStack(spacing: 4) {
            Image(systemName: node.sessionCategory.icon)
                .font(.system(size: 8.5))
            Text(node.sessionCategory.rawValue)
                .font(.system(size: 9.5, weight: .bold))
        }
        .foregroundColor(node.sessionCategory.color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(node.sessionCategory.color.opacity(0.12))
        .cornerRadius(4)
        
        // 2. 角色名标签
        if let aName = node.agentName, !aName.isEmpty {
            Text("[\(aName)]")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(.primary.opacity(0.85))
        }
        
        // 3. 用户输入标题
        Text(node.title)
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(.primary)
            .lineLimit(1)
    }
    
    @ViewBuilder
    private var sessionMetricsView: some View {
        if let dur = node.duration {
            Text(String(format: "%.1fs", dur))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
        }
        
        if node.totalTokens > 0 {
            Text("\(node.totalTokens) T")
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundColor(.cyan)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.cyan.opacity(0.12))
                .cornerRadius(4)
        }
        
        Text(timeString(from: node.timestamp))
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(.secondary)
    }
    
    // MARK: - 标准子步骤行
    @ViewBuilder
    private var standardNodeRowView: some View {
        HStack(alignment: .top, spacing: 0) {
            // 1. O(0) 位运算绘制深层连接参考线
            ForEach(0..<item.depth, id: \.self) { d in
                let isAncestorLast = (item.ancestorMask & (1 << d)) != 0
                ZStack(alignment: .leading) {
                    if !isAncestorLast {
                        Rectangle()
                            .fill(Color(NSColor.separatorColor).opacity(0.45))
                            .frame(width: 1.5)
                            .padding(.leading, 8)
                            .frame(maxHeight: .infinity)
                    }
                }.frame(width: 28)
            }
            
            // 2. 节点圆点与分支线
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(node.level.color.opacity(0.18)).frame(width: 16, height: 16)
                    Image(systemName: node.level.icon).foregroundColor(node.level.color).font(.system(size: 8.5))
                }.padding(.top, 4)
                
                if !item.isLast || (node.isExpanded && !node.children.isEmpty) {
                    Rectangle()
                        .fill(Color(NSColor.separatorColor).opacity(0.45))
                        .frame(width: 1.5)
                        .padding(.top, 3)
                        .frame(maxHeight: .infinity)
                } else { Spacer() }
            }.frame(width: 16)
            
            Spacer().frame(width: 10)
            
            // 3. 核心日志文本区
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 6) {
                    if !node.children.isEmpty || node.detail != nil {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(node.isExpanded ? 90 : 0))
                            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: node.isExpanded)
                            .frame(width: 10)
                    } else { Spacer().frame(width: 10) }
                    
                    Text(timeString(from: node.timestamp))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(.secondary)
                    
                    if node.totalTokens > 0 {
                        Text("\(node.totalTokens) T")
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .foregroundColor(.cyan)
                            .padding(.horizontal, 3.5).padding(.vertical, 0.5)
                            .background(Color.cyan.opacity(0.12))
                            .cornerRadius(3)
                    }
                    
                    Text(node.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    Spacer(minLength: 8)
                    
                    HStack(spacing: 6) {
                        Button(action: copyDetailToClipboard) {
                            Image(systemName: "doc.on.clipboard").font(.system(size: 10)).foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .opacity((isHovered && node.detail != nil) ? 1.0 : 0.0)
                        
                        Text("\(node.fileName):\(node.line)")
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    LogManager.shared.toggleExpand(for: node.id)
                    if node.isExpanded && formattedDetail == nil { formatLogDetailAsync() }
                }
                
                if node.isExpanded && node.detail != nil {
                    let textToDisplay = formattedDetail ?? node.detail ?? ""
                    FastLogTextView(text: textToDisplay)
                        .frame(height: 160)
                        .background(Color(NSColor.textBackgroundColor).opacity(0.2))
                        .cornerRadius(5)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(NSColor.separatorColor).opacity(0.25), lineWidth: 0.8))
                }
            }
            .padding(.bottom, 6)
        }
        .onHover { hovering in isHovered = hovering }
        .onAppear { if node.isExpanded && formattedDetail == nil { formatLogDetailAsync() } }
    }
    
    private func timeString(from date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: date)
    }
    
    private func copyDetailToClipboard() {
        guard let text = formattedDetail ?? node.detail else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    
    private func formatLogDetailAsync() {
        guard let rawText = node.detail else { return }
        Task.detached(priority: .userInitiated) {
            let clean = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            if (clean.hasPrefix("{") && clean.hasSuffix("}")) || (clean.hasPrefix("[") && clean.hasSuffix("]")) {
                if let d = clean.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: d, options: []),
                   let pd = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes]),
                   let pStr = String(data: pd, encoding: .utf8) {
                    await MainActor.run { self.formattedDetail = pStr }
                }
            }
        }
    }
}

// MARK: - 5. 高性能滚动文本组件

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
        textView.textColor = NSColor.labelColor.withAlphaComponent(0.85)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        
        // 禁用昂贵的文本辅助系统
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        
        // 约束单向弹性布局，宽度跟随父级，高度在内部滚动
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
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.85)
            ])
            tv.textStorage?.append(attrStr)
            tv.scrollToEndOfDocument(nil)
        } else if tv.string != text {
            tv.string = text
        }
    }
}
