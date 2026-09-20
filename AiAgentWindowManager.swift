//////////////////////////////////////////////////////////////////
// 文件名：AiAgentWindowManager.swift
// 文件说明：macOS 14+ AI智能体工作台
// 代码要求：请保证代码的逻辑和完整性，保留代码中的所有注释内容
// 核心解构架构拓扑 (Domain-Driven Architecture):
// 1. 基于 ZStack 几何重映射架构，彻底解决推挤/缩回模式下的换行重排卡顿
// 2. 适配 Swift 6：添加 @MainActor 隔离，解决 AgentViewModel 初始化并发报错
// 3. 架构解耦修复：向 SkillManagementPanel 正确传递 agentVM.skillManager，修复类型不匹配错误
//////////////////////////////////////////////////////////////////

import SwiftUI
import AppKit

// MARK: - ==================== 1. 配置项定义 ====================

enum ConfigTab: Int, CaseIterable, Identifiable {
    case agents = 0
    case models = 1
    case skills = 2
    case mcp = 3
    case knowledge = 4
    case memory = 5
    case automation = 6
    case history = 8
    case logs = 9
    case persona = 10
    
    var id: Int { self.rawValue }
    
    var icon: String {
        switch self {
        case .agents: return "person.crop.square.fill"
        case .persona: return "theatermasks.fill"
        case .models: return "server.rack"
        case .skills: return "wrench.and.screwdriver.fill"
        case .mcp: return "network.badge.shield.half.filled"
        case .knowledge: return "books.vertical.fill"
        case .memory: return "brain.head.profile"
        case .automation: return "bolt.badge.automatic.fill"
        case .history: return "clock.arrow.2.circlepath"
        case .logs: return "list.bullet.rectangle"
        }
    }
    
    var title: String {
        switch self {
        case .agents: return "智能体"
        case .persona: return "数字分身"
        case .models: return "模型引擎"
        case .skills: return "技能链"
        case .mcp: return "MCP"
        case .knowledge: return "知识库"
        case .memory: return "长效记忆"
        case .automation: return "自动化"
        case .history: return "对话记录"
        case .logs: return "运行日志"
        }
    }
}

// MARK: - ==================== 2. 融合工作台主视图 (几何隔离调优版) ====================

@MainActor
struct AiWorkspaceView: View {
    // 统一使用全局单例门面，杜绝局部多实例内存不同步导致的技能勾选丢失
    private var agentVM: AgentViewModel { AgentManager.shared.agentVM }
    private var knowledgeVM: KnowledgeViewModel { AgentManager.shared.knowledgeVM }
    
    // 控制当前展开的配置面板，nil 表示收起
    @State private var activeTab: ConfigTab? = nil
    
    // 持久化用户的面板展开偏好（true = 浮动覆盖，false = 向右推挤）
    @AppStorage("isConfigPanelFloating") private var isFloatingMode: Bool = true
    
    // 持久化用户拖拽调整的配置面板宽度
    @AppStorage("configPanelWidth") private var configPanelWidth: Double = 780
    
    var body: some View {
        GeometryReader { geometry in
            let totalWidth = geometry.size.width
            let sidebarWidth: CGFloat = 64
            let currentPanelWidth = (activeTab != nil) ? CGFloat(configPanelWidth) : 0
            
            ZStack(alignment: .leading) {
                
                // 1. 右侧主内容：主显示 AI 对话
                AiChatView(knowledgeVM: knowledgeVM, agentVM: agentVM)
                    // 物理 Frame 锁定在可用主视口，通过 padding 实现 GPU 硬件级无损平移
                    .frame(
                        width: max(400, totalWidth - sidebarWidth - (!isFloatingMode ? currentPanelWidth : 0)),
                        height: geometry.size.height
                    )
                    .padding(.leading, sidebarWidth + (!isFloatingMode ? currentPanelWidth : 0))
                    .animation(.none, value: activeTab) // 断绝隐式动画污染
                    .zIndex(0)
                
                // 2. 向右推挤模式 (Split Mode) 专属独立视口容器
                // 容器起点严格锁定在 sidebarWidth 右侧，并在该局部视口内执行 clipped()。
                // 彻底杜绝 .transition(.move(edge: .leading)) 滑动时穿越 0~64pt 导轨区域造成视觉重叠。
                if !isFloatingMode {
                    ZStack(alignment: .leading) {
                        if let tab = activeTab {
                            FloatingConfigPanel(
                                tab: tab,
                                agentVM: agentVM,
                                knowledgeVM: knowledgeVM,
                                isFloatingMode: false,
                                onClose: closePanel
                            )
                            .frame(width: CGFloat(configPanelWidth), height: geometry.size.height)
                            .transition(.move(edge: .leading))
                            .zIndex(1)
                            
                            ResizableDivider(
                                panelWidth: $configPanelWidth,
                                accentColor: .blue,
                                showHandle: true,
                                onDoubleClick: {
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                                        closePanel()
                                    }
                                }
                            )
                            .padding(.leading, CGFloat(configPanelWidth) - 8)
                            .zIndex(2)
                        }
                    }
                    .frame(width: max(0, totalWidth - sidebarWidth), height: geometry.size.height, alignment: .leading)
                    .clipped()
                    .offset(x: sidebarWidth)
                    .zIndex(1)
                }
                
                // 3. 浮动覆盖模式 (Overlay Mode)
                if isFloatingMode, let tab = activeTab {
                    // 背景轻遮罩：点击空白处收起
                    Color.black.opacity(0.001)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onTapGesture { closePanel() }
                        .zIndex(2)
                    
                    FloatingConfigPanel(
                        tab: tab,
                        agentVM: agentVM,
                        knowledgeVM: knowledgeVM,
                        isFloatingMode: true,
                        onClose: closePanel
                    )
                    .frame(maxWidth: 800)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .padding(.leading, sidebarWidth + 10)
                    .padding(.vertical, 32)
                    .shadow(color: Color.black.opacity(0.2), radius: 25, x: 10, y: 5)
                    .zIndex(3)
                }
                
                // 4. 最左侧：垂直图标导轨 (刚性锁死在最顶层，尺寸固定不被压缩)
                SideRailView(activeTab: $activeTab, isFloatingMode: $isFloatingMode)
                    .frame(width: sidebarWidth)
                    .fixedSize(horizontal: true, vertical: false)
                    .zIndex(4)
            }
            .frame(width: totalWidth, height: geometry.size.height)
            .clipped()
        }
        .background(
            VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
        // 丝滑阻尼弹簧动画曲线
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: activeTab)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: isFloatingMode)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: configPanelWidth)
    }
    
    private func closePanel() {
        activeTab = nil
    }
}

// MARK: - ==================== 可拖拽的调整分割线 ====================

@MainActor
struct ResizableDivider: View {
    @Binding var panelWidth: Double
    var accentColor: Color = .blue
    var showHandle: Bool = true
    var onDoubleClick: (() -> Void)? = nil // MARK: - [Added] 双击回调
    
    @State private var dragStartWidth: Double? = nil
    @State private var isHovered: Bool = false
    @State private var isDragging: Bool = false
    
    var body: some View {
        ZStack {
            // 1. 视觉线条：渐变虚化与交互高亮
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            dividerColor.opacity(0.1),
                            dividerColor,
                            dividerColor,
                            dividerColor.opacity(0.1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: (isHovered || isDragging) ? 2 : 1)
                .shadow(color: (isHovered || isDragging) ? accentColor.opacity(0.3) : .clear, radius: 3)
            
            // 2. 居中抓手指示胶囊
            if showHandle {
                Capsule()
                    .fill((isHovered || isDragging) ? accentColor : Color(NSColor.separatorColor))
                    .frame(width: (isHovered || isDragging) ? 4 : 3, height: 28)
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(0.08), radius: 2, y: 1)
            }
            
            // 3. 隐形宽幅交互区
            Color.black.opacity(0.0001)
                .frame(width: 16)
        }
        .frame(width: 16)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    onDoubleClick?()
                }
        )
        // 鼠标悬停指针控制
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.18)) {
                self.isHovered = hovering
            }
            DispatchQueue.main.async {
                if hovering || self.isDragging {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
        // 拖拽宽度调节
        .gesture(
            DragGesture(minimumDistance: 0.1)
                .onChanged { value in
                    if dragStartWidth == nil {
                        dragStartWidth = panelWidth
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isDragging = true
                        }
                    }
                    
                    if let startWidth = dragStartWidth {
                        let newWidth = startWidth + Double(value.translation.width)
                        panelWidth = max(450, min(newWidth, 1200))
                    }
                }
                .onEnded { _ in
                    dragStartWidth = nil
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isDragging = false
                    }
                    if !isHovered {
                        NSCursor.pop()
                    }
                }
        )
    }
    
    private var dividerColor: Color {
        if isDragging {
            return accentColor
        } else if isHovered {
            return accentColor.opacity(0.8)
        } else {
            return Color(NSColor.separatorColor).opacity(0.65)
        }
    }
}

// MARK: - ==================== 3. 垂直侧边图标导轨 (优化点击热区版) ====================

@MainActor
struct SideRailView: View {
    @Binding var activeTab: ConfigTab?
    @Binding var isFloatingMode: Bool
    
    // 引入对全局配置的显式观测状态，确保菜单勾选状态实时响应
    @State private var showTimeline: Bool = ConfigManager.shared.app.generalConfig.showSkillTimeline
    @State private var sortByFrequency: Bool = ConfigManager.shared.app.generalConfig.historySortByFrequency
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部间距
            Spacer().frame(height: 8)
            
            // 中间 Tab 按钮列表
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(ConfigTab.allCases) { tab in
                        Button(action: {
                            if activeTab != tab {
                                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                            }
                            
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) {
                                if activeTab == tab {
                                    activeTab = nil
                                } else {
                                    activeTab = tab
                                }
                            }
                        }) {
                            VStack(spacing: 4) {
                                Image(systemName: tab.icon)
                                    .font(.system(size: 17, weight: .semibold))
                                Text(tab.title)
                                    .font(.system(size: 9.5, weight: .medium))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            .frame(width: 50, height: 44)
                            .foregroundColor(activeTab == tab ? .white : .secondary)
                            .contentShape(Rectangle())
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(activeTab == tab ? Color.blue : Color.clear)
                                    .opacity(activeTab == tab ? 1.0 : 0)
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help(tab.title)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
            }
            .forceHideScrollbars()
            
            Divider()
                .opacity(0.4)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            
            // 底部设置菜单：锚定在导轨底端
            Menu {
                Button("通用设置...") { /* 后续添加的配置 */ }
                Button("模型引擎") { /* 后续添加的配置 */ }
                
                Divider()
                
                Menu("面板展开方式") {
                    Picker("布局偏好", selection: $isFloatingMode) {
                        ImgLabel("浮动覆盖模式 (Overlay)", systemImage: "uiwindow.split.2x1").tag(true)
                        ImgLabel("向右推挤模式 (Split)", systemImage: "sidebar.left").tag(false)
                    }
                    .pickerStyle(.inline)
                }
                
                Button(action: {
                    showTimeline.toggle()
                    ConfigManager.shared.app.generalConfig.showSkillTimeline = showTimeline
                    ConfigManager.shared.saveConfig()
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                }) {
                    HStack {
                        Text("AI对话气泡显示技能链时间轴")
                        if showTimeline {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                
                Button(action: {
                    sortByFrequency.toggle()
                    ConfigManager.shared.app.generalConfig.historySortByFrequency = sortByFrequency
                    ConfigManager.shared.saveConfig()
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                }) {
                    HStack {
                        Text("历史对话记录按使用频率排序")
                        if sortByFrequency { Image(systemName: "checkmark") }
                    }
                }
                
                Divider()
                Button("帮助") { /* 预留 */ }
                
            } label: {
                VStack {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 17))
                        .foregroundColor(.secondary)
                }
                .frame(width: 50, height: 40)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("系统设置与布局偏好")
            .padding(.bottom, 12)
        }
        .frame(width: 64)
        .background(Color.clear)
        .overlay(
            VerticalModernDivider(color: Color(NSColor.separatorColor), opacity: 0.8, width: 1),
            alignment: .trailing
        )
        .onAppear {
            // 确保每次打开菜单时与最新配置对齐
            self.showTimeline = ConfigManager.shared.app.generalConfig.showSkillTimeline
        }
    }
}

// MARK: - ==================== 4. 动态配置面板包装容器 (沉浸式无头精简版) ====================

@MainActor
struct FloatingConfigPanel: View {
    let tab: ConfigTab
    let agentVM: AgentViewModel
    let knowledgeVM: KnowledgeViewModel
    let isFloatingMode: Bool
    let onClose: () -> Void
    
    // 内部加载防抖哨兵
    @State private var isContentReady: Bool = false
    
    // 模块专属主题色映射
    private var tabTheme: (color: Color, gradient: [Color]) {
        switch tab {
        case .agents: return (.blue, [Color.blue, Color.cyan])
        case .persona: return (.purple, [Color.purple, Color.pink])
        case .models: return (.indigo, [Color.indigo, Color.blue])
        case .skills: return (.orange, [Color.orange, Color.yellow])
        case .mcp: return (.purple, [Color.purple, Color(hex: "#00E676")])
        case .knowledge: return (.cyan, [Color.cyan, Color.blue])
        case .memory: return (.pink, [Color.pink, Color.purple])
        case .automation: return (.yellow, [Color.orange, Color.red])
        case .history: return (.green, [Color.green, Color.mint])
        case .logs: return (.gray, [Color.secondary, Color.primary.opacity(0.6)])
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 💡 遵照用户需求：已彻底移除冗余的头部面板，将垂直空间释放给子功能模块，
            // 収缩/展开操作统一交由左侧垂直侧边图标导轨（再次点击当前图标即可快速收缩）。
            
            // 内容区域：动态平滑按需懒加载
            ZStack {
                if isContentReady {
                    Group {
                        switch tab {
                        case .agents:
                            AgentProfilesPanel(agentVM: agentVM, knowledgeVM: knowledgeVM)
                        case .persona:
                            PersonaManagementPanel(manager: .shared)
                        case .models:
                            AiModelConfigPanel()
                        case .skills:
                            SkillManagementPanel(viewModel: agentVM.skillManager)
                        case .mcp:
                            MCPManagementPanel(viewModel: agentVM.skillManager)
                        case .knowledge:
                            KnowledgeBasePanel(viewModel: knowledgeVM)
                        case .memory:
                            MemoryManagementPanel()
                        case .automation:
                            AutomationManagementPanel()
                        case .history:
                            ChatHistoryManagementPanel()
                        case .logs:
                            LogPanelWindow()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.85)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(isFloatingMode ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.thinMaterial))
        .cornerRadius(isFloatingMode ? 14 : 0)
        .overlay(
            Group {
                if isFloatingMode {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    tabTheme.color.opacity(0.35),
                                    Color.white.opacity(0.1)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
            }
        )
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.easeIn(duration: 0.15)) {
                    isContentReady = true
                }
            }
        }
        .onChange(of: tab) { _, _ in
            isContentReady = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.easeIn(duration: 0.12)) {
                    isContentReady = true
                }
            }
        }
    }
}

// MARK: - ==================== 5. Window Manager 适配 ====================

@MainActor
public class AiAgentWindowManager: NSObject, NSWindowDelegate {
    public static let shared = AiAgentWindowManager()
    private var window: NSWindow?
    var isVisible: Bool { return window != nil }
    private override init() { super.init() }
    
    public func show() {
        if let existingWindow = window {
            if existingWindow.isMiniaturized { existingWindow.deminiaturize(nil) }
            existingWindow.makeKeyAndOrderFront(nil)
            existingWindow.orderFrontRegardless()
            if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
            return
        }
        
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        
        let newWindow = NSWindow(
            contentRect: visibleFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        newWindow.title = "AI 智能体工作台"
        newWindow.contentView = NSHostingView(rootView: AiWorkspaceView())
        
        newWindow.minSize = NSSize(width: 960, height: 620)
        
        newWindow.setFrame(visibleFrame, display: true)
        newWindow.setFrameAutosaveName("LinTools_CombinedAIWorkspace_Window")
        
        newWindow.isOpaque = false
        newWindow.backgroundColor = .clear
        newWindow.hasShadow = true
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self
        newWindow.titlebarAppearsTransparent = true
        newWindow.titleVisibility = .hidden
        
        self.window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        MainWindowManager.syncDockIconPolicy()
    }
    
    public func windowWillClose(_ notification: Notification) {
        window = nil
        MainWindowManager.syncDockIconPolicy()
    }
}

// MARK: - ==================== 6. 辅助工具类 (Swift 6 严格模式向下兼容) ====================

/// 🛠️ 解决 SwiftUI 在特定低版本 macOS 14 编译环境中将原生 Label 当作不可变静态子树引起的渲染异常
struct ImgLabel: View {
    let title: String
    let systemImage: String
    
    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title)
        }
    }
}
