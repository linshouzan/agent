//////////////////////////////////////////////////////////////////
// 文件名：ChatHistoryManager.swift
// 文件说明：适用于 macOS 14+ 的对话历史记录综合管理与多维资产归档中心
// 代码要求：请保证代码的逻辑和完整性，保留代码中的所有注释内容
// 核心架构：
// 1. 资产双向流转：已熔铸标签完美重构为原生态冷绿发光质感的“移出到活跃库”动作按钮，赋予用户反向流转控制权。
// 2. Swift 6 神经断路保护：归档反思管道升级为传递 100% Sendable 的 SavedChatMessage 数组，彻底解决 NSImage 跨Actor隔离报错。
// 3. 异步防重上锁：引入 MainActor 线程安全的 archivingSessionIDs 状态锁，提炼时瞬间置灰并展现微小 Progress 菊花。
// 4. 环境柔性自愈：修正了老版本 URL 条件解包时的语法摩擦，气泡通知完全对齐回原生的 ___updateIslandNotice。
//////////////////////////////////////////////////////////////////

import SwiftUI
import UniformTypeIdentifiers
import Combine // 提供响应式数据流状态重绘的底层支撑

// MARK: - ==================== 1. 核心状态管理与神经元反思业务层 ====================

@MainActor
class ChatHistoryManager: ObservableObject {
    static let shared = ChatHistoryManager()
    
    @Published var sessions: [ChatSession] = []
    
    // 后台潜意识全景反思的会话 ID 并发追踪锁（利用 Set 保持 O(1) 级极速检索拦截）
    @Published var archivingSessionIDs: Set<UUID> = []
    
    private init() { loadSessions() }
    
    /// 从本地磁盘静默反序列化全量历史记录
    func loadSessions() {
        let optionalURL: URL? = ConfigManager.shared.chatHistoryFileName
        guard let url = optionalURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([ChatSession].self, from: data) else { return }
        self.sessions = decoded.sorted { $0.updatedAt > $1.updatedAt }
    }
    
    /// 将当前运行时会话增量同步至历史仓库
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
        persistToDisk()
    }
    
    func updateSessionTitle(id: UUID, newTitle: String) {
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].title = newTitle
            persistToDisk()
        }
    }
    
    func deleteSession(id: UUID) {
        sessions.removeAll { $0.id == id }
        persistToDisk()
    }
    
    func deleteMessage(sessionID: UUID, messageID: UUID) {
        if let idx = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[idx].messages.removeAll { $0.id == messageID }
            persistToDisk()
        }
    }
    
    func updateMessageText(sessionID: UUID, messageID: UUID, newText: String) {
        if let sIdx = sessions.firstIndex(where: { $0.id == sessionID }),
           let mIdx = sessions[sIdx].messages.firstIndex(where: { $0.id == messageID }) {
            sessions[sIdx].messages[mIdx].text = newText
            sessions[sIdx].updatedAt = Date()
            persistToDisk()
        }
    }
    
    // =================================================================
    // 🚀 反向流转动作：将已归档会话无损释放并归还活跃库池中
    // =================================================================
    /// 将指定资产从长期记忆库注销，重置状态位并回归至日常聊天活跃池中
    func unarchiveSession(id: UUID) {
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].isArchived = false
            sessions[idx].archiveCategory = "常规会话"
            sessions[idx].updatedAt = Date()
            
            persistToDisk()
            
            // 引导重绘全局 UI 面板状态并激发动态通知气泡
            NotificationCenter.default.post(name: NSNotification.Name("AgentProfilesExternallyUpdated"), object: nil)
            ___updateIslandNotice(text: "会话资产已成功恢复至活跃库", icon: "tray.and.arrow.up.fill")
        }
    }
    
    /// 脱离主并发轨道的安全磁盘异步持久化落盘
    private func persistToDisk() {
        let optionalURL: URL? = ConfigManager.shared.chatHistoryFileName
        guard let url = optionalURL else { return }
        let sessionsToSave = self.sessions
        Task.detached(priority: .background) {
            if let data = try? JSONEncoder().encode(sessionsToSave) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}

// MARK: - ==================== 2. 神经元反思资产正向划转扩展 ====================

extension ChatHistoryManager {
    // =================================================================
    // 🌌 全景多维反思收割引擎 (Subconscious Reflective Lifecycler)
    // =================================================================
    /// 触发会话终结结算，调用底层潜意识神经元反思核收割认知，并物理封锁该对话划归资产库
    @MainActor
    func archiveAndReflectSession(id: UUID, model: String) async {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        
        // 🚀 瞬间上锁：塞入追踪集合中，驱动上游 UI 瞬间置灰，拦截一切后续重复误触
        archivingSessionIDs.insert(id)
        
        // 🚀 终极生命周期防护线：利用 Swift 原生 defer 守卫机制
        // 无论后面的大模型网络请求是成功、还是超时破损，函数退出瞬间【必定】无条件解锁，恢复 UI 可点击态
        defer {
            withAnimation(.easeOut(duration: 0.2)) {
                archivingSessionIDs.remove(id)
            }
        }
        
        let session = sessions[idx]
        
        // 🌟 终极修复：直接投递完全符合 Sendable 契约的原始持久化 messages 数组 (纯 String 镜像资产)
        // 坚决不跨边界投递包含非 Sendable [NSImage] 的 ChatMessage 实体，完美自愈 Swift 6 Concurrency 地雷
        await MemoryManager.shared.observeAndExtractSession(messages: session.messages, model: model)
        
        // 3. 智能路由：基于会话文本特征自适应划分资产库门类
        let titleLower = session.title.lowercased()
        var derivedCategory = "经验资产"
        if titleLower.contains("bug") || titleLower.contains("报错") || titleLower.contains("修复") || titleLower.contains("❌") || titleLower.contains("error") {
            derivedCategory = "避坑心法"
        } else if titleLower.contains("习惯") || titleLower.contains("人设") || titleLower.contains("我是谁") || titleLower.contains("偏好") || titleLower.contains("称呼") {
            derivedCategory = "偏好画像"
        }
        
        // 4. 修改持久化物理状态位，打上永久固化资产标签
        sessions[idx].isArchived = true
        sessions[idx].archiveCategory = derivedCategory
        sessions[idx].updatedAt = Date()
        
        persistToDisk()
        
        // 5. 唤醒全局 UI 联动并激发气泡通知
        NotificationCenter.default.post(name: NSNotification.Name("AgentProfilesExternallyUpdated"), object: nil)
        ___updateIslandNotice(text: "该会话核心经验已提炼归档", icon: "brain.head.profile")
    }
}

// MARK: - ==================== 3. 界面呈现与多维资产管理视窗 ====================

// 历史对话综合管理面板 (设计师流光溢彩重构：分类切换滑道完全体)
@MainActor
struct ChatHistoryManagementPanel: View {
    @StateObject private var historyManager = ChatHistoryManager.shared
    @State private var selectedSessionID: UUID?
    @State private var editingSessionID: UUID?
    @State private var editTitleText: String = ""
    
    // 用于消息内容的内联修改草稿沙盒状态
    @State private var editingMessageID: UUID? = nil
    @State private var editingMessageText: String = ""
    
    // 🚀 归档库门类多维导航锚点状态机
    @State private var selectedLibraryFilter: LibraryFilter = .active
    
    enum LibraryFilter: String, CaseIterable, Identifiable {
        case active = "📱 活跃对话"
        case persona = "👤 偏好画像"
        case lesson = "💡 避坑心法"
        case asset = "📦 经验资产"
        
        var id: String { self.rawValue }
    }
    
    // 基于高阶函数在内存中直接对多级归档执行计算分流
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
            // 1. 现代化极客风顶部面板
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("全局历史会话与反思网络资产库").font(.system(size: 15, weight: .bold))
                    Text("安全持久化管理您的所有会话。已归档项已被大模型潜意识层归纳提炼，跨对话固化为永久常识。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) {
                    // 全量清空活跃库功能(预留)
                } label: { Label("清空活跃库", systemImage: "trash") }
                .buttonStyle(.bordered)
                .disabled(historyManager.sessions.filter { !($0.isArchived ?? false) }.isEmpty)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(Color.clear)
            
            ModernDivider(style: .fade(0.18))
            
            // 2. 一键弹流光分类切换道 (Premium Segmented Controller)
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
                // 左侧栏：联动智能分流的历史列表区
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
                                    Text("\(formatTokens(estimateSessionTokens(session))) T")
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
                
                // 右侧栏：细节视窗只读预览与全景交互提炼区
                ZStack {
                    VisualEffectView(material: .sidebar, blendingMode: .behindWindow).ignoresSafeArea()
                    
                    if let selectedID = selectedSessionID,
                       let session = historyManager.sessions.first(where: { $0.id == selectedID }) {
                        
                        VStack(spacing: 0) {
                            HStack {
                                Image(systemName: "message.fill").foregroundColor(.blue)
                                Text(session.title).font(.system(size: 14, weight: .bold))
                                
                                Text("累计负荷: \(formatTokens(estimateSessionTokens(session))) Tokens")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Color.orange.opacity(0.12))
                                    .cornerRadius(6)
                                    .padding(.leading, 8)
                                
                                Spacer()
                                
                                // 🚀 3. 产品交互流转：点击瞬间置灰上锁并展现菊花转轮，熔铸完毕后无损回流活跃池
                                if !(session.isArchived ?? false) {
                                    let isArchiving = historyManager.archivingSessionIDs.contains(session.id)
                                    
                                    Button {
                                        Task {
                                            let activeModel = AiChatStore.shared.currentAgent.baseModel
                                            await historyManager.archiveAndReflectSession(id: session.id, model: activeModel)
                                            withAnimation { selectedSessionID = nil } // 提炼完自动退场，净化卡片
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
                                    .tint(isArchiving ? .secondary : .purple) // 上锁置灰时从尊贵紫优雅退化为 secondary 冷灰
                                    .disabled(isArchiving) // 🌟 核心需求落实：物理锁死上游点击事件
                                    .help(isArchiving ? "大模型正在深层神经网络中复盘、推演此剧本，请稍候..." : "激活大模型神经元复盘机制，深度榨取全局开发习惯或避坑指南并归入资产库")
                                } else {
                                    // 🌟 核心需求落实：已熔铸标签物理升维为原生态冷绿发光反向回流动作按钮
                                    Button {
                                        historyManager.unarchiveSession(id: session.id)
                                        withAnimation { selectedSessionID = nil } // 反向划转成功后清空当前视窗
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "tray.and.arrow.up.fill")
                                            Text("移出到活跃库").font(.system(size: 11, weight: .bold))
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(.green) // 原生态冷绿发光质感
                                    .help("【核心资产流转】：物理重置此会话的归档常识烙印，将其无损释放回左侧的「📱 活跃对话」列表池中。")
                                }
                                
                                Button { exportSessionToText(session) } label: {
                                    Label("导出文本", systemImage: "square.and.arrow.up").font(.system(size: 11))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                                .disabled(historyManager.archivingSessionIDs.contains(session.id)) // 提炼时同步封锁导出
                                .help("将当前全量上下文及工具链痕迹整体导出为标准 .txt 开发档案")
                                
                                Button("继续这段对话") {
                                    AiChatStore.shared.loadSession(session)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(historyManager.archivingSessionIDs.contains(session.id)) // 提炼时同步封锁唤醒
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
            selectedSessionID = nil // 归档分类切换时强力重置选择点，避免布局越界坍塌
            editingMessageID = nil
            editingMessageText = ""
        }
    }
    
    // MARK: - 🎨 独立气泡组件 (多媒体素材与富文本自愈一体化完美排盘)
    @ViewBuilder
    private func messageBubbleView(msg: SavedChatMessage, sessionID: UUID) -> some View {
        HStack(alignment: .top) {
            if msg.isUser { Spacer(minLength: 40) }
            
            VStack(alignment: msg.isUser ? .trailing : .leading, spacing: 6) {
                // A. 顶部身份区与浮置动作连携条
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
                        Text("你") // 🌟 修复点：根据底层设计规范校准回原生的“你”
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
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(msg.text, forType: .string)
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
                
                // B. 输入修改的内联持久化沙盒控制
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
                    // C. 实体呈现层：收纳图片、胶囊文件、富文本于一体
                    VStack(alignment: msg.isUser ? .trailing : .leading, spacing: 10) {
                        
                        // 1. 历史图片瀑布流
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
                                                    try? pngData.write(to: tempURL)
                                                    NSWorkspace.shared.open(tempURL)
                                                }
                                            }
                                    }
                                }
                                if !msg.isUser { Spacer(minLength: 0) }
                            }
                        }
                        
                        // 2. 物理文件资产胶囊流
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
                        
                        // 3. 核心文本内容
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
    
    // MARK: - ⚙️ 统一基础辅助函数群
    
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
    
    private func estimateSessionTokens(_ session: ChatSession) -> Int {
        var totalTokens = 0
        for msg in session.messages {
            totalTokens += Int(Double(msg.text.count) * 1.5)
            for log in msg.skillLogs { totalTokens += Int(Double(log.argsJSON.count + log.resultOutput.count) * 1.5) }
        }
        return totalTokens
    }
    
    private func formatTokens(_ count: Int) -> String {
        if count >= 1000 { return String(format: "%.1fk", Double(count) / 1000.0) }
        return "\(count)"
    }
    
    private func formatFullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
    
    @MainActor
    private func exportSessionToText(_ session: ChatSession) {
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
}
