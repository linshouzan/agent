//////////////////////////////////////////////////////////////////
// 文件名：ChatHistoryManager.swift
// 文件说明：适用于 macOS 14+ 的对话历史记录综合管理与多维资产归档中心 (Swift 6 Ready)
//
// 核心解构架构拓扑 (Domain-Driven Architecture):
// ├── 1. HistoryModels            : 归档库分类枚举 (LibraryFilter) 与 ChatSession 实体自描述契约
// ├── 2. HistoryStorageEngine     : 基于 DatabaseRecordConvertible 统一网关的后台异步读写引擎
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
    
    // MARK: - 通过通用数据网关全量载入历史会话
    static func loadFromDisk() -> [ChatSession] {
        return LocalDatabaseManager.shared.loadAll(orderBy: "updated_at DESC")
    }
    
    // MARK: - 通过通用数据网关异步保存单条会话
    static func persistSingleSessionAsync(_ session: ChatSession) {
        Task.detached(priority: .background) {
            LocalDatabaseManager.shared.save(session)
        }
    }
    
    // MARK: - 通过通用数据网关异步删除单条会话
    static func deleteSessionAsync(id: UUID) {
        Task.detached(priority: .background) {
            LocalDatabaseManager.shared.delete(ChatSession.self, id: id.uuidString)
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

// MARK: - 升级为现代 @Observable @MainActor 响应式状态机
@Observable
@MainActor
final class ChatHistoryManager: Sendable {
    static let shared = ChatHistoryManager()
    
    var sessions: [ChatSession] = []
    
    /// 后台潜意识全景反思的会话 ID 并发追踪锁
    var archivingSessionIDs: Set<UUID> = []
    
    private init() {
        loadSessions()
    }
    
    func loadSessions() {
        self.sessions = HistoryStorageEngine.loadFromDisk()
    }
    
    func saveSession(
        id: UUID,
        title: String,
        agentID: UUID,
        messages: [ChatMessage],
        personaID: UUID? = nil,
        blackboardPlan: String? = nil,
        scratchpad: String? = nil
    ) {
        let savedMsgs = messages.map { $0.toSaved() }
        let sessionToPersist: ChatSession
        
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].messages = savedMsgs
            sessions[idx].updatedAt = Date()
            sessions[idx].agentID = agentID
            sessions[idx].personaID = personaID
            if !title.isEmpty { sessions[idx].title = title }
            
            if let plan = blackboardPlan { sessions[idx].blackboardPlan = plan }
            if let pad = scratchpad { sessions[idx].scratchpad = pad }
            
            sessionToPersist = sessions[idx]
        } else {
            let newSession = ChatSession(
                id: id,
                title: title.isEmpty ? "新对话" : title,
                updatedAt: Date(),
                agentID: agentID,
                messages: savedMsgs,
                activatedPrivateQAIDs: [],
                isArchived: false,
                archiveCategory: "常规会话",
                personaID: personaID,
                blackboardPlan: blackboardPlan,
                scratchpad: scratchpad
            )
            sessions.insert(newSession, at: 0)
            sessionToPersist = newSession
        }
        
        // 单会话毫秒级落盘至 SQLite
        HistoryStorageEngine.persistSingleSessionAsync(sessionToPersist)
    }
    
    func updateSessionTitle(id: UUID, newTitle: String) {
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].title = newTitle
            HistoryStorageEngine.persistSingleSessionAsync(sessions[idx])
        }
    }
    
    func deleteSession(id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        if sessions[idx].isLocked == true {
            ___updateIslandNotice(text: "此会话已锁定，禁止删除", icon: "lock.fill")
            return
        }
        sessions.remove(at: idx)
        HistoryStorageEngine.deleteSessionAsync(id: id)
    }
    
    func deleteMessage(sessionID: UUID, messageID: UUID) {
        if let idx = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[idx].messages.removeAll { $0.id == messageID }
            HistoryStorageEngine.persistSingleSessionAsync(sessions[idx])
        }
    }
    
    func updateMessageText(sessionID: UUID, messageID: UUID, newText: String) {
        if let sIdx = sessions.firstIndex(where: { $0.id == sessionID }),
           let mIdx = sessions[sIdx].messages.firstIndex(where: { $0.id == messageID }) {
            sessions[sIdx].messages[mIdx].text = newText
            sessions[sIdx].updatedAt = Date()
            HistoryStorageEngine.persistSingleSessionAsync(sessions[sIdx])
        }
    }
    
    func unarchiveSession(id: UUID) {
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].isArchived = false
            sessions[idx].archiveCategory = "常规会话"
            sessions[idx].updatedAt = Date()
            
            HistoryStorageEngine.persistSingleSessionAsync(sessions[idx])
            
            NotificationCenter.default.post(name: NSNotification.Name("AgentProfilesExternallyUpdated"), object: nil)
            ___updateIslandNotice(text: "会话资产已成功恢复至活跃库", icon: "tray.and.arrow.up.fill")
        }
    }
    
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
        
        HistoryStorageEngine.persistSingleSessionAsync(sessions[idx])
        
        NotificationCenter.default.post(name: NSNotification.Name("AgentProfilesExternallyUpdated"), object: nil)
        ___updateIslandNotice(text: "该会话核心经验已提炼归档", icon: "brain.head.profile")
    }
    
    func toggleSessionLock(id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let currentlyLocked = sessions[idx].isLocked ?? false
        sessions[idx].isLocked = !currentlyLocked
        HistoryStorageEngine.persistSingleSessionAsync(sessions[idx])
        
        let statusText = !currentlyLocked ? "会话已锁定（防误删保护已开启）" : "会话已解除锁定"
        let icon = !currentlyLocked ? "lock.fill" : "lock.open.fill"
        ___updateIslandNotice(text: statusText, icon: icon)
    }
    
    // 纯净的原地提炼经验：沉淀长效记忆，不改变会话归档属性，不移出当前会话列表
    func extractExperienceOnly(id: UUID, model: String) async {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        
        archivingSessionIDs.insert(id)
        defer {
            withAnimation(.easeOut(duration: 0.2)) {
                self.archivingSessionIDs.remove(id)
            }
        }
        
        let session = sessions[idx]
        _ = await HistoryReflectionPipeline.reflectAndDeriveCategory(
            messages: session.messages,
            title: session.title,
            model: model
        )
        
        // 保持可见性：不设 isArchived = true，仅更新时间
        sessions[idx].updatedAt = Date()
        HistoryStorageEngine.persistSingleSessionAsync(sessions[idx])
        
        NotificationCenter.default.post(name: NSNotification.Name("AgentProfilesExternallyUpdated"), object: nil)
        ___updateIslandNotice(text: "该会话核心经验已成功提炼入库", icon: "brain.head.profile")
    }
}

// MARK: - ==================== 6. ChatHistoryUI Components (资产视窗与气泡呈现) ====================

@MainActor
struct ChatHistoryManagementPanel: View {
    @State private var historyManager = ChatHistoryManager.shared
    @State private var selectedSessionID: UUID?
    @State private var editingSessionID: UUID?
    @State private var editTitleText: String = ""
    
    @State private var editingMessageID: UUID? = nil
    @State private var editingMessageText: String = ""
    
    // 智能体过滤：nil 表示“全部智能体”
    @State private var selectedAgentFilterID: UUID? = nil
    
    // 删除二次确认状态
    @State private var sessionToDelete: ChatSession? = nil
    @State private var showDeleteConfirmAlert: Bool = false
    
    // 全部配置的智能体档案
    private var allAgentProfiles: [AgentProfile] {
        ConfigManager.shared.app.agentProfiles
    }
    
    // 根据当前选中的智能体过滤会话列表
    private var filteredSessions: [ChatSession] {
        if let agentID = selectedAgentFilterID {
            return historyManager.sessions.filter { $0.agentID == agentID }
        }
        return historyManager.sessions
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 1. 顶部控制栏
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("智能体对话资产库").font(.system(size: 15, weight: .bold))
                    Text("按智能体归拢管理历史对话。支持会话锁定防误删，可随时原地提炼长效经验。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(Color.clear)
            
            ModernDivider(style: .fade(0.18))
            
            // 2. 智能体分类选择滑道 (支持“全部”与各个智能体专属标签)
            agentFilterBarView
            
            Divider().opacity(0.4)
            
            // 3. 主分割视窗
            HSplitView {
                // 左侧栏：会话列表
                sessionListView
                    .frame(minWidth: 230, idealWidth: 270, maxWidth: 330)
                
                // 右侧栏：详情与对话流预览
                sessionDetailPreviewView
                    .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // 物理删除二次确认安全弹窗
        .alert("确认删除会话？", isPresented: $showDeleteConfirmAlert, presenting: sessionToDelete) { session in
            Button("确认删除", role: .destructive) {
                withAnimation {
                    historyManager.deleteSession(id: session.id)
                    if selectedSessionID == session.id {
                        selectedSessionID = nil
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: { session in
            Text("将彻底删除会话「\(session.title)」及其全部交互记录。此操作不可撤销。")
        }
        .onChange(of: selectedAgentFilterID) { _, _ in
            selectedSessionID = nil
            editingSessionID = nil
        }
    }
    
    // MARK: - 智能体横向分类导轨
    private var agentFilterBarView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                agentFilterPill(title: "全部智能体", icon: "square.grid.2x2.fill", targetID: nil, count: historyManager.sessions.count)
                
                ForEach(allAgentProfiles) { profile in
                    let count = historyManager.sessions.filter { $0.agentID == profile.id }.count
                    agentFilterPill(title: profile.name, icon: profile.icon, targetID: profile.id, count: count)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color.primary.opacity(0.015))
    }
    
    private func agentFilterPill(title: String, icon: String, targetID: UUID?, count: Int) -> some View {
        let isSelected = (selectedAgentFilterID == targetID)
        return Button(action: {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                selectedAgentFilterID = targetID
            }
        }) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? .blue : .secondary)
                
                Text(title)
                    .font(.system(size: 11.5, weight: isSelected ? .bold : .medium))
                    .foregroundColor(isSelected ? .blue : .primary.opacity(0.85))
                
                Text("\(count)")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(isSelected ? .blue : .secondary.opacity(0.7))
                    .padding(.horizontal, 4.5)
                    .padding(.vertical, 1)
                    .background(isSelected ? Color.blue.opacity(0.15) : Color.primary.opacity(0.05))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4.5)
            .background(isSelected ? Color.blue.opacity(0.10) : Color.primary.opacity(0.03))
            .cornerRadius(7)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isSelected ? Color.blue.opacity(0.35) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - 会话侧边列表
    private var sessionListView: some View {
        List(selection: $selectedSessionID) {
            if filteredSessions.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "tray.fill").font(.system(size: 24)).foregroundColor(.secondary.opacity(0.3))
                    Text("当前智能体暂无历史记录").font(.system(size: 11.5)).foregroundColor(.secondary.opacity(0.6))
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 160)
                .listRowBackground(Color.clear)
            }
            
            ForEach(filteredSessions) { session in
                let isLocked = session.isLocked ?? false
                let matchedAgent = allAgentProfiles.first(where: { $0.id == session.agentID })
                
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            if isLocked {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 9.5))
                                    .foregroundColor(.orange)
                                    .help("此会话已锁定，防止误删")
                            }
                            
                            if editingSessionID == session.id {
                                TextField("输入标题", text: $editTitleText)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { saveTitleEdit(for: session.id) }
                            } else {
                                Text(session.title)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .lineLimit(1)
                            }
                        }
                        
                        HStack(spacing: 6) {
                            Text(formatDate(session.updatedAt))
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            
                            if selectedAgentFilterID == nil, let agent = matchedAgent {
                                Text(agent.name)
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundColor(.blue.opacity(0.8))
                                    .padding(.horizontal, 4).padding(.vertical, 0.5)
                                    .background(Color.blue.opacity(0.08))
                                    .cornerRadius(3)
                            }
                        }
                    }
                    
                    Spacer(minLength: 4)
                    
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("\(session.messages.count) 条")
                            .font(.system(size: 9.5))
                            .foregroundColor(.secondary)
                        
                        Text("\(formatTokens(HistoryExportBridge.estimateSessionTokens(session))) T")
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .foregroundColor(.orange.opacity(0.85))
                    }
                }
                .padding(.vertical, 4)
                .tag(session.id)
                .contextMenu {
                    Button("在主窗口加载此对话") { AiChatStore.shared.loadSession(session) }
                    Button(isLocked ? "解除锁定" : "锁定此会话 (防误删)") {
                        historyManager.toggleSessionLock(id: session.id)
                    }
                    Button("重命名") { startEditing(session) }
                    Divider()
                    Button("删除此会话", role: .destructive) {
                        sessionToDelete = session
                        showDeleteConfirmAlert = true
                    }
                    .disabled(isLocked)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .forceHideScrollbars()
    }
    
    // MARK: - 右侧详情预览区
    private var sessionDetailPreviewView: some View {
        ZStack {
            VisualEffectView(material: .sidebar, blendingMode: .behindWindow).ignoresSafeArea()
            
            if let selectedID = selectedSessionID,
               let session = historyManager.sessions.first(where: { $0.id == selectedID }) {
                
                let isLocked = session.isLocked ?? false
                let isArchiving = historyManager.archivingSessionIDs.contains(session.id)
                
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: "message.fill").foregroundColor(.blue)
                        
                        Text(session.title)
                            .font(.system(size: 13.5, weight: .bold))
                            .lineLimit(1)
                        
                        if isLocked {
                            HStack(spacing: 3) {
                                Image(systemName: "lock.fill").font(.system(size: 9))
                                Text("已锁定").font(.system(size: 9.5, weight: .bold))
                            }
                            .foregroundColor(.orange)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.12))
                            .cornerRadius(4)
                        }
                        
                        Spacer()
                        
                        // 原地“提炼经验”按钮（不归档移出会话）
                        Button {
                            Task {
                                let activeModel = AiChatStore.shared.currentAgent.baseModel
                                await historyManager.extractExperienceOnly(id: session.id, model: activeModel)
                            }
                        } label: {
                            HStack(spacing: 5) {
                                if isArchiving {
                                    ProgressView().controlSize(.small).scaleEffect(0.7)
                                    Text("正在提炼...")
                                } else {
                                    Image(systemName: "brain.head.profile.fill")
                                    Text("提炼经验")
                                }
                            }
                            .font(.system(size: 11, weight: .bold))
                        }
                        .buttonStyle(.bordered)
                        .tint(.purple)
                        .disabled(isArchiving)
                        .help("提取对话中的关键开发经验与避坑心法并沉淀入记忆库，会话仍保留在当前列表")
                        
                        // 锁定 / 解锁切换按钮
                        Button {
                            historyManager.toggleSessionLock(id: session.id)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: isLocked ? "lock.fill" : "lock.open")
                                Text(isLocked ? "解锁" : "锁定")
                            }
                            .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .help(isLocked ? "解除锁定状态" : "锁定此会话以防止误删")
                        
                        Button {
                            HistoryExportBridge.exportSessionToFile(session: session)
                        } label: {
                            Label("导出", systemImage: "square.and.arrow.up").font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        
                        // 物理删除（已锁定状态禁用）
                        Button {
                            sessionToDelete = session
                            showDeleteConfirmAlert = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundColor(isLocked ? .secondary.opacity(0.3) : .red.opacity(0.85))
                        }
                        .buttonStyle(.bordered)
                        .disabled(isLocked)
                        .help(isLocked ? "会话已锁定，请先解锁后再删除" : "删除此会话")
                        
                        Button("继续对话") {
                            AiChatStore.shared.loadSession(session)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    
                    Divider()
                    
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            ForEach(session.messages) { msg in
                                messageBubbleView(msg: msg, sessionID: session.id)
                            }
                        }
                        .padding(16)
                    }
                    .scrollContentBackground(.hidden)
                    .forceOverlayScrollbars()
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(.tertiary)
                    Text("请在左侧选择会话以预览详情、提炼经验或锁定记录")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12.5))
                }
            }
        }
    }
    
    @ViewBuilder
    private func messageBubbleView(msg: SavedChatMessage, sessionID: UUID) -> some View {
        HStack(alignment: .top) {
            if msg.isUser { Spacer(minLength: 40) }
            
            VStack(alignment: msg.isUser ? .trailing : .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(msg.isUser ? "你" : "AI")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                    
                    if !msg.isUser && !msg.skillLogs.isEmpty {
                        Text("调用了 \(msg.skillLogs.count) 个底层工具")
                            .font(.system(size: 10))
                            .foregroundColor(.purple)
                    }
                    
                    if editingMessageID != msg.id {
                        HStack(spacing: 6) {
                            Button {
                                editingMessageText = msg.text
                                withAnimation(.spring()) { editingMessageID = msg.id }
                            } label: {
                                Image(systemName: "pencil.circle.fill").foregroundColor(.blue.opacity(0.7)).font(.system(size: 12))
                            }.buttonStyle(.plain).help("修正文本")
                            
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(msg.text, forType: .string)
                                ___updateIslandNotice(text: "已复制到剪贴板", icon: "doc.on.clipboard")
                            } label: {
                                Image(systemName: "doc.on.clipboard.fill").foregroundColor(.secondary.opacity(0.8)).font(.system(size: 10.5))
                            }.buttonStyle(.plain).help("拷贝")
                            
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    historyManager.deleteMessage(sessionID: sessionID, messageID: msg.id)
                                }
                            } label: {
                                Image(systemName: "trash.circle.fill").foregroundColor(.red.opacity(0.7)).font(.system(size: 12))
                            }.buttonStyle(.plain).help("删除该行")
                        }
                    }
                }
                .padding(.horizontal, 4)
                
                if editingMessageID == msg.id {
                    VStack(alignment: .trailing, spacing: 8) {
                        MacCodeEditor(text: $editingMessageText, language: .builtin)
                            .frame(minHeight: 80, maxHeight: 260)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue.opacity(0.4), lineWidth: 1))
                        
                        HStack(spacing: 10) {
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
                    .padding(10)
                    .background(Color(NSColor.windowBackgroundColor))
                    .cornerRadius(10)
                } else {
                    Text(msg.text)
                        .font(.system(size: 12.5))
                        .foregroundColor(msg.isUser ? .white : .primary)
                        .lineSpacing(3.5)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 10)
                        .background(msg.isUser ? Color.blue.opacity(0.85) : Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
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
