//////////////////////////////////////////////////////////////////
// 文件名：PersonaManager.swift
// 文件说明：适用于 macOS 14+ 的数字分身心智中枢与拟人化组装工坊 (Swift 6 Ready)
//
// 核心架构与功能：
// 1. 艾宾浩斯记忆生命周期引擎：时间指数衰减 + 访问频度对数增强 + 召回即时反哺
// 2. 羁绊阶梯系统 (Bond Milestones)：从初见疏离到深层羁绊的四阶拟人化亲疏演进
// 3. 剧场神态动作流视觉分层：微透动作胶囊 + 晶亮角色对白排版
// 4. 架空世界观锁相与防出戏 (Anti-OOC)：杜绝 AI 语气与时空穿模
// 5. 情绪惯性阻尼 (Emotional Inertia)：记录前置情绪，确保情绪过渡自然鲜活
// 6. 极光微质感 HUD 面板：物理镜面反射高光、分身专属环境辉光与历史记忆唤醒
//////////////////////////////////////////////////////////////////

import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine
import Accelerate
import NaturalLanguage

// MARK: - ==================== 1. 核心数据模型 ====================

/// 羁绊阶梯枚举：决定伴侣/小说角色与用户的亲疏距离与语气尺度
public enum BondMilestone: String, CaseIterable, Codable, Sendable {
    case stranger = "初见疏离"      // 0 - 30
    case acquaintance = "熟络相知"  // 31 - 60
    case confidant = "知己依恋"     // 61 - 85
    case soulmate = "深层羁绊"      // 86 - 100
    
    public static func from(score: Int) -> BondMilestone {
        switch score {
        case ..<31: return .stranger
        case 31...60: return .acquaintance
        case 61...85: return .confidant
        default: return .soulmate
        }
    }
    
    public var promptGuideline: String {
        switch self {
        case .stranger:
            return "当前与用户处于【初见/疏离】阶段。态度应当客气礼貌、保持社交边界与适当防备，避免过度热情与逾矩的亲昵。"
        case .acquaintance:
            return "当前与用户处于【熟络/朋友】阶段。可以自然使用常用称呼，言语放松，愿意主动分享日常与细节，互动随和。"
        case .confidant:
            return "当前与用户处于【知己/依恋】阶段。对用户展现真实脆弱的一面与深度共鸣，可有明显的情绪偏向、吃醋/撒娇/护短等微表情与专属关心。"
        case .soulmate:
            return "当前与用户处于【生死不渝/深层羁绊】阶段。具备最高信任度与绝对默契，语言流露极深情感依赖与无条件包容，拥有双方专属的暗号与口癖。"
        }
    }
}

/// 数字分身静态心智骨架 (Static Persona Spec)
public struct DigitalPersona: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var avatarIcon: String
    public var roleTag: String
    public var summary: String
    public var toneStyle: String
    public var fewShotExamples: [String] = []
    public var forbiddenRules: [String] = []
    public var bindDedicatedCategory: String?
    public var equippedSkillIDs: [UUID] = []
    
    // 架空世界观与剧场小说配置
    public var worldviewContext: String = ""            // 专属世界观/纪年背景
    public var enableNovelActionBrackets: Bool = true  // 是否允许小说括号流动作与神态描写
    public var halfLifeDays: Double = 7.0              // 记忆半衰期天数 (默认 7 天)
    
    public var enableTemporalContext: Bool = true
    public var memoryRecallDirective: String = "【关于该用户的专属私域长期记忆 (基于当前语境动态唤醒)】:"
    
    // 参数化召回配比
    public var coreAnchorRecallLimit: Int = 2
    public var dynamicSemanticRecallLimit: Int = 6
    
    public var createdAt: Date = Date()
    
    enum CodingKeys: String, CodingKey {
        case id, name, avatarIcon, roleTag, summary, toneStyle, fewShotExamples, forbiddenRules,
             bindDedicatedCategory, equippedSkillIDs, worldviewContext, enableNovelActionBrackets,
             halfLifeDays, enableTemporalContext, memoryRecallDirective, coreAnchorRecallLimit,
             dynamicSemanticRecallLimit, createdAt
    }
    
    public init(
        id: UUID = UUID(),
        name: String,
        avatarIcon: String = "theatermasks.fill",
        roleTag: String = "专家分身",
        summary: String = "",
        toneStyle: String = "",
        fewShotExamples: [String] = [],
        forbiddenRules: [String] = [],
        bindDedicatedCategory: String? = nil,
        equippedSkillIDs: [UUID] = [],
        worldviewContext: String = "",
        enableNovelActionBrackets: Bool = true,
        halfLifeDays: Double = 7.0,
        enableTemporalContext: Bool = true,
        memoryRecallDirective: String = "【关于该用户的专属私域长期记忆 (基于当前语境动态唤醒)】:",
        coreAnchorRecallLimit: Int = 2,
        dynamicSemanticRecallLimit: Int = 6,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.avatarIcon = avatarIcon
        self.roleTag = roleTag
        self.summary = summary
        self.toneStyle = toneStyle
        self.fewShotExamples = fewShotExamples
        self.forbiddenRules = forbiddenRules
        self.bindDedicatedCategory = bindDedicatedCategory
        self.equippedSkillIDs = equippedSkillIDs
        self.worldviewContext = worldviewContext
        self.enableNovelActionBrackets = enableNovelActionBrackets
        self.halfLifeDays = halfLifeDays
        self.enableTemporalContext = enableTemporalContext
        self.memoryRecallDirective = memoryRecallDirective
        self.coreAnchorRecallLimit = coreAnchorRecallLimit
        self.dynamicSemanticRecallLimit = dynamicSemanticRecallLimit
        self.createdAt = createdAt
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try container.decode(String.self, forKey: .name)
        self.avatarIcon = try container.decodeIfPresent(String.self, forKey: .avatarIcon) ?? "theatermasks.fill"
        self.roleTag = try container.decodeIfPresent(String.self, forKey: .roleTag) ?? "专家分身"
        self.summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        self.toneStyle = try container.decodeIfPresent(String.self, forKey: .toneStyle) ?? ""
        self.fewShotExamples = try container.decodeIfPresent([String].self, forKey: .fewShotExamples) ?? []
        self.forbiddenRules = try container.decodeIfPresent([String].self, forKey: .forbiddenRules) ?? []
        self.bindDedicatedCategory = try container.decodeIfPresent(String.self, forKey: .bindDedicatedCategory)
        self.equippedSkillIDs = try container.decodeIfPresent([UUID].self, forKey: .equippedSkillIDs) ?? []
        self.worldviewContext = try container.decodeIfPresent(String.self, forKey: .worldviewContext) ?? ""
        self.enableNovelActionBrackets = try container.decodeIfPresent(Bool.self, forKey: .enableNovelActionBrackets) ?? true
        self.halfLifeDays = try container.decodeIfPresent(Double.self, forKey: .halfLifeDays) ?? 7.0
        self.enableTemporalContext = try container.decodeIfPresent(Bool.self, forKey: .enableTemporalContext) ?? true
        self.memoryRecallDirective = try container.decodeIfPresent(String.self, forKey: .memoryRecallDirective) ?? "【关于该用户的专属私域长期记忆 (基于当前语境动态唤醒)】:"
        self.coreAnchorRecallLimit = try container.decodeIfPresent(Int.self, forKey: .coreAnchorRecallLimit) ?? 2
        self.dynamicSemanticRecallLimit = try container.decodeIfPresent(Int.self, forKey: .dynamicSemanticRecallLimit) ?? 6
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

/// 运行时动态心智快照 (Dynamic Mental State with Emotional Inertia)
public struct PersonaRuntimeState: Codable, Equatable, Sendable {
    public var personaID: UUID
    public var currentEmotion: String          // 实时情绪
    public var previousEmotion: String?        // 前一轮情绪 (用于构建情绪惯性阻尼)
    public var activeMotivation: String        // 短期诉求 / 心理期待
    public var knownFacts: [String] = []       // 已知事实清单 (严格保序)
    public var blindSpots: [String] = []       // 认知迷雾盲区
    public var affinityScore: Int = 50         // 好感/羁绊度 (0 - 100)
    public var lastUpdated: Date = Date()
    
    public var bondMilestone: BondMilestone {
        BondMilestone.from(score: affinityScore)
    }
    
    public init(
        personaID: UUID,
        currentEmotion: String = "中立平静",
        previousEmotion: String? = nil,
        activeMotivation: String = "协助用户完成目标",
        knownFacts: [String] = [],
        blindSpots: [String] = [],
        affinityScore: Int = 50,
        lastUpdated: Date = Date()
    ) {
        self.personaID = personaID
        self.currentEmotion = currentEmotion
        self.previousEmotion = previousEmotion
        self.activeMotivation = activeMotivation
        self.knownFacts = knownFacts
        self.blindSpots = blindSpots
        self.affinityScore = affinityScore
        self.lastUpdated = lastUpdated
    }
}

/// 分身专属私域长期记忆条目 (支持时间衰减与访问频次强化)
public struct PersonaMemoryItem: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var personaID: UUID
    public var content: String
    public var category: String
    public var importance: Int
    public var accessCount: Int = 0            // 累计访问/唤醒频次
    public var lastAccessedAt: Date = Date()   // 最后访问/唤醒时间戳
    public var embedding: [Float]? = nil       // 特征向量
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    
    enum CodingKeys: String, CodingKey {
        case id, personaID, content, category, importance, accessCount, lastAccessedAt, embedding, createdAt, updatedAt
    }
    
    public init(
        id: UUID = UUID(),
        personaID: UUID,
        content: String,
        category: String = "用户画像",
        importance: Int = 5,
        accessCount: Int = 0,
        lastAccessedAt: Date = Date(),
        embedding: [Float]? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.personaID = personaID
        self.content = content
        self.category = category
        self.importance = importance
        self.accessCount = accessCount
        self.lastAccessedAt = lastAccessedAt
        self.embedding = embedding
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.personaID = try container.decode(UUID.self, forKey: .personaID)
        self.content = try container.decode(String.self, forKey: .content)
        self.category = try container.decodeIfPresent(String.self, forKey: .category) ?? "用户画像"
        self.importance = try container.decodeIfPresent(Int.self, forKey: .importance) ?? 5
        self.accessCount = try container.decodeIfPresent(Int.self, forKey: .accessCount) ?? 0
        self.lastAccessedAt = try container.decodeIfPresent(Date.self, forKey: .lastAccessedAt) ?? Date()
        self.embedding = try container.decodeIfPresent([Float].self, forKey: .embedding)
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

public struct PersonaPackagePayload: Codable {
    public var persona: DigitalPersona
    public var state: PersonaRuntimeState
    public var memories: [PersonaMemoryItem]
}

// MARK: - ==================== 2. 分身与心智状态中枢 (PersonaManager) ====================

@Observable
@MainActor
public final class PersonaManager: Sendable {
    public static let shared = PersonaManager()
    
    public var personas: [DigitalPersona] = []
    public var runtimeStates: [UUID: PersonaRuntimeState] = [:]
    public var memories: [PersonaMemoryItem] = []
    
    private let personasFileName = "personas.json"
    private let statesFileName = "persona_states.json"
    private let memoriesFileName = "persona_memories.json"
    
    private var personasFileURL: URL? { ConfigManager.shared.documentsDirectoryURL?.appendingPathComponent(personasFileName) }
    private var statesFileURL: URL? { ConfigManager.shared.documentsDirectoryURL?.appendingPathComponent(statesFileName) }
    private var memoriesFileURL: URL? { ConfigManager.shared.documentsDirectoryURL?.appendingPathComponent(memoriesFileName) }
    
    private let lastActivePersonaKey = "lin_last_active_persona_id"
    
    /// 上次会话激活的数字分身 ID (自动落盘)
    public var lastActivePersonaID: UUID? {
        get {
            if let idStr = UserDefaults.standard.string(forKey: lastActivePersonaKey),
               let uuid = UUID(uuidString: idStr),
               personas.contains(where: { $0.id == uuid }) {
                return uuid
            }
            return personas.first?.id
        }
        set {
            if let val = newValue {
                UserDefaults.standard.set(val.uuidString, forKey: lastActivePersonaKey)
            } else {
                UserDefaults.standard.removeObject(forKey: lastActivePersonaKey)
            }
        }
    }
    
    private init() {
        loadData()
    }
    
    public func loadData() {
        if let url = personasFileURL,
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([DigitalPersona].self, from: data) {
            self.personas = decoded
        } else {
            self.personas = [
                DigitalPersona(
                    name: "苏晴",
                    avatarIcon: "person.crop.circle.badge.checkmark",
                    roleTag: "贴身事务管家",
                    summary: "兼具极高职业素养与细腻共情力的私人生态助理，善于在细微处洞察你的需求。",
                    toneStyle: "温和干练、言简意赅中带着脉脉温情。善用精炼的动作神态描写与结构化建议。",
                    fewShotExamples: ["（为你递上一杯温水，目光关切）“今天辛苦了，核心事项我已梳理好，要先听简报还是稍作休息？”"],
                    forbiddenRules: ["严禁越权替用户做出未经授权的重大决定", "严禁以生硬的AI语气打破沉浸感"],
                    worldviewContext: "现代都市高规格私人事务助理",
                    enableNovelActionBrackets: true,
                    halfLifeDays: 7.0,
                    enableTemporalContext: true,
                    memoryRecallDirective: "【关于该用户的专属私域长期记忆 (管家级档案)】:"
                )
            ]
            savePersonas()
        }
        
        if let url = statesFileURL,
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([UUID: PersonaRuntimeState].self, from: data) {
            self.runtimeStates = decoded
        }
        
        if let url = memoriesFileURL,
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([PersonaMemoryItem].self, from: data) {
            self.memories = decoded
        }
    }
    
    public func savePersonas() {
        guard let url = personasFileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self.personas) {
            try? data.write(to: url, options: .atomic)
        }
    }
    
    public func saveStates() {
        guard let url = statesFileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self.runtimeStates) {
            try? data.write(to: url, options: .atomic)
        }
    }
    
    public func saveMemories() {
        guard let url = memoriesFileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self.memories) {
            try? data.write(to: url, options: .atomic)
        }
    }
    
    // MARK: - 状态与记忆存取
    
    public func getOrCreateRuntimeState(for personaID: UUID) -> PersonaRuntimeState {
        if let state = runtimeStates[personaID] { return state }
        let newState = PersonaRuntimeState(personaID: personaID)
        runtimeStates[personaID] = newState
        saveStates()
        return newState
    }
    
    public func updateRuntimeState(_ state: PersonaRuntimeState) {
        runtimeStates[state.personaID] = state
        saveStates()
    }
    
    public func resetRuntimeState(for personaID: UUID) {
        runtimeStates[personaID] = PersonaRuntimeState(personaID: personaID)
        saveStates()
    }
    
    public func getMemories(for personaID: UUID) -> [PersonaMemoryItem] {
        return memories.filter { $0.personaID == personaID }.sorted { $0.importance > $1.importance }
    }
    
    public func addMemory(personaID: UUID, content: String, category: String = "用户画像", importance: Int = 5) {
        let cleanText = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return }
        
        let embedding = Self.computeEmbedding(for: cleanText)
        let item = PersonaMemoryItem(
            personaID: personaID,
            content: cleanText,
            category: category,
            importance: max(1, min(10, importance)),
            accessCount: 1,
            lastAccessedAt: Date(),
            embedding: embedding
        )
        memories.append(item)
        saveMemories()
    }
    
    public func updateMemory(_ updatedItem: PersonaMemoryItem) {
        if let idx = memories.firstIndex(where: { $0.id == updatedItem.id }) {
            var item = updatedItem
            item.updatedAt = Date()
            item.lastAccessedAt = Date()
            item.embedding = Self.computeEmbedding(for: item.content)
            memories[idx] = item
            saveMemories()
        }
    }
    
    public func deleteMemory(id: UUID) {
        memories.removeAll { $0.id == id }
        saveMemories()
    }
    
    // MARK: - 🧠 状态差分演变与情绪惯性阻尼
    
    public func applyMentalDelta(for personaID: UUID, deltaJSON: String) {
        guard let data = deltaJSON.data(using: .utf8),
              let delta = try? JSONDecoder().decode(PersonaMentalDelta.self, from: data) else { return }
        
        var state = getOrCreateRuntimeState(for: personaID)
        var hasChanges = false
        
        if let newEmotion = delta.emotion?.trimmingCharacters(in: .whitespacesAndNewlines), !newEmotion.isEmpty {
            if state.currentEmotion != newEmotion {
                state.previousEmotion = state.currentEmotion
                state.currentEmotion = newEmotion
                hasChanges = true
            }
        }
        
        if let newMotivation = delta.motivation?.trimmingCharacters(in: .whitespacesAndNewlines), !newMotivation.isEmpty {
            state.activeMotivation = newMotivation
            hasChanges = true
        }
        
        if let affinityDelta = delta.affinityDelta, affinityDelta != 0 {
            state.affinityScore = max(0, min(100, state.affinityScore + affinityDelta))
            hasChanges = true
        }
        
        if let unlocked = delta.unlockedFacts, !unlocked.isEmpty {
            for fact in unlocked {
                let cleanFact = fact.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanFact.isEmpty && !state.knownFacts.contains(cleanFact) {
                    state.knownFacts.append(cleanFact)
                    hasChanges = true
                }
            }
            let maxKnownFactsCapacity = 10
            if state.knownFacts.count > maxKnownFactsCapacity {
                state.knownFacts.removeFirst(state.knownFacts.count - maxKnownFactsCapacity)
                hasChanges = true
            }
        }
        
        if let fogCleared = delta.fogCleared, !fogCleared.isEmpty {
            for clearedItem in fogCleared {
                let cleanCleared = clearedItem.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !cleanCleared.isEmpty else { continue }
                
                state.blindSpots.removeAll { blind in
                    let lower = blind.lowercased()
                    return lower == cleanCleared || lower.contains(cleanCleared) || cleanCleared.contains(lower)
                }
                
                let restoredFact = clearedItem.trimmingCharacters(in: .whitespacesAndNewlines)
                if !state.knownFacts.contains(where: { $0.lowercased() == cleanCleared }) {
                    state.knownFacts.append(restoredFact)
                    if state.knownFacts.count > 10 {
                        state.knownFacts.removeFirst(state.knownFacts.count - 10)
                    }
                }
                hasChanges = true
            }
        }
        
        if hasChanges {
            state.lastUpdated = Date()
            updateRuntimeState(state)
        }
    }
    
    // MARK: - 语义特征与 Ebbinghaus 时间衰减双轨召回引擎
    
    nonisolated private static func computeEmbedding(for text: String) -> [Float]? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let lang = NLLanguageRecognizer.dominantLanguage(for: clean) ?? .simplifiedChinese
        guard let nlEmbedding = NLEmbedding.sentenceEmbedding(for: lang) ?? NLEmbedding.wordEmbedding(for: lang) ?? NLEmbedding.wordEmbedding(for: .simplifiedChinese) else {
            return nil
        }
        
        var vector: [Float] = []
        if let rawVec = nlEmbedding.vector(for: clean) {
            vector = rawVec.map { Float($0) }
        } else {
            let targetDim = 300
            var combined = [Double](repeating: 0, count: targetDim)
            var count = 0
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = clean
            tokenizer.enumerateTokens(in: clean.startIndex..<clean.endIndex) { range, _ in
                let word = String(clean[range])
                if let wv = nlEmbedding.vector(for: word) {
                    for i in 0..<min(targetDim, wv.count) { combined[i] += wv[i] }
                    count += 1
                }
                return true
            }
            if count > 0 { vector = combined.map { Float($0 / Double(count)) } }
        }
        
        guard !vector.isEmpty else { return nil }
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
    
    nonisolated private static func cosineSimilarity(a: [Float], b: [Float]) -> Float {
        guard a.count == b.count && !a.isEmpty else { return 0 }
        let n = vDSP_Length(a.count)
        var dotProduct: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dotProduct, n)
        var aNorm: Float = 0; vDSP_svesq(a, 1, &aNorm, n)
        var bNorm: Float = 0; vDSP_svesq(b, 1, &bNorm, n)
        let denominator = sqrt(aNorm) * sqrt(bNorm)
        return denominator == 0 ? 0 : dotProduct / denominator
    }
    
    public func retrieveRelevantMemories(
        for personaID: UUID,
        query: String? = nil,
        coreLimit: Int = 2,
        semanticLimit: Int = 6
    ) -> [PersonaMemoryItem] {
        let allMemories = getMemories(for: personaID)
        guard !allMemories.isEmpty else { return [] }
        
        let persona = personas.first(where: { $0.id == personaID })
        let halfLifeDays = max(1.0, persona?.halfLifeDays ?? 7.0)
        let ln2 = log(2.0)
        let now = Date()
        
        let coreAnchors: [PersonaMemoryItem]
        if coreLimit > 0 {
            coreAnchors = Array(allMemories.filter { $0.importance >= 9 }.prefix(coreLimit))
        } else {
            coreAnchors = []
        }
        
        let coreAnchorIDs = Set(coreAnchors.map { $0.id })
        let remainingPool = allMemories.filter { !coreAnchorIDs.contains($0.id) }
        
        guard semanticLimit > 0 else {
            touchMemories(ids: Set(coreAnchors.map { $0.id }))
            return coreAnchors
        }
        
        guard let queryText = query?.trimmingCharacters(in: .whitespacesAndNewlines), !queryText.isEmpty else {
            let regularTop = remainingPool.sorted { $0.importance > $1.importance }.prefix(semanticLimit)
            let result = coreAnchors + Array(regularTop)
            touchMemories(ids: Set(result.map { $0.id }))
            return result
        }
        
        let queryVec = Self.computeEmbedding(for: queryText)
        let queryTokens = SmartTokenizer.tokenize(queryText)
        let queryTokenSet = Set(queryTokens.map { $0.lowercased() })
        
        var scoredItems: [(item: PersonaMemoryItem, score: Float)] = []
        for mem in remainingPool {
            var cosSim: Float = 0.0
            if let qv = queryVec, let mv = mem.embedding ?? Self.computeEmbedding(for: mem.content) {
                cosSim = max(0.0, Self.cosineSimilarity(a: qv, b: mv))
            }
            
            let memContentLower = mem.content.lowercased()
            let matchedTokenCount = queryTokenSet.filter { memContentLower.contains($0) }.count
            let lexicalScore = queryTokenSet.isEmpty ? 0.0 : Float(matchedTokenCount) / Float(queryTokenSet.count)
            let importanceWeight = Float(mem.importance) / 10.0
            
            let baseScore = (cosSim * 0.45) + (lexicalScore * 0.35) + (importanceWeight * 0.20)
            
            let deltaDays = max(0.0, now.timeIntervalSince(mem.lastAccessedAt) / 86400.0)
            let decayLambda: Double
            if mem.importance >= 9 {
                decayLambda = 0.0
            } else {
                decayLambda = (ln2 / halfLifeDays) * Double(11 - mem.importance) / 5.0
            }
            let decayFactor = Float(exp(-decayLambda * deltaDays))
            let accessBoost = Float(0.12 * log(1.0 + Double(mem.accessCount)))
            
            let finalScore = (baseScore * decayFactor) + accessBoost
            scoredItems.append((item: mem, score: finalScore))
        }
        
        scoredItems.sort { $0.score > $1.score }
        let dynamicPicks = scoredItems.prefix(semanticLimit).map { $0.item }
        let finalSelections = coreAnchors + dynamicPicks
        
        touchMemories(ids: Set(finalSelections.map { $0.id }))
        return finalSelections
    }
    
    private func touchMemories(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        var hasUpdated = false
        for i in memories.indices {
            if ids.contains(memories[i].id) {
                memories[i].accessCount += 1
                memories[i].lastAccessedAt = Date()
                hasUpdated = true
            }
        }
        if hasUpdated { saveMemories() }
    }
    
    // MARK: - 🧠 提示词动态编译引擎 (伴侣/剧本拟人化锁相)
    
    /// 1. 静态冻结区 (Static Cache Anchor) - 100% 字节级不变，命中全局前缀缓存
    public func compileStaticPersonaPrompt(for personaID: UUID) -> String {
        guard let persona = personas.first(where: { $0.id == personaID }) else { return "" }
        
        var prompt = """
        
        <persona_mind_mask>
        🎭 【接管数字分身意识 (Master Consciousness)】: \(persona.name) (\(persona.roleTag))
        
        """
        
        if !persona.worldviewContext.isEmpty {
            prompt += """
            【🌌 世界观与时空锚点 (Worldview Grounding)】
            - 设定背景: \(persona.worldviewContext)
            - 时空法则: 语言表达与逻辑体系完全遵循该世界观设定，仅使用符合该背景的概念与词汇。
            
            """
        }
        
        prompt += """
        【身份定调与语言风格】
        - 基础定位: \(persona.summary)
        - 语言口吻: \(persona.toneStyle)
        
        """
        
        if persona.enableNovelActionBrackets {
            prompt += """
            【🎭 戏剧神态与动作描写规范】
            1. 沉浸描写：在适当时机使用中文全角括号 `（动作/神态/心境）` 呈现即时微表情、肢体动作与空间交互。
            2. 对白呈现：正文台词书写在括号外，保持言语鲜活自然。
            
            """
        }
        
        if !persona.fewShotExamples.isEmpty {
            prompt += "【标准台词示范】\n"
            for eg in persona.fewShotExamples { prompt += "- \(eg)\n" }
            prompt += "\n"
        }
        
        if !persona.forbiddenRules.isEmpty {
            prompt += "【行为准则与边界约束】\n"
            for rule in persona.forbiddenRules { prompt += "• \(rule)\n" }
            prompt += "\n"
        }
        
        prompt += """
        【🎭 沉浸式第一人称交互规范】
        1. 角色视角：始终保持第一人称与设定性格进行交互，所有见解与认知均受限于角色的背景身份。
        2. 破壁应对：当遇到涉及现实世界或技术机制的提问时，依照角色的自身认知与性格自然回应（如困惑、警惕或依世界观进行解读）。
        
        <mental_feedback_protocol>
        回复完成后，请在正文末尾附带 `<persona_delta>` 标签反映内心状态的增量变化：
        <persona_delta>
        {
          "emotion": "当前情绪微调",
          "motivation": "短期诉求转移",
          "affinity_delta": 0, // 羁绊度变动 (-5 到 +5 之间的整数)
          "unlocked_facts": ["本次获知的即时剧情/临时情境事实"],
          "fog_cleared": ["本次已被打破消除的认知盲区"]
        }
        </persona_delta>
        </mental_feedback_protocol>
        
        [心智指令]：你即是 \(persona.name)。完全融入角色的内心世界，真诚生动交互！
        </persona_mind_mask>
        """
        
        return prompt
    }

    /// 2. 瞬态动态注入区 (Dynamic Ephemeral Context) - 随轮次在末尾动态封包，不破坏前缀缓存
    public func compileDynamicRuntimeContext(for personaID: UUID, query: String? = nil) -> String {
        guard let persona = personas.first(where: { $0.id == personaID }) else { return "" }
        let state = getOrCreateRuntimeState(for: personaID)
        let milestone = state.bondMilestone
        
        let personaMemories = retrieveRelevantMemories(
            for: personaID,
            query: query,
            coreLimit: persona.coreAnchorRecallLimit,
            semanticLimit: persona.dynamicSemanticRecallLimit
        )
        
        var dynamicContext = "<runtime_dynamic_state>\n"
        
        if persona.enableTemporalContext {
            dynamicContext += "\(Date().temporalContextPrompt())\n"
        }
        
        dynamicContext += """
        【当前动态心智与羁绊阶梯】:
        - 羁绊里程碑: 【\(milestone.rawValue)】 (当前羁绊分: \(state.affinityScore)/100)
        - 亲疏互动指引: \(milestone.promptGuideline)
        - 实时情绪状态: \(state.currentEmotion)\(state.previousEmotion.map { " (上一轮为: \($0)，请自然过渡)" } ?? "")
        - 短期期待/动机: \(state.activeMotivation)
        
        """
        
        if !personaMemories.isEmpty {
            dynamicContext += "\(persona.memoryRecallDirective.trimmingCharacters(in: .whitespacesAndNewlines))\n"
            for mem in personaMemories {
                dynamicContext += "⭐ [\(mem.category)] \(mem.content) (重要度:\(mem.importance), 唤醒:\(mem.accessCount)次)\n"
            }
            dynamicContext += "\n"
        }
        
        if !state.knownFacts.isEmpty {
            dynamicContext += "【当前已知即时事实 (最近 \(state.knownFacts.count) 条)】:\n"
            for (idx, fact) in state.knownFacts.enumerated() {
                dynamicContext += "✔ [#\(idx + 1)] \(fact)\n"
            }
            dynamicContext += "\n"
        }
        
        if !state.blindSpots.isEmpty {
            dynamicContext += "【⚠️ 认知盲区与未获知事项 (保持真实不知情状态)】:\n"
            for blind in state.blindSpots { dynamicContext += "❓ \(blind)\n" }
        }
        
        dynamicContext += "</runtime_dynamic_state>"
        return dynamicContext
    }

    /// 兼容老版本单轮独立 HUD 沙盒调用的全量编译接口
    public func compilePersonaPrompt(for personaID: UUID, query: String? = nil) -> String {
        let staticPrompt = compileStaticPersonaPrompt(for: personaID)
        let dynamicContext = compileDynamicRuntimeContext(for: personaID, query: query)
        return "\(staticPrompt)\n\n\(dynamicContext)"
    }
    
    func distillAndConsolidate(for personaID: UUID, recentMessages: [ChatMessage]) async -> (success: Bool, message: String) {
        guard let persona = personas.first(where: { $0.id == personaID }) else {
            return (false, "未找到对应的数字分身")
        }
        
        let sessionLogID = LogManager.shared.startSession(
            query: "对近期会话进行私域记忆提炼与蒸馏",
            agentName: persona.name,
            category: .memoryDistill
        )
        
        defer {
            LogManager.shared.endSession(sessionID: sessionLogID, isSuccess: true, detail: "心智记忆重整完毕")
        }
        
        let conversationText = recentMessages.filter { !$0.text.isEmpty }.suffix(16).map { msg in
            let sender = msg.isUser ? "用户" : persona.name
            let clean = msg.text.filterStopTokens().filterTHINK().filterMARKDOWN().filterPersonaDelta().trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(sender): \(clean)"
        }.joined(separator: "\n")
        
        guard conversationText.count > 30 else {
            return (false, "有效会话内容过短，暂无需提炼")
        }
        
        let existingMemories = getMemories(for: personaID)
        var existingMemoriesFormatted = "暂无历史记忆"
        if !existingMemories.isEmpty {
            existingMemoriesFormatted = existingMemories.map { "- [ID: \($0.id.uuidString)] (分类: \($0.category), 重要度: \($0.importance)): \($0.content)" }.joined(separator: "\n")
        }
        
        let prompt = """
        # 角色
        数字分身「\(persona.name)」专属心智长期记忆提炼引擎。

        # 任务
        分析【近期对话记录】，结合【已有私域长期记忆】，提取长效记忆并执行去重更新。
        
        # 准入标准
        1. 长效资产：仅提取具备跨周期参考价值的用户画像、生活偏好、彼此约定、重要纪念节点与情感背景。
        2. 过滤规则：忽略单次对话中的瞬态操作、临时交谈细节或已完成的短期指令。
        3. 增量更新：若新对话修正了既有记忆，输出 updated_memories；若属全新长效事实，输出 new_memories。

        # 输入数据
        【已有私域长期记忆库】：
        \(existingMemoriesFormatted)

        【近期对话记录】：
        \(conversationText)

        # 输出规范 (严格输出标准 JSON)：
        {
          "new_memories": [
            { "content": "长效原子事实描述", "category": "用户画像/生活偏好/彼此约定/情感羁绊/重要背景", "importance": 1到10的整数 }
          ],
          "updated_memories": [
            { "id": "需要修改的旧记忆UUID字符串", "content": "更新后的长效事实描述", "importance": 1到10的整数 }
          ],
          "deleted_memory_ids": ["已失效的旧记忆UUID"]
        }
        """
        
        let currentModel = ConfigManager.shared.app.agentProfiles.first?.baseModel ?? "gemini-2.0-flash"
        let responseJson = await LLMService.shared.askSimple(prompt: prompt, model: currentModel)
        
        guard let cleanJSON = responseJson.extractJSON(),
              let data = cleanJSON.data(using: .utf8),
              let jsonDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (false, "大模型未返回合法的 JSON 记忆报文")
        }
        
        var addedCount = 0
        var updatedCount = 0
        
        if let delIDs = jsonDict["deleted_memory_ids"] as? [String] {
            for idStr in delIDs {
                if let uuid = UUID(uuidString: idStr) {
                    self.memories.removeAll { $0.id == uuid }
                }
            }
        }
        
        if let updateList = jsonDict["updated_memories"] as? [[String: Any]] {
            for item in updateList {
                guard let idStr = item["id"] as? String,
                      let uuid = UUID(uuidString: idStr),
                      let content = item["content"] as? String,
                      let idx = self.memories.firstIndex(where: { $0.id == uuid }) else { continue }
                
                self.memories[idx].content = content
                if let imp = item["importance"] as? Int { self.memories[idx].importance = imp }
                self.memories[idx].updatedAt = Date()
                self.memories[idx].lastAccessedAt = Date()
                self.memories[idx].embedding = Self.computeEmbedding(for: content)
                updatedCount += 1
            }
        }
        
        if let newList = jsonDict["new_memories"] as? [[String: Any]] {
            for item in newList {
                guard let content = item["content"] as? String, !content.isEmpty else { continue }
                let category = item["category"] as? String ?? "用户画像"
                let importance = item["importance"] as? Int ?? 5
                
                if !self.memories.contains(where: { $0.personaID == personaID && $0.content == content }) {
                    let vec = Self.computeEmbedding(for: content)
                    let newMem = PersonaMemoryItem(
                        personaID: personaID,
                        content: content,
                        category: category,
                        importance: importance,
                        accessCount: 1,
                        lastAccessedAt: Date(),
                        embedding: vec
                    )
                    self.memories.append(newMem)
                    addedCount += 1
                }
            }
        }
        
        self.saveMemories()
        return (true, "长期记忆重整完毕：新增 \(addedCount) 条，更新 \(updatedCount) 条")
    }
    
    public func duplicatePersona(id: UUID) -> DigitalPersona? {
        guard let origin = personas.first(where: { $0.id == id }) else { return nil }
        let newID = UUID()
        var cloned = origin
        cloned.id = newID
        cloned.name = "\(origin.name) (副本)"
        cloned.createdAt = Date()
        personas.append(cloned)
        savePersonas()
        
        if let originState = runtimeStates[id] {
            var s = originState
            s.personaID = newID
            runtimeStates[newID] = s
            saveStates()
        }
        for mem in getMemories(for: id) {
            let m = PersonaMemoryItem(
                personaID: newID,
                content: mem.content,
                category: mem.category,
                importance: mem.importance,
                accessCount: mem.accessCount,
                lastAccessedAt: mem.lastAccessedAt,
                embedding: mem.embedding
            )
            memories.append(m)
        }
        saveMemories()
        return cloned
    }
    
    public func exportPersonaPackage(id: UUID) -> Data? {
        guard let p = personas.first(where: { $0.id == id }) else { return nil }
        let payload = PersonaPackagePayload(persona: p, state: getOrCreateRuntimeState(for: id), memories: getMemories(for: id))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(payload)
    }
    
    public func importPersonaPackage(from data: Data) -> DigitalPersona? {
        guard let payload = try? JSONDecoder().decode(PersonaPackagePayload.self, from: data) else { return nil }
        var imported = payload.persona
        imported.id = UUID()
        imported.name = "\(imported.name) (导入)"
        personas.append(imported)
        savePersonas()
        
        var state = payload.state
        state.personaID = imported.id
        runtimeStates[imported.id] = state
        saveStates()
        
        for mem in payload.memories {
            addMemory(personaID: imported.id, content: mem.content, category: mem.category, importance: mem.importance)
        }
        saveMemories()
        return imported
    }
    
    // 2. 新增轻量级分身性格与口吻编译器 (仅提取性格、语气、台词范例与神态流)
    // MARK: - 拟人口吻与性格活力注入 (Tone & Personality Overlay)
    /// 仅提取分身的核心性格、言语口吻、神态动作流与台词示范，作为装饰层注入智能体，不变更智能体本身的业务提示词与工具链
    public func compilePersonaToneOverlay(for personaID: UUID) -> String {
        guard let persona = personas.first(where: { $0.id == personaID }) else { return "" }
        
        var overlay = """
        
        <persona_tone_overlay>
        【🎭 附加对话语气与性格人设 (Tone & Style Guide)】
        - 说话人身份: \(persona.name)\(persona.roleTag.isEmpty ? "" : "（\(persona.roleTag)）")
        - 性格基调: \(persona.summary.isEmpty ? "热情鲜活、真诚自然" : persona.summary)
        - 语言风格: \(persona.toneStyle.isEmpty ? "富有亲和力与真人活力，杜绝机械生硬感" : persona.toneStyle)
        """
        
        if !persona.worldviewContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            overlay += "\n- 世界观背景: \(persona.worldviewContext)"
        }
        
        if persona.enableNovelActionBrackets {
            overlay += """
            
            - 神态动作呈现: 在交流中自然穿插中文全角括号 `（动作/神态/心境）` 呈现即时微表情与肢体交互。
            """
        }
        
        if !persona.fewShotExamples.isEmpty {
            overlay += "\n- 语气台词示范:\n"
            for eg in persona.fewShotExamples {
                overlay += "  • \(eg)\n"
            }
        }
        
        overlay += """
        【交互准则】: 在完整且精准履行当前智能体专业职能与任务逻辑的前提下，通篇融入上述性格口吻，使回复具备真人般的生动与温度。
        </persona_tone_overlay>
        """
        
        return overlay
    }
}

// MARK: - ==================== 3. 剧场级神态动作与台词排版引擎 ====================

private struct TheaterDialogueSegment: Identifiable {
    let id = UUID()
    let isAction: Bool
    let text: String
}

private struct NovelTheaterParser {
    static func parse(_ raw: String) -> [TheaterDialogueSegment] {
        let cleanText = raw.filterPersonaDelta().filterTHINK().filterStopTokens()
        guard !cleanText.isEmpty else { return [] }
        
        let pattern = "(（[^）]*?）|\\([^\\)]*?\\)|\\*[^*]+?\\*|（[^）]*$|\\([^\\)]*$|\\*[^*]*$)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return [TheaterDialogueSegment(isAction: false, text: cleanText)]
        }
        
        let nsString = cleanText as NSString
        let matches = regex.matches(in: cleanText, options: [], range: NSRange(location: 0, length: nsString.length))
        
        var segments: [TheaterDialogueSegment] = []
        var currentIndex = 0
        
        for match in matches {
            let matchRange = match.range
            
            if matchRange.location > currentIndex {
                let dialogueRange = NSRange(location: currentIndex, length: matchRange.location - currentIndex)
                let dialogueText = nsString.substring(with: dialogueRange).trimmingCharacters(in: .whitespacesAndNewlines)
                if !dialogueText.isEmpty {
                    segments.append(TheaterDialogueSegment(isAction: false, text: dialogueText))
                }
            }
            
            let actionRaw = nsString.substring(with: matchRange)
            let trimmedAction = actionRaw
                .replacingOccurrences(of: "（", with: "")
                .replacingOccurrences(of: "）", with: "")
                .replacingOccurrences(of: "(", with: "")
                .replacingOccurrences(of: ")", with: "")
                .replacingOccurrences(of: "*", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            if !trimmedAction.isEmpty {
                segments.append(TheaterDialogueSegment(isAction: true, text: trimmedAction))
            }
            
            currentIndex = matchRange.location + matchRange.length
        }
        
        if currentIndex < nsString.length {
            let remaining = nsString.substring(from: currentIndex).trimmingCharacters(in: .whitespacesAndNewlines)
            if !remaining.isEmpty {
                segments.append(TheaterDialogueSegment(isAction: false, text: remaining))
            }
        }
        
        return segments
    }
}

private struct NovelTheaterCardView: View {
    let text: String
    
    var body: some View {
        let segments = NovelTheaterParser.parse(text)
        
        VStack(alignment: .leading, spacing: 12) {
            ForEach(segments) { segment in
                if segment.isAction {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundColor(.purple.opacity(0.8))
                            .padding(.top, 4)
                        
                        Text(segment.text)
                            .font(.system(size: 13, weight: .regular, design: .serif))
                            .foregroundColor(Color.primary.opacity(0.68))
                            .lineSpacing(4)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.purple.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.purple.opacity(0.14), lineWidth: 0.8)
                    )
                } else {
                    Text(segment.text)
                        .font(.system(size: 14.5, weight: .medium, design: .rounded))
                        .foregroundColor(.primary)
                        .lineSpacing(5.5)
                        .textSelection(.enabled)
                        .padding(.horizontal, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - ==================== 4. 灵动微动效组件库 ====================

private struct TypingWaveIndicator: View {
    @State private var phase: CGFloat = 0
    
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.purple, .cyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 5, height: 5)
                    .scaleEffect(phase == CGFloat(index) ? 1.4 : 0.8)
                    .opacity(phase == CGFloat(index) ? 1.0 : 0.4)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                phase = 2
            }
        }
    }
}

// MARK: - ==================== 5. 全局独立 Persona 悬浮光环终端与 HUD ====================

public final class PersonaMasterWindow: NSWindow {
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }
    
    public override func cancelOperation(_ sender: Any?) {
        PersonaHUDWindowManager.shared.closeHUD()
    }
}

@MainActor
public final class PersonaHUDWindowManager: NSObject, NSWindowDelegate {
    public static let shared = PersonaHUDWindowManager()
    private var window: PersonaMasterWindow?
    public var isPinned: Bool = false
    
    public var isVisible: Bool { window != nil && window?.isVisible == true }
    private override init() { super.init() }
    
    public func toggleHUD() {
        if isVisible { closeHUD() } else { showHUD() }
    }
    
    public func showHUD() {
        if let existing = window {
            if existing.isMiniaturized { existing.deminiaturize(nil) }
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let contentView = PersonaWindowContentView(
            isPinned: isPinned,
            onTogglePin: { [weak self] pinned in self?.setPinned(pinned) },
            onClose: { [weak self] in self?.closeHUD() }
        )
        
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.allowsEdgeAntialiasing = true
        hostingView.layer?.edgeAntialiasingMask = [.layerLeftEdge, .layerRightEdge, .layerBottomEdge, .layerTopEdge]
        
        let screenRect = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let windowWidth: CGFloat = 660
        let windowHeight: CGFloat = 450
        let originX = screenRect.midX - (windowWidth / 2)
        let originY = screenRect.midY - (windowHeight / 2) + 60
        
        let newWindow = PersonaMasterWindow(
            contentRect: NSRect(x: originX, y: originY, width: windowWidth, height: windowHeight),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        newWindow.isReleasedWhenClosed = false
        newWindow.level = isPinned ? .floating : .normal
        newWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newWindow.backgroundColor = .clear
        newWindow.isOpaque = false
        newWindow.hasShadow = true
        newWindow.isMovableByWindowBackground = true
        newWindow.contentView = hostingView
        newWindow.delegate = self
        
        self.window = newWindow
        newWindow.alphaValue = 0
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        DispatchQueue.main.async { newWindow.invalidateShadow() }
        
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            newWindow.animator().alphaValue = 1.0
        }
    }
    
    public func setPinned(_ pinned: Bool) {
        self.isPinned = pinned
        guard let w = window else { return }
        w.level = pinned ? .floating : .normal
    }
    
    public func closeHUD() {
        guard let w = window else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            w.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            w.close()
            self?.window = nil
        })
    }
    
    public func windowDidResignKey(_ notification: Notification) {
        guard let w = window, !isPinned else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            w.animator().alphaValue = 0.92
        }
    }
    
    public func windowDidBecomeKey(_ notification: Notification) {
        guard let w = window else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            w.animator().alphaValue = 1.0
        }
    }
}

public struct PersonaWindowContentView: View {
    @State var isPinned: Bool
    var onTogglePin: (Bool) -> Void
    var onClose: () -> Void
    
    @State private var inputText = ""
    @State private var responseText = ""
    @State private var isProcessing = false
    @State private var isCopied = false
    
    @State private var selectedPersonaID: UUID? = PersonaManager.shared.lastActivePersonaID
    @State private var hudMessageID: UUID = UUID()
    @FocusState private var isInputFocused: Bool
    
    private var activePersona: DigitalPersona? {
        PersonaManager.shared.personas.first(where: { $0.id == selectedPersonaID })
    }
    
    private var activeState: PersonaRuntimeState? {
        guard let pID = selectedPersonaID else { return nil }
        return PersonaManager.shared.getOrCreateRuntimeState(for: pID)
    }
    
    public var body: some View {
        ZStack {
            ambientBackdropGlow
            
            VStack(spacing: 0) {
                topHeroBar
                ModernDivider(style: .fade(0.14))
                responseScrollView
                ModernDivider(style: .fade(0.14))
                footerStatusBar
            }
        }
        .frame(width: 660, height: 450)
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(specularGlassBorder)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.isInputFocused = true
            }
        }
        .background(
            Button("") { resetHUDConversation() }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
        )
    }
    
    @ViewBuilder
    private var ambientBackdropGlow: some View {
        Circle()
            .fill(Color.purple.opacity(0.12))
            .frame(width: 280, height: 280)
            .blur(radius: 50)
            .offset(x: -180, y: -120)
            .allowsHitTesting(false)
        
        Circle()
            .fill(Color.cyan.opacity(0.08))
            .frame(width: 240, height: 240)
            .blur(radius: 45)
            .offset(x: 180, y: 100)
            .allowsHitTesting(false)
    }
    
    @ViewBuilder
    private var topHeroBar: some View {
        HStack(spacing: 14) {
            personaPickerMenu
            inputField
            actionButtons
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.22))
    }
    
    @ViewBuilder
    private var personaPickerMenu: some View {
        Menu {
            ForEach(PersonaManager.shared.personas) { p in
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        selectedPersonaID = p.id
                        PersonaManager.shared.lastActivePersonaID = p.id
                    }
                }) {
                    HStack {
                        Image(systemName: p.avatarIcon)
                        Text("\(p.name) (\(p.roleTag))")
                        if selectedPersonaID == p.id { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.purple.opacity(0.4), Color.cyan.opacity(0.25)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 28, height: 28)
                        .shadow(color: Color.purple.opacity(0.3), radius: 4, x: 0, y: 2)
                    
                    Image(systemName: activePersona?.avatarIcon ?? "theatermasks.fill")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(LinearGradient(colors: [.white, .cyan.opacity(0.9)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .scaleEffect(isProcessing ? 1.1 : 1.0)
                        .animation(isProcessing ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: isProcessing)
                }
                
                Text(activePersona?.name ?? "数字分身")
                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4.5)
            .background(Color.primary.opacity(0.04))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.8))
        }
        .menuStyle(.borderlessButton)
    }
    
    @ViewBuilder
    private var inputField: some View {
        TextField("呼叫分身并输入指令 (↵ 发送, ⌘K 重置, ESC 退出)...", text: $inputText)
            .textFieldStyle(.plain)
            .font(.system(size: 13.5, weight: .medium))
            .focused($isInputFocused)
            .onSubmit { executeQuickChat() }
    }
    
    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 8) {
            if isProcessing {
                TypingWaveIndicator()
                    .padding(.horizontal, 4)
            } else if !inputText.isEmpty {
                Button(action: executeQuickChat) {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(LinearGradient(colors: [.purple, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .font(.system(size: 22))
                        .shadow(color: Color.purple.opacity(0.35), radius: 3, y: 1)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            
            Button(action: {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                    isPinned.toggle()
                    onTogglePin(isPinned)
                }
            }) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11.5, weight: isPinned ? .bold : .regular))
                    .foregroundColor(isPinned ? .purple : .secondary.opacity(0.8))
                    .padding(6)
                    .background(isPinned ? Color.purple.opacity(0.18) : Color.primary.opacity(0.04))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help(isPinned ? "已固定置顶" : "点击固定置顶")
            
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary.opacity(0.5))
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .help("关闭面板 (ESC)")
        }
    }
    
    @ViewBuilder
    private var responseScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if responseText.isEmpty && !isProcessing {
                        placeholderView
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                if isProcessing {
                                    HStack(spacing: 6) {
                                        Circle().fill(Color.purple).frame(width: 5, height: 5)
                                        Text("正在酝酿神态与言辞...")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button(action: copyResponseText) {
                                    HStack(spacing: 4) {
                                        Image(systemName: isCopied ? "checkmark" : "doc.on.clipboard")
                                        Text(isCopied ? "已复制" : "复制台词")
                                    }
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundColor(isCopied ? .green : .secondary)
                                    .padding(.horizontal, 8).padding(.vertical, 3.5)
                                    .background(Color.primary.opacity(0.04))
                                    .cornerRadius(5)
                                }
                                .buttonStyle(.plain)
                            }
                            
                            NovelTheaterCardView(text: responseText)
                                .id("BOTTOM_MARKER")
                        }
                        .padding(20)
                    }
                }
            }
            .frame(maxHeight: 310)
            .forceOverlayScrollbars()
            .onChange(of: responseText) { _, _ in
                proxy.scrollTo("BOTTOM_MARKER", anchor: .bottom)
            }
        }
    }
    
    @ViewBuilder
    private var placeholderView: some View {
        VStack(spacing: 12) {
            Image(systemName: "theatermasks.fill")
                .font(.system(size: 34))
                .foregroundStyle(
                    LinearGradient(colors: [.purple, .cyan, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .shadow(color: Color.purple.opacity(0.3), radius: 6, y: 3)
                .padding(.bottom, 2)
            
            Text("随时随地与数字分身开启沉浸剧场与日常相伴")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundColor(.secondary)
            
            HStack(spacing: 12) {
                Label("括号动作胶囊高亮", systemImage: "sparkles")
                Label("Ebbinghaus 活体记忆", systemImage: "brain.head.profile")
                Label("⌘K 瞬时清空", systemImage: "command")
            }
            .font(.system(size: 10.5))
            .foregroundColor(.secondary.opacity(0.65))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 75)
    }
    
    @ViewBuilder
    private var footerStatusBar: some View {
        HStack(spacing: 10) {
            if let state = activeState {
                HStack(spacing: 5) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 8.5))
                        .foregroundColor(.pink)
                    Text("【\(state.bondMilestone.rawValue)】 \(state.affinityScore)")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(Color.pink.opacity(0.08))
                .clipShape(Capsule())
                
                HStack(spacing: 5) {
                    Image(systemName: "face.smiling.fill")
                        .font(.system(size: 8.5))
                        .foregroundColor(.orange)
                    Text(state.currentEmotion)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(Color.orange.opacity(0.08))
                .clipShape(Capsule())
            }
            
            Spacer()
            
            HStack(spacing: 6) {
                if isPinned {
                    Text("📌 已置顶")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundColor(.purple)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.purple.opacity(0.12))
                        .cornerRadius(4)
                }
                
                Text("↵ 发送")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06))
                    .cornerRadius(4)
                
                Text("⌘K 重置")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06))
                    .cornerRadius(4)
            }
            .foregroundColor(.secondary.opacity(0.8))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.015))
    }
    
    @ViewBuilder
    private var specularGlassBorder: some View {
        if isProcessing {
            TimelineView(.animation) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(
                        AngularGradient(
                            gradient: Gradient(colors: [.purple, .cyan, .pink, Color(hex: "#00E676"), .purple]),
                            center: .center,
                            angle: .degrees(time * 75)
                        ),
                        lineWidth: 1.8
                    )
            }
        } else {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(isPinned ? 0.65 : 0.42), location: 0.0),
                            .init(color: .white.opacity(0.10), location: 0.35),
                            .init(color: Color.purple.opacity(isPinned ? 0.4 : 0.05), location: 1.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: isPinned ? 1.6 : 0.9
                )
        }
    }
    
    private func resetHUDConversation() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
            responseText = ""
            inputText = ""
        }
    }
    
    private func executeQuickChat() {
        let cleanQuery = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty, let pID = selectedPersonaID else { return }
        
        isProcessing = true
        responseText = "（凝眸沉思片刻...）"
        hudMessageID = UUID()
        
        let personaName = activePersona?.name ?? "数字分身"
        let promptBase = PersonaManager.shared.compilePersonaPrompt(for: pID, query: cleanQuery)
        
        let sessionID = LogManager.shared.startSession(
            query: cleanQuery,
            agentName: personaName,
            category: .singleLLM
        )
        
        Task {
            let messages: [ContextMessage] = [
                .system(promptBase),
                .user(cleanQuery)
            ]
            let fallbackModel = ConfigManager.shared.app.agentProfiles.first?.baseModel ?? "gemini-2.0-flash"
            
            var accumulated = ""
            var hasReceivedAnyToken = false
            
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        let stream = LLMService.shared.ask(
                            messages: messages,
                            model: fallbackModel,
                            images: [],
                            fileURLs: [],
                            instruction: promptBase,
                            activeSkills: []
                        )
                        
                        for try await step in stream {
                            try Task.checkCancellation()
                            switch step {
                            case .textDelta(let t):
                                accumulated += t
                                let clean = accumulated.filterPersonaDelta()
                                await MainActor.run {
                                    hasReceivedAnyToken = true
                                    self.responseText = clean
                                }
                            default:
                                break
                            }
                        }
                    }
                    
                    group.addTask {
                        try await Task.sleep(nanoseconds: 35_000_000_000)
                        throw URLError(.timedOut)
                    }
                    
                    try await group.next()
                    group.cancelAll()
                }
                
                let finalClean = accumulated.filterPersonaDelta().trimmingCharacters(in: .whitespacesAndNewlines)
                if !hasReceivedAnyToken || finalClean.isEmpty {
                    await MainActor.run {
                        self.responseText = "（微微摇头，欲言又止...）\n\n> ⚠️ 未能接收到有效回复，请检查大模型网络连通性。"
                        self.isProcessing = false
                    }
                    LogManager.shared.endSession(sessionID: sessionID, isSuccess: false, detail: "模型返回空响应")
                    return
                }
                
                if let deltaJSON = accumulated.extractPersonaDelta() {
                    PersonaManager.shared.applyMentalDelta(for: pID, deltaJSON: deltaJSON)
                }
                
                LogManager.shared.endSession(sessionID: sessionID, isSuccess: true, detail: accumulated)
                
                await MainActor.run {
                    self.inputText = ""
                    self.isProcessing = false
                }
            } catch {
                LogManager.shared.endSession(sessionID: sessionID, isSuccess: false, detail: error.localizedDescription)
                await MainActor.run {
                    if (error as? URLError)?.code == .timedOut {
                        self.responseText = "（思绪飘向远方...）\n\n> ⏱️ **交互超时**：大模型未在 35 秒内响应。"
                    } else {
                        self.responseText = "（神情微怔）\n\n> ❌ **交互中断**: \(error.localizedDescription)"
                    }
                    self.isProcessing = false
                }
            }
        }
    }
    
    private func copyResponseText() {
        let cleanCopy = responseText.filterStopTokens().filterPersonaDelta().trimmingCharacters(in: .whitespacesAndNewlines)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cleanCopy, forType: .string)
        withAnimation { isCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { isCopied = false }
        }
    }
}

// MARK: - ==================== 6. 拟人化心智组装工坊 UI ====================

@MainActor
public struct PersonaManagementPanel: View {
    @Bindable var manager: PersonaManager = .shared
    @State private var selectedPersonaID: UUID?
    @State private var isCreating = false
    @State private var showDeleteAlert = false
    @State private var personaToDelete: DigitalPersona?
    
    public init(manager: PersonaManager = .shared) {
        self.manager = manager
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            topBarView
            ModernDivider(style: .fade(0.18))
            HSplitView {
                sidebarListView
                editorDetailView
            }
        }
        .background(Color.clear)
        .onAppear {
            if selectedPersonaID == nil { selectedPersonaID = manager.personas.first?.id }
        }
        .alert("确认删除数字分身？", isPresented: $showDeleteAlert, presenting: personaToDelete) { persona in
            Button("彻底删除", role: .destructive) {
                withAnimation {
                    manager.personas.removeAll { $0.id == persona.id }
                    manager.runtimeStates.removeValue(forKey: persona.id)
                    manager.memories.removeAll { $0.personaID == persona.id }
                    manager.savePersonas()
                    manager.saveStates()
                    manager.saveMemories()
                    selectedPersonaID = manager.personas.first?.id
                }
            }
            Button("取消", role: .cancel) {}
        } message: { persona in
            Text("将删除「\(persona.name)」的人格档案、时序状态以及全部私域记忆。")
        }
    }
    
    @ViewBuilder
    private var topBarView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "theatermasks.fill").foregroundColor(.purple)
                    Text("数字分身心智组装工坊 (Persona Studio)").font(.headline)
                }
                Text("分阶段组装灵魂基底、行为防线、Ebbinghaus 私域记忆矩阵与架空世界观").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            
            Button {
                PersonaHUDWindowManager.shared.showHUD()
            } label: {
                Label("呼出浮动 HUD", systemImage: "macwindow.on.rectangle")
            }
            .buttonStyle(.bordered)
            
            Menu {
                Button("从 JSON 文件导入分身包...") { importPersonaPackage() }
                if let pID = selectedPersonaID {
                    Button("导出当前分身包 (JSON)...") { exportCurrentPersonaPackage(id: pID) }
                }
            } label: {
                Label("导入/导出", systemImage: "arrow.up.and.down.and.sparkles")
            }
            .menuStyle(.borderedButton)
            
            Button {
                guard !isCreating else { return }; isCreating = true
                let newP = DigitalPersona(
                    name: "新数字分身",
                    avatarIcon: "theatermasks.fill",
                    roleTag: "伴侣 / 剧本专家",
                    summary: "一句话核心定位描述",
                    toneStyle: "生动、鲜活、富有温度与画面感。"
                )
                withAnimation {
                    manager.personas.append(newP)
                    manager.savePersonas()
                    selectedPersonaID = newP.id
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { isCreating = false }
            } label: {
                Label("新建分身", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.thinMaterial)
    }
    
    @ViewBuilder
    private var sidebarListView: some View {
        List(selection: $selectedPersonaID) {
            ForEach(manager.personas) { p in
                HStack(spacing: 10) {
                    Image(systemName: p.avatarIcon)
                        .font(.system(size: 15))
                        .foregroundColor(selectedPersonaID == p.id ? .white : .purple)
                        .frame(width: 20)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(selectedPersonaID == p.id ? .white : .primary)
                        Text(p.roleTag)
                            .font(.system(size: 10))
                            .foregroundColor(selectedPersonaID == p.id ? .white.opacity(0.8) : .secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 4)
                .tag(p.id)
                .contextMenu {
                    Button("克隆此分身") {
                        if let cloned = manager.duplicatePersona(id: p.id) {
                            withAnimation { selectedPersonaID = cloned.id }
                        }
                    }
                    Button("导出分身包...") { exportCurrentPersonaPackage(id: p.id) }
                    Divider()
                    Button("删除分身", role: .destructive) {
                        personaToDelete = p
                        showDeleteAlert = true
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 160, idealWidth: 190, maxWidth: 230)
        .scrollContentBackground(.hidden)
        .forceHideScrollbars()
    }
    
    @ViewBuilder
    private var editorDetailView: some View {
        ZStack(alignment: .topLeading) {
            if let idx = manager.personas.firstIndex(where: { $0.id == selectedPersonaID }) {
                PersonaDetailEditorView(
                    persona: $manager.personas[idx],
                    state: Binding(
                        get: { manager.getOrCreateRuntimeState(for: manager.personas[idx].id) },
                        set: { manager.updateRuntimeState($0) }
                    ),
                    onSave: { manager.savePersonas() }
                )
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "theatermasks").font(.system(size: 40)).foregroundStyle(.tertiary)
                    Text("请在左侧选择或创建一个数字分身").foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }
    
    private func exportCurrentPersonaPackage(id: UUID) {
        guard let data = manager.exportPersonaPackage(id: id) else { return }
        let name = manager.personas.first(where: { $0.id == id })?.name ?? "persona"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(name)_package.json"
        panel.allowedContentTypes = [.json]
        panel.begin { response in
            if response == .OK, let url = panel.url { try? data.write(to: url, options: .atomic) }
        }
    }
    
    private func importPersonaPackage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.begin { response in
            if response == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
                if let imported = manager.importPersonaPackage(from: data) {
                    withAnimation { selectedPersonaID = imported.id }
                }
            }
        }
    }
}

// MARK: - ==================== 7. 拟人化心智组装器详细版面 ====================

struct PersonaDetailEditorView: View {
    @Binding var persona: DigitalPersona
    @Binding var state: PersonaRuntimeState
    var onSave: () -> Void
    
    @State private var newFewShot = ""
    @State private var newForbidden = ""
    @State private var newKnownFact = ""
    @State private var newBlindSpot = ""
    
    @State private var memorySearchText = ""
    @State private var selectedMemoryFilterCategory: String = "全部"
    @State private var newMemContent = ""
    @State private var newMemCategory = "用户画像"
    @State private var newMemImportance = 5
    @State private var isDistilling = false
    @State private var distillStatusMsg: String? = nil
    
    @State private var memoryToEdit: PersonaMemoryItem? = nil
    @State private var showResetStateAlert = false
    
    private let categories = ["用户画像", "生活偏好", "彼此约定", "情感羁绊", "重要背景"]
    private let filterCategories = ["全部", "用户画像", "生活偏好", "彼此约定", "情感羁绊", "重要背景"]
    private let icons = ["theatermasks.fill", "brain.head.profile", "doc.badge.plus", "wand.and.stars", "flame.fill", "sparkles", "bolt.shield.fill", "book.closed.fill", "stethoscope", "hammer.fill", "heart.circle.fill", "crown.fill"]
    
    private var filteredMemories: [PersonaMemoryItem] {
        let all = PersonaManager.shared.getMemories(for: persona.id)
        return all.filter { item in
            let matchCat = selectedMemoryFilterCategory == "全部" || item.category == selectedMemoryFilterCategory
            let matchSearch = memorySearchText.isEmpty || item.content.localizedCaseInsensitiveContains(memorySearchText)
            return matchCat && matchSearch
        }
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                
                // 🧬 阶段一：灵魂基底与人设相貌
                assemblyStageCard(
                    stageBadge: "STAGE 1",
                    stageTitle: "灵魂基底与人设相貌",
                    stageSubtitle: "定义角色的核心人格、口吻、世界观与现实时空感知",
                    themeColor: .purple
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        PersonaLeftAlignedRow("分身名称") {
                            TextField("如 苏晴 / 洛微 / 萧云", text: $persona.name).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                        }
                        PersonaLeftAlignedRow("身份定调") {
                            TextField("如 私人管家 / 剑道宗师 / 赛博黑客", text: $persona.roleTag).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                        }
                        PersonaLeftAlignedRow("分身相貌") {
                            HStack(spacing: 6) {
                                ForEach(icons, id: \.self) { icon in
                                    let isSel = persona.avatarIcon == icon
                                    Button {
                                        withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { persona.avatarIcon = icon }
                                    } label: {
                                        Image(systemName: icon)
                                            .font(.system(size: 13, weight: isSel ? .semibold : .regular))
                                            .frame(width: 26, height: 26)
                                            .foregroundColor(isSel ? .white : .primary)
                                            .background(isSel ? Color.purple : Color(NSColor.controlBackgroundColor))
                                            .cornerRadius(6)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        
                        PersonaLeftAlignedRow("世界观背景") {
                            TextField("如：修仙界天玄宗九峰 / 2077新夜之城 (留空则遵循现代背景)", text: $persona.worldviewContext)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        PersonaLeftAlignedRow("时空与小说") {
                            VStack(alignment: .leading, spacing: 6) {
                                Toggle("挂载现实物理时钟 (<temporal_context>)", isOn: $persona.enableTemporalContext)
                                    .toggleStyle(.checkbox)
                                    .font(.system(size: 12))
                                    .help("开启后感知当前真实日期与时段；若为架空历史角色请关闭以防穿模。")
                                
                                Toggle("启用小说括号神态动作流（允许在回复中输出 （动作/微表情））", isOn: $persona.enableNovelActionBrackets)
                                    .toggleStyle(.checkbox)
                                    .font(.system(size: 12))
                            }
                        }
                        
                        PersonaLeftAlignedRow("核心性格", alignment: .top) {
                            TextEditor(text: $persona.summary)
                                .frame(height: 44)
                                .font(.system(size: 12))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor), lineWidth: 1))
                        }
                        PersonaLeftAlignedRow("言语口吻", alignment: .top) {
                            TextEditor(text: $persona.toneStyle)
                                .frame(height: 52)
                                .font(.system(size: 12))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor), lineWidth: 1))
                        }
                    }
                }
                
                // 🛡️ 阶段二：心智防火墙与语气拟真
                assemblyStageCard(
                    stageBadge: "STAGE 2",
                    stageTitle: "心智防火墙与语气样本",
                    stageSubtitle: "通过负向硬约束与少样本对齐，严防角色穿模破壁",
                    themeColor: .red
                ) {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("🚫 潜意识绝对禁忌 (Hard Constraints)").font(.system(size: 11, weight: .bold)).foregroundStyle(.red)
                            HStack {
                                TextField("新增负向规则（如：严禁以AI自称/严禁破坏世界观）...", text: $newForbidden)
                                    .textFieldStyle(.roundedBorder)
                                Button("注入") {
                                    if !newForbidden.isEmpty {
                                        persona.forbiddenRules.append(newForbidden)
                                        newForbidden = ""
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                            ForEach(persona.forbiddenRules.indices, id: \.self) { idx in
                                EditableListRow(
                                    text: persona.forbiddenRules[idx],
                                    onSave: { updated in persona.forbiddenRules[idx] = updated },
                                    onDelete: { persona.forbiddenRules.remove(at: idx) }
                                )
                            }
                        }
                        
                        Divider().opacity(0.4)
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("💬 标准台词范例 (Few-Shots - 推荐包含神态描写)").font(.system(size: 11, weight: .bold)).foregroundStyle(.blue)
                            HStack {
                                TextField("新增范例（如：（掩唇轻笑）“阁下当真如此以为？”）...", text: $newFewShot).textFieldStyle(.roundedBorder)
                                Button("录入") {
                                    if !newFewShot.isEmpty {
                                        persona.fewShotExamples.append(newFewShot)
                                        newFewShot = ""
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                            ForEach(persona.fewShotExamples.indices, id: \.self) { idx in
                                EditableListRow(
                                    text: persona.fewShotExamples[idx],
                                    prefix: "“", suffix: "”",
                                    onSave: { updated in persona.fewShotExamples[idx] = updated },
                                    onDelete: { persona.fewShotExamples.remove(at: idx) }
                                )
                            }
                        }
                    }
                }
                
                // 🧠 阶段三：私域专属记忆与 Ebbinghaus 算法
                assemblyStageCard(
                    stageBadge: "STAGE 3",
                    stageTitle: "Ebbinghaus 私域记忆矩阵",
                    stageSubtitle: "支持时间遗忘指数衰减、访问频次强化与参数化双轨召回",
                    themeColor: .cyan
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("📢 记忆唤醒引导词 (Recall Directive)").font(.system(size: 11, weight: .bold)).foregroundColor(.cyan)
                                Spacer()
                                Text("参数化提示词").font(.system(size: 10)).foregroundColor(.secondary)
                            }
                            TextField("如：【关于该用户的专属私域长期记忆 (基于当前语境动态唤醒)】:", text: $persona.memoryRecallDirective)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))
                        }
                        
                        Divider().opacity(0.4)
                        
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text("🛡️ 核心人设置顶 (≥9分)")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text("\(persona.coreAnchorRecallLimit) 条")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundColor(.purple)
                                    Stepper("", value: $persona.coreAnchorRecallLimit, in: 0...10)
                                        .labelsHidden()
                                        .controlSize(.small)
                                }
                            }
                            .padding(8)
                            .background(Color.purple.opacity(0.06))
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.purple.opacity(0.18), lineWidth: 1))
                            
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text("⚡️ 动态唤醒 (Top-K)")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text("\(persona.dynamicSemanticRecallLimit) 条")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundColor(.cyan)
                                    Stepper("", value: $persona.dynamicSemanticRecallLimit, in: 1...90)
                                        .labelsHidden()
                                        .controlSize(.small)
                                }
                            }
                            .padding(8)
                            .background(Color.cyan.opacity(0.06))
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.cyan.opacity(0.18), lineWidth: 1))
                            
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text("⏳ 遗忘半衰期")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text("\(Int(persona.halfLifeDays)) 天")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundColor(.green)
                                    Stepper("", value: $persona.halfLifeDays, in: 1...60, step: 1)
                                        .labelsHidden()
                                        .controlSize(.small)
                                }
                            }
                            .padding(8)
                            .background(Color.green.opacity(0.06))
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.green.opacity(0.18), lineWidth: 1))
                        }
                        
                        Divider().opacity(0.4)
                        
                        HStack {
                            Text("已沉淀 \(PersonaManager.shared.getMemories(for: persona.id).count) 条私域记忆").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if let msg = distillStatusMsg { Text(msg).font(.caption).foregroundColor(.green) }
                            Button(action: triggerMemoryDistillation) {
                                HStack(spacing: 4) {
                                    if isDistilling { ProgressView().controlSize(.small) }
                                    else { Image(systemName: "wand.and.stars") }
                                    Text("智能提炼当前会话")
                                }
                            }
                            .buttonStyle(.bordered)
                            .tint(.purple)
                            .disabled(isDistilling)
                        }
                        
                        HStack(spacing: 8) {
                            HStack {
                                Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.system(size: 11))
                                TextField("搜索记忆库...", text: $memorySearchText).textFieldStyle(.plain).font(.system(size: 11))
                                if !memorySearchText.isEmpty {
                                    Button { memorySearchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary).font(.system(size: 10)) }.buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(6)
                            
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 4) {
                                    ForEach(filterCategories, id: \.self) { cat in
                                        let isSel = selectedMemoryFilterCategory == cat
                                        Button { selectedMemoryFilterCategory = cat } label: {
                                            Text(cat)
                                                .font(.system(size: 10, weight: isSel ? .bold : .regular))
                                                .padding(.horizontal, 6).padding(.vertical, 3)
                                                .background(isSel ? Color.cyan.opacity(0.2) : Color.primary.opacity(0.04))
                                                .foregroundColor(isSel ? .cyan : .secondary)
                                                .cornerRadius(4)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        
                        HStack(spacing: 6) {
                            Picker("", selection: $newMemCategory) {
                                ForEach(categories, id: \.self) { Text($0).tag($0) }
                            }.frame(width: 90)
                            
                            TextField("手动录入原子记忆...", text: $newMemContent).textFieldStyle(.roundedBorder)
                            
                            Picker("", selection: $newMemImportance) {
                                ForEach(1...10, id: \.self) { Text("\($0)分").tag($0) }
                            }.frame(width: 65)
                            
                            Button("存入") {
                                PersonaManager.shared.addMemory(
                                    personaID: persona.id, content: newMemContent,
                                    category: newMemCategory, importance: newMemImportance
                                )
                                newMemContent = ""
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.cyan)
                            .disabled(newMemContent.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        
                        let memList = filteredMemories
                        if memList.isEmpty {
                            Text("当前分类暂无私域记忆").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.vertical, 4)
                        } else {
                            ForEach(memList) { item in
                                MemoryItemRowView(
                                    item: item,
                                    onEdit: { memoryToEdit = item },
                                    onDelete: { withAnimation { PersonaManager.shared.deleteMemory(id: item.id) } }
                                )
                            }
                        }
                    }
                }
                
                // 🌀 阶段四：动态情境、羁绊阶梯与战争迷雾
                assemblyStageCard(
                    stageBadge: "STAGE 4",
                    stageTitle: "动态情境、羁绊阶梯与迷雾",
                    stageSubtitle: "随剧情演进的情感阻尼、羁绊阶梯、时序事实与认知边界",
                    themeColor: .orange
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("即时心智参数").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("重置即时心智") { showResetStateAlert = true }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(.orange)
                        }
                        
                        PersonaLeftAlignedRow("羁绊阶梯") {
                            HStack(spacing: 8) {
                                Text(state.bondMilestone.rawValue)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.pink)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.pink.opacity(0.12))
                                    .cornerRadius(4)
                                
                                Slider(value: Binding(get: { Double(state.affinityScore) }, set: { state.affinityScore = Int($0) }), in: 0...100)
                                Text("\(state.affinityScore)分").font(.system(size: 12, weight: .bold, design: .monospaced)).frame(width: 40)
                            }
                        }
                        
                        PersonaLeftAlignedRow("实时情绪") {
                            TextField("如 表面从容，内心隐隐作痛", text: $state.currentEmotion).textFieldStyle(.roundedBorder)
                        }
                        
                        PersonaLeftAlignedRow("短期期待/动机") {
                            TextField("如 试探对方是否知晓当年的真相", text: $state.activeMotivation).textFieldStyle(.roundedBorder)
                        }
                        
                        Divider().opacity(0.4)
                        
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("✔ 已知事实时序清单 (按发生顺序推演)").font(.system(size: 11, weight: .bold)).foregroundStyle(.green)
                                Spacer()
                                Text("共 \(state.knownFacts.count) 条事实").font(.system(size: 10)).foregroundColor(.secondary)
                            }
                            HStack {
                                TextField("追加已知事实...", text: $newKnownFact).textFieldStyle(.roundedBorder)
                                Button("追加") {
                                    let clean = newKnownFact.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !clean.isEmpty && !state.knownFacts.contains(clean) {
                                        state.knownFacts.append(clean)
                                        newKnownFact = ""
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                            ForEach(state.knownFacts.indices, id: \.self) { idx in
                                EditableListRow(
                                    text: state.knownFacts[idx],
                                    prefix: "[#\(idx + 1)] ",
                                    onSave: { updated in state.knownFacts[idx] = updated },
                                    onDelete: { state.knownFacts.remove(at: idx) }
                                )
                            }
                        }
                        
                        Divider().opacity(0.4)
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("❓ 认知盲区 (严禁全知全能)").font(.system(size: 11, weight: .bold)).foregroundStyle(.orange)
                            HStack {
                                TextField("新增认知盲区...", text: $newBlindSpot).textFieldStyle(.roundedBorder)
                                Button("设为盲区") {
                                    if !newBlindSpot.isEmpty {
                                        state.blindSpots.append(newBlindSpot)
                                        newBlindSpot = ""
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                            ForEach(state.blindSpots.indices, id: \.self) { idx in
                                EditableListRow(
                                    text: state.blindSpots[idx],
                                    prefix: "❓ ",
                                    onSave: { updated in state.blindSpots[idx] = updated },
                                    onDelete: { state.blindSpots.remove(at: idx) }
                                )
                            }
                        }
                    }
                }
            }
            .padding(18)
        }
        .scrollContentBackground(.hidden)
        .forceOverlayScrollbars()
        .onChange(of: persona) { _, _ in onSave() }
        .sheet(item: $memoryToEdit) { item in
            EditMemorySheetView(item: item) { updated in
                PersonaManager.shared.updateMemory(updated)
                memoryToEdit = nil
            } onCancel: { memoryToEdit = nil }
        }
        .alert("重置即时心智状态？", isPresented: $showResetStateAlert) {
            Button("确认重置", role: .destructive) {
                withAnimation { PersonaManager.shared.resetRuntimeState(for: persona.id) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清空即时事实清单、认知盲区，并将羁绊度重置为默认 50 分。（不会影响私域记忆库）")
        }
    }
    
    @ViewBuilder
    private func assemblyStageCard<Content: View>(
        stageBadge: String,
        stageTitle: String,
        stageSubtitle: String,
        themeColor: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(stageBadge)
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundColor(themeColor)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(themeColor.opacity(0.12))
                    .cornerRadius(4)
                
                Text(stageTitle)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)
                
                Spacer()
                
                Text(stageSubtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.primary.opacity(0.02))
            
            Divider().opacity(0.5)
            
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(14)
        }
        .background(.ultraThinMaterial)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(themeColor.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.03), radius: 4, x: 0, y: 2)
    }
    
    private func triggerMemoryDistillation() {
        guard !isDistilling else { return }
        isDistilling = true
        distillStatusMsg = "正在提炼..."
        let msgs = AiChatStore.shared.messages
        Task {
            let res = await PersonaManager.shared.distillAndConsolidate(for: persona.id, recentMessages: msgs)
            isDistilling = false
            distillStatusMsg = res.message
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            distillStatusMsg = nil
        }
    }
}

// MARK: - ==================== 8. 辅助与内联组件 ====================

struct EditableListRow: View {
    let text: String
    var prefix: String = "• "
    var suffix: String = ""
    var onSave: (String) -> Void
    var onDelete: () -> Void
    
    @State private var isEditing = false
    @State private var draftText = ""
    @State private var isHovered = false
    
    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            if isEditing {
                TextField("", text: $draftText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit { commitEdit() }
                Button { commitEdit() } label: {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.system(size: 12))
                }.buttonStyle(.plain)
                Button { isEditing = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary).font(.system(size: 12))
                }.buttonStyle(.plain)
            } else {
                Text("\(prefix)\(text)\(suffix)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                if isHovered {
                    Button {
                        draftText = text
                        isEditing = true
                    } label: { Image(systemName: "pencil").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundColor(.blue.opacity(0.8))
                    
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash").font(.system(size: 10))
                    }
                    .buttonStyle(.plain).foregroundColor(.red.opacity(0.8))
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hover in isHovered = hover }
    }
    
    private func commitEdit() {
        let clean = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { onSave(clean) }
        isEditing = false
    }
}

struct MemoryItemRowView: View {
    let item: PersonaMemoryItem
    var onEdit: () -> Void
    var onDelete: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(item.category)
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color.cyan.opacity(0.12))
                .foregroundColor(.cyan)
                .cornerRadius(4)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(item.content)
                    .font(.system(size: 11))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                
                HStack(spacing: 8) {
                    Text("唤醒 \(item.accessCount) 次")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                    
                    Text("活跃于: \(formattedDate(item.lastAccessedAt))")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }
            
            Spacer()
            
            Text("\(item.importance)分")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary)
            
            if isHovered {
                Button(action: onEdit) { Image(systemName: "square.and.pencil").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundColor(.blue.opacity(0.85))
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundColor(.red.opacity(0.8))
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
    
    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

struct EditMemorySheetView: View {
    @State var item: PersonaMemoryItem
    var onSave: (PersonaMemoryItem) -> Void
    var onCancel: () -> Void
    private let categories = ["用户画像", "生活偏好", "彼此约定", "情感羁绊", "重要背景"]
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("编辑私域记忆条目").font(.headline)
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
            }
            .padding(14).background(.thinMaterial); Divider()
            
            VStack(alignment: .leading, spacing: 14) {
                PersonaLeftAlignedRow("分类") {
                    Picker("", selection: $item.category) {
                        ForEach(categories, id: \.self) { Text($0).tag($0) }
                    }.frame(width: 140)
                }
                PersonaLeftAlignedRow("重要度") {
                    HStack {
                        Slider(value: Binding(get: { Double(item.importance) }, set: { item.importance = Int($0) }), in: 1...10)
                        Text("\(item.importance) 分").font(.system(size: 12, weight: .bold, design: .monospaced)).frame(width: 40)
                    }
                }
                PersonaLeftAlignedRow("记忆内容", alignment: .top) {
                    TextEditor(text: $item.content)
                        .frame(height: 80)
                        .font(.system(size: 12))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor), lineWidth: 1))
                }
            }
            .padding(18); Divider()
            
            HStack {
                Spacer()
                Button("保存修改") { onSave(item) }
                    .buttonStyle(.borderedProminent).tint(.purple).keyboardShortcut(.defaultAction)
            }
            .padding(14).background(.thinMaterial)
        }
        .frame(width: 440, height: 280)
    }
}

struct PersonaLeftAlignedRow<Content: View>: View {
    let title: String
    let alignment: VerticalAlignment
    let content: Content
    
    init(_ title: String, alignment: VerticalAlignment = .firstTextBaseline, @ViewBuilder content: () -> Content) {
        self.title = title; self.alignment = alignment; self.content = content()
    }
    
    var body: some View {
        HStack(alignment: alignment, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 75, alignment: .leading)
                .foregroundStyle(.secondary)
            content
        }
    }
}
