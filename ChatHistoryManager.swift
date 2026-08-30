//////////////////////////////////////////////////////////////////
// 文件名：ChatHistoryManager.swift
// 文件说明：适用于 macOS 14+ 的对话历史记录综合管理与多维资产归档中心 (Swift 6 Ready)
//
// 核心解构架构拓扑 (Domain-Driven Architecture):
// ├── 1. HistoryModels            : 归档库分类枚举 (LibraryFilter) 与资产象限定义
// ├── 2. HistoryStorageEngine     : 后台异步磁盘安全原子化读写引擎 (JSON 落盘)
// ├── 3. HistoryReflectionPipeline: 潜意识全景认知反思与资产分类智能路由核
// ├── 4. HistoryExportBridge      : 标准化全量开发档案导出与访达交互桥接器
// ├── 5. ChatHistoryManager       : 核心状态管理器与反向流转门面 (@Observable @MainActor)
// └── 6. ChatHistoryUI Components : 历史会话管理视窗 (ManagementPanel) 与富文本气泡排盘
//////////////////////////////////////////////////////////////////

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

// MARK: - ==================== 1. HistoryModels (分类过滤与资产模型) ====================

enum LibraryFilter: String, CaseIterable, Identifiable, Sendable {
    case active = "📱 活跃对话"
    case persona = "👤 偏好画像"
    case lesson = "💡 避坑心法"
    case asset = "📦 经验资产"
    
    var id: String { self.rawValue }
}

// MARK: - ==================== 2. HistoryStorageEngine (磁盘异步持久化引擎) ====================

struct HistoryStorageEngine: Sendable {
    
    static func loadFromDisk() -> [ChatSession] {
        guard let url = ConfigManager.shared.chatHistoryFileName,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([ChatSession].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.updatedAt > $1.updatedAt }
    }
    
    static func persistAsync(sessions: [ChatSession]) {
        guard let url = ConfigManager.shared.chatHistoryFileName else { return }
        let snapshot = sessions
        Task.detached(priority: .background) {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}

// MARK: - ==================== 3. HistoryReflectionPipeline (潜意识全景反思核) ====================

struct HistoryReflectionPipeline: Sendable {
    
    /// 执行全景认知反思并计算自适应资产分类标签
    static func reflectAndDeriveCategory(messages: [SavedChatMessage], title: String, model: String) async -> String {
        // 传递 100% Sendable 的纯数据持久化 messages 数组
        await MemoryManager.shared.observeAndExtractSession(messages: messages, model: model)
        
        let titleLower = title.lowercased()
        var derivedCategory = "经验资产"
        if titleLower.contains("bug") || titleLower.contains("报错") || titleLower.contains("修复") || titleLower.contains("❌") || titleLower.contains("error") {
            derivedCategory = "避坑心法"
        } else if titleLower.contains("习惯") || titleLower.contains("人设") || titleLower.contains("我是谁") || titleLower.contains("偏好") || titleLower.contains("称呼") {
            derivedCategory = "偏好画像"
        }
        return derivedCategory
    }
}

// MARK: - ==================== 4. HistoryExportBridge (标准化档案导出桥接) ====================

struct HistoryExportBridge: Sendable {
    
    @MainActor
    static func exportSessionToFile(session: ChatSession) {
        var content = ""
        content += "==================================================\n"
        content += "         AI 智能体工作台 - 历史对话资产导出          \n"
        content += "==================================================\n"
        content += " 会话主题: \(session.title)\n"
        content += " 导出时间: \(formatFullDate(Date()))\n"
        content += " 累计负荷: \(estimateSessionTokens(session)) Tokens\n"
        content += " 消息总计: \(session.messages.count) 条记录\n"
        content += "==================================================\n\n"
        
        for (index, msg) in session.messages.enumerated() {
            let floor = "#\(index + 1)"
            let sender = msg.isUser ? "👤 【用户】" : "🤖 【AI 智能体】"
            content += "\(floor) ---------------------------------------------\n"
            content += "\(sender)\n"
            content += "\(msg.text)\n"
            if !msg.isUser && !msg.skillLogs.isEmpty {
                content += "\n🛠️ 底层工具链集成调用记录:\n"
                for log in msg.skillLogs {
                    content += "  ▶ [\(log.skillName)] \(log.displayName)\n"
                    if !log.resultOutput.isEmpty {
                        let formattedOutput = log.resultOutput.components(separatedBy: .newlines).map { "     \($0)" }.joined(separator: "\n")
                        content += "    执行反馈:\n\(formattedOutput)\n"
                    }
                }
            }
            content += "\n"
        }
        content += "=================== 导出结束 (EOF) ===================\n"
        
        let savePanel = NSSavePanel()
        savePanel.title = "导出全量对话记录"
        savePanel.prompt = "导出"
        savePanel.allowedContentTypes = [.plainText]
        let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")
        let sanitizedTitle = session.title.components(separatedBy: invalidCharacters).joined(separator: "_")
        savePanel.nameFieldStringValue = sanitizedTitle.isEmpty ? "未命名会话" : "\(sanitizedTitle).txt"
        
        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                do {
                    try content.write(to: url, atomically: true, encoding: .utf8)
                    ___updateIslandNotice(text: "对话已成功导出至本地", icon: "arrow.down.doc.fill")
                } catch {
                    print("❌ [导出失败] 无法写入文件: \(error.localizedDescription)")
                    ___updateIslandNotice(text: "导出失败，无写入权限", icon: "exclamationmark.triangle.fill")
                }
            }
        }
    }
    
    private static func formatFullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
    
    static func estimateSessionTokens(_ session: ChatSession) -> Int {
        var totalTokens = 0
        for msg in session.messages {
            totalTokens += TokenEstimationEngine.estimateTextTokens(msg.text)
            for log in msg.skillLogs {
                totalTokens += TokenEstimationEngine.estimateTextTokens(log.argsJSON)
                totalTokens += TokenEstimationEngine.estimateTextTokens(log.resultOutput)
            }
        }
        return totalTokens
    }
}

// MARK: - ==================== 5. ChatHistoryManager (核心状态管理与资产流转门面) ====================

@MainActor
class ChatHistoryManager: ObservableObject {
    static let shared = ChatHistoryManager()
    
    @Published var sessions: [ChatSession] = []
    
    /// 后台潜意识全景反思的会话 ID 并发追踪锁
    @Published var archivingSessionIDs: Set<UUID> = []
    
    private init() {
        loadSessions()
    }
    
    func loadSessions() {
        self.sessions = HistoryStorageEngine.loadFromDisk()
    }
    
    func saveSession(id: UUID, title: String, agentID: UUID, messages: [ChatMessage], personaID: UUID? = nil) {
        let savedMsgs = messages.map { $0.toSaved() }
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].messages = savedMsgs
            sessions[idx].updatedAt = Date()
            sessions[idx].agentID = agentID
            sessions[idx].personaID = personaID
            if !title.isEmpty { sessions[idx].title = title }
        } else {
            let newSession = ChatSession(
                id: id,
                title: title.isEmpty ? "新对话" : title,
                updatedAt: Date(),
                agentID: agentID,
                messages: savedMsgs,
                isArchived: false,
                archiveCategory: "常规会话",
                personaID: personaID
            )
            sessions.insert(newSession, at: 0)
        }
        HistoryStorageEngine.persistAsync(sessions: self.sessions)
    }
    
    func updateSessionTitle(id: UUID, newTitle: String) {
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].title = newTitle
            HistoryStorageEngine.persistAsync(sessions: self.sessions)
        }
    }
    
    func deleteSession(id: UUID) {
        sessions.removeAll { $0.id == id }
        HistoryStorageEngine.persistAsync(sessions: self.sessions)
    }
    
    func deleteMessage(sessionID: UUID, messageID: UUID) {
        if let idx = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[idx].messages.removeAll { $0.id == messageID }
            HistoryStorageEngine.persistAsync(sessions: self.sessions)
        }
    }
    
    func updateMessageText(sessionID: UUID, messageID: UUID, newText: String) {
        if let sIdx = sessions.firstIndex(where: { $0.id == sessionID }),
           let mIdx = sessions[sIdx].messages.firstIndex(where: { $0.id == messageID }) {
            sessions[sIdx].messages[mIdx].text = newText
            sessions[sIdx].updatedAt = Date()
            HistoryStorageEngine.persistAsync(sessions: self.sessions)
        }
    }
    
    /// 将已归档会话无损释放并归还活跃库池中
    func unarchiveSession(id: UUID) {
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].isArchived = false
            sessions[idx].archiveCategory = "常规会话"
            sessions[idx].updatedAt = Date()
            
            HistoryStorageEngine.persistAsync(sessions: self.sessions)
            
            NotificationCenter.default.post(name: NSNotification.Name("AgentProfilesExternallyUpdated"), object: nil)
            ___updateIslandNotice(text: "会话资产已成功恢复至活跃库", icon: "tray.and.arrow.up.fill")
        }
    }
    
    /// 触发会话终结结算，调用底层潜意识神经元反思核收割认知，并物理封锁该对话划归资产库
    func archiveAndReflectSession(id: UUID, model: String) async {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        
        archivingSessionIDs.insert(id)
        
        defer {
            withAnimation(.easeOut(duration: 0.2)) {
                self.archivingSessionIDs.remove(id)
            }
        }
        
        let session = sessions[idx]
        let derivedCategory = await HistoryReflectionPipeline.reflectAndDeriveCategory(
            messages: session.messages,
            title: session.title,
            model: model
        )
        
        sessions[idx].isArchived = true
        sessions[idx].archiveCategory = derivedCategory
        sessions[idx].updatedAt = Date()
        
        HistoryStorageEngine.persistAsync(sessions: self.sessions)
        
        NotificationCenter.default.post(name: NSNotification.Name("AgentProfilesExternallyUpdated"), object: nil)
        ___updateIslandNotice(text: "该会话核心经验已提炼归档", icon: "brain.head.profile")
    }
}

// MARK: - ==================== 6. ChatHistoryUI Components (资产视窗与气泡呈现) ====================

@MainActor
struct ChatHistoryManagementPanel: View {
    @StateObject private var historyManager = ChatHistoryManager.shared
    @State private var selectedSessionID: UUID?
    @State private var editingSessionID: UUID?
    @State private var editTitleText: String = ""
    
    @State private var editingMessageID: UUID? = nil
    @State private var editingMessageText: String = ""
    @State private var selectedLibraryFilter: LibraryFilter = .active
    
    var segmentedSessions: [ChatSession] {
        switch selectedLibraryFilter {
        case .active:
            return historyManager.sessions.filter { !($0.isArchived ?? false) }
        case .persona:
            return historyManager.sessions.filter { ($0.isArchived ?? false) && $0.archiveCategory == "偏好画像" }
        case .lesson:
            return historyManager.sessions.filter { ($0.isArchived ?? false) && $0.archiveCategory == "避坑心法" }
        case .asset:
            return historyManager.sessions.filter { ($0.isArchived ?? false) && $0.archiveCategory == "经验资产" }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 1. 顶栏
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("全局历史会话与反思网络资产库").font(.system(size: 15, weight: .bold))
                    Text("安全持久化管理您的所有会话。已归档项已被大模型潜意识层归纳提炼，跨对话固化为永久常识。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(Color.clear)
            
            ModernDivider(style: .fade(0.18))
            
            // 2. 分类切换滑道
            VStack(spacing: 0) {
                Picker("", selection: $selectedLibraryFilter) {
                    ForEach(LibraryFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.01))
                
                Divider().opacity(0.6)
            }
            
            HSplitView {
                // 左侧栏：历史列表
                List(selection: $selectedSessionID) {
                    if segmentedSessions.isEmpty {
                        VStack(spacing: 8) {
                            Spacer()
                            Image(systemName: "tray.fill").font(.system(size: 22)).foregroundColor(.secondary.opacity(0.3))
                            Text("该资产象限暂无物理记录").font(.system(size: 11)).foregroundColor(.secondary.opacity(0.5))
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, minHeight: 140)
                        .listRowBackground(Color.clear)
                    }
                    
                    ForEach(segmentedSessions) { session in
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                if editingSessionID == session.id {
                                    TextField("输入标题", text: $editTitleText)
                                        .textFieldStyle(.roundedBorder)
                                        .onSubmit { saveTitleEdit(for: session.id) }
                                } else {
                                    Text(session.title)
                                        .font(.system(size: 13, weight: .semibold))
                                        .lineLimit(1)
                                }
                                Text(formatDate(session.updatedAt))
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("\(session.messages.count) 条记录")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                                
                                HStack(spacing: 2) {
                                    Image(systemName: "memorychip")
                                    Text("\(formatTokens(HistoryExportBridge.estimateSessionTokens(session))) T")
                                }
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(selectedLibraryFilter == .active ? .orange : .purple)
                            }
                        }
                        .padding(.vertical, 6)
                        .tag(session.id)
                        .contextMenu {
                            Button("在主窗口加载此对话") { AiChatStore.shared.loadSession(session) }
                            Button("重命名") { startEditing(session) }
                            Divider()
                            Button("删除此记录", role: .destructive) { withAnimation { historyManager.deleteSession(id: session.id) } }
                        }
                    }
                }
                .listStyle(.sidebar)
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
                .scrollContentBackground(.hidden)
                .forceHideScrollbars()
                
                // 右侧栏：详情预览
                ZStack {
                    VisualEffectView(material: .sidebar, blendingMode: .behindWindow).ignoresSafeArea()
                    
                    if let selectedID = selectedSessionID,
                       let session = historyManager.sessions.first(where: { $0.id == selectedID }) {
                        
                        VStack(spacing: 0) {
                            HStack {
                                Image(systemName: "message.fill").foregroundColor(.blue)
                                Text(session.title).font(.system(size: 14, weight: .bold))
                                
                                Text("累计负荷: \(formatTokens(HistoryExportBridge.estimateSessionTokens(session))) Tokens")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Color.orange.opacity(0.12))
                                    .cornerRadius(6)
                                    .padding(.leading, 8)
                                
                                Spacer()
                                
                                if !(session.isArchived ?? false) {
                                    let isArchiving = historyManager.archivingSessionIDs.contains(session.id)
                                    
                                    Button {
                                        Task {
                                            let activeModel = AiChatStore.shared.currentAgent.baseModel
                                            await historyManager.archiveAndReflectSession(id: session.id, model: activeModel)
                                            withAnimation { selectedSessionID = nil }
                                        }
                                    } label: {
                                        HStack(spacing: 6) {
                                            if isArchiving {
                                                ProgressView()
                                                    .controlSize(.small)
                                                    .scaleEffect(0.7)
                                            } else {
                                                Image(systemName: "brain.head.profile.fill")
                                            }
                                            Text(isArchiving ? "正在提炼经验..." : "归档并提炼经验")
                                        }
                                        .font(.system(size: 12, weight: .bold))
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(isArchiving ? .secondary : .purple)
                                    .disabled(isArchiving)
                                    .help(isArchiving ? "大模型正在深层神经网络中复盘、推演此剧本，请稍候..." : "激活大模型神经元复盘机制，深度提炼全局开发习惯或避坑指南并归入资产库")
                                } else {
                                    Button {
                                        historyManager.unarchiveSession(id: session.id)
                                        withAnimation { selectedSessionID = nil }
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "tray.and.arrow.up.fill")
                                            Text("移出到活跃库").font(.system(size: 11, weight: .bold))
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(.green)
                                    .help("【核心资产流转】：重置此会话的归档常识烙印，将其释放回「📱 活跃对话」列表池中。")
                                }
                                
                                Button {
                                    HistoryExportBridge.exportSessionToFile(session: session)
                                } label: {
                                    Label("导出文本", systemImage: "square.and.arrow.up").font(.system(size: 11))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                                .disabled(historyManager.archivingSessionIDs.contains(session.id))
                                
                                Button("继续这段对话") {
                                    AiChatStore.shared.loadSession(session)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(historyManager.archivingSessionIDs.contains(session.id))
                            }
                            .padding(16).background(.ultraThinMaterial)
                            
                            Divider()
                            
                            ScrollView {
                                LazyVStack(spacing: 16) {
                                    ForEach(session.messages) { msg in
                                        messageBubbleView(msg: msg, sessionID: session.id)
                                    }
                                }
                                .padding(20)
                            }
                            .scrollContentBackground(.hidden)
                            .forceOverlayScrollbars()
                        }
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 44)).foregroundStyle(.tertiary)
                            Text("选择左侧特定资产块以预览、更正或下发全景归档指令").foregroundColor(.secondary).font(.system(size: 13))
                        }
                    }
                }
            }
        }
        .onChange(of: selectedLibraryFilter) { _, _ in
            selectedSessionID = nil
            editingMessageID = nil
            editingMessageText = ""
        }
    }
    
    @ViewBuilder
    private func messageBubbleView(msg: SavedChatMessage, sessionID: UUID) -> some View {
        HStack(alignment: .top) {
            if msg.isUser { Spacer(minLength: 40) }
            
            VStack(alignment: msg.isUser ? .trailing : .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if !msg.isUser {
                        Text("AI")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary)
                        
                        if !msg.skillLogs.isEmpty {
                            Text("调用了 \(msg.skillLogs.count) 个底层工具")
                                .font(.system(size: 10))
                                .foregroundColor(.purple)
                        }
                    } else {
                        Text("你")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    
                    if editingMessageID != msg.id && !historyManager.archivingSessionIDs.contains(sessionID) {
                        HStack(spacing: 6) {
                            Button {
                                editingMessageText = msg.text
                                withAnimation(.spring()) { editingMessageID = msg.id }
                            } label: {
                                Image(systemName: "pencil.circle.fill").foregroundColor(.blue.opacity(0.7)).font(.system(size: 13))
                            }.buttonStyle(.plain).help("修正历史语境")
                            
                            Button {
                                let pasteboard = NSPasteboard.general
                                pasteboard.clearContents()
                                pasteboard.setString(msg.text, forType: .string)
                                ___updateIslandNotice(text: "已复制到剪贴板", icon: "doc.on.clipboard")
                            } label: {
                                Image(systemName: "doc.on.clipboard.fill").foregroundColor(.secondary.opacity(0.8)).font(.system(size: 11))
                            }.buttonStyle(.plain).help("拷贝正文")
                            
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    historyManager.deleteMessage(sessionID: sessionID, messageID: msg.id)
                                }
                            } label: {
                                Image(systemName: "trash.circle.fill").foregroundColor(.red.opacity(0.7)).font(.system(size: 13))
                            }.buttonStyle(.plain).help("永久抹除此行")
                        }
                    }
                }
                .padding(.horizontal, 4)
                
                if editingMessageID == msg.id {
                    VStack(alignment: .trailing, spacing: 8) {
                        MacCodeEditor(text: $editingMessageText, language: .builtin)
                            .frame(minHeight: 80, maxHeight: 300)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue.opacity(0.4), lineWidth: 1))
                        
                        HStack(spacing: 12) {
                            Button("取消") { withAnimation(.spring()) { editingMessageID = nil } }
                                .buttonStyle(.plain).foregroundColor(.secondary)
                            Button("确认修改") {
                                let newText = editingMessageText.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !newText.isEmpty {
                                    historyManager.updateMessageText(sessionID: sessionID, messageID: msg.id, newText: newText)
                                }
                                withAnimation(.spring()) { editingMessageID = nil }
                            }.buttonStyle(.borderedProminent).tint(.blue).controlSize(.small)
                        }
                    }
                    .padding(12)
                    .background(Color(NSColor.windowBackgroundColor))
                    .cornerRadius(12)
                    .shadow(color: Color.black.opacity(0.08), radius: 5, y: 2)
                    
                } else {
                    VStack(alignment: msg.isUser ? .trailing : .leading, spacing: 10) {
                        if let b64Images = msg.imageB64Strings, !b64Images.isEmpty {
                            HStack(spacing: 6) {
                                if msg.isUser { Spacer(minLength: 0) }
                                ForEach(b64Images, id: \.self) { b64String in
                                    if let data = Data(base64Encoded: b64String), let nsImg = NSImage(data: data) {
                                        Image(nsImage: nsImg)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 72, height: 72)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(msg.isUser ? Color.white.opacity(0.25) : Color.primary.opacity(0.12), lineWidth: 1))
                                            .onTapGesture {
                                                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
                                                if let tiff = nsImg.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let pngData = bitmap.representation(using: .png, properties: [:]) {
                                                    try? pngData.write(to: tempURL, options: .atomic)
                                                    NSWorkspace.shared.open(tempURL)
                                                }
                                            }
                                    }
                                }
                                if !msg.isUser { Spacer(minLength: 0) }
                            }
                        }
                        
                        if let urlStrings = msg.fileURLStrings, !urlStrings.isEmpty {
                            VStack(alignment: msg.isUser ? .trailing : .leading, spacing: 4) {
                                ForEach(urlStrings, id: \.self) { urlStr in
                                    if let url = URL(string: urlStr) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "doc.fill")
                                                .foregroundColor(msg.isUser ? .white.opacity(0.85) : .blue)
                                                .font(.system(size: 11))
                                            Text(url.lastPathComponent)
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundColor(msg.isUser ? .white : .primary)
                                                .lineLimit(1)
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(msg.isUser ? Color.white.opacity(0.12) : Color(NSColor.controlBackgroundColor))
                                        .cornerRadius(6)
                                        .onTapGesture { NSWorkspace.shared.open(url) }
                                    }
                                }
                            }
                        }
                        
                        if !msg.text.isEmpty {
                            Text(msg.text)
                                .font(.system(size: 13))
                                .foregroundColor(msg.isUser ? .white : .primary)
                                .lineSpacing(4)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(msg.isUser ? Color.blue.opacity(0.85) : Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: Color.black.opacity(0.02), radius: 1, y: 1)
                    .textSelection(.enabled)
                }
            }
            if !msg.isUser { Spacer(minLength: 40) }
        }
    }
    
    private func startEditing(_ session: ChatSession) {
        editTitleText = session.title
        editingSessionID = session.id
    }
    
    private func saveTitleEdit(for id: UUID) {
        let cleanTitle = editTitleText.trimmingCharacters(in: .whitespaces)
        if !cleanTitle.isEmpty { historyManager.updateSessionTitle(id: id, newTitle: cleanTitle) }
        editingSessionID = nil
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    private func formatTokens(_ count: Int) -> String {
        if count >= 1000 { return String(format: "%.1fk", Double(count) / 1000.0) }
        return "\(count)"
    }
}
