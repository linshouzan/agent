//////////////////////////////////////////////////////////////////
// 文件名：GrammarManager.swift
// 文件说明：适用于 macOS 14+ 的 Agent 智能体意图与真值语义收敛中枢
//
// 核心架构与运行逻辑说明：
//
//////////////////////////////////////////////////////////////////

import SwiftUI
import AppKit
import Combine
import Foundation

// MARK: - ==================== 智能体意图与真值语义收敛中枢 ====================

// MARK: - 1. 物理真值校验收敛器 (Physical Truth Verifier)
public struct PhysicalTruthVerifier: Sendable {
    
    /// 结构化显式错误特征前缀
    private static let explicitErrorMarkers: Set<String> = [
        "❌", "⚠️", "Exception:", "Error:", "FATAL:", "panic:", "Traceback (most recent call last):"
    ]
    
    /// 工具返回结构体字典中的错误键
    private static let errorJsonKeys: Set<String> = [
        "error", "err_code", "failed", "exception", "errorMessage"
    ]
    
    /// 综合判别物理操作是否发生实质性失败
    /// - Parameters:
    ///   - output: 工具执行原始返回文本
    ///   - exitCode: 进程物理退出码 (非 0 即判定失败)
    public static func hasPhysicalError(output: String, exitCode: Int? = nil) -> Bool {
        if let code = exitCode, code != 0 { return true }
        
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        
        // 1. 匹配显式错误特征
        if explicitErrorMarkers.contains(where: { trimmed.contains($0) }) {
            return true
        }
        
        // 2. 探查顶层结构化 JSON 是否携带错误键
        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return errorJsonKeys.contains(where: { dict[$0] != nil })
        }
        
        return false
    }
}

// MARK: - 2. 调度推进与意图看门狗 (Continuance Intent Watchdog)
public enum ContinuanceActionIntent: Sendable {
    case stepContinuation       // 步骤衔接（"接下来"、"继续推进"）
    case retryInvestigation     // 重新排查（"再次核对"、"重新查询"）
    case cliExplicitCommand     // 具体 CLI 命令预告（"form list"、"add-field" 等）
    case none
    
    private static let continuationKeywords: Set<String> = ["接下来", "先通过", "随后", "准备执行", "下一步", "继续推进"]
    private static let retryKeywords: Set<String> = ["重新", "再次核对", "排查后重试", "纠正参数", "再次尝试"]
    private static let knownCliCommands: Set<String> = [
        "list", "read", "add-field", "create", "search", "delete", "query", "install", "build"
    ]
    
    /// 意图匹配探针
    public static func match(from text: String) -> ContinuanceActionIntent {
        let lower = text.lowercased()
        if knownCliCommands.contains(where: { lower.contains($0) }) {
            return .cliExplicitCommand
        }
        if retryKeywords.contains(where: { text.contains($0) }) {
            return .retryInvestigation
        }
        if continuationKeywords.contains(where: { text.contains($0) }) {
            return .stepContinuation
        }
        return .none
    }
    
    /// 看门狗早退拦截判定
    public static func shouldInterceptEarlyExit(
        text: String,
        isBlackboardActive: Bool,
        hasUnfinishedTasks: Bool,
        textOnlyRounds: Int
    ) -> Bool {
        guard isBlackboardActive, hasUnfinishedTasks, textOnlyRounds <= 2 else { return false }
        return match(from: text) != .none
    }
}

// MARK: - 3. 黑板节点与状态语法收敛器 (Blackboard Grammar)
public struct BlackboardGrammar: Sendable {
    
    /// 物理动词词库 (命中即标记为物理 Tool 节点)
    private static let strictActionKeywords: Set<String> = [
        "点击", "打开", "删除", "新建", "创建", "运行", "执行", "粘贴", "按键", "抓屏",
        "修改", "写入", "移动", "下载", "安装", "清除", "输入", "滑动", "滚屏", "唤醒",
        "保存", "导出", "构建", "编译", "部署", "查询", "检索", "请求", "截屏", "截图",
        "click", "open", "delete", "remove", "run", "execute", "paste", "write",
        "download", "install", "press", "scroll", "launch", "save", "build", "fetch"
    ]
    
    /// 纯文本交付动词库
    private static let reasoningKeywords: Set<String> = [
        "纯文本回复", "直接回答", "总结归纳", "口头说明", "解答疑问", "提供建议", "解释原理", "阐述方案",
        "reply", "answer", "explain", "summarize", "analyze"
    ]
    
    /// 推断节点类型
    public static func inferNodeType(from text: String) -> GraphNodeType {
        let lower = text.lowercased()
        if strictActionKeywords.contains(where: { lower.contains($0) }) {
            return .tool
        }
        if reasoningKeywords.contains(where: { lower.contains($0) }) {
            return .reasoning
        }
        return .tool // 默认保持保守策略，分配给物理操作
    }
    
    /// 弹性解析任务状态
    public static func parseStatus(from text: String) -> GraphNodeStatus {
        let s = text.lowercased()
        
        // 1. 最高优先级：判定失败、阻断、异常、中止语素
        if s.contains("失败") || s.contains("failed") || s.contains("error") ||
           s.contains("阻断") || s.contains("中止") || s.contains("取消") || s.contains("异常") ||
           s.contains("未通过") || s.contains("无法") {
            return .failed
        }
        
        // 2. 次优先级：判定明确成功语素
        if s.contains("成功") || s.contains("success") || s.contains("ok") ||
           (s.contains("完成") && !s.contains("未完成")) ||
           (s.contains("done") && !s.contains("not done")) {
            return .success
        }
        
        // 3. 判定执行中语素
        if s.contains("执行中") || s.contains("进行中") || s.contains("running") || s.contains("in_progress") {
            return .running
        }
        
        // 4. 其余态默认回退为等待态
        return .pending
    }
}

// MARK: - 4. 诊断自愈与引导语法收敛器 (Diagnostic Grammar)
public enum ToolExecutionDiagnostic: Sendable {
    case commandNotFound
    case parameterValidationFailed
    case resourceNotFound           // 业务资源不存在 (如 应用ID/表单ID 不存在)
    case pathNotFound               // 本地文件系统物理路径不存在
    case permissionDenied           // 系统级沙盒或文件权限受限
    case generic(String)
    
    /// 结构化分析错误类型 (优化优先级：优先匹配业务资源与参数错误)
    public static func analyze(errorMessage: String) -> ToolExecutionDiagnostic {
        let lower = errorMessage.lowercased()
        
        // 1. 命令/二进制未就绪
        if lower.contains("未找到命令") || lower.contains("command not found") || lower.contains("找不到可执行") {
            return .commandNotFound
        }
        
        // 2. 参数语法/必填项对齐
        if lower.contains("参数校验失败") || lower.contains("缺少必填参数") || lower.contains("usage:") || lower.contains("invalid argument") {
            return .parameterValidationFailed
        }
        
        // 3. 业务资源与物理路径区分判断
        if lower.contains("不存在") || lower.contains("not found") || lower.contains("找不到") || lower.contains("404") || lower.contains("无此") || lower.contains("unknown") {
            if lower.contains("文件") || lower.contains("目录") || lower.contains("path") || lower.contains("file") || lower.contains("directory") {
                return .pathNotFound
            }
            return .resourceNotFound
        }
        
        // 4. 权限与沙盒保护 (排除非权限引起的报错)
        if (lower.contains("权限") || lower.contains("denied") || lower.contains("permission") || lower.contains("eacces")) && !lower.contains("不存在") {
            return .permissionDenied
        }
        
        return .generic(errorMessage)
    }
    
    /// 正向自愈指引
    public var structuredHealingPrompt: String {
        switch self {
        case .commandNotFound:
            return "● 执行诊断：目标指令未就绪。\n● 推荐动作：核对工具确切名称，或调用系统 Shell/Python 脚本直接执行。"
        case .parameterValidationFailed:
            return "● 执行诊断：参数结构需要对齐。\n● 推荐动作：核对必填字段的类型格式（如 JSON 结构），直接发起修正后的 Tool Call。"
        case .resourceNotFound:
            return "● 执行诊断：目标业务资源未找到 (如目标应用 ID / 表单 ID 不存在)。\n● 推荐动作：优先调用 list/search 等探针指令检索当前环境有效资源列表，校准目标 ID。"
        case .pathNotFound:
            return "● 执行诊断：目标物理路径未找到。\n● 推荐动作：优先调用目录读取或文件检索工具获取有效物理路径。"
        case .permissionDenied:
            return "● 执行诊断：触发沙盒访问保护。\n● 推荐动作：将操作限定在应用沙盒允许范围或用户 Downloads 目录下执行。"
        case .generic(let msg):
            let summary = msg.count > 160 ? String(msg.prefix(160)) + "..." : msg
            return "● 执行反馈：\(summary)\n● 推荐动作：结合上下文调整参数配置后继续推进。"
        }
    }
}

// MARK: - 5. 技能物理操作类型与写后验收契约 (RAW Verification Protocol)

/// 技能物理操作类型分类
public enum SkillOperationType: String, Codable, Sendable {
    case query      // 只读探查 (如 app list, form list, file read)
    case mutation   // 物理写入/变异 (如 form add-field, workflow bind, file write)
    case validation // 验收探针 (如 form read, file_exists, schema inspect)
}

/// 业务里程碑写后物理核验状态
public enum MilestoneValidationState: String, Codable, Sendable {
    case unverified         // 待验证 (已下发写操作，尚未启动物理反查)
    case verifying          // 反查中 (探针执行或数据对账比对中)
    case verifiedSuccess    // 已核验 (反查比对一致，物理生效通过)
    case discrepancyFound   // 差异纠偏 (反查发现未生效/属性缺失，需自动纠偏)
    
    public var badgeTitle: String {
        switch self {
        case .unverified: return "待核验"
        case .verifying: return "物理核验中"
        case .verifiedSuccess: return "真实生效"
        case .discrepancyFound: return "数据差异"
        }
    }
}

/// 验收契约：定义写操作与反查探针的绑定关系
public struct VerificationContract: Codable, Sendable, Equatable {
    public let targetResourceId: String       // 目标资源标识 (如 表单 ID "1100882478332862465")
    public let expectedMutationKey: String     // 预期新增/变更的特征键 (如 字段名 "请假类型")
    public let probeToolName: String          // 验收探针工具名 (如 "skill-e10-cli")
    public let probeCommandTemplate: String   // 探针执行指令模版 (如 "form read {resource_id}")
    
    public init(
        targetResourceId: String,
        expectedMutationKey: String,
        probeToolName: String,
        probeCommandTemplate: String
    ) {
        self.targetResourceId = targetResourceId
        self.expectedMutationKey = expectedMutationKey
        self.probeToolName = probeToolName
        self.probeCommandTemplate = probeCommandTemplate
    }
}

/// 操作类型与变异特征解析器
public struct SkillOperationGrammar: Sendable {
    
    /// 变异动作特征词（写入/创建/挂载/修改）
    private static let mutationKeywords: Set<String> = [
        "add-field", "create", "update", "delete", "remove", "bind", "write",
        "save", "modify", "insert", "append", "publish", "drop", "alter"
    ]
    
    /// 探针与只读特征词
    private static let validationKeywords: Set<String> = [
        "read", "inspect", "diff", "verify", "validate", "check", "get", "detail"
    ]
    
    /// 判别物理操作类型
    public static func classify(toolName: String, args: [String: Any]) -> SkillOperationType {
        let cmd = (args["cmd"] as? String ?? args["command"] as? String ?? "").lowercased()
        let name = toolName.lowercased()
        let combined = "\(name) \(cmd)"
        
        // 1. 优先匹配物理写入动作
        if mutationKeywords.contains(where: { combined.contains($0) }) {
            return .mutation
        }
        
        // 2. 匹配验收探针动作
        if validationKeywords.contains(where: { combined.contains($0) }) {
            return .validation
        }
        
        // 3. 默认为只读探查
        return .query
    }
    
    /// 自动提取变异写操作的验收契约
    public static func extractContract(toolName: String, args: [String: Any]) -> VerificationContract? {
        let cmd = args["cmd"] as? String ?? args["command"] as? String ?? ""
        let parts = cmd.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        // 针对 E10 表单字段添加动作: form add-field <formId> <fieldName> <type> ...
        if parts.count >= 4 && parts[0].lowercased() == "form" && parts[1].lowercased() == "add-field" {
            let formId = parts[2]
            let fieldName = parts[3]
            return VerificationContract(
                targetResourceId: formId,
                expectedMutationKey: fieldName,
                probeToolName: toolName,
                probeCommandTemplate: "form read \(formId)"
            )
        }
        
        return nil
    }
}
