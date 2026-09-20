//////////////////////////////////////////////////////////////////
// 文件名：SkillManager.swift
// 文件说明：适用于 macOS 14+ 的 Skill 与 MCP (Model Context Protocol) 引擎管理中心
// 代码规范：Swift 6 Ready (严格并发安全、Actor 隔离、模块化解耦)
//
// 核心解构架构拓扑 (Domain-Driven Architecture)：
// ├── 1. SkillModels          : 核心实体模型、枚举与 MCP 传输协议定义
// ├── 2. SkillEnvironment     : 终端 PATH 动态解析探针与文件系统变动监听器
// ├── 3. SkillSecurity        : 安全规则防护网、Touch ID 硬件拦截与 HITL 人工在环中枢
// ├── 4. SkillDiscovery       : 动态技能包嗅探装配引擎 (LocalSkillScanner) 与系统内置技能名录
// ├── 5. SkillCommandBridge   : 通用 CLI 指令归一化网关、内联 JSON 桥接与手册透视器
// ├── 6. SkillExecutors       : 多态物理执行引擎集群 (CLI, Shell, Python, AppleScript, API, MCP, Builtin)
// ├── 7. SkillDataExchange    : 开放格式导入导出网关 (OpenAPI / Swagger / 标准 JSON)
// ├── 8. SkillManager (Facade): 统一状态管理与响应式业务门面中枢 (@Observable)
// ├── 9. SkillSessionCache    : 会话参数历史状态与表单记忆缓存
// └── 10. SkillUI Components  : 原生 macOS 14+ 拟态毛玻璃管理面板与交互视图群
//////////////////////////////////////////////////////////////////

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine
import Foundation

// MARK: - ==================== 1. SkillModels (核心数据模型域) ====================

/// 技能执行媒介类型
public enum SkillType: String, CaseIterable, Codable, Sendable {
    case api = "REST API"
    case shell = "Shell 脚本 (Zsh)"
    case cli = "CLI 命令行工具"
    case applescript = "AppleScript (自动化)"
    case python = "Python 脚本"
    case builtin = "系统原生方法"
    case mcp = "MCP 动态代理"
}

/// 技能参数数据类型
public enum ParameterType: String, CaseIterable, Codable, Sendable {
    case string = "String"
    case number = "Number"
    case boolean = "Boolean"
    case array = "Array"
    case `enum` = "Enum"
    case object = "Object"
}

/// 技能参数元数据模型
public struct SkillParameter: Identifiable, Hashable, Codable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var type: ParameterType
    public var description: String
    public var isRequired: Bool
    
    public init(id: UUID = UUID(), name: String, type: ParameterType, description: String, isRequired: Bool) {
        self.id = id
        self.name = name
        self.type = type
        self.description = description
        self.isRequired = isRequired
    }
    
    enum CodingKeys: String, CodingKey {
        case id, name, type, description, isRequired
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.isRequired = try container.decodeIfPresent(Bool.self, forKey: .isRequired) ?? true
        
        if let typeStr = try container.decodeIfPresent(String.self, forKey: .type) {
            if let exactMatch = ParameterType(rawValue: typeStr) {
                self.type = exactMatch
            } else if let lowerMatch = ParameterType.allCases.first(where: { $0.rawValue.lowercased() == typeStr.lowercased() }) {
                self.type = lowerMatch
            } else {
                self.type = .string
            }
        } else {
            self.type = .string
        }
    }
}

/// 智能体技能核心实体
public struct AgentSkill: Identifiable, Hashable, Codable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var displayName: String
    public var description: String
    public var detailedInstruction: String = ""
    public var type: SkillType
    public var parameters: [SkillParameter]
    public var executionBody: String
    public var isEnabled: Bool = true
    public var requiresConfirmation: Bool = false
    public var outputKey: String = ""
    public var isLocal: Bool = false
    public var workingDirectory: String? = nil
    public var entryPoint: String? = nil
    public var createdAt: Date = Date()
    public var category: String = "自定义"
    public var score: Int = 100
    public var uiTemplate: String = ""
    
    enum CodingKeys: String, CodingKey {
        case id, name, displayName, description, detailedInstruction, type, parameters, executionBody, isEnabled, requiresConfirmation, outputKey, isLocal, workingDirectory, entryPoint, createdAt, category, score, uiTemplate
    }
    
    public init(
        id: UUID = UUID(),
        name: String,
        displayName: String,
        description: String,
        detailedInstruction: String = "",
        type: SkillType,
        parameters: [SkillParameter],
        executionBody: String,
        isEnabled: Bool = true,
        requiresConfirmation: Bool = false,
        outputKey: String = "",
        isLocal: Bool = false,
        workingDirectory: String? = nil,
        entryPoint: String? = nil,
        createdAt: Date = Date(),
        category: String = "自定义",
        score: Int = 100,
        uiTemplate: String = ""
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.description = description
        self.detailedInstruction = detailedInstruction
        self.type = type
        self.parameters = parameters
        self.executionBody = executionBody
        self.isEnabled = isEnabled
        self.requiresConfirmation = requiresConfirmation
        self.outputKey = outputKey
        self.isLocal = isLocal
        self.workingDirectory = workingDirectory
        self.entryPoint = entryPoint
        self.createdAt = createdAt
        self.category = category
        self.score = score
        self.uiTemplate = uiTemplate
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try container.decode(String.self, forKey: .name)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.description = try container.decode(String.self, forKey: .description)
        self.detailedInstruction = try container.decodeIfPresent(String.self, forKey: .detailedInstruction) ?? ""
        self.type = try container.decodeIfPresent(SkillType.self, forKey: .type) ?? .shell
        self.parameters = try container.decode([SkillParameter].self, forKey: .parameters)
        self.executionBody = try container.decode(String.self, forKey: .executionBody)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.requiresConfirmation = try container.decodeIfPresent(Bool.self, forKey: .requiresConfirmation) ?? false
        self.outputKey = try container.decodeIfPresent(String.self, forKey: .outputKey) ?? ""
        self.isLocal = try container.decodeIfPresent(Bool.self, forKey: .isLocal) ?? false
        self.workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        self.entryPoint = try container.decodeIfPresent(String.self, forKey: .entryPoint)
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.category = try container.decodeIfPresent(String.self, forKey: .category) ?? "自定义"
        self.score = try container.decodeIfPresent(Int.self, forKey: .score) ?? 100
        self.uiTemplate = try container.decodeIfPresent(String.self, forKey: .uiTemplate) ?? ""
    }
}

/// MCP 传输协议类型
public enum MCPTransportType: String, Codable, CaseIterable, Sendable {
    case stdio = "Standard I/O (本地进程)"
    case sse = "SSE (HTTP 长连接)"
}

/// MCP 外部服务节点配置
public struct MCPServer: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var transport: MCPTransportType
    public var command: String?
    public var args: String?
    public var url: String?
    public var status: String
    public var isEnabled: Bool
    
    public init(id: UUID = UUID(), name: String, transport: MCPTransportType = .stdio, command: String? = nil, args: String? = nil, url: String? = nil, status: String = "未连接", isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.transport = transport
        self.command = command
        self.args = args
        self.url = url
        self.status = status
        self.isEnabled = isEnabled
    }
}

/// 技能包 Manifest 配置文件契约
struct SkillPackageManifest: Codable, Sendable {
    let name: String
    let displayName: String?
    let description: String
    let type: String?
    let entryPoint: String
    let requiresConfirmation: Bool?
    let outputKey: String?
    let order: Int?
    let category: String?
    let parameters: [SkillPackageParameter]?
    
    struct SkillPackageParameter: Codable, Sendable {
        let name: String
        let type: String
        let description: String
        let isRequired: Bool
    }
}

// MARK: - ==================== 2. SkillEnvironment (环境与进程底座) ====================

/// 动态环境解析器：自适应探测并捕获用户登录 Shell 的真实 PATH 与环境配置
@MainActor
public final class EnvironmentResolver {
    public static let shared = EnvironmentResolver()
    
    private var cachedPATH: String?
    private var isProbing: Bool = false
    
    private init() {
        Task.detached(priority: .utility) {
            await self.warmUpEnvironment()
        }
    }
    
    /// 获取已解析的完整系统 PATH
    public func getResolvedPATH() async -> String {
        if let path = cachedPATH, !path.isEmpty { return path }
        return await warmUpEnvironment()
    }
    
    /// 预热并缓存动态环境变量
    @discardableResult
    public func warmUpEnvironment() async -> String {
        if let path = cachedPATH, !path.isEmpty { return path }
        let probed = await probeUserShellPATH()
        let fallback = buildFallbackPATH()
        let merged = mergePATHs(probed: probed, fallback: fallback)
        self.cachedPATH = merged
        return merged
    }
    
    /// 异步派生轻量级登录交互式 Shell 探测真实环境
    private func probeUserShellPATH() async -> String {
        return await Task.detached(priority: .utility) {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let proc = Process()
            let pipe = Pipe()
            proc.executableURL = URL(fileURLWithPath: shell)
            proc.arguments = ["-l", "-c", "echo -n \"__E_PATH_START__${PATH}__E_PATH_END__\""]
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            
            do {
                try proc.run()
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                proc.waitUntilExit()
                guard let output = String(data: data, encoding: .utf8) else { return "" }
                
                if let startRange = output.range(of: "__E_PATH_START__"),
                   let endRange = output.range(of: "__E_PATH_END__", range: startRange.upperBound..<output.endIndex) {
                    return String(output[startRange.upperBound..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return ""
            } catch {
                return ""
            }
        }.value
    }
    
    // MARK: - 全生态多级开发者环境拓扑垫片 (涵盖 Node/Python/Rust/Go/Bun/Conda/MacPorts 及系统配置)
    private func buildFallbackPATH() -> [String] {
        let fileManager = FileManager.default
        let home = NSHomeDirectory()
        var candidatePaths: [String] = []
        
        // 1. 系统级路径配置文件 (/etc/paths 与 /etc/paths.d/*)
        if let etcPaths = try? String(contentsOfFile: "/etc/paths", encoding: .utf8) {
            for line in etcPaths.components(separatedBy: .newlines) {
                let p = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !p.isEmpty && fileManager.fileExists(atPath: p) { candidatePaths.append(p) }
            }
        }
        if let pathsD = try? fileManager.contentsOfDirectory(atPath: "/etc/paths.d") {
            for item in pathsD where !item.hasPrefix(".") {
                let filePath = "/etc/paths.d/\(item)"
                if let content = try? String(contentsOfFile: filePath, encoding: .utf8) {
                    for line in content.components(separatedBy: .newlines) {
                        let p = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !p.isEmpty && fileManager.fileExists(atPath: p) { candidatePaths.append(p) }
                    }
                }
            }
        }
        
        // 2. 基础与包管理器常见路径
        let staticCandidates = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "/opt/local/bin",      // MacPorts
            "/opt/local/sbin",
            "\(home)/.local/bin",
            "\(home)/.cargo/bin",  // Rust / uv / maturin
            "\(home)/.bun/bin",    // Bun
            "\(home)/.volta/bin",  // Volta
            "\(home)/go/bin",      // Go
            "\(home)/Library/pnpm", // pnpm
            "\(home)/.local/share/pnpm",
            "\(home)/.local/share/mise/shims",
            "\(home)/.asdf/shims",
            "\(home)/.fnm/current/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.yarn/bin"
        ]
        
        for p in staticCandidates where fileManager.fileExists(atPath: p) {
            candidatePaths.append(p)
        }
        
        // 3. 动态探测 NVM 全局版本
        let nvmRoot = "\(home)/.nvm/versions/node"
        if let nodeVersions = try? fileManager.contentsOfDirectory(atPath: nvmRoot) {
            for v in nodeVersions.sorted().reversed() {
                let binDir = "\(nvmRoot)/\(v)/bin"
                if fileManager.fileExists(atPath: binDir) { candidatePaths.append(binDir) }
            }
        }
        
        // 4. 动态探测 Pyenv 与 Conda/Miniconda/Miniforge 环境
        let pyenvShims = "\(home)/.pyenv/shims"
        if fileManager.fileExists(atPath: pyenvShims) { candidatePaths.append(pyenvShims) }
        
        let condaRoots = [
            "\(home)/miniconda3/bin",
            "\(home)/miniforge3/bin",
            "\(home)/anaconda3/bin",
            "/opt/homebrew/Caskroom/miniconda/base/bin",
            "/opt/homebrew/Caskroom/miniforge/base/bin"
        ]
        for cRoot in condaRoots where fileManager.fileExists(atPath: cRoot) {
            candidatePaths.append(cRoot)
        }
        
        return candidatePaths
    }
    
    // MARK: - 路径有序去重合并器
    private func mergePATHs(probed: String, fallback: [String]) -> String {
        var seen = Set<String>()
        var result: [String] = []
        let fileManager = FileManager.default
        
        let probedComponents = probed.split(separator: ":").map(String.init)
        for p in probedComponents where !p.isEmpty {
            let clean = (p as NSString).standardizingPath
            if !seen.contains(clean) && fileManager.fileExists(atPath: clean) {
                seen.insert(clean)
                result.append(clean)
            }
        }
        for p in fallback where !p.isEmpty {
            let clean = (p as NSString).standardizingPath
            if !seen.contains(clean) && fileManager.fileExists(atPath: clean) {
                seen.insert(clean)
                result.append(clean)
            }
        }
        return result.joined(separator: ":")
    }
    
    /// 统一构造注入给底层 Process 的安全环境变量字典
    public func buildProcessEnvironment(
        sharedContext: [String: String] = [:],
        args: [String: Any] = [:],
        customEnv: [String: String] = [:]
    ) async -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let fullPath = await getResolvedPATH()
        env["PATH"] = fullPath
        
        // 核心加固：强制注入 UTF-8 编码，防止 GUI 管道中运行 Node/Python 遇到中文表格时闪退
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        
        // 统一注入上下文变量 (CTX_XXX)
        for (k, v) in sharedContext {
            env["CTX_\(k.uppercased())"] = v
        }
        
        // 统一注入参数变量 (ARG_XXX)
        for (k, v) in args {
            let envKey = "ARG_\(k.uppercased())"
            if let dict = v as? [String: Any],
               let jsonData = try? JSONSerialization.data(withJSONObject: dict),
               let jsonStr = String(data: jsonData, encoding: .utf8) {
                env[envKey] = jsonStr
            } else if let arr = v as? [Any],
                      let jsonData = try? JSONSerialization.data(withJSONObject: arr),
                      let jsonStr = String(data: jsonData, encoding: .utf8) {
                env[envKey] = jsonStr
            } else {
                env[envKey] = String(describing: v)
            }
        }
        
        for (k, v) in customEnv { env[k] = v }
        return env
    }
}

/// 技能目录独立监听器 (DispatchSource-based)
final class SkillDirectoryMonitor: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject
    private let descriptor: Int32
    
    init?(directoryURL: URL, onChange: @escaping @Sendable () -> Void) {
        let fd = open(directoryURL.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        self.descriptor = fd
        
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .link],
            queue: .main
        )
        src.setEventHandler(handler: onChange)
        src.setCancelHandler {
            close(fd)
        }
        src.resume()
        self.source = src
    }
    
    func stop() {
        source.cancel()
    }
    
    deinit {
        source.cancel()
    }
}

// MARK: - ==================== 3. SkillSecurity (安全防护与鉴权拦截) ====================

/// 安全规则防毒扫描器
public struct SecurityScanner {
    public static func isSafe(command: String) -> Bool {
        let lowerCmd = command.lowercased()
        let blackList = ["rm -rf /", "rm -rf ~", "mkfs", "dd if=", "> /dev/disk", "chmod -r 777", "chown -r", "crontab -r", "history -c", ":(){ :|:& };:"]
        for word in blackList {
            if lowerCmd.contains(word) {
                print("🛑 [安全拦截] 触发黑名单关键词: \(word)")
                return false
            }
        }
        let dangerPathsPattern = "(rm|mv|cp|chmod|chown)\\s+.*(/etc|/var|/System|/Library|/usr|/bin|/sbin)"
        if let regex = try? NSRegularExpression(pattern: dangerPathsPattern, options: .caseInsensitive) {
            let range = NSRange(location: 0, length: command.utf16.count)
            if regex.firstMatch(in: command, options: [], range: range) != nil {
                print("🛑 [安全拦截] 触发系统级敏感目录保护正则")
                return false
            }
        }
        let powerPattern = "^\\s*(sudo\\s+)?(shutdown|reboot|halt)\\b"
        if let powerRegex = try? NSRegularExpression(pattern: powerPattern, options: .caseInsensitive) {
            let range = NSRange(location: 0, length: command.utf16.count)
            if powerRegex.firstMatch(in: command, options: [], range: range) != nil {
                print("🛑 [安全拦截] 触发电源管理保护正则")
                return false
            }
        }
        return true
    }
}

/// Touch ID 硬件安全拦截 UI 调度控制器
public class SystemAuthUI {
    public enum DangerLevel {
        case low, medium, high
        
        public var color: Color {
            switch self { case .low: return .blue; case .medium: return .orange; case .high: return .red }
        }
        public var icon: String {
            switch self { case .low: return "info.circle.fill"; case .medium: return "exclamationmark.triangle.fill"; case .high: return "touchid" }
        }
    }
    
    @MainActor
    public static func requestUserPermission(title: String, message: String, dangerLevel: DangerLevel) async -> Bool {
        ___triggerBreathing(text: "触控 ID 确认", icon: "touchid", duration: 10.0, style: 1)
        
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 210),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.center()
        
        return await withCheckedContinuation { continuation in
            let authView = TouchIDAuthOverlayView(
                title: title,
                message: message,
                level: dangerLevel,
                onResult: { isAllowed in
                    panel.animator().alphaValue = 0
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        panel.close()
                        ___dynamicIslandEscape(isEscape: true)
                        continuation.resume(returning: isAllowed)
                    }
                }
            )
            
            panel.contentView = NSHostingView(rootView: authView)
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.175, 0.885, 0.32, 1.1)
                panel.animator().alphaValue = 1.0
            }
        }
    }
}

/// Touch ID 悬浮鉴权覆层视图
public struct TouchIDAuthOverlayView: View {
    public let title: String
    public let message: String
    public let level: SystemAuthUI.DangerLevel
    public let onResult: (Bool) -> Void
    
    @State private var isAuthenticating = false
    @State private var timeRemaining = 30
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    public init(title: String, message: String, level: SystemAuthUI.DangerLevel, onResult: @escaping (Bool) -> Void) {
        self.title = title
        self.message = message
        self.level = level
        self.onResult = onResult
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "touchid")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(level.color.gradient)
                    .symbolEffect(.bounce, options: .repeating)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .bold)).foregroundColor(.primary)
                    Text("请轻触 Touch ID 或输入密码以授权").font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer()
                Text("\(timeRemaining)s")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(timeRemaining < 10 ? .red : .secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(Capsule())
            }
            .padding(16)
            
            Divider().opacity(0.5)
            
            ScrollView {
                Text(message)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .frame(maxHeight: 110)
            .background(Color(NSColor.textBackgroundColor).opacity(0.3))
            .forceOverlayScrollbars()
            
            Divider().opacity(0.5)
            
            HStack(spacing: 12) {
                Button(action: { onResult(false) }) {
                    Text("拒绝执行").font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 8)
                .background(Color(NSColor.windowBackgroundColor))
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1), lineWidth: 1))
                .keyboardShortcut(.cancelAction)
                
                Button(action: { triggerTouchID() }) {
                    HStack(spacing: 6) {
                        if isAuthenticating {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "touchid")
                            Text("指纹验证并允许")
                        }
                    }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 8)
                .background(level.color.gradient)
                .cornerRadius(6)
                .disabled(isAuthenticating)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.1), lineWidth: 1))
        .onReceive(timer) { _ in
            if timeRemaining > 0 { timeRemaining -= 1 } else { onResult(false) }
        }
        .onAppear { triggerTouchID() }
    }
    
    private func triggerTouchID() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        
        Task {
            let res = await AdminAuthEngine.shared.authenticateWithBiometrics(reason: "授权执行系统级高危动作: \(title)")
            isAuthenticating = false
            onResult(res.success)
        }
    }
}

/// 支持 Touch ID 与 Agent 人工在环指引的交互协同中枢
public actor UserInteractionManager {
    public static let shared = UserInteractionManager()
    private var continuations: [String: CheckedContinuation<Bool, Never>] = [:]
    private var guidanceContinuations: [String: CheckedContinuation<String?, Never>] = [:]

    // 1. 权限授权通道 (Touch ID / HITL 按钮)
    public func requestPermission(id: String) async -> Bool {
        return await withCheckedContinuation { continuation in
            continuations[id] = continuation
        }
    }

    public func resolvePermission(id: String, allow: Bool) {
        if let continuation = continuations.removeValue(forKey: id) {
            continuation.resume(returning: allow)
        }
    }

    // 2. 人工在环指引与挂起恢复通道 (Pause-and-Resume)
    public func requestHumanGuidance(id: String) async -> String? {
        return await withCheckedContinuation { continuation in
            guidanceContinuations[id] = continuation
        }
    }

    public func resolveHumanGuidance(id: String, guidance: String?) {
        if let continuation = guidanceContinuations.removeValue(forKey: id) {
            continuation.resume(returning: guidance)
        }
    }
}

// MARK: - 允许接管键盘焦点的原生浮动面板子类
private final class KeyInterventionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 原生人工在环 (HITL) 悬浮交互控制台
@MainActor
public final class AgentInterventionUI {
    public static func requestGuidance(
        agentName: String,
        reason: String,
        suggestedActions: [String] = []
    ) async -> String? {
        let panel = KeyInterventionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 320),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.center()
        
        return await withCheckedContinuation { continuation in
            let interventionView = AgentInterventionPanel(
                agentName: agentName,
                reason: reason,
                suggestedActions: suggestedActions,
                onSubmit: { guidance in
                    panel.animator().alphaValue = 0
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        panel.close()
                        continuation.resume(returning: guidance)
                    }
                },
                onCancel: {
                    panel.animator().alphaValue = 0
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        panel.close()
                        continuation.resume(returning: nil)
                    }
                }
            )
            
            panel.contentView = NSHostingView(rootView: interventionView)
            panel.alphaValue = 0
            
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
            
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                panel.animator().alphaValue = 1.0
            }
        }
    }
}

/// 人工介入控制台面板视图
public struct AgentInterventionPanel: View {
    public let agentName: String
    public let reason: String
    public let suggestedActions: [String]
    public let onSubmit: (String) -> Void
    public let onCancel: () -> Void
    
    @State private var inputText: String = ""
    @FocusState private var isInputFocused: Bool
    
    public init(agentName: String, reason: String, suggestedActions: [String], onSubmit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.agentName = agentName
        self.reason = reason
        self.suggestedActions = suggestedActions
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.18))
                        .frame(width: 32, height: 32)
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.orange)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("智能体推演挂起 · 请求人工指引")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.primary)
                    Text("[\(agentName)] 需要进一步的操作指示以继续推进任务")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)
            
            Divider().opacity(0.3)
            
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                        .padding(.top, 1)
                    Text(reason)
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.06))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.18), lineWidth: 1))
                
                if !suggestedActions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("快捷选项")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                        
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(suggestedActions, id: \.self) { action in
                                    Button(action: { onSubmit(action) }) {
                                        Text(action)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(.blue)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 4)
                                            .background(Color.blue.opacity(0.1))
                                            .cornerRadius(6)
                                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.blue.opacity(0.2), lineWidth: 1))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.top, 2)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("补充指示或调整要求")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    
                    TextField("输入具体指引，按 ⌘ + Return 快速恢复推演...", text: $inputText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .lineLimit(2...4)
                        .focused($isInputFocused)
                        .padding(8)
                        .background(Color(NSColor.textBackgroundColor).opacity(0.6))
                        .cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12), lineWidth: 1))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            
            Divider().opacity(0.3)
            
            HStack(spacing: 10) {
                Button(action: onCancel) {
                    Text("终止推演 (Esc)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button(action: {
                    let finalGuidance = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSubmit(finalGuidance.isEmpty ? "追加步数继续执行" : finalGuidance)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10))
                        Text("恢复推演")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.blue.gradient)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 440)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.15), lineWidth: 1))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isInputFocused = true
            }
        }
    }
}

// MARK: - ==================== 4. SkillDiscovery (动态扫描与内置技能名录) ====================

/// 本地物理技能扫描与装配引擎
public struct LocalSkillScanner {
    public static func scanAndMount() -> [AgentSkill] {
        var scannedItems: [(skill: AgentSkill, order: Int)] = []
        let fileManager = FileManager.default
        
        guard let skillsPath = ConfigManager.shared.skillsPath,
              let subDirs = try? fileManager.contentsOfDirectory(at: skillsPath, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey], options: .skipsHiddenFiles) else {
            print("⚠️ [SkillScanner] 找不到 skills 目录或目录为空")
            return []
        }
        
        let comprehensivePaths = buildComprehensiveSearchPaths()
        
        for dir in subDirs {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            
            let fileAttributes = try? fileManager.attributesOfItem(atPath: dir.path)
            let folderCreationDate = fileAttributes?[.creationDate] as? Date ?? Date()
            
            let defaultSkillName = dir.lastPathComponent
            let manifestURL = dir.appendingPathComponent("manifest.json")
            
            // 策略 A: 标准 manifest.json 模式
            if fileManager.fileExists(atPath: manifestURL.path),
               let data = try? Data(contentsOf: manifestURL),
               let manifest = try? JSONDecoder().decode(SkillPackageManifest.self, from: data) {
                
                var detailedDocs = ""
                let possibleDocs = ["skill.md", "SKILL.md", "readme.md", "README.md"]
                for docName in possibleDocs {
                    let docURL = dir.appendingPathComponent(docName)
                    if let mdContent = try? String(contentsOf: docURL, encoding: .utf8) {
                        detailedDocs = mdContent; break
                    }
                }
                
                let mappedType = mapTypeString(manifest.type ?? "shell")
                let scriptURL = dir.appendingPathComponent(manifest.entryPoint)
                let executionBody = (try? String(contentsOf: scriptURL, encoding: .utf8)) ?? manifest.entryPoint
                
                let params = manifest.parameters?.map {
                    SkillParameter(name: $0.name, type: ParameterType(rawValue: $0.type) ?? .string, description: $0.description, isRequired: $0.isRequired)
                } ?? []
                
                let skill = AgentSkill(
                    name: manifest.name.replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_"),
                    displayName: manifest.displayName ?? manifest.name,
                    description: manifest.description,
                    detailedInstruction: detailedDocs,
                    type: mappedType,
                    parameters: params,
                    executionBody: executionBody,
                    isEnabled: true,
                    requiresConfirmation: manifest.requiresConfirmation ?? false,
                    outputKey: manifest.outputKey ?? "\(manifest.name)_output",
                    isLocal: true,
                    workingDirectory: dir.path,
                    entryPoint: manifest.entryPoint,
                    createdAt: folderCreationDate,
                    category: manifest.category ?? "自定义"
                )
                
                let sortOrder = manifest.order ?? 9999
                scannedItems.append((skill: skill, order: sortOrder))
                continue
            }
            
            // 策略 B: 智能自适应模式 (无配置无感接入)
            let skillMdURL = dir.appendingPathComponent("SKILL.md")
            let scriptsDir = dir.appendingPathComponent("scripts")
            let fullMarkdown = (try? String(contentsOf: skillMdURL, encoding: .utf8)) ?? ""
            let lines = fullMarkdown.components(separatedBy: .newlines)
            
            var parsedName = defaultSkillName
            var parsedDescription = ""
            var parsedCategory = "自定义"
            var parsedOrder = 9999
            var explicitTypeStr: String? = nil
            
            if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
                var frontmatterEndIndex = 0
                for (index, line) in lines.enumerated().dropFirst() {
                    if line.trimmingCharacters(in: .whitespaces) == "---" { frontmatterEndIndex = index; break }
                    let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    if parts.count == 2 {
                        let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                        let value = parts[1].trimmingCharacters(in: .whitespaces)
                        if key == "name" { parsedName = value }
                        else if key == "description" { parsedDescription = value }
                        else if key == "category" { parsedCategory = value }
                        else if key == "type" { explicitTypeStr = value }
                        else if key == "order", let orderVal = Int(value) { parsedOrder = orderVal }
                    }
                }
                if parsedDescription.isEmpty && frontmatterEndIndex > 0 && frontmatterEndIndex < lines.count - 1 {
                    let bodyLines = lines[(frontmatterEndIndex + 1)...]
                    parsedDescription = bodyLines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }) ?? "\(parsedName) 工具"
                }
            } else {
                parsedDescription = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }) ?? "\(parsedName) 工具"
            }
            
            let (detectedType, entryPoint, executionBody) = detectSkillTypeAndBody(
                dirURL: dir,
                scriptsDirURL: scriptsDir,
                markdown: fullMarkdown,
                explicitTypeStr: explicitTypeStr,
                skillName: parsedName,
                systemPaths: comprehensivePaths
            )
            
            var parameters: [SkillParameter] = []
            if detectedType == .cli {
                parameters = [
                    SkillParameter(
                        name: "command",
                        type: .string,
                        description: "直接传入要执行的命令与参数字符串，例如: 'app list' 或 'workflow list --app 17'",
                        isRequired: true
                    )
                ]
            } else {
                parameters = [
                    SkillParameter(
                        name: "raw_command",
                        type: .string,
                        description: "要执行的脚本指令或命令参数",
                        isRequired: true
                    )
                ]
            }
            
            let skill = AgentSkill(
                name: parsedName.replacingOccurrences(of: " ", with: "_"),
                displayName: parsedName,
                description: parsedDescription,
                detailedInstruction: fullMarkdown,
                type: detectedType,
                parameters: parameters,
                executionBody: executionBody,
                isEnabled: true,
                requiresConfirmation: false,
                outputKey: "\(parsedName)_output",
                isLocal: true,
                workingDirectory: dir.path,
                entryPoint: entryPoint,
                createdAt: folderCreationDate,
                category: parsedCategory
            )
            
            scannedItems.append((skill: skill, order: parsedOrder))
            print("✅ [SkillScanner] 识别并挂载技能: \(parsedName) -> [\(detectedType.rawValue)]")
        }
        
        scannedItems.sort { $0.order < $1.order }
        return scannedItems.map { $0.skill }
    }
    
    private static func detectSkillTypeAndBody(
        dirURL: URL,
        scriptsDirURL: URL,
        markdown: String,
        explicitTypeStr: String?,
        skillName: String,
        systemPaths: [String]
    ) -> (type: SkillType, entryPoint: String, executionBody: String) {
        let fileManager = FileManager.default
        
        // 1. 显式声明优先
        if let explicit = explicitTypeStr, !explicit.isEmpty {
            let mapped = mapTypeString(explicit)
            let (ep, body) = extractBodyForType(type: mapped, defaultName: skillName, markdown: markdown)
            return (mapped, ep, body)
        }
        
        // 2. 本地物理脚本文件检索 (Python / AppleScript / Shell)
        var candidates: [URL] = []
        if let rootFiles = try? fileManager.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil) {
            candidates.append(contentsOf: rootFiles)
        }
        if fileManager.fileExists(atPath: scriptsDirURL.path),
           let scriptFiles = try? fileManager.contentsOfDirectory(at: scriptsDirURL, includingPropertiesForKeys: nil) {
            candidates.append(contentsOf: scriptFiles)
        }
        
        if let pyFile = candidates.first(where: { $0.pathExtension.lowercased() == "py" }) {
            let body = (try? String(contentsOf: pyFile, encoding: .utf8)) ?? ""
            let relPath = pyFile.path.replacingOccurrences(of: dirURL.path + "/", with: "")
            return (.python, relPath, body)
        }
        
        if let scptFile = candidates.first(where: { ["scpt", "applescript"].contains($0.pathExtension.lowercased()) }) {
            let body = (try? String(contentsOf: scptFile, encoding: .utf8)) ?? ""
            let relPath = scptFile.path.replacingOccurrences(of: dirURL.path + "/", with: "")
            return (.applescript, relPath, body)
        }
        
        if let shFile = candidates.first(where: { ["sh", "bash", "zsh"].contains($0.pathExtension.lowercased()) }) {
            let body = (try? String(contentsOf: shFile, encoding: .utf8)) ?? ""
            let relPath = shFile.path.replacingOccurrences(of: dirURL.path + "/", with: "")
            return (.shell, relPath, body)
        }
        
        // 3. CLI 宿主程序探针：建立确定性候选优先级队列
        var orderedCandidates: [String] = []
        var seenCandidates = Set<String>()
        
        func appendCandidate(_ cmd: String) {
            let clean = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean.count >= 2, !seenCandidates.contains(clean) else { return }
            seenCandidates.insert(clean)
            orderedCandidates.append(clean)
        }
        
        // 系统命令与运行时黑名单 (严格排除 command, which, test 等系统封装脚本)
        let systemToolBlacklist: Set<String> = [
            "command", "which", "test", "env", "echo", "type", "true", "false",
            "npm", "npx", "node", "nodejs", "pnpm", "pnpx", "yarn", "bun", "bunx",
            "python", "python3", "pip", "pip3", "brew", "git", "bash", "sh", "zsh",
            "cat", "curl", "wget", "rm", "cp", "mv", "chmod", "chown", "sudo",
            "ls", "cd", "mkdir", "export", "source", "install", "unlink", "link",
            "grep", "sed", "awk", "kill", "ps", "top", "open", "clear"
        ]
        
        // 优先级 A：从本地 package.json 提取 bin 执行体
        let pkgURL = dirURL.appendingPathComponent("package.json")
        if fileManager.fileExists(atPath: pkgURL.path),
           let data = try? Data(contentsOf: pkgURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let binStr = json["bin"] as? String {
                let base = (binStr as NSString).lastPathComponent
                appendCandidate((base as NSString).deletingPathExtension)
            } else if let binDict = json["bin"] as? [String: Any] {
                for key in binDict.keys {
                    appendCandidate(key)
                }
            }
        }
        
        // 优先级 B：从技能名拆解的短标识 (如 weaver-e9-assistant 拆解出 e9)
        let subTokens = skillName.components(separatedBy: CharacterSet(charactersIn: "-_"))
        for token in subTokens {
            let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.count >= 2 && clean.count <= 6 && !systemToolBlacklist.contains(clean.lowercased()) {
                appendCandidate(clean)
            }
        }
        
        // 优先级 C：从 Markdown 代码块及反引号中提取高频主命令
        let codeBlockPattern = #"(?m)(?:```(?:bash|sh|zsh|cli)?[\r\n]+|`)([a-zA-Z0-9_-]{2,16})(?:\s+[^`\r\n]*)?(?:```|`)"#
        if let regex = try? NSRegularExpression(pattern: codeBlockPattern) {
            let matches = regex.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown))
            var freqMap: [String: Int] = [:]
            for m in matches {
                if let r = Range(m.range(at: 1), in: markdown) {
                    let cmd = String(markdown[r]).lowercased()
                    if !systemToolBlacklist.contains(cmd) {
                        freqMap[cmd, default: 0] += 1
                    }
                }
            }
            for (cmd, _) in freqMap.sorted(by: { $0.value > $1.value }) {
                appendCandidate(cmd)
            }
        }
        
        // 优先级 D：技能派生全名
        let strippedName = skillName.replacingOccurrences(of: "^skill[-_]", with: "", options: .regularExpression)
        appendCandidate(skillName)
        appendCandidate(strippedName)
        appendCandidate(skillName.replacingOccurrences(of: "_", with: "-"))
        appendCandidate(dirURL.lastPathComponent.replacingOccurrences(of: "^skill[-_]", with: "", options: .regularExpression))
        
        // 遍历有序候选集，在系统 PATH 中探测实体
        for cmd in orderedCandidates {
            if systemToolBlacklist.contains(cmd.lowercased()) { continue }
            
            for searchPath in systemPaths {
                let binaryPath = (searchPath as NSString).appendingPathComponent(cmd)
                if fileManager.isExecutableFile(atPath: binaryPath) {
                    return (.cli, cmd, cmd)
                }
            }
        }
        
        // 4. 文档内联代码块探针
        let pattern = "(?s)```(python|bash|sh|shell|zsh|applescript|cli)\\s*\\n(.*?)```"
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let nsString = markdown as NSString
            let results = regex.matches(in: markdown, options: [], range: NSRange(location: 0, length: nsString.length))
            if let firstMatch = results.first {
                let lang = nsString.substring(with: firstMatch.range(at: 1)).lowercased()
                let code = nsString.substring(with: firstMatch.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                
                if lang == "python" { return (.python, "SKILL.md (Inline Python)", code) }
                if lang == "applescript" { return (.applescript, "SKILL.md (Inline AppleScript)", code) }
                if lang == "cli" { return (.cli, code, code) }
                return (.shell, "SKILL.md (Inline Shell)", code)
            }
        }
        
        // 5. 最终降级兜底：透传 Shell 代理执行
        let defaultShellScript = """
        if [ -n "$ARG_RAW_COMMAND" ]; then
            eval "$ARG_RAW_COMMAND"
        else
            echo "未接收到执行指令，请传入 raw_command 参数。"
            exit 1
        fi
        """
        return (.shell, "SKILL.md (Instruction Only)", defaultShellScript)
    }
    
    private static func buildComprehensiveSearchPaths() -> [String] {
        var paths: [String] = []
        if let currentPath = ProcessInfo.processInfo.environment["PATH"] {
            paths.append(contentsOf: currentPath.split(separator: ":").map(String.init))
        }
        
        let home = NSHomeDirectory()
        let directProbes = [
            "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin",
            "\(home)/.cargo/bin", "\(home)/.bun/bin", "\(home)/Library/pnpm",
            "\(home)/.npm-global/bin", "/usr/bin", "/bin"
        ]
        paths.append(contentsOf: directProbes)
        
        var seen = Set<String>()
        return paths.filter { p in
            let clean = (p as NSString).standardizingPath
            if !seen.contains(clean) && FileManager.default.fileExists(atPath: clean) {
                seen.insert(clean)
                return true
            }
            return false
        }
    }
    
    private static func extractBodyForType(type: SkillType, defaultName: String, markdown: String) -> (entryPoint: String, executionBody: String) {
        let cleanCmd = defaultName.replacingOccurrences(of: "^skill[-_]", with: "", options: .regularExpression)
        if type == .cli {
            return (cleanCmd, cleanCmd)
        }
        return ("SKILL.md (Auto)", markdown)
    }
    
    public static func mapTypeString(_ typeStr: String) -> SkillType {
        let lower = typeStr.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.contains("python") { return .python }
        if lower.contains("applescript") || lower.contains("osascript") { return .applescript }
        if lower.contains("api") || lower.contains("http") || lower.contains("rest") { return .api }
        if lower.contains("cli") || lower.contains("command") || lower.contains("binary") { return .cli }
        if lower.contains("mcp") { return .mcp }
        return .shell
    }
    
    public static func makeDeterministicID(for skillName: String) -> UUID {
        return UUID.deterministic(from: "skill_local_\(skillName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())")
    }
}

// MARK: - 系统内置技能工厂 (Builtin Skills Factory)

public func Skill_Evolve() -> AgentSkill {
    AgentSkill(
        name: "skill_creator",
        displayName: "🐲 自我进化与维护引擎",
        description: "【核心底层能力】当你需要创建新工具，或者【修复/升级】现有工具时调用此工具。支持局部更新：如果要修改现有技能，只需传入 skillName 和 需要修改的特定字段（例如：只传 manual 更新文档，或只传 code 修复代码），未传入的字段将保持原状。",
        detailedInstruction: "",
        type: .builtin,
        parameters: [
            SkillParameter(name: "skillName", type: .string, description: "由你命名的纯英文技能名，如 fetch_news（必填项）", isRequired: true),
            SkillParameter(name: "type", type: .string, description: "python 或 shell 或 cli。如果是更新现有技能，且不改变语言类型，请留空不传。", isRequired: false),
            SkillParameter(name: "code", type: .string, description: "完整可执行代码或可执行命令。如果是局部更新且不修改代码，请留空。更新时会自动备份旧代码。", isRequired: false),
            SkillParameter(name: "description", type: .string, description: "该技能的中文简述。如果是更新现有技能且不修改描述，请留空。", isRequired: false),
            SkillParameter(name: "manual", type: .string, description: "详细使用手册（Markdown格式）。如果是更新代码而不需要改说明书，请留空。", isRequired: false)
        ],
        executionBody: "builtin_evolve",
        isEnabled: true,
        requiresConfirmation: false,
        outputKey: "",
        isLocal: false,
        category: "系统"
    )
}

func Skill_ReadManual(skillsBasePath: String? = nil) -> AgentSkill {
    let basePath = skillsBasePath ?? ConfigManager.shared.skillsPath?.path ?? ""
    return AgentSkill(
        name: "read_skill_manual",
        displayName: "📚 查阅技能手册",
        description: "按需查阅指定技能的说明书或子目录下的扩展文档。支持渐进式内省发现参数规格与指令用法。",
        detailedInstruction: "传入 target_skill_name 获取主手册；可选用 doc_path 指定子文档（如 'docs/api.md'）。",
        type: .builtin,
        parameters: [
            SkillParameter(name: "target_skill_name", type: .string, description: "需要查询的目标技能名称 (skill_name)", isRequired: true),
            SkillParameter(name: "doc_path", type: .string, description: "可选：技能目录下的相对文档路径，默认为主 SKILL.md", isRequired: false)
        ],
        executionBody: "builtin_read_manual",
        isEnabled: true,
        requiresConfirmation: false,
        outputKey: "manual_content",
        isLocal: false,
        workingDirectory: basePath,
        entryPoint: "",
        category: "系统"
    )
}

public func Skill_ExecuteSkill() -> AgentSkill {
    AgentSkill(
        name: "execute_skill",
        displayName: "⚡️ 执行技能与命令",
        description: "通用物理执行代理。请先阅读对应目标技能的手册掌握规范后，再将具体的执行命令或参数传递至此。",
        detailedInstruction: "通用执行入口。如果目标工具规范要求通过外部文件传递配置数据（例如传入 @fields.json），系统底层具备自动桥接能力：请直接在 input 参数中写入该文件的完整 JSON 数据结构，系统会自动将其存为临时文件并替换执行命令。",
        type: .builtin,
        parameters: [
            SkillParameter(name: "skill_name", type: .string, description: "需要执行的目标技能或 CLI 工具名称", isRequired: true),
            SkillParameter(name: "input", type: .string, description: "执行参数：传入子命令或结构化数据。若规范要求文件路径，请直接传入完整的 JSON 字符串数据。", isRequired: true)
        ],
        executionBody: "builtin_unified_runner",
        isEnabled: true,
        requiresConfirmation: false,
        outputKey: "skill_execution_result",
        isLocal: false,
        category: "系统"
    )
}

public func Skill_MemoryManager() -> AgentSkill {
    AgentSkill(
        name: "skill_memory_manager",
        displayName: "🧠 长效记忆管理器",
        description: "当用户表达长期偏好、习惯、个人身份或关键环境参数时，调用此工具进行物理存储（action='save'）或检索（action='search'）。",
        detailedInstruction: "action: 可选 'save' 或 'search'。\ncategory: 可选 '用户画像' | '项目环境' | '避坑指南' | '短期备忘'。\nimportance: 1 到 10 的整数。",
        type: .builtin,
        parameters: [
            SkillParameter(name: "action", type: .string, description: "操作类型: 'save' (存入) 或 'search' (检索)", isRequired: true),
            SkillParameter(name: "content", type: .string, description: "要记录或搜索的具体文本", isRequired: true),
            SkillParameter(name: "category", type: .string, description: "分类(保存时填写)", isRequired: false),
            SkillParameter(name: "importance", type: .number, description: "重要度评分 1-10 (保存时填写)", isRequired: false)
        ],
        executionBody: "builtin_memory",
        isEnabled: true,
        requiresConfirmation: false,
        category: "系统"
    )
}

public func Skill_CallAgent() -> AgentSkill {
    AgentSkill(
        name: "call_sub_agent",
        displayName: "🤖 召唤专家智能体",
        description: "当遇到特定领域的复杂任务，需要具备专门技能或背景知识的专家协助时调用。请从系统已注册的专家名单中指定 agent_name 并指派任务。",
        detailedInstruction: "传入目标专家的 agent_name 与详尽的 task_instruction。",
        type: .builtin,
        parameters: [
            SkillParameter(name: "agent_name", type: .string, description: "需要唤醒的目标专家名称", isRequired: true),
            SkillParameter(name: "task_instruction", type: .string, description: "给该专家的任务指令、上下文背景与期望产出格式", isRequired: true)
        ],
        executionBody: "builtin_call_agent",
        isEnabled: true,
        requiresConfirmation: false,
        category: "系统"
    )
}

public func Skill_Finish() -> AgentSkill {
    AgentSkill(
        name: "finish_task",
        displayName: "✅ 提交最终结果与验证证据",
        description: "完成全部业务操作并通过物理读回命令获取证据后调用此工具，用于正式提交交付物与读回数据以供系统公证结单。",
        detailedInstruction: "请将前置查询命令获取的真实输出数据作为证据提交。系统无头公证员将据此进行客观校验。",
        type: .builtin,
        parameters: [
            SkillParameter(name: "final_answer", type: .string, description: "交付给用户的最终回答或总结报告（支持 Markdown）", isRequired: true),
            SkillParameter(name: "verification_evidence", type: .string, description: "请填入上一步物理查询指令（如 list/info）返回的真实控制台输出原文。请保持数据原貌，避免自行概括或重构。", isRequired: true),
            SkillParameter(name: "status", type: .string, description: "任务状态：'success' 或 'failed'", isRequired: false)
        ],
        executionBody: "builtin_finish",
        isEnabled: true,
        requiresConfirmation: false,
        isLocal: false,
        category: "系统"
    )
}

public func Skill_KnowledgeSearch() -> AgentSkill {
    AgentSkill(
        name: "knowledge_search",
        displayName: "📚 检索知识库",
        description: "【核心底层能力】当需要查询技术文档、业务规范或你无法确认的知识时调用。请先消除代词指代，并提炼出精准的检索关键词。",
        detailedInstruction: "query: 提炼后的精准搜索关键词或语义提问。category: 可选，指定知识库分类名称（留空则默认搜索当前 Agent 绑定的分类或全局）。",
        type: .builtin,
        parameters: [
            SkillParameter(name: "query", type: .string, description: "提炼后的精准检索关键词或语义提问", isRequired: true),
            SkillParameter(name: "category", type: .string, description: "可选：知识库分类名称，留空检索 Agent 绑定分类", isRequired: false)
        ],
        executionBody: "builtin_knowledge_search",
        isEnabled: true,
        requiresConfirmation: false,
        category: "系统"
    )
}

public func Skill_CallPersona(boundPersonas: [DigitalPersona] = []) -> AgentSkill {
    let targetPersonas = boundPersonas.isEmpty ? [] : boundPersonas
    let personaDescriptions = targetPersonas.map { p in
        let role = p.roleTag.isEmpty ? "" : "(\(p.roleTag))"
        let summary = p.summary.isEmpty ? "" : ": \(p.summary)"
        return "• \(p.name)\(role)\(summary)"
    }.joined(separator: "\n")
    
    let paramDesc = targetPersonas.isEmpty
        ? "当前系统暂无可用数字分身，请先在分身工坊中创建。"
        : "可选分身名单:\n\(personaDescriptions)"
    
    return AgentSkill(
        name: "call_digital_persona",
        displayName: "🎭 呼叫数字分身",
        description: "当你需要与特定的数字分身进行拟人化角色扮演、对戏、情境咨询时调用。系统将在独立心智沙盒中运行，自动维系羁绊度与记忆。",
        detailedInstruction: "必须严格从可选名单中指定 persona_name，并下发 dialogue_input 开展对戏。",
        type: .builtin,
        parameters: [
            SkillParameter(name: "persona_name", type: .string, description: paramDesc, isRequired: true),
            SkillParameter(name: "dialogue_input", type: .string, description: "向该分身表达的对白、互动指令或提问", isRequired: true),
            SkillParameter(name: "scene_context", type: .string, description: "可选：当前场景舞台设定、空间氛围或需要分身知晓的临时情境", isRequired: false)
        ],
        executionBody: "builtin_call_persona",
        isEnabled: true,
        requiresConfirmation: false,
        category: "系统"
    )
}

// MARK: - 终端命令执行器 (内置系统级技能)
/// 提供在宿主机直接执行 Shell 命令与内联脚本的基础环境
/// - Returns: 配置了完备自愈机制与 Word/文件操作范式的 AgentSkill
public func Skill_Terminal() -> AgentSkill {
    let manualContent = """
    ---
    name: system_terminal
    description: 宿主机通用终端与脚本执行环境
    category: 系统
    ---

    # 💻 通用终端与自动化执行手册

    本工具用于在宿主机环境执行 Shell 命令、临时 Python 脚本以及基础文件系统操作。专有业务领域接口请通过 execute_skill 对应调用。

    ## 1. 富文本与 Office 文档生成范式 (Word / Excel)
    当需要为用户生成 Word (.docx) 或数据表格时，推荐通过内联 Python 脚本一步完成。

    ### Word (.docx) 标准执行模版：
    ```bash
    python3 - << 'EOF'
    import sys, os

    # 1. 依赖动态自愈检查
    try:
        import docx
    except ImportError:
        os.system("pip3 install -q python-docx")
        import docx

    from docx import Document
    from docx.shared import Pt, Inches, RGBColor

    doc = Document()
    doc.add_heading('文档标题', level=1)
    doc.add_paragraph('正文段落内容...')

    # 2. 规范交付路径：统一落地至用户 Downloads 目录
    out_dir = os.path.expanduser("~/Downloads")
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, "交付文档.docx")

    doc.save(out_path)
    print(f"FILE_CREATED_SUCCESS: {out_path}")
    EOF
    ```

    ## 2. 基础文件与归档操作范式
    - 中间过程临时解压（用于安装、编译、检查文件内容等中间步骤）：
      推荐优先解压到系统临时目录（如 `/tmp/<包名>`），系统会自动回收临时空间，保持宿主环境整洁。
      示例：`unzip -q -o "archive.zip" -d "/tmp/pkg_temp" && cd "/tmp/pkg_temp"`
    - 最终目标解压（用户明确要求解压文件到本地留存）：
      解压至用户指定路径或 `~/Downloads/<目录>`，并向用户交付解压后的物理绝对路径。
    - 归档检查：调用 `unzip -l "archive.zip"` 查看目录清单。
    - 验证安装：`npm list -g --depth=0` 或 `which <cmd> && <cmd> --version`。

    ## 3. 产物交付与凭据准则
    - 脚本执行结束时，在控制台输出真实控制台回显。
    - 结单阶段将控制台输出作为有效客观凭据交付。
    """

    let executionBody = #"""
    #!/usr/bin/env zsh

    # 1. 兼容多入参键名 (自适应 raw_command / input / command)
    CMD="${ARG_RAW_COMMAND:-${ARG_INPUT:-$ARG_COMMAND}}"
    if [ -z "$CMD" ]; then
        echo "【自愈提示】: 未接收到执行指令，请传入具体的待执行命令或脚本。"
        exit 1
    fi

    # 2. 静默与非交互式运行环境注入 (防死锁与 ANSI 颜色污染)
    export TERM=dumb
    export NO_COLOR=1
    export CI=true
    export DEBIAN_FRONTEND=noninteractive
    export PYTHONUNBUFFERED=1

    # 3. 波浪号绝对路径安全展开
    CMD="${CMD/#\~/$HOME}"
    CMD="${CMD//\~\//$HOME/}"

    # 4. 局部虚拟环境（.venv / node_modules）自动感知与 PATH 优先注入
    if [ -d "venv/bin" ]; then
        export PATH="$(pwd)/venv/bin:$PATH"
    elif [ -d ".venv/bin" ]; then
        export PATH="$(pwd)/.venv/bin:$PATH"
    fi
    if [ -d "node_modules/.bin" ]; then
        export PATH="$(pwd)/node_modules/.bin:$PATH"
    fi

    # 5. 执行指令 (关闭 stdin 防止终端交互阻塞，合并 stdout 与 stderr，原汁原味返回)
    eval "$CMD" </dev/null 2>&1
    exit $?
    """#

    return AgentSkill(
        name: "system_terminal",
        displayName: "💻 终端脚本执行器",
        description: "【通用基础工具】用于在宿主机执行系统级基础操作（如文件解压归档、目录检查、临时 Python 脚本生成 Word/Excel 文档等）。专有业务领域接口请通过 execute_skill 对应调用。",
        detailedInstruction: manualContent,
        type: .shell,
        parameters: [
            SkillParameter(
                name: "raw_command",
                type: .string,
                description: "要执行的 Shell 命令或内联脚本，例如: unzip -l archive.zip 或 npm list -g --depth=0",
                isRequired: true
            )
        ],
        executionBody: executionBody,
        isEnabled: true,
        requiresConfirmation: false,
        outputKey: "shell_output",
        isLocal: false,
        category: "系统"
    )
}

// MARK: - ==================== 5. Skill Execution & Manual Architecture (解耦架构) ====================

// MARK: - 5.1 SkillBinaryResolver: 可执行实体识别与别名推导引擎
/// 负责技能宿主程序、物理别名挖掘及系统环境工具黑名单管控
public enum SkillBinaryResolver {
    
    /// POSIX 保留命令、系统包装脚本与包管理器黑名单（杜绝文档排错文本误抢占为工具实体）
    public static let systemToolBlacklist: Set<String> = [
        "command", "which", "test", "env", "echo", "type", "true", "false",
        "npm", "npx", "node", "nodejs", "pnpm", "pnpx", "yarn", "bun", "bunx",
        "python", "python3", "pip", "pip3", "brew", "git", "bash", "sh", "zsh",
        "cat", "curl", "wget", "rm", "cp", "mv", "chmod", "chown", "sudo",
        "ls", "cd", "mkdir", "export", "source", "install", "unlink", "link",
        "grep", "sed", "awk", "kill", "ps", "top", "open", "clear"
    ]
    
    /// 动态挖掘技能的全部物理特征别名集合 (覆盖完整名称、连字符短词及文档中的高频命令)
    /// - Parameters:
    ///   - skill: 目标技能实体
    ///   - workingDirectory: 技能物理工作区目录
    /// - Returns: 经过清洗的特征别名哈希集合
    public static func resolveDynamicPhysicalAliases(skill: AgentSkill, workingDirectory: String) -> Set<String> {
        var aliases: Set<String> = []
        
        // 1. 提取执行体自身标识
        let execBody = skill.executionBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if !execBody.isEmpty {
            let base = (execBody as NSString).lastPathComponent.lowercased()
            aliases.insert(execBody.lowercased())
            aliases.insert(base)
            aliases.insert((base as NSString).deletingPathExtension)
        }
        
        // 2. 提取入口脚本标识
        if let entry = skill.entryPoint?.trimmingCharacters(in: .whitespacesAndNewlines), !entry.isEmpty {
            let base = (entry as NSString).lastPathComponent.lowercased()
            aliases.insert(entry.lowercased())
            aliases.insert(base)
            aliases.insert((base as NSString).deletingPathExtension)
        }
        
        // 3. 提取技能标识及其连字符拆分词元 (如 weaver-e9-assistant 提取 e9)
        let sName = skill.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !sName.isEmpty {
            aliases.insert(sName)
            let stripped = sName.replacingOccurrences(of: "^skill[-_]", with: "", options: .regularExpression)
            aliases.insert(stripped)
            let withoutCli = stripped.replacingOccurrences(of: "[-_]cli$", with: "", options: .regularExpression)
            if !withoutCli.isEmpty { aliases.insert(withoutCli) }
            
            let subTokens = sName.components(separatedBy: CharacterSet(charactersIn: "-_"))
            for token in subTokens {
                let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleanToken.count >= 2 && cleanToken.count <= 6 && !systemToolBlacklist.contains(cleanToken) {
                    aliases.insert(cleanToken)
                }
            }
        }
        
        // 4. 从说明文档中提取最高频的反引号命令名称 (如 `e9 version` 提取 e9)
        if !skill.detailedInstruction.isEmpty {
            let cliRegex = try? NSRegularExpression(pattern: #"(?m)(?:```(?:bash|sh|zsh|cli)?[\r\n]+|`)([a-zA-Z0-9_-]{2,10})(?:\s+[^`\r\n]*)?(?:```|`)"#)
            if let matches = cliRegex?.matches(in: skill.detailedInstruction, range: NSRange(skill.detailedInstruction.startIndex..., in: skill.detailedInstruction)) {
                var frequencyMap: [String: Int] = [:]
                for m in matches {
                    if let r = Range(m.range(at: 1), in: skill.detailedInstruction) {
                        let cmd = String(skill.detailedInstruction[r]).lowercased()
                        if !systemToolBlacklist.contains(cmd) {
                            frequencyMap[cmd, default: 0] += 1
                        }
                    }
                }
                if let topCmd = frequencyMap.sorted(by: { $0.value > $1.value }).first?.key {
                    aliases.insert(topCmd)
                }
            }
        }
        
        // 5. 探针本地 package.json 的 bin 声明
        if !workingDirectory.isEmpty {
            let pkgURL = URL(fileURLWithPath: workingDirectory).appendingPathComponent("package.json")
            if FileManager.default.fileExists(atPath: pkgURL.path),
               let data = try? Data(contentsOf: pkgURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                
                if let pkgName = json["name"] as? String {
                    let cleanPkgName = pkgName.replacingOccurrences(of: "^@[^/]+/", with: "", options: .regularExpression).lowercased()
                    aliases.insert(pkgName.lowercased())
                    aliases.insert(cleanPkgName)
                }
                
                if let binStr = json["bin"] as? String {
                    let binBase = (binStr as NSString).lastPathComponent.lowercased()
                    aliases.insert(binBase)
                    aliases.insert((binBase as NSString).deletingPathExtension)
                } else if let binDict = json["bin"] as? [String: Any] {
                    for (binKey, binVal) in binDict {
                        aliases.insert(binKey.lowercased())
                        if let binPath = binVal as? String {
                            let binBase = (binPath as NSString).lastPathComponent.lowercased()
                            aliases.insert(binBase)
                            aliases.insert((binBase as NSString).deletingPathExtension)
                        }
                    }
                }
            }
        }
        
        return aliases.filter { $0.count >= 2 }
    }
    
    /// 推导当前技能最具代表性的主程序可执行文件名 (优先选择最精炼的专属别名，如 e9)
    /// - Parameters:
    ///   - skill: 目标技能实体
    ///   - workingDirectory: 工作区目录
    ///   - aliases: 已生成的特征别名池
    /// - Returns: 确定的主执行程序名称
    public static func resolvePrimaryBinaryName(skill: AgentSkill, workingDirectory: String, aliases: Set<String>) -> String? {
        // 1. 优先提取 2~6 字符且代表主程序的短标识 (如 e9)
        let shortCandidates = aliases.filter {
            !$0.contains("-cli") &&
            !$0.contains("_cli") &&
            !$0.contains(" ") &&
            $0.count >= 2 &&
            $0.count <= 6
        }
        if let bestShort = shortCandidates.sorted(by: { $0.count < $1.count }).first {
            return bestShort
        }
        
        // 2. 检查 executionBody 是否本身为单个二进制程序
        let exec = skill.executionBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if !exec.isEmpty && !exec.contains(" ") && !exec.contains("\n") {
            return (exec as NSString).lastPathComponent
        }
        
        // 3. 兜底选取最短且无 cli 后缀的别名
        let candidates = aliases.filter { !$0.contains("-cli") && !$0.contains("_cli") && $0.count <= 12 }
        return candidates.sorted(by: { $0.count < $1.count }).first
    }
}

// MARK: - 5.2 CLICommandNormalizer: 命令行参数清洗、分词与桥接引擎
/// 负责严格切词、剥除外层字面量引号、执行体对齐与内联 JSON 转存
public enum CLICommandNormalizer {
    
    /// 命令行精准切词器：剥除外层字面量引号，避免给底层进程 argv 传递残留引号导致参数解析失败
    /// - Parameter command: 待切分的完整命令行字符串
    /// - Returns: 纯净的参数数组 (argv)
    public static func splitCommandLineTokens(_ command: String) -> [String] {
        var tokens: [String] = []
        var currentToken = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var isEscaped = false
        var hasQuotedToken = false
        
        for char in command {
            if isEscaped {
                currentToken.append(char)
                isEscaped = false
                continue
            }
            if char == "\\" {
                isEscaped = true
                continue
            }
            if char == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                hasQuotedToken = true
                continue // 仅切换状态，不将单引号自身存入参数内容
            }
            if char == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                hasQuotedToken = true
                continue // 仅切换状态，不将双引号自身存入参数内容
            }
            if char.isWhitespace && !inSingleQuote && !inDoubleQuote {
                if !currentToken.isEmpty || hasQuotedToken {
                    tokens.append(currentToken)
                    currentToken = ""
                    hasQuotedToken = false
                }
            } else {
                currentToken.append(char)
            }
        }
        if !currentToken.isEmpty || hasQuotedToken {
            tokens.append(currentToken)
        }
        return tokens
    }
    
    public static func splitCommandLine(_ command: String) -> [String] {
        splitCommandLineTokens(command)
    }
    
    /// 自动识别并清洗命令行参数：在 .cli 模式下仅在确认首词等于执行体时剥离，在 .shell 模式下自动补齐缺失的主命令
    /// - Parameters:
    ///   - command: 模型传入的原始指令字符串
    ///   - skill: 当前挂载的目标技能实体
    /// - Returns: 经过网关校准对齐后的可执行命令串
    public static func normalizeCLICommand(command: String, skill: AgentSkill) -> String {
        var raw = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }
        
        // 防篡改：通用终端与脚本执行器 (system_terminal / bash_runner) 接收任意原生命令，
        // 绝对禁止剥离运行器（如 npm），也绝对禁止追加推导的主程序前缀（如 unzip）
        let sName = skill.name.lowercased()
        if sName == "system_terminal" || sName == "bash_runner" || sName.contains("terminal") {
            return raw
        }
        
        let workingDir = skill.workingDirectory ?? ConfigManager.shared.skillsPath?.path ?? ""
        let aliases = SkillBinaryResolver.resolveDynamicPhysicalAliases(skill: skill, workingDirectory: workingDir)
        let primaryBinary = SkillBinaryResolver.resolvePrimaryBinaryName(skill: skill, workingDirectory: workingDir, aliases: aliases)
        let boundBinaryName = (skill.executionBody as NSString).lastPathComponent.lowercased()
        
        let runtimeWrappers: Set<String> = [
            "node", "nodejs", "npm", "npx", "pnpm", "pnpx", "yarn", "bun", "bunx",
            "python", "python3", "py", "bash", "sh", "zsh", "env"
        ]
        
        var hasMutated = true
        var iterationCount = 0
        let maxIterations = 4
        
        while hasMutated && iterationCount < maxIterations {
            hasMutated = false
            iterationCount += 1
            
            let tokens = splitCommandLineTokens(raw)
            guard let firstToken = tokens.first else { break }
            
            let normalizedToken = cleanToken(firstToken)
            let tokenBaseName = (normalizedToken as NSString).lastPathComponent.lowercased()
            let tokenWithoutExt = (tokenBaseName as NSString).deletingPathExtension.lowercased()
            
            // 剥离显式运行时解释器 (仅对专用 CLI 技能生效)
            if runtimeWrappers.contains(tokenBaseName) || runtimeWrappers.contains(tokenWithoutExt) {
                if tokens.count > 1 {
                    raw = tokens.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    hasMutated = true
                    continue
                }
            }
            
            // 一致性校验：只有首个 Token 确认等于底层绑定的可执行文件名或其已知主别名时，才允许在 .cli 模式下剥离
            let isTargetSelfInvocation = (tokenBaseName == boundBinaryName)
                || (tokenWithoutExt == boundBinaryName)
                || (primaryBinary != nil && tokenBaseName == primaryBinary!.lowercased())
            
            if isTargetSelfInvocation && skill.type == .cli {
                if tokens.count > 1 {
                    raw = tokens.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    hasMutated = true
                    LogManager.shared.info(
                        "🪄 [通用命令净化] 已校准底层可执行体 [\(boundBinaryName)]，剥离前缀 [\(firstToken)]，子参数: [\(raw)]",
                        parentID: LogManager.shared.activeContextID
                    )
                } else {
                    raw = "--help"
                    hasMutated = false
                }
            }
        }
        
        // 针对专用 Shell 技能补齐缺失的主命令前缀
        if skill.type == .shell {
            let tokens = splitCommandLineTokens(raw)
            if let firstToken = tokens.first {
                let cleanFirst = cleanToken(firstToken).lowercased()
                let commonShellBuiltins: Set<String> = [
                    "which", "echo", "export", "cd", "ls", "pwd", "cat", "grep",
                    "find", "mkdir", "rm", "cp", "mv", "chmod", "curl", "source", "test"
                ]
                
                let isAlreadyCommand = commonShellBuiltins.contains(cleanFirst)
                    || aliases.contains(cleanFirst)
                    || (primaryBinary != nil && cleanFirst == primaryBinary!.lowercased())
                
                if !isAlreadyCommand, let bin = primaryBinary, !bin.isEmpty {
                    raw = "\(bin) \(raw)"
                    LogManager.shared.info(
                        "🪄 [通用命令对齐] 检测到 Shell 媒介缺失主程序前缀，已补齐: [\(raw)]",
                        parentID: LogManager.shared.activeContextID
                    )
                }
            }
        }
        
        return raw
    }
    
    /// 自动将命令行中的内联 JSON 转存为工作区临时文件
    /// - Parameters:
    ///   - command: 包含内联 JSON 的命令行
    ///   - workingDirectory: 目标工作目录
    /// - Returns: 参数已桥接为临时文件路径的命令行
    public static func autoBridgeInlineJSONToTempFile(command: String, workingDirectory: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let firstObj = trimmed.firstIndex(of: "{")
        let lastObj = trimmed.lastIndex(of: "}")
        let firstArr = trimmed.firstIndex(of: "[")
        let lastArr = trimmed.lastIndex(of: "]")
        
        var start: String.Index? = nil
        var end: String.Index? = nil
        
        if let fO = firstObj, let lO = lastObj, fO < lO {
            start = fO; end = lO
        }
        if let fA = firstArr, let lA = lastArr, fA < lA {
            if start == nil || fA < start! { start = fA }
            if end == nil || lA > end! { end = lA }
        }
        
        guard let jsonStart = start, let jsonEnd = end, jsonStart < jsonEnd else {
            return command
        }
        
        let jsonCandidate = String(trimmed[jsonStart...jsonEnd])
        
        if let data = jsonCandidate.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            
            let tempFileName = "auto_payload_\(UUID().uuidString.prefix(8)).json"
            let tempFileURL = URL(fileURLWithPath: workingDirectory).appendingPathComponent(tempFileName)
            
            do {
                try jsonCandidate.write(to: tempFileURL, atomically: true, encoding: .utf8)
                let prefix = String(trimmed[..<jsonStart]).trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                let suffix = String(trimmed[trimmed.index(after: jsonEnd)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                
                let targetArgPath = tempFileURL.path
                let spacer = prefix.hasSuffix("@") ? "" : " "
                let bridgedCommand = "\(prefix)\(spacer)\(targetArgPath) \(suffix)".trimmingCharacters(in: .whitespaces)
                
                LogManager.shared.info(
                    "🪄 [通用参数桥接] 已将内联 JSON 自动转存为临时文件 [\(targetArgPath)]",
                    parentID: LogManager.shared.activeContextID
                )
                return bridgedCommand
            } catch {
                return command
            }
        }
        
        return command
    }
    
    public static func cleanToken(_ token: String) -> String {
        return token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            .replacingOccurrences(of: "^\\./", with: "", options: .regularExpression)
    }
}

// MARK: - 5.3 SkillManualOrchestrator: 技能手册自省、渐进式路由与章节切片中枢
/// 负责 Markdown 文档物理扫描、通用文档摘要自省、全局基座提取及标题锚点切片
public enum SkillManualOrchestrator {
    
    /// 净化并重构技能手册：针对多文件复合技能自动提供「全局基座 + 主手册与子文档目录」，单文件技能直接透传
    /// - Parameters:
    ///   - rawContent: 主文档原始文本 (SKILL.md)
    ///   - skillName: 目标技能唯一标识
    ///   - folderURL: 技能在本地的物理存储目录
    /// - Returns: 经过结构化处理、利于模型二跳路由的手册内容
    public static func purifyAndStructureManual(rawContent: String, skillName: String, folderURL: URL) -> String {
        let fileManager = FileManager.default
        var detectedSubDocs: [(path: String, summary: String)] = []
        
        // 1. 物理扫描子文档：递归检索所有 markdown 及文本规范
        if let enumerator = fileManager.enumerator(at: folderURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                let fileName = fileURL.lastPathComponent.lowercased()
                
                // 排除主入口文档与非文本资产
                if (ext == "md" || ext == "txt") && !fileName.contains("skill.md") && !fileName.contains("readme.md") {
                    let relative = fileURL.path.replacingOccurrences(of: folderURL.path + "/", with: "")
                    let docSummary = extractGenericDocSummary(fileURL: fileURL, fallbackName: fileURL.deletingPathExtension().lastPathComponent)
                    detectedSubDocs.append((path: relative, summary: docSummary))
                }
            }
        }
        
        // 2. 单文档简单技能分支：若无任何独立子文档，原样交付完整手册，保障轻量 Agent 顺畅执行
        guard !detectedSubDocs.isEmpty else {
            return rawContent
        }
        
        // 3. 复合长任务技能分支：截取主文档全局基座（环境配置、CLI 二进制、主命令等），截断后续细节
        let baseOverview = extractBaseOverview(from: rawContent)
        
        // 4. 通用结构树与语义导读装配 (将 SKILL.md 显式作为全局规范资产透出)
        var assembledDoc = """
        【🛠️ 工具全局基座信息】
        \(baseOverview)

        【📖 可查阅文档与业务模块目录】
        本技能已解耦为多模块文档，操作时可按需精读：
        - 📄 `SKILL.md`：全局通用规范（包含环境配置、鉴权登录流程、操作确认要求与通用参数）
        """
        
        for item in detectedSubDocs.sorted(by: { $0.path < $1.path }) {
            assembledDoc += "\n- 📄 `\(item.path)`：\(item.summary)"
        }
        
        // 5. 正向推演指引 (遵循正向逻辑规约，避免负面词汇)
        assembledDoc += """
        

        【下一步行动指引】
        请根据当前步骤的具体意图，直接调用 read_skill_manual(target_skill_name: "\(skillName)", doc_path: "<目标文档路径>") 精读对应的指令规范与参数契约。若需核验登录鉴权或全局要求，可直接指定 doc_path: "SKILL.md"（支持锚点切片，如 "SKILL.md#安装与鉴权"）。
        """
        
        return assembledDoc
    }
    
    /// 截取 SKILL.md 前段关于环境要求、配置命令、主二进制说明的全局基座内容
    public static func extractBaseOverview(from markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        var overviewLines: [String] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 遇到业务域枚举、路由章节或细分指令大标题时安全截断
            if trimmed.hasPrefix("## 何时触发") ||
               trimmed.hasPrefix("## 业务域") ||
               trimmed.hasPrefix("## 子文档") ||
               trimmed.hasPrefix("## 详细指令") ||
               trimmed.hasPrefix("## 业务命令") ||
               trimmed.hasPrefix("## 命令列表") {
                break
            }
            overviewLines.append(line)
            
            // 安全阈值：全局基座最多保留前 60 行
            if overviewLines.count >= 60 {
                break
            }
        }
        
        let result = overviewLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "本工具需配合宿主命令行执行，操作前请确保执行环境与网络基地址可用。" : result
    }
    
    /// 基于文件物理特征自适应提取子文档摘要 (Frontmatter -> H1/引用块 -> 首段正文 -> 文件名)
    public static func extractGenericDocSummary(fileURL: URL, fallbackName: String) -> String {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return fallbackName
        }
        
        let lines = content.components(separatedBy: .newlines)
        var isInsideFrontmatter = false
        var frontmatterDesc: String? = nil
        
        // Level 1: 优先解析标准 YAML Frontmatter
        for line in lines.prefix(20) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                if isInsideFrontmatter { break }
                isInsideFrontmatter = true
                continue
            }
            if isInsideFrontmatter {
                let parts = trimmed.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 {
                    let key = parts[0].lowercased()
                    let val = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if key == "description" || key == "desc" || key == "summary" {
                        frontmatterDesc = val
                        break
                    }
                }
            }
        }
        if let desc = frontmatterDesc, !desc.isEmpty {
            return desc
        }
        
        // Level 2: 提取正文首个 H1 标题或 blockquote 引用
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let cleanTitle = trimmed.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
                if !cleanTitle.isEmpty { return cleanTitle }
            }
            if trimmed.hasPrefix(">") {
                let cleanQuote = trimmed.replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces)
                if !cleanQuote.isEmpty { return cleanQuote }
            }
        }
        
        // Level 3: 提取第一个非空普通文本行
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !trimmed.hasPrefix("---") && !trimmed.hasPrefix("```") {
                return trimmed.count > 60 ? String(trimmed.prefix(60)) + "..." : trimmed
            }
        }
        
        // Level 4: 最终兜底使用纯文件名
        return fallbackName
    }
    
    /// 从 Markdown 文本中精准截取指定标题锚点下的正文切片，未指定或未找到时返回全文
    /// - Parameters:
    ///   - content: 完整的 Markdown 正文
    ///   - anchor: 章节标题关键词 (如 "安装与鉴权" 或 "鉴权")
    /// - Returns: 截取出的对应章节正文
    public static func extractAnchorSection(content: String, anchor: String) -> String {
        let cleanAnchor = anchor.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
        guard !cleanAnchor.isEmpty else { return content }
        
        let lines = content.components(separatedBy: .newlines)
        var matchedStartIndex: Int? = nil
        var matchedHeaderLevel: Int = 2
        
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let headerLevel = trimmed.prefix(while: { $0 == "#" }).count
                let headerText = trimmed.dropFirst(headerLevel).trimmingCharacters(in: .whitespaces).lowercased()
                
                if matchedStartIndex == nil {
                    if headerText.contains(cleanAnchor) {
                        matchedStartIndex = index
                        matchedHeaderLevel = headerLevel
                    }
                } else {
                    // 遇到同级或更高级别的标题时，视为当前章节结束
                    if headerLevel <= matchedHeaderLevel {
                        let sectionLines = lines[matchedStartIndex!..<index]
                        return sectionLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
        }
        
        if let start = matchedStartIndex {
            let sectionLines = lines[start..<lines.count]
            return sectionLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return content
    }
}

// MARK: - 5.4 SkillCommandBridge: 全局兼容门面代理 (Facade)
/// 100% 透明向下兼容既有代码调用，内部全部重定向至上述三个专用解耦引擎
public enum SkillCommandBridge {
    
    @inline(__always)
    public static func normalizeCLICommand(command: String, skill: AgentSkill) -> String {
        CLICommandNormalizer.normalizeCLICommand(command: command, skill: skill)
    }
    
    @inline(__always)
    public static func autoBridgeInlineJSONToTempFile(command: String, workingDirectory: String) -> String {
        CLICommandNormalizer.autoBridgeInlineJSONToTempFile(command: command, workingDirectory: workingDirectory)
    }
    
    @inline(__always)
    public static func resolveDynamicPhysicalAliases(skill: AgentSkill, workingDirectory: String) -> Set<String> {
        SkillBinaryResolver.resolveDynamicPhysicalAliases(skill: skill, workingDirectory: workingDirectory)
    }
    
    @inline(__always)
    public static func resolvePrimaryBinaryName(skill: AgentSkill, workingDirectory: String, aliases: Set<String>) -> String? {
        SkillBinaryResolver.resolvePrimaryBinaryName(skill: skill, workingDirectory: workingDirectory, aliases: aliases)
    }
    
    @inline(__always)
    public static func purifyAndStructureManual(rawContent: String, skillName: String, folderURL: URL) -> String {
        SkillManualOrchestrator.purifyAndStructureManual(rawContent: rawContent, skillName: skillName, folderURL: folderURL)
    }
    
    @inline(__always)
    public static func splitCommandLine(_ command: String) -> [String] {
        CLICommandNormalizer.splitCommandLine(command)
    }
    
    @inline(__always)
    public static func splitCommandLineTokens(_ command: String) -> [String] {
        CLICommandNormalizer.splitCommandLineTokens(command)
    }
}

// MARK: - ==================== 6. SkillExecutors (多态异构执行引擎集群) ====================

public enum SkillExecutors {
    
    // MARK: 6.1 CLI 原生命令行执行引擎
    public struct CLI {
        public static func execute(
            executableTarget: String,
            args: [String: Any],
            sharedContext: [String: String],
            workingDirectory: String?,
            skillParameters: [SkillParameter]
        ) async -> String {
            return await Task.detached(priority: .userInitiated) {
                let process = Process()
                let outPipe = Pipe()
                let errPipe = Pipe()
                
                let baseWD = workingDirectory ?? NSTemporaryDirectory()
                let workDirURL = URL(fileURLWithPath: baseWD)
                process.currentDirectoryURL = workDirURL
                
                guard let executableURL = await resolveExecutableURL(target: executableTarget, workingDir: workDirURL) else {
                    return "❌ CLI 执行失败：找不到可执行命令或二进制文件 [\(executableTarget)]。请确认已在宿主环境中安装并在终端 PATH 内配置。"
                }
                process.executableURL = executableURL
                
                let finalArguments = buildCLIArguments(args: args, skillParameters: skillParameters)
                process.arguments = finalArguments
                
                let processEnv = await EnvironmentResolver.shared.buildProcessEnvironment(
                    sharedContext: sharedContext,
                    args: args
                )
                process.environment = processEnv
                process.standardOutput = outPipe
                process.standardError = errPipe
                
                let lock = NSLock()
                var accumulatedStdout = Data()
                var accumulatedStderr = Data()
                
                let outHandle = outPipe.fileHandleForReading
                let errHandle = errPipe.fileHandleForReading
                
                outHandle.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if !chunk.isEmpty {
                        lock.lock()
                        accumulatedStdout.append(chunk)
                        lock.unlock()
                    }
                }
                
                errHandle.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if !chunk.isEmpty {
                        lock.lock()
                        accumulatedStderr.append(chunk)
                        lock.unlock()
                    }
                }
                
                return await withTaskCancellationHandler {
                    do {
                        try process.run()
                        
                        let timeoutTask = Task {
                            try? await Task.sleep(nanoseconds: 60_000_000_000)
                            if process.isRunning { process.terminate() }
                        }
                        
                        process.waitUntilExit()
                        timeoutTask.cancel()
                        
                        outHandle.readabilityHandler = nil
                        errHandle.readabilityHandler = nil
                        
                        let remainingOut = (try? outHandle.readToEnd()) ?? Data()
                        let remainingErr = (try? errHandle.readToEnd()) ?? Data()
                        
                        lock.lock()
                        accumulatedStdout.append(remainingOut)
                        accumulatedStderr.append(remainingErr)
                        let finalOutData = accumulatedStdout
                        let finalErrData = accumulatedStderr
                        lock.unlock()
                        
                        let stdoutStr = String(data: finalOutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let stderrStr = String(data: finalErrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        
                        if process.terminationReason == .uncaughtSignal {
                            return "❌ CLI 执行超时被强行终止 (Code: \(process.terminationStatus))"
                        }
                        
                        if process.terminationStatus != 0 {
                            let errMsg = stderrStr.isEmpty ? stdoutStr : stderrStr
                            return "⚠️ CLI 命令异常退出 (Code \(process.terminationStatus)):\n\(errMsg)"
                        }
                        
                        if stdoutStr.isEmpty && !stderrStr.isEmpty {
                            return stderrStr
                        }
                        return stdoutStr.isEmpty ? "执行成功 (无输出)" : stdoutStr
                    } catch {
                        outHandle.readabilityHandler = nil
                        errHandle.readabilityHandler = nil
                        return "❌ CLI 进程启动异常: \(error.localizedDescription)"
                    }
                } onCancel: {
                    if process.isRunning { process.terminate() }
                    outHandle.readabilityHandler = nil
                    errHandle.readabilityHandler = nil
                }
            }.value
        }
        
        private static func resolveExecutableURL(target: String, workingDir: URL) async -> URL? {
            let fileManager = FileManager.default
            let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            
            // 1. 显式绝对路径或相对路径
            if trimmed.hasPrefix("/") {
                let url = URL(fileURLWithPath: trimmed)
                if fileManager.fileExists(atPath: url.path) { return url }
            } else if trimmed.hasPrefix("./") {
                let relativeURL = workingDir.appendingPathComponent(String(trimmed.dropFirst(2)))
                if fileManager.fileExists(atPath: relativeURL.path) { return relativeURL }
            }
            
            // 2. 当前技能工作目录直接命中
            let localURL = workingDir.appendingPathComponent(trimmed)
            if fileManager.fileExists(atPath: localURL.path) { return localURL }
            
            // 3. 遍历全量纯净 PATH 环境变量寻址
            let fullPathStr = await EnvironmentResolver.shared.getResolvedPATH()
            let searchPaths = fullPathStr.split(separator: ":").map(String.init)
            
            for dir in searchPaths {
                let candidatePath = (dir as NSString).appendingPathComponent(trimmed)
                if fileManager.isExecutableFile(atPath: candidatePath) || fileManager.fileExists(atPath: candidatePath) {
                    return URL(fileURLWithPath: candidatePath)
                }
            }
            return nil
        }
        
        private static func buildCLIArguments(args: [String: Any], skillParameters: [SkillParameter]) -> [String] {
            var arguments: [String] = []
            
            // 优先检查高阶透传参数
            if let rawArgsList = args["raw_args"] as? [String] {
                return rawArgsList
            } else if let rawArgsStr = (args["raw_args"] as? String) ?? (args["raw_command"] as? String),
                      !rawArgsStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return SkillCommandBridge.splitCommandLine(rawArgsStr)
            } else if let actionStr = args["action"] as? String, !actionStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return SkillCommandBridge.splitCommandLine(actionStr)
            } else if let inputStr = args["input"] as? String, !inputStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return SkillCommandBridge.splitCommandLine(inputStr)
            } else if let cmdStr = args["command"] as? String, !cmdStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return SkillCommandBridge.splitCommandLine(cmdStr)
            }
            
            // 通用纯位置参数白名单：绝不能被追加 '--' 前缀
            let positionalKeys: Set<String> = [
                "command", "input", "raw_command", "raw_args", "subcommand", "action", "query"
            ]
            
            for param in skillParameters {
                guard let val = args[param.name] else { continue }
                let flagKey = param.name.replacingOccurrences(of: "_", with: "-")
                
                switch param.type {
                case .boolean:
                    if let boolVal = val as? Bool, boolVal {
                        arguments.append("--\(flagKey)")
                    } else if let strVal = val as? String, (strVal.lowercased() == "true" || strVal == "1") {
                        arguments.append("--\(flagKey)")
                    }
                case .array:
                    if let arr = val as? [Any] {
                        for item in arr {
                            arguments.append("--\(flagKey)")
                            arguments.append(String(describing: item))
                        }
                    }
                default:
                    let strVal = String(describing: val).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !strVal.isEmpty {
                        if positionalKeys.contains(param.name.lowercased()) {
                            arguments.append(contentsOf: SkillCommandBridge.splitCommandLine(strVal))
                        } else {
                            arguments.append("--\(flagKey)")
                            arguments.append(strVal)
                        }
                    }
                }
            }
            return arguments
        }
    }
    
    // MARK: 6.2 Python 执行引擎
    public struct Python {
        public static func execute(
            scriptSource: String,
            args: [String: Any],
            sharedContext: [String: String],
            workingDirectory: String?,
            entryPoint: String?
        ) async -> String {
            return await Task.detached(priority: .userInitiated) {
                let baseWD = workingDirectory ?? NSTemporaryDirectory()
                let workDirURL = URL(fileURLWithPath: baseWD)
                
                if let ep = entryPoint, !ep.isEmpty {
                    let originFile = workDirURL.appendingPathComponent(ep)
                    try? scriptSource.write(to: originFile, atomically: true, encoding: .utf8)
                }
                
                let runnerFile = workDirURL.appendingPathComponent(".\(UUID().uuidString)_runner.py")
                let payloadFile = workDirURL.appendingPathComponent(".payload_\(UUID().uuidString).json")
                
                let wrapperScript = """
                import sys, json, os
                try:
                    __payload_path = sys.argv[1]
                    with open(__payload_path, 'r', encoding='utf-8') as __f:
                        __payload = json.load(__f)
                    args = __payload.get('args', {})
                    context = __payload.get('context', {})
                except Exception as e:
                    print(f"❌ 底层参数解析失败: {e}")
                    sys.exit(1)
                
                # --- 以下为真实业务代码 ---
                \(scriptSource)
                """
                
                let process = Process()
                let pipe = Pipe()
                let venvPython = workDirURL.appendingPathComponent("venv/bin/python3")
                if FileManager.default.fileExists(atPath: venvPython.path) {
                    process.executableURL = venvPython
                } else {
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                }
                
                return await withTaskCancellationHandler {
                    do {
                        try wrapperScript.write(to: runnerFile, atomically: true, encoding: .utf8)
                        
                        let payloadDict: [String: Any] = ["args": args, "context": sharedContext]
                        let payloadData = try JSONSerialization.data(withJSONObject: payloadDict, options: [])
                        try payloadData.write(to: payloadFile)
                        
                        process.currentDirectoryURL = workDirURL
                        
                        var secureEnv = await EnvironmentResolver.shared.buildProcessEnvironment(
                            sharedContext: sharedContext,
                            args: args
                        )
                        secureEnv["AGENT_PAYLOAD_PATH"] = payloadFile.path
                        secureEnv["PYTHONPATH"] = workDirURL.path
                        
                        process.environment = secureEnv
                        process.arguments = [runnerFile.path, payloadFile.path]
                        process.standardOutput = pipe
                        process.standardError = pipe
                        
                        try process.run()
                        
                        let timeoutTask = Task {
                            try? await Task.sleep(nanoseconds: 45_000_000_000)
                            if process.isRunning { process.terminate() }
                        }
                        
                        let outputData = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                        process.waitUntilExit()
                        timeoutTask.cancel()
                        
                        try? FileManager.default.removeItem(at: runnerFile)
                        try? FileManager.default.removeItem(at: payloadFile)
                        
                        let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        // 使用 Swift 原生正则清除控制台颜色字符，彻底避免 Shell 管道碎片泄漏
                        let cleanOutput = output.replacingOccurrences(of: #"\x1B\[[0-9;]*[a-zA-Z]"#, with: "", options: .regularExpression)
                        
                        if process.terminationReason == .uncaughtSignal {
                            return "❌ 脚本执行超时或被强制终止 (代码 \(process.terminationStatus)):\n\(cleanOutput)"
                        }
                        if process.terminationStatus != 0 {
                            return "⚠️ Shell 脚本异常退出 (代码 \(process.terminationStatus)):\n\(cleanOutput)"
                        }
                        return cleanOutput.isEmpty ? "执行成功 (无返回值)" : cleanOutput
                    } catch {
                        try? FileManager.default.removeItem(at: runnerFile)
                        try? FileManager.default.removeItem(at: payloadFile)
                        return "❌ 执行引擎异常: \(error.localizedDescription)"
                    }
                } onCancel: {
                    if process.isRunning { process.terminate() }
                }
            }.value
        }
    }
    
    // MARK: 6.3 Shell 执行引擎
    public struct Shell {
        public static func execute(
            scriptSource: String,
            args: [String: Any],
            sharedContext: [String: String],
            workingDirectory: String?,
            entryPoint: String?
        ) async -> String {
            return await Task.detached(priority: .userInitiated) {
                if let wd = workingDirectory, !wd.isEmpty, let ep = entryPoint, !ep.isEmpty {
                    let execFile = URL(fileURLWithPath: wd).appendingPathComponent(ep)
                    try? scriptSource.write(to: execFile, atomically: true, encoding: .utf8)
                }
                
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                
                let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    ?? FileManager.default.temporaryDirectory
                let skillsURL = await ConfigManager.shared.skillsPath
                    ?? FileManager.default.temporaryDirectory

                try? FileManager.default.createDirectory(at: downloadsURL, withIntermediateDirectories: true)
                try? FileManager.default.createDirectory(at: skillsURL, withIntermediateDirectories: true)

                if let wd = workingDirectory, !wd.isEmpty {
                    process.currentDirectoryURL = URL(fileURLWithPath: wd)
                } else {
                    process.currentDirectoryURL = skillsURL
                }
                
                var secureEnv = await EnvironmentResolver.shared.buildProcessEnvironment(
                    sharedContext: sharedContext,
                    args: args
                )
                secureEnv["SAFE_DOWNLOADS_DIR"] = downloadsURL.path
                secureEnv["SAFE_SKILLS_DIR"] = skillsURL.path
                
                var cleanScript = scriptSource.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleanScript.hasPrefix("`") && cleanScript.hasSuffix("`") {
                    cleanScript = String(cleanScript.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if cleanScript.hasPrefix(">") {
                    cleanScript = String(cleanScript.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                }

                process.arguments = ["-c", cleanScript]
                process.environment = secureEnv
                process.standardOutput = pipe
                process.standardError = pipe
                
                return await withTaskCancellationHandler {
                    do {
                        try process.run()
                        let timeoutTask = Task {
                            try? await Task.sleep(nanoseconds: 45_000_000_000)
                            if process.isRunning { process.terminate() }
                        }
                        let outputData = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                        process.waitUntilExit()
                        timeoutTask.cancel()
                        
                        let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        
                        if process.terminationReason == .uncaughtSignal {
                            return "❌ 脚本执行超时或被强制终止 (代码 \(process.terminationStatus)):\n\(output)"
                        }
                        if process.terminationStatus != 0 {
                            return "⚠️ Shell 脚本异常退出 (代码 \(process.terminationStatus)):\n\(output)"
                        }
                        return output.isEmpty ? "执行成功 (无返回值)" : output
                    } catch {
                        return "❌ 脚本执行异常: \(error.localizedDescription)"
                    }
                } onCancel: {
                    if process.isRunning { process.terminate() }
                }
            }.value
        }
    }
    
    // MARK: 6.4 AppleScript 执行引擎
    public struct AppleScript {
        public static func execute(
            scriptSource: String,
            args: [String: Any],
            sharedContext: [String: String],
            workingDirectory: String?,
            entryPoint: String?
        ) async -> String {
            return await Task.detached(priority: .userInitiated) {
                if let wd = workingDirectory, !wd.isEmpty, let ep = entryPoint, !ep.isEmpty {
                    let execFile = URL(fileURLWithPath: wd).appendingPathComponent(ep)
                    try? scriptSource.write(to: execFile, atomically: true, encoding: .utf8)
                }
                
                let process = Process()
                let outPipe = Pipe()
                let inPipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                if let wd = workingDirectory, !wd.isEmpty { process.currentDirectoryURL = URL(fileURLWithPath: wd) }
                
                let secureEnv = await EnvironmentResolver.shared.buildProcessEnvironment(
                    sharedContext: sharedContext,
                    args: args
                )
                process.environment = secureEnv
                process.standardInput = inPipe
                process.standardOutput = outPipe
                process.standardError = outPipe
                
                return await withTaskCancellationHandler {
                    do {
                        try process.run()
                        if let scriptData = scriptSource.data(using: .utf8) {
                            try inPipe.fileHandleForWriting.write(contentsOf: scriptData)
                            inPipe.fileHandleForWriting.closeFile()
                        }
                        
                        let timeoutTask = Task {
                            try? await Task.sleep(nanoseconds: 45_000_000_000)
                            if process.isRunning { process.terminate() }
                        }
                        
                        let outputData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                        process.waitUntilExit()
                        timeoutTask.cancel()
                        
                        let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        
                        if process.terminationReason == .uncaughtSignal {
                            return "❌ AppleScript 执行超时被强制终止 (退出码 \(process.terminationStatus)):\n\(output)"
                        }
                        if process.terminationStatus != 0 {
                            return "❌ AppleScript 执行失败 (退出码 \(process.terminationStatus)):\n\(output)"
                        }
                        return output.isEmpty ? "执行成功 (无返回值)" : output
                    } catch {
                        return "❌ AppleScript 引擎异常: \(error.localizedDescription)"
                    }
                } onCancel: {
                    if process.isRunning { process.terminate() }
                }
            }.value
        }
    }
    
    // MARK: 6.5 RESTful API 执行引擎
    public struct API {
        public static func execute(
            apiSource: String,
            args: [String: Any],
            sharedContext: [String: String]
        ) async -> String {
            return await Task.detached(priority: .userInitiated) {
                var requestURLString = apiSource
                var httpMethod = "GET"
                var staticHeaders: [String: Any] = [:]
                
                if apiSource.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"),
                   let data = apiSource.data(using: .utf8),
                   let configDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    requestURLString = configDict["url"] as? String ?? ""
                    httpMethod = configDict["method"] as? String ?? "GET"
                    if let headers = configDict["headers"] as? [String: Any] {
                        staticHeaders = headers
                    }
                }
                
                requestURLString = (args["url"] as? String) ?? requestURLString
                httpMethod = (args["method"] as? String)?.uppercased() ?? httpMethod
                
                for (k, v) in args {
                    if k == "url" || k == "method" || k == "headers" || k == "body" || k == "raw_command" { continue }
                    let safeValue = "\(v)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "\(v)"
                    requestURLString = requestURLString.replacingOccurrences(of: "{\(k)}", with: safeValue)
                }
                
                guard let url = URL(string: requestURLString) else {
                    return "❌ API URL 解析或构建失败: \(requestURLString)"
                }
                
                var request = URLRequest(url: url)
                request.httpMethod = httpMethod
                request.addValue("application/json", forHTTPHeaderField: "Content-Type")
                
                for (key, val) in staticHeaders { request.addValue("\(val)", forHTTPHeaderField: key) }
                if let headersArg = args["headers"] {
                    var dynamicHeaders: [String: Any] = [:]
                    if let dict = headersArg as? [String: Any] {
                        dynamicHeaders = dict
                    } else if let str = headersArg as? String, let data = str.data(using: .utf8), let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        dynamicHeaders = dict
                    }
                    for (key, val) in dynamicHeaders { request.addValue("\(val)", forHTTPHeaderField: key) }
                }
                
                if ["POST", "PUT", "PATCH"].contains(httpMethod) {
                    if let bodyArg = args["body"] {
                        if let str = bodyArg as? String {
                            request.httpBody = str.data(using: .utf8)
                        } else if let dict = bodyArg as? [String: Any] {
                            request.httpBody = try? JSONSerialization.data(withJSONObject: dict)
                        }
                    } else if !args.isEmpty {
                        var fallbackBody = args
                        ["url", "method", "headers", "raw_command"].forEach { fallbackBody.removeValue(forKey: $0) }
                        if !fallbackBody.isEmpty { request.httpBody = try? JSONSerialization.data(withJSONObject: fallbackBody) }
                    }
                }
                
                do {
                    let config = URLSessionConfiguration.default
                    config.timeoutIntervalForRequest = 60
                    config.timeoutIntervalForResource = 300
                    
                    let session = URLSession(configuration: config, delegate: LLMService.shared, delegateQueue: nil)
                    let (data, response) = try await session.data(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        return "❌ 收到非法的 HTTP 响应"
                    }
                    
                    var responseString = String(data: data, encoding: .utf8) ?? "无法解析的二进制响应数据"
                    let maxCharacterLimit = 15000
                    if responseString.count > maxCharacterLimit {
                        responseString = String(responseString.prefix(maxCharacterLimit))
                        responseString += "\n\n...(⚠️ 系统警告：因目标网页内容过长，为防止内存溢出，已在 \(maxCharacterLimit) 字符处自动截断。目前的信息已足够你分析核心内容。)"
                    }
                    
                    if (200...299).contains(httpResponse.statusCode) {
                        return responseString
                    } else {
                        return "⚠️ API 请求失败 (状态码: \(httpResponse.statusCode))\n[响应详情]: \(responseString)"
                    }
                } catch {
                    let nsError = error as NSError
                    if nsError.code == NSURLErrorTimedOut {
                        return "❌ API 请求超时 (超过系统设定的等待时间)，请检查网络或目标服务器状态。"
                    }
                    return "❌ API 请求异常: \(error.localizedDescription)"
                }
            }.value
        }
    }
    
    // MARK: 6.6 MCP 动态代理执行引擎
    public struct MCP {
        public static func execute(
            serverId: String,
            method: String,
            args: [String: Any],
            serverConfig: MCPServer?
        ) async -> String {
            guard let config = serverConfig else {
                return "❌ MCP 节点阻断：找不到指定的物理节点"
            }
            guard config.isEnabled else {
                return "❌ MCP 节点阻断：所属的底层 MCP 物理节点 [\(config.name)] 目前已被用户手动关闭。请立刻停止尝试调用该节点下的任何工具！"
            }
            guard !method.isEmpty else {
                return "❌ MCP 节点阻断：未指定调用的 Method 入口"
            }
            
            let transport = config.transport
            let cmd = config.command?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !cmd.isEmpty else {
                return "❌ MCP 节点阻断：未配置节点的调度主命令 (如绝对路径或 python3)"
            }
            
            let cmdArgs = config.args ?? ""
            
            return await Task.detached(priority: .userInitiated) {
                do {
                    if transport == .stdio {
                        try await MCPConnectionEngine.shared.connectStdioServer(serverId: serverId, command: cmd, args: cmdArgs)
                    } else {
                        return "❌ 仅支持 stdio 隔离模式"
                    }
                    
                    return try await withThrowingTaskGroup(of: String.self) { group in
                        group.addTask {
                            return try await MCPConnectionEngine.shared.callTool(serverId: serverId, method: method, parameters: args)
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: 45_000_000_000)
                            throw NSError(domain: "MCPEngine", code: 408, userInfo: [NSLocalizedDescriptionKey: "执行超时 (超过45秒)，底层进程无响应。"])
                        }
                        let result = try await group.next()!
                        group.cancelAll()
                        return result
                    }
                } catch {
                    let nsError = error as NSError
                    return "❌ MCP 底层通信异常 (Code: \(nsError.code)):\n\(nsError.localizedDescription)"
                }
            }.value
        }
    }
    
    // MARK: 6.7 Builtin 系统级内省与进化执行引擎
    public struct Builtin {
        @MainActor
        public static func executeEvolve(args: [String: Any], manager: SkillManager) async -> String {
            guard let skillName = args["skillName"] as? String,
                  let skillsPath = ConfigManager.shared.skillsPath else {
                return "❌ 操作失败：缺少核心参数 skillName 或本地技能路径未初始化"
            }
            
            let typeStr = args["type"] as? String
            let code = args["code"] as? String
            let description = args["description"] as? String
            let manualContent = args["manual"] as? String
            
            let folderURL = skillsPath.appendingPathComponent(skillName)
            let fileManager = FileManager.default
            let isExists = fileManager.fileExists(atPath: folderURL.path)
            
            if !isExists {
                guard typeStr != nil, code != nil, description != nil else {
                    return "❌ 创建新技能失败：作为全新技能，你必须完整提供 type, code 和 description 参数。"
                }
            }
            
            do {
                if !isExists { try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true, attributes: nil) }
                
                let manifestURL = folderURL.appendingPathComponent("manifest.json")
                var manifestDict: [String: Any] = ["name": skillName, "displayName": skillName, "requiresConfirmation": false, "parameters": []]
                
                if isExists, let oldData = try? Data(contentsOf: manifestURL),
                   let oldManifest = try? JSONSerialization.jsonObject(with: oldData) as? [String: Any] {
                    manifestDict = oldManifest
                }
                
                let finalType = typeStr?.lowercased() ?? (manifestDict["type"] as? String ?? "shell")
                let isPython = finalType.contains("python")
                let scriptName = isPython ? "script.py" : "script.sh"
                
                manifestDict["type"] = finalType
                if let newDesc = description, !newDesc.isEmpty { manifestDict["description"] = newDesc }
                manifestDict["entryPoint"] = scriptName
                manifestDict["category"] = "进化"
                
                if let newCode = code, !newCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let scriptURL = folderURL.appendingPathComponent(scriptName)
                    if isExists && fileManager.fileExists(atPath: scriptURL.path) {
                        let backupURL = folderURL.appendingPathComponent(".\(scriptName).bak")
                        try? fileManager.removeItem(at: backupURL)
                        try? fileManager.copyItem(at: scriptURL, to: backupURL)
                    }
                    try newCode.write(to: scriptURL, atomically: true, encoding: .utf8)
                    
                    if !isPython {
                        let task = Process(); task.executableURL = URL(fileURLWithPath: "/bin/chmod"); task.arguments = ["+x", scriptURL.path]
                        try? task.run(); task.waitUntilExit()
                    }
                }
                
                let manualURL = folderURL.appendingPathComponent("SKILL.md")
                
                if let rawManual = manualContent, !rawManual.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    var finalManual = rawManual.trimmingCharacters(in: .whitespacesAndNewlines)
                    let currentDesc = manifestDict["description"] as? String ?? "未提供描述"
                    
                    let standardHeader = """
                    ---
                    name: \(skillName)
                    description: \(currentDesc)
                    category: 进化
                    ---
                    """
                    
                    if !finalManual.hasPrefix("# \(skillName)") && !finalManual.hasPrefix("---") {
                        finalManual = "\(standardHeader)\n\n# \(skillName)\n\n> \(currentDesc)\n\n\(finalManual)"
                    }
                    
                    if isExists && fileManager.fileExists(atPath: manualURL.path) {
                        let backupURL = folderURL.appendingPathComponent(".SKILL.md.bak")
                        try? fileManager.removeItem(at: backupURL)
                        try? fileManager.copyItem(at: manualURL, to: backupURL)
                    }
                    
                    try finalManual.write(to: manualURL, atomically: true, encoding: .utf8)
                } else if !isExists {
                    let fallbackDesc = description ?? "未提供描述"
                    let defaultManual = "---\nname: \(skillName)\ndescription: \(fallbackDesc)\ncategory: 进化\n---\n\n## 核心逻辑\n本技能未提供详细的参数说明，请直接查阅 `\(scriptName)` 源码。"
                    try defaultManual.write(to: manualURL, atomically: true, encoding: .utf8)
                }
                
                let manifestData = try JSONSerialization.data(withJSONObject: manifestDict, options: .prettyPrinted)
                try manifestData.write(to: manifestURL)
                
                manager.loadSkills()
                if !isExists {
                    if let newSkill = manager.skills.first(where: { $0.name == skillName }) {
                        let activeAgentID = AiChatStore.shared.selectedAgentID
                        if let idx = ConfigManager.shared.app.agentProfiles.firstIndex(where: { $0.id == activeAgentID }) {
                            if !ConfigManager.shared.app.agentProfiles[idx].equippedSkillIDs.contains(newSkill.id) {
                                ConfigManager.shared.app.agentProfiles[idx].equippedSkillIDs.append(newSkill.id)
                                ConfigManager.shared.saveConfig()
                            }
                        }
                    }
                    Util.message("🧬 AI 已自我进化并挂载新技能: \(skillName)")
                } else {
                    Util.message("🔄 AI 已成功对技能 [\(skillName)] 进行局部热更新")
                }
                
                if isExists {
                    return "✅ 技能 [\(skillName)] 已成功进行局部更新并热重载。您可以立即运行测试看是否达到预期。如果需要查看原有代码，可以在其本地目录找到隐藏的 .bak 文件。"
                } else {
                    return "✅ 技能 [\(skillName)] 已成功编写、保存并动态挂载至当前智能体分身。请立即调用测试该技能。"
                }
                
            } catch {
                return "❌ 技能进化/更新失败，文件系统发生错误: \(error.localizedDescription)"
            }
        }
        
        // MARK: - readManual: 区分隐式初探与显式精读，解除 SKILL.md 读取死锁
        /// 物理读取技能手册：隐式调用提供目录索引，显式指定路径（含 SKILL.md）时完整交付并支持章节锚点切片
        public static func readManual(
            rawTarget: String,
            subDocPath: String,
            skillsBasePath: String,
            availableSkills: [AgentSkill] = []
        ) async -> String {
            guard !rawTarget.isEmpty else {
                return "❌ 参数错误：请传入有效的 target_skill_name。"
            }
            
            let fileManager = FileManager.default
            let baseDirURL = URL(fileURLWithPath: skillsBasePath).standardized
            
            let baseName = rawTarget.lowercased().replacingOccurrences(of: "^skill[-_]", with: "", options: .regularExpression)
            let candidateNames = [rawTarget, baseName, "skill-\(baseName)", "skill_\(baseName)"]
            
            var matchedFolderURL: URL? = nil
            for name in candidateNames {
                let folder = baseDirURL.appendingPathComponent(name).standardized
                if fileManager.fileExists(atPath: folder.path) {
                    matchedFolderURL = folder
                    break
                }
            }
            
            // 拆分 doc_path 中的相对路径与可选锚点 (如 "SKILL.md#安装与鉴权" 或 "#鉴权")
            let rawPathTrimmed = subDocPath.trimmingCharacters(in: .whitespacesAndNewlines)
            let pathAndAnchor = rawPathTrimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let relativeFilePath = pathAndAnchor.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let anchorKeyword = pathAndAnchor.count > 1 ? pathAndAnchor[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            
            // 当本地磁盘无物理文件夹时，优雅回退至内存技能池检索
            guard let targetFolder = matchedFolderURL else {
                let normalizedTarget = rawTarget.lowercased()
                    .replacingOccurrences(of: "-", with: "_")
                    .replacingOccurrences(of: "skill_", with: "")
                
                if let memorySkill = availableSkills.first(where: {
                    let sName = $0.name.lowercased().replacingOccurrences(of: "-", with: "_")
                    let sStripped = sName.replacingOccurrences(of: "skill_", with: "")
                    return sName == normalizedTarget || sStripped == normalizedTarget || $0.displayName.localizedCaseInsensitiveContains(rawTarget)
                }) {
                    var manualText = ""
                    if !memorySkill.detailedInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        manualText = extractAnchorSection(content: memorySkill.detailedInstruction, anchor: anchorKeyword)
                    } else {
                        // 无 detailedInstruction 时，根据元数据动态组装正向规范说明
                        var dynamicDoc = """
                        # \(memorySkill.displayName) (\(memorySkill.name))

                        > \(memorySkill.description)

                        ## 参数规范说明
                        """
                        if memorySkill.parameters.isEmpty {
                            dynamicDoc += "\n该技能无需传入任何参数。"
                        } else {
                            for param in memorySkill.parameters {
                                let reqStr = param.isRequired ? "必填" : "可选"
                                dynamicDoc += "\n- `\(param.name)` (\(param.type.rawValue), \(reqStr)): \(param.description)"
                            }
                        }
                        manualText = extractAnchorSection(content: dynamicDoc, anchor: anchorKeyword)
                    }
                    
                    let toolLessons = await MemoryManager.shared.getToolLessons(for: [baseName, rawTarget], topKPerTool: 2)
                    if !toolLessons.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        manualText += "\n\n---\n### 💡 历史调用避坑与最佳实践参考：\n\(toolLessons)"
                    }
                    return manualText
                }
                
                return "💡 未检索到技能 [\(rawTarget)] 的本地手册目录。请对照可用技能名录核对名称。"
            }
            
            // 以下为既有的物理文件读取与子文档扫描逻辑
            var targetFileURL: URL
            if relativeFilePath.isEmpty {
                let standardDocs = ["SKILL.md", "skill.md", "README.md", "manifest.json"]
                targetFileURL = standardDocs.map { targetFolder.appending(path: $0).standardized }
                    .first(where: { fileManager.fileExists(atPath: $0.path) }) ?? targetFolder.appending(path: "SKILL.md").standardized
            } else {
                let directCandidate = URL(fileURLWithPath: relativeFilePath, relativeTo: targetFolder).standardizedFileURL
                
                if fileManager.fileExists(atPath: directCandidate.path) {
                    targetFileURL = directCandidate
                } else {
                    let targetFileName = (relativeFilePath as NSString).lastPathComponent.lowercased()
                    var foundURL: URL? = nil
                    if let enumerator = fileManager.enumerator(at: targetFolder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                        for case let fileURL as URL in enumerator {
                            if fileURL.lastPathComponent.lowercased() == targetFileName {
                                foundURL = fileURL.standardized
                                break
                            }
                        }
                    }
                    targetFileURL = foundURL ?? directCandidate
                }
            }
            
            guard targetFileURL.path.hasPrefix(targetFolder.path) else {
                return "❌ 安全拦截：检测到非法路径回溯操作，已阻断访问。"
            }
            
            var manualText = ""
            if fileManager.fileExists(atPath: targetFileURL.path),
               let content = try? String(contentsOf: targetFileURL, encoding: .utf8) {
                
                if relativeFilePath.isEmpty && anchorKeyword.isEmpty {
                    manualText = SkillCommandBridge.purifyAndStructureManual(rawContent: content, skillName: rawTarget, folderURL: targetFolder)
                } else {
                    manualText = extractAnchorSection(content: content, anchor: anchorKeyword)
                }
            } else {
                manualText = "💡 未在 [\(rawTarget)] 目录下找到指定文档 [\(targetFileURL.lastPathComponent)]。请确认该子文档是否存在。"
            }
            
            if relativeFilePath.isEmpty && anchorKeyword.isEmpty {
                let toolLessons = await MemoryManager.shared.getToolLessons(for: [baseName, rawTarget], topKPerTool: 2)
                if !toolLessons.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    manualText += "\n\n---\n### 💡 历史调用避坑与最佳实践参考：\n\(toolLessons)"
                }
            }
            
            return manualText
        }
        
        // MARK: - extractAnchorSection: 章节级 Markdown 标题锚点切片引擎
        /// 从 Markdown 文本中精准截取指定标题锚点下的正文切片，未指定或未找到时优雅返回全文
        /// - Parameters:
        ///   - content: 完整的 Markdown 正文
        ///   - anchor: 章节标题关键词 (如 "安装与鉴权" 或 "鉴权")
        /// - Returns: 截取出的对应章节正文，未匹配时返回原内容
        private static func extractAnchorSection(content: String, anchor: String) -> String {
            let cleanAnchor = anchor.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
            guard !cleanAnchor.isEmpty else { return content }
            
            let lines = content.components(separatedBy: .newlines)
            var matchedStartIndex: Int? = nil
            var matchedHeaderLevel: Int = 2
            
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#") {
                    let headerLevel = trimmed.prefix(while: { $0 == "#" }).count
                    let headerText = trimmed.dropFirst(headerLevel).trimmingCharacters(in: .whitespaces).lowercased()
                    
                    if matchedStartIndex == nil {
                        if headerText.contains(cleanAnchor) {
                            matchedStartIndex = index
                            matchedHeaderLevel = headerLevel
                        }
                    } else {
                        // 遇到同级或更高级别的标题时，视为当前章节结束
                        if headerLevel <= matchedHeaderLevel {
                            let sectionLines = lines[matchedStartIndex!..<index]
                            return sectionLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                }
            }
            
            if let start = matchedStartIndex {
                let sectionLines = lines[start..<lines.count]
                return sectionLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            
            // 兜底：未匹配到锚点时安全返回完整文档
            return content
        }
    }
}

// MARK: - ==================== 7. SkillDataExchange (开放格式导入导出) ====================

public enum SkillDataExchange {
    
    public static func parseOpenAPI(data: Data) -> [AgentSkill]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let paths = json["paths"] as? [String: Any] else { return nil }
        
        var baseUrl = "https://api.example.com"
        if let servers = json["servers"] as? [[String: Any]],
           let firstServer = servers.first,
           let host = firstServer["url"] as? String {
            baseUrl = host
        }
        
        var parsedSkills: [AgentSkill] = []
        for (pathKey, pathValue) in paths {
            guard let methods = pathValue as? [String: Any] else { continue }
            for (methodKey, methodValue) in methods {
                guard let details = methodValue as? [String: Any] else { continue }
                let summary = (details["summary"] as? String) ?? (details["description"] as? String) ?? "自动导入的API"
                let operationId = (details["operationId"] as? String) ?? "\(methodKey)_\(pathKey.replacingOccurrences(of: "/", with: "_"))"
                
                var parsedParams: [SkillParameter] = []
                if let parameters = details["parameters"] as? [[String: Any]] {
                    for p in parameters {
                        let pName = p["name"] as? String ?? "unknown"
                        let pDesc = p["description"] as? String ?? ""
                        let pRequired = p["required"] as? Bool ?? false
                        var pType: ParameterType = .string
                        if let schema = p["schema"] as? [String: Any], let typeStr = schema["type"] as? String {
                            if typeStr == "integer" || typeStr == "number" { pType = .number }
                            if typeStr == "boolean" { pType = .boolean }
                        }
                        parsedParams.append(SkillParameter(name: pName, type: pType, description: pDesc, isRequired: pRequired))
                    }
                }
                
                let cleanOperationId = operationId.replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
                let skill = AgentSkill(
                    name: cleanOperationId,
                    displayName: summary,
                    description: summary,
                    detailedInstruction: "",
                    type: .api,
                    parameters: parsedParams,
                    executionBody: "\(baseUrl)\(pathKey)",
                    isEnabled: true,
                    requiresConfirmation: methodKey.lowercased() == "delete",
                    outputKey: ""
                )
                parsedSkills.append(skill)
            }
        }
        return parsedSkills
    }
}

// MARK: - ==================== 8. SkillManager (核心业务与状态门面) ====================

@Observable
@MainActor
public final class SkillManager {
    
    private static let mcpConfigKey = "mcp_servers_config"
    private static let skillsRegistryKey = "agent_skills_registry"
    
    public var skills: [AgentSkill] = []
    public var sharedContext: [String: String] = [:]
    
    public var editingSkill: AgentSkill?
    public var skillToDelete: AgentSkill?
    
    // MCP 运行状态池
    public var mcpServers: [MCPServer] = []
    public var editingMCP: MCPServer?
    public var mcpToDelete: MCPServer?
    
    private var directoryMonitor: SkillDirectoryMonitor?
    
    public init() {
        loadSkills()
        loadMCPServers()
    }
    
    // MARK: - 本地技能热重载监听
    public func startMonitoringSkillsFolder() {
        guard let skillsURL = ConfigManager.shared.skillsPath else { return }
        directoryMonitor?.stop()
        directoryMonitor = SkillDirectoryMonitor(directoryURL: skillsURL) { [weak self] in
            Task { @MainActor [weak self] in
                self?.loadSkills()
            }
        }
    }
    
    // MARK: - MCP 底座网络配置
    public func loadMCPServers() {
        if let jsonStr = LocalDatabaseManager.shared.loadConfig(key: Self.mcpConfigKey),
           let data = jsonStr.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([MCPServer].self, from: data) {
            self.mcpServers = decoded
        } else {
            self.mcpServers = []
        }
    }
    
    public func saveMCPServers() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(self.mcpServers)
            if let jsonStr = String(data: data, encoding: .utf8) {
                LocalDatabaseManager.shared.saveConfig(key: Self.mcpConfigKey, jsonString: jsonStr)
            }
        } catch {
            print("⚠️ [SkillManager] 保存 MCP 配置至 SQLite 失败: \(error)")
        }
    }
    
    public func toggleMCPStatus(id: UUID, isEnabled: Bool) {
        guard let idx = mcpServers.firstIndex(where: { $0.id == id }) else { return }
        mcpServers[idx].isEnabled = isEnabled
        
        if isEnabled {
            mcpServers[idx].status = "连接中..."
            let server = mcpServers[idx]
            saveMCPServers()
            
            Task {
                do {
                    let cmd = server.command?.trimmingCharacters(in: .whitespaces) ?? ""
                    if cmd.isEmpty { throw NSError(domain: "MCPEngine", code: 400, userInfo: [NSLocalizedDescriptionKey: "调度主命令不能为空。"]) }
                    
                    try await MCPConnectionEngine.shared.connectStdioServer(serverId: server.id.uuidString, command: cmd, args: server.args ?? "")
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                    let isAlive = await MCPConnectionEngine.shared.isServerAlive(serverId: server.id.uuidString)
                    
                    if !isAlive {
                        throw NSError(domain: "MCPEngine", code: 127, userInfo: [NSLocalizedDescriptionKey: "进程启动后意外闪退。请检查命令路径是否正确或文件是否具有执行权限。"])
                    }
                    
                    await MainActor.run {
                        if let i = self.mcpServers.firstIndex(where: { $0.id == id }) {
                            self.mcpServers[i].status = "已连接"
                            self.saveMCPServers()
                        }
                    }
                } catch {
                    await MainActor.run {
                        if let i = self.mcpServers.firstIndex(where: { $0.id == id }) {
                            self.mcpServers[i].status = "启动失败"
                            self.mcpServers[i].isEnabled = false
                            self.saveMCPServers()
                            Util.message("❌ [\(server.name)] 启动失败: \(error.localizedDescription)")
                        }
                    }
                }
            }
        } else {
            mcpServers[idx].status = "未连接"
            saveMCPServers()
            Task { await MCPConnectionEngine.shared.cleanupServer(serverId: id.uuidString) }
        }
    }
    
    public func deleteMCP(_ server: MCPServer) {
        mcpServers.removeAll { $0.id == server.id }
        saveMCPServers()
        syncMCPToolsToMemory()
    }
    
    public func sniffAndRegisterMCPTools(server: MCPServer) async throws -> Int {
        guard server.status == "已连接" else {
            throw NSError(domain: "SkillManager", code: 400, userInfo: [NSLocalizedDescriptionKey: "节点未连接，无法执行协议内省。"])
        }
        
        let serverId = server.id.uuidString
        let responseJsonStr = try await MCPConnectionEngine.shared.callTool(serverId: serverId, method: "tools/list", parameters: [:])
        
        guard let data = responseJsonStr.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tools = dict["tools"] as? [[String: Any]] else {
            throw NSError(domain: "SkillManager", code: 500, userInfo: [NSLocalizedDescriptionKey: "无法解析节点返回的工具清单报文。"])
        }
        
        var newSkillCount = 0
        
        for tool in tools {
            let toolName = tool["name"] as? String ?? ""
            let toolDesc = tool["description"] as? String ?? "由 \(server.name) 提供的动态 MCP 工具"
            
            let existingIndex = self.skills.firstIndex { $0.type == .mcp && $0.entryPoint == toolName && $0.executionBody == serverId }
            if existingIndex != nil { continue }
            
            var skillParams: [SkillParameter] = []
            if let inputSchema = tool["inputSchema"] as? [String: Any],
               let properties = inputSchema["properties"] as? [String: Any] {
                let requiredKeys = inputSchema["required"] as? [String] ?? []
                for (key, propValue) in properties {
                    if let propDict = propValue as? [String: Any] {
                        let typeStr = propDict["type"] as? String ?? "string"
                        let propDesc = propDict["description"] as? String ?? ""
                        let isReq = requiredKeys.contains(key)
                        var pType: ParameterType = .string
                        switch typeStr.lowercased() {
                        case "integer", "number": pType = .number
                        case "boolean": pType = .boolean
                        case "array": pType = .array
                        case "object": pType = .object
                        default: pType = .string
                        }
                        skillParams.append(SkillParameter(name: key, type: pType, description: propDesc, isRequired: isReq))
                    }
                }
            }
            
            let magicUI = "### 🪄 [{{args.method|default:'\(toolName)'}}] 执行结果\n由底层节点 **\(server.name)** 代理执行完毕。\n\n> ++{{output}}++"
            
            let newSkill = AgentSkill(
                name: "mcp_\(toolName)",
                displayName: "🔗 [\(server.name)] \(toolName)",
                description: toolDesc,
                detailedInstruction: "此工具由 `\(server.name)` 节点底层驱动。参数由 MCP 协议动态分发。",
                type: .mcp,
                parameters: skillParams,
                executionBody: serverId,
                isEnabled: true,
                requiresConfirmation: false,
                outputKey: "mcp_result",
                isLocal: false,
                entryPoint: toolName,
                category: "MCP 网络",
                uiTemplate: magicUI
            )
            
            self.skills.append(newSkill)
            newSkillCount += 1
        }
        
        if newSkillCount > 0 { self.saveSkills() }
        return newSkillCount
    }
    
    private func syncMCPToolsToMemory() {
        self.skills.removeAll { $0.type == .mcp }
        for server in mcpServers where server.isEnabled && server.status == "已连接" {
            let dynamicTool = AgentSkill(
                name: "mcp_\(server.id.uuidString.prefix(6).lowercased())_proxy",
                displayName: "🔗 [\(server.name)] 代理执行器",
                description: "该工具由 MCP 协议动态提供。可执行网络服务下发的跨系统操作。",
                detailedInstruction: "此为底层 MCP RPC 调度代理。",
                type: .mcp,
                parameters: [
                    SkillParameter(name: "method", type: .string, description: "需要调用的 MCP Tool Name", isRequired: true),
                    SkillParameter(name: "arguments", type: .object, description: "传给该工具的 JSON Payload", isRequired: true)
                ],
                executionBody: server.id.uuidString,
                isEnabled: true,
                requiresConfirmation: false,
                isLocal: false,
                category: "MCP协议"
            )
            self.skills.append(dynamicTool)
        }
    }
    
    // MARK: - 统一执行调度总线
    /// 执行指定的智能体技能，包含安全扫描、权限拦截、通用参数桥接与多态分发
    public func executeTool(skill: AgentSkill, args: [String: Any], skipConfirmation: Bool = false) async -> String {
        var flatArgs = args
        if let cmdArgsStr = args["raw_command"] as? String,
           let data = cmdArgsStr.data(using: .utf8),
           let jsonDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in jsonDict { flatArgs[k] = v }
        }

        // 核心对齐：建立命令行/输入等价键名双向映射，防止参数校验因名称差异被误拦截
        if flatArgs["command"] == nil {
            if let val = flatArgs["input"] ?? flatArgs["raw_command"] ?? flatArgs["action"] {
                flatArgs["command"] = val
            }
        }
        if flatArgs["input"] == nil {
            if let val = flatArgs["command"] ?? flatArgs["raw_command"] ?? flatArgs["action"] {
                flatArgs["input"] = val
            }
        }
        if flatArgs["raw_command"] == nil {
            if let val = flatArgs["command"] ?? flatArgs["input"] ?? flatArgs["action"] {
                flatArgs["raw_command"] = val
            }
        }

        var missingParams: [String] = []
        for param in skill.parameters where param.isRequired {
            if flatArgs[param.name] == nil { missingParams.append(param.name) }
        }
        if !missingParams.isEmpty { return "❌ 参数校验失败：缺少必填参数 [\(missingParams.joined(separator: ", "))]" }
        
        if skill.requiresConfirmation && !skipConfirmation {
            let isAuthorized = await SystemAuthUI.requestUserPermission(title: "⚠️ AI 请求执行高危指令", message: "工具: \(skill.displayName)\n参数: \(args)", dangerLevel: .high)
            if !isAuthorized { return "❌ 拒绝执行：用户取消了系统授权。" }
        }
        
        if let rawCommand = flatArgs["raw_command"] as? String {
            if !SecurityScanner.isSafe(command: rawCommand) { return "❌ 安全警告：指令触碰了系统核心敏感目录，强制阻断。" }
        }
        if skill.type == .shell || skill.type == .python || skill.type == .applescript || skill.type == .cli {
            if !SecurityScanner.isSafe(command: skill.executionBody) { return "❌ 安全警告：脚本或命令包含高危操作代码，防毒拦截。" }
        }
        
        var executionResult: String = ""
        switch skill.type {
        case .cli:
            let workingDir = skill.workingDirectory ?? ConfigManager.shared.skillsPath?.path ?? "/tmp"
            var commandStr = (flatArgs["command"] as? String) ?? (flatArgs["raw_command"] as? String) ?? (flatArgs["input"] as? String) ?? ""
            
            commandStr = SkillCommandBridge.normalizeCLICommand(command: commandStr, skill: skill)
            commandStr = SkillCommandBridge.autoBridgeInlineJSONToTempFile(command: commandStr, workingDirectory: workingDir)
            
            flatArgs["command"] = commandStr
            flatArgs["raw_command"] = commandStr
            flatArgs["input"] = commandStr
            
            executionResult = await SkillExecutors.CLI.execute(
                executableTarget: skill.executionBody.trimmingCharacters(in: .whitespacesAndNewlines),
                args: flatArgs,
                sharedContext: self.sharedContext,
                workingDirectory: skill.workingDirectory,
                skillParameters: skill.parameters
            )
            
        case .shell:
            executionResult = await SkillExecutors.Shell.execute(
                scriptSource: skill.executionBody,
                args: flatArgs,
                sharedContext: self.sharedContext,
                workingDirectory: skill.workingDirectory,
                entryPoint: skill.entryPoint
            )
            
        case .applescript:
            executionResult = await SkillExecutors.AppleScript.execute(
                scriptSource: skill.executionBody,
                args: flatArgs,
                sharedContext: self.sharedContext,
                workingDirectory: skill.workingDirectory,
                entryPoint: skill.entryPoint
            )
            
        case .python:
            executionResult = await SkillExecutors.Python.execute(
                scriptSource: skill.executionBody,
                args: flatArgs,
                sharedContext: self.sharedContext,
                workingDirectory: skill.workingDirectory,
                entryPoint: skill.entryPoint
            )
            
        case .api:
            executionResult = await SkillExecutors.API.execute(
                apiSource: skill.executionBody,
                args: flatArgs,
                sharedContext: self.sharedContext
            )
            
        case .mcp:
            let serverConfig = self.mcpServers.first(where: { $0.id.uuidString == skill.executionBody })
            executionResult = await SkillExecutors.MCP.execute(
                serverId: skill.executionBody,
                method: skill.entryPoint ?? "",
                args: flatArgs,
                serverConfig: serverConfig
            )
            
        case .builtin:
            if skill.executionBody == "builtin_evolve" {
                executionResult = await SkillExecutors.Builtin.executeEvolve(args: flatArgs, manager: self)
            } else if skill.executionBody == "builtin_memory" {
                let action = flatArgs["action"] as? String ?? ""
                let content = flatArgs["content"] as? String ?? ""
                if action == "save" {
                    let cat = flatArgs["category"] as? String ?? "项目环境"
                    let imp = flatArgs["importance"] as? Int ?? 5
                    executionResult = await MemoryManager.shared.addMemory(content: content, category: cat, importance: imp)
                } else if action == "search" {
                    let searchRes = await MemoryManager.shared.searchContext(for: content, topK: 3)
                    executionResult = searchRes.isEmpty ? "当前记忆库中未找到关于「\(content)」的强关联线索。" : searchRes
                } else {
                    executionResult = "❌ 未知的 action，必须为 save 或 search"
                }
            } else if skill.executionBody == "builtin_finish" {
                return "[AGENT_PIPELINE_TERMINATE]:\((flatArgs["final_answer"] as? String) ?? "结束")"
            } else if skill.executionBody == "builtin_read_manual" {
                let rawTarget = (flatArgs["target_skill_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let subDocPath = (flatArgs["doc_path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let basePath = skill.workingDirectory ?? ConfigManager.shared.skillsPath?.path ?? ""
                executionResult = await SkillExecutors.Builtin.readManual(
                    rawTarget: rawTarget,
                    subDocPath: subDocPath,
                    skillsBasePath: basePath,
                    availableSkills: self.skills
                )
            } else if skill.executionBody == "builtin_unified_runner" {
                let targetSkillName = (flatArgs["skill_name"] as? String) ?? (flatArgs["target_skill_name"] as? String) ?? ""
                var rawInput = (flatArgs["input"] as? String) ?? (flatArgs["command"] as? String) ?? (flatArgs["action"] as? String) ?? (flatArgs["raw_command"] as? String) ?? ""
                
                if rawInput.isEmpty, let argStr = flatArgs["arguments"] as? String {
                    rawInput = argStr
                } else if rawInput.isEmpty, let argDict = flatArgs["arguments"] as? [String: Any] {
                    rawInput = (argDict["command"] as? String) ?? (argDict["input"] as? String) ?? (argDict["action"] as? String) ?? ""
                }
                
                guard !targetSkillName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "❌ 执行失败：缺少必填参数 skill_name。" }
                guard !rawInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "❌ 执行失败：缺少执行参数 input。" }
                
                let normalizedTarget = targetSkillName.lowercased()
                    .replacingOccurrences(of: "-", with: "_")
                    .replacingOccurrences(of: "skill_", with: "")

                guard let physicalSkill = self.skills.first(where: {
                    let sName = $0.name.lowercased().replacingOccurrences(of: "-", with: "_")
                    let sStripped = sName.replacingOccurrences(of: "skill_", with: "")
                    return sName == targetSkillName.lowercased()
                        || sName == normalizedTarget
                        || sStripped == normalizedTarget
                        || $0.displayName.localizedCaseInsensitiveContains(targetSkillName)
                }) else {
                    return "💡 系统中未找到已挂载的技能 [\(targetSkillName)]。请对照可用技能名录核对名称。"
                }
                
                if physicalSkill.requiresConfirmation && !skipConfirmation {
                    let isAuthorized = await SystemAuthUI.requestUserPermission(
                        title: "⚠️ AI 申请执行系统级动作",
                        message: "工具: \(physicalSkill.displayName)\n入参: \(rawInput)",
                        dangerLevel: .high
                    )
                    if !isAuthorized { return "❌ 拒绝执行：用户取消了系统授权。" }
                }
                
                var childArgs: [String: Any] = [:]
                if physicalSkill.type == .cli || physicalSkill.type == .shell {
                    let workingDir = physicalSkill.workingDirectory ?? ConfigManager.shared.skillsPath?.path ?? "/tmp"
                    
                    // 防篡改：通用终端直接放行，专用业务工具才走自适应对齐
                    let isUniversalTerminal = physicalSkill.name == "system_terminal" || physicalSkill.name == "bash_runner" || physicalSkill.name.contains("terminal")
                    
                    var bridgedCommand = isUniversalTerminal ? rawInput : SkillCommandBridge.normalizeCLICommand(command: rawInput, skill: physicalSkill)
                    bridgedCommand = SkillCommandBridge.autoBridgeInlineJSONToTempFile(command: bridgedCommand, workingDirectory: workingDir)
                    
                    childArgs["command"] = bridgedCommand
                    childArgs["raw_command"] = bridgedCommand
                    childArgs["input"] = bridgedCommand
                    childArgs["raw_args"] = SkillCommandBridge.splitCommandLine(bridgedCommand)
                } else {
                    if let data = rawInput.data(using: .utf8),
                       let jsonDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        childArgs = jsonDict
                    } else if let dynamicArgs = flatArgs["arguments"] as? [String: Any] {
                        childArgs = dynamicArgs
                    } else {
                        childArgs["raw_input"] = rawInput
                        childArgs["command"] = rawInput
                    }
                }
                
                executionResult = await executeTool(skill: physicalSkill, args: childArgs, skipConfirmation: true)
            } else if skill.executionBody == "builtin_knowledge_search" {
                let searchQuery = (flatArgs["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                var searchCategory = (flatArgs["category"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                
                if searchQuery.isEmpty {
                    executionResult = "❌ 检索失败：query 参数不能为空。"
                } else {
                    let activeAgentID = AiChatStore.shared.selectedAgentID
                    let currentAgent = ConfigManager.shared.app.agentProfiles.first(where: { $0.id == activeAgentID })
                    if searchCategory.isEmpty {
                        searchCategory = currentAgent?.bindKnowledgeCategory ?? "全部"
                    }
                    let currentModel = currentAgent?.baseModel ?? ""
                    
                    let knowledgeVM = KnowledgeViewModel()
                    let ragResult = await knowledgeVM.injectedRag(query: searchQuery, category: searchCategory, currentModel: currentModel)
                    executionResult = ragResult.context.isEmpty ? "⚠️ 在分类 [\(searchCategory.isEmpty ? "全局" : searchCategory)] 中未找到与「\(searchQuery)」相关的有效切片。" : ragResult.context
                }
            } else {
                executionResult = "系统原生方法暂未对接具体的路由"
            }
        }
        
        // 进化技能动态评分与熔断
        if skill.category == "进化" {
            let lowerResult = executionResult.lowercased()
            let isFailure = executionResult.contains("❌") || executionResult.contains("⚠️") || lowerResult.contains("error") || lowerResult.contains("exception") || lowerResult.contains("traceback")
            
            if let idx = self.skills.firstIndex(where: { $0.id == skill.id }) {
                if isFailure {
                    self.skills[idx].score -= 15
                } else {
                    self.skills[idx].score = min(100, self.skills[idx].score + 5)
                }
                
                if self.skills[idx].score < 60 {
                    self.skills[idx].isEnabled = false
                    self.saveSkills()
                    print("🛑 [熔断机制] 进化技能 [\(skill.name)] 评分跌破及格线(\(self.skills[idx].score)分)，已被系统自动停用。")
                    return executionResult + "\n\n[SYSTEM ALERT]: 警告！您所调用的技能 [\(skill.name)] 因连续执行抛错，健康评分已跌至 \(self.skills[idx].score) 分。触发系统底层熔断安全机制，系统已强制将其永久停用！请立刻停止调用此技能，换用其他方案！"
                }
                self.saveSkills()
            }
        }
        
        return executionResult
    }
    
    // MARK: - 数据持久化与生命周期管理
    public func getActiveSkills(for agentID: UUID? = nil) -> [AgentSkill] {
        let allEnabledSkills = skills.filter { $0.isEnabled }
        let targetID = agentID ?? AiChatStore.shared.selectedAgentID
        guard let profile = ConfigManager.shared.app.agentProfiles.first(where: { $0.id == targetID }) else {
            return allEnabledSkills
        }
        
        var mandatoryPipelineSkills = [""]
        if profile.enableAutonomy {
            mandatoryPipelineSkills.append("knowledge_search")
        }
        
        return allEnabledSkills.filter { skill in
            mandatoryPipelineSkills.contains(skill.name) || profile.equippedSkillIDs.contains(skill.id)
        }
    }
    
    public func loadSkills() {
        var localSkills = LocalSkillScanner.scanAndMount()
        var userSkills: [AgentSkill] = []
        
        if let jsonStr = LocalDatabaseManager.shared.loadConfig(key: Self.skillsRegistryKey),
           let data = jsonStr.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([AgentSkill].self, from: data) {
            userSkills = decoded
        }
        
        for i in 0..<localSkills.count {
            let stableID = LocalSkillScanner.makeDeterministicID(for: localSkills[i].name)
            if let match = userSkills.first(where: { $0.name == localSkills[i].name }) {
                localSkills[i].isEnabled = match.isEnabled
                localSkills[i].id = match.id
                localSkills[i].score = match.score
                localSkills[i].category = match.category
            } else {
                localSkills[i].id = stableID
            }
        }
        
        let localNames = Set(localSkills.map { $0.name })
        var customUserSkills = userSkills.filter { !localNames.contains($0.name) && !$0.isLocal }
        
        var systemSkills = [
            Skill_ReadManual(),
            Skill_ExecuteSkill(),
            Skill_Terminal(),
            Skill_Evolve(),
            Skill_MemoryManager(),
            Skill_CallAgent(),
            Skill_Finish(),
            Skill_KnowledgeSearch(),
            Skill_CallPersona()
        ]
        
        for i in 0..<systemSkills.count {
            let stableSystemID = UUID.deterministic(from: "skill_system_\(systemSkills[i].name)")
            if let match = userSkills.first(where: { $0.name == systemSkills[i].name }) {
                systemSkills[i].isEnabled = match.isEnabled
                systemSkills[i].id = match.id
                systemSkills[i].score = match.score
            } else {
                systemSkills[i].id = stableSystemID
            }
        }
        
        let systemNames = Set(systemSkills.map { $0.name })
        customUserSkills.removeAll { systemNames.contains($0.name) }
        localSkills.removeAll { systemNames.contains($0.name) }
        
        var normalSkills = localSkills + customUserSkills
        normalSkills.sort { $0.createdAt > $1.createdAt }
        
        var newAssembledSkills = systemSkills + normalSkills
        newAssembledSkills.removeAll { $0.type == .mcp && $0.name.hasSuffix("_proxy") }
        
        let isSkillsChanged = (self.skills != newAssembledSkills)
        self.skills = newAssembledSkills
        
        if isSkillsChanged {
            saveSkills()
        }
    }
    
    public func saveSkills() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(self.skills)
            if let jsonStr = String(data: data, encoding: .utf8) {
                LocalDatabaseManager.shared.saveConfig(key: Self.skillsRegistryKey, jsonString: jsonStr)
            }
        } catch {
            print("⚠️ [SkillManager] 保存技能注册表至 SQLite 失败: \(error)")
        }
    }
    
    public func syncLocalSkillFiles(skill: inout AgentSkill) -> Bool {
        guard skill.isLocal else { return false }
        
        if skill.workingDirectory == nil || skill.workingDirectory!.isEmpty {
            guard let skillsURL = ConfigManager.shared.skillsPath else { return false }
            let safeFolderName = skill.name.replacingOccurrences(of: " ", with: "_")
            skill.workingDirectory = skillsURL.appendingPathComponent(safeFolderName).path
        }
        
        guard let wd = skill.workingDirectory, !wd.isEmpty else { return false }
        let folderURL = URL(fileURLWithPath: wd)
        
        do {
            if !FileManager.default.fileExists(atPath: folderURL.path) {
                try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true, attributes: nil)
            }
            
            let mdURL = folderURL.appendingPathComponent("SKILL.md")
            var mdContent = ""
            
            if !skill.detailedInstruction.hasPrefix("---") && !skill.detailedInstruction.isEmpty {
                mdContent = "---\nname: \(skill.name)\ndescription: \(skill.description)\ncategory: \(skill.category)\n---\n\n\(skill.detailedInstruction)"
            } else if !skill.detailedInstruction.isEmpty {
                mdContent = skill.detailedInstruction
            } else {
                mdContent = "---\nname: \(skill.name)\ndescription: \(skill.description)\ncategory: \(skill.category)\n---\n\n# \(skill.displayName)\n\n> \(skill.description)\n\n## 核心逻辑\n此技能由本地脚本直接驱动。"
            }
            try mdContent.write(to: mdURL, atomically: true, encoding: .utf8)
            
            if skill.entryPoint == "SKILL.md (Instruction Only)" {
                try? FileManager.default.removeItem(at: folderURL.appendingPathComponent("manifest.json"))
                try? FileManager.default.removeItem(at: folderURL.appendingPathComponent("scripts"))
                try? FileManager.default.removeItem(at: folderURL.appendingPathComponent("script.sh"))
                try? FileManager.default.removeItem(at: folderURL.appendingPathComponent("script.py"))
                return true
            }
            
            var ep = skill.entryPoint ?? ""
            if ep.isEmpty || ep.contains("SKILL.md") || ep.contains("Inline") {
                let ext: String
                switch skill.type {
                case .python: ext = "py"
                case .applescript: ext = "scpt"
                case .shell, .builtin, .cli: ext = "sh"
                case .api, .mcp: ext = "json"
                }
                ep = "script.\(ext)"
                skill.entryPoint = ep
            }
            
            let manifestURL = folderURL.appendingPathComponent("manifest.json")
            let scriptURL = folderURL.appendingPathComponent(ep)
            
            if skill.type != .cli {
                try skill.executionBody.write(to: scriptURL, atomically: true, encoding: .utf8)
                if skill.type == .shell {
                    let task = Process(); task.executableURL = URL(fileURLWithPath: "/bin/chmod"); task.arguments = ["+x", scriptURL.path]; try? task.run(); task.waitUntilExit()
                }
            }
            
            var parameters: [[String: Any]] = []
            for p in skill.parameters {
                parameters.append(["name": p.name, "type": p.type.rawValue, "description": p.description, "isRequired": p.isRequired])
            }
            
            var typeStr: String
            switch skill.type {
            case .python: typeStr = "python"
            case .applescript: typeStr = "applescript"
            case .api: typeStr = "api"
            case .mcp: typeStr = "mcp"
            case .cli: typeStr = "cli"
            case .shell, .builtin: typeStr = "shell"
            }
            
            let manifestDict: [String: Any] = [
                "name": skill.name, "displayName": skill.displayName, "description": skill.description,
                "type": typeStr, "entryPoint": ep, "requiresConfirmation": skill.requiresConfirmation,
                "outputKey": skill.outputKey, "category": skill.category, "parameters": parameters
            ]
            let manifestData = try JSONSerialization.data(withJSONObject: manifestDict, options: [.prettyPrinted, .sortedKeys])
            try manifestData.write(to: manifestURL, options: .atomic)
            return true
            
        } catch {
            print("❌ 同步写入本地技能文件失败: \(error)")
            return false
        }
    }
    
    public func toggleSkillStatus(id: UUID, isEnabled: Bool) {
        if let index = skills.firstIndex(where: { $0.id == id }) {
            skills[index].isEnabled = isEnabled
            if isEnabled && skills[index].score < 60 { skills[index].score = 100 }
            saveSkills()
        }
    }
    
    public func deleteSkill(_ skill: AgentSkill, deleteLocalFiles: Bool) {
        if deleteLocalFiles, skill.isLocal, let wd = skill.workingDirectory, !wd.isEmpty {
            let folderURL = URL(fileURLWithPath: wd)
            if let skillsPath = ConfigManager.shared.skillsPath?.path, wd.hasPrefix(skillsPath) {
                do {
                    try FileManager.default.removeItem(at: folderURL)
                    print("🗑️ [SkillManager] 已彻底粉碎本地技能文件夹: \(folderURL.path)")
                } catch { Util.alert(title: "文件删除失败", text: error.localizedDescription) }
            }
        }
        self.skills.removeAll { $0.id == skill.id }
        var isProfileChanged = false
        for i in 0..<ConfigManager.shared.app.agentProfiles.count {
            if ConfigManager.shared.app.agentProfiles[i].equippedSkillIDs.contains(skill.id) {
                ConfigManager.shared.app.agentProfiles[i].equippedSkillIDs.removeAll { $0 == skill.id }
                isProfileChanged = true
            }
        }
        if isProfileChanged { ConfigManager.shared.saveConfig() }
        self.saveSkills()
    }
    
    public func testSkill(_ skill: AgentSkill, customArgs: [String: Any]? = nil) {
        if skill.requiresConfirmation {
            let alert = NSAlert()
            alert.messageText = "安全拦截 (HITL)"
            alert.informativeText = "即将测试执行高危技能「\(skill.displayName)」\n\n这可能会对系统或云端数据造成影响，是否允许执行？"
            alert.alertStyle = .critical
            alert.addButton(withTitle: "允许执行")
            alert.addButton(withTitle: "拒绝")
            if alert.runModal() != .alertFirstButtonReturn {
                Util.message("已取消高危技能执行")
                return
            }
        }
        var finalArgs: [String: Any] = [:]
        if let custom = customArgs {
            finalArgs = custom
        } else {
            for param in skill.parameters { finalArgs[param.name] = "TestValue_\(param.name)" }
        }
        Task {
            let executionResult = await executeTool(skill: skill, args: finalArgs)
            await MainActor.run {
                Util.alert(title: skill.type == .api ? "API 调用完成" : (skill.type == .cli ? "CLI 执行完成" : "脚本执行完成"), text: executionResult)
                if !skill.outputKey.isEmpty && !executionResult.contains("❌") {
                    self.sharedContext[skill.outputKey] = executionResult
                    Util.message("已成功将结果挂载至上下文变量: {\(skill.outputKey)}")
                }
            }
        }
    }
    
    public func importFile(allowedTypes: [UTType], completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = allowedTypes
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.begin { response in if response == .OK, let url = panel.url { completion(url) } }
    }
    
    public func exportFile(defaultName: String, completion: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [.json]
        panel.begin { response in if response == .OK, let url = panel.url { completion(url) } }
    }
    
    public func exportSkills(url: URL) {
        if let encoded = try? JSONEncoder().encode(skills) {
            try? encoded.write(to: url, options: .atomic)
            Util.message("技能链已成功导出")
        }
    }
    
    public func importSkills(url: URL) {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([AgentSkill].self, from: data) {
            self.skills.append(contentsOf: decoded)
            saveSkills()
            Util.message("成功导入 \(decoded.count) 个技能")
        } else {
            Util.alert(title: "导入失败", text: "无法解析该文件，请确保格式正确。")
        }
    }
    
    public func importOpenAPI(url: URL) {
        guard let data = try? Data(contentsOf: url),
              let importedSkills = SkillDataExchange.parseOpenAPI(data: data) else {
            Util.alert(title: "解析失败", text: "未找到有效的 OpenAPI paths 节点。")
            return
        }
        self.skills.append(contentsOf: importedSkills)
        saveSkills()
        Util.message("OpenAPI 扫描完成，共动态生成并挂载 \(importedSkills.count) 个新技能。")
    }
    
    public func openSkillFolder() {
        if let url = ConfigManager.shared.skillsPath {
            NSWorkspace.shared.open(url)
        } else {
            Util.alert(title: "错误", text: "无法定位本地技能文件夹路径，请检查沙盒权限或配置。")
        }
    }
    
    // MARK: - 团队与分身静态名录生成器 (严格授权过滤 + 确定性排序 + 100% 保护 Prompt Cache)
    /// 构造当前智能体已授权的协作专家与数字分身白皮书
    /// - Parameter mainAgent: 当前执行任务的主控智能体档案
    /// - Returns: 符合缓存友好规范的纯静态 XML 结构串；若未授权任何协作角色则返回空字符串
    func generateTeamManifest(for mainAgent: AgentProfile) -> String {
        let allProfiles = ConfigManager.shared.app.agentProfiles
        let allPersonas = PersonaManager.shared.personas
        
        // 1. 严格权限剪枝：只允许当前 Agent 显式勾选配备的专家和数字分身
        let allowedSubAgents = allProfiles
            .filter { mainAgent.allowedSubAgentIDs.contains($0.id) && $0.id != mainAgent.id }
            .sorted { $0.id.uuidString < $1.id.uuidString } // 确定性排序，保护 KV Cache 前缀
            
        let allowedPersonas = allPersonas
            .filter { mainAgent.allowedPersonaIDs.contains($0.id) }
            .sorted { $0.id.uuidString < $1.id.uuidString } // 确定性排序，保护 KV Cache 前缀
        
        // 2. 双重判空守卫：若均未配备，彻底返回空，绝不输出外层空标签骨架
        guard !allowedSubAgents.isEmpty || !allowedPersonas.isEmpty else {
            return ""
        }
        
        var manifest = """
        
        <delegation_registry>
        <!-- 当前系统已注册并授权的协作专家与角色名录，仅供调用委派工具时参考参数规范 -->
        
        """
        
        // 3. 专家智能体名录装配 (保持静态路由说明与挂载技能)
        if !allowedSubAgents.isEmpty {
            manifest += "### 🤖 可委派的专家智能体 (通过 call_sub_agent 唤醒):\n"
            for sub in allowedSubAgents {
                let lines = sub.systemPrompt.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                let safeSummary = lines.first(where: { !$0.isEmpty }) ?? "提供专业的领域定制化任务处理能力"
                manifest += "- **[\(sub.name)]**: \(safeSummary)\n"
                
                let subSkillNames = sub.equippedSkillIDs.compactMap { skillId in
                    self.skills.first(where: { $0.id == skillId })?.name
                }.sorted()
                
                if !subSkillNames.isEmpty {
                    manifest += "  └ 挂载工具: \(subSkillNames.joined(separator: ", "))\n"
                }
            }
            manifest += "\n"
        }
        
        // 4. 数字分身静态档案装配 (彻底剥离 affinityScore 与 currentEmotion 等动态变量)
        if !allowedPersonas.isEmpty {
            manifest += "### 🎭 可对戏的数字分身 (通过 call_digital_persona 呼叫):\n"
            for p in allowedPersonas {
                let worldDesc = p.worldviewContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "现代日常" : p.worldviewContext
                let toneDesc = p.toneStyle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "灵动自然、真诚生动" : p.toneStyle
                let summaryDesc = p.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "角色专属互动伙伴" : p.summary
                
                // 纯静态内容声明：保持字节流恒定不变，最大化命中大模型底座 KV 缓存
                manifest += "- **[\(p.name)]** (\(p.roleTag)): \(summaryDesc)\n"
                manifest += "  └ 世界观: \(worldDesc) | 口吻风格: \(toneDesc)\n"
            }
            manifest += "\n"
        }
        
        manifest += "</delegation_registry>\n"
        return manifest
    }
}

// MARK: - ==================== 9. SkillSessionCache (会话参数缓存池) ====================

@MainActor
public final class SkillSessionCache: ObservableObject {
    public static let shared = SkillSessionCache()
    @Published private var memoryBank: [String: [String: Any]] = [:]
    
    private init() {}
    
    public func saveRecentArgs(for skillName: String, args: [String: Any]) {
        memoryBank[skillName] = args
    }
    
    public func getRecentArgs(for skillName: String) -> [String: Any]? {
        return memoryBank[skillName]
    }
    
    public func hydrateForm(skillName: String, defaultArgs: [String: Any]) -> [String: Any] {
        var hydrated = defaultArgs
        guard let lastMemory = getRecentArgs(for: skillName) else { return hydrated }
        for (key, _) in hydrated {
            if let rememberedValue = lastMemory[key] { hydrated[key] = rememberedValue }
        }
        return hydrated
    }
    
    public func clearAllSessionMemory() {
        memoryBank.removeAll()
    }
}

// MARK: - ==================== 10. SkillUI Components (管理面板与交互视图) ====================

struct SkillFrostedGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label.font(.headline)
            configuration.content
        }
        .padding()
        .background(Color.primary.opacity(0.02))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }
}

@MainActor
public struct SkillManagementPanel: View {
    @Bindable var viewModel: SkillManager
    @State private var showEditSheet = false
    @State private var showDeleteAlert = false
    @State private var skillToTest: AgentSkill? = nil
    
    public init(viewModel: SkillManager) {
        self.viewModel = viewModel
    }
    
    var groupedSkills: [(String, [AgentSkill])] {
        var dict: [String: [AgentSkill]] = [:]
        for skill in viewModel.skills { dict[skill.category, default: []].append(skill) }
        var result: [(String, [AgentSkill])] = []
        let orderedCategories = ConfigManager.shared.app.generalConfig.aCategories
        for cat in orderedCategories {
            if let skillsInCat = dict[cat] { result.append((cat, skillsInCat)); dict.removeValue(forKey: cat) }
        }
        for (cat, skillsInCat) in dict.sorted(by: { $0.key < $1.key }) { result.append((cat, skillsInCat)) }
        return result
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            topBarView
            ModernDivider(style: .fade(0.18))
            contentListView
        }
        .background(Color.clear)
        .alert("确认删除技能？", isPresented: $showDeleteAlert, presenting: viewModel.skillToDelete, actions: alertActions, message: alertMessage)
        .sheet(isPresented: $showEditSheet, content: editSheetContent)
        .sheet(item: $skillToTest, content: testSheetContent)
    }
    
    @ViewBuilder
    private var contentListView: some View {
        List {
            ForEach(groupedSkills, id: \.0) { group in
                Section(header: Text("📁 分类: \(group.0)").font(.system(size: 13, weight: .bold)).foregroundColor(.secondary).padding(.top, 8).padding(.bottom, 2)) {
                    ForEach(group.1) { skill in
                        SkillRowView(
                            skill: skill,
                            viewModel: viewModel,
                            showEditSheet: $showEditSheet,
                            showDeleteAlert: $showDeleteAlert,
                            skillToTest: $skillToTest
                        )
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .forceOverlayScrollbars()
    }
    
    @ViewBuilder
    private var topBarView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("技能链配置").font(.headline)
                Text("配置 AI 能够主动调用的系统级或 API 接口能力").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: { viewModel.openSkillFolder() }) {
                Label("技能目录", systemImage: "folder").font(.system(size: 13, weight: .medium))
            }
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) { viewModel.loadSkills() }
                Util.message("✅ 技能列表已刷新")
            }) {
                Label("刷新列表", systemImage: "arrow.clockwise").font(.system(size: 13, weight: .medium))
            }
            Menu {
                Button("导入标准 JSON 技能") { viewModel.importFile(allowedTypes: [.json]) { url in viewModel.importSkills(url: url) } }
                Button("扫描 OpenAPI / Swagger") { viewModel.importFile(allowedTypes: [.json]) { url in viewModel.importOpenAPI(url: url) } }
            } label: {
                Label("导入...", systemImage: "square.and.arrow.down")
            }
            Button {
                viewModel.exportFile(defaultName: "skills_export.json") { url in viewModel.exportSkills(url: url) }
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            Button {
                viewModel.editingSkill = AgentSkill(name: "new_skill", displayName: "新工具", description: "", detailedInstruction: "", type: .cli, parameters: [], executionBody: "", isEnabled: true, requiresConfirmation: false, outputKey: "", isLocal: true, category: "自定义")
                showEditSheet = true
            } label: {
                Label("新建技能", systemImage: "plus")
            }.buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.thinMaterial)
    }
    
    @ViewBuilder
    private func alertActions(for skill: AgentSkill) -> some View {
        if skill.isLocal {
            Button("删除记录并粉碎本地文件", role: .destructive) { withAnimation { viewModel.deleteSkill(skill, deleteLocalFiles: true) } }
            Button("仅删除列表记录", role: .destructive) { withAnimation { viewModel.deleteSkill(skill, deleteLocalFiles: false) } }
        } else {
            Button("删除记录", role: .destructive) { withAnimation { viewModel.deleteSkill(skill, deleteLocalFiles: false) } }
        }
        Button("取消", role: .cancel) { }
    }
    
    @ViewBuilder
    private func alertMessage(for skill: AgentSkill) -> some View {
        if skill.isLocal {
            Text("「\(skill.displayName)」是本地技能。\n您要连同它在硬盘上的独立文件夹一起彻底删除吗？（物理删除操作不可逆）")
        } else {
            Text("将彻底删除「\(skill.displayName)」。")
        }
    }
    
    @ViewBuilder
    private func editSheetContent() -> some View {
        if let skill = viewModel.editingSkill {
            SkillEditView(
                viewModel: viewModel,
                skill: skill,
                isNew: !viewModel.skills.contains(where: { $0.id == skill.id }),
                onSave: { updatedSkill in
                    var finalSkill = updatedSkill
                    if finalSkill.isLocal {
                        let success = viewModel.syncLocalSkillFiles(skill: &finalSkill)
                        if success { Util.message("✅ 本地文件已同步覆写") }
                    }
                    if let index = viewModel.skills.firstIndex(where: { $0.id == finalSkill.id }) {
                        viewModel.skills[index] = finalSkill
                    } else {
                        viewModel.skills.append(finalSkill)
                    }
                    viewModel.saveSkills()
                    showEditSheet = false
                },
                onCancel: {
                    showEditSheet = false
                }
            )
        }
    }
    
    @ViewBuilder
    private func testSheetContent(skill: AgentSkill) -> some View {
        SkillTestRunView(
            skill: skill,
            onRun: { args in
                viewModel.testSkill(skill, customArgs: args)
                skillToTest = nil
            },
            onCancel: {
                skillToTest = nil
            }
        )
    }
}

struct SkillRowView: View {
    let skill: AgentSkill
    let viewModel: SkillManager
    @Binding var showEditSheet: Bool
    @Binding var showDeleteAlert: Bool
    @Binding var skillToTest: AgentSkill?
    
    var paramString: String {
        skill.parameters.map { $0.name }.joined(separator: ", ")
    }
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: skill.type == .cli ? "terminal.fill" : "bolt.fill")
                .foregroundStyle(skill.isEnabled ? (skill.type == .cli ? .teal : .orange) : .gray.opacity(0.5))
                .font(.title2)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 6) {
                Text(skill.displayName)
                    .font(.headline)
                    .foregroundStyle(skill.isEnabled ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                Text("\(skill.name)(\(paramString))")
                    .font(.caption).fontDesign(.monospaced)
                    .foregroundStyle(skill.isEnabled ? .gray : .gray.opacity(0.4))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            HStack {
                Text(skill.type.rawValue)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1)).cornerRadius(4)
                    .fixedSize(horizontal: true, vertical: true)
                
                if skill.isLocal {
                    Text("本地")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.indigo.opacity(0.85)).cornerRadius(4)
                        .fixedSize(horizontal: true, vertical: true)
                        .help("此技能由本地物理文件夹驱动")
                }
                
                if skill.entryPoint == "SKILL.md (Instruction Only)" {
                    Text("Markdown代理")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.green.opacity(0.85)).cornerRadius(4)
                        .fixedSize(horizontal: true, vertical: true)
                }
                
                if skill.category == "进化" {
                    let scoreColor: Color = skill.score >= 80 ? .green : (skill.score >= 60 ? .orange : .red)
                    Text("评分: \(skill.score)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(scoreColor)
                        .lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(scoreColor.opacity(0.15))
                        .cornerRadius(4)
                        .fixedSize(horizontal: true, vertical: true)
                        .help("此技能根据每次执行的健康状况进行算分")
                }
            }

            Toggle("", isOn: Binding(
                get: { skill.isEnabled },
                set: { viewModel.toggleSkillStatus(id: skill.id, isEnabled: $0) }
            )).toggleStyle(.switch).controlSize(.small)
            
            Divider().frame(height: 20).padding(.horizontal, 8)
            
            Button("测试") { skillToTest = skill }.buttonStyle(.bordered).disabled(!skill.isEnabled)
            Button("编辑") { viewModel.editingSkill = skill; showEditSheet = true }.buttonStyle(.plain).foregroundStyle(.blue)
            Button("删除") { viewModel.skillToDelete = skill; showDeleteAlert = true }.buttonStyle(.plain).foregroundStyle(.red)
        }
        .padding(.vertical, 8)
    }
}

struct SkillEditView: View {
    @Bindable var viewModel: SkillManager
    @State var skill: AgentSkill
    var isNew: Bool
    var onSave: (AgentSkill) -> Void
    var onCancel: () -> Void
    
    @State private var hoveredParamId: UUID? = nil
    @State private var isMarkdownMode: Bool = false
    @State private var showTestSheet = false
    
    init(viewModel: SkillManager, skill: AgentSkill, isNew: Bool, onSave: @escaping (AgentSkill) -> Void, onCancel: @escaping () -> Void) {
        self.viewModel = viewModel
        self._skill = State(initialValue: skill)
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
        self._isMarkdownMode = State(initialValue: skill.entryPoint == "SKILL.md (Instruction Only)")
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isNew ? "构建新技能" : "配置 Agent 技能").font(.system(size: 16, weight: .bold))
                    Text(isNew ? "定义一个大模型可调用的新工具" : "修改 [\(skill.name)] 的底层执行逻辑").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: exportCurrentToClipboard) {
                    Label("导出到剪贴板", systemImage: "square.and.arrow.up.on.square").font(.system(size: 12, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .background(Color.green.opacity(0.1))
                .foregroundColor(.green)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.green.opacity(0.3), lineWidth: 1))
                
                Button(action: parseClipboardJSON) {
                    Label("从剪贴板解析", systemImage: "doc.on.clipboard").font(.system(size: 12, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .background(Color.blue.opacity(0.1))
                .foregroundColor(.blue)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.blue.opacity(0.3), lineWidth: 1))
                
                Image(systemName: "cube.transparent.fill").font(.system(size: 24)).foregroundStyle(.blue.gradient).padding(.leading, 12)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.8))
            
            ModernDivider(style: .fade(0.18))
            
            Picker("", selection: $isMarkdownMode) {
                Text("💻 标准执行模式 (脚本代码/CLI/MCP)").tag(false)
                Text("📄 纯代理模式 (仅提供 SKILL.md)").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 16) {
                            LeftAlignedRow("唯一标识") {
                                TextField("如 get_weather_data", text: $skill.name).textFieldStyle(.roundedBorder).fontDesign(.monospaced)
                            }
                            LeftAlignedRow("展示名称") {
                                HStack(spacing: 12) {
                                    TextField("如 获取实时天气", text: $skill.displayName).textFieldStyle(.roundedBorder)
                                    Text("分类").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                                    Picker("", selection: $skill.category) {
                                        ForEach(ConfigManager.shared.app.generalConfig.aCategories, id: \.self) { cat in Text(cat).tag(cat) }
                                    }.frame(width: 100)
                                }
                            }
                            LeftAlignedRow("功能描述", alignment: .top) {
                                TextEditor(text: $skill.description).frame(height: 50).font(.system(size: 13)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor), lineWidth: 1))
                            }
                        }.padding(12)
                    } label: { Text("基础属性").font(.headline).foregroundStyle(.primary) }.groupBoxStyle(SkillFrostedGroupBoxStyle())
                    
                    if isMarkdownMode {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("只需书写指令与要求，不涉及具体脚本语言，适合纯系统命令代理：").font(.caption).foregroundColor(.secondary)
                                MacCodeEditor(text: $skill.detailedInstruction, language: .builtin).frame(minHeight: 300).background(Color(NSColor.textBackgroundColor)).cornerRadius(6).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor), lineWidth: 1))
                            }.padding(12)
                        } label: { Text("系统指令定义 (Markdown)").font(.headline).foregroundStyle(.primary) }
                    } else {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("技能使用手册 (SKILL.md)").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                                Text("供大模型阅读的补充指令，如边界条件、依赖环境或异常处理方案 (支持 Markdown)。").font(.caption).foregroundStyle(.secondary)
                                MacCodeEditor(text: $skill.detailedInstruction, language: .builtin)
                                    .frame(minHeight: 120).background(Color(NSColor.textBackgroundColor)).cornerRadius(6).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor), lineWidth: 1))
                            }.padding(12)
                        } label: { Text("说明文档").font(.headline).foregroundStyle(.primary) }
                        
                        GroupBox {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("参数定义").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                                    Spacer()
                                    Button {
                                        withAnimation(.spring()) {
                                            skill.parameters.append(SkillParameter(name: "", type: .string, description: "", isRequired: true))
                                        }
                                    } label: {
                                        Label("新增参数", systemImage: "plus.circle.fill").font(.system(size: 12))
                                    }.buttonStyle(.plain).foregroundStyle(.blue)
                                }
                                if skill.parameters.isEmpty {
                                    Text("此技能无需入参 (或通过 raw_args 透传)").font(.system(size: 12)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 16).background(RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(.separator))
                                } else {
                                    VStack(spacing: 8) {
                                        ForEach($skill.parameters) { $param in
                                            HStack(spacing: 12) {
                                                TextField("键名", text: $param.name).textFieldStyle(.roundedBorder).fontDesign(.monospaced).frame(width: 130)
                                                Picker("", selection: $param.type) { ForEach(ParameterType.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 90)
                                                TextField("AI 提示描述", text: $param.description).textFieldStyle(.roundedBorder)
                                                Toggle("必填", isOn: $param.isRequired).toggleStyle(.checkbox).controlSize(.small)
                                                Button(role: .destructive) { withAnimation { skill.parameters.removeAll { $0.id == param.id } } } label: { Image(systemName: "minus.circle.fill").foregroundStyle(hoveredParamId == param.id ? .red : .gray.opacity(0.3)) }.buttonStyle(.plain).onHover { isHovered in hoveredParamId = isHovered ? param.id : nil }
                                            }
                                        }
                                    }
                                }
                            }.padding(12)
                        } label: { Text("参数矩阵").font(.headline).foregroundStyle(.primary) }
                        
                        GroupBox {
                            VStack(alignment: .leading, spacing: 16) {
                                LeftAlignedRow("执行引擎") {
                                    Picker("", selection: $skill.type) {
                                        ForEach(SkillType.allCases, id: \.self) { type in Text(type.rawValue).tag(type) }
                                    }.labelsHidden().pickerStyle(.menu).frame(width: 200)
                                }
                                
                                if skill.type == .mcp {
                                    LeftAlignedRow("挂载节点") {
                                        Picker("", selection: $skill.executionBody) {
                                            Text("请选择底层 MCP 物理节点...").tag("")
                                            ForEach(viewModel.mcpServers) { server in
                                                Text("🟢 \(server.name)").tag(server.id.uuidString)
                                            }
                                        }.labelsHidden().pickerStyle(.menu).frame(width: 200)
                                    }
                                    
                                    LeftAlignedRow("调用方法") {
                                        TextField("对应 MCP Tool Name (如 fetch)", text: Binding(get: { skill.entryPoint ?? "" }, set: { skill.entryPoint = $0 }))
                                            .textFieldStyle(.roundedBorder)
                                            .fontDesign(.monospaced)
                                            .frame(width: 200)
                                    }
                                    Text("💡 大模型下发的参数矩阵将自动封装为 JSON-RPC 载荷打入上述节点的 Method 中。").font(.system(size: 11)).foregroundColor(.purple)
                                    
                                } else if skill.type == .cli {
                                    LeftAlignedRow("挂载变量") { TextField("例如: cli_output (留空则不挂载到上下文)", text: $skill.outputKey).textFieldStyle(.roundedBorder).fontDesign(.monospaced) }
                                    LeftAlignedRow("安全防护") { Toggle("执行前需经过人类确认 (HITL)", isOn: $skill.requiresConfirmation).toggleStyle(.switch).tint(.orange) }
                                    LeftAlignedRow("命令行程序") {
                                        TextField("可执行程序路径或系统命令 (如 e10-cli, ffmpeg, ripgrep, git)", text: $skill.executionBody)
                                            .textFieldStyle(.roundedBorder)
                                            .fontDesign(.monospaced)
                                    }
                                    Text("💡 系统通过登录态 PATH 动态解析定位该命令，参数自动映射为 argv 并支持实时非阻塞流式捕获。")
                                        .font(.system(size: 11)).foregroundColor(.teal).padding(.leading, 87)
                                } else {
                                    LeftAlignedRow("挂载变量") { TextField("例如: weather_result (留空则不挂载到上下文)", text: $skill.outputKey).textFieldStyle(.roundedBorder).fontDesign(.monospaced) }
                                    LeftAlignedRow("安全防护") { Toggle("执行前需经过人类确认 (HITL)", isOn: $skill.requiresConfirmation).toggleStyle(.switch).tint(.orange) }
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("代码实现 (支持环境变量注入)").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                                        MacCodeEditor(text: $skill.executionBody, language: skill.type).frame(minHeight: 140).background(Color(NSColor.textBackgroundColor)).cornerRadius(6).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor), lineWidth: 1))
                                        Text("💡 通过 args 字典或环境变量接收参数，详情参阅手册。").font(.system(size: 10)).foregroundColor(.blue)
                                    }
                                }
                            }.padding(12)
                        } label: { Text("执行层配置").font(.headline).foregroundStyle(.primary) }
                        
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack { Text("前端展示 UI 配置 (可选)").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary); Spacer(); Text("支持 Markdown 与动态变量").font(.caption).foregroundColor(.blue) }
                                Text("留空则默认显示 JSON 代码块。可使用 {{args.键名}} 提取入参，使用 {{output.键名}} 提取返回值，使用 {{content}} 引用 AI 的原始对话回复。").font(.system(size: 10)).foregroundStyle(.secondary)
                                MacCodeEditor(text: $skill.uiTemplate, language: .builtin).frame(minHeight: 100).background(Color(NSColor.textBackgroundColor)).cornerRadius(6).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor), lineWidth: 1))
                            }.padding(12)
                        } label: { Text("呈现层配置").font(.headline).foregroundStyle(.primary) }
                    }
                }.padding(20)
            }
            .scrollContentBackground(.hidden)
            .background(.ultraThinMaterial)
            .forceOverlayScrollbars()
            
            Divider()
            
            HStack {
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(action: { showTestSheet = true }) {
                    Label("测试当前配置", systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isMarkdownMode ? skill.detailedInstruction.isEmpty : skill.executionBody.isEmpty)
                
                Button("保存配置") {
                    if isMarkdownMode {
                        skill.entryPoint = "SKILL.md (Instruction Only)"
                        skill.type = .shell
                        skill.executionBody = "if [ -n \"$ARG_RAW_COMMAND\" ]; then eval \"$ARG_RAW_COMMAND\"; else exit 1; fi"
                        if !skill.parameters.contains(where: { $0.name == "raw_command" }) {
                            skill.parameters = [SkillParameter(name: "raw_command", type: .string, description: "必传，严格根据 SKILL.md 返回要执行的 JSON 结构参数", isRequired: false)]
                        }
                    }
                    onSave(skill)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    skill.name.isEmpty ||
                    (isMarkdownMode ? skill.detailedInstruction.isEmpty : skill.executionBody.isEmpty) ||
                    (skill.type == .mcp && (skill.entryPoint ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                )
            }
            .padding(20)
            .background(.thinMaterial)
        }
        .frame(width: 740, height: 760)
        .sheet(isPresented: $showTestSheet) {
            SkillTestRunView(skill: skill) { args in
                viewModel.testSkill(skill, customArgs: args)
                showTestSheet = false
            } onCancel: { showTestSheet = false }
        }
    }
    
    private func parseClipboardJSON() {
        guard let jsonString = NSPasteboard.general.string(forType: .string),
              let data = jsonString.data(using: .utf8) else {
            Util.message("剪贴板中没有有效的文本内容")
            return
        }
        
        do {
            let decoder = JSONDecoder()
            if let decodedSkill = try? decoder.decode(AgentSkill.self, from: data) {
                withAnimation { self.skill = decodedSkill }
                Util.message("✅ 成功导入完整技能结构")
                return
            }
            
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let functionDict = dict["function"] as? [String: Any] ?? dict
            
            let parsedName = functionDict["name"] as? String ?? ""
            let parsedDisplayName = functionDict["displayName"] as? String ?? ""
            let parsedDesc = functionDict["description"] as? String ?? ""
            var parsedParams: [SkillParameter] = []
            
            if let paramsArray = functionDict["parameters"] as? [[String: Any]] {
                let paramsData = try JSONSerialization.data(withJSONObject: paramsArray)
                if let decodedParams = try? decoder.decode([SkillParameter].self, from: paramsData) {
                    parsedParams = decodedParams
                }
            } else if let paramsDict = functionDict["parameters"] as? [String: Any],
                      let properties = paramsDict["properties"] as? [String: Any] {
                let requiredKeys = paramsDict["required"] as? [String] ?? []
                for (key, propValue) in properties {
                    if let propDict = propValue as? [String: Any] {
                        let typeStr = propDict["type"] as? String ?? "string"
                        let propDesc = propDict["description"] as? String ?? ""
                        let isReq = requiredKeys.contains(key)
                        
                        var pType: ParameterType = .string
                        switch typeStr.lowercased() {
                        case "integer", "number": pType = .number
                        case "boolean": pType = .boolean
                        case "array": pType = .array
                        case "object": pType = .object
                        default:
                            if propDict["enum"] != nil { pType = .enum } else { pType = .string }
                        }
                        parsedParams.append(SkillParameter(name: key, type: pType, description: propDesc, isRequired: isReq))
                    }
                }
            }
            
            if !parsedName.isEmpty {
                withAnimation {
                    self.skill.name = parsedName
                    if self.skill.displayName.isEmpty || self.skill.displayName == "新工具" { self.skill.displayName = parsedDisplayName }
                    self.skill.description = parsedDesc
                    self.skill.parameters = parsedParams
                    
                    let typeRaw = (dict["type"] as? String) ?? (functionDict["type"] as? String) ?? ""
                    let lowerType = typeRaw.lowercased()
                    if lowerType.contains("python") { self.skill.type = .python }
                    else if lowerType.contains("applescript") { self.skill.type = .applescript }
                    else if lowerType.contains("api") { self.skill.type = .api; self.skill.isLocal = false }
                    else if lowerType.contains("mcp") { self.skill.type = .mcp; self.skill.isLocal = false }
                    else if lowerType.contains("cli") { self.skill.type = .cli }
                    else { self.skill.type = .shell }
                    
                    if let execBody = (dict["executionBody"] as? String) ?? (functionDict["executionBody"] as? String) {
                        self.skill.executionBody = execBody
                    }
                    
                    if let entryPoint = (dict["entryPoint"] as? String) ?? (functionDict["entryPoint"] as? String) {
                        self.skill.entryPoint = entryPoint
                    }
                    
                    if let outKey = (dict["outputKey"] as? String) ?? (functionDict["outputKey"] as? String) { self.skill.outputKey = outKey }
                    if let reqConfirm = (dict["requiresConfirmation"] as? Bool) ?? (functionDict["requiresConfirmation"] as? Bool) { self.skill.requiresConfirmation = reqConfirm }
                    if let cat = (dict["category"] as? String) ?? (functionDict["category"] as? String) { self.skill.category = cat }
                }
                Util.message("✅ 成功解析并导入剪贴板技能配置")
            }
        } catch {
            Util.message("❌ 解析失败：JSON 格式不合法")
        }
    }
    
    private func exportCurrentToClipboard() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var draftSkill = self.skill
            if isMarkdownMode {
                draftSkill.entryPoint = "SKILL.md (Instruction Only)"
                draftSkill.type = .shell
                draftSkill.executionBody = "if [ -n \"$ARG_RAW_COMMAND\" ]; then eval \"$ARG_RAW_COMMAND\"; else exit 1; fi"
                if !draftSkill.parameters.contains(where: { $0.name == "raw_command" }) {
                    draftSkill.parameters = [SkillParameter(name: "raw_command", type: .string, description: "必传，严格根据 SKILL.md 返回要执行的 JSON 结构参数", isRequired: false)]
                }
            }
            let data = try encoder.encode(draftSkill)
            if let jsonString = String(data: data, encoding: .utf8) {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(jsonString, forType: .string)
                Util.message("✅ 当前编辑的技能配置已复制到剪贴板")
            }
        } catch {
            Util.message("❌ 导出失败：\(error.localizedDescription)")
        }
    }
}

struct SkillTestRunView: View {
    let skill: AgentSkill
    let onRun: ([String: Any]) -> Void
    let onCancel: () -> Void
    
    @State private var argValues: [String: String] = [:]
    @State private var jsonErrorMsg: String? = nil
    
    init(skill: AgentSkill, onRun: @escaping ([String: Any]) -> Void, onCancel: @escaping () -> Void) {
        self.skill = skill
        self.onRun = onRun
        self.onCancel = onCancel
        var initialValues: [String: String] = [:]
        for param in skill.parameters { initialValues[param.name] = "" }
        _argValues = State(initialValue: initialValues)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("测试运行：\(skill.displayName)").font(.system(size: 16, weight: .bold))
                    Text("请输入执行该技能所需的真实参数 (支持 JSON 格式验证)").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "play.terminal.fill").font(.system(size: 24)).foregroundStyle(.green.gradient).padding(.leading, 12)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.8))
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if skill.parameters.isEmpty {
                        Text("该技能无需传入任何参数，可直接运行。")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 30)
                    } else {
                        if let error = jsonErrorMsg {
                            Text(error)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.red)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.red.opacity(0.1))
                                .cornerRadius(6)
                        }
                        
                        ForEach(skill.parameters) { param in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(param.name).font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    if param.isRequired { Text("*").foregroundColor(.red) }
                                    Spacer()
                                    Text(param.type.rawValue).font(.system(size: 10)).foregroundColor(isJsonType(param.type) ? .purple : .secondary)
                                }
                                
                                if isJsonType(param.type) {
                                    TextEditor(text: Binding(get: { argValues[param.name] ?? "" }, set: { argValues[param.name] = $0 }))
                                        .font(.system(size: 12, design: .monospaced))
                                        .frame(minHeight: 80, maxHeight: 200)
                                        .padding(4)
                                        .background(Color(NSColor.textBackgroundColor))
                                        .cornerRadius(6)
                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor), lineWidth: 1))
                                } else {
                                    TextField(param.description.isEmpty ? "输入该参数的值..." : param.description, text: Binding(get: { argValues[param.name] ?? "" }, set: { argValues[param.name] = $0 }))
                                        .textFieldStyle(.roundedBorder)
                                }
                            }
                        }
                    }
                }.padding(20)
            }
            .background(Color(NSColor.controlBackgroundColor))
            .forceOverlayScrollbars()
            
            Divider()
            
            HStack {
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("确认执行") {
                    if let args = parseAndValidateArgs() {
                        jsonErrorMsg = nil
                        SkillSessionCache.shared.saveRecentArgs(for: skill.name, args: args)
                        onRun(args)
                    }
                }
                .buttonStyle(.borderedProminent).tint(.green).keyboardShortcut(.defaultAction)
            }
            .padding(20)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 500, height: skill.parameters.isEmpty ? 220 : min(CGFloat(220 + skill.parameters.count * 100), 650))
        .onAppear {
            if let memory = SkillSessionCache.shared.getRecentArgs(for: skill.name) {
                for param in skill.parameters {
                    if let val = memory[param.name] {
                        if isJsonType(param.type), let jsonData = try? JSONSerialization.data(withJSONObject: val, options: .prettyPrinted), let jsonStr = String(data: jsonData, encoding: .utf8) {
                            argValues[param.name] = jsonStr
                        } else {
                            argValues[param.name] = "\(val)"
                        }
                    }
                }
            }
        }
    }
    
    private func isJsonType(_ type: ParameterType) -> Bool {
        return type == .object || type == .array
    }
    
    private func parseAndValidateArgs() -> [String: Any]? {
        var finalArgs: [String: Any] = [:]
        for param in skill.parameters {
            let val = argValues[param.name] ?? ""
            if val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if param.isRequired { jsonErrorMsg = "❌ 必填参数 [\(param.name)] 不能为空"; return nil }
                continue
            }
            
            if param.type == .number, let num = Double(val) {
                finalArgs[param.name] = num
            } else if param.type == .boolean {
                finalArgs[param.name] = (val.lowercased() == "true" || val == "1")
            } else if param.type == .object {
                guard let data = val.data(using: .utf8), let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    jsonErrorMsg = "❌ 参数 [\(param.name)] 的 JSON (Object) 格式不合法，请检查拼写与引号。"
                    return nil
                }
                finalArgs[param.name] = dict
            } else if param.type == .array {
                guard let data = val.data(using: .utf8), let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
                    jsonErrorMsg = "❌ 参数 [\(param.name)] 的 JSON (Array) 格式不合法。"
                    return nil
                }
                finalArgs[param.name] = arr
            } else {
                finalArgs[param.name] = val
            }
        }
        return finalArgs
    }
}

// MARK: - MCP 管理控制台视图群

@MainActor
public struct MCPManagementPanel: View {
    @Bindable var viewModel: SkillManager
    @State private var showEditSheet = false
    @State private var showDeleteAlert = false
    
    public init(viewModel: SkillManager) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            topBarView
            ModernDivider(style: .fade(0.18))
            contentListView
        }
        .background(Color.clear)
        .alert("确认移除 MCP 节点？", isPresented: $showDeleteAlert, presenting: viewModel.mcpToDelete) { server in
            Button("断开并移除", role: .destructive) { withAnimation { viewModel.deleteMCP(server) } }
            Button("取消", role: .cancel) { }
        } message: { server in
            Text("将彻底删除「\(server.name)」配置。其提供的所有依赖工具链将失效。")
        }
        .sheet(isPresented: $showEditSheet) {
            if let mcp = viewModel.editingMCP {
                MCPEditView(
                    mcp: mcp,
                    isNew: !viewModel.mcpServers.contains(where: { $0.id == mcp.id }),
                    onSave: { updatedMCP in
                        if let idx = viewModel.mcpServers.firstIndex(where: { $0.id == updatedMCP.id }) {
                            viewModel.mcpServers[idx] = updatedMCP
                        } else {
                            viewModel.mcpServers.append(updatedMCP)
                        }
                        viewModel.saveMCPServers()
                        viewModel.toggleMCPStatus(id: updatedMCP.id, isEnabled: updatedMCP.isEnabled)
                        showEditSheet = false
                    },
                    onCancel: { showEditSheet = false }
                )
            }
        }
        .onAppear {
            viewModel.loadMCPServers()
        }
    }
    
    @ViewBuilder
    private var topBarView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("MCP 协议网络").font(.headline)
                Text("动态挂载遵循 Model Context Protocol 的进程与服务端，直接赋能大模型").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { viewModel.loadMCPServers() }; Util.message("✅ 连接池状态已重载") }) {
                Label("重载网络池", systemImage: "arrow.triangle.2.circlepath").font(.system(size: 13, weight: .medium))
            }
            
            Button {
                viewModel.editingMCP = MCPServer(name: "新建 MCP 节点", transport: .stdio)
                showEditSheet = true
            } label: {
                Label("接入新节点", systemImage: "plus")
            }.buttonStyle(.borderedProminent).tint(.purple)
        }
        .padding().background(.thinMaterial)
    }
    
    @ViewBuilder
    private var contentListView: some View {
        ScrollView {
            if viewModel.mcpServers.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "network.badge.shield.half.filled").font(.system(size: 48)).foregroundStyle(.tertiary)
                    Text("当前系统未接管任何外部 MCP 网络").font(.title3).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.top, 120)
            } else {
                LazyVStack(spacing: 16) {
                    ForEach(viewModel.mcpServers) { server in
                        MCPRowView(
                            server: server,
                            viewModel: viewModel,
                            showEditSheet: $showEditSheet,
                            showDeleteAlert: $showDeleteAlert
                        )
                    }
                }
                .padding(20)
            }
        }
        .scrollContentBackground(.hidden)
        .background(.ultraThinMaterial)
        .forceOverlayScrollbars()
    }
}

@MainActor
struct MCPRowView: View {
    let server: MCPServer
    let viewModel: SkillManager
    @Binding var showEditSheet: Bool
    @Binding var showDeleteAlert: Bool
    
    @State private var isSniffing = false
    @State private var sniffResultMsg: String? = nil
    
    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(server.isEnabled ? AnyShapeStyle(Color.purple.opacity(0.15)) : AnyShapeStyle(Color(NSColor.controlBackgroundColor)))
                    .frame(width: 44, height: 44)
                
                Image(systemName: server.transport == .stdio ? "terminal.fill" : "server.rack")
                    .foregroundStyle(server.isEnabled ? AnyShapeStyle(Color.purple.gradient) : AnyShapeStyle(Color.gray.opacity(0.5)))
                    .font(.system(size: 20))
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text(server.name)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(server.isEnabled ? .primary : .secondary)
                    .lineLimit(1)
                
                HStack(spacing: 6) {
                    Text(server.transport.rawValue)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    
                    Circle().fill(statusColor(server.status)).frame(width: 6, height: 6)
                        .modifier(PulseEffect(isActive: server.status == "连接中..."))
                    
                    Text(server.status)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(statusColor(server.status))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            HStack(spacing: 16) {
                if server.transport == .stdio {
                    let displayCmd = (server.command?.isEmpty == false) ? server.command! : "未配置"
                    Text(displayCmd)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(displayCmd == "未配置" ? .red : .secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color(NSColor.textBackgroundColor).opacity(0.5))
                        .cornerRadius(6)
                }
                
                Toggle("", isOn: Binding(
                    get: { server.isEnabled },
                    set: { viewModel.toggleMCPStatus(id: server.id, isEnabled: $0) }
                )).toggleStyle(.switch).controlSize(.regular).tint(.purple)
                
                Divider().frame(height: 24).opacity(0.5)
                
                Button {
                    guard server.status == "已连接" else { return }
                    isSniffing = true
                    Task {
                        do {
                            let count = try await viewModel.sniffAndRegisterMCPTools(server: server)
                            withAnimation {
                                sniffResultMsg = count > 0 ? "已装配 \(count) 个新工具" : "工具库已是最新"
                            }
                        } catch {
                            withAnimation { sniffResultMsg = "嗅探失败" }
                        }
                        isSniffing = false
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        withAnimation { sniffResultMsg = nil }
                    }
                } label: {
                    HStack(spacing: 4) {
                        if isSniffing {
                            ProgressView().controlSize(.small).scaleEffect(0.7)
                        } else {
                            Image(systemName: "wand.and.stars")
                        }
                        if let msg = sniffResultMsg { Text(msg) }
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(server.status == "已连接" ? .purple : .gray.opacity(0.4))
                .disabled(server.status != "已连接" || isSniffing)
                
                Button("编辑") { viewModel.editingMCP = server; showEditSheet = true }.buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(.blue)
                Button("移除") { viewModel.mcpToDelete = server; showDeleteAlert = true }.buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
    }
    
    private func statusColor(_ status: String) -> Color {
        if status.contains("已连接") { return .green }
        if status.contains("中") { return .orange }
        if status.contains("失败") { return .red }
        return .gray
    }
}

struct PulseEffect: ViewModifier {
    let isActive: Bool
    @State private var scale: CGFloat = 1.0
    
    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .opacity(scale > 1.2 ? 0.3 : 1.0)
            .onChange(of: isActive) { _, active in
                if active {
                    withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { scale = 1.4 }
                } else {
                    withAnimation { scale = 1.0 }
                }
            }
            .onAppear {
                if isActive { withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { scale = 1.4 } }
            }
    }
}

@MainActor
struct MCPEditView: View {
    @State var mcp: MCPServer
    var isNew: Bool
    var onSave: (MCPServer) -> Void
    var onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isNew ? "新建 MCP 协议节点" : "配置 MCP 协议参数").font(.system(size: 16, weight: .bold))
                    Text("挂载可执行程序或 SSE 接口，充当 Agent 的外部动态技能分发器").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "network.badge.shield.half.filled").font(.system(size: 24)).foregroundStyle(.purple.gradient).padding(.leading, 12)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.8))
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 16) {
                            LeftAlignedRow("服务名称") { TextField("如 GitHub, FileSystem", text: $mcp.name).textFieldStyle(.roundedBorder) }
                            
                            LeftAlignedRow("连接类型") {
                                Picker("", selection: $mcp.transport) {
                                    ForEach(MCPTransportType.allCases, id: \.self) { type in Text(type.rawValue).tag(type) }
                                }.pickerStyle(.segmented).labelsHidden()
                            }
                            
                            if mcp.transport == .stdio {
                                LeftAlignedRow("调度主命令") {
                                    TextField("可执行文件/包管理器，如 npx, uvx, python3", text: Binding(get: { mcp.command ?? "" }, set: { mcp.command = $0 }))
                                        .textFieldStyle(.roundedBorder)
                                        .fontDesign(.monospaced)
                                }
                                LeftAlignedRow("执行后缀参数") {
                                    TextField("完整参数链，如 -y @modelcontextprotocol/server-postgres", text: Binding(get: { mcp.args ?? "" }, set: { mcp.args = $0 }))
                                        .textFieldStyle(.roundedBorder)
                                        .fontDesign(.monospaced)
                                }
                                Text("💡 核心提示：系统会在后台开启静默子进程以唤起该命令。请确保你的操作系统中已全局安装环境 (如 Node.js)。")
                                    .font(.system(size: 11)).foregroundColor(.purple).padding(.leading, 87)
                            } else {
                                LeftAlignedRow("端点 URL") {
                                    TextField("Server-Sent Events 寻址，如 http://localhost:8080/sse", text: Binding(get: { mcp.url ?? "" }, set: { mcp.url = $0 }))
                                        .textFieldStyle(.roundedBorder)
                                        .fontDesign(.monospaced)
                                }
                                Text("💡 核心提示：确保安全组允许出站网络连接。")
                                    .font(.system(size: 11)).foregroundColor(.purple).padding(.leading, 87)
                            }
                            
                            LeftAlignedRow("自启状态") {
                                Toggle("立即连接并暴露节点工具链", isOn: $mcp.isEnabled).toggleStyle(.switch).controlSize(.small).tint(.purple)
                            }
                            
                        }.padding(12)
                    } label: { Text("节点寻址属性").font(.headline).foregroundStyle(.primary) }
                    .groupBoxStyle(SkillFrostedGroupBoxStyle())
                    
                }.padding(20)
            }
            .scrollContentBackground(.hidden)
            .background(.ultraThinMaterial)
            .forceOverlayScrollbars()
            
            Divider()
            
            HStack {
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("固化并握手连接") { onSave(mcp) }.buttonStyle(.borderedProminent).tint(.purple).controlSize(.large).keyboardShortcut(.defaultAction).disabled(mcp.name.isEmpty)
            }
            .padding(20)
            .background(.thinMaterial)
        }
        .frame(width: 600, height: 480)
    }
}
