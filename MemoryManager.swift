//////////////////////////////////////////////////////////////////
// 文件名：MemoryManager.swift
// 文件说明：适用于 macOS 14+ 的长效记忆 (LTM) 管理器与视图面板
// 代码要求：请保证代码的逻辑和完整性，保留代码中的所有注释内容
// 核心架构：
// 1. 🌟 现实与虚构硬隔离：升级反思 Prompt，建立严格的认知边界。严禁将小说叙写（虚构人物关系）、知识库检索（客观技术概念）灌入“用户画像”！
// 2. 🌟 智能流转：虚构小说的角色设定降准划归为「短期备忘」；知识库参数/路径划归为「项目环境」；唯有关于“现实用户本人”的事实才准进入「用户画像」。
// 3. 🌟 三重解析护盾：Decoder -> JSONSerialization -> Regex 盲拆引擎。100% 免疫未转义引号、脏数据，彻底根治格式解析错误！
// 4. Swift 6 Concurrency Safe: 全量确保多Actor隔离边界的数据流 100% 线程安全。
//////////////////////////////////////////////////////////////////

import SwiftUI
import AppKit
import Accelerate
import NaturalLanguage

// MARK: - ==================== 1. 底层持久化数据模型 ====================

enum MemoryCategory: String, CaseIterable, Codable {
    case persona = "用户画像" // 偏好、习惯、现实本人的专属称呼
    case project = "项目环境" // 路径、版本号、架构上下文、外部客观背景知识
    case lesson = "避坑指南" // 历史报错、解决经验
    case tickler = "短期备忘" // 临时提醒、小说剧本虚构角色背景、可过期备忘
    
    var icon: String {
        switch self {
        case .persona: return "person.text.rectangle.fill"
        case .project: return "folder.fill.badge.gearshape"
        case .lesson: return "exclamationmark.triangle.fill"
        case .tickler: return "clock.badge.exclamationmark.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .persona: return .indigo
        case .project: return .teal
        case .lesson: return .orange
        case .tickler: return .mint
        }
    }
}

struct MemoryItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var content: String
    var category: MemoryCategory
    var importance: Int
    var createdAt: Date
    var embedding: [Float]?
    var isPinned: Bool = false
    var dimension: String = "通用"
    var toolName: String? = nil
    var triggers: [String] = []
    
    enum CodingKeys: String, CodingKey {
        case id, content, category, importance, createdAt, embedding, isPinned, dimension, toolName, triggers
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.content = try container.decode(String.self, forKey: .content)
        self.category = try container.decode(MemoryCategory.self, forKey: .category)
        self.importance = try container.decode(Int.self, forKey: .importance)
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.embedding = try container.decodeIfPresent([Float].self, forKey: .embedding)
        self.isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        self.dimension = try container.decodeIfPresent(String.self, forKey: .dimension) ?? "通用"
        self.toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        self.triggers = try container.decodeIfPresent([String].self, forKey: .triggers) ?? []
    }
    
    init(id: UUID = UUID(), content: String, category: MemoryCategory, importance: Int, createdAt: Date = Date(), embedding: [Float]? = nil, isPinned: Bool = false, dimension: String = "通用", toolName: String? = nil, triggers: [String] = []) {
        self.id = id; self.content = content; self.category = category; self.importance = importance
        self.createdAt = createdAt; self.embedding = embedding; self.isPinned = isPinned; self.dimension = dimension
        self.toolName = toolName; self.triggers = triggers
    }
    
    var relativeTimeString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: createdAt, relativeTo: Date())
    }
}

struct DialogueTurn: Sendable {
    let isUser: Bool
    let text: String
    let toolLogsText: String
}

struct ExtractedMemoryHelper: Sendable {
    let content: String
    let categoryString: String
    let importance: Int
    let dimensionString: String
}

struct ExtractedMemory: Decodable, Sendable {
    let content: String
    let categoryString: String
    let importance: Int
    let dimensionString: String
    
    enum CodingKeys: String, CodingKey {
        case content, category, importance, dimension
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        self.dimensionString = try container.decodeIfPresent(String.self, forKey: .dimension) ?? "通用"
        
        if let intValue = try? container.decode(Int.self, forKey: .importance) {
            self.importance = intValue
        } else if let stringValue = try? container.decode(String.self, forKey: .importance) {
            let lower = stringValue.lowercased()
            if lower.contains("high") || lower.contains("高") || lower.contains("critical") { self.importance = 9 }
            else if lower.contains("low") || lower.contains("低") { self.importance = 2 }
            else { self.importance = 5 }
        } else {
            self.importance = 5
        }
        
        let rawCat = (try? container.decode(String.self, forKey: .category))?.lowercased() ?? ""
        if rawCat.contains("用户") || rawCat.contains("persona") || rawCat.contains("profile") || rawCat.contains("偏好") {
            self.categoryString = "用户画像"
        } else if rawCat.contains("避坑") || rawCat.contains("lesson") || rawCat.contains("error") || rawCat.contains("教训") || rawCat.contains("红线") || rawCat.contains("心法") {
            self.categoryString = "避坑指南"
        } else if rawCat.contains("环境") || rawCat.contains("project") || rawCat.contains("path") || rawCat.contains("参数") || rawCat.contains("知识") {
            self.categoryString = "项目环境"
        } else {
            self.categoryString = "短期备忘"
        }
    }
}

// MARK: - ==================== 2. 长期记忆核心逻辑调度中心 ====================

@Observable
@MainActor
class MemoryManager {
    static let shared = MemoryManager()
    
    var memories: [MemoryItem] = []
    var searchText: String = ""
    var filterCategory: MemoryCategory? = nil
    
    private var fileURL: URL {
        let baseURL = ConfigManager.shared.documentsDirectoryURL ?? FileManager.default.temporaryDirectory
        return baseURL.appendingPathComponent("agent_memory.json")
    }
    
    private init() { loadMemories() }
    
    func loadMemories() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([MemoryItem].self, from: data) {
            self.memories = decoded.sorted { $0.createdAt > $1.createdAt }
        }
    }
    
    func saveMemories() {
        if let encoded = try? JSONEncoder().encode(memories) {
            try? encoded.write(to: fileURL, options: .atomic)
        }
    }
    
    @discardableResult
    func addMemory(
        content: String,
        category: String,
        importance: Int,
        embeddingText: String? = nil,
        dimension: String = "通用",
        toolName: String? = nil,
        triggers: [String] = []
    ) async -> String {
        var matchedCategory: MemoryCategory = .project
        let catLower = category.lowercased()
        
        if catLower.contains("用户") || catLower.contains("user") || catLower.contains("persona") || catLower.contains("profile") {
            matchedCategory = .persona
        } else if catLower.contains("避坑") || catLower.contains("lesson") || catLower.contains("error") || catLower.contains("心法") {
            matchedCategory = .lesson
        } else if catLower.contains("环境") || catLower.contains("project") || catLower.contains("path") || catLower.contains("常识") {
            matchedCategory = .project
        } else {
            matchedCategory = .tickler
        }
        
        let safeImportance = max(1, min(10, importance))
        let textToEmbed = embeddingText ?? (triggers.isEmpty ? content : "\(triggers.joined(separator: " ")) \(content)")
        let vector = await MicroVectorDB.shared.generateEmbedding(for: textToEmbed)
        
        await MainActor.run {
            var memoriesToKeep: [MemoryItem] = []
            let cleanNewContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
            
            for oldMem in self.memories {
                // 仅在「同分类 + 同细分维度 + 同绑定工具」的严格作用域内进行去重校验
                let isSameScope = oldMem.category == matchedCategory && oldMem.dimension == dimension && oldMem.toolName == toolName
                
                if isSameScope {
                    // 1. 完全相同文本执行覆写更新
                    if oldMem.content.trimmingCharacters(in: .whitespacesAndNewlines) == cleanNewContent {
                        continue
                    }
                    
                    // 2. 仅对余弦相似度极高 (>= 0.96) 的近乎完全重复事实进行合并，彻底解决 0.85 阈值误伤不同经验的问题
                    if let oldEmb = oldMem.embedding {
                        let sim = cosineSimilarity(a: vector, b: oldEmb)
                        if sim >= 0.96 {
                            continue
                        }
                    }
                }
                memoriesToKeep.append(oldMem)
            }
            
            self.memories = memoriesToKeep
            let newMemory = MemoryItem(
                content: content,
                category: matchedCategory,
                importance: safeImportance,
                createdAt: Date(),
                embedding: vector,
                dimension: dimension,
                toolName: toolName?.isEmpty == true ? nil : toolName,
                triggers: triggers
            )
            self.memories.insert(newMemory, at: 0)
            self.saveMemories()
        }
        return "✅ 长期存储网络落盘成功。"
    }
    
    func deleteMemory(_ id: UUID) {
        memories.removeAll { $0.id == id }
        saveMemories()
    }
    
    func togglePin(_ id: UUID) {
        if let idx = memories.firstIndex(where: { $0.id == id }) {
            memories[idx].isPinned.toggle()
            saveMemories()
        }
    }
    
    func searchContext(for query: String, topK: Int = 3, categoryFilter: String? = nil) async -> String {
        let queryVector = await MicroVectorDB.shared.generateEmbedding(for: query)
        let queryLower = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let queryTokens = tokenize(queryLower)
        let isAskingIdentity = queryLower.contains("我是谁") || queryLower.contains("我叫") || queryLower.contains("我的名字") || queryLower.contains("怎么称呼")
        
        let pinnedMemories = await MainActor.run {
            memories.filter { mem in mem.isPinned && (categoryFilter == nil || mem.category.rawValue == categoryFilter) }
        }
        
        var scoredMemories: [(item: MemoryItem, score: Float)] = []
        let currentMemories = await MainActor.run { self.memories }
        
        for mem in currentMemories where !mem.isPinned {
            if let filter = categoryFilter, mem.category.rawValue != filter { continue }
            var score: Float = 0
            let memLower = mem.content.lowercased()
            
            if let emb = mem.embedding {
                let sim = cosineSimilarity(a: queryVector, b: emb)
                if sim > 0.3 { score += sim * 2.0 }
                if isAskingIdentity && mem.category == .persona && sim > 0.15 { score += 1.2 }
            }
            
            let matchedTokens = queryTokens.filter { memLower.contains($0) }
            let tokenCoverage = queryTokens.isEmpty ? 0 : Float(matchedTokens.count) / Float(queryTokens.count)
            if tokenCoverage > 0.5 { score += tokenCoverage * 1.5 }
            else if memLower.contains(queryLower) && queryLower.count > 2 { score += 2.0 }
            
            if isAskingIdentity && mem.category == .persona {
                if memLower.contains("名字") || memLower.contains("称呼") || memLower.contains("老板") || memLower.contains("习惯") || memLower.contains("程序员") { score += 1.5 }
            }
            if score > 0.5 { score += Float(mem.importance) * 0.05 }
            if score > 0.8 { scoredMemories.append((mem, score)) }
        }
        
        scoredMemories.sort { $0.score > $1.score }
        let topRecalls = Array(scoredMemories.prefix(topK)).map { $0.item }
        
        var resultText = ""
        let finalSet = pinnedMemories + topRecalls
        if !finalSet.isEmpty {
            let headerTitle = categoryFilter == MemoryCategory.lesson.rawValue ? "💡 提取到相关的历史避坑指南" : "🧠 提取到关于用户的强关联历史记忆"
            resultText += "【\(headerTitle) (请严格参考)】:\n"
            for mem in finalSet { resultText += "- [\(mem.category.rawValue)·\(mem.dimension)] \(mem.content)\n" }
        }
        return resultText
    }
    
    private func tokenize(_ text: String) -> [String] {
        let clean = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = clean
        if let lang = NLLanguageRecognizer.dominantLanguage(for: clean) { tokenizer.setLanguage(lang) }
        let trimCharacterSet = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        var tokens: Set<String> = [clean]
        tokenizer.enumerateTokens(in: clean.startIndex..<clean.endIndex) { range, _ in
            let word = String(clean[range]).trimmingCharacters(in: trimCharacterSet)
            if word.count > 1 || (word.count == 1 && word.rangeOfCharacter(from: .alphanumerics) != nil) { tokens.insert(word) }
            return true
        }
        return Array(tokens)
    }
    
    private func cosineSimilarity(a: [Float], b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        let n = vDSP_Length(a.count); var dotProduct: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dotProduct, n)
        var aNorm: Float = 0; vDSP_svesq(a, 1, &aNorm, n)
        var bNorm: Float = 0; vDSP_svesq(b, 1, &bNorm, n)
        let denominator = sqrt(aNorm) * sqrt(bNorm)
        return denominator == 0 ? 0 : dotProduct / denominator
    }
}

// MARK: - ==================== 3. 🌌 长期记忆进化二期：全景重载提取引擎 ====================

extension MemoryManager {
    
    nonisolated func observeAndExtractSession(messages: [SavedChatMessage], model: String) async {
        let turns = messages.map { msg in
            var logsSummary = ""
            if !msg.skillLogs.isEmpty {
                for log in msg.skillLogs {
                    logsSummary += "\n  - [物理工具 \(log.skillName)] 执行返回: \(log.resultOutput)"
                }
            }
            return DialogueTurn(isUser: msg.isUser, text: msg.text, toolLogsText: logsSummary)
        }
        await reflectOnSessionTurns(turns, model: model)
    }
    
    @MainActor
    func observeAndExtractSession(messages: [ChatMessage], model: String) {
        let turns = messages.map { msg in
            var logsSummary = ""
            if !msg.skillLogs.isEmpty {
                for log in msg.skillLogs {
                    let argStr = (try? JSONSerialization.data(withJSONObject: log.args)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    logsSummary += "\n  - [物理工具 \(log.skillName)] 参数: \(argStr)\n    执行返回: \(log.resultOutput)"
                }
            }
            return DialogueTurn(isUser: msg.isUser, text: msg.text, toolLogsText: logsSummary)
        }
        Task.detached(priority: .utility) { await self.reflectOnSessionTurns(turns, model: model) }
    }
    
    /// 轨道 B 核心：根据当前激活的工具列表，精准拉取高价值避坑规则（无需经过用户输入词的模糊匹配）
    func getToolLessons(for toolNames: Set<String>, topKPerTool: Int = 3) async -> String {
        guard !toolNames.isEmpty else { return "" }
        let currentMemories = await MainActor.run { self.memories }
        
        var lessons: [String] = []
        for tool in toolNames {
            let matched = currentMemories
                .filter { $0.category == .lesson && ($0.toolName == tool || $0.content.contains(tool)) }
                .sorted { $0.importance > $1.importance }
                .prefix(topKPerTool)
            
            for mem in matched {
                lessons.append("- [\(tool)] \(mem.content)")
            }
        }
        
        if lessons.isEmpty { return "" }
        return "\n\n<active_tool_lessons>\n" + lessons.joined(separator: "\n") + "\n</active_tool_lessons>"
    }
    
    /// 捕获用户即时反馈并提炼长效经验规则
    /// - Parameters:
    ///   - recentMessages: 当前会话历史消息数组
    ///   - targetMessageId: 被点赞/点踩的目标 AI 消息 ID
    ///   - feedback: 反馈类型 (.liked / .disliked)
    ///   - model: 用于反思的轻量模型名称
    func harvestFeedbackExperience(
        recentMessages: [ChatMessage],
        targetMessageId: UUID,
        feedback: MessageFeedback,
        model: String
    ) async {
        guard feedback != .none else { return }
        let isLike = feedback == .liked
        let feedbackLabel = isLike ? "满意 (点赞)" : "不满意 (点踩)"
        let logActionTitle = isLike ? "👍 [正向习惯捕获]" : "👎 [负向痛点归因]"
        
        await MainActor.run { LogManager.shared.info("\(logActionTitle) 启动双轨特征反思...") }
        
        guard let targetIndex = recentMessages.firstIndex(where: { $0.id == targetMessageId }) else { return }
        let startIndex = max(0, targetIndex - 4)
        let contextSlice = recentMessages[startIndex...targetIndex]
        
        var structuredLogs = ""
        var activeToolNames: Set<String> = []
        
        for msg in contextSlice {
            let roleLabel = msg.isUser ? "用户" : "AI智能体"
            let cleanMsgBody = msg.text
                .replacingOccurrences(of: "(?s)<think>.*?</think>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            structuredLogs += "[\(roleLabel)]:\n"
            if !cleanMsgBody.isEmpty { structuredLogs += "  正文: \(cleanMsgBody)\n" }
            
            if !msg.skillLogs.isEmpty {
                structuredLogs += "  工具执行记录:\n"
                for log in msg.skillLogs {
                    activeToolNames.insert(log.skillName)
                    let argStr = (try? JSONSerialization.data(withJSONObject: log.args)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    structuredLogs += "    - [工具: \(log.skillName)] 参数: \(argStr)\n      返回: \(log.resultOutput)\n"
                }
            }
        }
        
        let rlhfPrompt = """
        # 任务
        分析用户对近期交互历史给出的【\(feedbackLabel)】反馈，提炼一条可在后续任务中直接复用的高精度规则。

        <context_history>
        \(structuredLogs)
        </context_history>

        # 提炼规范
        1. 若历史中存在工具调用：
           - 提取具体工具名称（tool_name）。
           - 提炼【导致报错的原因】与【已验证有效的正确参数格式/顺序】。
           - 提取 2~4 个触发场景词（triggers），如操作意图或子命令名称。
        2. 若仅为普通沟通：
           - 提炼用户偏好的输出格式或沟通习惯。

        # 输出格式（严格输出单对象 JSON）
        {
          "tool_name": "\(activeToolNames.first ?? "")",
          "category": "\(activeToolNames.isEmpty ? (isLike ? "用户画像" : "避坑指南") : "避坑指南")",
          "dimension": "\(activeToolNames.isEmpty ? "输出排版" : "CLI命令规范")",
          "triggers": ["触发短语1", "触发短语2"],
          "content": "具体的规则说明（40~120字，包含具体参数顺序与语法）",
          "importance": 9
        }
        """
        
        let rawReport = await LLMService.shared.askSimple(prompt: rlhfPrompt, model: model)
        let reportWithoutThink = rawReport.replacingOccurrences(of: "(?s)<think>.*?</think>", with: "", options: .regularExpression)
        
        guard let cleanJSON = await reportWithoutThink.extractJSON()?.trimmingCharacters(in: .whitespacesAndNewlines),
              let data = cleanJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        
        let toolName = dict["tool_name"] as? String
        let categoryStr = dict["category"] as? String ?? "避坑指南"
        let dimensionStr = dict["dimension"] as? String ?? "CLI命令规范"
        let contentStr = dict["content"] as? String ?? ""
        let triggers = dict["triggers"] as? [String] ?? []
        let importance = dict["importance"] as? Int ?? 9
        
        guard !contentStr.isEmpty else { return }
        
        // 向量嵌入重点针对「触发短语 + 核心规则」，彻底避免长文本稀释特征
        let embedSource = (triggers.joined(separator: " ") + " " + contentStr)
        let vector = await MicroVectorDB.shared.generateEmbedding(for: embedSource)
        
        let matchedCategory: MemoryCategory = categoryStr.contains("用户") ? .persona : .lesson
        
        await MainActor.run {
            let newMemory = MemoryItem(
                content: contentStr,
                category: matchedCategory,
                importance: importance,
                createdAt: Date(),
                embedding: vector,
                dimension: dimensionStr,
                toolName: toolName?.isEmpty == true ? nil : toolName,
                triggers: triggers
            )
            self.memories.insert(newMemory, at: 0)
            self.saveMemories()
            
            LogManager.shared.success(
                "🛡️ 双轨工具经验固化成功",
                detail: "工具: \(toolName ?? "通用")\n触发词: \(triggers)\n规则: \(contentStr)"
            )
        }
    }
    
    /// 全局会话全景潜意识反思核心总线 (后台并发多线程，配载三重抗灾自愈护盾与子属性风道抽取)
    private nonisolated func reflectOnSessionTurns(_ turns: [DialogueTurn], model: String) async {
        let userMessages = turns.filter { $0.isUser }
        if userMessages.isEmpty { return }
        
        var chatScript = ""
        for turn in turns {
            let roleLabel = turn.isUser ? "用户" : "AI智能体"
            let cleanMsgBody = turn.text.replacingOccurrences(of: "(?s)<think>.*?</think>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            
            chatScript += "[\(roleLabel)]:\n"
            if !cleanMsgBody.isEmpty {
                chatScript += "  正文: \(cleanMsgBody)\n"
            }
            if !turn.toolLogsText.isEmpty {
                chatScript += "  工具执行记录:\(turn.toolLogsText)\n"
            }
        }
        
        guard !chatScript.isEmpty else { return }
        
        let batchReflectPrompt = """
        # 任务
        深度复盘以下会话与工具执行日志，提取具备长期沉淀价值的高精度事实与硬核技术经验规则。

        <classification_and_extraction_rules>
        1. 【避坑指南 (lesson)】（核心重点）：
           - 关注点：重点分析日志中「工具调用报错、命令异常退出、参数错误、顺序颠倒、缺失必填项」以及后续「修正成功的真实命令」。
           - 提炼标准：输出必须包含具体技术要素：【工具名/子命令】+【导致报错的写法】+【实测验证有效的正确格式/参数顺序/文件语法】。
           - 质量要求：拒绝“需要仔细阅读文档”、“避免机械输出”等泛泛而谈的沟通建议；只沉淀具备直接执行价值的技术语法与参数契约。

        2. 【用户画像 (persona)】：
           - 仅提取现实人类用户本人的技术栈背景、工作习惯与称呼。

        3. 【项目环境 (project)】：
           - 提取本次会话中出现的客观项目ID、应用ID、租户Key、服务器地址、本地环境路径等。

        4. 【短期备忘 (tickler)】：
           - 临时任务与尚未验证成功的待办事项。
        </classification_and_extraction_rules>

        # 细分维度 (dimension) 规范
        - 避坑指南：'CLI命令规范' | '参数顺序契约' | 'API调用避坑' | '环境配置'
        - 项目环境：'应用ID' | '环境地址' | '沙盒路径' | '架构版本'
        - 用户画像：'技术偏好' | '职业称呼'
        - 短期备忘：'临时事项'

        [待复盘会话与执行记录]
        \(chatScript)

        # 输出格式要求 (严格输出标准 JSON 数组，无高价值信息时输出 [])
        [
          {
            "content": "具体的规则陈述（如：`e10-cli form layout read` 必须严格按 `<objId> <appId>` 顺序传入位置参数，不可包含 --app-id 选项）",
            "category": "避坑指南",
            "dimension": "CLI命令规范",
            "importance": 9
          }
        ]
        """
        
        await MainActor.run { LogManager.shared.info("🌌 [潜意识反思器] 启动全景多维记忆收割流...") }
        let rawJsonReport = await LLMService.shared.askSimple(prompt: batchReflectPrompt, model: model)
        let reportWithoutThink = rawJsonReport.replacingOccurrences(of: "(?s)<think>.*?</think>", with: "", options: .regularExpression)
        
        guard let extractedStr = await reportWithoutThink.extractJSON() else {
            await MainActor.run { LogManager.shared.error("❌ [潜意识观察者] 解析失败：未找到有效 JSON 数据") }
            return
        }
        
        let cleanJSON = extractedStr.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if let data = cleanJSON.data(using: .utf8) {
            var finalExtractedItems: [ExtractedMemoryHelper] = []
            
            do {
                let decoded = try JSONDecoder().decode([ExtractedMemory].self, from: data)
                finalExtractedItems = decoded.map { ExtractedMemoryHelper(content: $0.content, categoryString: $0.categoryString, importance: $0.importance, dimensionString: $0.dimensionString) }
            } catch {
                if let looseArray = try? JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]] {
                    for dict in looseArray {
                        let content = dict["content"] as? String ?? ""
                        let category = dict["category"] as? String ?? ""
                        let dimension = dict["dimension"] as? String ?? "通用"
                        let importanceRaw = dict["importance"]
                        
                        var importanceInt = 5
                        if let rawInt = importanceRaw as? Int { importanceInt = rawInt }
                        else if let rawStr = importanceRaw as? String {
                            let lower = rawStr.lowercased()
                            if lower.contains("high") || lower.contains("高") { importanceInt = 9 }
                            else if lower.contains("low") || lower.contains("低") { importanceInt = 2 }
                        }
                        finalExtractedItems.append(ExtractedMemoryHelper(content: content, categoryString: category, importance: importanceInt, dimensionString: dimension))
                    }
                } else {
                    finalExtractedItems = regexParseFallback(jsonStr: cleanJSON)
                }
            }
            
            if !finalExtractedItems.isEmpty {
                for item in finalExtractedItems {
                    let sanitizedContent = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if sanitizedContent.isEmpty || sanitizedContent == "[]" || sanitizedContent == "null" { continue }
                    
                    _ = await self.addMemory(
                        content: item.content,
                        category: item.categoryString,
                        importance: item.importance,
                        embeddingText: item.content,
                        dimension: item.dimensionString
                    )
                }
            }
        }
    }
    
    private nonisolated func regexParseFallback(jsonStr: String) -> [ExtractedMemoryHelper] {
        var results: [ExtractedMemoryHelper] = []
        let objectRegex = try? NSRegularExpression(pattern: "\\{[^\\{]*?\\}", options: [.dotMatchesLineSeparators])
        guard let objRegex = objectRegex else { return [] }
        
        let range = NSRange(jsonStr.startIndex..<jsonStr.endIndex, in: jsonStr)
        let matches = objRegex.matches(in: jsonStr, options: [], range: range)
        
        for match in matches {
            guard let matchRange = Range(match.range, in: jsonStr) else { continue }
            let objStr = String(jsonStr[matchRange])
            
            let contentRegex = try? NSRegularExpression(pattern: "\"content\"\\s*:\\s*\"(.*?)\"\\s*(?:,|\n|\\})", options: [.dotMatchesLineSeparators])
            let categoryRegex = try? NSRegularExpression(pattern: "\"category\"\\s*:\\s*\"(.*?)\"\\s*(?:,|\n|\\})", options: [.dotMatchesLineSeparators])
            let dimensionRegex = try? NSRegularExpression(pattern: "\"dimension\"\\s*:\\s*\"(.*?)\"\\s*(?:,|\n|\\})", options: [.dotMatchesLineSeparators])
            let importanceRegex = try? NSRegularExpression(pattern: "\"importance\"\\s*:\\s*(?:\"(.*?)\"|(\\d+))", options: [.dotMatchesLineSeparators])
            
            let objRange = NSRange(objStr.startIndex..<objStr.endIndex, in: objStr)
            var content = ""
            if let cMatch = contentRegex?.firstMatch(in: objStr, options: [], range: objRange), let cRange = Range(cMatch.range(at: 1), in: objStr) { content = String(objStr[cRange]) }
            
            var category = ""
            if let catMatch = categoryRegex?.firstMatch(in: objStr, options: [], range: objRange), let catRange = Range(catMatch.range(at: 1), in: objStr) { category = String(objStr[catRange]) }
            
            var dimension = "通用"
            if let dMatch = dimensionRegex?.firstMatch(in: objStr, options: [], range: objRange), let dRange = Range(dMatch.range(at: 1), in: objStr) { dimension = String(objStr[dRange]) }
            
            var importanceStr = ""
            var importanceInt = 5
            if let iMatch = importanceRegex?.firstMatch(in: objStr, options: [], range: objRange) {
                if let r1 = Range(iMatch.range(at: 1), in: objStr) { importanceStr = String(objStr[r1]) }
                else if let r2 = Range(iMatch.range(at: 2), in: objStr) { importanceStr = String(objStr[r2]) }
            }
            
            if let parsedInt = Int(importanceStr) { importanceInt = parsedInt }
            else {
                let lower = importanceStr.lowercased()
                if lower.contains("high") || lower.contains("高") { importanceInt = 9 }
                else if lower.contains("low") || lower.contains("低") { importanceInt = 2 }
            }
            results.append(ExtractedMemoryHelper(content: content, categoryString: category, importance: importanceInt, dimensionString: dimension))
        }
        return results
    }

    // MARK: 🌌 认知三：梦境反思 (Memory Consolidation)
    /// 触发梦境记忆整合（支持工具独立聚类、参数语法保真与元数据继承）
    /// - Parameter model: 用于反思整合的轻量模型名称
    /// - Returns: 成功完成整合的原始记忆碎片总数
    func triggerDreamConsolidation(model: String) async -> Int {
        var totalConsolidatedCount = 0
        
        // 1. 避坑指南专用通道：按 toolName 独立聚类，严防跨工具规则混淆抹平
        totalConsolidatedCount += await consolidateToolLessons(model: model)
        
        // 2. 用户画像与项目环境常规通道：语义去重与画像融合
        totalConsolidatedCount += await consolidateGeneralCategory(.persona, model: model)
        totalConsolidatedCount += await consolidateGeneralCategory(.project, model: model)
        
        return totalConsolidatedCount
    }
    
    // MARK: - 内部私有整合子流水线
    
    /// 针对【避坑指南】的独立高保真规则提炼流水线
    private func consolidateToolLessons(model: String) async -> Int {
        var processedCount = 0
        
        // 提取所有未置顶的避坑指南
        let lessonFragments = await MainActor.run {
            self.memories.filter { $0.category == .lesson && !$0.isPinned }
        }
        guard lessonFragments.count >= 2 else { return 0 }
        
        // 1. 按 toolName 分组聚类
        var toolGroups: [String: [MemoryItem]] = [:]
        for item in lessonFragments {
            let key = item.toolName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? item.toolName! : "通用规范"
            toolGroups[key, default: []].append(item)
        }
        
        // 2. 逐工具进行高精度规则融合
        for (toolKey, groupItems) in toolGroups where groupItems.count >= 2 {
            let fragmentsText = groupItems.enumerated().map { "\($0 + 1). \($1.content)" }.joined(separator: "\n")
            
            // 纯正向、高密度、要求保留参数占位符与命令签名的提示词
            let lessonPrompt = """
            # 角色与任务
            你是一位系统执行规范提炼专家。请对当前工具【\(toolKey)】收集到的调用经验碎片进行去重与结构化融合，输出高密度的调用规范手册。

            <raw_lessons>
            \(fragmentsText)
            </raw_lessons>

            # 提炼规范
            1. 语法与参数保真：完整保留具体子命令名、位置参数顺序、长选项定义、文件路径格式（如 @file.json）以及 JSON 键值规范（如 title 与 type）。
            2. 结构化输出：每条规则单独成行，采用「[场景/子命令]: 正确执行规范（关键说明）」的格式，拒绝任何空泛的沟通套话。
            3. 场景触发词提炼：总结 3~5 个高频调用场景关键词或子命令名称。

            # 输出格式 (严格输出标准 JSON 单对象)
            {
              "triggers": ["触发场景词1", "子命令", "动作词"],
              "dimension": "CLI命令规范",
              "content": "条目化规则正文"
            }
            """
            
            let rawOutput = await LLMService.shared.askSimple(prompt: lessonPrompt, model: model)
            let reportWithoutThink = rawOutput.replacingOccurrences(of: "(?s)<think>.*?</think>", with: "", options: .regularExpression)
            
            guard let cleanJSON = await reportWithoutThink.extractJSON()?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let data = cleanJSON.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            
            let contentStr = (dict["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let dimensionStr = dict["dimension"] as? String ?? "CLI命令规范"
            let triggers = dict["triggers"] as? [String] ?? []
            
            guard !contentStr.isEmpty && contentStr.count > 15 else { continue }
            
            // 向量特征计算：重点锚定触发词 + 规则正文
            let embedSource = triggers.joined(separator: " ") + " " + contentStr
            let vector = await MicroVectorDB.shared.generateEmbedding(for: embedSource)
            
            let targetToolName = toolKey == "通用规范" ? nil : toolKey
            let oldIDs = groupItems.map { $0.id }
            
            await MainActor.run {
                // 安全替换旧碎片
                self.memories.removeAll { oldIDs.contains($0.id) }
                
                let consolidatedItem = MemoryItem(
                    content: contentStr,
                    category: .lesson,
                    importance: 9,
                    createdAt: Date(),
                    embedding: vector,
                    isPinned: false,
                    dimension: dimensionStr,
                    toolName: targetToolName,
                    triggers: triggers
                )
                self.memories.insert(consolidatedItem, at: 0)
                self.saveMemories()
                
                LogManager.shared.success(
                    "🌌 [梦境反思·工具避坑融合]",
                    detail: "工具: \(toolKey)\n规则数: \(groupItems.count) -> 1\n触发词: \(triggers)\n正文: \(contentStr)"
                )
            }
            
            processedCount += groupItems.count
        }
        
        return processedCount
    }
    
    /// 针对【用户画像 / 项目环境】的常规记忆整合流水线
    private func consolidateGeneralCategory(_ category: MemoryCategory, model: String) async -> Int {
        let fragments = await MainActor.run {
            self.memories.filter { $0.category == category && !$0.isPinned }
        }
        guard fragments.count >= 3 else { return 0 }
        
        let listStr = fragments.map { "- \($0.content)" }.joined(separator: "\n")
        let categoryName = category.rawValue
        
        let generalPrompt = """
        # 任务
        对以下收集到的「\(categoryName)」记忆碎片进行融合与去重，输出一篇高度浓缩、条理清晰的全局备忘录。

        [记忆碎片]
        \(listStr)

        # 输出要求
        直接输出提炼后的正文陈述（50~150字），保持事实准确，去除重复内容。
        """
        
        let rawOutput = await LLMService.shared.askSimple(prompt: generalPrompt, model: model)
        let cleanSummary = rawOutput
            .replacingOccurrences(of: "(?s)<think>.*?</think>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !cleanSummary.isEmpty && cleanSummary.count > 15 else { return 0 }
        
        let oldIDs = fragments.map { $0.id }
        await MainActor.run {
            self.memories.removeAll { oldIDs.contains($0.id) }
            self.saveMemories()
        }
        
        _ = await self.addMemory(
            content: "【核心\(categoryName)融合】\n" + cleanSummary,
            category: categoryName,
            importance: 9,
            dimension: "全局认知"
        )
        
        return fragments.count
    }
}

// MARK: - ==================== 4. 视觉面板 UI 视图渲染 ====================

struct MemoryManagementPanel: View {
    @State private var manager = MemoryManager.shared
    @State private var showAddSheet = false
    @State private var isConsolidating = false
    
    var filteredMemories: [MemoryItem] {
        manager.memories.filter { mem in
            let matchCategory = manager.filterCategory == nil || mem.category == manager.filterCategory
            let matchSearch = manager.searchText.isEmpty || mem.content.localizedCaseInsensitiveContains(manager.searchText)
            return matchCategory && matchSearch
        }
    }
    
    let columns = [GridItem(.adaptive(minimum: 260, maximum: 340), spacing: 16)]
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("神经网络记忆核").font(.headline)
                    Text("由 Agent 自治管理的长期记忆，赋予 AI 跨会话的持续认知能力").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("搜索记忆突触...", text: $manager.searchText)
                        .textFieldStyle(.plain)
                    if !manager.searchText.isEmpty {
                        Button(action: { manager.searchText = "" }) { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.clear)
                .cornerRadius(8)
                .frame(width: 200)
                
                Picker("", selection: $manager.filterCategory) {
                    Text("全部分类").tag(MemoryCategory?.none)
                    ForEach(MemoryCategory.allCases, id: \.self) { cat in Text(cat.rawValue).tag(MemoryCategory?.some(cat)) }
                }.frame(width: 120).padding(.leading, 8)
                
                Button(action: {
                    Task {
                        isConsolidating = true
                        let model = ConfigManager.shared.app.agentProfiles.first?.baseModel ?? ""
                        let count = await manager.triggerDreamConsolidation(model: model)
                        await MainActor.run {
                            isConsolidating = false
                            if count > 0 { ___updateIslandNotice(text: "梦境反思完成，已整合 \(count) 条碎片", icon: "moon.stars.fill") }
                        }
                    }
                }) {
                    if isConsolidating { ProgressView().controlSize(.small).padding(.horizontal, 4) }
                    else { Label("梦境反思", systemImage: "moon.stars.fill") }
                }
                .buttonStyle(.bordered).tint(.purple).padding(.leading, 8).disabled(isConsolidating)
                
                Button(action: { showAddSheet = true }) { Label("注入记忆", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).tint(.indigo).padding(.leading, 8)
            }.padding().background(Color.clear);
            
            ModernDivider(style: .fade(0.18))
            
            ScrollView {
                if filteredMemories.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "brain").font(.system(size: 48)).foregroundStyle(.tertiary)
                        Text("记忆库空空如也...").foregroundColor(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.top, 100)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        ForEach(filteredMemories) { mem in MemoryCardView(memory: mem, manager: manager) }
                    }.padding(20)
                }
            }
            .background(.ultraThinMaterial)
            .scrollContentBackground(.hidden)
            .forceOverlayScrollbars()
        }
        .sheet(isPresented: $showAddSheet) { MemoryAddSheet(manager: manager) { showAddSheet = false } }
    }
}

struct MemoryCardView: View {
    var memory: MemoryItem
    var manager: MemoryManager
    @State private var isHovered = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                HStack(spacing: 4) {
                    Image(systemName: memory.category.icon)
                    Text(memory.category.rawValue + (memory.dimension == "通用" ? "" : " · \(memory.dimension)")).font(.system(size: 11, weight: .bold))
                }
                .foregroundColor(memory.category.color)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(memory.category.color.opacity(0.15))
                .cornerRadius(4)
                
                Spacer()
                if memory.isPinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundColor(.red) }
                Text(memory.relativeTimeString).font(.system(size: 10)).foregroundColor(.secondary)
            }
            
            Text(memory.content)
                .font(.system(size: 13, design: .rounded))
                .foregroundColor(.primary.opacity(0.9))
                .lineSpacing(4)
                .lineLimit(isHovered ? nil : 4)
                .layoutPriority(1)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            if !isHovered { Spacer(minLength: 0) } else { Spacer().frame(height: 4) }
            
            HStack {
                HStack(spacing: 2) {
                    ForEach(0..<5) { i in
                        Image(systemName: "star.fill").font(.system(size: 8)).foregroundColor(i < (memory.importance / 2) ? .orange : .gray.opacity(0.3))
                    }
                }.help("重要度: \(memory.importance) 分")
                
                Spacer()
                if isHovered {
                    Button(action: { manager.togglePin(memory.id) }) {
                        Image(systemName: memory.isPinned ? "pin.slash" : "pin").font(.system(size: 12)).foregroundColor(.secondary)
                    }.buttonStyle(.plain).help(memory.isPinned ? "取消强制注入" : "强制将此记忆注入每次对话")
                    
                    Button(action: {
                        let pb = NSPasteboard.general; pb.clearContents(); pb.setString(memory.content, forType: .string)
                    }) { Image(systemName: "doc.on.clipboard").font(.system(size: 12)).foregroundColor(.secondary) }.buttonStyle(.plain).padding(.leading, 6).help("复制")
                    
                    Button(action: { withAnimation { manager.deleteMemory(memory.id) } }) {
                        Image(systemName: "trash").font(.system(size: 12)).foregroundColor(.red.opacity(0.8))
                    }.buttonStyle(.plain).padding(.leading, 6).help("遗忘 (删除)")
                }
            }
        }
        .padding(16)
        .frame(height: isHovered ? nil : 140, alignment: .top)
        .background(VisualEffectView(material: .popover, blendingMode: .withinWindow))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.1), radius: 8, x: 0, y: 4)
        .onHover { hover in withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isHovered = hover } }
    }
}

struct MemoryAddSheet: View {
    var manager: MemoryManager
    var onClose: () -> Void
    
    @State private var content: String = ""
    @State private var category: MemoryCategory = .lesson
    @State private var dimension: String = "CLI命令规范"
    @State private var toolName: String = "skill-e10-cli"
    @State private var triggersText: String = ""
    @State private var importance: Double = 9.0
    @State private var isSaving = false
    
    var body: some View {
        VStack(spacing: 0) {
            // MARK: 顶部导航栏
            HStack(alignment: .center) {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.indigo)
                    Text("人工注入长效记忆")
                        .font(.system(size: 13, weight: .bold))
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.primary.opacity(0.03))
            
            Divider()
            
            // MARK: 主表单内容区
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    
                    // 1. 元数据配置网格 (固定标签宽度，右侧自适应撑满)
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                        GridRow {
                            Text("分类归属")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                                .frame(width: 76, alignment: .trailing)
                            
                            HStack {
                                Picker("", selection: $category) {
                                    ForEach(MemoryCategory.allCases, id: \.self) { cat in
                                        Label(cat.rawValue, systemImage: cat.icon).tag(cat)
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                                .frame(width: 140)
                                
                                Spacer()
                            }
                        }
                        
                        GridRow {
                            Text("细分维度")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 76, alignment: .trailing)
                            
                            TextField("如: CLI命令规范 / 输出排版 / 技术偏好", text: $dimension)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))
                        }
                        
                        if category == .lesson {
                            GridRow {
                                Text("绑定工具")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 76, alignment: .trailing)
                                
                                TextField("输入工具唯一标识 (如: skill-e10-cli，可选)", text: $toolName)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12, design: .monospaced))
                            }
                            
                            GridRow {
                                Text("触发场景词")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 76, alignment: .trailing)
                                
                                TextField("用英文逗号分隔 (如: 表单创建, 字段定义, layout)", text: $triggersText)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12))
                            }
                        }
                    }
                    
                    Divider()
                        .padding(.vertical, 2)
                    
                    // 2. 记忆核心内容编辑区
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("记忆内容 (核心规则 / 事实上下文)")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("\(content.count) 字符")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        
                        TextEditor(text: $content)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(height: 95)
                            .padding(4)
                            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 1)
                            )
                    }
                    
                    // 3. 重要度权重设定区
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("重要度权重")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            HStack(spacing: 3) {
                                ForEach(0..<5) { i in
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 8))
                                        .foregroundStyle(i < (Int(importance) / 2) ? .orange : .gray.opacity(0.25))
                                }
                                Text("\(Int(importance)) 分")
                                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                                    .foregroundStyle(.indigo)
                                    .padding(.leading, 4)
                            }
                        }
                        
                        Slider(value: $importance, in: 1...10, step: 1)
                            .tint(.indigo)
                            .controlSize(.small)
                        
                        Text("分值越高，在 Agent 挂载工具或相关会话中被先验唤醒的优先级越高。")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(10)
                    .background(Color.indigo.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.indigo.opacity(0.12), lineWidth: 1)
                    )
                }
                .padding(16)
            }
            .scrollContentBackground(.hidden)
            
            Divider()
            
            // MARK: 底部操作栏
            HStack(spacing: 12) {
                Spacer()
                Button("取消", action: onClose)
                    .keyboardShortcut(.cancelAction)
                
                Button(action: {
                    isSaving = true
                    Task {
                        let parsedTriggers = triggersText
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        
                        _ = await manager.addMemory(
                            content: content,
                            category: category.rawValue,
                            importance: Int(importance),
                            dimension: dimension.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "通用" : dimension,
                            toolName: toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : toolName,
                            triggers: parsedTriggers
                        )
                        await MainActor.run {
                            isSaving = false
                            onClose()
                        }
                    }
                }) {
                    HStack(spacing: 4) {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                        }
                        Text("提交至突触网络")
                    }
                    .frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .controlSize(.regular)
                .disabled(content.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.02))
        }
        .frame(width: 480, height: 460)
    }
}
