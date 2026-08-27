//////////////////////////////////////////////////////////////////
// 文件名：KnowledgeManager.swift
// 文件说明：适用于 macOS 14+ 的知识库管理与 RAG (检索增强生成) 引擎
// 核心架构：
// 1. 混合检索 (Hybrid Search): BM25 + Vector 倒数排名融合 (RRF)
// 2. 纯 Swift 微型向量数据库: 无缝集成、极低资源占用
// 3. 语义级 RAG 切片: 基于自然语言的智能滑动窗口机制
// 4. 目录树形双栏 UI: 左侧无限极树状分类，右键可递归全选
// 5. 沉浸式悬浮操作台: 列表项操作和启停开关转为 macOS 原生悬浮图标，极大释放横向空间
// 6. 结构化代码提取与专属代码摘要策略: 保护特殊语法边界并以架构师视角进行高维代码总结
// 7. 并发节流与后台脱轨引擎: 彻底解决海量文件扫描与提取导致的 UI 卡死问题
// 8. 层级智能排序与面包屑导航: 优先展示当前直属文件，清晰标注子文件相对路径来源
// 9. 导入路径优化：选择文件夹导入时，自动剥离所选文件夹自身的目录名，直接以其内容作为分类根目录
// 10. 虚拟路径编辑：支持直接在 UI 中编辑多级目录，严格只读保护底层文件路径
// 11. 双阶段检索架构：引入滑动窗口的 Native Sentence Level 精排引擎，大幅提升召回精确度
//////////////////////////////////////////////////////////////////

//////////////////////////////////////////////////////////////////
// 文件名：KnowledgeManager.swift
// 文件说明：适用于 macOS 14+ 的知识库管理与自适应 RAG 引擎
// 核心升级：
// 1. 废除手动分类策略，改为切片级元数据自适应感知 (Self-Adaptive Retrieval)
// 2. 物理隔离标签与禁忌词，彻底防止负向词污染 Embedding
// 3. 2-Gram 连续短语增强与负向词一票否决 (Hard Veto)
// 4. 切片预览、检索测试与 Agent 检索面板全链路显化结构化元数据徽章
//////////////////////////////////////////////////////////////////

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Accelerate
import PDFKit
import NaturalLanguage

// MARK: - ==================== 1. 核心数据模型 ====================

public struct ChunkMetadata: Codable, Equatable, Sendable {
    public var title: String?
    public var headingPath: [String] = []
    public var positiveTags: [String] = []  // 正向标签 (tags, 标签)
    public var negativeTags: [String] = []  // 负向/禁用标签 (prohibited, exclude, 禁用)
    public var kvPairs: [String: String] = [:]
    
    public init(title: String? = nil, headingPath: [String] = [], positiveTags: [String] = [], negativeTags: [String] = [], kvPairs: [String : String] = [:]) {
        self.title = title
        self.headingPath = headingPath
        self.positiveTags = positiveTags
        self.negativeTags = negativeTags
        self.kvPairs = kvPairs
    }
}

struct KnowledgeItem: Identifiable, Hashable, Codable, Equatable {
    var id = UUID()
    var title: String
    var summary: String
    var chunkCount: Int
    var status: String
    var isEnabled: Bool = true
    var category: String = "默认"
    var filePath: String?
    var metaEmbedding: [Float]?
    var relativePath: String?
    
    enum CodingKeys: String, CodingKey {
        case id, title, summary, chunkCount, status, isEnabled, category, filePath, metaEmbedding, relativePath
    }
    
    init(title: String, summary: String, chunkCount: Int, status: String, isEnabled: Bool = true, category: String = "默认", filePath: String? = nil, metaEmbedding: [Float]? = nil, relativePath: String? = nil) {
        self.title = title
        self.summary = summary
        self.chunkCount = chunkCount
        self.status = status
        self.isEnabled = isEnabled
        self.category = category
        self.filePath = filePath
        self.metaEmbedding = metaEmbedding
        self.relativePath = relativePath
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decode(String.self, forKey: .summary)
        chunkCount = try container.decode(Int.self, forKey: .chunkCount)
        status = try container.decode(String.self, forKey: .status)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? "默认"
        filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
        metaEmbedding = try container.decodeIfPresent([Float].self, forKey: .metaEmbedding)
        relativePath = try container.decodeIfPresent(String.self, forKey: .relativePath)
    }
}

// MARK: - ==================== 2. 知识库 ViewModel 引擎 ====================

@Observable
@MainActor
class KnowledgeViewModel {
    
    var knowledgeBases: [KnowledgeItem] = []
    var categories: [String] = ["默认"]
    var dedicatedCategories: [String] = []
    
    var allCategories: [String] {
        return categories + dedicatedCategories
    }
    
    var editingKnowledge: KnowledgeItem?
    var knowledgeToDelete: KnowledgeItem?
    
    let supportedExtensions: Set<String> = [
        "pdf", "txt", "md", "csv", "json", "xml", "html", "css",
        "swift", "py", "java", "c", "cpp", "h", "cs", "js", "ts", "go", "rs", "php", "sh",
        "doc", "docx", "rtf", "rtfd", "xlsx"
    ]
    
    private var knowledgeFileURL: URL = ConfigManager.shared.ragMetaFileName!
    
    init() {
        loadKnowledge()
    }
    
    func loadKnowledge() {
        if let data = try? Data(contentsOf: knowledgeFileURL),
           let decoded = try? JSONDecoder().decode([KnowledgeItem].self, from: data) {
            self.knowledgeBases = decoded
        }
        
        self.categories = ConfigManager.shared.app.generalConfig.kCategories
        self.dedicatedCategories = ConfigManager.shared.app.generalConfig.dedicatedKCategories
        
        if !self.categories.contains("默认") { self.categories.insert("默认", at: 0) }
        MicroVectorDB.shared.load()
    }
    
    func saveKnowledgeMeta() {
        if let encoded = try? JSONEncoder().encode(knowledgeBases) {
            try? encoded.write(to: knowledgeFileURL, options: .atomic)
        }
    }
    
    func saveCategories() {
        ConfigManager.shared.app.generalConfig.kCategories = categories
        ConfigManager.shared.app.generalConfig.dedicatedKCategories = dedicatedCategories
        ConfigManager.shared.saveConfig()
    }
    
    func addCategory(_ name: String, isDedicated: Bool = false) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !categories.contains(trimmed), !dedicatedCategories.contains(trimmed) else { return }
        
        if isDedicated { dedicatedCategories.append(trimmed) }
        else { categories.append(trimmed) }
        saveCategories()
    }
    
    func renameCategory(oldName: String, newName: String, isDedicated: Bool) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, oldName != "默认", !categories.contains(trimmed), !dedicatedCategories.contains(trimmed) else { return }
        
        if isDedicated {
            if let index = dedicatedCategories.firstIndex(of: oldName) { dedicatedCategories[index] = trimmed }
        } else {
            if let index = categories.firstIndex(of: oldName) { categories[index] = trimmed }
        }
        
        saveCategories()
        for i in 0..<knowledgeBases.count { if knowledgeBases[i].category == oldName { knowledgeBases[i].category = trimmed } }
        saveKnowledgeMeta()
    }
    
    func deleteCategory(_ name: String, isDedicated: Bool) {
        guard name != "默认" else { return }
        if isDedicated { dedicatedCategories.removeAll { $0 == name } }
        else { categories.removeAll { $0 == name } }
        
        saveCategories()
        for i in 0..<knowledgeBases.count { if knowledgeBases[i].category == name { knowledgeBases[i].category = "默认" } }
        saveKnowledgeMeta()
    }
    
    func toggleKnowledgeStatus(id: UUID, isEnabled: Bool) {
        if let index = knowledgeBases.firstIndex(where: { $0.id == id }) {
            knowledgeBases[index].isEnabled = isEnabled; saveKnowledgeMeta()
        }
    }
    
    func deleteMultipleKnowledge(ids: Set<UUID>) {
        knowledgeBases.removeAll { ids.contains($0.id) }
        saveKnowledgeMeta()
        for id in ids { MicroVectorDB.shared.deleteDocument(kbId: id) }
    }
    
    func deleteKnowledge(_ kb: KnowledgeItem) {
        knowledgeBases.removeAll { $0.id == kb.id }
        saveKnowledgeMeta()
        MicroVectorDB.shared.deleteDocument(kbId: kb.id)
    }
    
    func processKnowledgeFiles(files: [(url: URL, relativePath: String)], category: String) {
        guard !files.isEmpty else { return }
        let isBatch = files.count > 1
        
        Util.message(isBatch ? "⏳ 扫描完毕，正在构建 \(files.count) 个文件的提取队列..." : "⏳ 准备解析文档...")
        
        var newItems: [KnowledgeItem] = []
        for file in files {
            let title = file.url.deletingPathExtension().lastPathComponent
            let newKB = KnowledgeItem(
                title: title,
                summary: isBatch ? "等待进入解析队列..." : "正在准备提取...",
                chunkCount: 0,
                status: "排队中",
                isEnabled: true,
                category: category,
                filePath: file.url.path,
                relativePath: file.relativePath
            )
            newItems.append(newKB)
        }
        
        self.knowledgeBases.insert(contentsOf: newItems.reversed(), at: 0)
        self.saveKnowledgeMeta()
        
        Task.detached(priority: .userInitiated) {
            await withTaskGroup(of: Void.self) { group in
                let maxConcurrency = 3
                var activeCount = 0
                
                for (index, file) in files.enumerated() {
                    if activeCount >= maxConcurrency {
                        await group.next()
                        activeCount -= 1
                    }
                    
                    let kbId = newItems[index].id
                    group.addTask {
                        await self.executeFullPipeline(kbId: kbId, url: file.url)
                    }
                    activeCount += 1
                }
            }
            
            await MainActor.run {
                Util.message(isBatch ? "✅ \(files.count) 个文件已全部处理完成！" : "✅ 文件解析并索引完成！")
            }
        }
    }
    
    func reindexKnowledge(kb: KnowledgeItem) {
        guard let path = kb.filePath, FileManager.default.fileExists(atPath: path) else {
            Util.alert(title: "重新索引失败", text: "找不到原始文件，可能已被移动、重命名或删除。\n历史路径: \(kb.filePath ?? "未知")")
            return
        }
        
        let url = URL(fileURLWithPath: path)
        updateKnowledgeStatus(id: kb.id, status: "排队中", count: 0, summary: "等待进入后台队列重构...")
        MicroVectorDB.shared.deleteDocument(kbId: kb.id)
        
        Util.message("⏳ 正在重新分配 \(kb.title) 的深度解析...")
        
        Task.detached(priority: .userInitiated) {
            await self.executeFullPipeline(kbId: kb.id, url: url)
            await MainActor.run { Util.message("✅ 重新索引完成！") }
        }
    }
    
    nonisolated private func executeFullPipeline(kbId: UUID, url: URL) async {
        await MainActor.run { self.updateKnowledgeStatus(id: kbId, status: "提取中", count: 0, summary: "正在读取与分析文件内容...") }
        
        let ext = url.pathExtension.lowercased()
        var extractedText: String = ""
        var predefinedStructuralChunks: [String]? = nil
        
        do {
            if ["pdf", "docx", "doc", "pptx", "ppt", "csv", "xlsx", "xls"].contains(ext) {
                do {
                    extractedText = try await DoclingBridge.parseTo(fileURL: url)
                } catch {
                    // Docling 失败或未安装，自动降级为原生解析
                    extractedText = self.extractNativeFallback(url: url, ext: ext)
                }
            } else if ["swift", "java", "json", "py", "c", "cpp", "h", "cs", "js", "ts", "go", "rs", "php", "sh"].contains(ext) {
                predefinedStructuralChunks = try CodeKnowledgeExtractor.chunkCodeFile(fileURL: url)
                extractedText = predefinedStructuralChunks?.joined(separator: "\n\n") ?? ""
            } else {
                extractedText = try String(contentsOf: url, encoding: .utf8)
            }
            
            guard !extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                await MainActor.run { self.updateKnowledgeStatus(id: kbId, status: "失败", count: 0, summary: "文件内容为空或提取失败") }
                return
            }
            
            guard !extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                await MainActor.run { self.updateKnowledgeStatus(id: kbId, status: "失败", count: 0, summary: "文件内容为空或提取失败") }
                return
            }
            
            let cleanedText = DataCleaner.clean(extractedText)
            
            await MainActor.run { self.updateKnowledgeStatus(id: kbId, status: "切片中", count: 0, summary: "正在进行智能滑动语义分块与元数据隔离...") }
            
            let validChunks: [(text: String, meta: MicroVectorDB.ChunkMetadata)]
            let isCodeFile = (predefinedStructuralChunks != nil)
            
            if let structuralChunks = predefinedStructuralChunks, !structuralChunks.isEmpty {
                validChunks = structuralChunks.filter { DataCleaner.isValidChunk($0) }.map { ($0, MicroVectorDB.ChunkMetadata()) }
            } else {
                let rawChunks = MicroVectorDB.shared.chunkText(cleanedText, maxTokens: 500)
                validChunks = rawChunks.filter { DataCleaner.isValidChunk($0.text) }
            }

            guard !validChunks.isEmpty else {
                await MainActor.run { self.updateKnowledgeStatus(id: kbId, status: "失败", count: 0, summary: "提取的文本不具备语义拆分价值") }
                return
            }

            await MainActor.run { self.updateKnowledgeStatus(id: kbId, status: "向量化", count: validChunks.count, summary: "正在生成纯净正文的语义特征向量...") }
            
            let fileName = await MainActor.run { self.knowledgeBases.first(where: { $0.id == kbId })?.title ?? "未知文件" }

            await MicroVectorDB.shared.addDocument(kbId: kbId, chunks: validChunks)
            
            await MainActor.run { self.updateKnowledgeStatus(id: kbId, status: "生成摘要", count: validChunks.count, summary: "正在请求大模型生成全局摘要...") }
            
            let aiSummary = await self.generateDocumentSummary(text: cleanedText, isCodeFile: isCodeFile, fileName: fileName)
            
            let categoryName = await MainActor.run { self.knowledgeBases.first(where: { $0.id == kbId })?.category ?? "默认" }
            let metaText = "\(fileName) \(categoryName) \(aiSummary)".lowercased()
            let metaVector = await MicroVectorDB.shared.generateEmbedding(for: metaText)
            
            await MainActor.run {
                if let index = self.knowledgeBases.firstIndex(where: { $0.id == kbId }) {
                    self.knowledgeBases[index].status = "索引完成"
                    self.knowledgeBases[index].chunkCount = validChunks.count
                    self.knowledgeBases[index].summary = aiSummary
                    self.knowledgeBases[index].metaEmbedding = metaVector
                    self.saveKnowledgeMeta()
                }
            }
            
        } catch {
            await MainActor.run {
                self.updateKnowledgeStatus(id: kbId, status: "失败", count: 0, summary: "抛出异常: \(error.localizedDescription)")
            }
        }
    }
    
    nonisolated private func generateDocumentSummary(text: String, isCodeFile: Bool = false, fileName: String = "") async -> String {
        let maxLength = 6000
        var extraction = ""
        
        if text.count <= maxLength {
            extraction = text
        } else {
            let prefix = String(text.prefix(4000))
            let suffix = String(text.suffix(2000))
            extraction = "\(prefix)\n\n...[中间部分段落省略]...\n\n\(suffix)"
        }
        
        let promptText: String
        if isCodeFile {
            promptText = CodeKnowledgeExtractor.buildCodeSummaryPrompt(extraction: extraction, fileName: fileName)
        } else {
            promptText = """
            请对以下文档内容进行精准、客观的结构化摘要：
            1. 核心主题：用一句话（100字内）概括文档的核心讨论对象与主旨。
            2. 关键要点：提取 3-5 个核心观点或关键数据，使用列表项呈现。
            3. 适用场景：简述文档适用的业务场景或受众群体。
            4. 结论与行动：文档得出的核心结论或下一步建议（无明确说明则填写“无”）。
            
            文档内容：
            \(extraction)
            """
        }
        
        let aiSummary = await LLMService.shared.askSimple(prompt: promptText)
        var cleanSummary = aiSummary
        
        if let regex = try? NSRegularExpression(pattern: "(?s)<think>.*?</think>") {
            cleanSummary = regex.stringByReplacingMatches(
                in: cleanSummary,
                range: NSRange(cleanSummary.startIndex..., in: cleanSummary),
                withTemplate: ""
            )
        }
        
        if let startRange = cleanSummary.range(of: "<think>") {
            cleanSummary = String(cleanSummary[..<startRange.lowerBound])
        }
        
        cleanSummary = cleanSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanSummary.isEmpty ? "" : cleanSummary
    }
    
    private func updateKnowledgeStatus(id: UUID, status: String, count: Int, summary: String? = nil) {
        if let index = knowledgeBases.firstIndex(where: { $0.id == id }) {
            knowledgeBases[index].status = status; knowledgeBases[index].chunkCount = count
            if let sum = summary { knowledgeBases[index].summary = sum }
            saveKnowledgeMeta()
        }
    }
    
    func importFiles(allowedTypes: [UTType], completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = allowedTypes
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.begin { response in
            if response == .OK { completion(panel.urls) }
        }
    }
    
    func importDirectory(completion: @escaping ([(url: URL, relativePath: String)]) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "选择一个或多个文件夹，将自动扫描内部受支持的文件"
        
        panel.begin { [weak self] response in
            guard let self = self, response == .OK else { return }
            let targetUrls = panel.urls
            
            Task.detached(priority: .userInitiated) {
                var results: [(url: URL, relativePath: String)] = []
                let fileManager = FileManager.default
                
                for dirURL in targetUrls {
                    guard let enumerator = fileManager.enumerator(at: dirURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
                    
                    for case let fileURL as URL in enumerator {
                        if let isRegularFile = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile, isRegularFile {
                            if self.supportedExtensions.contains(fileURL.pathExtension.lowercased()) {
                                let relativePath = fileURL.path.replacingOccurrences(of: dirURL.path, with: "")
                                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                                results.append((url: fileURL, relativePath: relativePath))
                            }
                        }
                    }
                }
                
                await MainActor.run { completion(results) }
            }
        }
    }
    
    // MARK: - 支持结构化元数据封装与自适应加权的 RAG 检索
    func injectedRag(query: String, category: String = "", currentModel: String) async -> (context: String, logString: String) {
        let config = ConfigManager.shared.app.generalConfig
        var activeKBs = getActiveKnowledgeItems()
        var injectedContext = ""
        var logString = ""
        
        if category != "" {
            if category != "全部" {
                activeKBs = activeKBs.filter { $0.category == category }
            } else {
                let dedicatedCats = config.dedicatedKCategories
                activeKBs = activeKBs.filter { !dedicatedCats.contains($0.category) }
            }
        } else {
            return ("", "")
        }

        let activeKBIDs = activeKBs.map { $0.id }
        var cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let chitChatStopWords: Set<String> = ["你好", "在吗", "测试", "你是谁", "谢谢", "好的", "ok", "哈喽", "hi", "hello", "退出"]
        let isChitChat = chitChatStopWords.contains(cleanQuery.lowercased())
        
        let genericTaskWords = ["怎么写", "帮我写", "代码", "示例", "解释一下", "报错", "bug", "python", "swift", "java", "c++", "写一个", "帮我", "翻译"]
        let isGenericTask = cleanQuery.count < 20 &&
                            genericTaskWords.contains(where: { cleanQuery.lowercased().contains($0) }) &&
                            !cleanQuery.contains("文档") &&
                            !cleanQuery.contains("知识库") &&
                            !cleanQuery.contains("本地")
        
        if config.ragQueryRewrite && !cleanQuery.isEmpty && !isChitChat {
            cleanQuery = await rewriteQueryForRetrieval(originalQuery: cleanQuery, model: currentModel)
        }

        if !activeKBIDs.isEmpty && cleanQuery.count >= 2 && !isChitChat && !isGenericTask {
            let currentTopK = ConfigManager.shared.app.generalConfig.ragTopK
            let userMinScore = ConfigManager.shared.app.generalConfig.ragScore
            
            let rawSearchResults = await MicroVectorDB.shared.search(
                query: cleanQuery,
                enabledKbIds: activeKBIDs,
                topK: currentTopK
            )
            
            let effectiveThreshold: Float = userMinScore < 0.1 ? 0.35 : userMinScore
            let validSearchResults = rawSearchResults.filter { ($0.score ?? 0) >= effectiveThreshold }
            
            if !validSearchResults.isEmpty {
                var xmlBuilder = "\n<knowledge>\n"
                xmlBuilder += "  <context_policy>\n"
                xmlBuilder += "    1. 事实依据：优先依据下方 <knowledge_chunk> 标签内 CDATA 区域提供的参考信息回答。\n"
                xmlBuilder += "    2. 边界声明：若参考信息不足以完整解答问题，请在答复中客观说明已知事实与信息缺失部分。\n"
                xmlBuilder += "  </context_policy>\n"
                
                for (index, result) in validSearchResults.enumerated() {
                    let matchedKB = activeKBs.first(where: { $0.id == result.kbId })
                    let documentTitle = matchedKB?.title ?? "未知文档"
                    let sourceFilePath = matchedKB?.filePath ?? "未知源物理路径"
                    let chunkScore = String(format: "%.4f", result.score ?? 0.0)
                    
                    let tagsStr = (result.metadata?.positiveTags.isEmpty == false) ? " tags=\"\(result.metadata!.positiveTags.joined(separator: ", "))\"" : ""
                    let prohStr = (result.metadata?.negativeTags.isEmpty == false) ? " prohibited=\"\(result.metadata!.negativeTags.joined(separator: ", "))\"" : ""
                    
                    xmlBuilder += "  <knowledge_chunk id=\"\(index + 1)\" source_title=\"\(documentTitle)\" rrf_score=\"\(chunkScore)\"\(tagsStr)\(prohStr)>\n"
                    xmlBuilder += "    <![CDATA[\n"
                    xmlBuilder += "\(result.text)\n"
                    xmlBuilder += "    ]]>\n"
                    xmlBuilder += "  </knowledge_chunk>\n"
                    
                    logString += "📚 [命中知识库: \(documentTitle)|\(sourceFilePath)]\n\(result.text)\n====== 提取结束 ======\n"
                }
                
                xmlBuilder += "</knowledge>\n"
                injectedContext = xmlBuilder
            }
        }
        return (injectedContext, logString)
    }
    
    private func rewriteQueryForRetrieval(originalQuery: String, model: String) async -> String {
        if originalQuery.count > 30 { return originalQuery }
        let prompt = """
        # 角色
        检索意图语义扩展专家

        # 任务
        对下方 [用户查询] 进行高密度语义重构，扩展核心动作、行业术语与同义词，以提升向量数据库的检索召回率。

        # 输出规范
        直接输出重构后的单段纯文本，无需包含前缀、导语或解释说明。

        [用户查询]
        \(originalQuery)
        """
        var rewritten = await LLMService.shared.askSimple(prompt: prompt, model: model)
        if let regex = try? NSRegularExpression(pattern: "(?s)<think>.*?</think>") {
            rewritten = regex.stringByReplacingMatches(in: rewritten, range: NSRange(rewritten.startIndex..., in: rewritten), withTemplate: "")
        }
        let cleanResult = rewritten.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanResult.isEmpty ? originalQuery : cleanResult
    }
    
    private func getActiveKnowledgeItems() -> [KnowledgeItem] {
        guard let data = try? Data(contentsOf: knowledgeFileURL),
              let kbs = try? JSONDecoder().decode([KnowledgeItem].self, from: data) else { return [] }
        return kbs.filter { $0.isEnabled && $0.status == "索引完成" }
    }
    
    // 原生降级文本解析兜底
    nonisolated private func extractNativeFallback(url: URL, ext: String) -> String {
        if ext == "pdf", let pdf = PDFDocument(url: url) {
            return (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
        }
        if let attrString = try? NSAttributedString(
            url: url,
            options: [
                .documentType: (ext == "docx") ? NSAttributedString.DocumentType.officeOpenXML : NSAttributedString.DocumentType.rtf
            ],
            documentAttributes: nil
        ) {
            let str = attrString.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !str.isEmpty { return str }
        }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

// MARK: - ==================== 3. 纯 Swift 微型向量数据库 (自适应版) ====================

class MicroVectorDB: @unchecked Sendable {
    static let shared = MicroVectorDB()
    private init() { load() }
    
    public struct ChunkMetadata: Codable, Equatable, Sendable {
        public var headingPath: [String] = []
        public var positiveTags: [String] = []
        public var negativeTags: [String] = []
        public var kvPairs: [String: String] = [:]
        
        public init(headingPath: [String] = [], positiveTags: [String] = [], negativeTags: [String] = [], kvPairs: [String : String] = [:]) {
            self.headingPath = headingPath
            self.positiveTags = positiveTags
            self.negativeTags = negativeTags
            self.kvPairs = kvPairs
        }
    }
    
    struct VectorChunk: Codable, Identifiable {
        var id = UUID()
        var kbId: UUID
        var text: String
        var embedding: [Float]
        var score: Float?
        var debugInfo: String?
        var metadata: ChunkMetadata? = nil
        
        enum CodingKeys: String, CodingKey { case id, kbId, text, embedding, score, debugInfo, metadata }
    }
    
    private var chunks: [VectorChunk] = []
    private let dbQueue = DispatchQueue(label: "com.lintools.vectordb", qos: .userInitiated)
    private var dbFileURL: URL { ConfigManager.shared.ragVectordbFileName! }
    
    func load() {
        if let data = try? Data(contentsOf: dbFileURL), let decoded = try? JSONDecoder().decode([VectorChunk].self, from: data) { self.chunks = decoded }
    }
    private func save() { if let encoded = try? JSONEncoder().encode(chunks) { try? encoded.write(to: dbFileURL, options: .atomic) } }
    
    // MARK: - 纯净切片提取与正文物理隔离
    func chunkText(_ text: String, maxTokens: Int = 400, overlap: Int = 50) -> [(text: String, meta: ChunkMetadata)] {
        var result: [(text: String, meta: ChunkMetadata)] = []
        let lines = text.components(separatedBy: .newlines)
        
        // 1. 预先检测文档是否为纯正或成体系的 QA 问答文档 (出现 >= 2 组问答特征)
        let isQADocument = detectQAPattern(in: lines)
        
        var currentChunk = ""
        var currentHeaderContext = ""
        var currentPositiveTags: [String] = []
        var currentNegativeTags: [String] = []
        
        let tagsRegex = try? NSRegularExpression(pattern: #"(?i)\*\s*\*\*(?:tags|category|标签)\*\*\s*:\s*(?:\[(.*?)\]|(.*))"#)
        let prohRegex = try? NSRegularExpression(pattern: #"(?i)\*\s*\*\*(?:prohibited|exclude|forbidden|禁用)\*\*\s*:\s*(?:\[(.*?)\]|(.*))"#)
        
        func extractList(from line: String, regex: NSRegularExpression?) -> [String]? {
            guard let regex = regex else { return nil }
            let nsString = line as NSString
            if let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: nsString.length)) {
                let range1 = match.range(at: 1)
                let range2 = match.range(at: 2)
                let matchedRange = (range1.location != NSNotFound) ? range1 : range2
                guard matchedRange.location != NSNotFound else { return nil }
                
                let content = nsString.substring(with: matchedRange)
                return content.components(separatedBy: CharacterSet(charactersIn: ",，;；、")).map {
                    $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'[]*")))
                }.filter { !$0.isEmpty }
            }
            return nil
        }
        
        func appendChunkIfValid(chunkStr: String, headers: [String], posTags: [String], negTags: [String]) {
            let trimmed = chunkStr.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            
            let bodyWithoutHeader = trimmed.replacingOccurrences(of: #"^\[.*?\]\n?"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            
            if !bodyWithoutHeader.isEmpty || !posTags.isEmpty || !negTags.isEmpty {
                result.append((trimmed, ChunkMetadata(headingPath: headers, positiveTags: posTags, negativeTags: negTags)))
            }
        }
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty { continue }
            
            // a) 解析 Markdown Headers 并重置上下文
            if trimmedLine.hasPrefix("#") {
                let headerLevel = trimmedLine.prefix(while: { $0 == "#" }).count
                if headerLevel > 0 && headerLevel <= 6 {
                    let newHeader = trimmedLine.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
                    
                    if !currentChunk.isEmpty {
                        appendChunkIfValid(chunkStr: currentChunk, headers: [currentHeaderContext], posTags: currentPositiveTags, negTags: currentNegativeTags)
                        currentChunk = ""
                    }
                    currentHeaderContext = newHeader
                    currentPositiveTags = []
                    currentNegativeTags = []
                    currentChunk = "[\(currentHeaderContext)]\n"
                    continue
                }
            }
            
            // b) 嗅探并隔离负向标签 (prohibited)
            if let prohibited = extractList(from: trimmedLine, regex: prohRegex) {
                currentNegativeTags.append(contentsOf: prohibited)
                continue
            }
            
            // c) 嗅探并隔离正向标签 (tags)
            if let tags = extractList(from: trimmedLine, regex: tagsRegex) {
                currentPositiveTags.append(contentsOf: tags)
                continue
            }
            
            // d) 过滤非正文元数据标记行
            if trimmedLine.hasPrefix("* **") && trimmedLine.contains("**:") && !trimmedLine.contains("核心特征") && !trimmedLine.contains("描述") {
                continue
            }
            
            // e) [QA 结构边界识别]：仅在判定为 QA 文档时，遇新问题强制作为独立切片起点
            if isQADocument && isQuestionLine(trimmedLine) {
                let strippedChunk = currentChunk.replacingOccurrences(of: "[\(currentHeaderContext)]\n", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !strippedChunk.isEmpty {
                    appendChunkIfValid(chunkStr: currentChunk, headers: currentHeaderContext.isEmpty ? [] : [currentHeaderContext], posTags: currentPositiveTags, negTags: currentNegativeTags)
                    currentChunk = !currentHeaderContext.isEmpty ? "[\(currentHeaderContext)]\n" : ""
                }
            }
            
            // f) 常规正文滑动窗口切片
            let projectedSize = currentChunk.count + trimmedLine.count + 1
            if projectedSize > maxTokens {
                if !currentChunk.isEmpty {
                    appendChunkIfValid(chunkStr: currentChunk, headers: [currentHeaderContext], posTags: currentPositiveTags, negTags: currentNegativeTags)
                }
                if trimmedLine.count > maxTokens {
                    let forcedChunks = breakDownHugeSentence(trimmedLine, maxTokens: maxTokens, overlap: overlap)
                    if let first = forcedChunks.first, !currentHeaderContext.isEmpty {
                        appendChunkIfValid(chunkStr: "[\(currentHeaderContext)] \(first)", headers: [currentHeaderContext], posTags: currentPositiveTags, negTags: currentNegativeTags)
                        for chunk in forcedChunks.dropFirst() {
                            appendChunkIfValid(chunkStr: chunk, headers: [currentHeaderContext], posTags: currentPositiveTags, negTags: currentNegativeTags)
                        }
                    } else {
                        for chunk in forcedChunks {
                            appendChunkIfValid(chunkStr: chunk, headers: [currentHeaderContext], posTags: currentPositiveTags, negTags: currentNegativeTags)
                        }
                    }
                    currentChunk = ""
                } else {
                    currentChunk = !currentHeaderContext.isEmpty ? "[\(currentHeaderContext)]\n\(trimmedLine)" : trimmedLine
                }
            } else {
                currentChunk += (currentChunk.isEmpty ? "" : "\n") + trimmedLine
            }
        }
        
        if !currentChunk.isEmpty {
            appendChunkIfValid(chunkStr: currentChunk, headers: [currentHeaderContext], posTags: currentPositiveTags, negTags: currentNegativeTags)
        }
        
        return result
    }

    // MARK: - QA 问答特征探测辅助逻辑
    private func isQuestionLine(_ line: String) -> Bool {
        let questionPatterns = [
            #"^(?i)Q[:：]\s*"#,
            #"^(?i)问[:：]\s*"#,
            #"^【问】[:：]?\s*"#,
            #"^(?i)Question[:：]\s*"#
        ]
        return questionPatterns.contains { line.range(of: $0, options: .regularExpression) != nil }
    }

    private func isAnswerLine(_ line: String) -> Bool {
        let answerPatterns = [
            #"^(?i)A[:：]\s*"#,
            #"^(?i)答[:：]\s*"#,
            #"^【答】[:：]?\s*"#,
            #"^(?i)Answer[:：]\s*"#
        ]
        return answerPatterns.contains { line.range(of: $0, options: .regularExpression) != nil }
    }

    private func detectQAPattern(in lines: [String]) -> Bool {
        var questionCount = 0
        var answerCount = 0
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if isQuestionLine(trimmed) {
                questionCount += 1
            } else if isAnswerLine(trimmed) {
                answerCount += 1
            }
        }
        // 必须存在至少 2 个明确的问题行，且存在至少 1 个回答行，才判定为问答类知识文档
        return questionCount >= 2 && answerCount >= 1
    }
    
    nonisolated private func breakDownHugeSentence(_ text: String, maxTokens: Int, overlap: Int) -> [String] {
        var chunks: [String] = []; var currentIndex = text.startIndex
        while currentIndex < text.endIndex {
            let remaining = text.distance(from: currentIndex, to: text.endIndex)
            if remaining <= maxTokens { chunks.append(String(text[currentIndex...])); break }
            var endIndex = text.index(currentIndex, offsetBy: maxTokens); var searchIndex = endIndex; var foundBoundary = false
            while searchIndex > currentIndex {
                let char = text[searchIndex]; if char.isWhitespace || char.isPunctuation { endIndex = searchIndex; foundBoundary = true; break }
                searchIndex = text.index(before: searchIndex)
            }
            if !foundBoundary { endIndex = text.index(currentIndex, offsetBy: maxTokens) }
            let chunk = String(text[currentIndex..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines); if !chunk.isEmpty { chunks.append(chunk) }
            var nextIndex = endIndex
            if overlap > 0 && nextIndex < text.endIndex {
                var overlapCount = 0; while nextIndex > currentIndex && overlapCount < overlap { nextIndex = text.index(before: nextIndex); overlapCount += 1 }
                while nextIndex > currentIndex && nextIndex < endIndex { if text[nextIndex].isWhitespace || text[nextIndex].isPunctuation { nextIndex = text.index(after: nextIndex); break }; nextIndex = text.index(after: nextIndex) }
            }
            currentIndex = nextIndex
        }
        return chunks
    }
    
    func addDocument(kbId: UUID, chunks: [(text: String, meta: ChunkMetadata)]) async {
        var newVectorChunks: [VectorChunk] = []
        for chunk in chunks {
            newVectorChunks.append(VectorChunk(kbId: kbId, text: chunk.text, embedding: await generateEmbedding(for: chunk.text), metadata: chunk.meta))
        }
        dbQueue.sync { self.chunks.append(contentsOf: newVectorChunks); self.save() }
    }
    
    func deleteDocument(kbId: UUID) { dbQueue.sync { self.chunks.removeAll { $0.kbId == kbId }; self.save() } }
    
    func fetchChunks(for kbId: UUID) -> [VectorChunk] { return dbQueue.sync { self.chunks.filter { $0.kbId == kbId } } }
    
    // MARK: - 自适应感知混合检索
    func search(query: String, enabledKbIds: [UUID], topK: Int = 3, exactMatch: Bool = false) async -> [VectorChunk] {
        guard !enabledKbIds.isEmpty else { return [] }
        
        let queryVector = await generateEmbedding(for: query)
        let queryTokens = SmartTokenizer.tokenize(query)
        let lowerQuery = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        var validChunks = dbQueue.sync { chunks.filter { enabledKbIds.contains($0.kbId) } }
        
        if exactMatch {
            validChunks = validChunks.filter { chunk in
                let chunkText = chunk.text.lowercased()
                let meta = chunk.metadata
                let posTags = meta?.positiveTags.map { $0.lowercased() } ?? []
                let headers = meta?.headingPath.map { $0.lowercased() } ?? []
                
                if chunkText.contains(lowerQuery) ||
                   posTags.contains(where: { $0.contains(lowerQuery) || lowerQuery.contains($0) }) ||
                   headers.contains(where: { $0.contains(lowerQuery) }) {
                    return true
                }
                
                let coreTokens = queryTokens.filter { $0.count >= 2 && $0 != lowerQuery }
                if coreTokens.isEmpty { return false }
                
                let matchedCount = coreTokens.filter { token in
                    chunkText.contains(token) ||
                    posTags.contains(where: { $0.contains(token) }) ||
                    headers.contains(where: { $0.contains(token) })
                }.count
                
                let requiredCount = max(1, Int(ceil(Double(coreTokens.count) * 0.6)))
                return matchedCount >= requiredCount
            }
        }
        
        guard !validChunks.isEmpty else { return [] }
        let totalChunksCount = Float(validChunks.count)

        async let vectorResults = computeVectorSimilarity(queryVector: queryVector, chunks: validChunks)
        async let bm25Results = computeBM25(queryTokens: queryTokens, chunks: validChunks, totalDocs: totalChunksCount)
        
        let (vectorScored, (bm25Scored, idfMap)) = await (vectorResults, bm25Results)
        
        let isTechnicalQuery = queryTokens.contains { $0.contains("_") || $0.count < 4 }
        let bm25Weight: Float = isTechnicalQuery ? 1.8 : 1.3
        let vectorWeight: Float = isTechnicalQuery ? 0.2 : 0.7
        
        let bm25ScoreMap = Dictionary(uniqueKeysWithValues: bm25Scored)
        let vectorScoreMap = Dictionary(uniqueKeysWithValues: vectorScored)
        
        var rrfScores: [UUID: Float] = [:]
        let rrf_k: Float = 60.0
        
        for (rank, item) in vectorScored.enumerated() {
            rrfScores[item.id] = (1.0 / (rrf_k + Float(rank + 1))) * vectorWeight
        }
        for (rank, item) in bm25Scored.enumerated() {
            let current = rrfScores[item.id] ?? 0
            rrfScores[item.id] = current + (1.0 / (rrf_k + Float(rank + 1))) * bm25Weight
        }
        
        // 仅在库内实际存在的有效词 (IDF > 0) 中选取最高信息熵锚点
        let validTokensByIDF = queryTokens
            .filter { $0.count >= 2 && (idfMap[$0] ?? 0) > 0 }
            .sorted { (idfMap[$0] ?? 0) > (idfMap[$1] ?? 0) }
        let topAnchorToken = validTokensByIDF.first
        let topAnchorIDF = topAnchorToken != nil ? (idfMap[topAnchorToken!] ?? 0.0) : 0.0
        
        var coarseRanked = validChunks.compactMap { chunk -> VectorChunk? in
            let bm25 = bm25ScoreMap[chunk.id] ?? 0.0
            let vecSim = vectorScoreMap[chunk.id] ?? 0.0
            let chunkTextLower = chunk.text.lowercased()
            
            // 实体门禁放行判定
            if topAnchorIDF > 1.0, let topAnchor = topAnchorToken {
                let hasAnchor = chunkTextLower.contains(topAnchor) ||
                               (chunk.metadata?.positiveTags.contains { $0.lowercased().contains(topAnchor) } ?? false) ||
                               (chunk.metadata?.headingPath.contains { $0.lowercased().contains(topAnchor) } ?? false)
                if !hasAnchor && vecSim < 0.68 && bm25 <= 0 {
                    return nil
                }
            }
            
            // 底噪初筛：无 BM25 且稠密向量低于 0.48 直接剔除
            if bm25 <= 0 && vecSim < 0.48 {
                return nil
            }
            
            guard let score = rrfScores[chunk.id], score > 0 else { return nil }
            var resultChunk = chunk
            resultChunk.score = score
            return resultChunk
        }
        
        coarseRanked.sort { ($0.score ?? 0) > ($1.score ?? 0) }
        let coarsePool = Array(coarseRanked.prefix(topK * 4))
        
        if !coarsePool.isEmpty {
            var finalRanked = await NativeReranker.shared.rerank(
                query: query,
                chunks: coarsePool,
                topK: topK,
                idfMap: idfMap
            )
            
            finalRanked = finalRanked.filter { ($0.score ?? 0) >= 0.20 }
            return finalRanked
        } else {
            return Array(coarsePool.prefix(topK))
        }
    }
    
    private func computeVectorSimilarity(queryVector: [Float], chunks: [VectorChunk]) async -> [(id: UUID, score: Float)] {
        return await withTaskGroup(of: [(id: UUID, score: Float)].self) { group in
            let batchSize = 500
            var results: [(id: UUID, score: Float)] = []
            for i in stride(from: 0, to: chunks.count, by: batchSize) {
                let end = min(i + batchSize, chunks.count)
                let batch = Array(chunks[i..<end])
                group.addTask {
                    var batchResults: [(id: UUID, score: Float)] = []
                    for chunk in batch {
                        let score = self.cosineSimilarity(a: queryVector, b: chunk.embedding)
                        if score >= 0.45 { batchResults.append((chunk.id, score)) }
                    }
                    return batchResults
                }
            }
            for await batchResult in group { results.append(contentsOf: batchResult) }
            results.sort { $0.score > $1.score }
            return results
        }
    }
    
    // MARK: - 自适应 BM25 (负向拦截 + Tag 自感知)
    private func computeBM25(queryTokens: [String], chunks: [VectorChunk], totalDocs: Float) async -> (scored: [(id: UUID, score: Float)], idfMap: [String: Float]) {
        guard !queryTokens.isEmpty else { return ([], [:]) }
        
        let meaningfulTokens = queryTokens.filter { $0.count >= 2 }
        let effectiveTokens = meaningfulTokens.isEmpty ? queryTokens : meaningfulTokens
        
        var documentFrequency: [String: Float] = [:]
        var idfMap: [String: Float] = [:]
        
        for q in effectiveTokens {
            // 统计正文及正向标签中包含该词的切片数
            let count = chunks.filter {
                $0.text.localizedCaseInsensitiveContains(q) ||
                ($0.metadata?.positiveTags.contains(where: { $0.localizedCaseInsensitiveContains(q) }) ?? false) ||
                ($0.metadata?.headingPath.contains(where: { $0.localizedCaseInsensitiveContains(q) }) ?? false)
            }.count
            
            documentFrequency[q] = Float(count)
            
            // 库中完全不存在的 0 频拼接短语赋予 IDF = 0.0，不作为核心实体锚点
            if count > 0 {
                let idf = log((totalDocs - Float(count) + 0.5) / (Float(count) + 0.5) + 1.0)
                idfMap[q] = max(0.0, idf)
            } else {
                idfMap[q] = 0.0
            }
        }
        
        let avgdl = chunks.map { Float($0.text.count) }.reduce(0, +) / max(totalDocs, 1.0)
        let k1: Float = 1.5; let b: Float = 0.75
        var bm25Scored: [(id: UUID, score: Float)] = []
        var maxBM25Score: Float = 0.0
        
        for chunk in chunks {
            let meta = chunk.metadata
            
            // 1. 负向禁忌词硬拦截 (保持原有逻辑)
            if let negTags = meta?.negativeTags, !negTags.isEmpty {
                let hasNegativeHit = effectiveTokens.contains { qt in
                    negTags.contains(where: { $0.lowercased().contains(qt) })
                }
                if hasNegativeHit { continue }
            }
            
            // 2. 专用分类与标签过滤 (保持原有逻辑)
            if let pos = meta?.positiveTags, !pos.isEmpty {
                let tagHits = effectiveTokens.filter { qt in pos.contains(where: { $0.lowercased().contains(qt) }) }
                let headerHits = effectiveTokens.filter { qt in meta?.headingPath.contains(where: { $0.lowercased().contains(qt) }) ?? false }
                if tagHits.isEmpty && headerHits.isEmpty {
                    continue
                }
            }
            
            var totalBM25: Float = 0
            let chunkText = chunk.text.lowercased()
            let chunkLength = Float(chunkText.count)
            
            for q in effectiveTokens {
                let idf = idfMap[q] ?? 0.0
                guard idf > 0 else { continue }
                
                var f_qD = Float(chunkText.components(separatedBy: q).count - 1)
                
                var fieldMultiplier: Float = 1.0
                if let tags = meta?.positiveTags, tags.contains(where: { $0.lowercased().contains(q) }) {
                    fieldMultiplier = 4.0
                    f_qD += 2.0
                }
                if let path = meta?.headingPath, path.contains(where: { $0.lowercased().contains(q) }) {
                    fieldMultiplier = max(fieldMultiplier, 2.5)
                }
                
                if f_qD <= 0 { continue }
                
                let termScore = idf * (f_qD * (k1 + 1) / (f_qD + k1 * (1 - b + b * (chunkLength / avgdl))))
                totalBM25 += termScore * fieldMultiplier
            }
            
            if totalBM25 > 0 {
                bm25Scored.append((chunk.id, totalBM25))
                if totalBM25 > maxBM25Score { maxBM25Score = totalBM25 }
            }
        }
        
        if maxBM25Score > 0 {
            bm25Scored = bm25Scored.map { (id: $0.id, score: $0.score / maxBM25Score) }
        }
        
        bm25Scored.sort { $0.score > $1.score }
        return (bm25Scored, idfMap)
    }
    
    func generateEmbedding(for text: String) async -> [Float] {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanText.isEmpty { return [Float](repeating: 0, count: 300) }
        
        let lang = NLLanguageRecognizer.dominantLanguage(for: cleanText) ?? .simplifiedChinese
        guard let embedding = NLEmbedding.sentenceEmbedding(for: lang) ?? NLEmbedding.wordEmbedding(for: lang) else {
            guard let fallback = NLEmbedding.wordEmbedding(for: .simplifiedChinese) else {
                return [Float](repeating: 0, count: 300)
            }
            return await computeAverageWordVector(text: cleanText, embedding: fallback)
        }
        
        var vector: [Float] = []
        if let rawVector = embedding.vector(for: cleanText) {
            vector = rawVector.map { Float($0) }
        } else {
            vector = await computeAverageWordVector(text: cleanText, embedding: embedding)
        }
        
        var norm: Float = 0
        vDSP_svesq(vector, 1, &norm, vDSP_Length(vector.count))
        norm = sqrt(norm)
        
        if norm > 0 {
            var normalized = [Float](repeating: 0, count: vector.count)
            vDSP_vsdiv(vector, 1, &norm, &normalized, 1, vDSP_Length(vector.count))
            return normalized
        }
        return vector
    }
    
    private func computeAverageWordVector(text: String, embedding: NLEmbedding) async -> [Float] {
        let targetDimension = 300
        var combinedVector = [Double](repeating: 0, count: targetDimension)
        var wordCount = 0
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = String(text[range])
            if let wv = embedding.vector(for: word) {
                for i in 0..<min(targetDimension, wv.count) { combinedVector[i] += wv[i] }
                wordCount += 1
            }
            return true
        }
        return wordCount > 0 ? combinedVector.map { Float($0 / Double(wordCount)) } : [Float](repeating: 0, count: targetDimension)
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

// MARK: - ==================== 4. 知识库 UI 视图组件 ====================

struct KnowledgeNode: Identifiable {
    let id: String
    let name: String
    let isFolder: Bool
    var item: KnowledgeItem?
    var children: [KnowledgeNode]?
}

struct KnowledgeBasePanel: View {
    @Bindable var viewModel: KnowledgeViewModel
    @State private var generalConfig = ConfigManager.shared.app.generalConfig
    @State private var showEditSheet = false
    @State private var showDeleteAlert = false
    @State private var showingChunksFor: KnowledgeItem? = nil
    @State private var showingCategoryManager = false
    @State private var selectedKnowledgeIDs: Set<UUID> = []
    @State private var showBatchDeleteAlert = false
    @State private var showAlgorithmGuidePopover = false
    
    @State private var isDoclingInstalled: Bool = false
    @State private var showDoclingGuidePopover: Bool = false
    @State private var selectedFolderPath: String? = "全部"
    
    var currentCategory: String {
        if let path = selectedFolderPath, path != "全部" {
            return path.components(separatedBy: "/").first ?? "全部"
        }
        return "全部"
    }

    var categoryNodes: [KnowledgeNode] {
        class NodeBuilder {
            var name: String
            var path: String
            var isFolder: Bool
            var item: KnowledgeItem?
            var children: [String: NodeBuilder] = [:]
            
            init(name: String, path: String, isFolder: Bool, item: KnowledgeItem? = nil) {
                self.name = name; self.path = path; self.isFolder = isFolder; self.item = item
            }
            
            func toNode() -> KnowledgeNode {
                let sortedChildren = children.values.sorted {
                    if $0.isFolder == $1.isFolder { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    return $0.isFolder && !$1.isFolder
                }.map { $0.toNode() }
                return KnowledgeNode(id: path, name: name, isFolder: isFolder, item: item, children: isFolder ? (sortedChildren.isEmpty ? nil : sortedChildren) : nil)
            }
        }
        
        var catBuilders: [String: NodeBuilder] = [:]
        for cat in viewModel.allCategories {
            catBuilders[cat] = NodeBuilder(name: cat, path: cat, isFolder: true)
        }
        
        for kb in viewModel.knowledgeBases {
            let cat = kb.category
            if catBuilders[cat] == nil {
                catBuilders[cat] = NodeBuilder(name: cat, path: cat, isFolder: true)
            }
            let rootBuilder = catBuilders[cat]!
            
            let relPath = kb.relativePath ?? URL(fileURLWithPath: kb.filePath ?? "").lastPathComponent
            let components = relPath.components(separatedBy: "/").filter { !$0.isEmpty }
            
            var current = rootBuilder
            var currentPath = cat
            for (index, component) in components.enumerated() {
                let isLast = index == components.count - 1
                currentPath += "/\(component)"
                
                if current.children[component] == nil {
                    current.children[component] = NodeBuilder(name: component, path: currentPath, isFolder: !isLast, item: isLast ? kb : nil)
                } else if isLast {
                    current.children[component]?.item = kb
                    current.children[component]?.isFolder = false
                }
                current = current.children[component]!
            }
        }
        return viewModel.allCategories.compactMap { catBuilders[$0]?.toNode() }
    }
    
    var leftPaneNodes: [KnowledgeNode] {
        func extractFolders(from nodes: [KnowledgeNode]) -> [KnowledgeNode] {
            nodes.compactMap { node in
                guard node.isFolder else { return nil }
                var folderNode = node
                if let children = node.children {
                    let folderChildren = extractFolders(from: children)
                    folderNode.children = folderChildren.isEmpty ? nil : folderChildren
                } else {
                    folderNode.children = nil
                }
                return folderNode
            }
        }
        return extractFolders(from: categoryNodes)
    }
    
    var displayFiles: [KnowledgeItem] {
        var files = getFiles(in: selectedFolderPath ?? "全部", from: categoryNodes)
        let selectedPath = selectedFolderPath ?? "全部"
        
        files.sort { a, b in
            let rawPathA = a.relativePath ?? URL(fileURLWithPath: a.filePath ?? "").lastPathComponent
            let rawPathB = b.relativePath ?? URL(fileURLWithPath: b.filePath ?? "").lastPathComponent
            
            let pathA = (a.category + "/" + rawPathA).components(separatedBy: "/").dropLast().joined(separator: "/")
            let pathB = (b.category + "/" + rawPathB).components(separatedBy: "/").dropLast().joined(separator: "/")
            
            let isADirect = (selectedPath == "全部") ? (pathA == a.category) : (pathA == selectedPath)
            let isBDirect = (selectedPath == "全部") ? (pathB == b.category) : (pathB == selectedPath)
            
            if isADirect && !isBDirect { return true }
            if !isADirect && isBDirect { return false }
            return rawPathA.localizedStandardCompare(rawPathB) == .orderedAscending
        }
        
        return files
    }
    
    var isAllSelected: Bool {
        !displayFiles.isEmpty && displayFiles.allSatisfy { selectedKnowledgeIDs.contains($0.id) }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            topBarView
            ragConfigView
            ModernDivider(style: .fade(0.18))
            knowledgeListView
        }
        .alert("清理知识库？", isPresented: $showDeleteAlert, presenting: viewModel.knowledgeToDelete) { kb in
            Button("删除", role: .destructive) { viewModel.deleteKnowledge(kb) }
            Button("取消", role: .cancel) { }
        } message: { kb in
            Text("将从 VectorDB 中彻底清除「\(kb.title)」。")
        }
        .alert("批量删除？", isPresented: $showBatchDeleteAlert) {
            Button("删除", role: .destructive) {
                withAnimation { viewModel.deleteMultipleKnowledge(ids: selectedKnowledgeIDs); selectedKnowledgeIDs.removeAll() }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("彻底删除 \(selectedKnowledgeIDs.count) 个知识库。")
        }
        .sheet(isPresented: $showEditSheet) {
            if let kb = viewModel.editingKnowledge {
                KnowledgeEditView(
                    knowledge: kb,
                    categories: viewModel.categories,
                    dedicatedCategories: viewModel.dedicatedCategories,
                    isNew: !viewModel.knowledgeBases.contains(where: { $0.id == kb.id })
                ) { updatedKB in
                    if let idx = viewModel.knowledgeBases.firstIndex(where: { $0.id == updatedKB.id }) { viewModel.knowledgeBases[idx] = updatedKB }
                    viewModel.saveKnowledgeMeta()
                    showEditSheet = false
                } onCancel: { showEditSheet = false }
            }
        }
        .sheet(item: $showingChunksFor) { kb in KnowledgeChunksPreviewView(knowledge: kb) { showingChunksFor = nil } }
        .sheet(isPresented: $showingCategoryManager) { CategoryManagerView(viewModel: viewModel) { showingCategoryManager = false } }
    }
    
    private func selectAll(in path: String) {
        let files = getFiles(in: path, from: categoryNodes)
        for f in files { selectedKnowledgeIDs.insert(f.id) }
    }
    
    private func deselectAll(in path: String) {
        let files = getFiles(in: path, from: categoryNodes)
        for f in files { selectedKnowledgeIDs.remove(f.id) }
    }
    
    private func getFiles(in path: String, from nodes: [KnowledgeNode]) -> [KnowledgeItem] {
        if path == "全部" {
             return viewModel.knowledgeBases.filter { !viewModel.dedicatedCategories.contains($0.category) }
        }
        
        func findNode(path: String, nodes: [KnowledgeNode]) -> KnowledgeNode? {
            for node in nodes {
                if node.id == path { return node }
                if let children = node.children, let found = findNode(path: path, nodes: children) { return found }
            }
            return nil
        }
        
        guard let targetNode = findNode(path: path, nodes: nodes) else { return [] }
        
        func collectFiles(node: KnowledgeNode) -> [KnowledgeItem] {
            var files: [KnowledgeItem] = []
            if let item = node.item { files.append(item) }
            if let children = node.children {
                for child in children { files.append(contentsOf: collectFiles(node: child)) }
            }
            return files
        }
        return collectFiles(node: targetNode)
    }

    @ViewBuilder
    private var topBarView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("知识库").font(.headline)
                Text("由微型向量库驱动的本地自适应 RAG 数据中心").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            
            HStack(spacing: 8) {
                if !displayFiles.isEmpty {
                    Button(action: {
                        if isAllSelected {
                            deselectAll(in: selectedFolderPath ?? "全部")
                        } else {
                            selectAll(in: selectedFolderPath ?? "全部")
                        }
                    }) {
                        Label(isAllSelected ? "全不选" : "全选", systemImage: isAllSelected ? "checkmark.square.fill" : "square")
                    }
                    .buttonStyle(.bordered)
                }
                
                if !selectedKnowledgeIDs.isEmpty {
                    Button(role: .destructive) { showBatchDeleteAlert = true } label: {
                        Label("批量删除 (\(selectedKnowledgeIDs.count))", systemImage: "trash.fill")
                    }.buttonStyle(.borderedProminent).tint(.red)
                }
            }.padding(.trailing, 8)
            
            Button { showingCategoryManager = true } label: { Image(systemName: "folder.badge.gearshape") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .padding(.trailing, 8)
                .help("管理分类架构与检索编写规范")
            
            Button {
                KnowledgeSearchWindowManager.shared.show(viewModel: viewModel)
            } label: {
                Label("检索测试", systemImage: "magnifyingglass")
            }
            .buttonStyle(.bordered)
            
            Button {
                var allowed: [UTType] = [.pdf, .plainText, .rtf, .html, .xml, .sourceCode, .script, .commaSeparatedText]
                allowed.append(contentsOf: viewModel.supportedExtensions.compactMap { UTType(filenameExtension: $0) })
                
                viewModel.importFiles(allowedTypes: Array(Set(allowed))) { urls in
                    let cat = currentCategory == "全部" ? "默认" : currentCategory
                    let files = urls.map { (url: $0, relativePath: $0.lastPathComponent) }
                    viewModel.processKnowledgeFiles(files: files, category: cat)
                }
            } label: { Label("导入文件", systemImage: "doc.badge.plus") }.buttonStyle(.bordered)
            
            Button {
                viewModel.importDirectory { results in
                    let cat = currentCategory == "全部" ? "默认" : currentCategory
                    viewModel.processKnowledgeFiles(files: results, category: cat)
                }
            } label: { Label("导入文件夹", systemImage: "folder.badge.plus") }.buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.thinMaterial)
    }
    
    @ViewBuilder
    private var ragConfigView: some View {
        HStack(spacing: 16) {
            Toggle("Query 语义重写", isOn: $generalConfig.ragQueryRewrite)
                .toggleStyle(.checkbox)
                .help("开启后，检索前会利用大模型对问题进行扩写，显著提升跨词检索的召回率")
            
            Divider().frame(height: 16)
            
            HStack(spacing: 6) {
                Text("检索数量:").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("", value: $generalConfig.ragTopK, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 40)
                    .multilineTextAlignment(.center)
                Text("块").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            
            Divider().frame(height: 16)
            
            HStack(spacing: 6) {
                Text("最低分值:").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("", value: $generalConfig.ragScore, format: .number.precision(.fractionLength(3)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .multilineTextAlignment(.center)
            }
            
            Spacer()
            
            // Docling 安装状态与引导胶囊
            Button(action: { showDoclingGuidePopover.toggle() }) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(isDoclingInstalled ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    
                    Text(isDoclingInstalled ? "Docling 高保真引擎就绪" : "Docling 待配置 (点击查看)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isDoclingInstalled ? .green : .orange)
                    
                    Image(systemName: "info.circle")
                        .font(.system(size: 9))
                        .opacity(0.8)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isDoclingInstalled ? Color.green.opacity(0.08) : Color.orange.opacity(0.08))
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke((isDoclingInstalled ? Color.green : Color.orange).opacity(0.2), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showDoclingGuidePopover, arrowEdge: .top) {
                DoclingInstallGuidePopover(isInstalled: $isDoclingInstalled)
            }
            
            Button(action: { showAlgorithmGuidePopover.toggle() }) {
                HStack(spacing: 5) {
                    Image(systemName: "gearshape.2.fill")
                        .font(.system(size: 10))
                    Text("自适应算法与切片机制")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Color.blue)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showAlgorithmGuidePopover, arrowEdge: .top) {
                RAGAlgorithmEngineGuidePopover()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.clear)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.1), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .task {
            self.isDoclingInstalled = await DoclingBridge.isAvailable()
        }
    }
    
    @ViewBuilder
    private var knowledgeListView: some View {
        HSplitView {
            List(selection: Binding(
                get: { selectedFolderPath ?? "全部" },
                set: { selectedFolderPath = $0 ?? "全部" }
            )) {
                HStack {
                    Image(systemName: "tray.fill").foregroundColor(.gray)
                    Text("全部分类")
                }
                .tag("全部")
                .contextMenu {
                    Button("全选") { selectAll(in: "全部") }
                    Button("全不选") { deselectAll(in: "全部") }
                }
                
                OutlineGroup(leftPaneNodes, children: \.children) { node in
                    HStack {
                        let isDedicatedRoot = viewModel.dedicatedCategories.contains(node.name) && node.id == node.name
                        Image(systemName: isDedicatedRoot ? "lock.doc.fill" : "folder.fill")
                            .foregroundColor(isDedicatedRoot ? .purple : .blue)
                        Text(node.name)
                    }
                    .tag(node.id)
                    .contextMenu {
                        Button("全选该分类及子级") { selectAll(in: node.id) }
                        Button("全不选该分类及子级") { deselectAll(in: node.id) }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 160, idealWidth: 200, maxWidth: 300)
            
            List {
                ForEach(displayFiles) { kb in
                    KnowledgeRowView(
                        kb: kb,
                        viewModel: viewModel,
                        selectedKnowledgeIDs: $selectedKnowledgeIDs,
                        showingChunksFor: $showingChunksFor,
                        showEditSheet: $showEditSheet,
                        showDeleteAlert: $showDeleteAlert
                    )
                }
            }
            .frame(minWidth: 300, maxWidth: .infinity)
            .scrollContentBackground(.hidden)
            .forceOverlayScrollbars()
        }
    }
}

// 行组件
struct KnowledgeRowView: View {
    let kb: KnowledgeItem
    let viewModel: KnowledgeViewModel
    
    @Binding var selectedKnowledgeIDs: Set<UUID>
    @Binding var showingChunksFor: KnowledgeItem?
    @Binding var showEditSheet: Bool
    @Binding var showDeleteAlert: Bool
    
    @State private var isHovered = false
    
    var displayName: String {
        if let path = kb.filePath, !path.isEmpty {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return kb.title
    }
    
    var displayPath: String {
        let path = kb.relativePath ?? URL(fileURLWithPath: kb.filePath ?? "").lastPathComponent
        let components = path.components(separatedBy: "/")
        if components.count > 1 {
            return "\(kb.category) / " + components.dropLast().joined(separator: " / ")
        } else {
            return "\(kb.category)"
        }
    }
    
    var body: some View {
        HStack(spacing: 16) {
            let isSelected = Binding<Bool>(
                get: { selectedKnowledgeIDs.contains(kb.id) },
                set: { if $0 { selectedKnowledgeIDs.insert(kb.id) } else { selectedKnowledgeIDs.remove(kb.id) } }
            )
            Toggle("", isOn: isSelected).toggleStyle(.checkbox)
            
            Image(systemName: "doc.text.fill")
                .foregroundStyle(kb.isEnabled ? .blue : .gray.opacity(0.5))
                .font(.title2)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(displayName)
                        .font(.headline)
                        .foregroundStyle(kb.isEnabled ? .primary : .secondary)
                        .lineLimit(1)
                    Spacer()
                }
                
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill").foregroundColor(.secondary).font(.system(size: 9))
                    Text(displayPath)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                
                HStack(spacing: 8) {
                    Text("切片: \(kb.chunkCount)").font(.caption).foregroundStyle(.gray)
                    Text(kb.status).font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(kb.status == "索引完成" ? Color.green.opacity(0.2) : Color.blue.opacity(0.2))
                        .foregroundStyle(kb.status == "索引完成" ? .green : .blue)
                        .cornerRadius(4)
                }
            }
            
            HStack(spacing: 14) {
                Button(action: {
                    withAnimation { viewModel.toggleKnowledgeStatus(id: kb.id, isEnabled: !kb.isEnabled) }
                }) {
                    Image(systemName: kb.isEnabled ? "checkmark.circle.fill" : "circle.dashed")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(kb.isEnabled ? .green : .gray)
                .help(kb.isEnabled ? "停用此知识库" : "启用此知识库")
                .disabled(kb.status != "索引完成")
                
                Divider().frame(height: 12)
                
                Button(action: { viewModel.reindexKnowledge(kb: kb) }) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(.purple)
                .help("重新提取并索引")
                .disabled(kb.status == "处理中" || kb.status == "生成摘要中" || kb.status == "排队中")
                
                Button(action: { showingChunksFor = kb }) {
                    Image(systemName: "eye").font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(.orange)
                .help("预览知识切片与元数据")
                .disabled(kb.status != "索引完成")
                
                Button(action: { viewModel.editingKnowledge = kb; showEditSheet = true }) {
                    Image(systemName: "square.and.pencil").font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(.blue)
                .help("编辑元数据")
                
                Button(action: { viewModel.knowledgeToDelete = kb; showDeleteAlert = true }) {
                    Image(systemName: "trash").font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(.red)
                .help("清理并删除")
            }
            .opacity(isHovered ? 1.0 : 0.0)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering in isHovered = hovering }
    }
}

// MARK: - 知识库检索测试面板 (显化结构化元数据徽章)
struct KnowledgeSearchTestView: View {
    @Bindable var viewModel: KnowledgeViewModel
    var onClose: () -> Void
    
    @State private var query: String = ""
    @State private var results: [MicroVectorDB.VectorChunk] = []
    @State private var isSearching = false
    @State private var searchTime: TimeInterval = 0
    @State private var isExactMatch: Bool = false
    @State private var selectedCategory: String = "全部"
    
    // 是否仅展示达标切片
    @State private var showQualifiedOnly: Bool = false
    
    /// 当前生效的有效最低分值门槛
    private var minThreshold: Float {
        let userScore = ConfigManager.shared.app.generalConfig.ragScore
        return userScore < 0.1 ? 0.35 : userScore
    }
    
    /// 诊断视图下的渲染列表（包含是否达标标记）
    private var diagnosticResults: [(index: Int, chunk: MicroVectorDB.VectorChunk, isQualified: Bool)] {
        let mapped = results.enumerated().map { index, chunk in
            let score = chunk.score ?? 0.0
            let isQualified = score >= minThreshold
            return (index: index, chunk: chunk, isQualified: isQualified)
        }
        if showQualifiedOnly {
            return mapped.filter { $0.isQualified }
        }
        return mapped
    }
    
    /// 达标切片数量统计
    private var qualifiedCount: Int {
        results.filter { ($0.score ?? 0.0) >= minThreshold }.count
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶栏
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("向量检索测试与自适应诊断").font(.headline)
                    Text("测试当前知识库的召回精确度、标签提权及最低分值过滤机制").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.gray)
            }
            .padding()
            
            Divider()
            
            // 搜索输入与控制项
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    TextField("输入需要测试的关键词或自然语言问题...", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .onSubmit { performSearch() }
                    
                    Button(action: performSearch) {
                        Label("执行检索", systemImage: "sparkle.magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
                }
                
                HStack(spacing: 16) {
                    Toggle("精确检索 (强制要求包含关键词)", isOn: $isExactMatch)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12, weight: isExactMatch ? .semibold : .regular))
                        .foregroundColor(isExactMatch ? .blue : .secondary)
                    
                    // 仅看达标切片
                    Toggle("仅看达标切片 (≥ \(String(format: "%.3f", minThreshold)))", isOn: $showQualifiedOnly)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12, weight: showQualifiedOnly ? .semibold : .regular))
                        .foregroundColor(showQualifiedOnly ? .green : .secondary)
                        .help("开启后将隐藏所有低于最低分值设定阈值的切片，模拟真实对话时的有效召回效果")
                    
                    Spacer()
                    
                    Picker("检索范围:", selection: $selectedCategory) {
                        Text("全部分类").tag("全部")
                        Divider()
                        ForEach(viewModel.categories, id: \.self) { Text("📂 \($0)").tag($0) }
                        if !viewModel.dedicatedCategories.isEmpty {
                            Divider()
                            ForEach(viewModel.dedicatedCategories, id: \.self) { Text("🔒 \($0) (专用)").tag($0) }
                        }
                    }
                    .frame(width: 180)
                }
            }
            .padding()
            
            // 检索结果展示
            List {
                if isSearching {
                    HStack { Spacer(); ProgressView("正在执行多通道自适应混合检索与精排...").padding(); Spacer() }
                } else if results.isEmpty {
                    if !query.isEmpty {
                        Text(isExactMatch ? "未召回任何有效切片。当前开启了【精确检索】，请确认文档中是否确实包含该关键词。" : "未召回任何有效切片，所有候选均未跨过向量初筛底线或触发了负向拦截。")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                } else if diagnosticResults.isEmpty && showQualifiedOnly {
                    VStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 28))
                            .foregroundColor(.orange)
                        Text("共召回 \(results.count) 个切片，但得分均低于当前阈值 (\(String(format: "%.3f", minThreshold)))。")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                        Text("建议取消勾选「仅看达标切片」以分析未达标切片的算分溯源，或在主界面适当降低「最低分值」。")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.8))
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
                } else {
                    let targetTopK = ConfigManager.shared.app.generalConfig.ragTopK
                    let qualifiedRate = results.isEmpty ? 0.0 : (Double(qualifiedCount) / Double(results.count)) * 100.0
                    
                    // 仪表盘 Header
                    Section(header: HStack {
                        Text("📊 检索性能仪表盘")
                            .font(.system(size: 12, weight: .bold))
                        Spacer()
                        Text("耗时: \(String(format: "%.3f", searchTime))s | 召回: \(results.count)/\(targetTopK) 块 | 达标生效: \(qualifiedCount) 块 (达标率: \(String(format: "%.0f", qualifiedRate))%) | 阈值门槛: \(String(format: "%.3f", minThreshold))")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(qualifiedCount > 0 ? .green : .orange)
                    }) {
                        ForEach(diagnosticResults, id: \.chunk.id) { item in
                            let index = item.index
                            let chunk = item.chunk
                            let isQualified = item.isQualified
                            let score = chunk.score ?? 0.0
                            
                            VStack(alignment: .leading, spacing: 8) {
                                // 头部指标行
                                HStack(alignment: .top) {
                                    Text("#\(index + 1)")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(isQualified ? Color.blue.opacity(0.85) : Color.gray.opacity(0.6))
                                        .cornerRadius(4)
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 8) {
                                            Text("综合最终得分: \(String(format: "%.4f", score))")
                                                .font(.system(size: 12, weight: .bold))
                                                .foregroundColor(isQualified ? scoreColor(score) : .secondary)
                                            
                                            // 达标状态徽章
                                            if isQualified {
                                                HStack(spacing: 3) {
                                                    Image(systemName: "checkmark.seal.fill").font(.system(size: 9))
                                                    Text("已达标 / 正式生效")
                                                }
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundColor(.green)
                                                .padding(.horizontal, 6).padding(.vertical, 2)
                                                .background(Color.green.opacity(0.12))
                                                .cornerRadius(4)
                                            } else {
                                                HStack(spacing: 3) {
                                                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                                                    Text("未达标 / 实际问答将过滤")
                                                }
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundColor(.red.opacity(0.85))
                                                .padding(.horizontal, 6).padding(.vertical, 2)
                                                .background(Color.red.opacity(0.08))
                                                .cornerRadius(4)
                                            }
                                        }
                                        
                                        if let debugTrace = chunk.debugInfo {
                                            Text("🧮 算分溯源: [ \(debugTrace) ]")
                                                .font(.system(size: 9, design: .monospaced))
                                                .foregroundColor(.secondary)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.primary.opacity(0.04))
                                                .cornerRadius(4)
                                        }
                                    }
                                    
                                    Spacer()
                                    
                                    if let kb = viewModel.knowledgeBases.first(where: { $0.id == chunk.kbId }) {
                                        Label(kb.title, systemImage: "doc.text.fill")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                            .frame(maxWidth: 200, alignment: .trailing)
                                    }
                                }
                                
                                // 结构化元数据徽章
                                if let meta = chunk.metadata {
                                    if !meta.positiveTags.isEmpty || !meta.negativeTags.isEmpty {
                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(spacing: 6) {
                                                ForEach(meta.positiveTags, id: \.self) { tag in
                                                    HStack(spacing: 3) {
                                                        Image(systemName: "tag.fill").font(.system(size: 8))
                                                        Text(tag).font(.system(size: 10, weight: .medium))
                                                    }
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.cyan.opacity(0.15))
                                                    .foregroundColor(.cyan)
                                                    .cornerRadius(4)
                                                }
                                                
                                                ForEach(meta.negativeTags, id: \.self) { proh in
                                                    HStack(spacing: 3) {
                                                        Image(systemName: "nosign").font(.system(size: 8))
                                                        Text(proh).font(.system(size: 10, weight: .medium))
                                                    }
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.red.opacity(0.12))
                                                    .foregroundColor(.red)
                                                    .cornerRadius(4)
                                                }
                                            }
                                        }
                                        .padding(.vertical, 2)
                                    }
                                }
                                
                                // 正文
                                Text(chunk.text)
                                    .font(.system(size: 13))
                                    .lineSpacing(4)
                                    .textSelection(.enabled)
                                    .foregroundColor(isQualified ? .primary : .secondary)
                                    .padding(.top, 2)
                            }
                            .padding(.vertical, 8)
                            // 未达标切片施加轻微低饱和度降权视觉
                            .opacity(isQualified ? 1.0 : 0.65)
                        }
                    }
                }
            }
        }
        .frame(width: 840, height: 680)
    }
    
    private func performSearch() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        
        isSearching = true
        let startTime = CFAbsoluteTimeGetCurrent()
        Task {
            let enabledIds = viewModel.knowledgeBases
                .filter { kb in
                    guard kb.isEnabled && kb.status == "索引完成" else { return false }
                    if selectedCategory == "全部" {
                        return !viewModel.dedicatedCategories.contains(kb.category)
                    } else {
                        return kb.category == selectedCategory
                    }
                }
                .map { $0.id }
            
            let res = await MicroVectorDB.shared.search(
                query: text,
                enabledKbIds: enabledIds,
                topK: ConfigManager.shared.app.generalConfig.ragTopK,
                exactMatch: isExactMatch
            )
            let timeElapsed = CFAbsoluteTimeGetCurrent() - startTime
            await MainActor.run {
                self.results = res
                self.searchTime = timeElapsed
                self.isSearching = false
            }
        }
    }
    
    private func scoreColor(_ score: Float) -> Color {
        if score >= 0.8 { return .green }
        if score >= 0.5 { return .cyan }
        if score >= 0.35 { return .orange }
        return .red
    }
}

// MARK: - 分类架构与机制指南面板
struct CategoryManagerView: View {
    @Bindable var viewModel: KnowledgeViewModel
    var onClose: () -> Void
    @State private var newCategoryName = ""
    @State private var isNewCategoryDedicated = false
    
    @State private var editingCategory: String? = nil
    @State private var editName = ""
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("分类架构与机制指南").font(.headline)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }.buttonStyle(.plain)
            }.padding(); Divider()
            
            // 创建新分类区
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    TextField("输入新分类名称...", text: $newCategoryName).textFieldStyle(.roundedBorder)
                    
                    Toggle("设为专用区", isOn: $isNewCategoryDedicated).toggleStyle(.checkbox)
                    
                    Button("添加分类") {
                        if !newCategoryName.isEmpty {
                            viewModel.addCategory(newCategoryName, isDedicated: isNewCategoryDedicated)
                            newCategoryName = ""
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            
            Divider()
            
            List {
                Section(header: Text("📂 通用区 (被包含在'全部知识库'搜索范围内)").font(.caption).foregroundStyle(.secondary)) {
                    ForEach(viewModel.categories, id: \.self) { cat in categoryRow(name: cat, isDedicated: false) }
                }
                Section(header: Text("🔒 专用区 (小说写作/私密文档等，仅独立绑定时生效)").font(.caption).foregroundStyle(.purple)) {
                    ForEach(viewModel.dedicatedCategories, id: \.self) { cat in categoryRow(name: cat, isDedicated: true) }
                }
            }
            
            Divider(); HStack { Spacer(); Button("完成", action: onClose).keyboardShortcut(.defaultAction) }.padding()
        }.frame(width: 620, height: 600)
    }
    
    @ViewBuilder private func categoryRow(name: String, isDedicated: Bool) -> some View {
        HStack {
            if editingCategory == name {
                TextField("名称", text: $editName).textFieldStyle(.roundedBorder)
                Button("保存") { viewModel.renameCategory(oldName: name, newName: editName, isDedicated: isDedicated); editingCategory = nil }
            } else {
                Image(systemName: isDedicated ? "lock.doc.fill" : "folder.fill").foregroundStyle(isDedicated ? .purple.opacity(0.7) : .blue.opacity(0.7))
                Text(name).font(.system(size: 13))
                if isDedicated { Text("专用").font(.system(size: 9)).padding(.horizontal, 4).padding(.vertical, 1).background(Color.purple.opacity(0.1)).foregroundStyle(.purple).cornerRadius(4) }
                
                Spacer()
                
                if name != "默认" {
                    Button("重命名") { editName = name; editingCategory = name }.buttonStyle(.plain).foregroundStyle(.blue)
                    Button("删除") { viewModel.deleteCategory(name, isDedicated: isDedicated) }.buttonStyle(.plain).foregroundStyle(.red).padding(.leading, 8)
                }
            }
        }.padding(.vertical, 4)
    }
}

// MARK: - 知识切片详情预览 (显化结构化元数据徽章)
struct KnowledgeChunksPreviewView: View {
    let knowledge: KnowledgeItem; var onClose: () -> Void
    @State private var chunks: [MicroVectorDB.VectorChunk] = []
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("切片详情与结构化元数据预览").font(.headline)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
            }.padding(); Divider()
            
            List {
                ForEach(Array(chunks.enumerated()), id: \.element.id) { index, chunk in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Chunk #\(index + 1)").font(.caption).bold().foregroundStyle(.blue)
                            if let headers = chunk.metadata?.headingPath, !headers.isEmpty {
                                Text("[\(headers.joined(separator: " > "))]").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("字符数: \(chunk.text.count)").font(.caption).foregroundStyle(.secondary)
                        }
                        
                        // 显化切片提取出的结构化元数据徽章
                        if let meta = chunk.metadata {
                            if !meta.positiveTags.isEmpty || !meta.negativeTags.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        ForEach(meta.positiveTags, id: \.self) { tag in
                                            HStack(spacing: 3) {
                                                Image(systemName: "tag.fill").font(.system(size: 8))
                                                Text(tag).font(.system(size: 10, weight: .medium))
                                            }
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.cyan.opacity(0.15))
                                            .foregroundColor(.cyan)
                                            .cornerRadius(4)
                                        }
                                        
                                        ForEach(meta.negativeTags, id: \.self) { proh in
                                            HStack(spacing: 3) {
                                                Image(systemName: "nosign").font(.system(size: 8))
                                                Text(proh).font(.system(size: 10, weight: .medium))
                                            }
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.red.opacity(0.12))
                                            .foregroundColor(.red)
                                            .cornerRadius(4)
                                        }
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        
                        Text(chunk.text).font(.system(size: 13)).textSelection(.enabled)
                    }.padding(.vertical, 8)
                }
            }
        }.frame(width: 680, height: 560).onAppear { chunks = MicroVectorDB.shared.fetchChunks(for: knowledge.id) }
    }
}

// 知识库编辑视图
struct KnowledgeEditView: View {
    @State var knowledge: KnowledgeItem
    var categories: [String]
    var dedicatedCategories: [String]
    var isNew: Bool
    
    var onSave: (KnowledgeItem) -> Void
    var onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "新增知识库文档" : "编辑文档元数据")
                    .font(.headline)
                Spacer()
            }
            .padding()
            
            Divider()
            
            Form {
                Section {
                    TextField("文档标题", text: $knowledge.title)
                        .textFieldStyle(.roundedBorder)
                    
                    Picker("分类归属", selection: $knowledge.category) {
                        Section(header: Text("通用分类")) {
                            ForEach(categories, id: \.self) { Text("📂 \($0)").tag($0) }
                        }
                        if !dedicatedCategories.isEmpty {
                            Section(header: Text("专用分类")) {
                                ForEach(dedicatedCategories, id: \.self) { Text("🔒 \($0)").tag($0) }
                            }
                        }
                    }
                    
                    TextField("虚拟路径", text: Binding(
                        get: { knowledge.relativePath ?? "" },
                        set: { knowledge.relativePath = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .help("使用 '/' 分隔即可快速创建左侧多级树状目录，例如：'架构设计/2026/核心引擎.md'")
                    
                    if let filePath = knowledge.filePath, !isNew {
                        HStack(alignment: .top) {
                            Text("本地源路径:")
                                .foregroundColor(.secondary)
                            Text(filePath)
                                .foregroundColor(.gray)
                                .lineLimit(2)
                                .truncationMode(.middle)
                            Spacer()
                        }
                        .font(.system(size: 11))
                        .padding(.top, 2)
                    }
                }
                
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("AI 全局摘要 (支持人工微调):")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        
                        TextEditor(text: $knowledge.summary)
                            .font(.system(size: 13))
                            .frame(height: 120)
                            .padding(4)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                            )
                    }
                    .padding(.top, 8)
                }
            }
            .padding()
            .frame(width: 480)
            
            Divider()
            
            HStack {
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存更改") {
                    if let path = knowledge.relativePath {
                        knowledge.relativePath = path.trimmingCharacters(in: .whitespaces)
                    }
                    onSave(knowledge)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
    }
}

// MARK: - 检索测试独立窗口生命周期管理器
@MainActor
final class KnowledgeSearchWindowManager: NSObject, NSWindowDelegate {
    static let shared = KnowledgeSearchWindowManager()
    private var window: NSWindow?
    
    var isVisible: Bool { window != nil }
    private override init() { super.init() }
    
    func show(viewModel: KnowledgeViewModel) {
        if let existingWindow = window {
            if existingWindow.isMiniaturized { existingWindow.deminiaturize(nil) }
            existingWindow.makeKeyAndOrderFront(nil)
            existingWindow.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let contentView = KnowledgeSearchTestView(viewModel: viewModel) { [weak self] in
            self?.window?.close()
        }
        
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "知识库向量检索与自适应诊断"
        newWindow.center()
        newWindow.setFrameAutosaveName("LinTools_KnowledgeSearchTest_Window")
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self
        newWindow.isOpaque = false
        //newWindow.backgroundColor = .clear
        newWindow.hasShadow = true
        newWindow.titlebarAppearsTransparent = true
        newWindow.titleVisibility = .hidden
        newWindow.contentView = NSHostingView(rootView: contentView)
        
        self.window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        newWindow.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        MainWindowManager.syncDockIconPolicy()
    }
    
    func windowWillClose(_ notification: Notification) {
        window = nil
        MainWindowManager.syncDockIconPolicy()
    }
}

// MARK: - 算法逻辑与切片机制深度解析 Popover
struct RAGAlgorithmEngineGuidePopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 头部
            HStack(spacing: 8) {
                Image(systemName: "cpu.fill")
                    .foregroundColor(.cyan)
                    .font(.system(size: 14, weight: .bold))
                Text("微型向量库内核与自适应切片机制")
                    .font(.system(size: 13, weight: .bold))
                Spacer()
            }
            .padding(.bottom, 2)
            
            Divider().opacity(0.5)
            
            // 模块 1：双阶段检索与算分机制
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.merge")
                        .font(.system(size: 11))
                        .foregroundColor(.blue)
                    Text("1. 双阶段混合检索与 RRF 融合打分")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.primary)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("• **粗排检索 (Coarse Retrieval)**: 并发执行 BM25 词频统计与 300 维 NLEmbedding 余弦检索，采用倒数排名融合算法（RRF，k=60）动态混洗。")
                    Text("• **2-Gram 连续短语增强**: 自动构造双字/双词连续大根集，大幅提升专有名词与短语的命中灵敏度。")
                    Text("• **精排重排 (Native Reranker)**: 启用滑动窗口句子级余弦重排（Sentence-Level），结合标题字面匹配（+0.35）与核心词覆盖率多重加权。")
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.leading, 14)
            }
            
            // 模块 2：切片架构说明
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "doc.badge.gearshape")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                    Text("2. 切片自适应提取与结构规范")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.primary)
                }
                
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .top, spacing: 4) {
                        Text("• **Markdown 层级切片**:").bold().foregroundColor(.primary)
                        Text("自动捕获 `# 一至六级标题` 作为作用域边界，继承上下文并执行 Token 滑动窗口。")
                    }
                    HStack(alignment: .top, spacing: 4) {
                        Text("• **QA 问答原子切片**:").bold().foregroundColor(.primary)
                        Text("探测到连续 `Q:` / `A:` 时自动启用问答边界，条目独立成块，杜绝语义杂糅。")
                    }
                    HStack(alignment: .top, spacing: 4) {
                        Text("• **结构化标签提权**:").bold().foregroundColor(.cyan)
                        Text("`* **tags**: [...]` 正向标签享受 **1.5x ~ 5.0x** 阶梯提权，保障精准命中。")
                    }
                    HStack(alignment: .top, spacing: 4) {
                        Text("• **负向禁忌一票否决**:").bold().foregroundColor(.red)
                        Text("`* **prohibited**: [...]` 命中时强制扣减 -10.0 分（Hard Veto），防止错误召回。")
                    }
                    HStack(alignment: .top, spacing: 4) {
                        Text("• **源码 AST 提取**:").bold().foregroundColor(.purple)
                        Text("代码文件自动解析 Class、Function、Struct 边界，保留模块完整性。")
                    }
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.leading, 14)
            }
        }
        .padding(16)
        .frame(width: 440)
        .background(.regularMaterial)
    }
}

// MARK: - ==================== 5. 清洗引擎 ====================

struct DataCleaner: Sendable {
    nonisolated static func clean(_ rawText: String) -> String {
        var text = rawText.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        text = text.replacing(pattern: "[\\x00-\\x08\\x0B\\x0C\\x0E-\\x1F\\x7F]", with: "")
        text = text.replacing(pattern: "(?m)^\\s*(?:page|页码|第)?\\s*-?\\s*\\d+\\s*(?:of\\s*\\d+|页)?\\s*-?\\s*$", with: "")
        text = text.replacing(pattern: "<[^>]+>", with: " ")
        text = text.replacing(pattern: "[ \\t]{2,}", with: " ")
        text = text.replacing(pattern: "\\n{3,}", with: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    nonisolated static func isValidChunk(_ chunk: String) -> Bool {
        let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 15 { return false }
        let letters = trimmed.unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.alphanumerics.contains($0) }
        return (Double(letters.count) / Double(trimmed.count)) >= 0.3
    }
}

fileprivate extension String {
    nonisolated func replacing(pattern: String, with template: String) -> String {
        do { let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive]); return regex.stringByReplacingMatches(in: self, options: [], range: NSRange(self.startIndex..., in: self), withTemplate: template) } catch { return self }
    }
}

// MARK: - ==================== 6. 多语言代码专用切片逻辑 ====================

public struct CodeKnowledgeExtractor {
    
    public static func buildCodeSummaryPrompt(extraction: String, fileName: String) -> String {
        return """
        请对代码文件【\(fileName)】进行宏观架构层面的技术摘要，直接输出以下 4 项要点：
        1. 核心职责：一句话提炼本模块的设计目标与业务范畴。
        2. 关键组件：列出 2-4 个核心类/接口/方法及其在架构中的职能。
        3. 架构层级：标明所属技术层级（如 UI 视图层、业务逻辑层、数据持久层、网络通信层等）。
        4. 外部依赖：列出交互的外部模块或系统组件。

        [代码上下文]
        \(extraction)
        """
    }
    
    public static func chunkCodeFile(fileURL: URL, projectName: String = "当前项目") throws -> [String] {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let fileName = fileURL.lastPathComponent
        let ext = fileURL.pathExtension.lowercased()
        
        var chunks: [String] = []
        let pattern: String
        let declarationPattern: String
        
        switch ext {
        case "py":
            pattern = #"(?m)^[ \t]*(?:class|def)\s+[A-Za-z0-9_]+[\s\S]*?(?=\n\S|\Z)"#
            declarationPattern = #"(?:class|def)\s+([A-Za-z0-9_]+)"#
        case "java", "c", "cpp", "h", "cs":
            pattern = #"(?m)^[ \t]*(?:public\s+|private\s+|protected\s+)?(?:static\s+|virtual\s+)?(?:class|struct|interface|enum)\s+[^{]+\{([\s\S]*?^\})"#
            declarationPattern = #"(?:class|struct|interface|enum)\s+([A-Za-z0-9_]+)"#
        case "js", "ts":
            pattern = #"(?m)^[ \t]*(?:export\s+|default\s+)?(?:class|function|const)\s+[A-Za-z0-9_]+[\s\S]*?(?=\n\n|\Z)"#
            declarationPattern = #"(?:class|function|const)\s+([A-Za-z0-9_]+)"#
        case "go":
            pattern = #"(?m)^[ \t]*(?:func|type)\s+[A-Za-z0-9_]+[\s\S]*?(?=\n\n|\Z)"#
            declarationPattern = #"(?:func|type)\s+([A-Za-z0-9_]+)"#
        default:
            pattern = #"(?m)^(?:\s*@\w+\s*)*(?:public\s+|private\s+|internal\s+|open\s+)?(?:final\s+)?(?:class|struct|enum|protocol|actor|extension)\s+[^{]+\{([\s\S]*?^\})"#
            declarationPattern = #"(?:class|struct|enum|protocol|actor|extension)\s+([A-Za-z0-9_]+)"#
        }
        
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) {
            let nsString = content as NSString
            let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsString.length))
            
            for match in matches {
                let codeBlock = nsString.substring(with: match.range)
                var entityName = "Unknown"
                if let declRegex = try? NSRegularExpression(pattern: declarationPattern),
                   let declMatch = declRegex.firstMatch(in: codeBlock, range: NSRange(location: 0, length: (codeBlock as NSString).length)) {
                    entityName = (codeBlock as NSString).substring(with: declMatch.range(at: 1))
                }
                
                let enrichedChunk = """
                [所属模块]: \(entityName)
                ```\(ext)
                \(codeBlock)
                ```
                """
                chunks.append(enrichedChunk)
            }
        }
        
        if chunks.isEmpty {
            return generateFallbackChunks(content: content, fileName: fileName, ext: ext)
        }
        
        return chunks
    }
    
    private static func generateFallbackChunks(content: String, fileName: String, ext: String) -> [String] {
        var chunks: [String] = []
        var currentIndex = content.startIndex
        let chunkSize = 1000
        
        while currentIndex < content.endIndex {
            let endIndex = content.index(currentIndex, offsetBy: chunkSize, limitedBy: content.endIndex) ?? content.endIndex
            let chunkContent = String(content[currentIndex..<endIndex])
            chunks.append(chunkContent)
            currentIndex = endIndex
        }
        return chunks
    }
}

// MARK: - ==================== 7. 智能分词与 NLTagger 语言学实体解析引擎 ====================

public struct QueryAnalysis: Sendable {
    public let rawTokens: [String]
    public let anchorEntities: [String]    // 核心专名/名词锚点 (权重 1.0)
    public let effectiveTokens: [String]   // 有效实词与 2-Gram 组合
}

public struct SmartTokenizer: Sendable {
    
    /// 提取词法分词与字符级 2~4 Gram 连续片段（彻底免除对人工停用词库与分词边界的依赖）
    public static func tokenize(_ text: String) -> [String] {
        let cleanText = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return [] }
        
        var tokenSet: Set<String> = []
        
        // 1. Apple 原生 NLTokenizer 词法切分
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = cleanText
        if let lang = NLLanguageRecognizer.dominantLanguage(for: cleanText) {
            tokenizer.setLanguage(lang)
        }
        
        let trimSet = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        var words: [String] = []
        
        tokenizer.enumerateTokens(in: cleanText.startIndex..<cleanText.endIndex) { range, _ in
            let word = String(cleanText[range]).trimmingCharacters(in: trimSet)
            if !word.isEmpty {
                words.append(word)
                tokenSet.insert(word)
            }
            return true
        }
        
        // 2. 词级 2-Gram 拼接
        if words.count >= 2 {
            for i in 0..<(words.count - 1) {
                tokenSet.insert(words[i] + words[i+1])
            }
        }
        
        // 3. 字符级多尺度滑动 N-Gram (2-Gram, 3-Gram, 4-Gram)
        // 专为中文未登录专有名词（如 "利欧"、"京桥通"）设计的零词库连续特征提取
        let chars = Array(cleanText.filter { !$0.isWhitespace && !$0.isPunctuation })
        let charCount = chars.count
        
        if charCount >= 2 {
            for n in 2...min(4, charCount) {
                for i in 0...(charCount - n) {
                    let gram = String(chars[i..<(i + n)])
                    tokenSet.insert(gram)
                }
            }
        }
        
        // 保留整句特征
        tokenSet.insert(cleanText)
        
        return Array(tokenSet)
    }
}

// MARK: - 鲁棒性精排引擎
public actor NativeReranker: Sendable {
    public static let shared = NativeReranker()
    private init() {}
    
    func rerank(
        query: String,
        chunks: [MicroVectorDB.VectorChunk],
        topK: Int,
        idfMap: [String: Float] = [:]
    ) async -> [MicroVectorDB.VectorChunk] {
        guard !chunks.isEmpty else { return [] }
        
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryTokens = SmartTokenizer.tokenize(cleanQuery)
        
        // 提取有效核心词（>=2 字符且在库内有频次）
        let meaningfulTokens = queryTokens.filter { $0.count >= 2 && (idfMap[$0] ?? 0) > 0 }
        let coreTokens = meaningfulTokens.isEmpty ? queryTokens.filter { $0.count >= 2 } : meaningfulTokens
        
        let totalQueryIDF = coreTokens.reduce(0.0) { $0 + (idfMap[$1] ?? 1.0) }
        let sortedTokensByIDF = coreTokens.sorted { (idfMap[$0] ?? 0) > (idfMap[$1] ?? 0) }
        let topAnchorToken = sortedTokensByIDF.first
        let topAnchorIDF = topAnchorToken != nil ? (idfMap[topAnchorToken!] ?? 0.0) : 0.0
        
        let qVec = await MicroVectorDB.shared.generateEmbedding(for: cleanQuery)
        
        var rerankedChunks = await withTaskGroup(of: MicroVectorDB.VectorChunk.self) { group in
            for chunk in chunks {
                group.addTask {
                    var modifiedChunk = chunk
                    
                    let rerankScore = self.computeSentenceLevelScore(
                        chunkText: chunk.text,
                        chunkEmbedding: chunk.embedding,
                        queryVector: qVec
                    )
                    
                    let chunkTextLower = chunk.text.lowercased()
                    let meta = chunk.metadata
                    
                    // 1. 标题与所属模块全字面匹配加分
                    var exactTitleBonus: Float = 0.0
                    if let headers = meta?.headingPath, headers.contains(where: { $0.localizedCaseInsensitiveContains(cleanQuery) }) {
                        exactTitleBonus = 0.35
                    } else if chunkTextLower.contains(cleanQuery.lowercased()) {
                        exactTitleBonus = 0.20
                    }
                    
                    // 2. 动态计算核心信息覆盖率
                    var hitIDF: Float = 0.0
                    for token in coreTokens {
                        if chunkTextLower.contains(token) ||
                           (meta?.positiveTags.contains(where: { $0.lowercased().contains(token) }) ?? false) ||
                           (meta?.headingPath.contains(where: { $0.lowercased().contains(token) }) ?? false) {
                            hitIDF += idfMap[token] ?? 1.0
                        }
                    }
                    
                    let coverageRatio = totalQueryIDF > 0 ? (hitIDF / totalQueryIDF) : 0.0
                    var coverageBonus: Float = 0.0
                    if coverageRatio >= 0.4 {
                        coverageBonus = 0.15 * coverageRatio
                    }
                    
                    // 3. 标签提权与实体硬门禁
                    var tagMultiplier: Float = 1.0
                    var negativePenalty: Float = 0.0
                    
                    let hasTopAnchor = topAnchorToken != nil && (
                        chunkTextLower.contains(topAnchorToken!) ||
                        (meta?.positiveTags.contains(where: { $0.lowercased().contains(topAnchorToken!) }) ?? false) ||
                        (meta?.headingPath.contains(where: { $0.lowercased().contains(topAnchorToken!) }) ?? false)
                    )
                    
                    if topAnchorIDF > 1.0 && !hasTopAnchor && exactTitleBonus == 0.0 {
                        negativePenalty -= 0.55
                    } else if coreTokens.count >= 2 && coverageRatio < 0.20 && exactTitleBonus == 0.0 {
                        negativePenalty -= 0.40
                    }
                    
                    if let meta = meta {
                        // a) 负向 Tags 一票否决
                        if !meta.negativeTags.isEmpty {
                            let matchedNeg = coreTokens.filter { qt in
                                meta.negativeTags.contains(where: { $0.lowercased().contains(qt) })
                            }
                            if !matchedNeg.isEmpty {
                                negativePenalty -= 10.0
                            }
                        }
                        
                        // b) 正向 Tags 阶梯加权 (完全保留)
                        if !meta.positiveTags.isEmpty {
                            let matchedTags = coreTokens.filter { qt in
                                meta.positiveTags.contains(where: { $0.lowercased().contains(qt) || qt.contains($0.lowercased()) })
                            }
                            
                            let isExactTagMatch = meta.positiveTags.contains(where: { tag in
                                let cleanTag = tag.lowercased().trimmingCharacters(in: .whitespaces)
                                let cleanQ = cleanQuery.lowercased()
                                if cleanQ.contains(cleanTag) || cleanTag.contains(cleanQ) { return true }
                                guard cleanTag.count >= 3 else { return false }
                                let tagChars = Array(cleanTag)
                                for token in coreTokens where token.count >= 3 {
                                    let matchedCount = tagChars.filter { token.contains($0) }.count
                                    if Float(matchedCount) / Float(tagChars.count) >= 0.80 { return true }
                                }
                                let globalMatched = tagChars.filter { cleanQ.contains($0) }.count
                                return Float(globalMatched) / Float(tagChars.count) >= 0.85
                            })
                            
                            if isExactTagMatch {
                                tagMultiplier = 5.0
                            } else if !matchedTags.isEmpty {
                                let coverage = Float(matchedTags.count) / Float(max(1, coreTokens.count))
                                tagMultiplier = 1.5 + (coverage * 2.5)
                            } else {
                                tagMultiplier = 0.3
                            }
                        }
                    }
                    
                    let originalScore = chunk.score ?? 0
                    let normalizedRRF = min(originalScore * 15.0, 1.0)
                    
                    var enhancedCos = max(0.0, (rerankScore - 0.45) * 2.0)
                    if topAnchorIDF > 1.0 && !hasTopAnchor && exactTitleBonus == 0.0 {
                        enhancedCos *= 0.15
                    }
                    
                    let baseScore = (normalizedRRF * 0.30) + (enhancedCos * 0.70) + exactTitleBonus + coverageBonus
                    let finalMultiplier = baseScore > 0.05 ? tagMultiplier : 1.0
                    
                    let rawFinal = max(0.0, min(1.0, (baseScore * finalMultiplier) + negativePenalty))
                    modifiedChunk.score = rawFinal
                    modifiedChunk.debugInfo = String(format: "Raw:%.2f (Base:%.2f x%.1f Cov:%.0f%%) | Pen:%.2f", rawFinal, baseScore, finalMultiplier, coverageRatio * 100, negativePenalty)
                    
                    return modifiedChunk
                }
            }
            
            var results: [MicroVectorDB.VectorChunk] = []
            for await sc in group { results.append(sc) }
            return results
        }
        
        rerankedChunks = rerankedChunks.filter { ($0.score ?? 0) > 0 }
        rerankedChunks.sort { ($0.score ?? 0) > ($1.score ?? 0) }
        
        return Array(rerankedChunks.prefix(topK))
    }
    
    nonisolated private func computeSentenceLevelScore(chunkText: String, chunkEmbedding: [Float], queryVector: [Float]) -> Float {
        let chunkCos = computeCosine(a: queryVector, b: chunkEmbedding)
        var maxSentenceSimilarity: Float = chunkCos
        
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = chunkText
        
        let embeddingHelper = NLEmbedding.sentenceEmbedding(for: .simplifiedChinese)
            ?? NLEmbedding.wordEmbedding(for: .simplifiedChinese)
            ?? NLEmbedding.sentenceEmbedding(for: .english)
            ?? NLEmbedding.wordEmbedding(for: .english)
            
        guard let embeddingHelper = embeddingHelper else {
            return maxSentenceSimilarity
        }
        
        tokenizer.enumerateTokens(in: chunkText.startIndex..<chunkText.endIndex) { range, _ in
            let sentence = String(chunkText[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if sentence.count > 3 {
                var sVec: [Float] = []
                if let rawVec = embeddingHelper.vector(for: sentence) {
                    sVec = rawVec.map { Float($0) }
                } else {
                    let words = SmartTokenizer.tokenize(sentence)
                    var combined = [Double](repeating: 0, count: queryVector.count)
                    var count = 0
                    for w in words {
                        if let wv = embeddingHelper.vector(for: w) {
                            for i in 0..<min(queryVector.count, wv.count) { combined[i] += wv[i] }
                            count += 1
                        }
                    }
                    if count > 0 {
                        sVec = combined.map { Float($0 / Double(count)) }
                    }
                }
                
                if !sVec.isEmpty && sVec.count == queryVector.count {
                    let sim = computeCosine(a: queryVector, b: sVec)
                    if sim > maxSentenceSimilarity {
                        maxSentenceSimilarity = sim
                    }
                }
            }
            return true
        }
        
        return maxSentenceSimilarity
    }
    
    nonisolated private func computeCosine(a: [Float], b: [Float]) -> Float {
        guard a.count == b.count && !a.isEmpty else { return 0 }
        let n = vDSP_Length(a.count)
        var dotProduct: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dotProduct, n)
        var aNorm: Float = 0; vDSP_svesq(a, 1, &aNorm, n)
        var bNorm: Float = 0; vDSP_svesq(b, 1, &bNorm, n)
        let denominator = sqrt(aNorm) * sqrt(bNorm)
        return denominator == 0 ? 0 : dotProduct / denominator
    }
}

// MARK: - RAG 统一解析引擎 (支持提取 tags 与 prohibited)
struct RAGXMLParser {
    struct HitItem: Hashable, Identifiable {
        let id = UUID()
        let title: String
        let score: Float
        let tags: [String]
        let prohibited: [String]
        let snippet: String
        let rawContent: String
    }
    
    static func extractHits(from xmlString: String) -> [HitItem] {
        var results: [HitItem] = []
        let pattern = "(?s)<knowledge_chunk([^>]*)>\\s*<!\\[CDATA\\[(.*?)\\]\\]>"
        
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = regex.matches(in: xmlString, range: NSRange(xmlString.startIndex..., in: xmlString))
        
        for match in matches {
            if let attrRange = Range(match.range(at: 1), in: xmlString),
               let contentRange = Range(match.range(at: 2), in: xmlString) {
                
                let attrString = String(xmlString[attrRange])
                let rawContent = String(xmlString[contentRange])
                
                let title = extractAttr(named: "source_title", from: attrString) ?? "未知文档"
                let scoreStr = extractAttr(named: "rrf_score", from: attrString) ?? "0.0"
                let score = Float(scoreStr) ?? 0.0
                
                let tagsStr = extractAttr(named: "tags", from: attrString) ?? ""
                let tags = tagsStr.components(separatedBy: CharacterSet(charactersIn: ",，")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                
                let prohStr = extractAttr(named: "prohibited", from: attrString) ?? ""
                let prohibited = prohStr.components(separatedBy: CharacterSet(charactersIn: ",，")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                
                let validLines = rawContent.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("```") }
                
                let firstLine = validLines.first ?? "无可用文本摘要"
                results.append(HitItem(title: title, score: score, tags: tags, prohibited: prohibited, snippet: firstLine, rawContent: rawContent))
            }
        }
        return results
    }
    
    private static func extractAttr(named: String, from text: String) -> String? {
        let pattern = "\(named)=\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

// MARK: - Docling 安装向导与状态检测 Popover (macOS 14+ 视觉体验)

struct DoclingInstallGuidePopover: View {
    @Binding var isInstalled: Bool
    @State private var isChecking = false
    @State private var isCopied = false
    
    private let installCommand = "pip3 install docling"
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: isInstalled ? "checkmark.seal.fill" : "doc.badge.gearshape.fill")
                    .foregroundColor(isInstalled ? .green : .orange)
                    .font(.system(size: 16))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(isInstalled ? "Docling 结构化解析引擎已就绪" : "Docling 高保真文档解析引擎")
                        .font(.system(size: 13, weight: .bold))
                    Text("针对 DOCX / PDF / XLSX 进行 Markdown 表格与标题保真重构")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            
            Divider().opacity(0.5)
            
            if isInstalled {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").foregroundColor(.green)
                        Text("系统已自动启用 Docling 作为高精度首选解析通道。")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    Text("导入复杂多列表格、跨行合并表单时，将自动保留完整 Markdown 结构，避免字段错位。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(10)
                .background(Color.green.opacity(0.06))
                .cornerRadius(8)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("当前处于【系统原生解析降级模式】。如需保留 DOCX/PDF 中的复杂表格与排版层级，推荐通过终端快速安装：")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    
                    HStack {
                        Text(installCommand)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(.primary)
                        Spacer()
                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(installCommand, forType: .string)
                            withAnimation { isCopied = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { isCopied = false } }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                Text(isCopied ? "已复制" : "复制命令")
                            }
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(isCopied ? .green : .blue)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(isCopied ? Color.green.opacity(0.15) : Color.blue.opacity(0.1))
                            .cornerRadius(5)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.08), lineWidth: 1))
                }
            }
            
            HStack {
                Spacer()
                Button(action: {
                    isChecking = true
                    Task {
                        let status = await DoclingBridge.isAvailable()
                        await MainActor.run {
                            self.isInstalled = status
                            self.isChecking = false
                        }
                    }
                }) {
                    HStack(spacing: 4) {
                        if isChecking {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("重新检测环境")
                    }
                    .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 420)
        .background(.regularMaterial)
    }
}

