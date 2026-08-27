//////////////////////////////////////////////////////////////////
// 文件名：AutomationManager.swift
// 文件说明：适用于 macOS 14+ 的全局自动化引擎与触发器管理
// 核心架构：
// 1. 触发器引擎：定时、文件监控、App状态、剪贴板正则、快捷键、划词选中(AXUIElement)
// 2. 双轨执行路由：支持唤醒智能体 (Agent) 与 多技能流水线直调 (Skill Pipeline)
// 3. 上下文注入引擎：支持不同触发器类型专属的动态变量智能插入
// 4. 极客悬浮窗：动态标题反馈、原地 Loading 动画、合理避让选中词
// 5. 内存级日志中心：执行记录不落盘，退出即焚，轻量高效
// 🚀 本次重大升级：增加 Fn 键触发划词管控；全盘拥抱 Swift 6 Async/Await 彻底解决严格并发警告(MainActor isolation)；异步化剪贴板休眠防止UI阻塞
//////////////////////////////////////////////////////////////////

import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers
import CoreServices
import ApplicationServices

// MARK: - ==================== 1. 数据模型 ====================

public enum TriggerType: String, CaseIterable, Codable {
    case timer = "定时循环"
    case fileSystem = "文件夹监控"
    case appState = "应用状态"
    case systemBoot = "系统唤醒/解锁"
    case clipboardMatch = "剪贴板正则"
    case hotkey = "快捷键触发"
    case selectedTextMatch = "划词选中正则"

    var icon: String {
        switch self {
        case .timer: return "timer"
        case .fileSystem: return "folder.badge.gearshape"
        case .appState: return "macwindow"
        case .systemBoot: return "power"
        case .clipboardMatch: return "doc.on.clipboard"
        case .hotkey: return "keyboard"
        case .selectedTextMatch: return "character.cursor.ibeam"
        }
    }
}

public enum ActionType: String, CaseIterable, Codable {
    case callAgent = "唤醒智能体 (对话)"
    case callSkill = "静默调用技能 (后台)"
}

public enum ResultDisplayMode: String, CaseIterable, Codable {
    case none = "不显示"
    case island = "灵动岛通知"
    case dialog = "对话框显示"
    case floatingPanel = "划词下方显示"
}

public struct SkillAction: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var skillName: String
    public var shortName: String
    public var argsJSON: String
    
    public init(skillName: String, shortName: String, argsJSON: String) {
        self.skillName = skillName
        self.shortName = shortName
        self.argsJSON = argsJSON
    }
}

public struct AutomationRule: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    
    public var triggerType: TriggerType
    public var triggerConfig: [String: String]
    
    public var actionType: ActionType
    public var targetAgentID: UUID?
    public var taskPrompt: String
    
    public var targetSkills: [SkillAction]
    public var targetSkillName: String
    public var skillArgsJSON: String
    
    public var displayMode: ResultDisplayMode
    
    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        triggerType: TriggerType,
        triggerConfig: [String: String] = [:],
        actionType: ActionType = .callAgent,
        targetAgentID: UUID? = nil,
        taskPrompt: String = "",
        targetSkills: [SkillAction] = [],
        targetSkillName: String = "",
        skillArgsJSON: String = "{}",
        displayMode: ResultDisplayMode = .island
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.triggerType = triggerType
        self.triggerConfig = triggerConfig
        self.actionType = actionType
        self.targetAgentID = targetAgentID
        self.taskPrompt = taskPrompt
        self.targetSkills = targetSkills
        self.targetSkillName = targetSkillName
        self.skillArgsJSON = skillArgsJSON
        self.displayMode = displayMode
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "未知规则"
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        
        self.triggerType = try container.decodeIfPresent(TriggerType.self, forKey: .triggerType) ?? .selectedTextMatch
        self.triggerConfig = try container.decodeIfPresent([String: String].self, forKey: .triggerConfig) ?? [:]
        
        self.actionType = try container.decodeIfPresent(ActionType.self, forKey: .actionType) ?? .callAgent
        self.targetAgentID = try container.decodeIfPresent(UUID.self, forKey: .targetAgentID)
        self.taskPrompt = try container.decodeIfPresent(String.self, forKey: .taskPrompt) ?? ""
        
        self.targetSkills = try container.decodeIfPresent([SkillAction].self, forKey: .targetSkills) ?? []
        self.targetSkillName = try container.decodeIfPresent(String.self, forKey: .targetSkillName) ?? ""
        self.skillArgsJSON = try container.decodeIfPresent(String.self, forKey: .skillArgsJSON) ?? "{}"
        
        self.displayMode = try container.decodeIfPresent(ResultDisplayMode.self, forKey: .displayMode) ?? .island
    }
}

public struct AutomationRunLog: Identifiable {
    public let id = UUID()
    public let ruleId: UUID
    public let ruleName: String
    public let timestamp: Date
    public let inputContext: String
    public let result: String
    public let isError: Bool
}

// MARK: - ==================== 2. 动态模板渲染引擎 ====================

public struct TemplateEngine {
    public static func render(text: String, context: [String: Any]) -> String {
        var rendered = text
        if rendered.contains("{{clipboard}}") {
            let clipText = NSPasteboard.general.string(forType: .string) ?? ""
            rendered = rendered.replacingOccurrences(of: "{{clipboard}}", with: clipText)
        }
        if rendered.contains("{{front_app}}") {
            let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown App"
            rendered = rendered.replacingOccurrences(of: "{{front_app}}", with: appName)
        }
        if rendered.contains("{{datetime}}") {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            rendered = rendered.replacingOccurrences(of: "{{datetime}}", with: formatter.string(from: Date()))
        }
        for (key, value) in context {
            let strValue = String(describing: value)
            rendered = rendered.replacingOccurrences(of: "{{\(key)}}", with: strValue)
        }
        return rendered
    }
    
    public static func renderDictionary(dict: [String: Any], context: [String: Any]) -> [String: Any] {
        var result = dict
        for (key, value) in dict {
            if let strValue = value as? String {
                result[key] = render(text: strValue, context: context)
            } else if let subDict = value as? [String: Any] {
                result[key] = renderDictionary(dict: subDict, context: context)
            } else if let arrDict = value as? [[String: Any]] {
                result[key] = arrDict.map { renderDictionary(dict: $0, context: context) }
            } else if let arrStr = value as? [String] {
                result[key] = arrStr.map { render(text: $0, context: context) }
            }
        }
        return result
    }
}

// MARK: - ==================== 3. 极客微型交互与结果面板 ====================

struct MenuActionItem: Identifiable { let id = UUID(); let title: String; let action: () -> Void }
struct QuickActionHoverButton: View {
    let item: MenuActionItem; let isExecuting: Bool; let action: () -> Void; @State private var isHovered = false
    var body: some View {
        Button(action: { if !isExecuting { action() } }) {
            HStack(spacing: 4) {
                if isExecuting { ProgressView().controlSize(.small).scaleEffect(0.75) }
                Text(isExecuting ? "稍等..." : item.title).font(.system(size: 11, weight: .medium))
            }.foregroundColor((isHovered || isExecuting) ? .white : .primary).padding(.horizontal, 8).padding(.vertical, 4).background((isHovered || isExecuting) ? Color.accentColor : Color.clear).clipShape(Capsule()).contentShape(Capsule())
        }.buttonStyle(.plain).onHover { isHovered = $0 }
    }
}
struct QuickActionMenuView: View {
    let items: [MenuActionItem]; @State private var executingId: UUID? = nil
    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                if executingId == nil || executingId == item.id {
                    QuickActionHoverButton(item: item, isExecuting: executingId == item.id) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { executingId = item.id }
                        item.action()
                    }
                }
            }
        }.padding(3).background(VisualEffectView(material: .popover, blendingMode: .behindWindow).opacity(0.95)).clipShape(Capsule()).overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5)).shadow(color: Color.black.opacity(0.12), radius: 5, x: 0, y: 2).background(GeometryReader { geo in Color.clear.onChange(of: geo.size) { _, newSize in DispatchQueue.main.async { QuickActionPanelManager.shared.resizePanel(to: newSize) } } })
    }
}
struct QuickActionResultView: View {
    let title: String; let resultText: String; var onCopy: () -> Void; var onClose: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(title).font(.system(size: 10, weight: .bold)).foregroundColor(.secondary); Spacer(); Button(action: onCopy) { Image(systemName: "doc.on.doc").font(.system(size: 10)) }.buttonStyle(.plain); Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain) }
            ScrollView { Text(resultText).font(.system(size: 12)).foregroundColor(.primary).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxHeight: 200)
        }.padding(12).frame(width: 300).background(VisualEffectView(material: .popover, blendingMode: .behindWindow).opacity(0.98)).cornerRadius(12).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1), lineWidth: 0.5)).shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 5)
    }
}
@MainActor
class QuickActionPanelManager: NSObject {
    static let shared = QuickActionPanelManager(); private var panel: NSPanel?; private var clickMonitors: [Any] = []; private var notificationObservers: [NSObjectProtocol] = []; var panelFrame: NSRect? { return panel?.frame }; private var currentSessionID: UUID = UUID()
    func show(rules: [AutomationRule], context: [String: Any], at point: NSPoint) {
        hide(); let sessionID = UUID(); self.currentSessionID = sessionID; var items: [MenuActionItem] = []
        for rule in rules {
            if rule.actionType == .callAgent { items.append(MenuActionItem(title: rule.name) { var ctx = context; ctx["floatingSessionID"] = sessionID; AutomationEngine.shared.execute(rule: rule, context: ctx) }) } else { for skill in rule.targetSkills { let displayName = skill.shortName.isEmpty ? skill.skillName : skill.shortName; items.append(MenuActionItem(title: displayName) { var ctx = context; ctx["floatingSessionID"] = sessionID; AutomationEngine.shared.execute(rule: rule, specificSkill: skill, context: ctx) }) } }
        }
        guard !items.isEmpty else { return }; setupPanel(view: AnyView(QuickActionMenuView(items: items)), at: point)
    }
    func showResult(title: String, text: String, at point: NSPoint, sessionID: UUID?) {
        if let sid = sessionID, sid != currentSessionID { ___triggerBreathing(text: "静默执行完毕", icon: "checkmark.seal.fill"); DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { ___dynamicIslandEscape(isEscape: true) }; return }
        hide(); self.currentSessionID = UUID(); let resultView = QuickActionResultView(title: title, resultText: text, onCopy: { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); ___triggerBreathing(text: "结果已复制", icon: "doc.on.doc.fill"); DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { ___dynamicIslandEscape(isEscape: true) } }, onClose: { [weak self] in self?.hide() })
        setupPanel(view: AnyView(resultView), at: point)
    }
    func resizePanel(to size: CGSize) { guard let panel = panel else { return }; var frame = panel.frame; let oldWidth = frame.width; let oldHeight = frame.height; frame.size = size; frame.origin.x += (oldWidth - size.width) / 2.0; frame.origin.y += (oldHeight - size.height); panel.setFrame(frame, display: true, animate: true) }
    func hideIfSessionMatches(_ sessionID: UUID) { if currentSessionID == sessionID { hide() } }
    private func setupPanel(view: AnyView, at point: NSPoint) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false); panel.level = .popUpMenu; panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
        let hostingView = NSHostingView(rootView: view); panel.contentView = hostingView; let size = hostingView.fittingSize; panel.setContentSize(size)
        let x = point.x - size.width / 2; let y = point.y - size.height - 18; panel.setFrameOrigin(NSPoint(x: max(10, x), y: max(10, y))); panel.alphaValue = 0; panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in context.duration = 0.15; panel.animator().alphaValue = 1.0 }; self.panel = panel
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in if let p = self?.panel, event.window == p { return event }; self?.hide(); return event }
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] _ in Task { @MainActor in self?.hide() } }
        if let l = local { clickMonitors.append(l) }; if let g = global { clickMonitors.append(g) }
        let resignActiveObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.hide() }; notificationObservers.append(resignActiveObserver)
    }
    func hide() { panel?.close(); panel = nil; clickMonitors.forEach { NSEvent.removeMonitor($0) }; clickMonitors.removeAll(); notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }; notificationObservers.removeAll() }
}

// MARK: - ==================== 4. FSEvents 递归监控 ====================

class RecursiveDirectoryMonitor {
    private var stream: FSEventStreamRef?
    let path: String
    let callback: (String) -> Void
    
    init(path: String, callback: @escaping (String) -> Void) {
        self.path = path
        self.callback = callback
    }
    
    func start() {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        
        let eventCallback: FSEventStreamCallback = { (streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in
            guard let clientInfo = clientCallBackInfo else { return }
            let monitor = Unmanaged<RecursiveDirectoryMonitor>.fromOpaque(clientInfo).takeUnretainedValue()
            
            guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
            let flagsBuffer = UnsafeBufferPointer(start: eventFlags, count: numEvents)
            
            var hasValidChange = false
            var targetPath = monitor.path
            
            // 遍历这批次发生的所有 FSEvents
            for i in 0..<numEvents {
                let currentPath = paths[i]
                let currentFlag = flagsBuffer[i]
                
                let fileName = URL(fileURLWithPath: currentPath).lastPathComponent
                
                // 🛡️ 核心防线 1：过滤系统隐藏文件、缓存文件 (如 .DS_Store, 临时文件等)
                if fileName.hasPrefix(".") || fileName.hasSuffix("~") {
                    continue
                }
                
                // 🛡️ 核心防线 2：精准识别真实变动，过滤纯元数据(Metadata)或属性修改
                let isCreated = (currentFlag & UInt32(kFSEventStreamEventFlagItemCreated)) != 0
                let isModified = (currentFlag & UInt32(kFSEventStreamEventFlagItemModified)) != 0
                let isRemoved = (currentFlag & UInt32(kFSEventStreamEventFlagItemRemoved)) != 0
                let isRenamed = (currentFlag & UInt32(kFSEventStreamEventFlagItemRenamed)) != 0
                
                // 仅当文件实质性新增、改内容、删除、重命名时才算作有效触发
                if isCreated || isModified || isRemoved || isRenamed {
                    targetPath = currentPath
                    hasValidChange = true
                    break // 在该批次中只要发现一个有效变动，就足够触发回调了，避免批量操作时的重复触发
                }
            }
            
            // 只有存在有效变动时，才将最终路径派发给防抖引擎
            if hasValidChange {
                monitor.callback(targetPath)
            }
        }
        
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        
        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            eventCallback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.5, // 稍微增加系统底层的延迟聚合时间 (从 1.0 改为 1.5)，减少 IO 碎片的连续触发
            flags
        )
        
        if let stream = stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .background))
            FSEventStreamStart(stream)
        }
    }
    
    func stop() {
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }
}

// MARK: - ==================== 5. 核心自动化执行引擎 ====================

@Observable
@MainActor
public class AutomationEngine {
    public static let shared = AutomationEngine()
    
    internal private(set) var cachedAgentVM: AgentViewModel?
    public var sessionLogs: [AutomationRunLog] = []
    
    private var fileMonitors: [UUID: RecursiveDirectoryMonitor] = [:]
    private var timers: [UUID: AnyCancellable] = [:]
    
    private var debounceTasks: [UUID: Task<Void, Never>] = [:]
    
    private var workspaceObservers: [UUID: [NSObjectProtocol]] = [:]
    private var clipboardObservers: [UUID: NSObjectProtocol] = [:]
    private var hotkeyMonitors: [UUID: (global: Any?, local: Any?)] = [:]
    private var selectionMonitors: [UUID: (global: Any?, local: Any?)] = [:]
    
    private let globalSelectionUUID = UUID()
    internal var lastMouseDownLocation: NSPoint?
    
    // 容错防抖与键盘记录
    internal var mouseDownTime: Date?
    internal var wasShiftDown: Bool = false
    
    private init() {}
    
    public func startEngine() {
        if cachedAgentVM == nil { cachedAgentVM = AgentViewModel() } else { cachedAgentVM?.loadSkills() }
        stopAll()
        LogManager.shared.info("🚀 AutomationEngine: 正在重载自动化引擎...")
        let rules = ConfigManager.shared.app.automations.filter { $0.isEnabled }
        let selectionRules = rules.filter { $0.triggerType == .selectedTextMatch }
        if !selectionRules.isEmpty { setupSelectionMonitor(for: selectionRules) }
        for rule in rules where rule.triggerType != .selectedTextMatch { setupTrigger(for: rule) }
    }
    
    public func stopAll() {
        timers.values.forEach { $0.cancel() }; timers.removeAll()
        fileMonitors.values.forEach { $0.stop() }; fileMonitors.removeAll()
        debounceTasks.values.forEach { $0.cancel() }; debounceTasks.removeAll()
        workspaceObservers.values.flatMap { $0 }.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; workspaceObservers.removeAll()
        clipboardObservers.values.forEach { NotificationCenter.default.removeObserver($0) }; clipboardObservers.removeAll()
        hotkeyMonitors.values.forEach { if let g = $0.global { NSEvent.removeMonitor(g) }; if let l = $0.local { NSEvent.removeMonitor(l) } }; hotkeyMonitors.removeAll()
        selectionMonitors.values.forEach { if let g = $0.global { NSEvent.removeMonitor(g) }; if let l = $0.local { NSEvent.removeMonitor(l) } }; selectionMonitors.removeAll()
    }
    
    // MARK: - 5. 核心自动化执行引擎中的监听器重构
        
    private func setupSelectionMonitor(for rules: [AutomationRule]) {
        
        // 1. 鼠标按下事件回调 (消除 assumeIsolated 崩溃，提取 ModifierFlags 异步入队)
        let downHandler: @Sendable (NSEvent) -> Void = { [weak self] event in
            let flags = event.modifierFlags
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let loc = NSEvent.mouseLocation
                
                if let frame = QuickActionPanelManager.shared.panelFrame, frame.contains(loc) {
                    self.lastMouseDownLocation = nil
                    self.mouseDownTime = nil
                    return
                }
                
                // 核心防线 1：源头掐断 (Fn 键规则过滤)
                let selectionRules = rules.filter { $0.triggerType == .selectedTextMatch }
                let allRequireFn = !selectionRules.isEmpty && selectionRules.allSatisfy { $0.triggerConfig["requireFnKey"] == "true" }
                let isFnDown = flags.contains(.function)
                
                if allRequireFn && !isFnDown {
                    self.lastMouseDownLocation = nil
                    self.mouseDownTime = nil
                    return
                }
                
                self.lastMouseDownLocation = loc
                self.mouseDownTime = Date()
            }
        }
        
        // 2. 鼠标抬起事件回调 (划词位移计算与触发分发)
        let upHandler: @Sendable (NSEvent) -> Void = { [weak self] event in
            let clickCount = event.clickCount
            let flags = event.modifierFlags
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let upLoc = NSEvent.mouseLocation
                
                if let frame = QuickActionPanelManager.shared.panelFrame, frame.contains(upLoc) { return }
                
                var isTextSelectionIntent = false
                if clickCount >= 2 {
                    isTextSelectionIntent = true
                } else if let downLoc = self.lastMouseDownLocation, let downTime = self.mouseDownTime {
                    let dx = upLoc.x - downLoc.x
                    let dy = upLoc.y - downLoc.y
                    let distance = sqrt(dx * dx + dy * dy)
                    let timeElapsed = Date().timeIntervalSince(downTime)
                    
                    if distance > 10.0 && timeElapsed > 0.1 {
                        isTextSelectionIntent = true
                    }
                }
                
                self.lastMouseDownLocation = nil
                self.mouseDownTime = nil
                
                guard isTextSelectionIntent else { return }
                
                // 核心防线 2：精准过滤
                let isFnDown = flags.contains(.function)
                let validRules = rules.filter { rule in
                    if rule.triggerType == .selectedTextMatch {
                        let requiresFn = rule.triggerConfig["requireFnKey"] == "true"
                        return requiresFn ? isFnDown : true
                    }
                    return true
                }
                
                guard !validRules.isEmpty else { return }
                
                self.processTextSelectionIntent(at: upLoc, with: validRules, flags: flags)
            }
        }
        
        // 3. 修饰键状态变动回调 (Shift 连选释放监听)
        let flagsHandler: @Sendable (NSEvent) -> Void = { [weak self] event in
            let flags = event.modifierFlags
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let isShiftDown = flags.contains(.shift)
                let loc = NSEvent.mouseLocation
                
                if self.wasShiftDown && !isShiftDown {
                    // 核心防线 3：Shift 释放时二次校验 Fn 条件
                    let isFnDown = flags.contains(.function)
                    let validRules = rules.filter { rule in
                        if rule.triggerType == .selectedTextMatch {
                            let requiresFn = rule.triggerConfig["requireFnKey"] == "true"
                            return requiresFn ? isFnDown : true
                        }
                        return true
                    }
                    
                    if !validRules.isEmpty {
                        self.processTextSelectionIntent(at: loc, with: validRules, flags: flags)
                    }
                }
                self.wasShiftDown = isShiftDown
            }
        }
        
        // 4. 挂载系统全局与应用内局部事件监视器
        let globalUp = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: upHandler)
        let localUp = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { e in upHandler(e); return e }
        
        let globalDown = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: downHandler)
        let localDown = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { e in downHandler(e); return e }
        
        let globalFlags = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged], handler: flagsHandler)
        let localFlags = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { e in flagsHandler(e); return e }
        
        selectionMonitors[UUID()] = (globalDown, localDown)
        selectionMonitors[globalSelectionUUID] = (globalUp, localUp)
        selectionMonitors[UUID()] = (globalFlags, localFlags)
    }
    
    // 统一防抖：通过提取和分析 Fn 修饰键管控触发行为
    private func processTextSelectionIntent(at location: NSPoint, with rules: [AutomationRule], flags: NSEvent.ModifierFlags) {
        let isFnPressed = flags.contains(.function)
        
        self.debounce(id: self.globalSelectionUUID, delay: 0.5) { [weak self] in
            guard let self = self else { return }
            // 异步提取文字，避免阻塞主线程
            guard let text = await self.getSystemSelectedText(), !text.isEmpty else { return }
            
            let range = NSRange(location: 0, length: text.utf16.count)
            var matchedFloating: [AutomationRule] = []
            var matchedDirectly: [AutomationRule] = []
            
            for rule in rules {
                guard let regexStr = rule.triggerConfig["regex"],
                      let regex = try? NSRegularExpression(pattern: regexStr, options: .caseInsensitive) else { continue }
                
                if regex.firstMatch(in: text, options: [], range: range) != nil {
                    if rule.triggerConfig["showFloatingMenu"] != "false" {
                        // Fn 键核心拦截逻辑
                        if rule.triggerConfig["requireFnKey"] == "true" {
                            if isFnPressed { matchedFloating.append(rule) }
                        } else {
                            matchedFloating.append(rule)
                        }
                    } else {
                        matchedDirectly.append(rule)
                    }
                }
            }
            
            let context: [String: Any] = ["selectedText": text, "mouseLocation": location]
            
            await MainActor.run {
                for rule in matchedDirectly { self.execute(rule: rule, context: context) }
                if !matchedFloating.isEmpty {
                    QuickActionPanelManager.shared.show(rules: matchedFloating, context: context, at: location)
                }
            }
        }
    }
    
    // nonisolated + async：保证调用层可以在后台极速提取且不污染并发队列
    nonisolated private func getSystemSelectedText() async -> String? {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return nil }
        
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementRef: CFTypeRef?
        
        let frontAppID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let isBrowser = ["com.google.Chrome", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.brave.Browser", "org.mozilla.firefox", "com.apple.Safari"].contains(frontAppID)

        // 1. 尝试获取焦点元素 (不要用 guard 强行拦截，因为 Chrome 划词时经常没有焦点)
        let hasFocusedElement = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElementRef) == .success
        
        if hasFocusedElement, let ref = focusedElementRef, CFGetTypeID(ref) == AXUIElementGetTypeID() {
            let focusedElement = ref as! AXUIElement

            // 优先尝试原生 AX API 提取
            var selectedTextValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, &selectedTextValue) == .success,
               let text = selectedTextValue as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // 检查 Role，防止在桌面/Finder 等非文本区乱发 Cmd+C
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(focusedElement, kAXRoleAttribute as CFString, &roleRef)
            
            if let role = roleRef as? String {
                let standardRoles = ["AXTextField", "AXTextArea", "AXStaticText", "AXWebArea", "AXDocument", "AXGroup", "AXWindow", "AXScrollArea", "AXUnknown"]
                
                // 如果不是浏览器，屏蔽掉 ScrollArea 和 Unknown，防止系统桌面拖拽文件触发
                if !isBrowser && (role == "AXScrollArea" || role == "AXUnknown") {
                    return nil
                }
                
                if !standardRoles.contains(role) {
                    return nil
                }
            }
        } else {
            // 核心突破口：没有焦点元素时（Chrome 常态）
            // 如果不在 Finder（桌面环境）下，直接放行！把信任交给按住 Fn 键的用户
            if frontAppID == "com.apple.finder" { return nil }
        }

        // 3. 终极降级策略：发送 Cmd+C
        return await getSelectedTextViaCopy()
    }
    
    nonisolated private func getSelectedTextViaAX() -> String? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        if AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success, let element = focusedElement {
            var selectedTextValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedTextValue) == .success, let text = selectedTextValue as? String {
                let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanText.isEmpty { return cleanText }
            }
        }
        return nil
    }
    
    // 2：引入异步剪贴板的智能轮询
    nonisolated private func getSelectedTextViaCopy() async -> String? {
        ClipboardMonitorService.shared.pauseMonitoring()
        
        defer {
            ClipboardMonitorService.shared.resumeMonitoring()
        }
        
        let pasteboard = NSPasteboard.general
        let oldItems = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let newItem = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { newItem.setData(data, forType: type) } }
            return newItem
        }
        
        pasteboard.clearContents()
        pasteboard.setString("___LIN_EMPTY___", forType: .string)
        
        // 核心防吞键：必须使用 HID 系统状态源，并在按下和抬起之间留出 20ms 停顿
        // 否则 Chromium 庞大的事件循环经常会把连在一起的 Down 和 Up 视为无效杂讯过滤掉
        let source = CGEventSource(stateID: .hidSystemState)
        let cmdC_down = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
        let cmdC_up = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        cmdC_down?.flags = .maskCommand
        cmdC_up?.flags = .maskCommand
        
        cmdC_down?.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 20_000_000) // 模拟人类按键按压停顿 20 毫秒
        cmdC_up?.post(tap: .cghidEventTap)
        
        // 智能轮询：每 20ms 查一次，最多等 15 次 (300ms)
        var grabbedText: String? = nil
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if let newString = pasteboard.string(forType: .string), newString != "___LIN_EMPTY___" {
                grabbedText = newString
                break
            }
        }
        
        pasteboard.clearContents()
        if let items = oldItems { pasteboard.writeObjects(items) }
        
        return grabbedText?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func setupTrigger(for rule: AutomationRule) {
        switch rule.triggerType {
        case .timer:
            if let intervalStr = rule.triggerConfig["interval"], let interval = TimeInterval(intervalStr) {
                timers[rule.id] = Timer.publish(every: interval, on: .main, in: .common).autoconnect().sink { [weak self] _ in
                    Task { @MainActor in self?.execute(rule: rule) }
                }
            }
        case .fileSystem:
            if let path = rule.triggerConfig["path"], !path.isEmpty {
                let monitor = RecursiveDirectoryMonitor(path: path) { [weak self] changedFilePath in
                    Task { @MainActor in
                        self?.debounce(id: rule.id, delay: 2.0) { [weak self] in
                            await MainActor.run { self?.execute(rule: rule, context: ["changedPath": changedFilePath]) }
                        }
                    }
                }
                fileMonitors[rule.id] = monitor; monitor.start()
            }
        case .appState:
            if let appName = rule.triggerConfig["appName"], !appName.isEmpty {
                let center = NSWorkspace.shared.notificationCenter
                let launchObserver = center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] notif in
                    if let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.localizedName?.lowercased() == appName.lowercased() {
                        Task { @MainActor in
                            self?.debounce(id: rule.id, delay: 1.0) { [weak self] in
                                await MainActor.run { self?.execute(rule: rule, context: ["appName": appName, "event": "launched"]) }
                            }
                        }
                    }
                }
                let activeObserver = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notif in
                    if let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.localizedName?.lowercased() == appName.lowercased() {
                        Task { @MainActor in
                            self?.debounce(id: rule.id, delay: 1.0) { [weak self] in
                                await MainActor.run { self?.execute(rule: rule, context: ["appName": appName, "event": "activated"]) }
                            }
                        }
                    }
                }
                workspaceObservers[rule.id] = [launchObserver, activeObserver]
            }
        case .systemBoot:
            let wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.debounce(id: rule.id, delay: 1.5) { [weak self] in
                        await MainActor.run { self?.execute(rule: rule, context: ["event": "system_unlocked"]) }
                    }
                }
            }
            workspaceObservers[rule.id] = [wakeObserver]
            
        case .clipboardMatch:
            if let regexStr = rule.triggerConfig["regex"], !regexStr.isEmpty, let regex = try? NSRegularExpression(pattern: regexStr, options: .caseInsensitive) {
                let observer = NotificationCenter.default.addObserver(forName: NSNotification.Name("NewClipboardItemReceived"), object: nil, queue: .main) { [weak self] _ in
                    guard let text = NSPasteboard.general.string(forType: .string) else { return }
                    if regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)) != nil {
                        Task { @MainActor in
                            self?.debounce(id: rule.id, delay: 1.0) { [weak self] in
                                await MainActor.run { self?.execute(rule: rule, context: ["clipboardMatched": text]) }
                            }
                        }
                    }
                }
                clipboardObservers[rule.id] = observer
            }
        case .hotkey:
            if let hotkeyStr = rule.triggerConfig["hotkey"], !hotkeyStr.isEmpty {
                let handler: @Sendable (NSEvent) -> Void = { [weak self] event in
                    Task { @MainActor in
                        guard let self = self else { return }
                        if self.matchHotkey(event: event, hotkeyStr: hotkeyStr) {
                            self.execute(rule: rule, context: ["hotkey": hotkeyStr])
                        }
                    }
                }
                let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
                let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in handler(event); return event }
                hotkeyMonitors[rule.id] = (global, local)
            }
        case .selectedTextMatch: break
        }
    }
    
    private func matchHotkey(event: NSEvent, hotkeyStr: String) -> Bool {
        let parts = hotkeyStr.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last else { return false }
        
        let flags = event.modifierFlags
        if (parts.contains("cmd") || parts.contains("command")) != flags.contains(.command) { return false }
        if parts.contains("shift") != flags.contains(.shift) { return false }
        if (parts.contains("opt") || parts.contains("option")) != flags.contains(.option) { return false }
        if (parts.contains("ctrl") || parts.contains("control")) != flags.contains(.control) { return false }
        
        var char = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if char == " " || event.keyCode == 49 { char = "space" }
        else if char == "\r" || char == "\n" || event.keyCode == 36 { char = "enter" }
        else if event.keyCode == 53 { char = "esc" }
        
        return char == key
    }
    
    // Swift 6 Async Debounce：零阻塞，零隔离警告
    private func debounce(id: UUID, delay: TimeInterval, action: @escaping @Sendable () async -> Void) {
        debounceTasks[id]?.cancel()
        let task = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if !Task.isCancelled {
                    await action() // 自由穿梭在后台队列执行计算与提取
                }
            } catch { }
        }
        debounceTasks[id] = task
    }
    
    private func handleResultDisplay(for rule: AutomationRule, title: String, detail: String, context: [String: Any] = [:]) {
        switch rule.displayMode {
        case .none: break
        case .island:
            ___triggerBreathing(text: title, icon: "checkmark.seal.fill")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { ___dynamicIslandEscape(isEscape: true) }
        case .dialog:
            let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail; alert.alertStyle = .informational
            NSApp.activate(ignoringOtherApps: true); alert.runModal()
        case .floatingPanel:
            let point = context["mouseLocation"] as? NSPoint ?? NSEvent.mouseLocation
            let sessionID = context["floatingSessionID"] as? UUID
            QuickActionPanelManager.shared.showResult(title: title, text: detail, at: point, sessionID: sessionID)
        }
        ___triggerBreathing(text: "执行完成", icon: "gearshape.fill", duration: 3, style: 1)
    }
    
    // MARK: - 路由执行分发
    public func execute(rule: AutomationRule, specificSkill: SkillAction? = nil, context: [String: Any] = [:]) {
        ___triggerBreathing(text: "正在执行: \(rule.name)", icon: "bolt.fill")
        switch rule.actionType {
        case .callAgent:
            guard let agentID = rule.targetAgentID else { return }
            let renderedPrompt = TemplateEngine.render(text: rule.taskPrompt, context: context)
            //if rule.displayMode == .island { ___triggerBreathing(text: "正在执行: \(rule.name)", icon: "bolt.fill") }
            
            Task {
                guard let profile = ConfigManager.shared.app.agentProfiles.first(where: { $0.id == agentID }) else { return }
                let vm = self.cachedAgentVM ?? AgentViewModel()
                let engine = AgentExecutionEngine()
                let result = await engine.runAgentLoop(initialPrompt: renderedPrompt, config: profile, tools: vm.getActiveSkills(for: agentID), agentViewModel: vm)
                let isError = result.contains("❌") || result.contains("⚠️")
                
                await MainActor.run {
                    self.recordLog(ruleId: rule.id, ruleName: rule.name, inputContext: renderedPrompt, result: result, isError: isError)
                    let displayTitle = "\(rule.name)结果"
                    self.handleResultDisplay(for: rule, title: displayTitle, detail: result, context: context)
                    if rule.displayMode != .floatingPanel, let sid = context["floatingSessionID"] as? UUID {
                        QuickActionPanelManager.shared.hideIfSessionMatches(sid)
                    }
                }
            }
            
        case .callSkill:
            if rule.targetSkills.isEmpty { return }
            Task {
                guard let vm = self.cachedAgentVM else { return }
                var finalOutput = ""
                var allInputContexts = ""
                var hasError = false
                let skillsToExecute = specificSkill != nil ? [specificSkill!] : rule.targetSkills
                //if rule.displayMode == .island { ___triggerBreathing(text: "正在执行技能...", icon: "gearshape.fill") }
                
                for skill in skillsToExecute {
                    var finalArgs: [String: Any] = [:]
                    if let data = skill.argsJSON.data(using: .utf8), let rawDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        finalArgs = TemplateEngine.renderDictionary(dict: rawDict, context: context)
                    }
                    for (k, v) in context { if finalArgs[k] == nil { finalArgs[k] = v } }
                    
                    let skillDisplayName = skill.shortName.isEmpty ? skill.skillName : skill.shortName
                    
                    let inputContextStr = (try? String(data: JSONSerialization.data(withJSONObject: finalArgs, options: .prettyPrinted), encoding: .utf8)) ?? "{}"
                    allInputContexts += "[\(skillDisplayName) 参数]: \n\(inputContextStr)\n"
                    
                    guard let targetSkill = vm.skills.first(where: { $0.name == skill.skillName }) else {
                        let errMsg = "❌ 未找到技能 [\(skill.skillName)]"
                        finalOutput += (skillsToExecute.count == 1) ? errMsg : "[\(skillDisplayName)]: \(errMsg)\n"
                        hasError = true
                        continue
                    }
                    
                    let result = await vm.executeTool(skill: targetSkill, args: finalArgs, skipConfirmation: true)
                    finalOutput += (skillsToExecute.count == 1) ? result : "[\(skillDisplayName)]: \(result)\n"
                    if result.contains("❌") { hasError = true }
                }
                
                await MainActor.run {
                    self.recordLog(ruleId: rule.id, ruleName: rule.name, inputContext: allInputContexts.trimmingCharacters(in: .whitespacesAndNewlines), result: finalOutput, isError: hasError)
                    
                    let baseName = specificSkill != nil ? (specificSkill!.shortName.isEmpty ? specificSkill!.skillName : specificSkill!.shortName) : rule.name
                    let displayTitle = hasError ? "⚠️ \(baseName)异常" : "\(baseName)结果"
                    
                    self.handleResultDisplay(for: rule, title: displayTitle, detail: finalOutput, context: context)
                    if rule.displayMode != .floatingPanel, let sid = context["floatingSessionID"] as? UUID {
                        QuickActionPanelManager.shared.hideIfSessionMatches(sid)
                    }
                }
            }
        }
    }
    
    private func recordLog(ruleId: UUID, ruleName: String, inputContext: String, result: String, isError: Bool) {
        let log = AutomationRunLog(ruleId: ruleId, ruleName: ruleName, timestamp: Date(), inputContext: inputContext, result: result, isError: isError)
        sessionLogs.insert(log, at: 0)
        if sessionLogs.count > 100 { sessionLogs.removeLast() }
    }
}

// MARK: - ==================== 5. UI 视图组件 ====================

struct AutomationLogsView: View {
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("运行记录 (本次启动)").font(.headline)
                    Text("所有自动化触发记录均保存在内存中，重启应用后将自动清空。").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button("清空记录") { AutomationEngine.shared.sessionLogs.removeAll() }.buttonStyle(.bordered)
                Button("关闭") { dismiss() }.buttonStyle(.borderedProminent)
            }.padding().background(Color(NSColor.windowBackgroundColor)); Divider()
            
            List(AutomationEngine.shared.sessionLogs) { log in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(log.ruleName).font(.system(size: 13, weight: .bold))
                        Spacer()
                        Text(log.timestamp, formatter: dateFormatter).font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("输入 / 参数:").font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
                            Text(log.inputContext)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.blue.opacity(0.8))
                                .textSelection(.enabled)
                            
                            Divider().opacity(0.3)
                            
                            Text("执行结果:").font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
                            Text(log.result)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(log.isError ? .red : .primary)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor).opacity(0.5))
                    .cornerRadius(6)
                }.padding(.vertical, 6)
            }.background(Color(NSColor.controlBackgroundColor))
        }.frame(width: 550, height: 600)
    }
    private var dateFormatter: DateFormatter { let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"; return f }
}

struct AutomationManagementPanel: View {
    @State private var automations: [AutomationRule] = ConfigManager.shared.app.automations
    @State private var selectedRule: AutomationRule?
    @State private var showLogs = false
    let columns = [GridItem(.adaptive(minimum: 300, maximum: 400), spacing: 16)]
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) { Text("后台自动化引擎").font(.headline); Text("划词选中或文件变动时静默执行 AI 任务").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button { showLogs = true } label: { Label("运行记录", systemImage: "list.bullet.clipboard") }.buttonStyle(.bordered)
                Button { selectedRule = AutomationRule(name: "新任务", triggerType: .selectedTextMatch) } label: { Label("添加触发器", systemImage: "plus") }.buttonStyle(.borderedProminent)
            }.padding().background(Color.clear);
            
            ModernDivider(style: .fade(0.18))
            
            ScrollView {
                if automations.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "bolt.slash.fill").font(.system(size: 48)).foregroundStyle(.tertiary)
                        Text("尚未配置被动触发任务").foregroundColor(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.top, 100)
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(automations) { rule in
                            AutomationCard(rule: rule, onToggle: { isEnabled in
                                if let idx = automations.firstIndex(where: { $0.id == rule.id }) {
                                    automations[idx].isEnabled = isEnabled
                                    ConfigManager.shared.app.automations = automations
                                    ConfigManager.shared.saveConfig()
                                    AutomationEngine.shared.startEngine()
                                }
                            }) {
                                selectedRule = rule
                            }
                        }
                    }.padding(20)
                }
            }.background(.ultraThinMaterial).scrollContentBackground(.hidden).forceOverlayScrollbars()
        }
        .sheet(isPresented: $showLogs) { AutomationLogsView() }
        .sheet(item: $selectedRule) { ruleItem in
            AutomationEditView(initialRule: ruleItem, onSave: { updatedRule in
                if let idx = automations.firstIndex(where: { $0.id == updatedRule.id }) { automations[idx] = updatedRule } else { automations.append(updatedRule) }
                ConfigManager.shared.app.automations = automations; ConfigManager.shared.saveConfig()
                AutomationEngine.shared.startEngine(); selectedRule = nil
            }, onDelete: { ruleToDelete in
                withAnimation { automations.removeAll { $0.id == ruleToDelete.id } }
                ConfigManager.shared.app.automations = automations; ConfigManager.shared.saveConfig()
                AutomationEngine.shared.startEngine(); selectedRule = nil
            })
        }
        .onAppear { self.automations = ConfigManager.shared.app.automations }
    }
}

struct AutomationCard: View {
    let rule: AutomationRule
    var onToggle: (Bool) -> Void
    var onEdit: () -> Void
    
    // 状态控制：点击测试时的瞬间反馈
    @State private var isTesting = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: rule.triggerType.icon)
                    .font(.title2)
                    .foregroundColor(.orange)
                VStack(alignment: .leading) {
                    Text(rule.name).font(.headline)
                    Text(rule.triggerType.rawValue).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { rule.isEnabled },
                    set: { onToggle($0) }
                )).toggleStyle(.switch).controlSize(.small)
            }
            
            HStack {
                if rule.actionType == .callAgent {
                    Text("🤖 目标 Agent: \(getAgentName(rule.targetAgentID))")
                } else {
                    let pipelineStr = rule.targetSkills.map { $0.shortName.isEmpty ? $0.skillName : $0.shortName }.joined(separator: " → ")
                    Text("⚙️ 技能链: \(pipelineStr.isEmpty ? "未配置" : pipelineStr)")
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(rule.actionType == .callAgent ? Color.blue.opacity(0.1) : Color.purple.opacity(0.1))
            .cornerRadius(4)
            
            Divider().opacity(0.5)
            
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("最近运行状态:").font(.caption).bold()
                    if let log = AutomationEngine.shared.sessionLogs.first(where: { $0.ruleId == rule.id }) {
                        Text("\(log.timestamp, formatter: dateFormatter) - \(log.result)")
                            .font(.system(size: 10))
                            .lineLimit(1)
                            .foregroundColor(log.isError ? .red : .secondary)
                    } else {
                        Text("本次运行尚未触发").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                // 🚀 新增：手动触发测试按钮
                Button {
                    runManualTest()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isTesting ? "hourglass" : "play.fill")
                        Text("立即测试")
                    }
                    .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(.green)
                .controlSize(.small)
                .disabled(!rule.isEnabled || isTesting)
                
                Button("配置详情") {
                    onEdit()
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)
                .font(.caption)
            }
        }
        .padding(16)
        .background(VisualEffectView(material: .popover, blendingMode: .withinWindow))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isTesting ? Color.green.opacity(0.5) : Color.primary.opacity(0.1), lineWidth: isTesting ? 2 : 1)
        )
        .animation(.spring(), value: isTesting)
    }
    
    /// 执行手动测试逻辑
    private func runManualTest() {
        isTesting = true
        
        // 构造模拟上下文
        let mockContext: [String: Any] = [
            "isManualTest": true,
            "selectedText": "这是手动触发的测试文本",
            "clipboard": NSPasteboard.general.string(forType: .string) ?? "剪贴板为空",
            "datetime": Date().description
        ]
        
        // 调用引擎执行
        AutomationEngine.shared.execute(rule: rule, context: mockContext)
        
        // 1秒后恢复按钮状态（执行过程在后台异步进行，灵动岛会持续反馈）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.isTesting = false
        }
    }
    
    private func getAgentName(_ id: UUID?) -> String {
        return ConfigManager.shared.app.agentProfiles.first { $0.id == id }?.name ?? "未知 Agent"
    }
    
    private var dateFormatter: DateFormatter {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"; return f
    }
}

struct HotkeyRecorderView: View {
    @Binding var hotkeyString: String
    @State private var isRecording = false
    @State private var monitor: Any?
    
    var body: some View {
        Button(action: {
            if isRecording { stopRecording() } else { startRecording() }
        }) {
            HStack {
                Image(systemName: "keyboard")
                Text(isRecording ? "按键监听中... (按 Esc 取消)" : (hotkeyString.isEmpty ? "点击录制快捷键" : hotkeyString))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(isRecording ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.1))
            .foregroundColor(isRecording ? .orange : .primary)
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(isRecording ? Color.orange : Color.secondary.opacity(0.2), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onDisappear { stopRecording() }
    }
    
    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stopRecording(); return nil }
            
            var keys: [String] = []
            let flags = event.modifierFlags
            if flags.contains(.command) { keys.append("cmd") }
            if flags.contains(.control) { keys.append("ctrl") }
            if flags.contains(.option) { keys.append("opt") }
            if flags.contains(.shift) { keys.append("shift") }
            
            if let char = event.charactersIgnoringModifiers?.lowercased(), !char.isEmpty {
                if char == " " || event.keyCode == 49 { keys.append("space") }
                else if char == "\r" || event.keyCode == 36 { keys.append("enter") }
                else { keys.append(char) }
                
                if !keys.isEmpty { hotkeyString = keys.joined(separator: "+") }
            }
            stopRecording()
            return nil
        }
    }
    
    private func stopRecording() {
        isRecording = false
        if let monitor = monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
}

struct AutomationEditView: View {
    var initialRule: AutomationRule
    var onSave: (AutomationRule) -> Void
    var onDelete: (AutomationRule) -> Void
    @Environment(\.dismiss) private var dismiss
    
    @State private var rule: AutomationRule
    private let availableAgents = ConfigManager.shared.app.agentProfiles
    @State private var availableSkills: [AgentSkill] = []
    
    @State private var timerInterval: String = "3600"
    @State private var watchPath: String = ""
    @State private var targetAppName: String = "Xcode"
    @State private var regexPattern: String = ""
    @State private var hotkeyString: String = ""
    
    @State private var showFloatingMenu: Bool = true
    @State private var requireFnKey: Bool = false // 新增：Fn 键限制状态
    
    init(initialRule: AutomationRule, onSave: @escaping (AutomationRule) -> Void, onDelete: @escaping (AutomationRule) -> Void) {
        self.initialRule = initialRule
        self._rule = State(initialValue: initialRule)
        self.onSave = onSave
        self.onDelete = onDelete
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) { Text(rule.name == "新任务" ? "新建自动化规则" : "编辑自动化规则").font(.system(size: 16, weight: .bold)); Text("设定触发条件与双轨执行策略").font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer(); Image(systemName: "bolt.badge.automatic.fill").font(.system(size: 24)).foregroundStyle(.orange.gradient).padding(.leading, 12)
            }.padding(.horizontal, 20).padding(.vertical, 16).background(Color(NSColor.windowBackgroundColor).opacity(0.8)); Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack { Text("规则名称").font(.system(size: 13, weight: .medium)).frame(width: 80, alignment: .leading).foregroundStyle(.secondary); TextField("如：保存文件自动更新知识图谱", text: $rule.name).textFieldStyle(.roundedBorder) }
                            Toggle("启用此自动化任务", isOn: $rule.isEnabled).toggleStyle(.switch).controlSize(.small)
                        }.padding(12)
                    } label: { Text("基础设定").font(.headline).foregroundStyle(.primary) }
                    
                    GroupBox {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Text("触发方式").font(.system(size: 13, weight: .medium)).frame(width: 80, alignment: .leading).foregroundStyle(.secondary)
                                Picker("", selection: $rule.triggerType) { ForEach(TriggerType.allCases, id: \.self) { type in Text(type.rawValue).tag(type) } }.labelsHidden().pickerStyle(.menu).frame(width: 150)
                            }
                            Divider().opacity(0.5)
                            dynamicTriggerConfigSection
                        }.padding(12)
                    } label: { Text("系统监听探针").font(.headline).foregroundStyle(.primary) }
                    
                    GroupBox {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Text("执行动作").font(.system(size: 13, weight: .medium)).frame(width: 80, alignment: .leading).foregroundStyle(.secondary)
                                Picker("", selection: $rule.actionType) { ForEach(ActionType.allCases, id: \.self) { type in Text(type.rawValue).tag(type) } }.labelsHidden().pickerStyle(.segmented)
                            }
                            
                            Divider().opacity(0.5)
                            
                            if rule.actionType == .callAgent {
                                HStack {
                                    Text("唤醒分身").font(.system(size: 13, weight: .medium)).frame(width: 80, alignment: .leading).foregroundStyle(.secondary)
                                    Picker("", selection: Binding(get: { rule.targetAgentID ?? availableAgents.first?.id ?? UUID() }, set: { rule.targetAgentID = $0 })) { ForEach(availableAgents) { agent in Text("\(agent.name)").tag(agent.id) } }.labelsHidden().frame(width: 150)
                                }
                                HStack { Text("唤醒指令 (Prompt)").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary); Spacer(); variablesHintButton }.padding(.top, 8)
                                TextEditor(text: $rule.taskPrompt).font(.system(size: 13)).frame(height: 80).padding(4).background(Color(NSColor.textBackgroundColor)).cornerRadius(6).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor), lineWidth: 1))
                            } else {
                                HStack {
                                    Text("流水线技能库 (按序触发)").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                                    Spacer()
                                    variablesHintButton
                                    Menu {
                                        if availableSkills.isEmpty { Text("正在加载底层技能引擎...").foregroundColor(.secondary) }
                                        else { ForEach(availableSkills, id: \.id) { skill in Button(skill.displayName) {
                                            rule.targetSkills.append(SkillAction(skillName: skill.name, shortName: skill.displayName, argsJSON: generateDefaultArgsJSON(for: skill)))
                                        } } }
                                    } label: { Label("添加环节", systemImage: "plus") }.menuStyle(.borderlessButton).fixedSize()
                                }
                                
                                if rule.targetSkills.isEmpty {
                                    Text("请点击上方添加执行技能。若配置多个，将按顺序串行执行。").font(.caption).foregroundColor(.secondary).padding(.top, 8)
                                } else {
                                    VStack(spacing: 12) {
                                        ForEach($rule.targetSkills) { $skill in
                                            VStack(alignment: .leading, spacing: 8) {
                                                HStack {
                                                    Text("🧩 \(skill.skillName)").font(.system(size: 13, weight: .bold))
                                                    Spacer()
                                                    Button(role: .destructive) { rule.targetSkills.removeAll { $0.id == skill.id } } label: { Image(systemName: "trash") }.buttonStyle(.plain)
                                                }
                                                HStack {
                                                    Text("悬浮窗简称:").font(.system(size: 12)).foregroundColor(.secondary)
                                                    TextField("如：翻译", text: $skill.shortName).textFieldStyle(.roundedBorder)
                                                }
                                                Text("JSON 参数:").font(.system(size: 12)).foregroundColor(.secondary)
                                                TextEditor(text: $skill.argsJSON).font(.system(size: 11, design: .monospaced)).frame(height: 70).padding(4).background(Color(NSColor.textBackgroundColor)).cornerRadius(4).overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.1), lineWidth: 1))
                                            }
                                            .padding(10)
                                            .background(Color.secondary.opacity(0.1))
                                            .cornerRadius(8)
                                        }
                                    }.padding(.top, 8)
                                }
                            }
                            
                            Divider().opacity(0.5)
                            HStack {
                                Text("完成反馈").font(.system(size: 13, weight: .medium)).frame(width: 80, alignment: .leading).foregroundStyle(.secondary)
                                Picker("", selection: $rule.displayMode) { ForEach(ResultDisplayMode.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) } }.labelsHidden().pickerStyle(.segmented)
                            }
                        }.padding(12)
                    } label: { Text("执行动作路由").font(.headline).foregroundStyle(.primary) }
                }.padding(20)
            }.background(Color(NSColor.controlBackgroundColor)); Divider()
            
            HStack {
                if rule.name != "新任务" {
                    Button(role: .destructive) {
                        onDelete(rule)
                    } label: {
                        Label("删除触发器", systemImage: "trash")
                    }.buttonStyle(.plain).foregroundColor(.red)
                }
                
                Spacer()
                
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存并生效") { packConfig(); onSave(rule) }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            }.padding(20).background(Color(NSColor.windowBackgroundColor))
        }.frame(width: 650, height: 760).onAppear {
            self.rule = initialRule; unpackConfig()
            Task { @MainActor in
                if let vm = AutomationEngine.shared.cachedAgentVM { self.availableSkills = vm.skills.filter { $0.isEnabled } }
                else { let vm = AgentViewModel(); self.availableSkills = vm.skills.filter { $0.isEnabled } }
            }
        }
    }
    
    @ViewBuilder private var variablesHintButton: some View {
        Menu {
            Section("通用变量 (点击复制)") {
                Button("{{clipboard}} - 剪贴板当前内容") { copyToClip("{{clipboard}}") }
                Button("{{front_app}} - 当前最前台的App") { copyToClip("{{front_app}}") }
                Button("{{datetime}} - 当前时间") { copyToClip("{{datetime}}") }
            }
            Section("专属变量 (根据触发器生效)") {
                switch rule.triggerType {
                case .fileSystem: Button("{{changedPath}} - 变动文件的绝对路径") { copyToClip("{{changedPath}}") }
                case .clipboardMatch: Button("{{clipboardMatched}} - 完全命中正则的文本") { copyToClip("{{clipboardMatched}}") }
                case .selectedTextMatch: Button("{{selectedText}} - 鼠标划词选中的文本") { copyToClip("{{selectedText}}") }
                case .appState: Button("{{appName}} - 触发状态的App名称") { copyToClip("{{appName}}") }; Button("{{event}} - 生命周期事件") { copyToClip("{{event}}") }
                case .hotkey: Button("{{hotkey}} - 被按下的快捷键组合") { copyToClip("{{hotkey}}") }
                default: Text("当前触发器无专属变量").foregroundColor(.secondary)
                }
            }
        } label: { Label("插入变量", systemImage: "curlybraces").font(.system(size: 11)).foregroundColor(.blue) }.buttonStyle(.plain)
    }
    
    private func copyToClip(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); Util.message("已复制: \(text)") }
    
    @ViewBuilder private var regexHelperMenu: some View {
        Menu {
            Button(".* (匹配任意所有文字)") { regexPattern = ".*" }
            Button("^[0-9]+$  (仅匹配纯数字)") { regexPattern = "^[0-9]+$" }
            Button("^https?://.* (仅匹配网址 URL)") { regexPattern = "^https?://.*" }
            Button("^[a-zA-Z]+$  (仅匹配纯英文字母)") { regexPattern = "^[a-zA-Z]+$" }
            Button("^\\s*$  (匹配纯空白或换行)") { regexPattern = "^\\s*$" }
        } label: { Image(systemName: "list.bullet.rectangle") }.menuStyle(.borderlessButton).fixedSize()
    }
    
    @ViewBuilder private var dynamicTriggerConfigSection: some View {
        switch rule.triggerType {
        case .timer: HStack { Text("执行间隔").font(.system(size: 13, weight: .medium)).frame(width: 80, alignment: .leading).foregroundStyle(.secondary); TextField("秒数", text: $timerInterval).textFieldStyle(.roundedBorder).frame(width: 120); Text("秒").font(.system(size: 13)).foregroundStyle(.secondary) }
        case .fileSystem: HStack { Text("监控目录").font(.system(size: 13, weight: .medium)).frame(width: 80, alignment: .leading).foregroundStyle(.secondary); TextField("绝对路径", text: $watchPath).textFieldStyle(.roundedBorder); Button("浏览...") { let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; if panel.runModal() == .OK, let url = panel.url { watchPath = url.path } } }
        case .clipboardMatch: HStack { Text("正则匹配").font(.system(size: 13, weight: .medium)).frame(width: 80, alignment: .leading).foregroundStyle(.secondary); TextField("如：^https://.*", text: $regexPattern).textFieldStyle(.roundedBorder).fontDesign(.monospaced); regexHelperMenu }
        case .selectedTextMatch:
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("匹配正则").font(.system(size: 13, weight: .medium)).frame(width: 80, alignment: .leading).foregroundStyle(.secondary); TextField("如：^[0-9]+$", text: $regexPattern).textFieldStyle(.roundedBorder).fontDesign(.monospaced); regexHelperMenu }
                
                // Fn 键控制 UI
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("显示微型交互气泡 (失去焦点时自动销毁)", isOn: $showFloatingMenu).toggleStyle(.checkbox).font(.system(size: 13)).foregroundColor(.primary)
                    if showFloatingMenu {
                        Toggle("仅在按住 Fn 键时触发悬浮窗 (防止频繁打扰)", isOn: $requireFnKey).toggleStyle(.checkbox).font(.system(size: 12)).foregroundColor(.secondary).padding(.leading, 24)
                    }
                }.padding(.leading, 88)
                
                Text("全局鼠标划词选中即触发。气泡会无缝融合在鼠标下方，点击外部或切换 App 即刻销毁。").font(.caption).foregroundColor(.blue).padding(.leading, 88)
            }
        case .appState:
            HStack {
                Text("监听 App").font(.system(size: 13, weight: .medium)).frame(width: 80, alignment: .leading).foregroundStyle(.secondary)
                TextField("应用名称", text: $targetAppName).textFieldStyle(.roundedBorder).disabled(true)
                Button("选择 App...") {
                    let panel = NSOpenPanel()
                    panel.directoryURL = URL(fileURLWithPath: "/Applications")
                    panel.allowedContentTypes = [UTType.applicationBundle]
                    panel.canChooseDirectories = false
                    panel.canChooseFiles = true
                    if panel.runModal() == .OK, let url = panel.url {
                        targetAppName = url.deletingPathExtension().lastPathComponent
                    }
                }
            }
        case .hotkey:
            HStack {
                Text("按键组合").font(.system(size: 13, weight: .medium)).frame(width: 80, alignment: .leading).foregroundStyle(.secondary)
                HotkeyRecorderView(hotkeyString: $hotkeyString)
            }
        case .systemBoot: Text("系统启动或屏幕解锁时自动触发。").font(.system(size: 13)).foregroundColor(.secondary).padding(.vertical, 8)
        }
    }
    
    private func generateDefaultArgsJSON(for skill: AgentSkill) -> String {
        guard !skill.parameters.isEmpty else { return "{}" }
        var dict: [String: Any] = [:]
        for param in skill.parameters {
            switch param.type { case .string, .enum: dict[param.name] = ""; case .number: dict[param.name] = 0; case .boolean: dict[param.name] = false; case .array: dict[param.name] = []; case .object: dict[param.name] = [String: Any]() }
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]), let str = String(data: data, encoding: .utf8) { return str.replacingOccurrences(of: "\\/", with: "/") }
        return "{}"
    }
    
    private func unpackConfig() {
        timerInterval = rule.triggerConfig["interval"] ?? "3600"; watchPath = rule.triggerConfig["path"] ?? ""; targetAppName = rule.triggerConfig["appName"] ?? "Xcode"; regexPattern = rule.triggerConfig["regex"] ?? ""; hotkeyString = rule.triggerConfig["hotkey"] ?? ""
        showFloatingMenu = rule.triggerConfig["showFloatingMenu"] != "false"
        // 恢复 Fn 键读取
        requireFnKey = rule.triggerConfig["requireFnKey"] == "true"
        
        if rule.targetSkills.isEmpty && !rule.targetSkillName.isEmpty { rule.targetSkills = [SkillAction(skillName: rule.targetSkillName, shortName: rule.targetSkillName, argsJSON: rule.skillArgsJSON)] }
    }
    
    private func packConfig() {
        rule.triggerConfig.removeAll()
        switch rule.triggerType {
        case .timer: rule.triggerConfig["interval"] = timerInterval
        case .fileSystem: rule.triggerConfig["path"] = watchPath
        case .appState: rule.triggerConfig["appName"] = targetAppName
        case .clipboardMatch: rule.triggerConfig["regex"] = regexPattern
        case .selectedTextMatch:
            rule.triggerConfig["regex"] = regexPattern
            rule.triggerConfig["showFloatingMenu"] = showFloatingMenu ? "true" : "false"
            // 封存 Fn 键状态
            rule.triggerConfig["requireFnKey"] = requireFnKey ? "true" : "false"
        case .hotkey: rule.triggerConfig["hotkey"] = hotkeyString
        default: break
        }
    }
}
