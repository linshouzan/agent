//////////////////////////////////////////////////////////////////
// 文件名：AiChatView.swift
// 文件说明：适用于 macOS 14+ 的 AI 对话窗口 UI 渲染与交互组件群 (Swift 6 Ready)
//
// 核心解构架构拓扑 (Domain-Driven Architecture):
// ├── 1. ChatModels             : 消息实体、RAG 命中、技能执行日志与会话持久化模型
// ├── 2. ChatParsers            : Markdown 增量渲染缓存、AST 块级解析器与流式提取器
// ├── 3. ChatStore & Managers   : 响应式全局会话状态池 (AiChatStore) 与语音识别服务
// ├── 4. ChatBlockViews         : 块级 Markdown 渲染组件群 (Header, Code, Table, Think, Divider)
// ├── 5. ChatInteractiveCards   : 具身工具时间轴、HITL 授权卡片、任务结单与 RAG 切片查看器
// ├── 6. ChatInputComponents    : 光标物理感知输入框 (NativeMacTextView)、@ 专家与 # 选项浮窗
// └── 7. ChatMainView           : 主对话窗口容器、消息气泡行 (RowView) 与 Siri 活跃流光背景
//////////////////////////////////////////////////////////////////

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine
import Speech
import AVFoundation

// MARK: - ==================== 1. ChatModels (数据模型与持久化实体) ====================

extension NSParagraphStyle: @retroactive @unchecked Sendable {}

extension NSColor {
    var color: Color { Color(self) }
}

struct RAGHitLog: Identifiable, Equatable, Sendable {
    let id = UUID()
    let title: String
    let path: String
    let content: String
}

struct SkillExecutionLog: Identifiable, Equatable, Sendable {
    let id: UUID
    let skillName: String
    var displayName: String
    var args: [String: Any]
    var resultOutput: String
    var confirmationId: String?
    var uiTemplate: String
    var executorName: String?
    
    init(
        id: UUID = UUID(),
        skillName: String,
        displayName: String? = nil,
        args: [String: Any] = [:],
        resultOutput: String,
        confirmationId: String? = nil,
        executorName: String? = nil,
        uiTemplate: String = ""
    ) {
        self.id = id
        self.skillName = skillName
        self.displayName = displayName ?? skillName
        self.args = args
        self.resultOutput = resultOutput
        self.confirmationId = confirmationId
        self.executorName = executorName
        self.uiTemplate = uiTemplate
    }
    
    static func == (lhs: SkillExecutionLog, rhs: SkillExecutionLog) -> Bool {
        return lhs.id == rhs.id &&
               lhs.skillName == rhs.skillName &&
               lhs.displayName == rhs.displayName &&
               lhs.resultOutput == rhs.resultOutput &&
               lhs.confirmationId == rhs.confirmationId &&
               lhs.executorName == rhs.executorName &&
               lhs.uiTemplate == rhs.uiTemplate
    }
}

enum MessageFeedback: String, Codable, Sendable {
    case none
    case liked
    case disliked
}

struct ChatMessage: Identifiable, Equatable, Sendable {
    var id = UUID()
    var isUser: Bool
    var text: String
    var images: [NSImage] = []
    var fileURLs: [URL] = []
    var ragHits: [RAGHitLog] = []
    var skillLogs: [SkillExecutionLog] = []
    var feedback: MessageFeedback = .none
    
    init(
        id: UUID = UUID(),
        isUser: Bool,
        text: String,
        images: [NSImage] = [],
        fileURLs: [URL] = [],
        ragHits: [RAGHitLog] = [],
        skillLogs: [SkillExecutionLog] = [],
        feedback: MessageFeedback = .none
    ) {
        self.id = id
        self.isUser = isUser
        self.text = text
        self.images = images
        self.fileURLs = fileURLs
        self.ragHits = ragHits
        self.skillLogs = skillLogs
        self.feedback = feedback
    }
}

enum PartType: Equatable, Sendable {
    case text
    case header(level: Int)
    case code(language: String)
    case think(isClosed: Bool)
    case table(headers: [String], rows: [[String]])
    case divider
}

struct MessagePart: Equatable, Sendable {
    let type: PartType
    let text: String
}

struct LLMBeaconAlert: Identifiable, Equatable, Sendable {
    let id = UUID()
    let message: String
    let isWarning: Bool
    let timestamp: Date = Date()
}

// MARK: - 历史会话持久化模型

struct ChatSession: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var title: String
    var updatedAt: Date = Date()
    var agentID: UUID
    var messages: [SavedChatMessage]
    var activatedPrivateQAIDs: Set<UUID> = []
    var isArchived: Bool? = false
    var archiveCategory: String? = "常规会话"
    var personaID: UUID? = nil
    var blackboardPlan: String? = nil
    
    enum CodingKeys: String, CodingKey {
        case id, title, updatedAt, agentID, messages, activatedPrivateQAIDs, isArchived, archiveCategory, personaID, blackboardPlan
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.title = try container.decode(String.self, forKey: .title)
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        self.agentID = try container.decode(UUID.self, forKey: .agentID)
        self.messages = try container.decode([SavedChatMessage].self, forKey: .messages)
        self.activatedPrivateQAIDs = try container.decodeIfPresent(Set<UUID>.self, forKey: .activatedPrivateQAIDs) ?? []
        self.isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        self.archiveCategory = try container.decodeIfPresent(String.self, forKey: .archiveCategory) ?? "常规会话"
        self.personaID = try container.decodeIfPresent(UUID.self, forKey: .personaID)
        self.blackboardPlan = try container.decodeIfPresent(String.self, forKey: .blackboardPlan)
    }
    
    init(
        id: UUID = UUID(),
        title: String,
        updatedAt: Date = Date(),
        agentID: UUID,
        messages: [SavedChatMessage],
        activatedPrivateQAIDs: Set<UUID> = [],
        isArchived: Bool = false,
        archiveCategory: String = "常规会话",
        personaID: UUID? = nil,
        blackboardPlan: String? = nil
    ) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.agentID = agentID
        self.messages = messages
        self.activatedPrivateQAIDs = activatedPrivateQAIDs
        self.isArchived = isArchived
        self.archiveCategory = archiveCategory
        self.personaID = personaID
        self.blackboardPlan = blackboardPlan
    }
}

struct SavedChatMessage: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var isUser: Bool
    var text: String
    var ragHits: [SavedRAGHitLog]
    var skillLogs: [SavedSkillExecutionLog]
    var imageB64Strings: [String]?
    var fileURLStrings: [String]?
    var feedback: MessageFeedback?
}

struct SavedRAGHitLog: Codable, Equatable, Sendable {
    var title: String
    var path: String
    var content: String
}

struct SavedSkillExecutionLog: Codable, Equatable, Sendable {
    var id: UUID
    var skillName: String
    var displayName: String
    var argsJSON: String
    var resultOutput: String
    var confirmationId: String?
    var executorName: String?
    var uiTemplate: String?
}

extension ChatMessage {
    func toSaved() -> SavedChatMessage {
        let imgStrings = images.compactMap { img -> String? in
            guard let tiff = img.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else { return nil }
            return pngData.base64EncodedString()
        }
        let urlStrings = fileURLs.map { $0.absoluteString }
        
        return SavedChatMessage(
            id: id,
            isUser: isUser,
            text: text,
            ragHits: ragHits.map { SavedRAGHitLog(title: $0.title, path: $0.path, content: $0.content) },
            skillLogs: skillLogs.map { log in
                let argsData = try? JSONSerialization.data(withJSONObject: log.args, options: [])
                let argsStr = String(data: argsData ?? Data(), encoding: .utf8) ?? "{}"
                return SavedSkillExecutionLog(id: log.id, skillName: log.skillName, displayName: log.displayName, argsJSON: argsStr, resultOutput: log.resultOutput, confirmationId: log.confirmationId, executorName: log.executorName, uiTemplate: log.uiTemplate)
            },
            imageB64Strings: imgStrings,
            fileURLStrings: urlStrings,
            feedback: feedback
        )
    }
    
    static func fromSaved(_ saved: SavedChatMessage) -> ChatMessage {
        let decodedSkillLogs = saved.skillLogs.map { savedLog -> SkillExecutionLog in
            let argsDict = (try? JSONSerialization.jsonObject(with: savedLog.argsJSON.data(using: .utf8) ?? Data())) as? [String: Any] ?? [:]
            return SkillExecutionLog(id: savedLog.id, skillName: savedLog.skillName, displayName: savedLog.displayName, args: argsDict, resultOutput: savedLog.resultOutput, confirmationId: savedLog.confirmationId, executorName: savedLog.executorName, uiTemplate: savedLog.uiTemplate ?? "")
        }
        
        let decodedRagHits = saved.ragHits.map { RAGHitLog(title: $0.title, path: $0.path, content: $0.content) }
        
        var restoredImages: [NSImage] = []
        if let b64Strings = saved.imageB64Strings {
            restoredImages = b64Strings.compactMap { str in
                guard let data = Data(base64Encoded: str) else { return nil }
                return NSImage(data: data)
            }
        }
        
        var restoredURLs: [URL] = []
        if let urlStrings = saved.fileURLStrings {
            restoredURLs = urlStrings.compactMap { URL(string: $0) }
        }
        
        return ChatMessage(
            id: saved.id,
            isUser: saved.isUser,
            text: saved.text,
            images: restoredImages,
            fileURLs: restoredURLs,
            ragHits: decodedRagHits,
            skillLogs: decodedSkillLogs,
            feedback: saved.feedback ?? .none
        )
    }
}

// MARK: - ==================== 2. ChatParsers (AST 解析与渲染缓存引擎) ====================

final class MessageASTCache: @unchecked Sendable {
    static let shared = MessageASTCache()
    private let cache = NSCache<NSString, AnyObject>()
    private init() { cache.countLimit = 1000 }
    
    func getParsedParts(id: UUID, text: String, isGenerating: Bool) -> [MessagePart] {
        if isGenerating {
            return MessageParser.parse(text)
        }
        
        let key = "\(id.uuidString)_\(text.hashValue)" as NSString
        if let cached = cache.object(forKey: key) as? NSArray {
            return cached as! [MessagePart]
        }
        
        let parsed = MessageParser.parse(text)
        cache.setObject(parsed as NSArray, forKey: key)
        return parsed
    }
}

// MARK: - 原生 macOS 极致排版 MarkdownRenderCache
class MarkdownRenderCache: @unchecked Sendable {
    static let shared = MarkdownRenderCache()
    
    private final class CacheWrapper: Sendable {
        let attrString: AttributedString
        init(_ attrString: AttributedString) { self.attrString = attrString }
    }
    
    private let cache = NSCache<NSString, CacheWrapper>()
    private init() { cache.countLimit = 2000 }
    
    private static let newlineRegex = try! NSRegularExpression(pattern: #"\n{3,}"#)
    private static let inlineCodeRegex = try! NSRegularExpression(pattern: #"(?<!`)`([^`\n\r]+)`(?!`)"#)
    private static let highlightRegex = try! NSRegularExpression(pattern: #"(?<!=)==([^=\n\r\t]+)==(?!=)"#)
    private static let errorRegex     = try! NSRegularExpression(pattern: #"(?<!\!)\!\!([^!\n\r\t]+)\!\!(?!\!)"#)
    private static let infoRegex      = try! NSRegularExpression(pattern: #"(?<!\?)\?\?([^?\n\r\t]+)\?\?(?!\?)"#)
    private static let successRegex   = try! NSRegularExpression(pattern: #"(?<!\+)\+\+([^+ \n\r\t][^+]*?[^+ \n\r\t])\+\+(?!\+)"#)
    private static let sparkRegex     = try! NSRegularExpression(pattern: #"(?<!~)~~([^~\n\r\t]+)~~(?!~)"#)
    private static let blockquoteRegex = try! NSRegularExpression(pattern: #"(?m)^>\s*(.*)$"#)
    private static let listItemRegex   = try! NSRegularExpression(pattern: #"(?m)^(?:\*|-)\s+(.*)$"#)
    private static let latexSymbolRegex = try! NSRegularExpression(pattern: #"\$?\\([a-zA-Z]+)\$?"#)
    
    private static let latexSymbolMap: [String: String] = [
        "rightarrow": "→", "to": "→", "rightarrowtail": "↣", "leftarrow": "←", "toleft": "←",
        "leftrightarrow": "↔", "Leftrightarrow": "⇔", "Rightarrow": "⇒", "Leftarrow": "⇐",
        "uparrow": "↑", "downarrow": "↓", "Delta": "Δ", "delta": "δ", "alpha": "α", "beta": "β",
        "gamma": "γ", "lambda": "λ", "Lambda": "Λ", "pi": "π", "sigma": "σ", "omega": "ω",
        "Omega": "Ω", "theta": "θ", "times": "×", "div": "÷", "neq": "≠", "le": "≤", "ge": "≥",
        "in": "∈", "notin": "∉", "infty": "∞", "approx": "≈", "dots": "…", "forall": "∀", "exists": "∃"
    ]
    
    private static let sharedQuoteParagraphStyle: NSParagraphStyle = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = 10
        paragraph.headIndent = 10
        paragraph.paragraphSpacingBefore = 4
        paragraph.paragraphSpacing = 4
        return paragraph.copy() as! NSParagraphStyle
    }()
    
    private static let sharedListParagraphStyle: NSParagraphStyle = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = 4
        paragraph.headIndent = 14
        paragraph.paragraphSpacing = 3
        return paragraph.copy() as! NSParagraphStyle
    }()
    
    func get(from text: String, isUser: Bool) -> AttributedString {
        let cacheKey = "\(isUser ? "U" : "A")_\(text.hashValue)" as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached.attrString }
        
        var safeText = text.replacingOccurrences(of: "\r\n", with: "\n")
        safeText = safeText.replacingOccurrences(of: "\u{00A0}", with: " ")
        
        // 1. 替换 LaTeX 常用特殊字符
        let latexMatches = Self.latexSymbolRegex.matches(in: safeText, options: [], range: NSRange(safeText.startIndex..., in: safeText))
        for match in latexMatches.reversed() {
            guard let totalRange = Range(match.range, in: safeText),
                  let symbolRange = Range(match.range(at: 1), in: safeText) else { continue }
            let symbolKey = String(safeText[symbolRange])
            if let unicodeReplacement = Self.latexSymbolMap[symbolKey] {
                safeText.replaceSubrange(totalRange, with: unicodeReplacement)
            }
        }
        
        // 2. 注入微空格 (\u{200A}) 形成行内代码呼吸感
        safeText = Self.inlineCodeRegex.stringByReplacingMatches(
            in: safeText,
            options: [],
            range: scRange(safeText),
            withTemplate: "`\u{200A}$1\u{200A}`"
        )
        
        // 3. 结构化标记规范化
        safeText = Self.newlineRegex.stringByReplacingMatches(in: safeText, options: [], range: scRange(safeText), withTemplate: "\n\n")
        safeText = Self.listItemRegex.stringByReplacingMatches(in: safeText, options: [], range: scRange(safeText), withTemplate: "[•](style://listitem) $1")
        safeText = Self.blockquoteRegex.stringByReplacingMatches(in: safeText, options: [], range: scRange(safeText), withTemplate: "[▎](style://blockquote) $1")
        
        // 4. 自定义高亮标签样式映射
        safeText = Self.highlightRegex.stringByReplacingMatches(in: safeText, options: [], range: scRange(safeText), withTemplate: "[$1](style://highlight)")
        safeText = Self.errorRegex.stringByReplacingMatches(in: safeText, options: [], range: scRange(safeText), withTemplate: "[$1](style://error)")
        safeText = Self.infoRegex.stringByReplacingMatches(in: safeText, options: [], range: scRange(safeText), withTemplate: "[$1](style://info)")
        safeText = Self.successRegex.stringByReplacingMatches(in: safeText, options: [], range: scRange(safeText), withTemplate: "[$1](style://success)")
        safeText = Self.sparkRegex.stringByReplacingMatches(in: safeText, options: [], range: scRange(safeText), withTemplate: "[$1](style://spark)")
        
        safeText = safeText.replacingOccurrences(of: "\n", with: "  \n")
        
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        
        var result = (try? AttributedString(markdown: safeText, options: options)) ?? AttributedString(text)
        
        // 5. 正文基准字体
        var baseAttr = AttributeContainer()
        baseAttr.font = Font.system(size: 14, weight: .regular)
        baseAttr.foregroundColor = isUser ? Color.white : Color(nsColor: .labelColor).opacity(0.92)
        result.mergeAttributes(baseAttr, mergePolicy: .keepNew)
        
        // 6. 遍历 Run 进行精细排版
        for run in result.runs {
            var runAttr = AttributeContainer()
            
            if let inlineIntent = run.inlinePresentationIntent {
                if inlineIntent.contains(.code) {
                    runAttr.font = Font.system(size: 12.0, weight: .medium, design: .monospaced)
                    runAttr.foregroundColor = isUser ? Color.white.opacity(0.95) : Color(nsColor: .labelColor).opacity(0.88)
                    runAttr.backgroundColor = isUser ? Color.white.opacity(0.18) : Color.primary.opacity(0.048)
                    result[run.range].mergeAttributes(runAttr, mergePolicy: .keepNew)
                } else if inlineIntent.contains(.stronglyEmphasized) && inlineIntent.contains(.emphasized) {
                    runAttr.font = Font.system(size: 14.0, weight: .bold).italic()
                    runAttr.foregroundColor = isUser ? Color.white : Color(nsColor: .labelColor)
                    result[run.range].mergeAttributes(runAttr, mergePolicy: .keepNew)
                } else if inlineIntent.contains(.stronglyEmphasized) {
                    runAttr.font = Font.system(size: 14.0, weight: .bold)
                    runAttr.foregroundColor = isUser ? Color.white : Color(nsColor: .labelColor)
                    result[run.range].mergeAttributes(runAttr, mergePolicy: .keepNew)
                } else if inlineIntent.contains(.emphasized) {
                    runAttr.font = Font.system(size: 14.0, weight: .semibold).italic()
                    runAttr.foregroundColor = isUser ? Color.white.opacity(0.95) : Color(nsColor: .labelColor).opacity(0.96)
                    result[run.range].mergeAttributes(runAttr, mergePolicy: .keepNew)
                }
            } else if let url = run.link, let scheme = url.scheme, let host = url.host {
                runAttr.underlineStyle = nil
                
                if scheme == "action" && host == "inspect_tool" {
                    runAttr.font = Font.system(size: 11.0, weight: .bold, design: .rounded)
                    runAttr.baselineOffset = 3.0
                    runAttr.backgroundColor = .clear
                    
                    let queryParams = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
                    let status = queryParams?.first(where: { $0.name == "status" })?.value ?? "running"
                    
                    switch status {
                    case "success":
                        runAttr.foregroundColor = Color(hex: "#10B981")
                    case "failed":
                        runAttr.foregroundColor = Color(hex: "#EF4444")
                    case "waiting":
                        runAttr.foregroundColor = Color.orange
                    default:
                        runAttr.foregroundColor = Color.purple.opacity(0.9)
                    }
                } else if scheme == "action" && host == "inspect_rag" {
                    runAttr.font = Font.system(size: 11.0, weight: .bold, design: .rounded)
                    runAttr.baselineOffset = 3.0
                    runAttr.backgroundColor = .clear
                    runAttr.foregroundColor = Color.cyan
                } else if scheme == "style" {
                    switch host {
                    case "highlight":
                        runAttr.font = Font.system(size: 14.0, weight: .bold, design: .rounded)
                        runAttr.foregroundColor = Color.orange
                    case "error":
                        runAttr.font = Font.system(size: 14.0, weight: .bold, design: .rounded)
                        runAttr.foregroundColor = Color.red
                    case "info":
                        runAttr.font = Font.system(size: 14.0, weight: .bold, design: .rounded)
                        runAttr.foregroundColor = Color.blue
                    case "success":
                        runAttr.font = Font.system(size: 14.0, weight: .bold, design: .rounded)
                        runAttr.foregroundColor = Color(hex: "#00897B")
                    case "spark":
                        runAttr.font = Font.system(size: 14.0, weight: .bold, design: .rounded)
                        runAttr.foregroundColor = Color.purple
                    case "blockquote":
                        runAttr.font = Font.system(size: 14, weight: .bold)
                        runAttr.foregroundColor = Color.cyan.opacity(0.8)
                        runAttr.paragraphStyle = Self.sharedQuoteParagraphStyle
                    case "listitem":
                        runAttr.font = Font.system(size: 14, weight: .bold)
                        runAttr.foregroundColor = Color.cyan
                        runAttr.paragraphStyle = Self.sharedListParagraphStyle
                    default: break
                    }
                }
                result[run.range].mergeAttributes(runAttr, mergePolicy: .keepNew)
            }
        }
        
        cache.setObject(CacheWrapper(result), forKey: cacheKey)
        return result
    }
    
    @inline(__always) private func scRange(_ str: String) -> NSRange {
        return NSRange(location: 0, length: str.utf16.count)
    }
}

struct AgentStreamParser {
    static func parse(_ rawText: String) -> (cleanText: String, ragHits: [RAGHitLog], skillLogs: [SkillExecutionLog]) {
        var text = rawText
        var ragHits: [RAGHitLog] = []
        var skillLogs: [SkillExecutionLog] = []
        
        if text.contains("📚 [命中知识库:") {
            let ragPattern = "(?s)📚 \\[命中知识库: ([^|\\]]+)(?:\\|([^\\]]*))?\\](.*?)(====== 提取结束 ======)"
            if let regex = try? NSRegularExpression(pattern: ragPattern) {
                let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                for match in matches.reversed() {
                    if let titleRange = Range(match.range(at: 1), in: text), let contentRange = Range(match.range(at: 3), in: text) {
                        var filePath = ""
                        if match.range(at: 2).location != NSNotFound, let pathRange = Range(match.range(at: 2), in: text) {
                            filePath = String(text[pathRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        ragHits.append(RAGHitLog(title: String(text[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines), path: filePath, content: String(text[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                    if let fr = Range(match.range(at: 0), in: text) { text.removeSubrange(fr) }
                }
            }
            if let pendingRange = text.range(of: "📚 [命中知识库:") { text.removeSubrange(pendingRange.lowerBound...) }
        }
        
        if text.contains("🛠️ [Agent ") {
            let skillPattern = "(?s)🛠️ \\[Agent (.*?): (.*?)\\](.*?)(======================)"
            if let regex = try? NSRegularExpression(pattern: skillPattern) {
                let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                for match in matches.reversed() {
                    if let nameRange = Range(match.range(at: 2), in: text), let outputRange = Range(match.range(at: 3), in: text) {
                        let name = String(text[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                        let output = String(text[outputRange]).replacingOccurrences(of: "====== 执行返回结果 ======", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                        skillLogs.append(SkillExecutionLog(skillName: name, resultOutput: output))
                    }
                    if let fr = Range(match.range(at: 0), in: text) { text.removeSubrange(fr) }
                }
            }
            if let pendingRange = text.range(of: "🛠️ [Agent ") { text.removeSubrange(pendingRange.lowerBound...) }
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), ragHits.reversed(), skillLogs.reversed())
    }
}

struct MessageParser {
    static func parse(_ rawText: String) -> [MessagePart] {
        var parts: [MessagePart] = []
        var remainingText = rawText
        
        let thinkOpen = "<think>"
        let thinkClose = "</think>"
        
        while !remainingText.isEmpty {
            if let openRange = remainingText.range(of: thinkOpen) {
                let precedingText = String(remainingText[..<openRange.lowerBound])
                if !precedingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parts.append(contentsOf: parseCardsAndBlocks(precedingText))
                }
                
                let searchRest = String(remainingText[openRange.upperBound...])
                if let endRange = searchRest.range(of: thinkClose) {
                    let thinkContent = String(searchRest[..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !thinkContent.isEmpty {
                        parts.append(MessagePart(type: .think(isClosed: true), text: thinkContent))
                    }
                    remainingText = String(searchRest[endRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    let thinkContent = searchRest.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !thinkContent.isEmpty {
                        parts.append(MessagePart(type: .think(isClosed: false), text: thinkContent))
                    }
                    remainingText = ""
                }
            } else {
                if !remainingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parts.append(contentsOf: parseCardsAndBlocks(remainingText))
                }
                remainingText = ""
            }
        }
        return parts
    }
    
    private static func parseCardsAndBlocks(_ text: String) -> [MessagePart] {
        var parts: [MessagePart] = []
        var remainingText = text
        
        let cardOpen = "<card>"
        let cardClose = "</card>"
        
        while !remainingText.isEmpty {
            if let openRange = remainingText.range(of: cardOpen) {
                let precedingText = String(remainingText[..<openRange.lowerBound])
                if !precedingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parts.append(contentsOf: parseBlocks(precedingText))
                }
                
                let searchRest = String(remainingText[openRange.upperBound...])
                if let endRange = searchRest.range(of: cardClose) {
                    let cardContent = String(searchRest[..<endRange.lowerBound])
                    parts.append(MessagePart(type: .text, text: "<card>\(cardContent)</card>"))
                    remainingText = String(searchRest[endRange.upperBound...])
                } else {
                    parts.append(MessagePart(type: .text, text: "<card>\(searchRest)</card>"))
                    remainingText = ""
                }
            } else {
                parts.append(contentsOf: parseBlocks(remainingText))
                remainingText = ""
            }
        }
        return parts
    }
    
    private static func parseBlocks(_ text: String) -> [MessagePart] {
        var parts: [MessagePart] = []
        let components = text.components(separatedBy: "```")
        
        for (index, component) in components.enumerated() {
            if index % 2 == 0 {
                let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { parts.append(contentsOf: parseTablesAndHeaders(from: trimmed)) }
            } else {
                var lines = component.components(separatedBy: .newlines)
                let lang = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
                if !lines.isEmpty { lines.removeFirst() }
                let code = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                parts.append(MessagePart(type: .code(language: lang), text: code))
            }
        }
        return parts
    }
    
    private static func parseTablesAndHeaders(from text: String) -> [MessagePart] {
        var parts: [MessagePart] = []
        let lines = text.components(separatedBy: .newlines)
        var tableLines: [String] = []
        var textLines: [String] = []
        
        let flushTextLines = {
            let joined = textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                let paragraphs = joined.components(separatedBy: "\n\n")
                for para in paragraphs {
                    let p = para.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !p.isEmpty { parts.append(MessagePart(type: .text, text: p)) }
                }
            }
            textLines.removeAll()
        }
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix(while: { $0 == "#" })
                if hashes.count >= 1 && hashes.count <= 6 && trimmed.dropFirst(hashes.count).hasPrefix(" ") {
                    if !tableLines.isEmpty { parts.append(createTablePart(from: tableLines)); tableLines.removeAll() }
                    if !textLines.isEmpty { flushTextLines() }
                    
                    let titleContent = trimmed.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
                    parts.append(MessagePart(type: .header(level: hashes.count), text: titleContent))
                    continue
                }
            }
            
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") {
                if !textLines.isEmpty { flushTextLines() }
                tableLines.append(trimmed)
            } else if isHorizontalRule(trimmed) {
                if !tableLines.isEmpty { parts.append(createTablePart(from: tableLines)); tableLines.removeAll() }
                if !textLines.isEmpty { flushTextLines() }
                parts.append(MessagePart(type: .divider, text: ""))
            } else {
                if !tableLines.isEmpty { parts.append(createTablePart(from: tableLines)); tableLines.removeAll() }
                textLines.append(line)
            }
        }
        
        if !tableLines.isEmpty { parts.append(createTablePart(from: tableLines)) }
        if !textLines.isEmpty { flushTextLines() }
        return parts
    }

    private static func isHorizontalRule(_ trimmedLine: String) -> Bool {
        guard trimmedLine.count >= 3 else { return false }
        guard let firstChar = trimmedLine.first, firstChar == "-" || firstChar == "*" || firstChar == "_" else { return false }
        return trimmedLine.allSatisfy { $0 == firstChar || $0 == " " }
    }
    
    private static func createTablePart(from lines: [String]) -> MessagePart {
        var rows: [[String]] = []
        for line in lines {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
            var cleanCells = cells
            if cleanCells.first == "" { cleanCells.removeFirst() }
            if cleanCells.last == "" { cleanCells.removeLast() }
            if cleanCells.allSatisfy({ $0.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " } }) { continue }
            rows.append(cleanCells)
        }
        if rows.count > 1 {
            let headers = rows.removeFirst()
            return MessagePart(type: .table(headers: headers, rows: rows), text: "")
        }
        return MessagePart(type: .text, text: lines.joined(separator: "\n"))
    }
}

// MARK: - ==================== 3. ChatStore & Managers (状态中枢与系统服务) ====================

@MainActor
class AiChatStore: ObservableObject {
    static let shared = AiChatStore()
    
    @Published var messages: [ChatMessage] = []
    @Published var isLoading: Bool = false
    @Published var isContextEnabled: Bool = true
    @Published var selectedImages: [NSImage] = []
    @Published var selectedFiles: [URL] = []
    @Published var currentSessionID: UUID = UUID()
    @Published var previewImage: NSImage? = nil
    @Published var selectedPersonaID: UUID? = nil
    @Published var blackboardPlan: String? = nil
    
    var activatedPrivateQAIDs: Set<UUID> = []
    var currentContextTokenCount: Int = 0
    
    @Published var inputText: String = ""
    @Published var editingTargetMessageID: UUID? = nil
    
    @Published var activeBeaconAlert: LLMBeaconAlert? = nil
    private var beaconDismissTask: Task<Void, Never>? = nil
    
    @Published var selectedAgentID: UUID = {
        let profiles = ConfigManager.shared.app.agentProfiles
        let defaultID = ConfigManager.shared.app.generalConfig.defaultAgentID
        if let id = defaultID, profiles.contains(where: { $0.id == id }) {
            return id
        }
        return profiles.first?.id ?? UUID()
    }()
    
    @MainActor static var globalPreviewImage: NSImage? {
        get { shared.previewImage }
        set { shared.previewImage = newValue }
    }
    
    var currentAgent: AgentProfile {
        ConfigManager.shared.app.agentProfiles.first(where: { $0.id == selectedAgentID })
        ?? ConfigManager.shared.app.agentProfiles.first!
    }
    
    let onClearEvent = PassthroughSubject<Void, Never>()
    var currentGenerationTask: Task<Void, Never>?
    
    private init() {
        NotificationCenter.default.addObserver(forName: NSNotification.Name("AgentProfilesExternallyUpdated"), object: nil, queue: .main) { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
    
    func stopGeneration() {
        currentGenerationTask?.cancel()
        currentGenerationTask = nil
        isLoading = false
        
        if var lastMsg = messages.last, !lastMsg.isUser, lastMsg.text.isEmpty == false {
            lastMsg.text += " 🛑 *(已手动中止)*"
            if let idx = messages.firstIndex(where: { $0.id == lastMsg.id }) {
                messages[idx] = lastMsg
            }
        }
        saveCurrentState()
    }
    
    func clearChat() {
        messages.removeAll()
        isLoading = false
        selectedImages.removeAll()
        selectedFiles.removeAll()
        currentSessionID = UUID()
        selectedPersonaID = nil
        activatedPrivateQAIDs.removeAll()
        
        blackboardPlan = nil
        AgentManager.shared.agentVM.sharedContext.removeValue(forKey: "AGENT_BLACKBOARD_PLAN")
        AgentManager.shared.agentVM.sharedContext.removeValue(forKey: "AGENT_GLOBAL_MEMO")
        
        onClearEvent.send()
    }
    
    func loadSession(_ session: ChatSession) {
        self.currentSessionID = session.id
        self.messages = session.messages.map { ChatMessage.fromSaved($0) }
        self.activatedPrivateQAIDs.removeAll()
        
        self.blackboardPlan = session.blackboardPlan
        if let plan = session.blackboardPlan, !plan.isEmpty {
            AgentManager.shared.agentVM.sharedContext["AGENT_BLACKBOARD_PLAN"] = plan
        } else {
            AgentManager.shared.agentVM.sharedContext.removeValue(forKey: "AGENT_BLACKBOARD_PLAN")
        }

        if ConfigManager.shared.app.agentProfiles.contains(where: { $0.id == session.agentID }) {
            self.selectedAgentID = session.agentID
        }
        
        if let pID = session.personaID, PersonaManager.shared.personas.contains(where: { $0.id == pID }) {
            self.selectedPersonaID = pID
        } else {
            self.selectedPersonaID = nil
        }
        
        self.isLoading = false
        self.selectedImages.removeAll()
        self.selectedFiles.removeAll()
        self.isContextEnabled = true
        onClearEvent.send()
    }
    
    func deleteMessage(id: UUID) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            messages.removeAll { $0.id == id }
        }
        saveCurrentState()
    }
    
    func updateMessage(id: UUID, action: (inout ChatMessage) -> Void) {
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            action(&messages[idx])
        }
    }
    
    func saveCurrentState() {
        guard !messages.isEmpty else { return }
        let title = messages.first(where: { $0.isUser })?.text.prefix(15) ?? "新对话"
        
        ChatHistoryManager.shared.saveSession(
            id: currentSessionID,
            title: String(title),
            agentID: selectedAgentID,
            messages: messages,
            personaID: selectedPersonaID
        )
    }
    
    func enterEditMode(for message: ChatMessage) {
        self.editingTargetMessageID = message.id
        self.inputText = message.text
        self.selectedImages = message.images
        self.selectedFiles = message.fileURLs
    }
    
    func cancelEditMode() {
        self.editingTargetMessageID = nil
        self.inputText = ""
        self.selectedImages.removeAll()
        self.selectedFiles.removeAll()
    }
    
    func prepareForEditedSend(agentVM: AgentViewModel) {
        guard let targetID = editingTargetMessageID else { return }
        if let targetIndex = messages.firstIndex(where: { $0.id == targetID }) {
            withAnimation(.easeInOut(duration: 0.3)) {
                messages.removeSubrange(targetIndex...)
            }
        }
        agentVM.sharedContext.removeValue(forKey: "AGENT_BLACKBOARD_PLAN")
        self.blackboardPlan = nil
        self.editingTargetMessageID = nil
    }
    
    func showLLMIndicator(message: String, isWarning: Bool = true, duration: TimeInterval = 4.0) {
        beaconDismissTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            self.activeBeaconAlert = LLMBeaconAlert(message: message, isWarning: isWarning)
        }
        beaconDismissTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.3)) {
                    self.activeBeaconAlert = nil
                }
            }
        }
    }
}

@MainActor
public class AiChatManager: NSObject, NSWindowDelegate {
    public static let shared = AiChatManager()
    private var window: NSWindow?
    var isVisible: Bool { return window != nil }
    private override init() { super.init() }
    
    public func show() {
        if let existingWindow = window {
            if existingWindow.isMiniaturized { existingWindow.deminiaturize(nil) }
            existingWindow.makeKeyAndOrderFront(nil)
            existingWindow.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let contentView = AiChatView(knowledgeVM: AgentManager.shared.knowledgeVM, agentVM: AgentManager.shared.agentVM)
        let hostingController = NSHostingController(rootView: contentView)
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 262, height: 750),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        newWindow.title = "AI对话"
        newWindow.contentViewController = hostingController
        newWindow.center()
        newWindow.setFrameAutosaveName("LinTools_AICHAT_Window")
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self
        self.window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        newWindow.orderFrontRegardless()
        
        NSApp.activate(ignoringOtherApps: true)
        MainWindowManager.syncDockIconPolicy()
    }
    public func windowWillClose(_ notification: Notification) {
        window = nil
        MainWindowManager.syncDockIconPolicy()
    }
}

@MainActor
class SpeechRecognizerManager: ObservableObject {
    @Published var isRecording = false
    @Published var isAuthorized = false
    
    private var audioEngine: AVAudioEngine?
    private var speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    func toggleRecording(baseText: String, onUpdate: @escaping (String) -> Void) {
        if isRecording { stopRecording() }
        else {
            if SFSpeechRecognizer.authorizationStatus() != .authorized { SFSpeechRecognizer.requestAuthorization { _ in }; return }
            startRecording(baseText: baseText, onUpdate: onUpdate)
        }
    }
    
    private func startRecording(baseText: String, onUpdate: @escaping (String) -> Void) {
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else { return }
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.inputFormat(forBus: 0)
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { return }
        recognitionRequest.shouldReportPartialResults = true
        
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { result, error in
            if let result = result {
                let recognizedText = result.bestTranscription.formattedString
                onUpdate(baseText + (baseText.isEmpty ? "" : " ") + recognizedText)
            }
            if error != nil || result?.isFinal == true { self.stopRecording() }
        }
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in self.recognitionRequest?.append(buffer) }
        audioEngine.prepare(); try? audioEngine.start(); isRecording = true
    }
    
    func stopRecording() {
        audioEngine?.stop(); audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio(); recognitionTask?.cancel()
        audioEngine = nil; recognitionRequest = nil; recognitionTask = nil; isRecording = false
    }
}

@MainActor
func openSystemImagePreview(image: NSImage, fileURL: URL? = nil) {
    if let url = fileURL, FileManager.default.fileExists(atPath: url.path) {
        NSWorkspace.shared.open(url)
        return
    }
    
    let tempDir = FileManager.default.temporaryDirectory
    let tempURL = tempDir.appendingPathComponent("preview_\(UUID().uuidString.prefix(8)).png")
    
    if let tiff = image.tiffRepresentation,
       let bitmap = NSBitmapImageRep(data: tiff),
       let pngData = bitmap.representation(using: .png, properties: [:]) {
        try? pngData.write(to: tempURL, options: .atomic)
        NSWorkspace.shared.open(tempURL)
    }
}

nonisolated func scanLocalImageFromText(_ text: String) -> (image: NSImage, url: URL)? {
    guard text.contains("screenshot_") || text.contains(".png") || text.contains(".jpg") || text.contains(".jpeg") || text.contains(".webp") else {
        return nil
    }
    
    let tokens = text.components(separatedBy: CharacterSet.whitespacesAndNewlines)
    for token in tokens {
        if (token.contains("screenshot_") || token.contains("/")) &&
           (token.hasSuffix(".png") || token.hasSuffix(".jpg") || token.hasSuffix(".jpeg") || token.hasSuffix(".webp")) {
            
            var cleanPath = token.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "/")))
            if let userRange = cleanPath.range(of: "/Users/") {
                cleanPath = String(cleanPath[userRange.lowerBound...])
            }
            
            let url = URL(fileURLWithPath: cleanPath)
            if FileManager.default.fileExists(atPath: cleanPath),
               let image = NSImage(contentsOfFile: cleanPath) {
                return (image, url)
            }
        }
    }
    return nil
}

// MARK: - ==================== 4. ChatBlockViews (基础 Markdown 块级组件) ====================

struct HeaderBlockView: View {
    let level: Int
    let text: String
    let isUser: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(MarkdownRenderCache.shared.get(from: text, isUser: isUser))
                .font(headerFont)
                .foregroundColor(.primary)
                .padding(.top, topSpacing)
                .padding(.bottom, 3)
                .textSelection(.enabled)
        }
    }
    
    private var headerFont: Font {
        switch level {
        case 1: return .system(size: 18, weight: .bold, design: .rounded)
        case 2: return .system(size: 16, weight: .bold, design: .rounded)
        case 3: return .system(size: 14.5, weight: .bold, design: .rounded)
        default: return .system(size: 13.5, weight: .semibold, design: .rounded)
        }
    }
    
    private var topSpacing: CGFloat {
        switch level {
        case 1: return 12
        case 2: return 8
        case 3: return 6
        default: return 4
        }
    }
}

struct CodeSyntaxHighlighter {
    private static let keywordsRegex = try! NSRegularExpression(
        pattern: #"\b(func|def|import|class|struct|enum|let|var|if|else|guard|return|switch|case|for|while|try|catch|async|await|SELECT|FROM|WHERE|INSERT|UPDATE|DELETE|JOIN|GROUP|BY|ORDER|LIMIT|true|false|nil|null|None)\b"#
    )
    private static let stringRegex = try! NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'"#)
    private static let commentRegex = try! NSRegularExpression(pattern: #"(?m)(//.*$|#.*$)"#)
    private static let numberRegex = try! NSRegularExpression(pattern: #"\b\d+(\.\d+)?\b"#)

    static func highlight(code: String) -> AttributedString {
        var attr = AttributedString(code)
        attr.font = Font.system(size: 12.5, weight: .regular, design: .monospaced)
        attr.foregroundColor = Color(NSColor.labelColor).opacity(0.90)
        
        let nsCode = code as NSString
        let fullRange = NSRange(location: 0, length: nsCode.length)
        
        for match in numberRegex.matches(in: code, range: fullRange) {
            if let range = Range(match.range, in: attr) {
                attr[range].foregroundColor = Color(hex: "#3B82F6")
            }
        }
        
        for match in keywordsRegex.matches(in: code, range: fullRange) {
            if let range = Range(match.range, in: attr) {
                attr[range].foregroundColor = Color(hex: "#8B5CF6")
                attr[range].font = Font.system(size: 12.5, weight: .semibold, design: .monospaced)
            }
        }
        
        for match in stringRegex.matches(in: code, range: fullRange) {
            if let range = Range(match.range, in: attr) {
                attr[range].foregroundColor = Color(hex: "#D97706")
            }
        }
        
        for match in commentRegex.matches(in: code, range: fullRange) {
            if let range = Range(match.range, in: attr) {
                attr[range].foregroundColor = Color.secondary.opacity(0.7)
            }
        }
        
        return attr
    }
}

struct CodeBlockView: View {
    var code: String
    var language: String
    @State private var isCopied = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(Color.red.opacity(0.8)).frame(width: 9, height: 9)
                    Circle().fill(Color.yellow.opacity(0.8)).frame(width: 9, height: 9)
                    Circle().fill(Color.green.opacity(0.8)).frame(width: 9, height: 9)
                }
                .padding(.trailing, 6)
                
                Text(language.isEmpty ? "Code" : language.lowercased())
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button(action: copyToClipboard) {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.clipboard")
                        Text(isCopied ? "已复制" : "复制")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isCopied ? .green : .secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
            
            Divider().opacity(0.4)
            
            Text(CodeSyntaxHighlighter.highlight(code: code))
                .padding(12)
                .lineSpacing(4.5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .background(Color(NSColor.textBackgroundColor).opacity(0.75))
        .cornerRadius(9)
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.primary.opacity(0.10), lineWidth: 0.8)
        )
        .padding(.vertical, 4)
    }
    
    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        withAnimation { isCopied = true }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { isCopied = false }
        }
    }
}

struct TableBlockView: View {
    let headers: [String]
    let rows: [[String]]
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(headers.indices, id: \.self) { i in
                        Text(headers[i]).font(.system(size: 13, weight: .bold)).padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading).background(Color(NSColor.windowBackgroundColor).opacity(0.5)).border(Color(NSColor.separatorColor), width: 0.5).fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(rows.indices, id: \.self) { r in
                    GridRow {
                        ForEach(rows[r].indices, id: \.self) { c in
                            Text(rows[r][c]).font(.system(size: 13)).padding(.horizontal, 10).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading).border(Color(NSColor.separatorColor), width: 0.5).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .background(Color(NSColor.controlBackgroundColor)).border(Color(NSColor.separatorColor), width: 1).cornerRadius(6)
        }.padding(.vertical, 6)
    }
}

struct ThinkBlockView: View {
    let content: String
    var isGenerating: Bool
    var isClosed: Bool
    
    @State private var isExpanded: Bool = false
    @State private var isHovered: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary.opacity(0.6))
                    
                    Text(dynamicTitle)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(isHovered ? .primary.opacity(0.9) : .secondary.opacity(0.8))
                        .lineLimit(1)
                    
                    Spacer()
                    
                    if isGenerating && !isClosed {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.55)
                    }
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isHovered ? Color.primary.opacity(0.04) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { h in isHovered = h }
            
            if isExpanded {
                HStack(alignment: .top, spacing: 8) {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    isClosed ? Color.secondary.opacity(0.3) : Color.purple.opacity(0.6),
                                    Color.clear
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 1.5)
                        .padding(.vertical, 2)
                    
                    Text(content)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.85))
                        .lineSpacing(4.5)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 10)
                .padding(.top, 2)
                .padding(.bottom, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 1)
        .onAppear {
            isExpanded = false
        }
        .onChange(of: isClosed) { _, closed in
            if closed {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded = false
                }
            }
        }
        .onChange(of: isGenerating) { _, generating in
            if !generating {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded = false
                }
            }
        }
    }
    
    private var dynamicTitle: String {
        if !isClosed { return "思考中..." }
        let text = content
        let lastStr: String
        if let lastNewlineIndex = text.lastIndex(of: "\n") {
            lastStr = String(text[text.index(after: lastNewlineIndex)...])
        } else {
            lastStr = text
        }
        let trimmed = lastStr.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "逻辑推演记录" }
        
        let cleanPreview = (trimmed.count > 150 ? String(trimmed.prefix(150)) + "..." : trimmed)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "##", with: "")
            .replacingOccurrences(of: "💡", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            
        return "\(cleanPreview)"
    }
}

struct TypingIndicatorView: View {
    @State private var scales: [CGFloat] = [0.5, 0.5, 0.5]
    @State private var opacities: [Double] = [0.3, 0.3, 0.3]
    
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Circle().fill(Color.cyan).frame(width: 8, height: 8).scaleEffect(scales[index]).opacity(opacities[index])
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 4).onAppear { animateDots() }
    }
    private func animateDots() {
        let animation = Animation.easeInOut(duration: 0.6).repeatForever(autoreverses: true)
        for i in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.2) {
                withAnimation(animation) { scales[i] = 1.0; opacities[i] = 1.0 }
            }
        }
    }
}

enum ActionChipType {
    case ask
    case skill
}

struct ActionChipModel: Hashable {
    let type: ActionChipType
    let payload: String
    let title: String
}

// MARK: - MessageContentView (已移除频繁监听 GeometryReader 状态震荡)
struct MessageContentView: View, Equatable {
    var messageID: UUID = UUID()
    var text: String
    var isUser: Bool
    var isGenerating: Bool
    var skillLogs: [SkillExecutionLog] = []
    var ragHits: [RAGHitLog] = []
    var onAction: ((String) -> Void)? = nil
    
    @State private var inspectingLog: SkillExecutionLog? = nil
    @State private var showInspectPopover: Bool = false
    
    @State private var inspectingRagHit: RAGHitLog? = nil
    @State private var showRagPopover: Bool = false
    
    static func == (lhs: MessageContentView, rhs: MessageContentView) -> Bool {
        return lhs.messageID == rhs.messageID &&
               lhs.text == rhs.text &&
               lhs.isGenerating == rhs.isGenerating &&
               lhs.skillLogs == rhs.skillLogs &&
               lhs.ragHits == rhs.ragHits
    }
    
    private func extractActionTags(from text: String) -> (String, [ActionChipModel]) {
        var cleanText = text
        var chips: [ActionChipModel] = []
        
        let pattern = "\\[(.*?)\\]\\(action://(ask|skill)(?:/([^)]*))?\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return (text, []) }
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: text.utf16.count))
        
        for match in matches.reversed() {
            if let range = Range(match.range, in: cleanText),
               let titleRange = Range(match.range(at: 1), in: cleanText),
               let typeRange = Range(match.range(at: 2), in: cleanText) {
                
                let title = String(cleanText[titleRange])
                let typeString = String(cleanText[typeRange])
                
                let rawPayload: String
                if match.range(at: 3).location != NSNotFound, let payloadRange = Range(match.range(at: 3), in: cleanText) {
                    rawPayload = String(cleanText[payloadRange])
                } else {
                    rawPayload = title
                }
                
                let payload = rawPayload.removingPercentEncoding ?? rawPayload
                let type: ActionChipType = (typeString == "skill") ? .skill : .ask
                let chip = ActionChipModel(type: type, payload: payload, title: title)
                
                chips.insert(chip, at: 0)
                cleanText.replaceSubrange(range, with: title)
            }
        }
        return (cleanText, chips)
    }
    
    private func splitByCardTag(_ text: String) -> [(content: String, isCard: Bool)] {
        var segments: [(content: String, isCard: Bool)] = []
        let pattern = "(?s)<card>(.*?)</card>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [(content: text, isCard: false)]
        }
        
        let nsString = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count))
        
        var lastOffset = 0
        for match in matches {
            if match.range.location > lastOffset {
                let prevRange = NSRange(location: lastOffset, length: match.range.location - lastOffset)
                let prevText = nsString.substring(with: prevRange)
                if !prevText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append((content: prevText, isCard: false))
                }
            }
            if match.range(at: 1).location != NSNotFound {
                let cardContent = nsString.substring(with: match.range(at: 1))
                segments.append((content: cardContent, isCard: true))
            }
            lastOffset = match.range.location + match.range.length
        }
        
        if lastOffset < text.utf16.count {
            let restRange = NSRange(location: lastOffset, length: text.utf16.count - lastOffset)
            let restText = nsString.substring(with: restRange)
            if !restText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append((content: restText, isCard: false))
            }
        }
        return segments.isEmpty ? [(content: text, isCard: false)] : segments
    }
    
    var body: some View {
        let parts = MessageASTCache.shared.getParsedParts(id: messageID, text: text, isGenerating: isGenerating)
        
        VStack(alignment: .leading, spacing: 6) {
            if parts.isEmpty {
                if isGenerating { TypingIndicatorView() }
                else { Text(" ").font(.system(size: 14)).foregroundColor(.secondary) }
            } else {
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    switch part.type {
                    case .header(let level):
                        HeaderBlockView(level: level, text: part.text, isUser: isUser)
                        
                    case .code(let language):
                        CodeBlockView(code: part.text, language: language)
                            .textSelection(.enabled)
                    case .table(let headers, let rows):
                        TableBlockView(headers: headers, rows: rows)
                            .textSelection(.enabled)
                    case .think(let isClosed):
                        ThinkBlockView(content: part.text, isGenerating: isGenerating, isClosed: isClosed)
                            .textSelection(.enabled)
                    case .divider:
                        HorizontalRuleBlockView()
                    case .text:
                        let (cleanText, actionChips) = extractActionTags(from: part.text)
                        let segments = splitByCardTag(cleanText)
                        
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(0..<segments.count, id: \.self) { segIdx in
                                let seg = segments[segIdx]
                                
                                if seg.isCard {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(MarkdownRenderCache.shared.get(from: seg.content, isUser: isUser))
                                            .lineSpacing(6)
                                            .multilineTextAlignment(.leading)
                                            .tint(.cyan)
                                            .textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 11)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(Color.cyan.opacity(0.07))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(Color.cyan.opacity(0.38), lineWidth: 1.5)
                                    )
                                    .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
                                    .padding(.vertical, 4)
                                    .compositingGroup()
                                } else {
                                    Text(MarkdownRenderCache.shared.get(from: seg.content, isUser: isUser))
                                        .lineSpacing(6)
                                        .multilineTextAlignment(.leading)
                                        .tint(.cyan)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .compositingGroup()
                                }
                            }
                            
                            if !actionChips.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(actionChips, id: \.self) { chip in
                                            Button(action: {
                                                if chip.type == .skill {
                                                    let systemInvokePrompt = "请直接调用此技能(tool)：\(chip.payload)。无需多余废话，直接执行。"
                                                    onAction?(systemInvokePrompt)
                                                } else {
                                                    onAction?(chip.payload)
                                                }
                                            }) {
                                                HStack(spacing: 4) {
                                                    Image(systemName: chip.type == .skill ? "wrench.and.screwdriver.fill" : "paperplane.fill")
                                                        .font(.system(size: 10))
                                                    Text(chip.title).font(.system(size: 12, weight: .bold))
                                                }
                                                .foregroundColor(chip.type == .skill ? .purple : .cyan)
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 5)
                                                .background((chip.type == .skill ? Color.purple : Color.cyan).opacity(0.15))
                                                .cornerRadius(6)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 6)
                                                        .stroke((chip.type == .skill ? Color.purple : Color.cyan).opacity(0.3), lineWidth: 1)
                                                )
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                    }
                }
            }
        }
        .popover(isPresented: $showInspectPopover, arrowEdge: .top) {
            if let log = inspectingLog {
                let isExec = log.resultOutput == "执行中..." || log.resultOutput == "等待授权..."
                let isFailed = PhysicalTruthVerifier.isExecutionFailed(toolName: log.skillName, output: log.resultOutput)
                DetailedSkillView(
                    log: log,
                    themeColor: log.executorName != nil ? .purple : (isExec ? .blue : (isFailed ? .red : .green)),
                    isExecuting: isExec
                )
            }
        }
        .popover(isPresented: $showRagPopover, arrowEdge: .top) {
            if let hit = inspectingRagHit {
                RAGChunkInspectorPopover(hit: hit)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "action" else {
                let handled = LocalLinkOpener.openSmartLink(url)
                return handled ? .handled : .systemAction
            }
            
            if url.host == "inspect_tool" {
                let targetToolName = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let queryParams = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
                let callId = queryParams?.first(where: { $0.name == "call_id" })?.value
                
                if let callId = callId, !callId.isEmpty,
                   let matchedLog = skillLogs.first(where: { $0.confirmationId == callId || $0.id.uuidString == callId }) {
                    self.inspectingLog = matchedLog
                    self.showInspectPopover = true
                    return .handled
                }
                
                if let matchedLog = skillLogs.last(where: {
                    $0.skillName.lowercased() == targetToolName.lowercased() ||
                    $0.displayName.lowercased() == targetToolName.lowercased()
                }) ?? skillLogs.last {
                    self.inspectingLog = matchedLog
                    self.showInspectPopover = true
                    return .handled
                }
            } else if url.host == "inspect_rag" {
                let hitId = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if let matchedHit = ragHits.first(where: { $0.id.uuidString == hitId || $0.title == hitId }) {
                    self.inspectingRagHit = matchedHit
                    self.showRagPopover = true
                    return .handled
                }
            }
            
            return .handled
        })
    }
}

struct HorizontalRuleBlockView: View {
    @Environment(\.colorScheme) var colorScheme
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.12))
            .frame(height: 1)
            .padding(.vertical, 8)
            .compositingGroup()
    }
}

// MARK: - ==================== 5. ChatInteractiveCards (具身工具与公证卡片) ====================

struct JsonTreeView: View {
    let value: Any
    let key: String?
    let isLast: Bool

    init(value: Any, key: String? = nil, isLast: Bool = true) {
        self.value = value
        self.key = key
        self.isLast = isLast
    }

    var body: some View {
        FastJsonViewer(value: value)
    }
}

struct FastJsonViewer: View {
    let value: Any
    
    var body: some View {
        if let dict = value as? [String: Any], !dict.isEmpty {
            let isFlat = dict.values.allSatisfy { !($0 is [String: Any]) && !($0 is [Any]) }
            if isFlat {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(dict.keys.sorted(), id: \.self) { k in
                        HStack(alignment: .top, spacing: 6) {
                            Text(k)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.indigo)
                            Text(":")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text(formatSimpleVal(dict[k]!))
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundColor(dict[k] is String ? .teal : .primary.opacity(0.9))
                                .lineLimit(6)
                                .textSelection(.enabled)
                        }
                    }
                }
            } else {
                Text(formatPrettyJSON(from: dict))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.9))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let array = value as? [Any], !array.isEmpty {
            Text(formatPrettyJSON(from: array))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.primary.opacity(0.9))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(formatSimpleVal(value))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(.teal)
                .textSelection(.enabled)
        }
    }
    
    private func formatSimpleVal(_ val: Any) -> String {
        if let s = val as? String { return "\"\(s)\"" }
        if let b = val as? Bool { return b ? "true" : "false" }
        if let n = val as? NSNumber { return "\(n)" }
        if val is NSNull { return "null" }
        return "\(val)"
    }
    
    private func formatPrettyJSON(from object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let str = String(data: data, encoding: .utf8) else {
            return "\(object)"
        }
        return str
    }
}

struct SkillConfirmationCardView: View {
    let log: SkillExecutionLog
    @State private var isResolving = false
    @State private var isArgsExpanded = true

    private struct UIConfig {
        let title: String
        let subtitle: String
        let icon: String
        let themeColor: Color
        let acceptText: String
        let rejectText: String
        let isDanger: Bool
    }
    
    private var uiConfig: UIConfig {
        let name = log.skillName.lowercased()
        if name == "system_extend_autonomy" {
            return UIConfig(
                title: "自治步数超限拦截",
                subtitle: "Agent 思考循环达到上限，是否授权继续？",
                icon: "pause.circle.fill",
                themeColor: .blue,
                acceptText: "批准延期",
                rejectText: "终止任务",
                isDanger: false
            )
        } else if name.contains("delete") || name.contains("remove") || name.contains("drop") || name.contains("clear") {
            return UIConfig(
                title: "高危破坏性操作",
                subtitle: "Agent 试图执行可能导致数据丢失的操作！",
                icon: "exclamationmark.triangle.fill",
                themeColor: .red,
                acceptText: "强制允许",
                rejectText: "安全拦截",
                isDanger: true
            )
        } else {
            return UIConfig(
                title: "系统操作授权",
                subtitle: "Agent 申请调用本地核心技能，等待您的批准",
                icon: "shield.checkerboard",
                themeColor: .orange,
                acceptText: "授权允许",
                rejectText: "拒绝执行",
                isDanger: true
            )
        }
    }

    var body: some View {
        let config = uiConfig

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: config.icon)
                    .foregroundColor(config.themeColor)
                    .font(.system(size: 18))
                    .shadow(color: config.themeColor.opacity(0.3), radius: 2, y: 1)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(config.title).font(.system(size: 13, weight: .bold)).foregroundColor(.primary)
                    Text(config.subtitle).font(.system(size: 10)).foregroundColor(.secondary)
                }
                Spacer()
                
                Text("需要介入")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(config.themeColor)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(config.themeColor.opacity(0.15))
                    .cornerRadius(6)
            }
            .padding(14)
            .background(LinearGradient(colors: [config.themeColor.opacity(0.15), config.themeColor.opacity(0.02)], startPoint: .topLeading, endPoint: .bottomTrailing))
            
            Divider().background(config.themeColor.opacity(0.2))
            
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "terminal.fill").foregroundColor(config.themeColor.opacity(0.8))
                    Text(log.displayName).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundColor(.primary)
                }
                
                if !log.args.isEmpty {
                    if log.args.count == 1, let singleValue = log.args.values.first as? String {
                        Text(singleValue)
                            .font(.system(size: 12))
                            .lineSpacing(4)
                            .foregroundColor(.primary.opacity(0.9))
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(NSColor.textBackgroundColor).opacity(0.6))
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(config.themeColor.opacity(0.1), lineWidth: 1))
                    } else {
                        Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isArgsExpanded.toggle() } }) {
                            HStack(spacing: 4) {
                                Image(systemName: isArgsExpanded ? "chevron.down" : "chevron.right").font(.system(size: 10))
                                Text(isArgsExpanded ? "隐藏执行参数" : "查看执行参数 (\(log.args.count)个)").font(.system(size: 11))
                            }.foregroundColor(config.themeColor)
                        }.buttonStyle(.plain).padding(.top, 2)
                        
                        if isArgsExpanded {
                            JsonTreeView(value: log.args)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(NSColor.textBackgroundColor).opacity(0.6))
                                .cornerRadius(8)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(config.themeColor.opacity(0.1), lineWidth: 1))
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                } else {
                    Text("该操作不包含附加参数").font(.system(size: 11)).foregroundColor(.secondary).italic()
                }
            }
            .padding(14)
            
            Divider().background(config.themeColor.opacity(0.1))
            
            HStack(spacing: 16) {
                Button(action: { resolve(false) }) {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                        Text(config.rejectText)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(config.isDanger ? .red : .primary)
                .disabled(isResolving)
                
                Button(action: { resolve(true) }) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                        Text(config.acceptText)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(config.themeColor)
                .controlSize(.large)
                .disabled(isResolving)
            }
            .padding(14)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.4))
        }
        .background(.regularMaterial)
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(config.themeColor.opacity(0.2), lineWidth: 1))
        .shadow(color: config.themeColor.opacity(0.08), radius: 8, x: 0, y: 4)
        .padding(.vertical, 4)
    }

    private func resolve(_ allow: Bool) {
        isResolving = true
        guard let confirmId = log.confirmationId else { return }
        Task { await UserInteractionManager.shared.resolvePermission(id: confirmId, allow: allow) }
    }
}

struct TaskCompletionCardView: View {
    let log: SkillExecutionLog
    let totalToolCalls: Int
    var totalTokens: Int = 0
    var duration: TimeInterval = 0.0
    
    let onConfirm: () -> Void
    let onRetry: (String) -> Void
    
    @State private var isConfirmed = false
    @State private var showRetryInput = false
    @State private var retryText = ""
    @State private var isCopied = false
    
    var body: some View {
        let finalStatus = (log.args["status"] as? String ?? "success").lowercased()
        let isSuccess = finalStatus == "success" || finalStatus == "成功"
        
        let themeColor = isSuccess ? Color.green : Color.red
        let bgGradient = LinearGradient(colors: [themeColor.opacity(0.15), themeColor.opacity(0.02)], startPoint: .topLeading, endPoint: .bottomTrailing)
        let iconName = isSuccess ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
        let titleText = isSuccess ? "任务执行成功" : "任务执行失败 / 中止"
        let subtitleText = isSuccess ? "已达到目标并输出最终结果" : "任务遇到阻碍，已输出失败原因或中止记录"
        
        let finalAnswer = (log.args["final_answer"] as? String) ?? log.resultOutput
        let contentToDisplay = finalAnswer.isEmpty ? "任务执行完毕，无文本返回" : finalAnswer
        
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .foregroundColor(themeColor)
                    .font(.system(size: 20, weight: .semibold))
                    .shadow(color: themeColor.opacity(0.4), radius: 3, x: 0, y: 2)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(titleText)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.primary)
                    Text(subtitleText)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
                
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Image(systemName: "wrench.and.screwdriver.fill")
                        Text("\(totalToolCalls)次")
                    }
                    .foregroundColor(.secondary)
                    
                    if totalTokens > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "bolt.horizontal.circle.fill")
                            Text("\(formatTokens(totalTokens)) T")
                            Text("(\(calculateCost(totalTokens)))")
                                .foregroundColor(themeColor.opacity(0.9))
                        }
                    }
                    
                    if duration > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "timer")
                            Text(String(format: "%.1fs", duration))
                        }
                        .foregroundColor(.secondary)
                    }
                }
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .padding(14)
            .background(bgGradient)
            
            Divider().background(themeColor.opacity(0.2))
            
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(isSuccess ? "最终成果输出：" : "失败原因与分析：")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(isSuccess ? .secondary : .red.opacity(0.8))
                    Spacer()
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(contentToDisplay, forType: .string)
                        withAnimation { isCopied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { isCopied = false } }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: isCopied ? "checkmark" : "doc.on.clipboard")
                            Text(isCopied ? "已复制" : "一键复制")
                        }.font(.system(size: 11)).foregroundColor(isCopied ? themeColor : .cyan)
                    }.buttonStyle(.plain)
                }
                
                MessageContentView(
                    text: contentToDisplay,
                    isUser: false,
                    isGenerating: false,
                    onAction: { instruction in
                        onRetry(instruction)
                    }
                )
                .padding(12)
                .background(Color(NSColor.textBackgroundColor).opacity(0.6))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(themeColor.opacity(0.1), lineWidth: 1))
                .textSelection(.enabled)
            }
            .padding(14)
            
            Divider().background(themeColor.opacity(0.1))
            
            if isConfirmed {
                HStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "archivebox.fill").foregroundColor(themeColor)
                    Text("任务已归档，执行流闭环完成").font(.system(size: 13, weight: .bold)).foregroundColor(themeColor)
                    Spacer()
                }
                .padding(16)
                .background(themeColor.opacity(0.05))
                .transition(.opacity)
            } else {
                VStack(spacing: 12) {
                    if showRetryInput {
                        HStack(spacing: 8) {
                            TextField(isSuccess ? "输入追加指令或修正意见..." : "输入修正策略或指导意见，让 AI 重试...", text: $retryText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))
                            
                            Button(action: {
                                onRetry(retryText)
                                withAnimation { showRetryInput = false; retryText = "" }
                            }) { Text("提交重试").fontWeight(.bold) }
                            .buttonStyle(.borderedProminent)
                            .tint(isSuccess ? .orange : .red)
                            .controlSize(.regular)
                            .disabled(retryText.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    
                    HStack(spacing: 16) {
                        Button(action: { withAnimation(.spring()) { showRetryInput.toggle() } }) {
                            HStack {
                                Image(systemName: isSuccess ? "arrow.uturn.backward.circle" : "stethoscope")
                                Text(isSuccess ? "发现问题，打回重做" : "提供策略，强制重启")
                            }.frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered).controlSize(.large)
                        
                        Button(action: { withAnimation(.spring()) { isConfirmed = true; onConfirm() } }) {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                Text(isSuccess ? "确认并结束任务" : "知悉失败并归档")
                            }.frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).tint(themeColor).controlSize(.large)
                    }
                }
                .padding(14)
                .background(Color(NSColor.windowBackgroundColor).opacity(0.4))
            }
        }
        .background(.regularMaterial)
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(themeColor.opacity(0.2), lineWidth: 1))
        .shadow(color: themeColor.opacity(0.08), radius: 8, x: 0, y: 4)
        .padding(.vertical, 4)
    }
    
    private func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1000 {
            return String(format: "%.1fk", Double(tokens) / 1000.0)
        }
        return "\(tokens)"
    }
    
    private func calculateCost(_ tokens: Int) -> String {
        let cost = Double(tokens) / 1000.0 * 0.002
        return cost < 0.001 ? "<$0.001" : String(format: "$%.3f", cost)
    }
}

struct DetailedSkillView: View {
    let log: SkillExecutionLog
    let themeColor: Color
    let isExecuting: Bool
    
    @State private var detectedImage: NSImage? = nil
    @State private var detectedURL: URL? = nil
    @State private var isCopied: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .foregroundColor(themeColor)
                    .font(.system(size: 12))
                
                Text(log.displayName)
                    .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                    .foregroundColor(.primary)
                
                Spacer()
                
                if isExecuting {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("计算中").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                }
                
                Button(action: copyAllDetails) {
                    HStack(spacing: 3) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.clipboard")
                        Text(isCopied ? "已复制" : "一键复制")
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(isCopied ? .green : themeColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background((isCopied ? Color.green : themeColor).opacity(0.12))
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(themeColor.opacity(0.06))
            
            Divider()
            
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: "tray.and.arrow.down")
                            Text("输入参数").fontWeight(.bold)
                        }
                        .font(.system(size: 11, design: .rounded))
                        .foregroundColor(.secondary)
                        
                        if !log.args.isEmpty {
                            FastJsonViewer(value: log.args)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(NSColor.textBackgroundColor).opacity(0.6))
                                .cornerRadius(7)
                        } else {
                            Text("无附加参数")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary.opacity(0.6))
                                .italic()
                        }
                    }
                    
                    if let img = detectedImage {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 4) {
                                Image(systemName: "photo")
                                Text("捕获的图像").fontWeight(.bold)
                            }
                            .font(.system(size: 11, design: .rounded))
                            .foregroundColor(.secondary)
                            
                            Image(nsImage: img)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 160)
                                .cornerRadius(7)
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.1), lineWidth: 1))
                                .onTapGesture {
                                    openSystemImagePreview(image: img, fileURL: detectedURL)
                                }
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: "tray.and.arrow.up")
                            Text("执行结果").fontWeight(.bold)
                        }
                        .font(.system(size: 11, design: .rounded))
                        .foregroundColor(.secondary)
                        
                        if log.skillName == "knowledge_search" && log.resultOutput.contains("<knowledge_chunk") {
                            KnowledgeSearchResultBubbleView(log: log)
                                .padding(10)
                                .background(Color(NSColor.textBackgroundColor).opacity(0.6))
                                .cornerRadius(7)
                        } else {
                            let resultText = log.resultOutput.isEmpty ? "(等待返回)" : log.resultOutput
                            Text(resultText)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundColor(log.resultOutput.contains("❌") ? .pink : .primary.opacity(0.9))
                                .lineSpacing(3.5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(10)
                                .background(Color(NSColor.textBackgroundColor).opacity(0.6))
                                .cornerRadius(7)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 480, height: 350)
        .background(.regularMaterial)
        .task(id: log.id) {
            let textToScan = "\(log.resultOutput) \(log.args)"
            guard textToScan.contains("screenshot_") || textToScan.contains(".png") || textToScan.contains(".jpg") else { return }
            
            let result = await Task.detached(priority: .userInitiated) {
                return scanLocalImageFromText(textToScan)
            }.value
            
            if let (img, url) = result {
                await MainActor.run {
                    self.detectedImage = img
                    self.detectedURL = url
                }
            }
        }
    }
    
    private func copyAllDetails() {
        let text = """
        【工具名称】: \(log.displayName) (\(log.skillName))
        【输入参数】: \(log.args)
        【执行结果】:
        \(log.resultOutput)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation { isCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { isCopied = false } }
    }
}

struct TimelineNodeView: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String
    let isLast: Bool
    
    var logToInspect: SkillExecutionLog? = nil
    @State private var showPopover = false
    
    var body: some View {
        Button(action: {
            if logToInspect != nil { showPopover.toggle() }
        }) {
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 0) {
                    Circle()
                        .stroke(color.opacity(0.8), lineWidth: 2)
                        .background(Circle().fill(color.opacity(0.2)))
                        .frame(width: 10, height: 10)
                        .overlay(Image(systemName: icon).font(.system(size: 6, weight: .bold)).foregroundColor(color))
                    
                    if !isLast {
                        Rectangle().fill(Color.primary.opacity(0.2)).frame(width: 2).padding(.top, 2).padding(.bottom, -12)
                    }
                }.padding(.top, 4)
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if let executor = logToInspect?.executorName {
                            Text(executor)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.purple)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.purple.opacity(0.15))
                                .cornerRadius(4)
                        }
                        
                        Text(title).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(.primary.opacity(0.9))
                    }
                    Text(subtitle).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            if let log = logToInspect {
                let isExec = log.resultOutput == "执行中..."
                DetailedSkillView(log: log, themeColor: log.executorName != nil ? .purple : (isExec ? .blue : (log.resultOutput.contains("❌") ? .red : .green)), isExecuting: isExec)
            }
        }
    }
}

struct AgentActionTimelineView: View {
    let skillLogs: [SkillExecutionLog]
    var isGenerating: Bool = false
    
    @State private var isExpanded = false
    @State private var hoveredLogId: UUID? = nil
    
    private var activeLog: SkillExecutionLog? {
        skillLogs.last
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isGenerating && activeLog?.resultOutput == "执行中..." {
                dynamicRollingTickerView
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    ))
            } else {
                restingHeaderView
            }
            
            if isExpanded && !skillLogs.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Divider().opacity(0.3).padding(.vertical, 2)
                    
                    ForEach(Array(skillLogs.enumerated()), id: \.element.id) { index, log in
                        let isLast = index == skillLogs.count - 1
                        
                        if log.confirmationId != nil && log.resultOutput == "等待授权..." {
                            SkillConfirmationCardView(log: log).padding(.bottom, isLast ? 0 : 6)
                        } else {
                            let isExec = log.resultOutput == "执行中..." || log.resultOutput.hasPrefix("思考中...")
                            let isErr = PhysicalTruthVerifier.isExecutionFailed(toolName: log.skillName, output: log.resultOutput)
                            let isTextOutput = log.skillName == "sub_agent_thought"
                            let icon = isTextOutput ? "bubble.left.and.bubble.right.fill" : (isExec ? "bolt.badge.clock.fill" : (isErr ? "exclamationmark.triangle.fill" : "terminal.fill"))
                            let color: Color = log.executorName != nil ? .purple : (isExec ? .blue : (isErr ? .red : .green))
                            
                            let displaySubtitle = (log.skillName == "knowledge_search" && log.resultOutput.contains("<knowledge_chunk"))
                                ? "✅ 成功召回 \(RAGXMLParser.extractHits(from: log.resultOutput).count) 个知识切片"
                                : log.resultOutput
                            
                            TimelineNodeView(icon: icon, color: color, title: log.displayName, subtitle: displaySubtitle, isLast: isLast, logToInspect: log)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(.ultraThinMaterial)
        .cornerRadius(9)
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
        )
        .padding(.bottom, 6)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isExpanded)
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: skillLogs.count)
    }
    
    private var dynamicRollingTickerView: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(Color.purple.opacity(0.15)).frame(width: 20, height: 20)
                ProgressView().controlSize(.mini).tint(.purple)
            }
            
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text("Agent 正在调度").font(.system(size: 9.5, weight: .bold)).foregroundColor(.purple)
                    Text("•").font(.system(size: 8)).foregroundColor(.secondary)
                    Text(activeLog?.displayName ?? "物理动作").font(.system(size: 11, weight: .bold)).foregroundColor(.primary)
                }
                
                Text(activeLog?.resultOutput ?? "执行中...")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            Text("\(skillLogs.count) 步")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.purple)
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(Color.purple.opacity(0.12))
                .cornerRadius(4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
    
    private var restingHeaderView: some View {
        Button(action: { isExpanded.toggle() }) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.down.right.fill")
                    .foregroundColor(.purple.opacity(0.85))
                    .font(.system(size: 12))
                
                if let last = activeLog {
                    let subtitle = (last.skillName == "knowledge_search" && last.resultOutput.contains("<knowledge_chunk"))
                        ? "成功召回 \(RAGXMLParser.extractHits(from: last.resultOutput).count) 个知识切片"
                        : (last.resultOutput.count > 30 ? String(last.resultOutput.prefix(30)) + "..." : last.resultOutput)
                    
                    HStack(spacing: 4) {
                        Text(last.displayName)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.primary)
                        Text("·")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                        Text(subtitle)
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text("Agent 执行流 (0)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                HStack(spacing: 4) {
                    Text("共 \(skillLogs.count) 步")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary.opacity(0.8))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct RAGHitsBottomView: View {
    let ragHits: [RAGHitLog]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().background(Color.primary.opacity(0.1)).padding(.vertical, 4)
            HStack(spacing: 6) {
                Image(systemName: "books.vertical.fill").font(.system(size: 10)).foregroundColor(.cyan)
                Text("知识库检索召回 (\(ragHits.count))").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
            }
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ragHits) { hit in
                        RAGHitChipButton(hit: hit)
                    }
                }
            }
        }
        .padding(.top, 2)
    }
}

struct RAGHitChipButton: View {
    let hit: RAGHitLog
    @State private var isHovered = false
    @State private var showDetailPopover = false
    
    var body: some View {
        Button(action: { showDetailPopover.toggle() }) {
            HStack(spacing: 5) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.cyan.opacity(0.85))
                Text(hit.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary.opacity(0.9))
                    .lineLimit(1)
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 9))
                    .foregroundColor(.cyan.opacity(0.7))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .background(isHovered ? Color.cyan.opacity(0.18) : Color.primary.opacity(0.06))
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.cyan.opacity(0.35), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .onHover { h in isHovered = h }
        .popover(isPresented: $showDetailPopover, arrowEdge: .bottom) {
            RAGChunkInspectorPopover(hit: hit)
        }
        .help("点击直接查看本轮命中的切片文本详情")
    }
}

struct RAGChunkInspectorPopover: View {
    let hit: RAGHitLog
    @State private var isCopied = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(Color.cyan.opacity(0.15)).frame(width: 24, height: 24)
                    Image(systemName: "books.vertical.fill").font(.system(size: 11, weight: .bold)).foregroundColor(.cyan)
                }
                
                VStack(alignment: .leading, spacing: 1) {
                    Text(hit.title).font(.system(size: 12.5, weight: .bold)).lineLimit(1)
                    if !hit.path.isEmpty {
                        Text(hit.path).font(.system(size: 9.5)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                
                Spacer()
                
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(hit.content, forType: .string)
                    withAnimation { isCopied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { isCopied = false } }
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.clipboard")
                        Text(isCopied ? "已复制" : "复制切片")
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(isCopied ? .green : .cyan)
                    .padding(.horizontal, 7).padding(.vertical, 3.5)
                    .background((isCopied ? Color.green : Color.cyan).opacity(0.12))
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(Color.cyan.opacity(0.06))
            
            Divider()
            
            ScrollView(.vertical, showsIndicators: true) {
                Text(hit.content.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.9))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            if !hit.path.isEmpty && FileManager.default.fileExists(atPath: hit.path) {
                Divider()
                HStack {
                    Spacer()
                    Button(action: { NSWorkspace.shared.selectFile(hit.path, inFileViewerRootedAtPath: "") }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.forward.app")
                            Text("在访达中定位源文件")
                        }
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.primary.opacity(0.02))
            }
        }
        .frame(width: 440, height: 320)
        .background(.ultraThinMaterial)
    }
}

struct ToolCardBubbleView: View {
    let log: SkillExecutionLog
    let parentContent: String
    var onAction: ((String) -> Void)? = nil
    
    @State private var isExpanded: Bool = false
    @State private var isImageHovered: Bool = false
    @State private var detectedImage: NSImage? = nil
    @State private var detectedURL: URL? = nil
    
    private var hasCustomTemplate: Bool {
        return !log.uiTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(hasCustomTemplate ? Color.indigo.opacity(0.15) : Color(NSColor.controlAccentColor).opacity(0.15))
                        .frame(width: 28, height: 28)
                    Image(systemName: hasCustomTemplate ? "wand.and.stars" : "cube.box.fill")
                        .foregroundColor(hasCustomTemplate ? .indigo : Color(NSColor.controlAccentColor))
                        .font(.system(size: 13, weight: .bold))
                }
                Text(log.displayName.isEmpty ? log.skillName : log.displayName).font(.system(size: 13, weight: .bold))
                Spacer()
                if hasCustomTemplate {
                    Button(action: { withAnimation(.spring()) { isExpanded.toggle() } }) {
                        Image(systemName: "curlybraces").font(.system(size: 10)).foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                } else {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(isExpanded ? 90 : 0)).font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            .padding(12)
            .contentShape(Rectangle())
            .onTapGesture { if !hasCustomTemplate { withAnimation(.spring()) { isExpanded.toggle() } } }
            
            if hasCustomTemplate {
                Divider().opacity(0.5)
                let renderedContent = log.uiTemplate.renderDynamicTemplate(
                    args: log.args,
                    output: log.resultOutput,
                    content: parentContent
                )
                
                MessageContentView(text: renderedContent, isUser: false, isGenerating: false, onAction: onAction)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
                
                if isExpanded {
                    Divider().opacity(0.5)
                    rawJsonDebuggerView.padding(12).background(Color(NSColor.textBackgroundColor).opacity(0.8))
                }
            } else if log.skillName == "knowledge_search" && log.resultOutput.contains("<knowledge_chunk") {
                Divider().opacity(0.5)
                KnowledgeSearchResultBubbleView(log: log)
                    .padding(12)
                    .background(Color(NSColor.windowBackgroundColor).opacity(0.3))
                
                if isExpanded {
                    Divider().opacity(0.5)
                    rawJsonDebuggerView.padding(12).background(Color(NSColor.textBackgroundColor).opacity(0.8))
                }
            } else if isExpanded || !log.resultOutput.isEmpty {
                Divider().opacity(0.5)
                rawJsonDebuggerView.padding(12).background(Color(NSColor.windowBackgroundColor).opacity(0.3))
            }
            
            if let image = detectedImage {
                VStack(alignment: .leading, spacing: 6) {
                    Divider().opacity(0.3)
                    
                    HStack(spacing: 6) {
                        Image(systemName: "photo.fill").font(.system(size: 11)).foregroundColor(.cyan)
                        Text("捕获的屏幕图像").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                        Spacer()
                        Text("点击用系统默认应用预览").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    
                    ZStack(alignment: .bottomTrailing) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 140)
                            .cornerRadius(8)
                            .shadow(color: Color.black.opacity(0.12), radius: 4, x: 0, y: 2)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.cyan.opacity(0.3), lineWidth: 1))
                        
                        Image(systemName: "arrow.up.forward.app.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(6)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                            .padding(6)
                    }
                    .scaleEffect(isImageHovered ? 1.02 : 1.0)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        openSystemImagePreview(image: image, fileURL: detectedURL)
                    }
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.15)) { isImageHovered = hovering }
                        if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                }
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(hasCustomTemplate ? Color.indigo.opacity(0.2) : Color(NSColor.separatorColor).opacity(0.6), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.04), radius: 4, x: 0, y: 2)
        .task(id: log.id) {
            let textToScan = "\(log.resultOutput) \(log.args)"
            guard textToScan.contains("screenshot_") || textToScan.contains(".png") || textToScan.contains(".jpg") else { return }
            
            let result = await Task.detached(priority: .userInitiated) {
                return scanLocalImageFromText(textToScan)
            }.value
            
            if let (img, url) = result {
                await MainActor.run {
                    self.detectedImage = img
                    self.detectedURL = url
                }
            }
        }
    }
    
    @ViewBuilder
    private var rawJsonDebuggerView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !log.args.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("INPUT")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary)
                    
                    Text(formatJSON(from: log.args))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(NSColor.labelColor))
                        .lineSpacing(4)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 1))
                }
            }
            
            if !log.resultOutput.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("OUTPUT")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary)
                    
                    Text(prettifyOutputString(log.resultOutput))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(NSColor.labelColor))
                        .lineSpacing(4)
                        .lineLimit(isExpanded || hasCustomTemplate ? nil : 4)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 1))
                }
            }
        }
    }
    
    private func formatJSON(from dictionary: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let jsonString = String(data: data, encoding: .utf8) else { return "{}" }
        return jsonString
    }
    
    private func prettifyOutputString(_ output: String) -> String {
        let cleanOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if (cleanOutput.hasPrefix("{") && cleanOutput.hasSuffix("}")) || (cleanOutput.hasPrefix("[") && cleanOutput.hasSuffix("]")) {
            if let data = cleanOutput.data(using: .utf8),
               let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
               let prettyData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
               let prettyString = String(data: prettyData, encoding: .utf8) { return prettyString }
        }
        return cleanOutput
    }
}

struct KnowledgeSearchResultBubbleView: View {
    let log: SkillExecutionLog
    @State private var isCopied = false
    
    var body: some View {
        let hitItems = RAGXMLParser.extractHits(from: log.resultOutput)
        let topK = ConfigManager.shared.app.generalConfig.ragTopK
        
        VStack(alignment: .leading, spacing: 10) {
            if hitItems.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.magnifyingglass")
                    Text("未召回任何有效知识切片，目标 Top-K: \(topK)。Agent 将依靠基础模型能力作答。")
                }
                .font(.system(size: 11))
                .foregroundColor(.orange)
            } else {
                HStack(alignment: .center) {
                    HStack(spacing: 6) {
                        Image(systemName: "books.vertical.fill").foregroundColor(.cyan)
                        Text("成功召回 \(hitItems.count) 个知识切片 (目标 Top-K: \(topK))：").font(.system(size: 11, weight: .bold))
                    }
                    .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(log.resultOutput, forType: .string)
                        withAnimation { isCopied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { isCopied = false } }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: isCopied ? "checkmark" : "doc.on.clipboard")
                            Text(isCopied ? "已复制" : "复制原结果")
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(isCopied ? .green : .cyan)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(isCopied ? Color.green.opacity(0.15) : Color.cyan.opacity(0.1))
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(hitItems) { hit in
                        KnowledgeHitRowView(hit: hit)
                    }
                }
            }
        }
    }
}

struct KnowledgeHitRowView: View {
    let hit: RAGXMLParser.HitItem
    @State private var isExpanded: Bool = false
    @State private var isHovered: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "doc.text.viewfinder")
                    .foregroundColor(.cyan.opacity(0.8))
                    .padding(.top, 2)
                
                Text(hit.title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                Spacer()
                
                Text(String(format: "%.4f", hit.score))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(scoreColor(hit.score).opacity(0.15))
                    .foregroundColor(scoreColor(hit.score))
                    .cornerRadius(4)
                
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(.top, 3)
                    .padding(.leading, 2)
            }
            
            if !hit.tags.isEmpty || !hit.prohibited.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(hit.tags, id: \.self) { tag in
                            HStack(spacing: 3) {
                                Image(systemName: "tag.fill").font(.system(size: 8))
                                Text(tag).font(.system(size: 9, weight: .medium))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.cyan.opacity(0.15))
                            .foregroundColor(.cyan)
                            .cornerRadius(4)
                        }
                        
                        ForEach(hit.prohibited, id: \.self) { proh in
                            HStack(spacing: 3) {
                                Image(systemName: "nosign").font(.system(size: 8))
                                Text(proh).font(.system(size: 9, weight: .medium))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red.opacity(0.12))
                            .foregroundColor(.red)
                            .cornerRadius(4)
                        }
                    }
                }
                .padding(.leading, 20)
                .padding(.top, 1)
            }
            
            if isExpanded {
                Divider().opacity(0.3).padding(.vertical, 2)
                
                Text(hit.rawContent.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.85))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
                    .padding(.bottom, 4)
            } else {
                Text(hit.snippet)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor).opacity(isHovered ? 0.8 : 0.6))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isExpanded ? Color.cyan.opacity(0.4) : Color.primary.opacity(0.08), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isExpanded.toggle()
            }
        }
        .onHover { hover in
            withAnimation(.easeInOut(duration: 0.2)) { isHovered = hover }
            if hover { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
    
    private func scoreColor(_ score: Float) -> Color {
        if score >= 0.8 { return .green }
        if score >= 0.5 { return .orange }
        return .red
    }
}

// MARK: - ==================== 6. ChatInputComponents (输入法交互与光标浮窗) ====================

struct NativeMacTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var dynamicHeight: CGFloat
    @Binding var caretRect: CGRect
    
    var onSubmit: () -> Void
    var onPasteImages: ([NSImage]) -> Void
    var onPasteFiles: ([URL]) -> Void
    
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        sv.drawsBackground = false
        sv.hasVerticalScroller = true
        sv.borderType = .noBorder
        
        let tv = CustomTextView()
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: 14)
        tv.delegate = context.coordinator
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.onPasteMedia = context.coordinator.handleMediaPaste
        
        sv.documentView = tv
        return sv
    }
    
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? CustomTextView else { return }
        guard !tv.hasMarkedText() else { return }
        
        if tv.string != text {
            tv.string = text
            DispatchQueue.main.async {
                let newHeight = context.coordinator.calculateHeight(for: tv)
                if self.dynamicHeight != newHeight {
                    self.dynamicHeight = newHeight
                }
                context.coordinator.updateCaretRect(for: tv)
            }
        }
    }
    
    class CustomTextView: NSTextView {
        var onPasteMedia: (() -> Bool)?
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "v" {
                if let h = onPasteMedia, h() { return true }
            }
            return super.performKeyEquivalent(with: event)
        }
    }
    
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeMacTextView
        init(_ parent: NativeMacTextView) { self.parent = parent }
        
        func calculateHeight(for tv: NSTextView) -> CGFloat {
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return 22 }
            lm.ensureLayout(for: tc)
            return min(max(lm.usedRect(for: tc).height + tv.textContainerInset.height * 2, 22), 106)
        }
        
        func updateCaretRect(for tv: NSTextView) {
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            let selectedLocation = tv.selectedRange().location
            let safeLocation = max(0, min(selectedLocation, tv.string.utf16.count))
            let glyphIndex = lm.glyphIndexForCharacter(at: safeLocation)
            
            var rect = lm.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 0), in: tc)
            rect.origin.x += tv.textContainerInset.width
            rect.origin.y += tv.textContainerInset.height
            if rect.height <= 0 { rect.size.height = 18 }
            if rect.width <= 0 { rect.size.width = 2 }
            
            DispatchQueue.main.async {
                if self.parent.caretRect != rect {
                    self.parent.caretRect = rect
                }
            }
        }
        
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            DispatchQueue.main.async {
                if self.parent.text != tv.string {
                    self.parent.text = tv.string
                }
                let newHeight = self.calculateHeight(for: tv)
                if self.parent.dynamicHeight != newHeight {
                    self.parent.dynamicHeight = newHeight
                }
                self.updateCaretRect(for: tv)
            }
        }
        
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            updateCaretRect(for: tv)
        }
        
        func textView(_ tv: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                if let e = NSApp.currentEvent, e.modifierFlags.contains(.shift) || e.modifierFlags.contains(.option) {
                    return false
                }
                parent.onSubmit()
                return true
            }
            return false
        }
        
        func handleMediaPaste() -> Bool {
            let pb = NSPasteboard.general
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
                var imgs = [URL](), files = [URL]()
                for u in urls {
                    if ["png", "jpg", "jpeg", "gif"].contains(u.pathExtension.lowercased()) { imgs.append(u) }
                    else { files.append(u) }
                }
                if !imgs.isEmpty { parent.onPasteImages(imgs.compactMap { NSImage(contentsOf: $0) }) }
                if !files.isEmpty { parent.onPasteFiles(files) }
                return true
            }
            if let imgs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage], !imgs.isEmpty {
                parent.onPasteImages(imgs)
                return true
            }
            return false
        }
    }
}

struct StreamingRingView: View {
    @State private var rotation: Double = 0.0
    var body: some View {
        Circle()
            .stroke(AngularGradient(gradient: Gradient(colors: [.red, .orange, .clear, .clear, .red]), center: .center, angle: .degrees(rotation)), lineWidth: 2)
            .frame(width: 44, height: 44).blur(radius: 1.5)
            .onAppear { withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) { rotation = 360.0 } }
    }
}

struct ChatInputAreaView: View {
    @ObservedObject var store: AiChatStore
    @ObservedObject var speechManager: SpeechRecognizerManager
    @Binding var micPulsing: Bool
    let onSend: (String) -> Void
    let onCancel: () -> Void
    
    @State private var inputHeight: CGFloat = 22
    @State private var caretRect: CGRect = .zero
    
    @State private var showAgentMentionMenu: Bool = false
    @State private var mentionFilterText: String = ""
    
    @State private var showOptionHashMenu: Bool = false
    @State private var optionHashFilterText: String = ""
    
    private var optionManager: TextOptionManager { .shared }
    
    init(
        store: AiChatStore,
        speechManager: SpeechRecognizerManager,
        micPulsing: Binding<Bool>,
        onSend: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.store = store
        self.speechManager = speechManager
        self._micPulsing = micPulsing
        self.onSend = onSend
        self.onCancel = onCancel
    }
    
    var canSend: Bool {
        return (!store.inputText.trimmingCharacters(in: .whitespaces).isEmpty || !store.selectedImages.isEmpty || !store.selectedFiles.isEmpty) && !store.isLoading
    }
    
    private var filteredMentionAgents: [AgentProfile] {
        let all = ConfigManager.shared.app.agentProfiles
        if mentionFilterText.isEmpty { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(mentionFilterText) }
    }
    
    private var filteredOptions: [TextOptionItem] {
        optionManager.searchOptions(keyword: optionHashFilterText)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if store.editingTargetMessageID != nil {
                editingBannerView
            }
            
            HStack(spacing: 12) {
                Button(action: { store.isContextEnabled.toggle() }) {
                    Image(systemName: "link")
                        .font(.system(size: 16))
                        .foregroundColor(store.isContextEnabled ? .blue : .secondary)
                        .opacity(store.isContextEnabled ? 1.0 : 0.5)
                }
                .buttonStyle(.plain)
                .disabled(store.isLoading)
                .help(store.isContextEnabled ? "已开启连续对话上下文" : "已关闭连续对话，当前为单条独立提问")
                
                Button(action: selectFile) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(store.isLoading)
                .help("添加附件或图片")
                
                HStack(alignment: .bottom, spacing: 8) {
                    VStack(alignment: .leading, spacing: 6) {
                        ZStack(alignment: .topLeading) {
                            if store.inputText.isEmpty {
                                Text(speechManager.isRecording ? "正在聆听..." : "输入问题，用 @ 召唤专家，用 # 插入预设选项...")
                                    .foregroundColor(.secondary.opacity(0.7))
                                    .font(.system(size: 14))
                                    .padding(.top, 2)
                                    .padding(.leading, 4)
                                    .allowsHitTesting(false)
                            }
                            
                            NativeMacTextView(
                                text: $store.inputText,
                                dynamicHeight: $inputHeight,
                                caretRect: $caretRect,
                                onSubmit: { if canSend { executeSend() } },
                                onPasteImages: { imgs in Task { @MainActor in store.selectedImages.append(contentsOf: imgs) } },
                                onPasteFiles: { urls in Task { @MainActor in store.selectedFiles.append(contentsOf: urls) } }
                            )
                            .frame(height: inputHeight)
                            
                            Color.clear
                                .frame(width: max(caretRect.width, 2), height: max(caretRect.height, 16))
                                .offset(x: max(0, caretRect.origin.x), y: max(0, caretRect.origin.y))
                                .popover(isPresented: $showOptionHashMenu, arrowEdge: .top) {
                                    OptionHashPopoverBubbleView(
                                        options: filteredOptions,
                                        onSelect: { optionText in
                                            insertOptionReplacement(optionText)
                                            showOptionHashMenu = false
                                        },
                                        onOpenFolder: { optionManager.openInFinder() },
                                        onClose: { showOptionHashMenu = false }
                                    )
                                }
                                .popover(isPresented: $showAgentMentionMenu, arrowEdge: .top) {
                                    AgentMentionPopoverBubbleView(
                                        agents: filteredMentionAgents,
                                        onSelect: { profileName in
                                            insertMention(profileName: profileName)
                                            showAgentMentionMenu = false
                                        },
                                        onClose: { showAgentMentionMenu = false }
                                    )
                                }
                        }
                    }
                    
                    Button(action: { speechManager.toggleRecording(baseText: store.inputText) { store.inputText = $0 } }) {
                        ZStack {
                            if speechManager.isRecording {
                                Circle().fill(Color.red.opacity(0.3)).frame(width: 20, height: 20).scaleEffect(micPulsing ? 1.5 : 0.8).opacity(micPulsing ? 0 : 1).onAppear { withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { micPulsing = true } }.onDisappear { micPulsing = false }
                            }
                            Image(systemName: speechManager.isRecording ? "mic.fill" : "mic").font(.system(size: 14, weight: .medium)).foregroundColor(speechManager.isRecording ? .red : .secondary)
                        }
                        .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isLoading)
                    .padding(.bottom, 2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(16)
                
                Button(action: {
                    if speechManager.isRecording { speechManager.stopRecording() }
                    if store.isLoading { onCancel() } else { executeSend() }
                }) {
                    ZStack {
                        Circle()
                            .fill(store.isLoading ? Color.red.opacity(0.8) : (canSend ? Color.blue : Color(NSColor.controlBackgroundColor)))
                            .frame(width: 36, height: 36)
                        if store.isLoading {
                            Image(systemName: "square.fill").foregroundColor(.white).font(.system(size: 14, weight: .bold))
                        } else {
                            Image(systemName: "paperplane.fill").foregroundColor(canSend ? .white : .secondary).font(.system(size: 14, weight: .semibold)).offset(x: -1, y: 1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canSend && !store.isLoading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .onChange(of: store.inputText) { _, newValue in
            checkAgentMentionTrigger(text: newValue)
            checkHashOptionTrigger(text: newValue)
        }
        .onReceive(store.onClearEvent) { _ in
            store.inputText = ""
            inputHeight = 22
            showAgentMentionMenu = false
            showOptionHashMenu = false
        }
    }
    
    private func checkHashOptionTrigger(text: String) {
        if let lastHashIndex = text.lastIndex(of: "#") {
            let suffix = String(text[lastHashIndex...])
            if !suffix.contains(" ") {
                optionHashFilterText = String(suffix.dropFirst())
                if !filteredOptions.isEmpty {
                    showOptionHashMenu = true
                    showAgentMentionMenu = false
                } else {
                    showOptionHashMenu = false
                }
                return
            }
        }
        if showOptionHashMenu { showOptionHashMenu = false }
    }
    
    private func insertOptionReplacement(_ optionText: String) {
        if let lastHashIndex = store.inputText.lastIndex(of: "#") {
            let prefix = String(store.inputText[..<lastHashIndex])
            store.inputText = "\(prefix)\(optionText) "
        } else {
            store.inputText = "\(optionText) "
        }
    }
    
    private func checkAgentMentionTrigger(text: String) {
        if let lastAtIndex = text.lastIndex(of: "@") {
            let suffix = String(text[lastAtIndex...])
            if !suffix.contains(" ") {
                mentionFilterText = String(suffix.dropFirst())
                if !filteredMentionAgents.isEmpty {
                    showAgentMentionMenu = true
                    showOptionHashMenu = false
                } else {
                    showAgentMentionMenu = false
                }
                return
            }
        }
        if showAgentMentionMenu { showAgentMentionMenu = false }
    }
    
    private func insertMention(profileName: String) {
        if let lastAtIndex = store.inputText.lastIndex(of: "@") {
            let prefix = String(store.inputText[..<lastAtIndex])
            store.inputText = "\(prefix)@\(profileName) "
        } else {
            store.inputText = "@\(profileName) "
        }
    }
    
    private var editingBannerView: some View {
        HStack(spacing: 12) {
            Image(systemName: "pencil.and.outline")
                .foregroundColor(.orange)
                .font(.system(size: 14))
            
            VStack(alignment: .leading, spacing: 2) {
                Text("正在编辑历史提问")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.primary)
                Text("发送后，此位置下方的所有对话及 Agent 任务黑板将被清空并重新生成。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(action: {
                withAnimation(.easeOut(duration: 0.2)) { store.cancelEditMode() }
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("取消编辑并恢复当前上下文")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
        .overlay(Rectangle().frame(height: 1).foregroundColor(Color.orange.opacity(0.15)), alignment: .bottom)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
    
    private func executeSend() {
        guard canSend else { return }
        showAgentMentionMenu = false
        showOptionHashMenu = false
        onSend(store.inputText)
        store.inputText = ""
        inputHeight = 22
    }
    
    private func selectFile() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.canChooseFiles = true
        p.allowedContentTypes = [.image, .pdf, .text, .rtf, .plainText, .data, .content]
        p.begin { r in
            if r == .OK {
                Task { @MainActor in
                    for u in p.urls {
                        if ["png", "jpg", "jpeg", "gif"].contains(u.pathExtension.lowercased()) {
                            if let img = NSImage(contentsOf: u) { store.selectedImages.append(img) }
                        } else { store.selectedFiles.append(u) }
                    }
                }
            }
        }
    }
}

struct OptionHashPopoverBubbleView: View {
    let options: [TextOptionItem]
    let onSelect: (String) -> Void
    let onOpenFolder: () -> Void
    var onReload: (() -> Void)? = nil
    let onClose: () -> Void
    
    @State private var isSpinning: Bool = false
    @State private var selectedTab: String = "全部"
    
    private var optionManager: TextOptionManager {
        TextOptionManager.shared
    }
    
    private var lastSelected: String? {
        optionManager.lastSelectedContent
    }
    
    private var availableFileTabs: [String] {
        Array(Set(options.map { $0.fileName })).sorted()
    }
    
    private var currentFilteredOptions: [TextOptionItem] {
        if selectedTab == "全部" {
            return options
        }
        return options.filter { $0.fileName == selectedTab }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
            Divider().opacity(0.25)
            tabBarView
            Divider().opacity(0.2)
            listView
        }
        .frame(width: 480)
        .background(.ultraThinMaterial)
        .onAppear {
            restoreLastTabAndPosition()
        }
    }
    
    private var headerView: some View {
        HStack(spacing: 6) {
            Image(systemName: "number.square.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(LinearGradient(colors: [.indigo, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
            
            Text("预设选项库")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.primary)
            
            Text("(# 快捷匹配)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
            
            Spacer()
            
            Button(action: executeReload) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(isSpinning ? 360 : 0))
                    Text("刷新")
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("重新扫描并加载 options 目录下的文本选项")
            
            Button(action: onOpenFolder) {
                HStack(spacing: 3) {
                    Image(systemName: "folder")
                    Text("打开目录")
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("在访达中打开 options/ 选项目录")
            .padding(.leading, 4)
            
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)
            .padding(.leading, 6)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Color.primary.opacity(0.02))
    }
    
    private var tabBarView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                tabPill(title: "全部", count: options.count)
                
                ForEach(availableFileTabs, id: \.self) { fileName in
                    let count = options.filter { $0.fileName == fileName }.count
                    tabPill(title: fileName, count: count)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(Color(NSColor.textBackgroundColor).opacity(0.15))
    }
    
    private func tabPill(title: String, count: Int) -> some View {
        let isSelected = (selectedTab == title)
        
        return Button(action: {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
                selectedTab = title
                optionManager.recordTab(title)
            }
        }) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                    .foregroundColor(isSelected ? .cyan : .primary.opacity(0.85))
                
                Text("\(count)")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(isSelected ? .cyan.opacity(0.9) : .secondary.opacity(0.7))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(isSelected ? Color.cyan.opacity(0.15) : Color.primary.opacity(0.05))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(isSelected ? Color.cyan.opacity(0.12) : Color.primary.opacity(0.03))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.cyan.opacity(0.35) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    private var listView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                if currentFilteredOptions.isEmpty {
                    VStack(spacing: 6) {
                        Text("当前分类下暂无选项内容")
                            .font(.system(size: 11.5))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    LazyVStack(spacing: 3) {
                        ForEach(currentFilteredOptions) { option in
                            let isLastPicked = (option.content == lastSelected)
                            
                            Button(action: {
                                optionManager.recordSelection(content: option.content, tab: selectedTab)
                                onSelect(option.content)
                            }) {
                                HStack(spacing: 8) {
                                    if selectedTab == "全部" {
                                        Text(option.fileName)
                                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                                            .foregroundColor(isLastPicked ? .cyan : .indigo)
                                            .padding(.horizontal, 4.5)
                                            .padding(.vertical, 1.5)
                                            .background((isLastPicked ? Color.cyan : Color.indigo).opacity(0.12))
                                            .cornerRadius(4)
                                    }
                                    
                                    Text(option.content)
                                        .font(.system(size: 12, weight: isLastPicked ? .semibold : .regular))
                                        .foregroundColor(.primary.opacity(0.9))
                                        .lineLimit(1)
                                    
                                    Spacer()
                                    
                                    if isLastPicked {
                                        HStack(spacing: 3) {
                                            Image(systemName: "clock.arrow.circlepath")
                                            Text("上次使用")
                                        }
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.cyan)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1.5)
                                        .background(Color.cyan.opacity(0.12))
                                        .cornerRadius(4)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(isLastPicked ? Color.cyan.opacity(0.08) : Color.clear)
                                .cornerRadius(6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(option.content)
                        }
                    }
                    .padding(6)
                }
            }
            .frame(maxHeight: 220)
            .onAppear {
                scrollToLastSelected(proxy: proxy)
            }
            .onChange(of: selectedTab) { _, _ in
                scrollToLastSelected(proxy: proxy)
            }
        }
    }
    
    private func restoreLastTabAndPosition() {
        if let savedTab = optionManager.lastSelectedTab {
            if savedTab == "全部" || availableFileTabs.contains(savedTab) {
                self.selectedTab = savedTab
            }
        }
    }
    
    private func scrollToLastSelected(proxy: ScrollViewProxy) {
        guard let target = lastSelected,
              currentFilteredOptions.contains(where: { $0.content == target }) else { return }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.easeInOut(duration: 0.22)) {
                proxy.scrollTo(target, anchor: .center)
            }
        }
    }
    
    private func executeReload() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            isSpinning = true
        }
        
        if let onReload = onReload {
            onReload()
        } else {
            TextOptionManager.shared.reloadOptions()
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            isSpinning = false
        }
    }
}

struct AgentMentionPopoverBubbleView: View {
    let agents: [AgentProfile]
    let onSelect: (String) -> Void
    let onClose: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "at")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: [.purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                
                Text("指派专家智能体")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.primary)
                
                Spacer()
                
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(Color.primary.opacity(0.02))
            
            Divider().opacity(0.3)
            
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 3) {
                    ForEach(agents) { profile in
                        Button(action: { onSelect(profile.name) }) {
                            HStack(spacing: 8) {
                                Image(systemName: profile.icon)
                                    .foregroundColor(.purple)
                                    .frame(width: 16)
                                Text(profile.name)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundColor(.primary)
                                Spacer()
                                Text(profile.baseModel)
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color.clear)
                            .cornerRadius(6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 180)
        }
        .frame(width: 360)
        .background(.ultraThinMaterial)
    }
}

struct OptionDrawerPopoverView: View {
    let onSelectOption: (String) -> Void
    
    @State private var searchText: String = ""
    @State private var selectedFileCategory: String = "全部"
    
    init(onSelectOption: @escaping (String) -> Void) {
        self.onSelectOption = onSelectOption
    }
    
    private var optionManager: TextOptionManager {
        TextOptionManager.shared
    }
    
    private var currentFilteredOptions: [TextOptionItem] {
        optionManager.searchOptions(keyword: searchText, selectedCategory: selectedFileCategory)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
                
                TextField("搜索选项内容或文本...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                }
                
                Spacer()
                
                Button(action: { optionManager.openInFinder() }) {
                    HStack(spacing: 3) {
                        Image(systemName: "folder")
                        Text("目录")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.purple)
                }
                .buttonStyle(.plain)
                .help("在访达中打开选项目录，自由添加或编辑 .txt 文件")
            }
            .padding(10)
            .background(Color.primary.opacity(0.03))
            
            Divider().opacity(0.5)
            
            if !optionManager.availableFiles.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        categoryChip(title: "全部")
                        ForEach(optionManager.availableFiles, id: \.self) { fileName in
                            categoryChip(title: fileName)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                Divider().opacity(0.3)
            }
            
            ScrollView(.vertical, showsIndicators: true) {
                if currentFilteredOptions.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 28))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("未检索到匹配的选项内容")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Button("打开文件夹添加 .txt 文件") {
                            optionManager.openInFinder()
                        }
                        .font(.system(size: 11))
                        .buttonStyle(.link)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                } else {
                    LazyVStack(spacing: 4) {
                        ForEach(currentFilteredOptions) { option in
                            Button(action: { onSelectOption(option.content) }) {
                                HStack(alignment: .top, spacing: 8) {
                                    Text(option.fileName)
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(.purple)
                                        .padding(.horizontal, 4).padding(.vertical, 2)
                                        .background(Color.purple.opacity(0.1))
                                        .cornerRadius(3)
                                        .padding(.top, 1)
                                    
                                    Text(option.content)
                                        .font(.system(size: 12))
                                        .foregroundColor(.primary.opacity(0.9))
                                        .lineSpacing(3)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(Color.primary.opacity(0.03))
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                }
            }
            .frame(maxHeight: 260)
        }
        .frame(width: 360)
        .background(.ultraThinMaterial)
    }
    
    private func categoryChip(title: String) -> some View {
        let isSelected = selectedFileCategory == title
        return Button(action: {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                selectedFileCategory = title
            }
        }) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                .foregroundColor(isSelected ? .purple : .secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(isSelected ? Color.purple.opacity(0.15) : Color.primary.opacity(0.04))
                .cornerRadius(5)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(isSelected ? Color.purple.opacity(0.3) : Color.clear, lineWidth: 0.8)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ==================== 7. ChatMainView (主视图装配与渲染管线) ====================

// MARK: - [Modified] ChatMessageRowView (支持悬浮同时展示上下双工具栏，零性能损耗)
struct ChatMessageRowView: View, Equatable {
    let msg: ChatMessage
    var isGenerating: Bool
    let onDelete: () -> Void
    var onEdit: (() -> Void)? = nil
    var onRegenerate: (() -> Void)? = nil
    var onAppendInstruction: ((String) -> Void)? = nil
    var onConfirmTask: (() -> Void)? = nil
    
    @State private var isHovered: Bool = false
    @State private var isCopied: Bool = false
    @State private var renderedText: String = ""
    @State private var lastRenderTime: Date = Date()
    private let throttleInterval: TimeInterval = 0.08
    
    static func == (lhs: ChatMessageRowView, rhs: ChatMessageRowView) -> Bool {
        return lhs.msg == rhs.msg && lhs.isGenerating == rhs.isGenerating
    }
    
    private var shouldHideStandardContent: Bool {
        if msg.isUser { return false }
        if isGenerating { return false }
        return msg.skillLogs.contains { !$0.uiTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    
    private var displaySafeText: String {
        if msg.isUser { return renderedText }
        
        var cleanText = renderedText.filterStopTokens().filterPersonaDelta()
        if isGenerating { return cleanText }
        
        cleanText = cleanText.replacingOccurrences(
            of: "(?s)```json\\n\\s*\\{.*?\"(action|tool|name)\".*?\\}\\n```",
            with: "", options: .regularExpression
        )
        cleanText = cleanText.replacingOccurrences(
            of: "(?s)\\n*\\[(正在)?调用技能:.*?\\]\\n*",
            with: "", options: .regularExpression
        )
        return cleanText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private var uniqueRagHits: [RAGHitLog] {
        var uniqueHits: [RAGHitLog] = []
        var seenTitles: Set<String> = []
        for hit in msg.ragHits {
            if !seenTitles.contains(hit.title) {
                seenTitles.insert(hit.title)
                let combined = msg.ragHits.filter { $0.title == hit.title }.map { $0.content }.joined(separator: "\n\n------\n\n")
                uniqueHits.append(RAGHitLog(title: hit.title, path: hit.path, content: combined))
            }
        }
        return uniqueHits
    }
    
    private var displayFileURLs: [URL] {
        return msg.fileURLs.filter { url in
            let fileName = url.lastPathComponent.lowercased()
            let isScreenshotPill = fileName.hasPrefix("screenshot_") && (fileName.hasSuffix(".png") || fileName.hasSuffix(".jpg") || fileName.hasSuffix(".jpeg"))
            return !isScreenshotPill
        }
    }
    
    var body: some View {
        let visibleFiles = displayFileURLs
        let hasImages = !msg.images.isEmpty
        let hasFiles = !visibleFiles.isEmpty
        let hasText = !displaySafeText.isEmpty || (isGenerating && !msg.isUser)
        let hasSkillLogs = !msg.skillLogs.isEmpty
        
        VStack(alignment: msg.isUser ? .trailing : .leading, spacing: 3) {
            // 1. 气泡顶部浮动工具条（AI 回复专属，鼠标移入时显现）
            if !msg.isUser {
                actionButtons
                    .padding(.horizontal, 4)
                    .padding(.bottom, 1)
                    .opacity(actionOpacity)
            }
            
            // 2. 主消息气泡容器
            HStack(alignment: .top, spacing: 0) {
                if msg.isUser {
                    Spacer(minLength: 28)
                }
                
                VStack(alignment: .leading, spacing: 10) {
                    if msg.isUser && hasImages {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(msg.images, id: \.self) { img in
                                    Image(nsImage: img)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxHeight: 140)
                                        .cornerRadius(8)
                                        .shadow(color: Color.black.opacity(0.1), radius: 3, x: 0, y: 2)
                                        .contentShape(Rectangle())
                                        .onTapGesture { openSystemImagePreview(image: img) }
                                        .onHover { hovering in
                                            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                                        }
                                }
                            }
                        }
                    }
                    
                    if hasFiles {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(visibleFiles, id: \.self) { url in
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.fill").foregroundColor(.primary).font(.system(size: 12))
                                    Text(url.lastPathComponent).font(.system(size: 11, weight: .medium)).foregroundColor(.primary).lineLimit(1)
                                }
                                .padding(6)
                                .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
                                .cornerRadius(6)
                                .onTapGesture { NSWorkspace.shared.open(url) }
                            }
                        }
                    }
                    
                    if hasSkillLogs {
                        VStack(alignment: .leading, spacing: 8) {
                            let isAutonomousLoop = AiChatStore.shared.currentAgent.enableAutonomy
                            
                            if isAutonomousLoop {
                                AgentActionTimelineView(skillLogs: msg.skillLogs, isGenerating: isGenerating)
                            } else {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(msg.skillLogs) { log in
                                        ToolCardBubbleView(log: log, parentContent: msg.text, onAction: onAppendInstruction)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    
                    if hasText {
                        if msg.isUser {
                            UserMessageContentView(text: msg.text)
                        } else if !shouldHideStandardContent {
                            MessageContentView(
                                messageID: msg.id,
                                text: displaySafeText,
                                isUser: false,
                                isGenerating: isGenerating,
                                skillLogs: msg.skillLogs,
                                ragHits: msg.ragHits,
                                onAction: onAppendInstruction
                            ).equatable()
                        }
                    }
                    
                    if !msg.isUser, let finishLog = msg.skillLogs.last(where: { $0.skillName == "finish_task" }) {
                        TaskCompletionCardView(
                            log: finishLog,
                            totalToolCalls: msg.skillLogs.count,
                            onConfirm: { onConfirmTask?() },
                            onRetry: { instruction in onAppendInstruction?(instruction) }
                        )
                    }
                    
                    if !msg.isUser && !uniqueRagHits.isEmpty {
                        RAGHitsBottomView(ragHits: uniqueRagHits)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    msg.isUser
                    ? AnyView(
                        LinearGradient(
                            colors: [Color.blue, Color(hex: "#1D4ED8")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    : AnyView(
                        Color(NSColor.controlBackgroundColor)
                            .opacity(0.52)
                            .background(.ultraThinMaterial)
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(
                            msg.isUser ? Color.clear : Color.primary.opacity(0.08),
                            lineWidth: 0.8
                        )
                )
                .shadow(color: Color.black.opacity(msg.isUser ? 0.12 : 0.04), radius: 3, x: 0, y: 1)
                
                if !msg.isUser {
                    Spacer(minLength: 28)
                }
            }
            
            // 3. 气泡底部浮动工具条（用户消息右对齐，AI 消息左对齐，鼠标移入时显现）
            actionButtons
                .padding(.horizontal, 4)
                .padding(.top, 2)
                .opacity(actionOpacity)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hover in withAnimation(.easeOut(duration: 0.15)) { isHovered = hover } }
        .onAppear { renderedText = msg.text }
        .onChange(of: msg.text) { _, newText in
            if !isGenerating { renderedText = newText } else {
                let now = Date()
                if now.timeIntervalSince(lastRenderTime) > throttleInterval { renderedText = newText; lastRenderTime = now }
            }
        }
        .onChange(of: isGenerating) { _, gen in if !gen { renderedText = msg.text } }
    }
    
    // 操作按钮组
    @ViewBuilder private var actionButtons: some View {
        HStack(spacing: 5) {
            if !msg.isUser {
                Button(action: { toggleFeedback(.liked) }) {
                    Image(systemName: msg.feedback == .liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundColor(msg.feedback == .liked ? .green : .secondary)
                        .padding(5)
                        .background(Circle().fill(msg.feedback == .liked ? Color.green.opacity(0.15) : Color(NSColor.controlBackgroundColor).opacity(0.75)))
                }
                .buttonStyle(.plain)
                .help("赞同回答")
                
                Button(action: { toggleFeedback(.disliked) }) {
                    Image(systemName: msg.feedback == .disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundColor(msg.feedback == .disliked ? .orange : .secondary)
                        .padding(5)
                        .background(Circle().fill(msg.feedback == .disliked ? Color.orange.opacity(0.15) : Color(NSColor.controlBackgroundColor).opacity(0.75)))
                }
                .buttonStyle(.plain)
                .help("不赞同回答")
                
                Divider().frame(height: 12).padding(.horizontal, 2)
            }
            
            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(displaySafeText, forType: .string)
                withAnimation { isCopied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { isCopied = false } }
            }) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.clipboard.fill")
                    .font(.system(size: 10.5))
                    .foregroundColor(isCopied ? .green : .secondary)
                    .padding(5)
                    .background(Circle().fill(isCopied ? Color.green.opacity(0.15) : Color(NSColor.controlBackgroundColor).opacity(0.75)))
            }
            .buttonStyle(.plain)
            .help(isCopied ? "已复制到剪贴板" : "复制内容")
            
            if !msg.isUser, let onRegenerate = onRegenerate {
                Button(action: onRegenerate) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.cyan)
                        .padding(5)
                        .background(Circle().fill(Color(NSColor.controlBackgroundColor).opacity(0.75)))
                }
                .buttonStyle(.plain)
                .help("重新生成回复")
            }
            
            if msg.isUser, let onEdit = onEdit {
                Button(action: onEdit) {
                    Image(systemName: "pencil.line")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.cyan)
                        .padding(5)
                        .background(Circle().fill(Color(NSColor.controlBackgroundColor).opacity(0.75)))
                }
                .buttonStyle(.plain)
                .help("编辑消息")
            }
            
            Button(action: onDelete) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 10.5))
                    .foregroundColor(.red.opacity(0.75))
                    .padding(5)
                    .background(Circle().fill(Color(NSColor.controlBackgroundColor).opacity(0.75)))
            }
            .buttonStyle(.plain)
            .help("删除消息")
        }
        .allowsHitTesting(isHovered && !isGenerating)
    }
    
    private func toggleFeedback(_ type: MessageFeedback) {
        guard let idx = AiChatStore.shared.messages.firstIndex(where: { $0.id == msg.id }) else { return }
        
        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
            if AiChatStore.shared.messages[idx].feedback == type {
                AiChatStore.shared.messages[idx].feedback = .none
            } else {
                AiChatStore.shared.messages[idx].feedback = type
                if type != .none {
                    let targetId = msg.id
                    let allMessagesSnapshot = AiChatStore.shared.messages
                    let currentModel = AiChatStore.shared.currentAgent.baseModel
                    
                    Task(priority: .utility) {
                        await MemoryManager.shared.harvestFeedbackExperience(
                            recentMessages: allMessagesSnapshot,
                            targetMessageId: targetId,
                            feedback: type,
                            model: currentModel
                        )
                    }
                }
            }
            AiChatStore.shared.saveCurrentState()
        }
    }
    
    private var actionOpacity: Double { (isHovered && !isGenerating) ? 1.0 : 0.0 }
}

struct UserMessageContentView: View {
    let text: String
    @State private var isExpanded: Bool = false
    @State private var isHovered: Bool = false
    
    private var isTooLong: Bool {
        let lineCount = text.components(separatedBy: .newlines).count
        return lineCount > 4 || text.count > 150
    }
    
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if !isTooLong || isExpanded {
                    Text(text)
                        .lineLimit(nil)
                        .textSelection(.enabled)
                } else {
                    Text(text)
                        .lineLimit(5)
                        .allowsHitTesting(false)
                }
            }
            .font(.system(size: 14))
            .foregroundColor(.white)
            .lineSpacing(4)
            .padding(.bottom, (!isExpanded && isTooLong) ? 16 : 0)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
            
            if isTooLong {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up.circle.fill" : "ellipsis.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white)
                        .background(Color.blue.clipShape(Circle()))
                        .shadow(color: Color.black.opacity(0.15), radius: 2, y: 1)
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: 4)
                .help(isExpanded ? "收起长文本" : "展开阅读全文")
                .scaleEffect(isHovered ? 1.1 : 1.0)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.2)) { isHovered = hovering }
                }
            }
        }
    }
}

// MARK: - [Modified] AiChatView (固定唯一标识并消除全量层叠重绘)
@MainActor
struct AiChatView: View {
    @ObservedObject private var store = AiChatStore.shared
    @StateObject private var speechManager = SpeechRecognizerManager()
    @State private var micPulsing = false
    @State private var autoScrollEnabled: Bool = true
    @State private var lastScrollTime = Date()
    @State private var orchestrator: ChatOrchestrator
    
    init(knowledgeVM: KnowledgeViewModel, agentVM: AgentViewModel) {
        self._orchestrator = State(initialValue: ChatOrchestrator(agentVM: agentVM, knowledgeVM: knowledgeVM))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            topBarView
            
            if let alert = store.activeBeaconAlert {
                LLMBeaconView(alert: alert)
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.95)))
                    .zIndex(10)
            }
            
            messageListView
            
            if let currentAgentModel = ConfigManager.shared.app.agentProfiles.first(where: { $0.id == store.selectedAgentID })?.baseModel {
                let maxTokens = ConfigManager.shared.app.aiConfigs.first(where: { $0.models.contains(currentAgentModel) })?.maxContextTokens ?? 32000
                let realtimeInputTokens = TokenEstimationEngine.estimateTextTokens(store.inputText)
                
                ContextTokenDividerBar(
                    currentTokens: store.currentContextTokenCount + realtimeInputTokens,
                    maxTokens: maxTokens
                )
            } else {
                Divider().background(Color(NSColor.separatorColor))
            }
            
            imagePreviewView
            ChatInputAreaView(
                store: store,
                speechManager: speechManager,
                micPulsing: $micPulsing,
                onSend: { text in
                    let imagesToBind = store.selectedImages
                    let filesToBind = store.selectedFiles

                    if store.editingTargetMessageID != nil {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            store.prepareForEditedSend(agentVM: orchestrator.agentVM)
                        }
                    }

                    Task {
                        await orchestrator.send(text: text, images: imagesToBind, files: filesToBind)
                    }
                },
                onCancel: { orchestrator.cancelCurrentTask() }
            )
        }
        .background(
            ZStack {
                SiriVibrantBackgroundView(isActive: store.isLoading)
            }
        )
        .onDisappear { speechManager.stopRecording() }
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: store.blackboardPlan)
    }
    
    private var topBarView: some View {
        HStack(spacing: 8) {
            let currentAgent = ConfigManager.shared.app.agentProfiles.first(where: { $0.id == store.selectedAgentID })
                ?? ConfigManager.shared.app.agentProfiles.first
            let defaultAgentID = ConfigManager.shared.app.generalConfig.defaultAgentID
            
            Menu {
                ForEach(ConfigManager.shared.app.agentProfiles) { profile in
                    Button(action: {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                            store.selectedAgentID = profile.id
                            store.saveCurrentState()
                        }
                    }) {
                        HStack {
                            Image(systemName: profile.icon)
                            Text(profile.name)
                            if !profile.baseModel.isEmpty {
                                Text("(\(profile.baseModel))")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            if defaultAgentID == profile.id {
                                Text("👑 默认")
                            }
                            if store.selectedAgentID == profile.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Divider()
                Button(action: {
                    AgentManager.shared.show()
                    NotificationCenter.default.post(name: NSNotification.Name("SwitchAgentManagerTab"), object: 0)
                }) {
                    Label("智能体流水线工坊...", systemImage: "slider.horizontal.3")
                }
            } label: {
                HStack(spacing: 6) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.blue.opacity(0.15))
                            .frame(width: 20, height: 20)
                        
                        Image(systemName: currentAgent?.icon ?? "person.crop.square.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.blue)
                    }
                    
                    Text(currentAgent?.name ?? "未选择智能体")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 110, alignment: .leading)
                    
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.secondary.opacity(0.8))
                }
                .padding(.leading, 4)
                .padding(.trailing, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.04))
                .cornerRadius(7)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("切换当前对话的智能体分身")
            
            Menu {
                Button("🚫 不挂载分身 (纯净模式)") {
                    withAnimation {
                        store.selectedPersonaID = nil
                        store.saveCurrentState()
                    }
                }
                Divider()
                ForEach(PersonaManager.shared.personas) { p in
                    Button(action: {
                        withAnimation {
                            store.selectedPersonaID = p.id
                            store.saveCurrentState()
                        }
                    }) {
                        HStack {
                            Image(systemName: p.avatarIcon)
                            Text("\(p.name) (\(p.roleTag))")
                            if store.selectedPersonaID == p.id { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                if let pID = store.selectedPersonaID, let p = PersonaManager.shared.personas.first(where: { $0.id == pID }) {
                    HStack(spacing: 4) {
                        Image(systemName: p.avatarIcon).foregroundColor(.purple).font(.system(size: 11))
                        Text(p.name).font(.system(size: 11, weight: .bold)).foregroundColor(.purple)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(Color.purple.opacity(0.12))
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.purple.opacity(0.25), lineWidth: 0.8))
                } else {
                    HStack(spacing: 3) {
                        Image(systemName: "theatermasks").foregroundColor(.secondary).font(.system(size: 11))
                        Text("分身").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(Color.primary.opacity(0.04))
                    .cornerRadius(6)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("挂载与切换数字分身心智")
            
            if let agent = currentAgent {
                let kbCategory = agent.bindKnowledgeCategory
                let hasKB = !kbCategory.isEmpty
                let kbText = (kbCategory == "全部" ? "全部知识" : kbCategory)
                
                HStack(spacing: 5) {
                    Image(systemName: "cpu")
                        .font(.system(size: 9))
                    Text(agent.baseModel.isEmpty ? "未指定模型" : agent.actualModelName)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    if hasKB {
                        Text("·")
                            .font(.system(size: 10, weight: .bold))
                            .opacity(0.3)
                        Image(systemName: kbCategory == "全部" ? "books.vertical.fill" : "folder.fill")
                            .font(.system(size: 9))
                        Text(kbText)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.035))
                .cornerRadius(6)
                .help("底层模型: \(agent.actualModelName)\(hasKB ? "\n关联知识库: \(kbText)" : "")")
            }
            
            Spacer(minLength: 4)
            
            Menu {
                let sessions = ChatHistoryManager.shared.sessions
                if sessions.isEmpty {
                    Text("暂无历史记录").foregroundColor(.secondary)
                } else {
                    let activeSessions = sessions.filter { !$0.isArchived! }
                    let archivedSessions = sessions.filter { $0.isArchived! }
                    
                    if !activeSessions.isEmpty {
                        Text("活跃会话").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
                        ForEach(activeSessions.prefix(8)) { session in
                            Button(action: { withAnimation { store.loadSession(session) } }) {
                                HStack {
                                    Text(session.title)
                                    if store.currentSessionID == session.id { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                    
                    if !archivedSessions.isEmpty {
                        Divider()
                        Text("📦 已归档经验库").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
                        ForEach(archivedSessions.prefix(8)) { session in
                            Button(action: { withAnimation { store.loadSession(session) } }) {
                                HStack {
                                    Text(session.title)
                                    if store.currentSessionID == session.id { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                    
                    Divider()
                    Button("管理全部对话...") {
                        AgentManager.shared.show()
                        NotificationCenter.default.post(name: NSNotification.Name("SwitchAgentManagerTab"), object: 7)
                    }
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.04))
                    .cornerRadius(6)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("历史对话记录")
            
            Button(action: {
                let currentMsgs = store.messages
                if let personaID = store.selectedPersonaID, !currentMsgs.isEmpty {
                    Task.detached(priority: .utility) {
                        _ = await PersonaManager.shared.distillAndConsolidate(for: personaID, recentMessages: currentMsgs)
                    }
                }
                withAnimation { store.clearChat() }
                orchestrator.agentVM.sharedContext.removeValue(forKey: "AGENT_BLACKBOARD_PLAN")
                orchestrator.agentVM.sharedContext.removeValue(forKey: "AGENT_GLOBAL_MEMO")
            }) {
                Image(systemName: "plus.bubble.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.cyan)
                    .frame(width: 26, height: 26)
                    .background(Color.cyan.opacity(0.12))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(store.isLoading)
            .opacity(store.isLoading ? 0.5 : 1.0)
            .help("开启新对话")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
    
    private var messageListView: some View {
        ScrollView {
            ScrollViewReader { proxy in
                VStack(spacing: 16) {
                    ForEach(store.messages, id: \.id) { msg in
                        let isGen = store.isLoading && msg.id == store.messages.last?.id
                        ChatMessageRowView(
                            msg: msg, isGenerating: isGen, onDelete: { store.deleteMessage(id: msg.id) },
                            onEdit: msg.isUser ? {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    orchestrator.cancelCurrentTask()
                                    store.enterEditMode(for: msg)
                                }
                            } : nil,
                            onRegenerate: !msg.isUser ? {
                                orchestrator.cancelCurrentTask()
                                if let aiIdx = store.messages.firstIndex(where: { $0.id == msg.id }) {
                                    var userIdx = aiIdx - 1
                                    while userIdx >= 0 && !store.messages[userIdx].isUser {
                                        userIdx -= 1
                                    }
                                    if userIdx >= 0 {
                                        let userMsgToResend = store.messages[userIdx]
                                        withAnimation(.easeInOut(duration: 0.3)) {
                                            store.messages.removeSubrange(userIdx...)
                                        }
                                        orchestrator.agentVM.sharedContext.removeValue(forKey: "AGENT_BLACKBOARD_PLAN")
                                        Task {
                                            await orchestrator.send(
                                                text: userMsgToResend.text,
                                                images: userMsgToResend.images,
                                                files: userMsgToResend.fileURLs
                                            )
                                        }
                                    }
                                }
                            } : nil,
                            onAppendInstruction: { instruction in
                                store.inputText = instruction
                                if !store.isLoading {
                                    Task {
                                        await orchestrator.send(text: instruction, images: [], files: [])
                                    }
                                }
                            },
                            onConfirmTask: { orchestrator.agentVM.sharedContext.removeValue(forKey: "AGENT_BLACKBOARD_PLAN") }
                        ).equatable()
                    }
                    Color.clear.frame(height: 1).id("BOTTOM_MARKER")
                }
                .padding(.horizontal, 16).padding(.vertical, 12).frame(minWidth: 420, maxWidth: .infinity, alignment: .topLeading)
                .onChange(of: store.isLoading) { _, loading in
                    if !loading && autoScrollEnabled { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("BOTTOM_MARKER", anchor: .bottom) } } }
                }
            }
        }.scrollContentBackground(.hidden).forceOverlayScrollbars().defaultScrollAnchor(.bottom).onReceive(NotificationCenter.default.publisher(for: NSScrollView.willStartLiveScrollNotification)) { _ in autoScrollEnabled = false }
    }
    
    @ViewBuilder private var imagePreviewView: some View {
        if !store.selectedImages.isEmpty || !store.selectedFiles.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.selectedImages, id: \.self) { img in ZStack(alignment: .topTrailing) { Image(nsImage: img).resizable().scaledToFill().frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 6)); Button(action: { withAnimation { if let idx = store.selectedImages.firstIndex(of: img) { store.selectedImages.remove(at: idx) } } }) { Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundColor(.white).background(Color.black.opacity(0.8).clipShape(Circle())) }.buttonStyle(.plain).offset(x: 6, y: -6) }.padding(.top, 6).padding(.trailing, 6) }
                    ForEach(store.selectedFiles, id: \.self) { url in ZStack(alignment: .topTrailing) { VStack { Image(systemName: "doc.text.fill").font(.system(size: 18)).foregroundColor(.primary); Text(url.lastPathComponent).font(.system(size: 9)).foregroundColor(.primary).lineLimit(1).truncationMode(.middle) }.frame(width: 44, height: 44).background(Color(NSColor.windowBackgroundColor).opacity(0.5)).cornerRadius(6); Button(action: { withAnimation { if let idx = store.selectedFiles.firstIndex(of: url) { store.selectedFiles.remove(at: idx) } } }) { Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundColor(.white).background(Color.black.opacity(0.8).clipShape(Circle())) }.buttonStyle(.plain).offset(x: 6, y: -6) }.padding(.top, 6).padding(.trailing, 6) }
                }.padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 8)
            }.background(Color(NSColor.windowBackgroundColor))
        }
    }
}

struct ContextTokenDividerBar: View {
    let currentTokens: Int
    let maxTokens: Int
    
    @State private var isExpanded: Bool = false
    @State private var isHovered: Bool = false
    
    var usageRatio: Double {
        return Double(currentTokens) / Double(maxTokens)
    }
    
    var themeColor: Color {
        if usageRatio > 0.9 { return .red }
        if usageRatio > 0.75 { return .orange }
        return .cyan
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                HStack(spacing: 12) {
                    Image(systemName: "cpu.fill")
                        .font(.system(size: 13))
                    
                    Text("\(currentTokens) / \(maxTokens)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                    
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.1))
                            Capsule()
                                .fill(themeColor.gradient)
                                .frame(width: geo.size.width * min(usageRatio, 1.0))
                        }
                    }
                    .frame(height: 4)
                    .frame(maxWidth: 160)
                    
                    Spacer()
                    
                    HStack(spacing: 6) {
                        Circle()
                            .fill(themeColor)
                            .frame(width: 6, height: 6)
                        
                        if usageRatio > 1.0 {
                            Text("记忆容量超限，早期上下文将被折叠")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.red)
                        } else {
                            Text("记忆负载 (\(Int(min(usageRatio * 100, 100)))%)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .foregroundColor(themeColor)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            
            ZStack {
                Divider().background(Color(NSColor.separatorColor))
                Capsule()
                    .fill(isHovered || isExpanded ? themeColor : Color.gray.opacity(0.2))
                    .frame(width: isHovered || isExpanded ? 48 : 24, height: isHovered || isExpanded ? 4 : 2)
                    .shadow(color: themeColor.opacity(isHovered || isExpanded ? 0.5 : 0), radius: 3)
            }
            .frame(height: 2)
            .contentShape(Rectangle())
            .onHover { hover in
                withAnimation(.easeInOut(duration: 0.2)) { isHovered = hover }
            }
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { isExpanded.toggle() }
            }
            .help(isExpanded ? "点击收起上下文大盘" : "点击展开上下文负载状态")
        }
        .zIndex(100)
    }
}

struct SiriVibrantBackgroundView: View {
    let isActive: Bool
    @Environment(\.colorScheme) var colorScheme
    
    @State private var shockwaveScale: CGFloat = 0.3
    @State private var shockwaveOpacity: CGFloat = 0.0
    @State private var steadyStateInflow: CGFloat = 0.0
    
    private let neonCyan = Color(red: 0.0, green: 0.98, blue: 1.0)
    private let neonPurple = Color(red: 0.70, green: 0.0, blue: 1.0)
    private let neonPink = Color(red: 1.0, green: 0.0, blue: 0.5)
    private let neonOrange = Color(red: 1.0, green: 0.5, blue: 0.0)

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if isActive {
                    let w = geometry.size.width
                    let h = geometry.size.height
                    
                    ZStack {
                        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
                            let time = timeline.date.timeIntervalSinceReferenceDate
                            let t = time * 1.1
                            let pulseLeft = sin(t * 1.6)
                            let pulseRight = cos(t * 1.4)
                            let pulseCenter = sin(t * 1.0)
                            
                            let driftLX = CGFloat(sin(t * 0.7) * (w * 0.07))
                            let driftLY = CGFloat(cos(t * 1.0) * (h * 0.03))
                            let driftRX = CGFloat(cos(t * 0.8) * (w * 0.07))
                            let driftRY = CGFloat(sin(t * 1.2) * (h * 0.03))
                            let driftCX = CGFloat(sin(t * 1.1) * (w * 0.10))
                            
                            ZStack {
                                Ellipse()
                                    .fill(RadialGradient(colors: [neonCyan.opacity(0.9), neonCyan.opacity(0.3), .clear], center: .center, startRadius: 0, endRadius: w * 0.6))
                                    .frame(width: w * 1.1, height: h * 0.4)
                                    .position(x: w * 0.0 + driftLX, y: h * 1.0 + driftLY)
                                    .scaleEffect(1.0 + pulseLeft * 0.08)
                                
                                Ellipse()
                                    .fill(RadialGradient(colors: [neonPurple.opacity(0.85), neonPurple.opacity(0.25), .clear], center: .center, startRadius: 0, endRadius: w * 0.6))
                                    .frame(width: w * 1.1, height: h * 0.4)
                                    .position(x: w * 1.0 + driftRX, y: h * 1.0 + driftRY)
                                    .scaleEffect(1.0 + pulseRight * 0.09)
                                
                                Ellipse()
                                    .fill(RadialGradient(colors: [neonPink.opacity(0.9), neonPink.opacity(0.4), .clear], center: .center, startRadius: 0, endRadius: w * 0.7))
                                    .frame(width: w * 1.3, height: h * 0.45)
                                    .position(x: w * 0.5 + driftCX, y: h * 1.02)
                                    .scaleEffect(1.0 + pulseCenter * 0.07)
                            }
                            .hueRotation(.degrees(time * 30))
                            .opacity(steadyStateInflow)
                        }
                        .drawingGroup()
                        
                        Rectangle()
                            .fill(LinearGradient(colors: [neonCyan, neonPink, neonPurple, neonOrange], startPoint: .leading, endPoint: .trailing))
                            .frame(height: h * 0.45)
                            .position(x: w * 0.5, y: h * 1.0)
                            .scaleEffect(x: shockwaveScale, y: shockwaveScale, anchor: .bottom)
                            .opacity(shockwaveOpacity)
                            .blendMode(.plusLighter)
                    }
                    .blur(radius: 36)
                    .opacity(colorScheme == .dark ? 0.60 : 0.32)
                    .blendMode(colorScheme == .dark ? .plusLighter : .normal)
                }
            }
        }
        .ignoresSafeArea()
        .onChange(of: isActive) { _, newValue in
            if newValue {
                shockwaveScale = 0.4
                shockwaveOpacity = 1.0
                steadyStateInflow = 0.0
                withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) {
                    shockwaveScale = 1.6
                    shockwaveOpacity = 0.0
                }
                withAnimation(.easeInOut(duration: 0.5).delay(0.05)) {
                    steadyStateInflow = 1.0
                }
            } else {
                withAnimation(.easeInOut(duration: 0.35)) {
                    steadyStateInflow = 0.0
                    shockwaveOpacity = 0.0
                    shockwaveScale = 0.3
                }
            }
        }
    }
}

struct LLMBeaconView: View {
    let alert: LLMBeaconAlert
    @State private var isBreathing: Bool = false
    
    var themeColor: Color {
        alert.isWarning ? .orange : .red
    }
    
    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(themeColor.opacity(0.3))
                    .frame(width: 14, height: 14)
                    .scaleEffect(isBreathing ? 1.4 : 0.8)
                    .opacity(isBreathing ? 0.2 : 0.8)
                
                Circle()
                    .fill(themeColor)
                    .frame(width: 6, height: 6)
            }
            
            Text(alert.message)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(.primary.opacity(0.9))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4.5)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: themeColor.opacity(0.18), radius: 6, x: 0, y: 2)
        )
        .overlay(
            Capsule()
                .stroke(themeColor.opacity(0.35), lineWidth: 0.8)
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                isBreathing = true
            }
        }
    }
}

// MARK: - ==================== Generic Action Badge Architecture ====================

public enum ActionBadgeType: Equatable, Sendable {
    case tool(name: String, callId: String, status: String)
    case rag(id: String, score: String?)
    case custom(scheme: String, payload: String)
}

public struct ActionBadgeModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let type: ActionBadgeType
    public let title: String
    public let rawURLString: String
    
    public init(id: String = UUID().uuidString, type: ActionBadgeType, title: String, rawURLString: String) {
        self.id = id
        self.type = type
        self.title = title
        self.rawURLString = rawURLString
    }
}

public struct ActionBadgeParser {
    public static func extractBadges(from text: String) -> (cleanText: String, badges: [ActionBadgeModel]) {
        var cleanText = text
        var badges: [ActionBadgeModel] = []
        
        let pattern = "\\[(.*?)\\]\\((action://(inspect_tool|inspect_rag|custom)(?:/([^?)]*))?(?:\\?([^)]*))?)\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return (text, []) }
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: text.utf16.count))
        
        for match in matches.reversed() {
            guard let totalRange = Range(match.range, in: cleanText),
                  let titleRange = Range(match.range(at: 1), in: cleanText),
                  let urlRange = Range(match.range(at: 2), in: cleanText),
                  let hostRange = Range(match.range(at: 3), in: cleanText) else { continue }
            
            let title = String(cleanText[titleRange])
            let rawUrl = String(cleanText[urlRange])
            let host = String(cleanText[hostRange])
            
            let path = match.range(at: 4).location != NSNotFound ? (Range(match.range(at: 4), in: cleanText).map { String(cleanText[$0]) } ?? "") : ""
            let query = match.range(at: 5).location != NSNotFound ? (Range(match.range(at: 5), in: cleanText).map { String(cleanText[$0]) } ?? "") : ""
            
            var queryParams: [String: String] = [:]
            for pair in query.components(separatedBy: "&") {
                let kv = pair.components(separatedBy: "=")
                if kv.count == 2 {
                    let k = kv[0].removingPercentEncoding ?? kv[0]
                    let v = kv[1].removingPercentEncoding ?? kv[1]
                    queryParams[k] = v
                }
            }
            
            let badgeType: ActionBadgeType
            let badgeId: String
            
            if host == "inspect_tool" {
                let callId = queryParams["call_id"] ?? UUID().uuidString
                let status = queryParams["status"] ?? "running"
                badgeType = .tool(name: path.removingPercentEncoding ?? path, callId: callId, status: status)
                badgeId = callId
            } else if host == "inspect_rag" {
                let score = queryParams["score"]
                badgeType = .rag(id: path.removingPercentEncoding ?? path, score: score)
                badgeId = path
            } else {
                badgeType = .custom(scheme: host, payload: path)
                badgeId = UUID().uuidString
            }
            
            let badge = ActionBadgeModel(id: badgeId, type: badgeType, title: title, rawURLString: rawUrl)
            badges.insert(badge, at: 0)
            cleanText.removeSubrange(totalRange)
        }
        
        return (cleanText.trimmingCharacters(in: .whitespacesAndNewlines), badges)
    }
}

// MARK: - 原生 macOS 极致圆角胶囊徽章组件

struct ActionBadgeCapsuleView: View {
    let badge: ActionBadgeModel
    let onTapTool: (String, String) -> Void
    var onTapRAG: ((String) -> Void)? = nil
    
    @State private var isHovered: Bool = false
    
    private var badgeThemeColor: Color {
        switch badge.type {
        case .tool(_, _, let status):
            switch status {
            case "success": return Color(hex: "#10B981")
            case "failed":  return Color(hex: "#EF4444")
            case "waiting": return Color.orange
            default:        return Color.purple
            }
        case .rag:
            return Color.cyan
        case .custom:
            return Color.indigo
        }
    }
    
    private var iconName: String {
        switch badge.type {
        case .tool(_, _, let status):
            switch status {
            case "success": return "checkmark.circle.fill"
            case "failed":  return "xmark.circle.fill"
            case "waiting": return "pause.circle.fill"
            default:        return "bolt.fill"
            }
        case .rag:
            return "books.vertical.fill"
        case .custom:
            return "link.circle.fill"
        }
    }
    
    var body: some View {
        Button(action: {
            switch badge.type {
            case .tool(let name, let callId, _):
                onTapTool(name, callId)
            case .rag(let id, _):
                onTapRAG?(id)
            case .custom:
                break
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: iconName)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(badgeThemeColor)
                
                Text(cleanTitle)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundColor(badgeThemeColor.opacity(0.95))
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(badgeThemeColor.opacity(isHovered ? 0.20 : 0.10))
            )
            .overlay(
                Capsule()
                    .stroke(badgeThemeColor.opacity(isHovered ? 0.50 : 0.28), lineWidth: 0.8)
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = h }
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .help("点击查看执行入参与返回详情")
    }
    
    private var cleanTitle: String {
        var str = badge.title
        for prefix in ["✓", "✕", "⚡︎", "⏸"] {
            if str.hasPrefix(prefix) {
                str = String(str.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return str
    }
}
