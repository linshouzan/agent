//////////////////////////////////////////////////////////////////
// 文件名：SkillManager.swift
// 文件说明：适用于 macOS 14+ 的 Skill 与 MCP (Model Context Protocol) 引擎管理
// 代码要求：保证逻辑与完整性，保留所有注释与交互组件
// 核心架构：
// 1. MCP 协议支持与动态技能包架构: 支持本地 MCP 服务与 manifest.json 热拔插挂载[cite: 1]
// 2. 状态记忆与多步技能链 (Stateful Pipeline): 支持上下文变量挂载传递[cite: 1]
// 3. 现代化安全执行引擎: 分离 Shell、AppleScript、Python、API、MCP 与 CLI 原生工具[cite: 1]
// 4. CLI 运行时环境自适应发现 (EnvironmentResolver) 与非阻塞实时流式捕获[cite: 1]
// 5. 动态分类与 Markdown 智能构建: 支持系统/自定义/进化分类，支持纯 SKILL.md 模式[cite: 1]
// 6. 物理级上下文隔离与 Touch ID 硬件安全拦截机制[cite: 1]
//////////////////////////////////////////////////////////////////

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine
import Foundation

// MARK: - ==================== 0. 终端环境自适应解析与进程底座 ====================

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
            proc.arguments = ["-l", "-i", "-c", "echo -n \"$PATH\""]
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            
            do {
                try proc.run()
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                proc.waitUntilExit()
                return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            } catch {
                return ""
            }
        }.value
    }
    
    /// 构建兜底垫片搜索路径拓扑
    private func buildFallbackPATH() -> [String] {
        let fileManager = FileManager.default
        var candidatePaths = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            NSString(string: "~/.cargo/bin").expandingTildeInPath,
            NSString(string: "~/.local/bin").expandingTildeInPath,
            NSString(string: "~/.local/share/mise/shims").expandingTildeInPath,
            NSString(string: "~/.asdf/shims").expandingTildeInPath,
            NSString(string: "~/.fnm/current/bin").expandingTildeInPath
        ]
        
        // 自动探测 nvm 全局版本目录
        let nvmRoot = NSString(string: "~/.nvm/versions/node").expandingTildeInPath
        if let nodeVersions = try? fileManager.contentsOfDirectory(atPath: nvmRoot) {
            for v in nodeVersions.sorted().reversed() {
                candidatePaths.append("\(nvmRoot)/\(v)/bin")
            }
        }
        
        // 自动探测 pyenv 目录
        let pyenvShims = NSString(string: "~/.pyenv/shims").expandingTildeInPath
        if fileManager.fileExists(atPath: pyenvShims) { candidatePaths.append(pyenvShims) }
        
        return candidatePaths
    }
    
    private func mergePATHs(probed: String, fallback: [String]) -> String {
        var seen = Set<String>()
        var result: [String] = []
        
        let probedComponents = probed.split(separator: ":").map(String.init)
        for p in probedComponents where !p.isEmpty {
            if !seen.contains(p) { seen.insert(p); result.append(p) }
        }
        for p in fallback where !p.isEmpty {
            if !seen.contains(p) { seen.insert(p); result.append(p) }
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

// MARK: - ==================== 1. 核心数据模型 ====================

enum SkillType: String, CaseIterable, Codable {
    case api = "REST API"
    case shell = "Shell 脚本 (Zsh)"
    case cli = "CLI 命令行工具"
    case applescript = "AppleScript (自动化)"
    case python = "Python 脚本"
    case builtin = "系统原生方法"
    case mcp = "MCP 动态代理"
}

enum ParameterType: String, CaseIterable, Codable {
    case string = "String"
    case number = "Number"
    case boolean = "Boolean"
    case array = "Array"
    case `enum` = "Enum"
    case object = "Object"
}

struct SkillParameter: Identifiable, Hashable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var type: ParameterType
    var description: String
    var isRequired: Bool
    
    init(id: UUID = UUID(), name: String, type: ParameterType, description: String, isRequired: Bool) {
        self.id = id
        self.name = name
        self.type = type
        self.description = description
        self.isRequired = isRequired
    }
    
    enum CodingKeys: String, CodingKey {
        case id, name, type, description, isRequired
    }
    
    init(from decoder: Decoder) throws {
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

struct AgentSkill: Identifiable, Hashable, Codable, Equatable {
    var id = UUID()
    var name: String
    var displayName: String
    var description: String
    var detailedInstruction: String = ""
    var type: SkillType
    var parameters: [SkillParameter]
    var executionBody: String
    var isEnabled: Bool = true
    var requiresConfirmation: Bool = false
    var outputKey: String = ""
    var isLocal: Bool = false
    var workingDirectory: String? = nil
    var entryPoint: String? = nil
    var createdAt: Date = Date()
    var category: String = "自定义"
    var score: Int = 100
    var uiTemplate: String = ""
    
    enum CodingKeys: String, CodingKey {
        case id, name, displayName, description, detailedInstruction, type, parameters, executionBody, isEnabled, requiresConfirmation, outputKey, isLocal, workingDirectory, entryPoint, createdAt, category, score, uiTemplate
    }
    
    init(id: UUID = UUID(), name: String, displayName: String, description: String, detailedInstruction: String = "", type: SkillType, parameters: [SkillParameter], executionBody: String, isEnabled: Bool = true, requiresConfirmation: Bool = false, outputKey: String = "", isLocal: Bool = false, workingDirectory: String? = nil, entryPoint: String? = nil, createdAt: Date = Date(), category: String = "自定义", score: Int = 100, uiTemplate: String = "") {
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
    
    init(from decoder: Decoder) throws {
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

// MARK: - MCP (Model Context Protocol) 模型
public enum MCPTransportType: String, Codable, CaseIterable, Sendable {
    case stdio = "Standard I/O (本地进程)"
    case sse = "SSE (HTTP 长连接)"
}

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

// MARK: - ==================== 2. 内置技能 (Builtin Skills) ====================

func Skill_Evolve() -> AgentSkill {
    return AgentSkill(
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

func Skill_ReadManual(skillsBasePath: String) -> AgentSkill {
    return AgentSkill(
        name: "read_skill_manual",
        displayName: "📚 阅读技能手册",
        description: "获取工具的使用说明。在调用任何本地工具前，若不确定其 raw_command 参数格式或详细指令，必须先调用此工具阅读说明书。",
        detailedInstruction: "",
        type: .builtin,
        parameters: [
            SkillParameter(name: "target_skill_name", type: .string, description: "需要查询的工具名称(name)", isRequired: true)
        ],
        executionBody: "builtin_read_manual",
        isEnabled: true,
        requiresConfirmation: false,
        outputKey: "manual_content",
        isLocal: false,
        workingDirectory: skillsBasePath,
        entryPoint: "",
        category: "系统"
    )
}

func Skill_MemoryManager() -> AgentSkill {
    return AgentSkill(
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

func Skill_TaskPlanner() -> AgentSkill {
    return AgentSkill(
        name: "task_planner",
        displayName: "📋 动态任务黑板",
        description: """
        【核心底层能力】多步任务的规划引擎。
        - 主智能体：接到复杂任务时，使用 'create' 创建主计划，只有黑板上存在任务 ID 时，你才被允许向子智能体指派具体任务。
        - 子智能体：当收到任务需要进一步拆解时，使用 'append_sub' 在当前任务节点下追加子任务。
        - 任务执行完毕后，使用 'update_status' 更新状态，并务必通过 'result_memo' 记录关键产出或提取的数据，以便排在后面的任务能够直接读取并使用。
        """,
        detailedInstruction: "",
        type: .builtin,
        parameters: [
            SkillParameter(name: "action", type: .string, description: "必填: 'create'(新建), 'append_sub'(追加子任务), 'update_status'(更新状态) 或 'clear'(清空)", isRequired: true),
            SkillParameter(name: "target_task_id", type: .string, description: "当 action 为 append_sub 或 update_status 时必填，代表目标节点 ID", isRequired: false),
            SkillParameter(name: "status", type: .string, description: "当 action 为 update_status 时必填，填: '成功', '失败', '执行中' 等", isRequired: false),
            SkillParameter(name: "result_memo", type: .string, description: "任务完成后的产出结果简述或关键数据提取，供后续任务直接使用 (update_status 强烈建议填写)", isRequired: false),
            SkillParameter(name: "tasks", type: .array, description: "任务列表。请传入一个数组，数组中每个对象包含三个字段：'id'(字符串，自增数字),'text'(任务描述),'status'(填'等待中')。", isRequired: false),
            SkillParameter(name: "memo", type: .string, description: "记录全局关键数据的备忘录", isRequired: false)
        ],
        executionBody: "builtin_planner",
        isEnabled: true,
        requiresConfirmation: false,
        category: "系统"
    )
}

func Skill_CallAgent() -> AgentSkill {
    return AgentSkill(
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

func Skill_Finish() -> AgentSkill {
    return AgentSkill(
        name: "finish_task",
        displayName: "✅ 提交最终结果",
        description: "多步任务黑板的所有规划步骤已全部完成时调用此工具，用于正式提交交付物并归档结单。",
        detailedInstruction: "传入 final_answer 完成任务归档；日常问答可直接输出自然语言答复。",
        type: .builtin,
        parameters: [
            SkillParameter(name: "final_answer", type: .string, description: "交付给用户的最终回答或总结报告（支持 Markdown）", isRequired: true),
            SkillParameter(name: "status", type: .string, description: "任务状态：'success' 或 'failed'", isRequired: true)
        ],
        executionBody: "builtin_finish",
        isEnabled: true,
        requiresConfirmation: false,
        isLocal: false,
        category: "系统"
    )
}

func Skill_KnowledgeSearch() -> AgentSkill {
    return AgentSkill(
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

// MARK: - 呼叫数字分身进行角色扮演与对戏
func Skill_CallPersona(boundPersonas: [DigitalPersona] = []) -> AgentSkill {
    // 1. 若外部未显式传入指定分身（如 loadSkills 默认装载），则兜底读取全部已注册分身
    let targetPersonas = boundPersonas.isEmpty ? [] : boundPersonas
    
    // 2. 格式化分身名单与人设概要
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
            SkillParameter(
                name: "persona_name",
                type: .string,
                description: paramDesc,
                isRequired: true
            ),
            SkillParameter(
                name: "dialogue_input",
                type: .string,
                description: "向该分身表达的对白、互动指令或提问",
                isRequired: true
            ),
            SkillParameter(
                name: "scene_context",
                type: .string,
                description: "可选：当前场景舞台设定、空间氛围或需要分身知晓的临时情境",
                isRequired: false
            )
        ],
        executionBody: "builtin_call_persona",
        isEnabled: true,
        requiresConfirmation: false,
        category: "系统"
    )
}

// MARK: - 🛡️ 升级版：Touch ID 指纹鉴权系统的安全拦截 UI (Swift 6 Mode)
class SystemAuthUI {
    enum DangerLevel {
        case low, medium, high
        
        var color: Color {
            switch self { case .low: return .blue; case .medium: return .orange; case .high: return .red }
        }
        var icon: String {
            switch self { case .low: return "info.circle.fill"; case .medium: return "exclamationmark.triangle.fill"; case .high: return "touchid" }
        }
    }
    
    @MainActor
    static func requestUserPermission(title: String, message: String, dangerLevel: DangerLevel) async -> Bool {
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

struct TouchIDAuthOverlayView: View {
    let title: String
    let message: String
    let level: SystemAuthUI.DangerLevel
    let onResult: (Bool) -> Void
    
    @State private var isAuthenticating = false
    @State private var timeRemaining = 30
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
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

// MARK: - 支持 Touch ID 与 Agent 人工在环指引的交互中枢
actor UserInteractionManager {
    static let shared = UserInteractionManager()
    private var continuations: [String: CheckedContinuation<Bool, Never>] = [:]
    private var guidanceContinuations: [String: CheckedContinuation<String?, Never>] = [:]

    // 1. 权限授权通道 (Touch ID / HITL 按钮)
    func requestPermission(id: String) async -> Bool {
        return await withCheckedContinuation { continuation in
            continuations[id] = continuation
        }
    }

    func resolvePermission(id: String, allow: Bool) {
        if let continuation = continuations.removeValue(forKey: id) {
            continuation.resume(returning: allow)
        }
    }

    // 2. 人工在环指引与挂起恢复通道 (Pause-and-Resume)
    func requestHumanGuidance(id: String) async -> String? {
        return await withCheckedContinuation { continuation in
            guidanceContinuations[id] = continuation
        }
    }

    func resolveHumanGuidance(id: String, guidance: String?) {
        if let continuation = guidanceContinuations.removeValue(forKey: id) {
            continuation.resume(returning: guidance)
        }
    }
}

// MARK: - ==================== 3. 动态技能包扫描引擎 (MCP-Like 混合兼容版) ====================

struct SkillPackageManifest: Codable {
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
    
    struct SkillPackageParameter: Codable {
        let name: String
        let type: String
        let description: String
        let isRequired: Bool
    }
}

struct LocalSkillScanner {
    static func scanAndMount() -> [AgentSkill] {
        var scannedItems: [(skill: AgentSkill, order: Int)] = []
        let fileManager = FileManager.default
        
        guard let skillsPath = ConfigManager.shared.skillsPath,
              let subDirs = try? fileManager.contentsOfDirectory(at: skillsPath, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey], options: .skipsHiddenFiles) else {
            print("⚠️ [SkillScanner] 找不到 skills 目录或目录为空")
            return []
        }
        
        // 1. 构建全量拓扑搜索路径 (彻底规避 macOS GUI 进程的精简 PATH 遮蔽问题)
        let comprehensivePaths = buildComprehensiveSearchPaths()
        
        for dir in subDirs {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            
            let fileAttributes = try? fileManager.attributesOfItem(atPath: dir.path)
            let folderCreationDate = fileAttributes?[.creationDate] as? Date ?? Date()
            
            let defaultSkillName = dir.lastPathComponent
            let manifestURL = dir.appendingPathComponent("manifest.json")
            
            // ==========================================
            // 策略 A: 标准 manifest.json 模式
            // ==========================================
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
            
            // ==========================================
            // 策略 B: 智能自适应模式 (无配置无感接入)
            // ==========================================
            let skillMdURL = dir.appendingPathComponent("SKILL.md")
            let scriptsDir = dir.appendingPathComponent("scripts")
            let fullMarkdown = (try? String(contentsOf: skillMdURL, encoding: .utf8)) ?? ""
            let lines = fullMarkdown.components(separatedBy: .newlines)
            
            var parsedName = defaultSkillName
            var parsedDescription = ""
            var parsedCategory = "自定义"
            var parsedOrder = 9999
            var explicitTypeStr: String? = nil
            
            // 1. 解析 SKILL.md YAML Frontmatter
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
            
            // 2. 自动检测技能类型（层级探测 + 默认 Shell 兜底）
            let (detectedType, entryPoint, executionBody) = detectSkillTypeAndBody(
                dirURL: dir,
                scriptsDirURL: scriptsDir,
                markdown: fullMarkdown,
                explicitTypeStr: explicitTypeStr,
                skillName: parsedName,
                systemPaths: comprehensivePaths
            )
            
            // 3. 构建参数矩阵
            var parameters: [SkillParameter] = []
            if detectedType == .cli {
                parameters = [
                    SkillParameter(
                        name: "raw_args",
                        type: .string,
                        description: "传递给命令行程序的子命令及完整参数字符串，例如: 'build' 或 '--help'",
                        isRequired: false
                    )
                ]
            } else {
                parameters = [
                    SkillParameter(
                        name: "raw_command",
                        type: .string,
                        description: "【核心传参通道】按照 SKILL.md 说明传入具体执行指令。",
                        isRequired: false
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
        var mountedSkills = scannedItems.map { $0.skill }
        
        if let skillsBasePath = ConfigManager.shared.skillsPath?.path {
            mountedSkills.insert(Skill_ReadManual(skillsBasePath: skillsBasePath), at: 0)
        }
        return mountedSkills
    }
    
    // MARK: - 内部自适应类型探测逻辑
    private static func detectSkillTypeAndBody(
        dirURL: URL,
        scriptsDirURL: URL,
        markdown: String,
        explicitTypeStr: String?,
        skillName: String,
        systemPaths: [String]
    ) -> (type: SkillType, entryPoint: String, executionBody: String) {
        let fileManager = FileManager.default
        
        // 1. Frontmatter 显式声明判定
        if let explicit = explicitTypeStr, !explicit.isEmpty {
            let mapped = mapTypeString(explicit)
            let (ep, body) = extractBodyForType(type: mapped, dirURL: dirURL, scriptsDirURL: scriptsDirURL, markdown: markdown, defaultName: skillName)
            return (mapped, ep, body)
        }
        
        // 2. 检查 scripts/ 目录及根目录下的脚本物理文件
        var candidates: [URL] = []
        if let rootFiles = try? fileManager.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil) {
            candidates.append(contentsOf: rootFiles)
        }
        if fileManager.fileExists(atPath: scriptsDirURL.path),
           let scriptFiles = try? fileManager.contentsOfDirectory(at: scriptsDirURL, includingPropertiesForKeys: nil) {
            candidates.append(contentsOf: scriptFiles)
        }
        
        // 探测 Python 脚本
        if let pyFile = candidates.first(where: { $0.pathExtension.lowercased() == "py" }) {
            let body = (try? String(contentsOf: pyFile, encoding: .utf8)) ?? ""
            let relPath = pyFile.path.replacingOccurrences(of: dirURL.path + "/", with: "")
            return (.python, relPath, body)
        }
        
        // 探测 AppleScript 脚本
        if let scptFile = candidates.first(where: { ["scpt", "applescript"].contains($0.pathExtension.lowercased()) }) {
            let body = (try? String(contentsOf: scptFile, encoding: .utf8)) ?? ""
            let relPath = scptFile.path.replacingOccurrences(of: dirURL.path + "/", with: "")
            return (.applescript, relPath, body)
        }
        
        // 探测 Shell 脚本文件
        if let shFile = candidates.first(where: { ["sh", "bash", "zsh"].contains($0.pathExtension.lowercased()) }) {
            let body = (try? String(contentsOf: shFile, encoding: .utf8)) ?? ""
            let relPath = shFile.path.replacingOccurrences(of: dirURL.path + "/", with: "")
            return (.shell, relPath, body)
        }
        
        // 3. 智能探测 CLI 工具 (结合命令变体与 SKILL.md 关键字嗅探)
        var potentialCommands: Set<String> = [
            skillName,
            skillName.replacingOccurrences(of: "^skill[-_]", with: "", options: .regularExpression),
            skillName.replacingOccurrences(of: "_", with: "-"),
            dirURL.lastPathComponent.replacingOccurrences(of: "^skill[-_]", with: "", options: .regularExpression)
        ]
        
        // 从 SKILL.md 提取可能的首选 CLI 命令 (如 `e10-cli ` 或 ````bash\ne10-cli ...````)
        let cliRegex = try? NSRegularExpression(pattern: #"`([a-zA-Z0-9_-]+(?:-cli)?)\s+[^`]*`"#)
        if let regex = cliRegex {
            let matches = regex.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown))
            for m in matches.prefix(5) {
                if let r = Range(m.range(at: 1), in: markdown) {
                    potentialCommands.insert(String(markdown[r]))
                }
            }
        }
        
        for cmd in potentialCommands where !cmd.isEmpty {
            for searchPath in systemPaths {
                let binaryPath = (searchPath as NSString).appendingPathComponent(cmd)
                if fileManager.isExecutableFile(atPath: binaryPath) {
                    return (.cli, cmd, cmd)
                }
            }
        }
        
        // 4. 解析 Markdown 代码块内嵌语言
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
        
        // 5. 无法识别时默认回退为 Shell
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
    
    // 构建全量开发环境路径拓扑集合
    private static func buildComprehensiveSearchPaths() -> [String] {
        let fileManager = FileManager.default
        var seen = Set<String>()
        var paths: [String] = []
        
        func appendPath(_ p: String) {
            let expanded = NSString(string: p).expandingTildeInPath
            if !seen.contains(expanded) && fileManager.fileExists(atPath: expanded) {
                seen.insert(expanded)
                paths.append(expanded)
            }
        }
        
        // 1. 系统现有环境变量
        if let currentPath = ProcessInfo.processInfo.environment["PATH"] {
            for p in currentPath.split(separator: ":").map(String.init) {
                appendPath(p)
            }
        }
        
        // 2. macOS 常见全局软件包安装路径
        let commonPaths = [
            "/usr/local/bin",
            "/usr/local/sbin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "~/.cargo/bin",
            "~/.local/bin",
            "~/.local/share/mise/shims",
            "~/.asdf/shims",
            "~/.fnm/current/bin",
            "~/.pyenv/shims"
        ]
        for p in commonPaths { appendPath(p) }
        
        // 3. 动态枚举所有 NVM 版本 bin 目录
        let nvmBase = NSString(string: "~/.nvm/versions/node").expandingTildeInPath
        if let versions = try? fileManager.contentsOfDirectory(atPath: nvmBase) {
            for v in versions.sorted().reversed() {
                appendPath("\(nvmBase)/\(v)/bin")
            }
        }
        
        return paths
    }
    
    private static func extractBodyForType(
        type: SkillType,
        dirURL: URL,
        scriptsDirURL: URL,
        markdown: String,
        defaultName: String
    ) -> (entryPoint: String, executionBody: String) {
        let cleanCmd = defaultName.replacingOccurrences(of: "^skill[-_]", with: "", options: .regularExpression)
        if type == .cli {
            return (cleanCmd, cleanCmd)
        }
        return ("SKILL.md (Auto)", markdown)
    }
    
    private static func mapTypeString(_ typeStr: String) -> SkillType {
        let lower = typeStr.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.contains("python") { return .python }
        if lower.contains("applescript") || lower.contains("osascript") { return .applescript }
        if lower.contains("api") || lower.contains("http") || lower.contains("rest") { return .api }
        if lower.contains("cli") || lower.contains("command") || lower.contains("binary") { return .cli }
        if lower.contains("mcp") { return .mcp }
        return .shell
    }
    
    // 确保扫描本地技能时，使用技能名称生成永久不变的确定性 ID
    static func makeDeterministicID(for skillName: String) -> UUID {
        return UUID.deterministic(from: "skill_local_\(skillName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())")
    }
}

struct SecurityScanner {
    static func isSafe(command: String) -> Bool {
        let lowerCmd = command.lowercased()
        let blackList = ["rm -rf /", "rm -rf ~", "mkfs", "dd if=", "> /dev/disk", "chmod -r 777", "chown -r", "crontab -r", "history -c", ":(){ :|:& };:"]
        for word in blackList { if lowerCmd.contains(word) { print("🛑 [安全拦截] 触发黑名单关键词: \(word)"); return false } }
        let dangerPathsPattern = "(rm|mv|cp|chmod|chown)\\s+.*(/etc|/var|/System|/Library|/usr|/bin|/sbin)"
        if let regex = try? NSRegularExpression(pattern: dangerPathsPattern, options: .caseInsensitive) { let range = NSRange(location: 0, length: command.utf16.count); if regex.firstMatch(in: command, options: [], range: range) != nil { print("🛑 [安全拦截] 触发系统级敏感目录保护正则"); return false } }
        let powerPattern = "^\\s*(sudo\\s+)?(shutdown|reboot|halt)\\b"
        if let powerRegex = try? NSRegularExpression(pattern: powerPattern, options: .caseInsensitive) { let range = NSRange(location: 0, length: command.utf16.count); if powerRegex.firstMatch(in: command, options: [], range: range) != nil { print("🛑 [安全拦截] 触发电源管理保护正则"); return false } }
        return true
    }
}

// MARK: - 技能目录独立监听器
private final class SkillDirectoryMonitor: @unchecked Sendable {
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

// MARK: - ==================== 4. 技能与 MCP 管理引擎 (SkillManager) ====================

@Observable
@MainActor
public class SkillManager {
    
    var skills: [AgentSkill] = []
    var sharedContext: [String: String] = [:]
    
    var editingSkill: AgentSkill?
    var skillToDelete: AgentSkill?
    
    // MCP 运行状态池
    var mcpServers: [MCPServer] = []
    var editingMCP: MCPServer?
    var mcpToDelete: MCPServer?
    
    private var directoryMonitor: SkillDirectoryMonitor?
    
    init() {
        loadSkills()
        loadMCPServers()
    }
    
    // MARK: - 启动本地技能文件夹变动监听
    private func startMonitoringSkillsFolder() {
        guard let skillsURL = ConfigManager.shared.skillsPath else { return }
        directoryMonitor?.stop()
        directoryMonitor = SkillDirectoryMonitor(directoryURL: skillsURL) { [weak self] in
            Task { @MainActor [weak self] in
                self?.loadSkills()
            }
        }
    }
    
    // MARK: - MCP 底座网络配置
    func loadMCPServers() {
        if let data = try? Data(contentsOf: ConfigManager.shared.mcpFileName!),
           let decoded = try? JSONDecoder().decode([MCPServer].self, from: data) {
            self.mcpServers = decoded
        } else {
            self.mcpServers = []
        }
    }
    
    func saveMCPServers() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(self.mcpServers)
            try data.write(to: ConfigManager.shared.mcpFileName!, options: .atomic)
        } catch {
            print("⚠️ [SkillManager] 保存 mcp.json 失败: \(error)")
        }
    }
    
    func toggleMCPStatus(id: UUID, isEnabled: Bool) {
        if let idx = mcpServers.firstIndex(where: { $0.id == id }) {
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
    }
    
    func deleteMCP(_ server: MCPServer) {
        mcpServers.removeAll { $0.id == server.id }
        saveMCPServers()
        syncMCPToolsToMemory()
    }
    
    // MARK: - 魔法嗅探：一键提取并自动注册 MCP 协议内省工具
    @MainActor
    func sniffAndRegisterMCPTools(server: MCPServer) async throws -> Int {
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
    
    // MARK: - 🚀 现代安全执行引擎核心 (带评分熔断机制与统一调度)
    func executeTool(skill: AgentSkill, args: [String: Any], skipConfirmation: Bool = false) async -> String {
        var flatArgs = args
        if let cmdArgsStr = args["raw_command"] as? String,
           let data = cmdArgsStr.data(using: .utf8),
           let jsonDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in jsonDict { flatArgs[k] = v }
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
        
        // 1. 获取底层引擎执行结果
        var executionResult: String = ""
        switch skill.type {
        case .cli:
            executionResult = await executeCLI(
                executableTarget: skill.executionBody.trimmingCharacters(in: .whitespacesAndNewlines),
                args: flatArgs,
                sharedContext: self.sharedContext,
                workingDirectory: skill.workingDirectory,
                skillParameters: skill.parameters
            )
        case .shell:
            executionResult = await executeSecureShell(scriptSource: skill.executionBody, args: flatArgs, sharedContext: self.sharedContext, workingDirectory: skill.workingDirectory, entryPoint: skill.entryPoint)
        case .applescript:
            executionResult = await executeAppleScript(scriptSource: skill.executionBody, args: flatArgs, sharedContext: self.sharedContext, workingDirectory: skill.workingDirectory, entryPoint: skill.entryPoint)
        case .python:
            executionResult = await executePython(scriptSource: skill.executionBody, args: flatArgs, sharedContext: self.sharedContext, workingDirectory: skill.workingDirectory, entryPoint: skill.entryPoint)
        case .api:
            executionResult = await executeAdvancedAPI(apiSource: skill.executionBody, args: flatArgs, sharedContext: self.sharedContext)
        case .mcp:
            executionResult = await executeMCPProxy(serverId: skill.executionBody, method: skill.entryPoint ?? "", args: flatArgs)
        case .builtin:
            if skill.executionBody == "builtin_evolve" { executionResult = await executeEvolveSkill(args: flatArgs) }
            else if skill.executionBody == "builtin_memory" {
                let action = flatArgs["action"] as? String ?? ""
                let content = flatArgs["content"] as? String ?? ""
                
                if action == "save" {
                    let cat = flatArgs["category"] as? String ?? "项目环境"
                    let imp = flatArgs["importance"] as? Int ?? 5
                    executionResult = await MemoryManager.shared.addMemory(content: content, category: cat, importance: imp)
                } else if action == "search" {
                    let searchRes = await MemoryManager.shared.searchContext(for: content, topK: 3)
                    if searchRes.isEmpty {
                        executionResult = "当前记忆库中未找到关于「\(content)」的强关联线索。"
                    } else {
                        executionResult = searchRes
                    }
                } else {
                    executionResult = "❌ 未知的 action，必须为 save 或 search"
                }
            }
            else if skill.executionBody == "builtin_finish" {
                return "[AGENT_PIPELINE_TERMINATE]:\((flatArgs["final_answer"] as? String) ?? "结束")"
            }
            else if skill.executionBody == "builtin_planner" {
                let action = flatArgs["action"] as? String ?? ""
                
                if let memo = flatArgs["memo"] as? String, !memo.trimmingCharacters(in: .whitespaces).isEmpty {
                    self.sharedContext["AGENT_GLOBAL_MEMO"] = (self.sharedContext["AGENT_GLOBAL_MEMO"] ?? "") + "\n- " + memo
                }
                
                switch action {
                case "create", "replan":
                    // 🌟 核心升级：调用弹性清洗引擎，自动兼容任意多态入参并补齐缺损字段
                    guard let sanitizedPlan = TaskBlackboardManager.shared.sanitizeAndEncodeTasks(from: flatArgs["tasks"]) else {
                        return "【任务初始化指引】: 请提供任务步骤描述以挂载黑板，格式如 tasks: [{\"text\": \"第一步...\"}]"
                    }
                    
                    self.sharedContext["AGENT_BLACKBOARD_PLAN"] = sanitizedPlan
                    let currentPlanSummary = TaskBlackboardManager.shared.generateExecutionPrompt(planString: sanitizedPlan)
                    
                    return """
                    ✅ 任务规划已成功挂载黑板！
                    \(currentPlanSummary)
                    【下一步指导】：请直接调用目标物理工具推进【等待中】的活动节点。
                    """
                
                case "append_sub":
                    guard let targetId = flatArgs["target_task_id"] as? String else {
                        return "【追加子任务提示】: 请提供 target_task_id 以指定目标父节点 ID。"
                    }
                    
                    guard let subPlanString = TaskBlackboardManager.shared.sanitizeAndEncodeTasks(from: flatArgs["tasks"]) else {
                        return "【追加子任务提示】: 请在 tasks 中提供子步骤描述。"
                    }
                    
                    let newSubtasks = TaskBlackboardManager.shared.parsePlan(subPlanString)
                    let currentPlan = self.sharedContext["AGENT_BLACKBOARD_PLAN"]
                    
                    if let updatedPlan = TaskBlackboardManager.shared.appendSubtasks(planString: currentPlan, parentTaskId: targetId, newSubtasks: newSubtasks) {
                        self.sharedContext["AGENT_BLACKBOARD_PLAN"] = updatedPlan
                        let currentPlanSummary = TaskBlackboardManager.shared.generateExecutionPrompt(planString: updatedPlan)
                        return """
                        ✅ 子任务已成功挂载到节点 [\(targetId)] 下！
                        \(currentPlanSummary)
                        【下一步指导】：请直接下发指令执行第一个子任务。
                        """
                    } else {
                        return "【节点未找到】: 在黑板中未检索到 ID 为 [\(targetId)] 的节点，请核对后重试。"
                    }
                
                case "update_status":
                    guard let targetId = flatArgs["target_task_id"] as? String else {
                        return "❌ 更新状态失败：必须提供 target_task_id。"
                    }
                    
                    let rawStatus = (flatArgs["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "成功"
                    let normalizedStatus: String
                    if ["成功", "success", "完成", "已完成", "done", "completed"].contains(rawStatus) {
                        normalizedStatus = "成功"
                    } else if ["执行中", "running", "in_progress", "executing"].contains(rawStatus) {
                        normalizedStatus = "执行中"
                    } else if ["失败", "failed", "error"].contains(rawStatus) {
                        normalizedStatus = "失败"
                    } else {
                        normalizedStatus = (flatArgs["status"] as? String) ?? "成功"
                    }
                    
                    let resultMemo = flatArgs["result_memo"] as? String
                    
                    var parsedArtifacts: [AgentArtifact]? = nil
                    if let rawArray = flatArgs["artifacts"] as? [Any] {
                        var list: [AgentArtifact] = []
                        for item in rawArray {
                            if let art = item as? AgentArtifact {
                                list.append(art)
                            } else if let str = item as? String, !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                list.append(AgentArtifact(name: str, type: .text, content: str))
                            } else if let dict = item as? [String: Any],
                                      let data = try? JSONSerialization.data(withJSONObject: dict),
                                      let decoded = try? JSONDecoder().decode(AgentArtifact.self, from: data) {
                                list.append(decoded)
                            }
                        }
                        if !list.isEmpty { parsedArtifacts = list }
                    } else if let jsonStr = flatArgs["artifacts"] as? String,
                              let data = jsonStr.data(using: .utf8) {
                        if let decodedArts = try? JSONDecoder().decode([AgentArtifact].self, from: data) {
                            parsedArtifacts = decodedArts
                        } else if let decodedStrs = try? JSONDecoder().decode([String].self, from: data) {
                            parsedArtifacts = decodedStrs.map { AgentArtifact(name: $0, type: .text, content: $0) }
                        }
                    }
                    
                    let currentPlan = self.sharedContext["AGENT_BLACKBOARD_PLAN"]
                    let hasContextError = (self.sharedContext["LAST_TOOL_HAS_ERROR"] == "true")
                    
                    if let updatedPlan = TaskBlackboardManager.shared.updateTaskStatus(
                        planString: currentPlan,
                        taskId: targetId,
                        newStatusStr: normalizedStatus,
                        resultMemo: resultMemo,
                        artifacts: parsedArtifacts,
                        hasPhysicalError: hasContextError
                    ) {
                        self.sharedContext["AGENT_BLACKBOARD_PLAN"] = updatedPlan
                        let currentPlanSummary = TaskBlackboardManager.shared.generateExecutionPrompt(planString: updatedPlan)
                        return """
                        ✅ 任务 [\(targetId)] 状态已更新为 [\(normalizedStatus)]！
                        \(currentPlanSummary)
                        【下一步指导】：请继续推进下一个【等待中】的任务。
                        """
                    } else {
                        return "❌ 更新失败：在黑板中找不到 ID 为 [\(targetId)] 的任务节点。"
                    }
                    
                case "clear":
                    self.sharedContext.removeValue(forKey: "AGENT_BLACKBOARD_PLAN")
                    return "✅ 任务黑板已清空。"
                    
                default:
                    return "❌ 未知的 action 操作: \(action)"
                }
            } else if skill.executionBody == "builtin_read_manual" {
                let rawTarget = (flatArgs["target_skill_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if rawTarget.isEmpty {
                    return "❌ 参数错误：请传入有效的 target_skill_name"
                }
                
                // 1. 生成所有可能的命名变体 (剥离/补充 skill- 前缀，兼容中划线与下划线)
                let baseName = rawTarget.lowercased()
                    .replacingOccurrences(of: "^skill[-_]", with: "", options: .regularExpression)
                
                var candidateNames: Set<String> = [
                    rawTarget,
                    baseName,
                    "skill-\(baseName)",
                    "skill_\(baseName)",
                    baseName.replacingOccurrences(of: "_", with: "-"),
                    baseName.replacingOccurrences(of: "-", with: "_"),
                    "skill-\(baseName.replacingOccurrences(of: "_", with: "-"))",
                    "skill_\(baseName.replacingOccurrences(of: "-", with: "_"))"
                ]
                
                let skillsBasePath = skill.workingDirectory ?? ConfigManager.shared.skillsPath?.path ?? ""
                let fileManager = FileManager.default
                var fileContent: String? = nil
                
                // 2. 物理路径直接探测
                for name in candidateNames {
                    let docPath = "\(skillsBasePath)/\(name)/SKILL.md"
                    if fileManager.fileExists(atPath: docPath),
                       let content = try? String(contentsOfFile: docPath, encoding: .utf8),
                       !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        fileContent = content
                        break
                    }
                }
                
                // 3. 物理目录遍历兜底探测 (扫描各子文件夹 SKILL.md Frontmatter)
                if fileContent == nil, let subDirs = try? fileManager.contentsOfDirectory(atPath: skillsBasePath) {
                    for dir in subDirs {
                        let candidateFile = "\(skillsBasePath)/\(dir)/SKILL.md"
                        if fileManager.fileExists(atPath: candidateFile),
                           let content = try? String(contentsOfFile: candidateFile, encoding: .utf8) {
                            let lowerContent = content.lowercased()
                            if candidateNames.contains(dir.lowercased()) ||
                               candidateNames.contains(where: { lowerContent.contains("name: \($0)") }) {
                                fileContent = content
                                break
                            }
                        }
                    }
                }
                
                // 4. 交付解析内容或正向引导 (无负面词汇，避免模型反复试探假工具)
                if let content = fileContent {
                    executionResult = content
                } else {
                    // 归一化内存比对
                    let matchedSkill = self.skills.first(where: { s in
                        let sBase = s.name.lowercased().replacingOccurrences(of: "^skill[-_]", with: "", options: .regularExpression)
                        return candidateNames.contains(s.name.lowercased()) ||
                               candidateNames.contains(s.displayName.lowercased()) ||
                               sBase == baseName
                    })
                    
                    if let matched = matchedSkill {
                        let instruction = matched.detailedInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !instruction.isEmpty {
                            executionResult = instruction
                        } else {
                            let paramList = matched.parameters.map { "\($0.name)(\($0.type.rawValue))" }.joined(separator: ", ")
                            executionResult = """
                            【工具: \(matched.displayName)】
                            - 唯一标识: \(matched.name)
                            - 核心功能: \(matched.description)
                            - 参数定义: [\(paramList)]
                            💡 该工具已在当前环境装载就绪，请直接通过原生 Tool Call 接口传入参数执行。
                            """
                        }
                    } else {
                        executionResult = "💡 未检索到 [\(rawTarget)] 的独立文档。请直接根据当前已启用的工具列表下发 Tool Call 执行任务。"
                    }
                }
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
                    let currentModel = currentAgent?.baseModel ?? "gemini-2.0-flash"
                    
                    let knowledgeVM = KnowledgeViewModel()
                    let ragResult = await knowledgeVM.injectedRag(query: searchQuery, category: searchCategory, currentModel: currentModel)
                    
                    if ragResult.context.isEmpty {
                        executionResult = "⚠️ 在分类 [\(searchCategory.isEmpty ? "全局" : searchCategory)] 中未找到与「\(searchQuery)」相关的有效切片。"
                    } else {
                        executionResult = ragResult.context
                    }
                }
            } else {
                executionResult = "系统原生方法暂未对接具体的路由"
            }
        }
        
        // 2. 进化技能动态评分与熔断机制
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

    // MARK: - 🚀 [Optimized] CLI 原生命令行执行引擎 (非阻塞实时流式捕获 + 真实 PATH 寻址)
    private func executeCLI(
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
            
            // 1. 结合动态环境解析二进制物理路径
            guard let executableURL = await Self.resolveExecutableURL(target: executableTarget, workingDir: workDirURL) else {
                return "❌ CLI 执行失败：找不到可执行命令或二进制文件 [\(executableTarget)]。请确认已在宿主环境中安装并在终端 PATH 内配置。"
            }
            process.executableURL = executableURL
            
            // 2. 组装参数矩阵
            let finalArguments = await Self.buildCLIArguments(args: args, skillParameters: skillParameters)
            process.arguments = finalArguments
            
            // 3. 构造完整终端环境变量
            let processEnv = await EnvironmentResolver.shared.buildProcessEnvironment(
                sharedContext: sharedContext,
                args: args
            )
            process.environment = processEnv
            process.standardOutput = outPipe
            process.standardError = errPipe
            
            // 4. 非阻塞流式线程安全聚合器
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
                        try? await Task.sleep(nanoseconds: 60_000_000_000) // 60 秒超时
                        if process.isRunning { process.terminate() }
                    }
                    
                    process.waitUntilExit()
                    timeoutTask.cancel()
                    
                    outHandle.readabilityHandler = nil
                    errHandle.readabilityHandler = nil
                    
                    // 读取可能残留在缓冲区的尾部数据
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
    
    // MARK: - [Added] 辅助工具：CLI 二进制物理寻址 (结合动态 PATH)
    private static func resolveExecutableURL(target: String, workingDir: URL) async -> URL? {
        let fileManager = FileManager.default
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        
        if trimmed.hasPrefix("/") {
            let url = URL(fileURLWithPath: trimmed)
            if fileManager.isExecutableFile(atPath: url.path) { return url }
        } else if trimmed.hasPrefix("./") {
            let relativeURL = workingDir.appendingPathComponent(String(trimmed.dropFirst(2)))
            if fileManager.isExecutableFile(atPath: relativeURL.path) { return relativeURL }
        }
        
        let localURL = workingDir.appendingPathComponent(trimmed)
        if fileManager.isExecutableFile(atPath: localURL.path) { return localURL }
        
        let fullPathStr = await EnvironmentResolver.shared.getResolvedPATH()
        let searchPaths = fullPathStr.split(separator: ":").map(String.init)
        
        for dir in searchPaths {
            let candidatePath = (dir as NSString).appendingPathComponent(trimmed)
            if fileManager.isExecutableFile(atPath: candidatePath) {
                return URL(fileURLWithPath: candidatePath)
            }
        }
        return nil
    }
    
    // MARK: - [Added] 辅助工具：CLI 参数矩阵智能装配
    private static func buildCLIArguments(args: [String: Any], skillParameters: [SkillParameter]) -> [String] {
        var arguments: [String] = []
        
        if let rawArgsList = args["raw_args"] as? [String] {
            return rawArgsList
        } else if let rawArgsStr = (args["raw_args"] as? String) ?? (args["raw_command"] as? String),
                  !rawArgsStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return splitCommandLine(rawArgsStr)
        }
        
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
                    if param.name.lowercased() == "subcommand" || param.name.lowercased() == "action" {
                        arguments.append(strVal)
                    } else {
                        arguments.append("--\(flagKey)")
                        arguments.append(strVal)
                    }
                }
            }
        }
        return arguments
    }
    
    // MARK: - [Added] 辅助工具：POSIX 命令行切分器
    private static func splitCommandLine(_ command: String) -> [String] {
        var args: [String] = []
        var current = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var isEscaped = false
        
        for char in command {
            if isEscaped {
                current.append(char)
                isEscaped = false
                continue
            }
            if char == "\\" {
                isEscaped = true
                continue
            }
            if char == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                continue
            }
            if char == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                continue
            }
            if char.isWhitespace && !inSingleQuote && !inDoubleQuote {
                if !current.isEmpty {
                    args.append(current)
                    current = ""
                }
                continue
            }
            current.append(char)
        }
        if !current.isEmpty { args.append(current) }
        return args
    }

    private func executeEvolveSkill(args: [String: Any]) async -> String {
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

            await MainActor.run {
                self.loadSkills()
                if !isExists {
                    if let newSkill = self.skills.first(where: { $0.name == skillName }) {
                        let activeAgentID = AiChatStore.shared.selectedAgentID
                        if let idx = ConfigManager.shared.app.agentProfiles.firstIndex(where: { $0.id == activeAgentID }) {
                            if !ConfigManager.shared.app.agentProfiles[idx].equippedSkillIDs.contains(newSkill.id) {
                                ConfigManager.shared.app.agentProfiles[idx].equippedSkillIDs.append(newSkill.id)
                                ConfigManager.shared.saveConfig()
                            }
                        }
                    }
                    Util.message("🧬 AI 已自我进化并挂载新技能: \(skillName)")
                } else { Util.message("🔄 AI 已成功对技能 [\(skillName)] 进行局部热更新") }
            }

            if isExists { return "✅ 技能 [\(skillName)] 已成功进行局部更新并热重载。您可以立即运行测试看是否达到预期。如果需要查看原有代码，可以在其本地目录找到隐藏的 .bak 文件。" }
            else { return "✅ 技能 [\(skillName)] 已成功编写、保存并动态挂载至当前智能体分身。请立即调用测试该技能。" }

        } catch { return "❌ 技能进化/更新失败，文件系统发生错误: \(error.localizedDescription)" }
    }
    
    // MARK: - 🚀 统一环境的 Python 执行引擎
    private func executePython(scriptSource: String, args: [String: Any], sharedContext: [String: String], workingDirectory: String?, entryPoint: String?) async -> String {
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
            
            let process = Process(); let pipe = Pipe()
            let venvPython = workDirURL.appendingPathComponent("venv/bin/python3")
            if FileManager.default.fileExists(atPath: venvPython.path) { process.executableURL = venvPython }
            else { process.executableURL = URL(fileURLWithPath: "/usr/bin/python3") }
            
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
                    process.standardOutput = pipe; process.standardError = pipe
                    
                    try process.run()
                    
                    let timeoutTask = Task {
                        try? await Task.sleep(nanoseconds: 45_000_000_000)
                        if process.isRunning { process.terminate() }
                    }
                    
                    let outputData = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                    process.waitUntilExit(); timeoutTask.cancel()
                    
                    try? FileManager.default.removeItem(at: runnerFile)
                    try? FileManager.default.removeItem(at: payloadFile)
                    
                    let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    
                    if process.terminationReason == .uncaughtSignal { return "❌ 超时被强行终止 (Code: \(process.terminationStatus)):\n\(output)" }
                    if process.terminationStatus != 0 { return "⚠️ 脚本异常退出 (Code: \(process.terminationStatus)):\n\(output)" }
                    return output.isEmpty ? "执行成功 (无返回值)" : output
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
    
    // MARK: - 🚀 统一环境的 Shell 执行引擎
    private func executeSecureShell(
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
                    
                    if process.terminationReason == .uncaughtSignal { return "❌ 脚本执行超时或被强制终止 (代码 \(process.terminationStatus)):\n\(output)" }
                    if process.terminationStatus != 0 { return "⚠️ Shell 脚本异常退出 (代码 \(process.terminationStatus)):\n\(output)" }
                    return output.isEmpty ? "执行成功 (无返回值)" : output
                } catch {
                    return "❌ 脚本执行异常: \(error.localizedDescription)"
                }
            } onCancel: {
                if process.isRunning { process.terminate() }
            }
        }.value
    }
    
    private func executeAppleScript(scriptSource: String, args: [String: Any], sharedContext: [String: String], workingDirectory: String?, entryPoint: String?) async -> String {
        return await Task.detached(priority: .userInitiated) {
            if let wd = workingDirectory, !wd.isEmpty, let ep = entryPoint, !ep.isEmpty {
                let execFile = URL(fileURLWithPath: wd).appendingPathComponent(ep)
                try? scriptSource.write(to: execFile, atomically: true, encoding: .utf8)
            }
            
            let process = Process(); let outPipe = Pipe(); let inPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            if let wd = workingDirectory, !wd.isEmpty { process.currentDirectoryURL = URL(fileURLWithPath: wd) }
            
            let secureEnv = await EnvironmentResolver.shared.buildProcessEnvironment(
                sharedContext: sharedContext,
                args: args
            )
            process.environment = secureEnv
            process.standardInput = inPipe; process.standardOutput = outPipe; process.standardError = outPipe
            
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
                    process.waitUntilExit(); timeoutTask.cancel()
                    
                    let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    
                    if process.terminationReason == .uncaughtSignal { return "❌ AppleScript 执行超时被强制终止 (退出码 \(process.terminationStatus)):\n\(output)" }
                    if process.terminationStatus != 0 { return "❌ AppleScript 执行失败 (退出码 \(process.terminationStatus)):\n\(output)" }
                    return output.isEmpty ? "执行成功 (无返回值)" : output
                } catch { return "❌ AppleScript 引擎异常: \(error.localizedDescription)" }
            } onCancel: {
                if process.isRunning { process.terminate() }
            }
        }.value
    }
    
    // MARK: - 企业级 RESTful API 物理执行引擎
    nonisolated private func executeAdvancedAPI(apiSource: String, args: [String: Any], sharedContext: [String: String]) async -> String {
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
    
    // MARK: - 🚀 MCP 物理通信代理引擎
    nonisolated private func executeMCPProxy(serverId: String, method: String, args: [String: Any]) async -> String {
        let serverConfig: MCPServer? = await MainActor.run { return self.mcpServers.first(where: { $0.id.uuidString == serverId }) }
        
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
    
    // MARK: - 数据持久化与管理
    func getActiveSkills(for agentID: UUID? = nil) -> [AgentSkill] {
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
    
    func loadSkills() {
        var localSkills = LocalSkillScanner.scanAndMount()
        var userSkills: [AgentSkill] = []
        
        if let url = ConfigManager.shared.skillsFileName, let data = try? Data(contentsOf: url), !data.isEmpty {
            do { userSkills = try JSONDecoder().decode([AgentSkill].self, from: data) }
            catch { print("⚠️ [SkillManager] skills.json 解析失败，自动重置: \(error)") }
        }
        
        // 1. 同步并固化本地技能 ID
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
        
        // 2. 固化系统内置技能 ID
        var systemSkills = [Skill_Evolve(), Skill_MemoryManager(), Skill_TaskPlanner(), Skill_CallAgent(), Skill_Finish(), Skill_KnowledgeSearch(), Skill_CallPersona()]
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
    
    func saveSkills() {
        guard let url = ConfigManager.shared.skillsFileName else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(self.skills)
            try data.write(to: url, options: .atomic)
        } catch { print("⚠️ [SkillManager] 保存 skills.json 失败: \(error)") }
    }
    
    func syncLocalSkillFiles(skill: inout AgentSkill) -> Bool {
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
                ep = "script.\(ext)"; skill.entryPoint = ep
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
            for p in skill.parameters { parameters.append(["name": p.name, "type": p.type.rawValue, "description": p.description, "isRequired": p.isRequired]) }
            
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
    
    func toggleSkillStatus(id: UUID, isEnabled: Bool) {
        if let index = skills.firstIndex(where: { $0.id == id }) {
            skills[index].isEnabled = isEnabled
            if isEnabled && skills[index].score < 60 { skills[index].score = 100 }
            saveSkills()
        }
    }
    
    func deleteSkill(_ skill: AgentSkill, deleteLocalFiles: Bool) {
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
    
    func testSkill(_ skill: AgentSkill, customArgs: [String: Any]? = nil) {
        if skill.requiresConfirmation {
            let alert = NSAlert(); alert.messageText = "安全拦截 (HITL)"; alert.informativeText = "即将测试执行高危技能「\(skill.displayName)」\n\n这可能会对系统或云端数据造成影响，是否允许执行？"; alert.alertStyle = .critical; alert.addButton(withTitle: "允许执行"); alert.addButton(withTitle: "拒绝")
            if alert.runModal() != .alertFirstButtonReturn { Util.message("已取消高危技能执行"); return }
        }
        var finalArgs: [String: Any] = [:]
        if let custom = customArgs { finalArgs = custom } else { for param in skill.parameters { finalArgs[param.name] = "TestValue_\(param.name)" } }
        Task {
            let executionResult = await executeTool(skill: skill, args: finalArgs)
            await MainActor.run {
                Util.alert(title: skill.type == .api ? "API 调用完成" : (skill.type == .cli ? "CLI 执行完成" : "脚本执行完成"), text: executionResult)
                if !skill.outputKey.isEmpty && !executionResult.contains("❌") { self.sharedContext[skill.outputKey] = executionResult; Util.message("已成功将结果挂载至上下文变量: {\(skill.outputKey)}") }
            }
        }
    }
    
    func importFile(allowedTypes: [UTType], completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = allowedTypes; panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.begin { response in if response == .OK, let url = panel.url { completion(url) } }
    }
    
    func exportFile(defaultName: String, completion: @escaping (URL) -> Void) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = defaultName; panel.allowedContentTypes = [.json]
        panel.begin { response in if response == .OK, let url = panel.url { completion(url) } }
    }
    
    func exportSkills(url: URL) {
        if let encoded = try? JSONEncoder().encode(skills) { try? encoded.write(to: url, options: .atomic); Util.message("技能链已成功导出") }
    }
    
    func importSkills(url: URL) {
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([AgentSkill].self, from: data) {
            self.skills.append(contentsOf: decoded); saveSkills(); Util.message("成功导入 \(decoded.count) 个技能")
        } else { Util.alert(title: "导入失败", text: "无法解析该文件，请确保格式正确。") }
    }
    
    func importOpenAPI(url: URL) {
        guard let data = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let paths = json["paths"] as? [String: Any] else { Util.alert(title: "解析失败", text: "未找到有效的 paths 节点。"); return }
        var baseUrl = "https://api.example.com"
        if let servers = json["servers"] as? [[String: Any]], let firstServer = servers.first, let host = firstServer["url"] as? String { baseUrl = host }
        var importedCount = 0
        for (pathKey, pathValue) in paths {
            guard let methods = pathValue as? [String: Any] else { continue }
            for (methodKey, methodValue) in methods {
                guard let details = methodValue as? [String: Any] else { continue }
                let summary = (details["summary"] as? String) ?? (details["description"] as? String) ?? "自动导入的API"
                let operationId = (details["operationId"] as? String) ?? "\(methodKey)_\(pathKey.replacingOccurrences(of: "/", with: "_"))"
                var parsedParams: [SkillParameter] = []
                if let parameters = details["parameters"] as? [[String: Any]] {
                    for p in parameters {
                        let pName = p["name"] as? String ?? "unknown"; let pDesc = p["description"] as? String ?? ""; let pRequired = p["required"] as? Bool ?? false
                        var pType: ParameterType = .string
                        if let schema = p["schema"] as? [String: Any], let typeStr = schema["type"] as? String {
                            if typeStr == "integer" || typeStr == "number" { pType = .number }
                            if typeStr == "boolean" { pType = .boolean }
                        }
                        parsedParams.append(SkillParameter(name: pName, type: pType, description: pDesc, isRequired: pRequired))
                    }
                }
                let cleanOperationId = operationId.replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
                self.skills.append(AgentSkill(name: cleanOperationId, displayName: summary, description: summary, detailedInstruction: "", type: .api, parameters: parsedParams, executionBody: "\(baseUrl)\(pathKey)", isEnabled: true, requiresConfirmation: methodKey.lowercased() == "delete", outputKey: ""))
                importedCount += 1
            }
        }
        saveSkills(); Util.message("OpenAPI 扫描完成，共动态生成并挂载 \(importedCount) 个新技能。")
    }
    
    func openSkillFolder() {
        if let url = ConfigManager.shared.skillsPath { NSWorkspace.shared.open(url) } else { Util.alert(title: "错误", text: "无法定位本地技能文件夹路径，请检查沙盒权限或配置。") }
    }
    
    func generateTeamManifest(for mainAgent: AgentProfile) -> String {
        let allProfiles = ConfigManager.shared.app.agentProfiles
        let allowedSubAgents = allProfiles.filter { mainAgent.allowedSubAgentIDs.contains($0.id) }
        let allPersonas = PersonaManager.shared.personas
        
        if allowedSubAgents.isEmpty && allPersonas.isEmpty { return "" }
        
        var manifest = """
        
        <delegation_registry>
        <!-- 当前系统已注册的外部协作专家与角色列表，仅供调用委派工具时参考参数使用 -->
        
        """
        
        if !allowedSubAgents.isEmpty {
            manifest += "### 🤖 可委派的专家智能体 (通过 call_sub_agent 唤醒):\n"
            for sub in allowedSubAgents {
                let lines = sub.systemPrompt.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                let safeSummary = lines.first(where: { !$0.isEmpty }) ?? "提供专业的定制化任务处理能力"
                manifest += "- **[\(sub.name)]**: \(safeSummary)\n"
                
                let subSkillNames = sub.equippedSkillIDs.compactMap { skillId in
                    self.skills.first(where: { $0.id == skillId })?.name
                }
                if !subSkillNames.isEmpty {
                    manifest += "  └ 挂载工具: \(subSkillNames.joined(separator: ", "))\n"
                }
            }
            manifest += "\n"
        }
        
        if !allPersonas.isEmpty {
            manifest += "### 🎭 可对戏的数字分身 (通过 call_digital_persona 呼叫):\n"
            for p in allPersonas {
                let state = PersonaManager.shared.getOrCreateRuntimeState(for: p.id)
                let worldDesc = p.worldviewContext.isEmpty ? "现代日常" : p.worldviewContext
                manifest += "- **[\(p.name)]** (\(p.roleTag)): \(p.summary)\n"
                manifest += "  └ 世界观: \(worldDesc) | 口吻: \(p.toneStyle) | 状态: \(state.bondMilestone.rawValue) (羁绊:\(state.affinityScore), 情绪:\(state.currentEmotion))\n"
            }
            manifest += "\n"
        }
        
        manifest += "</delegation_registry>\n"
        return manifest
    }
}

// MARK: - ==================== 5. 视图组件 ====================

struct SkillLeftAlignedRow<Content: View>: View {
    let title: String; let alignment: VerticalAlignment; let content: Content
    init(_ title: String, alignment: VerticalAlignment = .firstTextBaseline, @ViewBuilder content: () -> Content) { self.title = title; self.alignment = alignment; self.content = content() }
    var body: some View { HStack(alignment: alignment, spacing: 12) { Text(title).font(.system(size: 13, weight: .medium)).frame(width: 75, alignment: .leading).foregroundStyle(.secondary); content } }
}

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

struct SkillManagementPanel: View {
    @Bindable var viewModel: SkillManager
    @State private var showEditSheet = false
    @State private var showDeleteAlert = false
    @State private var skillToTest: AgentSkill? = nil
    
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
    
    var body: some View {
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
            VStack(alignment: .leading, spacing: 4) { Text("技能链配置").font(.headline); Text("配置 AI 能够主动调用的系统级或 API 接口能力").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button(action: { viewModel.openSkillFolder() }) { Label("技能目录", systemImage: "folder").font(.system(size: 13, weight: .medium)) }
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { viewModel.loadSkills() }; Util.message("✅ 技能列表已刷新") }) { Label("刷新列表", systemImage: "arrow.clockwise").font(.system(size: 13, weight: .medium)) }
            Menu {
                Button("导入标准 JSON 技能") { viewModel.importFile(allowedTypes: [.json]) { url in viewModel.importSkills(url: url) } }
                Button("扫描 OpenAPI / Swagger") { viewModel.importFile(allowedTypes: [.json]) { url in viewModel.importOpenAPI(url: url) } }
            } label: { Label("导入...", systemImage: "square.and.arrow.down") }
            Button { viewModel.exportFile(defaultName: "skills_export.json") { url in viewModel.exportSkills(url: url) } } label: { Label("导出", systemImage: "square.and.arrow.up") }
            Button {
                viewModel.editingSkill = AgentSkill(name: "new_skill", displayName: "新工具", description: "", detailedInstruction: "", type: .cli, parameters: [], executionBody: "", isEnabled: true, requiresConfirmation: false, outputKey: "", isLocal: true, category: "自定义")
                showEditSheet = true
            } label: { Label("新建技能", systemImage: "plus") }.buttonStyle(.borderedProminent)
        }.padding().background(.thinMaterial)
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
        }.padding(.vertical, 8)
    }
}

struct SkillEditView: View {
    @Bindable var viewModel: SkillManager
    @State var skill: AgentSkill; var isNew: Bool; var onSave: (AgentSkill) -> Void; var onCancel: () -> Void
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
                VStack(alignment: .leading, spacing: 4) { Text(isNew ? "构建新技能" : "配置 Agent 技能").font(.system(size: 16, weight: .bold)); Text(isNew ? "定义一个大模型可调用的新工具" : "修改 [\(skill.name)] 的底层执行逻辑").font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer()
                Button(action: exportCurrentToClipboard) { Label("导出到剪贴板", systemImage: "square.and.arrow.up.on.square").font(.system(size: 12, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 4) }
                    .buttonStyle(.plain).background(Color.green.opacity(0.1)).foregroundColor(.green).cornerRadius(6).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.green.opacity(0.3), lineWidth: 1))
                Button(action: parseClipboardJSON) { Label("从剪贴板解析", systemImage: "doc.on.clipboard").font(.system(size: 12, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 4) }.buttonStyle(.plain).background(Color.blue.opacity(0.1)).foregroundColor(.blue).cornerRadius(6).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.blue.opacity(0.3), lineWidth: 1))
                Image(systemName: "cube.transparent.fill").font(.system(size: 24)).foregroundStyle(.blue.gradient).padding(.leading, 12)
            }.padding(.horizontal, 20).padding(.vertical, 16).background(Color(NSColor.windowBackgroundColor).opacity(0.8))
            
            ModernDivider(style: .fade(0.18))
            
            Picker("", selection: $isMarkdownMode) {
                Text("💻 标准执行模式 (脚本代码/CLI/MCP)").tag(false)
                Text("📄 纯代理模式 (仅提供 SKILL.md)").tag(true)
            }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.vertical, 12)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 16) {
                            SkillLeftAlignedRow("唯一标识") { TextField("如 get_weather_data", text: $skill.name).textFieldStyle(.roundedBorder).fontDesign(.monospaced) }
                            SkillLeftAlignedRow("展示名称") {
                                HStack(spacing: 12) {
                                    TextField("如 获取实时天气", text: $skill.displayName).textFieldStyle(.roundedBorder)
                                    Text("分类").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                                    Picker("", selection: $skill.category) {
                                        ForEach(ConfigManager.shared.app.generalConfig.aCategories, id: \.self) { cat in Text(cat).tag(cat) }
                                    }.frame(width: 100)
                                }
                            }
                            SkillLeftAlignedRow("功能描述", alignment: .top) { TextEditor(text: $skill.description).frame(height: 50).font(.system(size: 13)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor), lineWidth: 1)) }
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
                                HStack { Text("参数定义").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary); Spacer(); Button { withAnimation(.spring()) { skill.parameters.append(SkillParameter(name: "", type: .string, description: "", isRequired: true)) } } label: { Label("新增参数", systemImage: "plus.circle.fill").font(.system(size: 12)) }.buttonStyle(.plain).foregroundStyle(.blue) }
                                if skill.parameters.isEmpty { Text("此技能无需入参 (或通过 raw_args 透传)").font(.system(size: 12)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 16).background(RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(.separator)) } else {
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
                                SkillLeftAlignedRow("执行引擎") {
                                    Picker("", selection: $skill.type) {
                                        ForEach(SkillType.allCases, id: \.self) { type in Text(type.rawValue).tag(type) }
                                    }.labelsHidden().pickerStyle(.menu).frame(width: 200)
                                }
                                
                                if skill.type == .mcp {
                                    SkillLeftAlignedRow("挂载节点") {
                                        Picker("", selection: $skill.executionBody) {
                                            Text("请选择底层 MCP 物理节点...").tag("")
                                            ForEach(viewModel.mcpServers) { server in
                                                Text("🟢 \(server.name)").tag(server.id.uuidString)
                                            }
                                        }.labelsHidden().pickerStyle(.menu).frame(width: 200)
                                    }
                                    
                                    SkillLeftAlignedRow("调用方法") {
                                        TextField("对应 MCP Tool Name (如 fetch)", text: Binding(get: { skill.entryPoint ?? "" }, set: { skill.entryPoint = $0 }))
                                            .textFieldStyle(.roundedBorder)
                                            .fontDesign(.monospaced)
                                            .frame(width: 200)
                                    }
                                    Text("💡 大模型下发的参数矩阵将自动封装为 JSON-RPC 载荷打入上述节点的 Method 中。").font(.system(size: 11)).foregroundColor(.purple)
                                    
                                } else if skill.type == .cli {
                                    SkillLeftAlignedRow("挂载变量") { TextField("例如: cli_output (留空则不挂载到上下文)", text: $skill.outputKey).textFieldStyle(.roundedBorder).fontDesign(.monospaced) }
                                    SkillLeftAlignedRow("安全防护") { Toggle("执行前需经过人类确认 (HITL)", isOn: $skill.requiresConfirmation).toggleStyle(.switch).tint(.orange) }
                                    SkillLeftAlignedRow("命令行程序") {
                                        TextField("可执行程序路径或系统命令 (如 e10-cli, ffmpeg, ripgrep, git)", text: $skill.executionBody)
                                            .textFieldStyle(.roundedBorder)
                                            .fontDesign(.monospaced)
                                    }
                                    Text("💡 系统通过登录态 PATH 动态解析定位该命令，参数自动映射为 argv 并支持实时非阻塞流式捕获。")
                                        .font(.system(size: 11)).foregroundColor(.teal).padding(.leading, 87)
                                } else {
                                    SkillLeftAlignedRow("挂载变量") { TextField("例如: weather_result (留空则不挂载到上下文)", text: $skill.outputKey).textFieldStyle(.roundedBorder).fontDesign(.monospaced) }
                                    SkillLeftAlignedRow("安全防护") { Toggle("执行前需经过人类确认 (HITL)", isOn: $skill.requiresConfirmation).toggleStyle(.switch).tint(.orange) }
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
            }.scrollContentBackground(.hidden).background(.ultraThinMaterial).forceOverlayScrollbars()
            Divider()
            HStack {
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction); Spacer()
                Button(action: { showTestSheet = true }) { Label("测试当前配置", systemImage: "play.fill") }
                    .buttonStyle(.bordered).controlSize(.large).disabled(isMarkdownMode ? skill.detailedInstruction.isEmpty : skill.executionBody.isEmpty)
                
                Button("保存配置") {
                    if isMarkdownMode {
                        skill.entryPoint = "SKILL.md (Instruction Only)"
                        skill.type = .shell
                        skill.executionBody = "if [ -n \"$ARG_RAW_COMMAND\" ]; then eval \"$ARG_RAW_COMMAND\"; else exit 1; fi"
                        if !skill.parameters.contains(where: { $0.name == "raw_command" }) { skill.parameters = [SkillParameter(name: "raw_command", type: .string, description: "必传，严格根据 SKILL.md 返回要执行的 JSON 结构参数", isRequired: false)] }
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
            }.padding(20).background(.thinMaterial)
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
            Util.message("剪贴板中没有有效的文本内容"); return
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
        self.skill = skill; self.onRun = onRun; self.onCancel = onCancel
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
            .padding(.horizontal, 20).padding(.vertical, 16)
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
                    jsonErrorMsg = "❌ 参数 [\(param.name)] 的 JSON (Object) 格式不合法，请检查拼写与引号。"; return nil
                }
                finalArgs[param.name] = dict
            } else if param.type == .array {
                guard let data = val.data(using: .utf8), let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
                    jsonErrorMsg = "❌ 参数 [\(param.name)] 的 JSON (Array) 格式不合法。"; return nil
                }
                finalArgs[param.name] = arr
            } else {
                finalArgs[param.name] = val
            }
        }
        return finalArgs
    }
}

// MARK: - ==================== 7. 缓存与上下文 ====================

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
        guard let lastMemory = getRecentArgs(for: skillName) else {
            return hydrated
        }
        
        for (key, _) in hydrated {
            if let rememberedValue = lastMemory[key] {
                hydrated[key] = rememberedValue
            }
        }
        return hydrated
    }
    
    public func clearAllSessionMemory() {
        memoryBank.removeAll()
    }
}

// MARK: - ==================== 8. MCP 服务器配置交互面板 ====================

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
            }.padding(.horizontal, 20).padding(.vertical, 16).background(Color(NSColor.windowBackgroundColor).opacity(0.8))
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 16) {
                            SkillLeftAlignedRow("服务名称") { TextField("如 GitHub, FileSystem", text: $mcp.name).textFieldStyle(.roundedBorder) }
                            
                            SkillLeftAlignedRow("连接类型") {
                                Picker("", selection: $mcp.transport) {
                                    ForEach(MCPTransportType.allCases, id: \.self) { type in Text(type.rawValue).tag(type) }
                                }.pickerStyle(.segmented).labelsHidden()
                            }
                            
                            if mcp.transport == .stdio {
                                SkillLeftAlignedRow("调度主命令") {
                                    TextField("可执行文件/包管理器，如 npx, uvx, python3", text: Binding(get: { mcp.command ?? "" }, set: { mcp.command = $0 }))
                                        .textFieldStyle(.roundedBorder)
                                        .fontDesign(.monospaced)
                                }
                                SkillLeftAlignedRow("执行后缀参数") {
                                    TextField("完整参数链，如 -y @modelcontextprotocol/server-postgres", text: Binding(get: { mcp.args ?? "" }, set: { mcp.args = $0 }))
                                        .textFieldStyle(.roundedBorder)
                                        .fontDesign(.monospaced)
                                }
                                Text("💡 核心提示：系统会在后台开启静默子进程以唤起该命令。请确保你的操作系统中已全局安装环境 (如 Node.js)。")
                                    .font(.system(size: 11)).foregroundColor(.purple).padding(.leading, 87)
                            } else {
                                SkillLeftAlignedRow("端点 URL") {
                                    TextField("Server-Sent Events 寻址，如 http://localhost:8080/sse", text: Binding(get: { mcp.url ?? "" }, set: { mcp.url = $0 }))
                                        .textFieldStyle(.roundedBorder)
                                        .fontDesign(.monospaced)
                                }
                                Text("💡 核心提示：确保安全组允许出站网络连接。")
                                    .font(.system(size: 11)).foregroundColor(.purple).padding(.leading, 87)
                            }
                            
                            SkillLeftAlignedRow("自启状态") {
                                Toggle("立即连接并暴露节点工具链", isOn: $mcp.isEnabled).toggleStyle(.switch).controlSize(.small).tint(.purple)
                            }
                            
                        }.padding(12)
                    } label: { Text("节点寻址属性").font(.headline).foregroundStyle(.primary) }
                    .groupBoxStyle(SkillFrostedGroupBoxStyle())
                    
                }.padding(20)
            }.scrollContentBackground(.hidden).background(.ultraThinMaterial).forceOverlayScrollbars()
            
            Divider()
            HStack {
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction); Spacer()
                Button("固化并握手连接") { onSave(mcp) }.buttonStyle(.borderedProminent).tint(.purple).controlSize(.large).keyboardShortcut(.defaultAction).disabled(mcp.name.isEmpty)
            }.padding(20).background(.thinMaterial)
        }.frame(width: 600, height: 480)
    }
}

// MARK: - ==================== 原生人工在环 (HITL) 悬浮交互控制台 ====================

// MARK: - 允许接管键盘焦点的原生浮动面板子类
private final class KeyInterventionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - 原生人工在环 (HITL) 悬浮交互控制台 (支持完整键盘焦点与输入)
@MainActor
public final class AgentInterventionUI {
    public static func requestGuidance(
        agentName: String,
        reason: String,
        suggestedActions: [String] = []
    ) async -> String? {
        // 使用支持成为 Key Window 的自定义子类，并移除 .nonactivatingPanel
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
            
            // 强制激活当前 App 并置为键盘响应窗口
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

// MARK: - macOS 14+ 拟真毛玻璃介入面板视图
struct AgentInterventionPanel: View {
    let agentName: String
    let reason: String
    let suggestedActions: [String]
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    
    @State private var inputText: String = ""
    @FocusState private var isInputFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // 1. 顶部状态栏
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
            
            // 2. 受阻原因摘要
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
                
                // 3. 快捷动作筹码 (Action Chips)
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
                
                // 4. 自定义文本输入
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
            
            // 5. 底部操作按钮
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
