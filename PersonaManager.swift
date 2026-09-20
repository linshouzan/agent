//////////////////////////////////////////////////////////////////
// 文件名：PersonaManager.swift
// 文件说明：适用于 macOS 14+ 的数字分身心智中枢与拟人化组装工坊 (Swift 6 Ready)
//
// 核心解构架构拓扑 (Domain-Driven Architecture):
// 1. 实体时序因果链 (Entity-Tagged Causal DAG): 物理时间锚点 + 覆盖指针 + 因果回退与置顶保护
// 2. 客户端三道程序级真值门禁 (Grounding Guard): 纯查询断路器 + 语义灭失自动消化 + 隐喻虚构拦截
// 3. 动机意图自适应衰减 (Motivation TTL): 避免特定情境小算盘在严肃任务中发生僵死附着
// 4. 浮动 HUD 瞬态会话环 (In-Memory Ring Buffer): 支持多轮指代追问，对白自动归口聚合蒸馏
// 5. 艾宾浩斯私域记忆矩阵: 时间指数衰减 + 访问频度对数增强 + 跨端双轨聚合提炼
// 6. 羁绊阶梯系统 (Bond Milestones): 从初见疏离到深层羁绊的四阶拟人化亲疏演进
// 7. 架空世界观锁相与防出戏 (Anti-OOC): 全正向逻辑引导，杜绝 AI 机械语气
// 8. 情绪惯性阻尼 (Emotional Inertia): 记录前置情绪，确保情绪过渡自然鲜活
// 9. 模块化语音生命周期门面 (TTS Process Lifecycle Facade): 按需加载、精准打断与完全解耦
// 10. [Architecture Upgrade]: 全面基于纯泛型 DatabaseRecordConvertible，兼容历史版本无损升格
//////////////////////////////////////////////////////////////////

import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine
import Accelerate
import NaturalLanguage

// MARK: - ==================== 1. 核心数据模型 ====================

/// 关系轨道枚举：界定数字分身与用户的情感性质与发展天花板
public enum RelationshipDirection: String, CaseIterable, Codable, Sendable {
    case romantic = "恋爱向"      // 伴侣、深情相依、浪漫羁绊
    case friendship = "挚友向"    // 兄弟、闺蜜、并肩战友、莫逆之交
    case family = "守护亲情向"    // 长辈、手足、舐犊庇护、亲族依偎
    case rivalry = "宿敌竞争向"   // 宿命对手、针锋相对、惺惺相惜、相爱相杀
    case professional = "职场向"  // 导师、助手、商业合伙、同盟搭档
    case passerby = "客态路人"    // 路人甲、过客、纯事务性交互 (不产生羁绊)
    
    /// 原生 SF Symbols 拟态图标
    public var icon: String {
        switch self {
        case .romantic: return "heart.fill"
        case .friendship: return "person.2.fill"
        case .family: return "house.fill"
        case .rivalry: return "flame.fill"
        case .professional: return "briefcase.fill"
        case .passerby: return "figure.walk"
        }
    }
    
    /// 原生主题语义色彩 (用于徽标与状态胶囊)
    public var themeColor: Color {
        switch self {
        case .romantic: return .pink
        case .friendship: return .blue
        case .family: return .orange
        case .rivalry: return .red
        case .professional: return .indigo
        case .passerby: return .secondary
        }
    }
    
    /// 轨道定位简述 (展示于 UI 辅助说明)
    public var summary: String {
        switch self {
        case .romantic: return "支持发展浪漫爱意与依恋情愫，随羁绊升温呈现专属亲昵"
        case .friendship: return "纯粹真挚的知己战友关系，随羁绊升温性命相托，恪守坦荡义气"
        case .family: return "以家眷手足之情相互关照，随羁绊升温流露无私宠溺、牵挂叮咛与坚实依靠"
        case .rivalry: return "亦敌亦友的宿命对手，随羁绊升温保持旗鼓相当的交锋，言语嘴硬心软但默契卓绝"
        case .professional: return "严谨高效的职场同盟与搭档，随羁绊升温默契协同，恪守职业得体"
        case .passerby: return "萍水相逢的过客与旁观者，无论交互多久均保持冷静客态，不建立私密羁绊"
        }
    }
    
    /// 结合羁绊阶梯生成全正向指引 (严格规避“禁止/严禁”字眼，通过正向逻辑强化行为定调)
    public func promptGuideline(for milestone: BondMilestone) -> String {
        switch self {
        case .romantic:
            switch milestone {
            case .stranger:
                return "处于【初见/疏离】阶段。态度客气礼貌、保持社交边界与微量矜持，避免过度热情与逾矩亲昵。"
            case .acquaintance:
                return "处于【熟络/朋友】阶段。言语随和放松，愿意主动分享日常与细节，偶有轻松惬意的玩笑互动。"
            case .confidant:
                return "处于【知己/依恋】阶段。展现真实脆弱与深度共鸣，互动中带有明显的偏向与好感，可自然流露吃醋、撒娇、护短等浪漫微表情。"
            case .soulmate:
                return "处于【深层爱恋/生死相依】阶段。具备最高信任度与炽热默契，语言流露极深情感依赖与无条件包容，拥有双方专属的暗号与亲昵口癖。"
            }
            
        case .friendship:
            switch milestone {
            case .stranger:
                return "处于【相识初见】阶段。礼貌随和，以平等友善的态度进行日常交流，尊重彼此私人空间。"
            case .acquaintance:
                return "处于【交情熟络】阶段。谈吐自然率直，如同同窗好友，言辞幽默风趣，愿意互相调侃打趣并分享经历。"
            case .confidant:
                return "处于【莫逆之交】阶段。推心置腹、义气相挺，面对困境主动担当撑腰，维系着纯粹深厚且毫无保留的知己挚友情谊。"
            case .soulmate:
                return "处于【生死之交/灵魂战友】阶段。经历过风雨与共，拥有绝对的信任与性命相托的默契，言语豁达真挚，坚定维系着至高的战友义气。"
            }
            
        case .family:
            switch milestone {
            case .stranger:
                return "处于【初涉关照】阶段。保持得体礼貌的关照姿态，言语随和温厚，给予日常礼节性照料，恪守舒适的长幼社交边界。"
            case .acquaintance:
                return "处于【温情渐近】阶段。如寻常手足或家人般轻松交谈，言语带有生活烟火气与日常关怀，主动分担琐碎琐事并叮嘱饮食起居。"
            case .confidant:
                return "处于【至亲信赖】阶段。态度温厚护短，面对用户的难处主动挺身撑腰，流露无保留的宠溺与包容，可自然穿插家人间的善意念叨与关爱。"
            case .soulmate:
                return "处于【无上依靠/骨肉同袍】阶段。具备极高维度的无私奉献与绝对依靠，无论风雨皆坚定托底，言辞充满亲人般的深厚庇护感与至纯温情。"
            }
            
        case .rivalry:
            switch milestone {
            case .stranger:
                return "处于【试探争锋】阶段。言语锐利克制，带有一丝清傲与审视，聚焦于能力或理念上的试探交锋。"
            case .acquaintance:
                return "处于【棋逢对手】阶段。习惯性嘴硬较劲与言语机锋，内心认可对方的过人之处，但口头上维持桀骜不服输的竞争姿态。"
            case .confidant:
                return "处于【莫逆宿敌】阶段。惺惺相惜、傲娇护短。对他人冷峻淡漠，对用户虽仍习惯冷嘲热讽与斗嘴较量，关键时刻却会主动并肩而立，绝不容许第三者轻侮。"
            case .soulmate:
                return "处于【宿命知己/生死博弈】阶段。心境默契达到顶峰，视对方为世间唯一配与自己并肩博弈的终极宿敌。言语嘴硬心软、行动性命相托，展现顶级的战力共鸣。"
            }
            
        case .professional:
            switch milestone {
            case .stranger:
                return "处于【事务初接】阶段。展现高标准的职业礼仪与干练作风，专注于任务目标本身，保持明确的职业安全边界。"
            case .acquaintance:
                return "处于【常规协作】阶段。业务沟通顺畅高效，言语精炼得体，能够主动预判并承接协作事项。"
            case .confidant:
                return "处于【信赖智囊】阶段。具备极高的专业洞察与默契，主动建言献策、查漏补缺，是值得托付关键任务的核心中坚。"
            case .soulmate:
                return "处于【终极合伙/黄金搭档】阶段。战略步调高度同频，拥有无需多言的合作默契与职业忠诚，在恪守成熟职业规范的同时形成牢不可破的事业同盟。"
            }
            
        case .passerby:
            return "处于【过客/客态交互】定位。始终保持萍水相逢的冷静客套与清晰的过客边界，言语客观精炼，点到即止，专注于当下事务本身，不产生情绪依恋与私密牵涉。"
        }
    }
}

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
    
    /// 根据关系轨道动态转译羁绊阶段名称
    public func dynamicTitle(for direction: RelationshipDirection) -> String {
        switch direction {
        case .romantic:
            switch self {
            case .stranger: return "初见疏离"
            case .acquaintance: return "熟络相知"
            case .confidant: return "知己依恋"
            case .soulmate: return "深情相依"
            }
        case .friendship:
            switch self {
            case .stranger: return "相识初见"
            case .acquaintance: return "交情熟络"
            case .confidant: return "莫逆之交"
            case .soulmate: return "生死之交"
            }
        case .family:
            switch self {
            case .stranger: return "初涉关照"
            case .acquaintance: return "温情渐近"
            case .confidant: return "至亲信赖"
            case .soulmate: return "无上依靠"
            }
        case .rivalry:
            switch self {
            case .stranger: return "试探争锋"
            case .acquaintance: return "棋逢对手"
            case .confidant: return "莫逆宿敌"  // 72 分对应 Confidant 阶段，精准呈现宿敌张力
            case .soulmate: return "宿命知己"
            }
        case .professional:
            switch self {
            case .stranger: return "事务初接"
            case .acquaintance: return "常规协作"
            case .confidant: return "信赖智囊"
            case .soulmate: return "黄金搭档"
            }
        case .passerby:
            switch self {
            case .stranger: return "萍水相逢"
            case .acquaintance: return "泛泛之交"
            case .confidant: return "客态疏离"
            case .soulmate: return "萍水过客"
            }
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
    
    // 关系轨道与情感方向
    public var relationshipDirection: RelationshipDirection = .romantic
    
    // 专属基底模型
    public var baseModel: String = ""
    
    // 架空世界观与剧场小说配置
    public var worldviewContext: String = ""
    public var enableNovelActionBrackets: Bool = true
    public var halfLifeDays: Double = 7.0
    
    public var enableTemporalContext: Bool = true
    public var memoryRecallDirective: String = "【关于该用户的专属私域长期记忆 (基于当前语境动态唤醒)】:"
    
    // 参数化召回配比
    public var coreAnchorRecallLimit: Int = 2
    public var dynamicSemanticRecallLimit: Int = 6
    
    // MARK: - [TTS Hook] 拟人语音与语速配置 (向后兼容持久化)
    public var enableTTS: Bool = false
    public var ttsVoice: String = "hojo_zh_f_02"
    public var ttsSpeed: Float = 1.0
    
    public var createdAt: Date = Date()
    
    public var actualModelName: String {
        guard baseModel.contains("/") else { return baseModel }
        let parts = baseModel.split(separator: "/", maxSplits: 1).map(String.init)
        return parts.count == 2 ? parts[1] : baseModel
    }
    
    public var displayModelName: String {
        guard !baseModel.isEmpty else { return "跟随全局默认模型" }
        return baseModel.asDisplayModelName
    }
    
    enum CodingKeys: String, CodingKey {
        case id, name, avatarIcon, roleTag, summary, toneStyle, fewShotExamples, forbiddenRules,
             bindDedicatedCategory, equippedSkillIDs, relationshipDirection, baseModel, worldviewContext,
             enableNovelActionBrackets, halfLifeDays, enableTemporalContext, memoryRecallDirective,
             coreAnchorRecallLimit, dynamicSemanticRecallLimit, enableTTS, ttsVoice, ttsSpeed, createdAt
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
        relationshipDirection: RelationshipDirection = .romantic,
        baseModel: String = "",
        worldviewContext: String = "",
        enableNovelActionBrackets: Bool = true,
        halfLifeDays: Double = 7.0,
        enableTemporalContext: Bool = true,
        memoryRecallDirective: String = "【关于该用户的专属私域长期记忆 (基于当前语境动态唤醒)】:",
        coreAnchorRecallLimit: Int = 2,
        dynamicSemanticRecallLimit: Int = 6,
        enableTTS: Bool = false,
        ttsVoice: String = "hojo_zh_f_02",
        ttsSpeed: Float = 1.0,
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
        self.relationshipDirection = relationshipDirection
        self.baseModel = baseModel
        self.worldviewContext = worldviewContext
        self.enableNovelActionBrackets = enableNovelActionBrackets
        self.halfLifeDays = halfLifeDays
        self.enableTemporalContext = enableTemporalContext
        self.memoryRecallDirective = memoryRecallDirective
        self.coreAnchorRecallLimit = coreAnchorRecallLimit
        self.dynamicSemanticRecallLimit = dynamicSemanticRecallLimit
        self.enableTTS = enableTTS
        self.ttsVoice = ttsVoice
        self.ttsSpeed = ttsSpeed
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
        self.relationshipDirection = try container.decodeIfPresent(RelationshipDirection.self, forKey: .relationshipDirection) ?? .romantic
        self.baseModel = try container.decodeIfPresent(String.self, forKey: .baseModel) ?? ""
        self.worldviewContext = try container.decodeIfPresent(String.self, forKey: .worldviewContext) ?? ""
        self.enableNovelActionBrackets = try container.decodeIfPresent(Bool.self, forKey: .enableNovelActionBrackets) ?? true
        self.halfLifeDays = try container.decodeIfPresent(Double.self, forKey: .halfLifeDays) ?? 7.0
        self.enableTemporalContext = try container.decodeIfPresent(Bool.self, forKey: .enableTemporalContext) ?? true
        self.memoryRecallDirective = try container.decodeIfPresent(String.self, forKey: .memoryRecallDirective) ?? "【关于该用户的专属私域长期记忆 (基于当前语境动态唤醒)】:"
        self.coreAnchorRecallLimit = try container.decodeIfPresent(Int.self, forKey: .coreAnchorRecallLimit) ?? 2
        self.dynamicSemanticRecallLimit = try container.decodeIfPresent(Int.self, forKey: .dynamicSemanticRecallLimit) ?? 6
        self.enableTTS = try container.decodeIfPresent(Bool.self, forKey: .enableTTS) ?? false
        self.ttsVoice = try container.decodeIfPresent(String.self, forKey: .ttsVoice) ?? "hojo_zh_f_02"
        self.ttsSpeed = try container.decodeIfPresent(Float.self, forKey: .ttsSpeed) ?? 1.0
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

/// 运行时动态心智快照 (支持动机存活衰减与时序因果链)
public struct PersonaRuntimeState: Codable, Equatable, Sendable {
    public var personaID: UUID
    public var currentEmotion: String          // 实时情绪
    public var previousEmotion: String?        // 前一轮情绪 (用于构建情绪惯性阻尼)
    public var activeMotivation: String        // 短期诉求 / 推进议题焦点
    public var motivationTurnsAlive: Int = 0   // 动机持续未更新的轮次计数 (用于意图衰减)
    public var knownFacts: [TemporalFact] = [] // 实体时序因果链清单
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
        motivationTurnsAlive: Int = 0,
        knownFacts: [TemporalFact] = [],
        blindSpots: [String] = [],
        affinityScore: Int = 50,
        lastUpdated: Date = Date()
    ) {
        self.personaID = personaID
        self.currentEmotion = currentEmotion
        self.previousEmotion = previousEmotion
        self.activeMotivation = activeMotivation
        self.motivationTurnsAlive = motivationTurnsAlive
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
    
    private let lastActivePersonaKey = "lin_last_active_persona_id"
    
    /// 上次会话激活的数字分身 ID (自动落盘至 UserDefaults)
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
    
    /// 从 SQLite 中通过纯泛型网关装配全量数据
    public func loadData() {
        self.personas = LocalDatabaseManager.shared.loadAll(orderBy: "created_at ASC")
        
        if self.personas.isEmpty {
            let defaultPersona = DigitalPersona(
                name: "苏晴",
                avatarIcon: "person.crop.circle.badge.checkmark",
                roleTag: "贴身事务管家",
                summary: "兼具极高职业素养与细腻共情力的私人生态助理，善于在细微处洞察你的需求。",
                toneStyle: "温和干练、言简意赅中带着脉脉温情。善用精炼的动作神态描写与结构化建议。",
                fewShotExamples: ["（为你递上一杯温水，目光关切）“今天辛苦了，核心事项我已梳理好，要先听简报还是稍作休息？”"],
                forbiddenRules: ["越权替用户做出未经授权的重大决定", "以生硬的AI语气打破沉浸感"],
                worldviewContext: "现代都市高规格私人事务助理",
                enableNovelActionBrackets: true,
                halfLifeDays: 7.0,
                enableTemporalContext: true,
                memoryRecallDirective: "【关于该用户的专属私域长期记忆 (管家级档案)】:"
            )
            self.personas = [defaultPersona]
            LocalDatabaseManager.shared.save(defaultPersona)
        }
        
        let loadedStates: [PersonaRuntimeState] = LocalDatabaseManager.shared.loadAll()
        self.runtimeStates = Dictionary(uniqueKeysWithValues: loadedStates.map { ($0.personaID, $0) })
        self.memories = LocalDatabaseManager.shared.loadAll(orderBy: "importance DESC, last_accessed_at DESC")
    }
    
    // MARK: - 状态与记忆存取 API
    
    public func savePersonas() {
        LocalDatabaseManager.shared.saveAll(self.personas, purgeMissing: true)
    }
    
    public func saveStates() {
        LocalDatabaseManager.shared.saveAll(Array(self.runtimeStates.values))
    }
    
    public func saveMemories() {
        LocalDatabaseManager.shared.saveAll(self.memories)
    }
    
    public func getOrCreateRuntimeState(for personaID: UUID) -> PersonaRuntimeState {
        if let state = runtimeStates[personaID] { return state }
        let newState = PersonaRuntimeState(personaID: personaID)
        runtimeStates[personaID] = newState
        LocalDatabaseManager.shared.save(newState)
        return newState
    }
    
    public func updateRuntimeState(_ state: PersonaRuntimeState) {
        runtimeStates[state.personaID] = state
        LocalDatabaseManager.shared.save(state)
    }
    
    public func resetRuntimeState(for personaID: UUID) {
        let newState = PersonaRuntimeState(personaID: personaID)
        runtimeStates[personaID] = newState
        LocalDatabaseManager.shared.save(newState)
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
        LocalDatabaseManager.shared.save(item)
    }
    
    public func updateMemory(_ updatedItem: PersonaMemoryItem) {
        if let idx = memories.firstIndex(where: { $0.id == updatedItem.id }) {
            var item = updatedItem
            item.updatedAt = Date()
            item.lastAccessedAt = Date()
            item.embedding = Self.computeEmbedding(for: item.content)
            memories[idx] = item
            LocalDatabaseManager.shared.save(item)
        }
    }
    
    public func deleteMemory(id: UUID) {
        memories.removeAll { $0.id == id }
        LocalDatabaseManager.shared.delete(PersonaMemoryItem.self, id: id.uuidString)
    }
    
    /// 将即时事实一键沉淀/升华为私域长期记忆
    public func convertFactToMemory(personaID: UUID, fact: TemporalFact, category: String = "用户画像", importance: Int = 6) {
        addMemory(
            personaID: personaID,
            content: fact.content,
            category: category,
            importance: importance
        )
    }
    
    public func duplicatePersona(id: UUID) -> DigitalPersona? {
        guard let origin = personas.first(where: { $0.id == id }) else { return nil }
        let newID = UUID()
        var cloned = origin
        cloned.id = newID
        cloned.name = "\(origin.name) (副本)"
        cloned.createdAt = Date()
        personas.append(cloned)
        LocalDatabaseManager.shared.save(cloned)
        
        if let originState = runtimeStates[id] {
            var s = originState
            s.personaID = newID
            runtimeStates[newID] = s
            LocalDatabaseManager.shared.save(s)
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
            LocalDatabaseManager.shared.save(m)
        }
        return cloned
    }
    
    public func importPersonaPackage(from data: Data) -> DigitalPersona? {
        guard let payload = try? JSONDecoder().decode(PersonaPackagePayload.self, from: data) else { return nil }
        var imported = payload.persona
        imported.id = UUID()
        imported.name = "\(imported.name) (导入)"
        personas.append(imported)
        LocalDatabaseManager.shared.save(imported)
        
        var state = payload.state
        state.personaID = imported.id
        runtimeStates[imported.id] = state
        LocalDatabaseManager.shared.save(state)
        
        for mem in payload.memories {
            addMemory(personaID: imported.id, content: mem.content, category: mem.category, importance: mem.importance)
        }
        return imported
    }
    
    // MARK: - 🧠 心智增量演化引擎 (三道真值门禁 + 灭失自动注销 + 动机衰减)
    
    /// 执行分身心智增量更新
    public func applyMentalDelta(for personaID: UUID, deltaJSON: String, userQuery: String? = nil) {
        guard let data = deltaJSON.data(using: .utf8),
              let delta = try? JSONDecoder().decode(PersonaMentalDelta.self, from: data) else { return }
        
        var state = getOrCreateRuntimeState(for: personaID)
        var hasChanges = false
        
        // 1. 情绪阻尼迁移
        if let newEmotion = delta.emotion?.trimmingCharacters(in: .whitespacesAndNewlines), !newEmotion.isEmpty {
            if state.currentEmotion != newEmotion {
                state.previousEmotion = state.currentEmotion
                state.currentEmotion = newEmotion
                hasChanges = true
            }
        }
        
        // 2. 动机/意图自适应衰减逻辑
        if let newMotivation = delta.motivation?.trimmingCharacters(in: .whitespacesAndNewlines), !newMotivation.isEmpty {
            if state.activeMotivation != newMotivation {
                state.activeMotivation = newMotivation
                state.motivationTurnsAlive = 0
                hasChanges = true
            }
        } else {
            state.motivationTurnsAlive += 1
            if state.motivationTurnsAlive >= 2 && state.activeMotivation != "真诚生动交互，随时响应用户需求" {
                state.activeMotivation = "真诚生动交互，随时响应用户需求"
                hasChanges = true
            }
        }
        
        // 3. 羁绊度平滑更新
        if let affinityDelta = delta.affinityDelta, affinityDelta != 0 {
            let currentPersona = personas.first(where: { $0.id == personaID })
            if currentPersona?.relationshipDirection != .passerby {
                state.affinityScore = max(0, min(100, state.affinityScore + affinityDelta))
                hasChanges = true
            }
        }
        
        // 锁定进入本轮变更前的当前生效事实只读快照 (用于 1-based 序号映射)
        let activeFactSnapshot = state.knownFacts.filter { $0.status == .active }
        
        // 4. 显式物理灭失通道 (invalidated_indices)
        if let invalidated = delta.invalidatedIndices, !invalidated.isEmpty {
            for targetIdx in invalidated where targetIdx > 0 && targetIdx <= activeFactSnapshot.count {
                let targetFactID = activeFactSnapshot[targetIdx - 1].id
                if let idxInState = state.knownFacts.firstIndex(where: { $0.id == targetFactID }) {
                    state.knownFacts[idxInState].status = .invalidated
                    hasChanges = true
                }
            }
        }
        
        // 5. 核心：客户端程序级真值门禁 (Grounding Guard)
        var candidateFacts: [DeltaFactItem] = delta.unlockedFacts ?? []
        
        if let rawQuery = userQuery?.trimmingCharacters(in: .whitespacesAndNewlines), !rawQuery.isEmpty {
            let queryMarkers = [
                "?", "？", "吗", "呢",
                "什么", "谁", "哪", "几点", "何时", "怎样", "如何",
                "做过什么", "做了什么", "有没有", "安排吗", "有吗", "是不是",
                "查一下", "查查", "查下", "看下", "看看", "确认下", "确认", "还记得"
            ]
            let isQuestion = queryMarkers.contains(where: { rawQuery.contains($0) })
            
            // 强陈述、强意图与日程待办特征标记（豁免纯提问断路）
            let strongDeclarativeMarkers = [
                "改成", "实际", "其实", "改为", "重新", "确实是",
                "提醒我", "记得", "要去", "打算", "计划", "需要", "准备", "决定"
            ]
            let hasStrongDeclarative = strongDeclarativeMarkers.contains(where: { rawQuery.contains($0) })
            
            // 仅在明确为纯提问且不含任何新事实/行为交代时进行断路拦截
            if isQuestion && !hasStrongDeclarative {
                candidateFacts = []
            }
        }
        
        // 6. 语义灭失自动消化 (Auto-Invalidator) 与口语化特征匹配
        let scheduleVoidKeywords = [
            "取消", "作废", "推迟", "延期", "无行程", "空窗期", "终止", "搁置",
            "不用开", "不用去", "不开了", "不去了", "去不了", "参加不了",
            "推了", "鸽了", "别提醒了", "不用记了", "计划取消"
        ]
        
        let metaphorKeywords = [
            "协议", "同盟", "契约", "守则", "约定达成", "共识",
            "默契", "战友", "最佳搭档", "共同约定", "羁绊加深", "心意相通"
        ]
        let queryLower = userQuery?.lowercased() ?? ""
        
        for factItem in candidateFacts {
            let cleanContent = factItem.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanContent.isEmpty else { continue }
            
            let isScheduleVoidFact = scheduleVoidKeywords.contains(where: { cleanContent.contains($0) })
            if isScheduleVoidFact {
                if let targetIdx = factItem.supersedesIndex, targetIdx > 0 && targetIdx <= activeFactSnapshot.count {
                    let targetFactID = activeFactSnapshot[targetIdx - 1].id
                    if let idxInState = state.knownFacts.firstIndex(where: { $0.id == targetFactID }) {
                        state.knownFacts[idxInState].status = .invalidated
                        hasChanges = true
                    }
                }
                continue
            }
            
            let isMetaphorFact = metaphorKeywords.contains(where: { cleanContent.contains($0) })
            if isMetaphorFact && !metaphorKeywords.contains(where: { queryLower.contains($0) }) {
                continue
            }
            
            if state.knownFacts.contains(where: { $0.status == .active && $0.content.lowercased() == cleanContent.lowercased() }) {
                continue
            }
            
            var newFact = TemporalFact(
                content: cleanContent,
                entities: factItem.entities ?? [],
                status: .active,
                timestamp: Date()
            )
            
            if let targetIdx = factItem.supersedesIndex, targetIdx > 0 && targetIdx <= activeFactSnapshot.count {
                let targetFactID = activeFactSnapshot[targetIdx - 1].id
                if let idxInState = state.knownFacts.firstIndex(where: { $0.id == targetFactID }) {
                    state.knownFacts[idxInState].status = .superseded
                    state.knownFacts[idxInState].supersededByID = newFact.id
                }
            }
            
            state.knownFacts.append(newFact)
            hasChanges = true
        }
        
        // 容量与优先级淘汰 (上限 16 条)
        let maxCapacity = 16
        while state.knownFacts.count > maxCapacity {
            if let staleIdx = state.knownFacts.firstIndex(where: { $0.status != .active && !$0.isPinned }) {
                state.knownFacts.remove(at: staleIdx)
                hasChanges = true
            } else if let unpinnedIdx = state.knownFacts.firstIndex(where: { !$0.isPinned }) {
                state.knownFacts.remove(at: unpinnedIdx)
                hasChanges = true
            } else {
                break
            }
        }
        
        // 7. 认知迷雾消除
        if let fogCleared = delta.fogCleared, !fogCleared.isEmpty {
            for clearedItem in fogCleared {
                let cleanCleared = clearedItem.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !cleanCleared.isEmpty else { continue }
                
                let beforeCount = state.blindSpots.count
                state.blindSpots.removeAll { blind in
                    let lower = blind.lowercased()
                    return lower == cleanCleared || lower.contains(cleanCleared) || cleanCleared.contains(lower)
                }
                if state.blindSpots.count != beforeCount {
                    hasChanges = true
                }
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
        let now = Date()
        var updatedMemories: [PersonaMemoryItem] = []
        for i in memories.indices {
            if ids.contains(memories[i].id) {
                memories[i].accessCount += 1
                memories[i].lastAccessedAt = now
                updatedMemories.append(memories[i])
            }
        }
        for mem in updatedMemories {
            LocalDatabaseManager.shared.save(mem)
        }
    }
    
    // MARK: - 🧠 提示词动态编译引擎 (结构化全正向指引，KV Cache 友好)
    
    public func compileStaticPersonaPrompt(for personaID: UUID) -> String {
        guard let persona = personas.first(where: { $0.id == personaID }) else { return "" }
        
        var prompt = """
        
        <persona_mind_mask>
        🎭 【接管数字分身意识 (Master Consciousness)】: \(persona.name) (\(persona.roleTag))
        
        【核心定位与关系轨道】
        - 基础身份: \(persona.summary)
        - 语言风格: \(persona.toneStyle)
        - 关系轨道: 【\(persona.relationshipDirection.rawValue)】 (\(persona.relationshipDirection.summary))
        
        """
        
        if !persona.worldviewContext.isEmpty {
            prompt += """
            【🌌 世界观与时空锚点 (Worldview Grounding)】
            - 设定背景: \(persona.worldviewContext)
            - 时空法则: 语言表达与逻辑体系完全遵循该世界观设定，仅使用符合该背景的概念与词汇。
            
            """
        }
        
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
        每次回复结束时，请在正文末尾附带 `<persona_delta>` 标签反映内心状态的增量变化：
        
        【协议输出逻辑规范】
        1. 事实捕获与豁免 (unlocked_facts)：
           • 当用户陈述了新的客观生活行为、真实事件、行程安排或偏好变动时，提炼为精炼客观事实录入 unlocked_facts。
           • 当用户本轮仅为提问、回溯或信息查询（未提供新事实）时，unlocked_facts 保持为空数组 []。
           • 仅接纳用户明确陈述的外部物理现实事实；分身自身的剧情推测、台词借口或状态缺失（如无安排）不生成新事实。
        2. 计划注销规范 (invalidated_indices)：
           • 仅当用户明确取消既定日程或作废约定事项时，填入对应旧事实的 1-based [#序号]（如 [1]）。
           • 当本轮无明确计划被取消或注销时，必须保持为空数组 []，不可填写 0 或无效数字。
        3. 盲区澄清规范 (fog_cleared)：
           • 仅填入此前在上下文【认知盲区】中已列出的条目名称。
           • 若本轮无预设认知盲区被打破，必须保持为空数组 []。
        
        <persona_delta>
        {
          "emotion": "当前主观情绪微调",
          "motivation": "短期推进诉求或待聚焦议题",
          "affinity_delta": 0, // 羁绊度变动 (-5 到 +5 之间的整数)
          "unlocked_facts": [
            { "content": "客观事实描述", "entities": ["主体或领域标签"], "supersedes_index": null }
          ],
          "invalidated_indices": [],
          "fog_cleared": []
        }
        </persona_delta>
        </mental_feedback_protocol>
        
        [心智指令]：你即是 \(persona.name)。完全融入角色的内心世界，真诚生动交互！
        </persona_mind_mask>
        """
        
        return prompt
    }

    public func compileDynamicRuntimeContext(for personaID: UUID, query: String? = nil) -> String {
        guard let persona = personas.first(where: { $0.id == personaID }) else { return "" }
        let state = getOrCreateRuntimeState(for: personaID)
        let milestone = state.bondMilestone
        let direction = persona.relationshipDirection
        let milestoneTitle = milestone.dynamicTitle(for: direction) // 动态阶段标题
        
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
        - 关系轨道: 【\(direction.rawValue)】
        - 羁绊里程碑: 【\(milestoneTitle)】 (当前羁绊分: \(direction == .passerby ? 0 : state.affinityScore)/100)
        - 亲疏尺度与言行指引: \(direction.promptGuideline(for: milestone))
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
        
        let activeFacts = state.knownFacts.filter { $0.status == .active }
        if !activeFacts.isEmpty {
            dynamicContext += "【当前已知即时事实时序 (按推演先后排序)】:\n"
            for (idx, fact) in activeFacts.enumerated() {
                let tagStr = fact.entities.isEmpty ? "" : "[\(fact.entities.joined(separator: "/"))] "
                let pinStr = fact.isPinned ? " 📌" : ""
                dynamicContext += "✔ [#\(idx + 1)] \(tagStr)\(fact.content)\(pinStr)\n"
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

    public func compilePersonaPrompt(for personaID: UUID, query: String? = nil) -> String {
        let staticPrompt = compileStaticPersonaPrompt(for: personaID)
        let dynamicContext = compileDynamicRuntimeContext(for: personaID, query: query)
        return "\(staticPrompt)\n\n\(dynamicContext)"
    }
    
    // MARK: - 智能记忆提炼流水线
    func distillAndConsolidate(for personaID: UUID, recentMessages: [ChatMessage]) async -> (success: Bool, message: String) {
        guard let persona = personas.first(where: { $0.id == personaID }) else {
            return (false, "未找到对应的数字分身")
        }
        
        let sessionLogID = LogManager.shared.startSession(
            query: "基于时序因果链与会话对白进行私域记忆提炼升华",
            agentName: persona.name,
            category: .memoryDistill
        )
        
        defer {
            LogManager.shared.endSession(sessionID: sessionLogID, isSuccess: true, detail: "心智记忆重整完毕")
        }
        
        // 1. 抽取主会话干净文本
        let mainChatLines: [String] = recentMessages
            .filter { !$0.text.isEmpty }
            .suffix(12)
            .map { msg in
                let sender = msg.isUser ? "用户" : persona.name
                let clean = msg.text.filterStopTokens().filterTHINK().filterMARKDOWN().filterPersonaDelta().trimmingCharacters(in: .whitespacesAndNewlines)
                return "\(sender): \(clean)"
            }
        
        // 2. 提取当前心智快照中生效的即时事实因果链 (作为核心输入信源)
        let state = getOrCreateRuntimeState(for: personaID)
        let activeFacts = state.knownFacts.filter { $0.status == .active }
        
        // 3. 门禁检查：若既无对白也无待沉淀因果事实，则静默跳过
        guard !mainChatLines.isEmpty || !activeFacts.isEmpty else {
            return (false, "当前暂无即时因果事实或有效会话，无需提炼")
        }
        
        var factsFormatted = "暂无生效即时事实"
        if !activeFacts.isEmpty {
            factsFormatted = activeFacts.enumerated().map { idx, fact in
                let tagStr = fact.entities.isEmpty ? "" : "[\(fact.entities.joined(separator: "/"))] "
                let pinStr = fact.isPinned ? " (📌核心人设置顶)" : ""
                return "- [#\(idx + 1)] \(tagStr)\(fact.content)\(pinStr)"
            }.joined(separator: "\n")
        }
        
        let existingMemories = getMemories(for: personaID)
        var existingMemoriesFormatted = "暂无历史记忆"
        if !existingMemories.isEmpty {
            existingMemoriesFormatted = existingMemories.map { "- [ID: \($0.id.uuidString)] (分类: \($0.category), 重要度: \($0.importance)): \($0.content)" }.joined(separator: "\n")
        }
        
        let conversationSection = mainChatLines.isEmpty ? "（近期无主窗口对白，主要依据时序因果链事实进行升华）" : mainChatLines.joined(separator: "\n")
        
        // 4. 全正向、无负面约束的提炼提示词 (KV Cache 结构亲和)
        let prompt = """
        # 角色
        数字分身「\(persona.name)」专属心智长期记忆提炼引擎。

        # 任务
        综合分析【即时时序因果链生效事实】与【近期对话记录】，结合【已有私域长期记忆库】，提炼具备长效价值的私域长期记忆并执行去重增量更新。
        
        # 提炼准则
        1. 长效资产导向：优先将具有跨周期参考价值的生活偏好、彼此约定、重要现实背景及核心事实升华沉淀为私域长期记忆。
        2. 即时事实升华：参考因果时序链中的客观有效事实，提炼其核心原子价值，忽略单次交谈细节或已完成的短期指令。
        3. 增量去重更新：若新事实修正或细化了既有记忆，输出 updated_memories；若为全新长效事实，输出 new_memories；已失效的旧记忆填入 deleted_memory_ids。

        # 输入数据
        【已有私域长期记忆库】：
        \(existingMemoriesFormatted)

        【即时时序因果链生效事实 (已通过真值门禁验证)】：
        \(factsFormatted)

        【近期对话记录】：
        \(conversationSection)

        # 输出规范 (严格输出标准 JSON 格式)：
        {
          "new_memories": [
            { "content": "长效原子事实描述", "category": "用户画像/生活偏好/彼此约定/情感羁绊/重要背景", "importance": 1到10的整数 }
          ],
          "updated_memories": [
            { "id": "需要修改的旧记忆UUID字符串", "content": "更新后的长效事实描述", "importance": 1到10的整数 }
          ],
          "deleted_memory_ids": ["已失效的旧记忆UUID字符串"]
        }
        """
        
        let effectiveModel: String = {
            if !persona.baseModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return persona.baseModel
            }
            return ConfigManager.shared.app.agentProfiles.first?.baseModel ?? ""
        }()
        
        let responseJson = await LLMService.shared.askSimple(prompt: prompt, model: effectiveModel)
        
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
                    deleteMemory(id: uuid)
                }
            }
        }
        
        if let updateList = jsonDict["updated_memories"] as? [[String: Any]] {
            for item in updateList {
                guard let idStr = item["id"] as? String,
                      let uuid = UUID(uuidString: idStr),
                      let content = item["content"] as? String,
                      let idx = self.memories.firstIndex(where: { $0.id == uuid }) else { continue }
                
                var mem = self.memories[idx]
                mem.content = content
                if let imp = item["importance"] as? Int { mem.importance = imp }
                updateMemory(mem)
                updatedCount += 1
            }
        }
        
        if let newList = jsonDict["new_memories"] as? [[String: Any]] {
            for item in newList {
                guard let content = item["content"] as? String, !content.isEmpty else { continue }
                let category = item["category"] as? String ?? "用户画像"
                let importance = item["importance"] as? Int ?? 5
                
                if !self.memories.contains(where: { $0.personaID == personaID && $0.content == content }) {
                    addMemory(personaID: personaID, content: content, category: category, importance: importance)
                    addedCount += 1
                }
            }
        }
        
        return (true, "长期记忆重整完毕：新增 \(addedCount) 条，更新 \(updatedCount) 条")
    }
    
    public func exportPersonaPackage(id: UUID) -> Data? {
        guard let p = personas.first(where: { $0.id == id }) else { return nil }
        let payload = PersonaPackagePayload(persona: p, state: getOrCreateRuntimeState(for: id), memories: getMemories(for: id))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(payload)
    }
    
    // MARK: - 拟人口吻与性格活力注入
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

// MARK: - ==================== 3. 剧场级神态动作与自适应卡片排版引擎 ====================

// MARK: - 3.1 核心数据结构与兼容模型

private struct TheaterDialogueSegment: Identifiable {
    let id = UUID()
    let isAction: Bool
    let text: String
}

/// 知识/词典卡片中的分节条目
private struct DictionarySectionItem: Identifiable, Sendable {
    let id = UUID()
    let index: Int?
    let title: String
    var content: String
    var examples: [String] = [] // 挂载例句，与核心释义主次分明呈现
}

/// 知识/词典卡片数据载荷
private struct DictionaryCardPayload: Sendable {
    let title: String                     // 词头 (如 "Weaver")
    let phonetic: String?                 // 音标 (如 "/'wi:və/")
    let transliteration: String?          // 音译/发音提示 (如 "威-夫")
    let definition: String?               // 核心总括释义
    let sections: [DictionarySectionItem] // 分项解析清单
    let rawMarkdown: String               // 原始文本 (供一键复制)
}

/// 键值属性卡片数据载荷 (专用于将 JSON 优雅卡片化呈现)
private struct KeyValueCardPayload: Sendable {
    let title: String
    let items: [(key: String, value: String)]
    let rawJSON: String
}

/// 高层级语义排版块
private enum PersonaContentBlock: Identifiable {
    case action(text: String)
    case dictionaryCard(payload: DictionaryCardPayload)
    case keyValueCard(payload: KeyValueCardPayload)
    case regularMarkdown(text: String)
    
    var id: String {
        switch self {
        case .action(let t): return "act_\(t.hashValue)"
        case .dictionaryCard(let p): return "dict_\(p.title)_\(p.sections.count)"
        case .keyValueCard(let p): return "kv_\(p.title)_\(p.items.count)"
        case .regularMarkdown(let t): return "md_\(t.hashValue)"
        }
    }
}

// MARK: - 3.2 语义解析与卡片分流引擎

private struct NovelTheaterParser {
    
    // MARK: - 动作语义守卫：严密阻断例句、发音提示与非动作括号
    private static func isActionBracket(_ content: String) -> Bool {
        let clean = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        
        // 1. 负向语义清单拦截 (排除例句、发音/音译、注释等)
        let nonActionPrefixes = [
            "如", "例如", "比如", "例：", "例", "注：", "注", "即", "或", "同", "见", "参见",
            "详见", "译为", "英文", "缩写", "俗称", "对应", "eg", "e.g.", "ex"
        ]
        for prefix in nonActionPrefixes {
            if clean.hasPrefix(prefix) { return false }
        }
        
        // 2. 排除纯连字符音译（如 "威-夫"、"阿-尔-法"）
        if clean.contains("-") && clean.count <= 12 && !clean.contains(" ") {
            let withoutHyphens = clean.replacingOccurrences(of: "-", with: "")
            if withoutHyphens.range(of: #"^[\u4e00-\u9fa5]+$"#, options: .regularExpression) != nil {
                return false
            }
        }
        
        // 3. 排除含有引号的语言引用（如 `“a weaver of tales”——故事的编造者`）
        if clean.contains("“") || clean.contains("\"") {
            return false
        }
        
        // 4. 排除纯英文技术片段或简短注记
        if clean.range(of: #"^[a-zA-Z0-9_\s\.\/\\:\-]+$"#, options: .regularExpression) != nil {
            return false
        }
        
        return true
    }
    
    // MARK: - 纯对白提取 (供给 TTS 朗读与底层模型，修复孤立标点粘连)
    static func parse(_ raw: String) -> [TheaterDialogueSegment] {
        let cleanText = raw.filterPersonaDelta().filterTHINK().filterStopTokens()
        guard !cleanText.isEmpty else { return [] }
        
        let pattern = "（([^）]+?)）|（([^）]*?)$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return [TheaterDialogueSegment(isAction: false, text: cleanText)]
        }
        
        let nsString = cleanText as NSString
        let matches = regex.matches(in: cleanText, options: [], range: NSRange(location: 0, length: nsString.length))
        guard !matches.isEmpty else {
            return [TheaterDialogueSegment(isAction: false, text: cleanText)]
        }
        
        var segments: [TheaterDialogueSegment] = []
        var currentIndex = 0
        
        for match in matches {
            let matchRange = match.range
            let bracketRaw = nsString.substring(with: matchRange)
            let trimmedContent = bracketRaw
                .replacingOccurrences(of: "（", with: "")
                .replacingOccurrences(of: "）", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            // 🛡️ 动作语义守卫：若非真正神态动作，则不切断文本，保留在常规对白/知识流中
            guard isActionBracket(trimmedContent) else {
                continue
            }
            
            // 提取动作前置正文
            if matchRange.location > currentIndex {
                let dRange = NSRange(location: currentIndex, length: matchRange.location - currentIndex)
                let dText = nsString.substring(with: dRange).trimmingCharacters(in: .whitespacesAndNewlines)
                if !dText.isEmpty {
                    segments.append(TheaterDialogueSegment(isAction: false, text: dText))
                }
            }
            
            if !trimmedContent.isEmpty {
                segments.append(TheaterDialogueSegment(isAction: true, text: trimmedContent))
            }
            
            // 标点防孤儿粘连：若动作后紧跟句尾标点（如 。，；），一并推进索引吸收，杜绝孤立成行
            var nextIndex = matchRange.location + matchRange.length
            let punctuationChars: Set<Character> = ["。", "，", "；", "！", "？", ".", ",", ";"]
            while nextIndex < nsString.length {
                let nextChar = Character(UnicodeScalar(nsString.character(at: nextIndex))!)
                if punctuationChars.contains(nextChar) || nextChar == " " || nextChar == "\t" {
                    nextIndex += 1
                } else {
                    break
                }
            }
            currentIndex = nextIndex
        }
        
        if currentIndex < nsString.length {
            let remain = nsString.substring(from: currentIndex).trimmingCharacters(in: .whitespacesAndNewlines)
            // 过滤落单孤立标点
            if !remain.isEmpty && remain != "。" && remain != "，" && remain != "；" {
                segments.append(TheaterDialogueSegment(isAction: false, text: remain))
            }
        }
        
        return segments.isEmpty ? [TheaterDialogueSegment(isAction: false, text: cleanText)] : segments
    }
    
    // MARK: - 智能卡片排版分块解析器
    static func parseToBlocks(_ raw: String) -> [PersonaContentBlock] {
        let cleanText = raw.filterPersonaDelta().filterTHINK().filterStopTokens().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return [] }
        
        // 1. 优先探测全文本是否为 JSON 结构
        if let kvCard = tryParseJSONCard(cleanText) {
            return [.keyValueCard(payload: kvCard)]
        }
        
        // 2. 探测是否为知识/词典定义卡片结构 (增强型特征探测)
        if let dictCard = tryParseDictionaryCard(cleanText) {
            return [.dictionaryCard(payload: dictCard)]
        }
        
        // 3. 常规混合流解析
        let segments = parse(cleanText)
        return segments.map { segment in
            if segment.isAction {
                return .action(text: segment.text)
            } else {
                if let subKV = tryParseJSONCard(segment.text) {
                    return .keyValueCard(payload: subKV)
                }
                return .regularMarkdown(text: segment.text)
            }
        }
    }
    
    /// 尝试将文本反序列化为属性卡片
    private static func tryParseJSONCard(_ text: String) -> KeyValueCardPayload? {
        var jsonCandidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if jsonCandidate.contains("```") {
            jsonCandidate = jsonCandidate.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```JSON", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard jsonCandidate.hasPrefix("{") && jsonCandidate.hasSuffix("}"),
              let data = jsonCandidate.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        
        var items: [(key: String, value: String)] = []
        let cardTitle = (dict["title"] as? String) ?? (dict["name"] as? String) ?? "结构化数据"
        
        for (key, val) in dict {
            if key == "title" || key == "name" { continue }
            if let arr = val as? [Any] {
                items.append((key: key, value: arr.map { "\($0)" }.joined(separator: ", ")))
            } else if let subDict = val as? [String: Any] {
                let subStr = (try? JSONSerialization.data(withJSONObject: subDict)).flatMap { String(data: $0, encoding: .utf8) } ?? "{...}"
                items.append((key: key, value: subStr))
            } else {
                items.append((key: key, value: "\(val)"))
            }
        }
        return KeyValueCardPayload(title: cardTitle, items: items, rawJSON: jsonCandidate)
    }
    
    // MARK: - 增强型词典/知识卡片特征打分探测器
    private static func tryParseDictionaryCard(_ text: String) -> DictionaryCardPayload? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else { return nil }
        
        // 特征打分：音标、解释标记、编号列表
        let hasPhonetic = lines.contains {
            $0.range(of: #"^[/\\[].+?[/\]]$"#, options: .regularExpression) != nil || $0.contains("/'") || $0.contains("/ˈ")
        }
        let hasExplainMarker = text.contains("解释：") || text.contains("释义：") || text.contains("【中文释义】") || text.contains("【释义】") || text.contains("【核心解析】")
        let hasNumberedItems = lines.filter {
            $0.range(of: #"^\d+[\.、]\s*.*?[：:]"#, options: .regularExpression) != nil
        }.count >= 2
        
        let score = (hasPhonetic ? 1 : 0) + (hasExplainMarker ? 1 : 0) + (hasNumberedItems ? 1 : 0)
        guard score >= 2 || (hasPhonetic && lines.count >= 3) else { return nil }
        
        // 词头提炼 (首行且剔除 Markdown 加粗)
        let title = lines[0].replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, title.count < 60 else { return nil }
        
        var phonetic: String? = nil
        var transliteration: String? = nil
        var definition: String? = nil
        var sections: [DictionarySectionItem] = []
        
        var currentIdx = 1
        // 解析头部元数据 (音标、谐音读音)
        while currentIdx < min(lines.count, 5) {
            let line = lines[currentIdx]
            
            // 探测音标 (如 /'wi:və/ 或 /ˈwiːvər/)
            if (line.hasPrefix("/") && line.hasSuffix("/")) || (line.hasPrefix("[") && line.hasSuffix("]")) || line.contains("/'") || line.contains("/ˈ") {
                phonetic = line.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
                currentIdx += 1
                continue
            }
            
            // 探测音译/发音提示 (如 (威-夫) 或 （威-夫）)
            if (line.hasPrefix("(") && line.hasSuffix(")")) || (line.hasPrefix("（") && line.hasSuffix("）")) {
                let inner = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                if !inner.hasPrefix("如") && !inner.hasPrefix("例如") {
                    transliteration = inner
                    currentIdx += 1
                    continue
                }
            }
            
            // 探测独立成行的解释标题
            if line == "解释：" || line == "释义：" || line.contains("【中文释义】") || line.contains("【释义】") {
                if currentIdx + 1 < lines.count {
                    let nextLine = lines[currentIdx + 1]
                    if nextLine.range(of: #"^\d+[\.、]"#, options: .regularExpression) == nil {
                        definition = nextLine.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
                        currentIdx += 2
                        continue
                    }
                }
                currentIdx += 1
                continue
            }
            break
        }
        
        // 解析分项与挂载例句
        var pendingItem: DictionarySectionItem? = nil
        
        while currentIdx < lines.count {
            let line = lines[currentIdx]
            if line == "***" || line == "---" { break }
            
            let itemPattern = #"^(?:(\d+)[\.、]|\-|\*)\s*\*{0,2}([^:：\*\n]+)\*{0,2}[:：]\s*(.*)$"#
            if let reg = try? NSRegularExpression(pattern: itemPattern),
               let match = reg.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                if let prev = pendingItem {
                    sections.append(prev)
                    pendingItem = nil
                }
                
                let nsLine = line as NSString
                let idxStr = match.range(at: 1).location != NSNotFound ? nsLine.substring(with: match.range(at: 1)) : nil
                let secTitle = match.range(at: 2).location != NSNotFound ? nsLine.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces) : ""
                let secContent = match.range(at: 3).location != NSNotFound ? nsLine.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespaces) : ""
                
                pendingItem = DictionarySectionItem(
                    index: idxStr.flatMap { Int($0) },
                    title: secTitle,
                    content: secContent,
                    examples: []
                )
            } else if var item = pendingItem {
                // 探测例句（如 “（如 “a weaver of tales”...）” 或 “如 Java 编程中的字节码织入”）
                if line.hasPrefix("（如") || line.hasPrefix("(如") || line.hasPrefix("如 ") || line.hasPrefix("例如") {
                    let cleanEg = line.replacingOccurrences(of: "（", with: "").replacingOccurrences(of: "）", with: "")
                        .replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    item.examples.append(cleanEg)
                    pendingItem = item
                } else {
                    item.content += "\n" + line
                    pendingItem = item
                }
            } else if definition == nil {
                definition = line
            }
            currentIdx += 1
        }
        
        if let last = pendingItem {
            sections.append(last)
        }
        
        guard definition != nil || phonetic != nil || !sections.isEmpty else { return nil }
        return DictionaryCardPayload(
            title: title,
            phonetic: phonetic,
            transliteration: transliteration,
            definition: definition,
            sections: sections,
            rawMarkdown: text
        )
    }
}

// MARK: - 3.3 主卡片排版容器组件 (NovelTheaterCardView)

private struct NovelTheaterCardView: View {
    let text: String
    var accentColor: Color = .purple
    
    var body: some View {
        let blocks = NovelTheaterParser.parseToBlocks(text)
        
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                switch block {
                case .action(let actionText):
                    ActionBadgeView(text: actionText, accentColor: accentColor)
                    
                case .dictionaryCard(let payload):
                    DictionaryCardView(payload: payload, accentColor: accentColor)
                    
                case .keyValueCard(let payload):
                    PropertyInspectorCardView(payload: payload, accentColor: accentColor)
                    
                case .regularMarkdown(let mdText):
                    RegularMarkdownView(text: mdText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 3.4 辞书/知识定义卡片 (DictionaryCardView)

private struct DictionaryCardView: View {
    let payload: DictionaryCardPayload
    let accentColor: Color
    @State private var isHovered = false
    @State private var isCopied = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 卡片头部：词头、音标、音译微胶囊与复制按钮
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .center, spacing: 8) {
                    Text(payload.title)
                        .font(.system(size: 17.5, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    
                    if let ph = payload.phonetic {
                        Text(ph)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(accentColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(accentColor.opacity(0.09))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(accentColor.opacity(0.22), lineWidth: 0.8))
                    }
                    
                    if let tr = payload.transliteration {
                        Text(tr)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(.secondary.opacity(0.9))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(Capsule())
                    }
                    
                    Spacer()
                    
                    if isHovered {
                        Button(action: copyToClipboard) {
                            HStack(spacing: 3) {
                                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 9.5))
                                Text(isCopied ? "已复制" : "复制")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity)
                    }
                }
                
                if let def = payload.definition {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "character.book.closed.fill")
                            .font(.system(size: 10.5))
                            .foregroundColor(accentColor.opacity(0.85))
                            .padding(.top, 2)
                        
                        Text(def)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary.opacity(0.9))
                            .lineSpacing(3.5)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 13)
            .padding(.bottom, payload.sections.isEmpty ? 13 : 10)
            
            // 卡片主体：各解析分节与内嵌例句
            if !payload.sections.isEmpty {
                ModernDivider(style: .fade(0.12))
                    .padding(.horizontal, 10)
                
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(payload.sections) { sec in
                        HStack(alignment: .top, spacing: 8) {
                            if let idx = sec.index {
                                Text("\(idx)")
                                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                    .foregroundColor(accentColor)
                                    .frame(width: 16, height: 16)
                                    .background(accentColor.opacity(0.12))
                                    .clipShape(Circle())
                                    .padding(.top, 1)
                            } else {
                                Circle()
                                    .fill(accentColor.opacity(0.6))
                                    .frame(width: 4, height: 4)
                                    .padding(.top, 7)
                            }
                            
                            VStack(alignment: .leading, spacing: 5) {
                                // 标题与释义
                                HStack(alignment: .firstTextBaseline, spacing: 3) {
                                    if !sec.title.isEmpty {
                                        Text(sec.title)
                                            .font(.system(size: 12.5, weight: .bold))
                                            .foregroundColor(.primary)
                                        Text("：")
                                            .font(.system(size: 12.5, weight: .bold))
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    Text(LocalizedStringKey(sec.content))
                                        .font(.system(size: 12.5, weight: .regular))
                                        .foregroundColor(.primary.opacity(0.85))
                                        .lineSpacing(3.5)
                                        .textSelection(.enabled)
                                }
                                
                                // 挂载例句（次级引用微排版，避免被切碎成神态动作）
                                ForEach(sec.examples, id: \.self) { eg in
                                    HStack(alignment: .top, spacing: 5) {
                                        Image(systemName: "quote.opening")
                                            .font(.system(size: 8.5))
                                            .foregroundColor(accentColor.opacity(0.75))
                                            .padding(.top, 2)
                                        
                                        Text(LocalizedStringKey(eg))
                                            .font(.system(size: 11.5, weight: .regular, design: .serif))
                                            .foregroundColor(.secondary)
                                            .lineSpacing(3)
                                            .textSelection(.enabled)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3.5)
                                    .background(Color.primary.opacity(0.03))
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 13)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [accentColor.opacity(0.28), Color.primary.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .onHover { isHovered = $0 }
    }
    
    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload.rawMarkdown, forType: .string)
        isCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { isCopied = false }
    }
}

// MARK: - 3.5 属性/键值对卡片 (PropertyInspectorCardView)

private struct PropertyInspectorCardView: View {
    let payload: KeyValueCardPayload
    let accentColor: Color
    @State private var isHovered = false
    @State private var isCopied = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.2.square")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(accentColor)
                
                Text(payload.title)
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button(action: copyJSON) {
                    HStack(spacing: 3) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9))
                        Text(isCopied ? "已复制" : "复制JSON")
                            .font(.system(size: 9.5))
                    }
                    .foregroundColor(.secondary.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.025))
            
            ModernDivider(style: .fade(0.1))
            
            VStack(alignment: .leading, spacing: 6) {
                ForEach(payload.items, id: \.key) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(item.key)
                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(minWidth: 70, alignment: .leading)
                        
                        Text(item.value)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(.primary)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 1.5)
                }
            }
            .padding(12)
        }
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
        )
    }
    
    private func copyJSON() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload.rawJSON, forType: .string)
        isCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { isCopied = false }
    }
}

// MARK: - 3.6 戏剧微动作与常规 Markdown 渲染视图

private struct ActionBadgeView: View {
    let text: String
    let accentColor: Color
    
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundColor(accentColor.opacity(0.85))
                .padding(.top, 3)
            
            Text(text)
                .font(.system(size: 12.5, weight: .regular, design: .serif))
                .foregroundColor(Color.primary.opacity(0.72))
                .lineSpacing(3.5)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(accentColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(accentColor.opacity(0.12), lineWidth: 0.8)
        )
    }
}

private struct RegularMarkdownView: View {
    let text: String
    
    var body: some View {
        let lines = text.components(separatedBy: .newlines)
        
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // 渲染 Markdown 分割线，杜绝 *** 字面量裸露
                if trimmed == "***" || trimmed == "---" || trimmed == "___" {
                    ModernDivider(style: .fade(0.14))
                        .padding(.vertical, 4)
                } else if !trimmed.isEmpty {
                    Text(LocalizedStringKey(line))
                        .font(.system(size: 13.5, weight: .regular))
                        .foregroundColor(.primary)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 2)
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

/// 瞬态 HUD 内存轻量会话条目
private struct HUDTurnItem: Identifiable, Sendable {
    let id: UUID = UUID()
    let isUser: Bool
    let text: String
    let timestamp: Date = Date()
}

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
    
    var isVisible: Bool { return window != nil }
    private override init() { super.init() }
    
    public func toggleHUD() {
        if isVisible { closeHUD() } else { showHUD() }
    }
    
    public func showHUD() {
        // MARK: - [TTS Hook] 仅在当前激活分身明确开启 TTS 时，才触发后台服务预热
        let activePersona = PersonaManager.shared.personas.first(where: { $0.id == PersonaManager.shared.lastActivePersonaID })
        LocalTTSProcessManager.shared.onHUDWillOpen(for: activePersona)
        
        if let existing = window {
            if existing.isMiniaturized { existing.deminiaturize(nil) }
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        // 使用包装后的窗口容器
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
        let windowHeight: CGFloat = 480
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
        guard let w = window else {
            LocalTTSProcessManager.shared.onHUDDidClose()
            return
        }
        
        LocalTTSProcessManager.shared.stopSpeaking()
        
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            w.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            w.close()
            self?.window = nil
            LocalTTSProcessManager.shared.onHUDDidClose()
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

// MARK: - [Decoupled Core] 纯净无边界数字分身对白交互中枢 (专为内嵌 AiView 设计)
public struct PersonaChatCoreView: View {
    public var showsWindowControls: Bool
    @Binding public var isPinned: Bool
    public var onTogglePin: ((Bool) -> Void)?
    public var onClose: (() -> Void)?
    
    @State private var inputText = ""
    @State private var streamingDeltaText = ""
    @State private var isProcessing = false
    @State private var isCopied = false
    
    // 内存滑动会话环 (承载最近 3 轮 / 6 条对白)
    @State private var hudHistory: [HUDTurnItem] = []
    
    @State private var selectedPersonaID: UUID? = PersonaManager.shared.lastActivePersonaID
    @FocusState private var isInputFocused: Bool
    
    // MARK: - [TTS Hook] 响应式监听 TTS 状态
    @ObservedObject private var ttsManager = LocalTTSProcessManager.shared
    
    private var activePersona: DigitalPersona? {
        PersonaManager.shared.personas.first(where: { $0.id == selectedPersonaID })
    }
    
    private var activeState: PersonaRuntimeState? {
        guard let pID = selectedPersonaID else { return nil }
        return PersonaManager.shared.getOrCreateRuntimeState(for: pID)
    }
    
    public init(
        showsWindowControls: Bool = false,
        isPinned: Binding<Bool> = .constant(false),
        onTogglePin: ((Bool) -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.showsWindowControls = showsWindowControls
        self._isPinned = isPinned
        self.onTogglePin = onTogglePin
        self.onClose = onClose
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            topHeroBar
            ModernDivider(style: .fade(0.14))
            responseScrollView
                .frame(maxWidth: .infinity, maxHeight: .infinity) // 移除固定高度限制，占满可用空间
            ModernDivider(style: .fade(0.14))
            footerStatusBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity) // 无宽高束缚
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
                        resetHUDConversation()
                        ttsManager.onActivePersonaChanged(to: p)
                    }
                }) {
                    HStack {
                        Image(systemName: p.avatarIcon)
                        Text("\(p.name) (\(p.roleTag))")
                        if p.enableTTS { Text("🎙️") }
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
        TextField("呼叫分身并输入指令 (↵ 发送, ⌘K 重置)...", text: $inputText)
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
            
            // 仅在启用窗口控制器时渲染固定与关闭按钮
            if showsWindowControls {
                Button(action: {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                        isPinned.toggle()
                        onTogglePin?(isPinned)
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
                
                if let closeAction = onClose {
                    Button(action: closeAction) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary.opacity(0.5))
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .help("关闭面板 (ESC)")
                }
            }
        }
    }
    
    @ViewBuilder
    private var responseScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if hudHistory.isEmpty && streamingDeltaText.isEmpty && !isProcessing {
                        placeholderView
                    } else {
                        ForEach(hudHistory) { turn in
                            if turn.isUser {
                                HStack {
                                    Spacer(minLength: 40)
                                    Text(turn.text)
                                        .font(.system(size: 13, weight: .medium))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(Color.purple.opacity(0.14))
                                        .foregroundColor(.primary)
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                            } else {
                                NovelTheaterCardView(
                                    text: turn.text,
                                    accentColor: activePersona?.relationshipDirection.themeColor ?? .purple
                                )
                                .padding(.trailing, 20)
                            }
                        }
                        
                        if isProcessing || !streamingDeltaText.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 6) {
                                    Circle().fill(Color.purple).frame(width: 5, height: 5)
                                    Text("正在酝酿神态与言辞...")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                                NovelTheaterCardView(
                                    text: streamingDeltaText.isEmpty ? "（凝眸沉思片刻...）" : streamingDeltaText,
                                    accentColor: activePersona?.relationshipDirection.themeColor ?? .purple
                                )
                            }
                        }
                        
                        Color.clear
                            .frame(height: 1)
                            .id("HUD_BOTTOM_MARKER")
                    }
                }
                .padding(20)
            }
            .forceOverlayScrollbars()
            .onChange(of: streamingDeltaText) { _, _ in
                proxy.scrollTo("HUD_BOTTOM_MARKER", anchor: .bottom)
            }
            .onChange(of: hudHistory.count) { _, _ in
                proxy.scrollTo("HUD_BOTTOM_MARKER", anchor: .bottom)
            }
        }
    }
    
    @ViewBuilder
    private var placeholderView: some View {
        VStack(spacing: 12) {
            Image(systemName: "theatermasks.fill")
                .font(.system(size: 38))
                .foregroundStyle(
                    LinearGradient(colors: [.purple, .cyan, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .shadow(color: Color.purple.opacity(0.3), radius: 6, y: 3)
                .padding(.bottom, 2)
            
            Text("随时随地与数字分身开启沉浸剧场与日常相伴")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
            
            HStack(spacing: 12) {
                Label("连贯指代追问", systemImage: "arrow.triangle.branch")
                Label("Ebbinghaus 活体记忆", systemImage: "brain.head.profile")
                Label("⌘K 瞬时清空", systemImage: "command")
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary.opacity(0.65))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 60)
    }
    
    @ViewBuilder
    private var footerStatusBar: some View {
        HStack(spacing: 10) {
            if let state = activeState {
                let direction = activePersona?.relationshipDirection ?? .romantic
                let milestoneTitle = state.bondMilestone.dynamicTitle(for: direction)
                HStack(spacing: 5) {
                    Image(systemName: direction.icon)
                        .font(.system(size: 8.5))
                        .foregroundColor(direction.themeColor)
                    Text("【\(direction.rawValue) · \(direction == .passerby ? "保持客态" : milestoneTitle)】\(direction == .passerby ? "" : " \(state.affinityScore)")")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(direction.themeColor.opacity(0.08))
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
            
            // MARK: - [TTS Hook] 语音交互微胶囊
            if activePersona?.enableTTS == true {
                Button {
                    switch ttsManager.state {
                    case .speaking:
                        ttsManager.stopSpeaking()
                    case .error:
                        Task { await ttsManager.retryLastSpeak() }
                    default:
                        break
                    }
                } label: {
                    HStack(spacing: 4.5) {
                        switch ttsManager.state {
                        case .speaking:
                            Image(systemName: "waveform")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundColor(.purple)
                                .symbolEffect(.variableColor.iterative.reversing, isActive: true)
                            Text("正在朗读 (点击打断)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                        case .error(let msg):
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundColor(.red)
                            Text("\(msg) (点击重试)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.red)
                        case .starting:
                            ProgressView()
                                .controlSize(.mini)
                            Text("引擎预热中...")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                        default:
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundColor(.indigo)
                            Text("语音就绪")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background({
                        switch ttsManager.state {
                        case .speaking: return Color.purple.opacity(0.14)
                        case .error:    return Color.red.opacity(0.14)
                        case .starting: return Color.orange.opacity(0.10)
                        default:        return Color.indigo.opacity(0.08)
                        }
                    }())
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(ttsManager.state == .speaking ? Color.purple.opacity(0.3) : (isTTSInError ? Color.red.opacity(0.35) : Color.clear), lineWidth: 0.8)
                    )
                }
                .buttonStyle(.plain)
            }
            
            Spacer()
            
            HStack(spacing: 6) {
                if !hudHistory.isEmpty {
                    Text("\(hudHistory.count / 2) 轮对话")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                
                if showsWindowControls && isPinned {
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
    
    private func resetHUDConversation() {
        ttsManager.stopSpeaking()
        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
            streamingDeltaText = ""
            inputText = ""
            hudHistory.removeAll()
        }
    }
    
    private func executeQuickChat() {
        let cleanQuery = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty, let pID = selectedPersonaID else { return }
        
        if let lastTurn = hudHistory.last, lastTurn.isUser && lastTurn.text == cleanQuery {
            _ = hudHistory.popLast()
        }
        
        isProcessing = true
        streamingDeltaText = "（凝眸沉思片刻...）"
        
        let userTurn = HUDTurnItem(isUser: true, text: cleanQuery)
        hudHistory.append(userTurn)
        
        let personaName = activePersona?.name ?? "数字分身"
        let staticInstruction = PersonaManager.shared.compileStaticPersonaPrompt(for: pID)
        let dynamicContext = PersonaManager.shared.compileDynamicRuntimeContext(for: pID, query: cleanQuery)
        
        let sessionLogID = LogManager.shared.startSession(
            query: cleanQuery,
            agentName: personaName,
            category: .singleLLM
        )
        
        var outgoingMessages: [ContextMessage] = []
        for turn in hudHistory.suffix(5).dropLast() {
            outgoingMessages.append(turn.isUser ? .user(turn.text) : .assistant(text: turn.text))
        }
        outgoingMessages.append(.system(dynamicContext))
        outgoingMessages.append(.user(cleanQuery))
        
        Task {
            let targetModel: String = {
                if let model = activePersona?.baseModel, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return model
                }
                return ConfigManager.shared.app.agentProfiles.first?.baseModel ?? ""
            }()
            
            var accumulated = ""
            var hasReceivedAnyToken = false
            
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        let stream = LLMService.shared.ask(
                            messages: outgoingMessages,
                            model: targetModel,
                            images: [],
                            fileURLs: [],
                            instruction: staticInstruction,
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
                                    self.streamingDeltaText = clean
                                }
                            default:
                                break
                            }
                        }
                    }
                    
                    group.addTask {
                        try await Task.sleep(nanoseconds: 90_000_000_000)
                        throw URLError(.timedOut)
                    }
                    
                    try await group.next()
                    group.cancelAll()
                }
                
                let finalClean = accumulated.filterPersonaDelta().trimmingCharacters(in: .whitespacesAndNewlines)
                if !hasReceivedAnyToken || finalClean.isEmpty {
                    await MainActor.run {
                        if let last = self.hudHistory.last, last.isUser && last.text == cleanQuery {
                            _ = self.hudHistory.popLast()
                        }
                        self.streamingDeltaText = "（微微摇头，欲言又止...）\n\n> ⚠️ 未能接收到有效回复，请检查网络后重新发送。"
                        self.isProcessing = false
                    }
                    LogManager.shared.endSession(sessionID: sessionLogID, isSuccess: false, detail: "模型返回空响应")
                    return
                }
                
                // 1. 心智增量更新：通过真值门禁提炼事实至 TemporalFact，驱动实体因果链演进
                if let deltaJSON = accumulated.extractPersonaDelta() {
                    PersonaManager.shared.applyMentalDelta(for: pID, deltaJSON: deltaJSON, userQuery: cleanQuery)
                }
                
                // 2. 闭环落盘至 HUD 内存轻量滑动环 (最大保留 6 条/3 轮)
                await MainActor.run {
                    self.hudHistory.append(HUDTurnItem(isUser: false, text: finalClean))
                    if self.hudHistory.count > 6 {
                        self.hudHistory.removeFirst(self.hudHistory.count - 6)
                    }
                    self.streamingDeltaText = ""
                    self.inputText = ""
                    self.isProcessing = false
                }
                
                // 3. TTS 朗读调度
                let pureDialogue = NovelTheaterParser.parse(finalClean)
                    .filter { !$0.isAction }
                    .map { $0.text }
                    .joined(separator: "\n")

                ttsManager.speakDialogue(pureDialogue, for: activePersona)
                
                LogManager.shared.endSession(sessionID: sessionLogID, isSuccess: true, detail: accumulated)
                
            } catch {
                LogManager.shared.endSession(sessionID: sessionLogID, isSuccess: false, detail: error.localizedDescription)
                await MainActor.run {
                    if let last = self.hudHistory.last, last.isUser && last.text == cleanQuery {
                        _ = self.hudHistory.popLast()
                    }
                    if (error as? URLError)?.code == .timedOut {
                        self.streamingDeltaText = "（思绪飘向远方...）\n\n> ⏱️ **交互超时**：服务端响应耗时过长，已自动释放，可再次尝试。"
                    } else {
                        self.streamingDeltaText = "（神情微怔）\n\n> ❌ **响应异常**: \(error.localizedDescription)"
                    }
                    self.isProcessing = false
                }
            }
        }
    }
    
    private var isTTSInError: Bool {
        if case .error = ttsManager.state { return true }
        return false
    }
}

// MARK: - [Wrapper View] 维持对老版本窗口的向后兼容，负责悬浮窗的特定修饰与尺寸锁相
public struct PersonaWindowContentView: View {
    @State var isPinned: Bool
    var onTogglePin: (Bool) -> Void
    var onClose: () -> Void
    
    public init(
        isPinned: Bool = false,
        onTogglePin: @escaping (Bool) -> Void = { _ in },
        onClose: @escaping () -> Void = {}
    ) {
        self._isPinned = State(initialValue: isPinned)
        self.onTogglePin = onTogglePin
        self.onClose = onClose
    }
    
    public var body: some View {
        ZStack {
            ambientBackdropGlow
            
            PersonaChatCoreView(
                showsWindowControls: true,
                isPinned: $isPinned,
                onTogglePin: onTogglePin,
                onClose: onClose
            )
        }
        .frame(width: 660, height: 480) // 仅在独立浮动窗口容器中才固定尺寸
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(specularGlassBorder)
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
    private var specularGlassBorder: some View {
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
                    
                    LocalDatabaseManager.shared.delete(DigitalPersona.self, id: persona.id.uuidString)
                    LocalDatabaseManager.shared.deleteWhere(
                        tableName: PersonaRuntimeState.databaseTableName,
                        conditionSQL: "persona_id = ?",
                        arguments: [persona.id.uuidString]
                    )
                    LocalDatabaseManager.shared.deleteWhere(
                        tableName: PersonaMemoryItem.databaseTableName,
                        conditionSQL: "persona_id = ?",
                        arguments: [persona.id.uuidString]
                    )
                    
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
                    LocalDatabaseManager.shared.save(newP)
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
                    onSave: {
                        LocalDatabaseManager.shared.save(manager.personas[idx])
                    }
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

// MARK: - ==================== 7. 拟人化心智组装器详细版面 (解耦无超时编译版) ====================

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
    
    // MARK: - 主视图：分层解耦装配，彻底消除编译器类型推断超时
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                stage1BaseCard
                stage2GuardrailCard
                stage3MemoryCard
                stage4DynamicCard
                
                // MARK: - [TTS Hook] 🎙️ 阶段五：拟人原声与 TTS 语音交互 (完全封装于 LocalTTSProcessManager，随时方便摘除)
                PersonaTTSConfigCardView(persona: $persona)
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
    
    // MARK: - 🧬 阶段一：灵魂基底与人设相貌
    @ViewBuilder
    private var stage1BaseCard: some View {
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
                PersonaLeftAlignedRow("关系轨道") {
                    HStack(spacing: 10) {
                        Picker("", selection: $persona.relationshipDirection) {
                            ForEach(RelationshipDirection.allCases, id: \.self) { dir in
                                HStack {
                                    Image(systemName: dir.icon)
                                    Text(dir.rawValue)
                                }
                                .tag(dir)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 135, alignment: .leading) // 微调至 135pt，5 汉字无缝舒展
                        
                        Text(persona.relationshipDirection.summary)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .help(persona.relationshipDirection.summary)
                    }
                }
                PersonaLeftAlignedRow("基底模型") {
                    Menu {
                        Button("跟随全局默认模型") {
                            persona.baseModel = ""
                        }
                        
                        Divider()
                        
                        ForEach(ConfigManager.shared.app.aiConfigs) { config in
                            let nodeName = config.name.isEmpty ? config.protocolType.uppercased() : config.name
                            Menu("\(nodeName) (\(config.models.count))") {
                                ForEach(config.models, id: \.self) { m in
                                    let compositeKey = "\(config.id.uuidString)/\(m)"
                                    Button(action: {
                                        persona.baseModel = compositeKey
                                    }) {
                                        HStack {
                                            Text(m)
                                            if persona.baseModel == compositeKey || persona.baseModel == m {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "cpu")
                                .font(.system(size: 11))
                                .foregroundColor(persona.baseModel.isEmpty ? .secondary : .purple)
                            
                            Text(persona.displayModelName)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            
                            Spacer()
                            
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.secondary.opacity(0.7))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4.5)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(NSColor.separatorColor), lineWidth: 0.8)
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 240, alignment: .leading) // 像素级对齐输入框宽度
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
    }
    
    // MARK: - 🛡️ 阶段二：心智防火墙与语气样本
    @ViewBuilder
    private var stage2GuardrailCard: some View {
        assemblyStageCard(
            stageBadge: "STAGE 2",
            stageTitle: "心智防火墙与语气样本",
            stageSubtitle: "通过行为约束与少样本对齐，规范输出行为",
            themeColor: .red
        ) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("🛡️ 潜意识行为准则 (Behavioral Guardrails)").font(.system(size: 11, weight: .bold)).foregroundStyle(.red)
                    HStack {
                        TextField("新增规则（如：遵循第一人称视角/遵循设定世界观）...", text: $newForbidden)
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
    }
    
    // MARK: - 🧠 阶段三：Ebbinghaus 私域记忆矩阵
    @ViewBuilder
    private var stage3MemoryCard: some View {
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
    }
    
    // MARK: - 🌀 阶段四：动态情境、因果时序与边界
    @ViewBuilder
    private var stage4DynamicCard: some View {
        assemblyStageCard(
            stageBadge: "STAGE 4",
            stageTitle: "动态情境、因果时序与边界",
            stageSubtitle: "随剧情演进的情感阻尼、羁绊阶梯、实体因果时序与认知边界",
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
                        // 1. 关系轨道徽标
                        HStack(spacing: 4) {
                            Image(systemName: persona.relationshipDirection.icon)
                                .font(.system(size: 9))
                            Text(persona.relationshipDirection.rawValue)
                                .font(.system(size: 10.5, weight: .bold))
                        }
                        .foregroundColor(persona.relationshipDirection.themeColor)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(persona.relationshipDirection.themeColor.opacity(0.12))
                        .cornerRadius(4)

                        // 2. 羁绊阶段徽标与分值滑块 (客态路人锁死，其余动态展示)
                        if persona.relationshipDirection != .passerby {
                            Text(state.bondMilestone.dynamicTitle(for: persona.relationshipDirection))
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundColor(.purple)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.purple.opacity(0.12))
                                .cornerRadius(4)
                            
                            Slider(value: Binding(get: { Double(state.affinityScore) }, set: { state.affinityScore = Int($0) }), in: 0...100)
                            Text("\(state.affinityScore)分").font(.system(size: 12, weight: .bold, design: .monospaced)).frame(width: 40)
                        } else {
                            Text("客态锁定 (无羁绊演进)")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                    }
                }
                
                PersonaLeftAlignedRow("实时情绪") {
                    TextField("如 表面从容，内心隐隐作痛", text: $state.currentEmotion).textFieldStyle(.roundedBorder)
                }
                
                PersonaLeftAlignedRow("短期期待/动机", alignment: .top) {
                    TextEditor(text: $state.activeMotivation)
                        .font(.system(size: 11.5))
                        .frame(minHeight: 38, maxHeight: 58)
                        .padding(3)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor).opacity(0.6), lineWidth: 1))
                }
                
                Divider().opacity(0.4)
                
                // 实体因果时间线 (Timeline DAG)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.green)
                            Text("实体时序因果链 (Causal Timeline)").font(.system(size: 11, weight: .bold))
                        }
                        Spacer()
                        let activeCount = state.knownFacts.filter { $0.status == .active }.count
                        let pinnedCount = state.knownFacts.filter { $0.isPinned }.count
                        Text("生效 \(activeCount) 条 · 置顶 \(pinnedCount) 条").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    
                    HStack(spacing: 6) {
                        TextField("新增事实（支持以 [主体] 开头标注实体）...", text: $newKnownFact)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addNewFact() }
                        
                        Button("录入事实") { addNewFact() }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .disabled(newKnownFact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    
                    if state.knownFacts.isEmpty {
                        Text("暂无即时事实，将在会话中随模型交互自动提炼推演")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 6)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(state.knownFacts.enumerated()), id: \.element.id) { index, fact in
                                TemporalFactTimelineRow(
                                    index: index + 1,
                                    fact: fact,
                                    allFacts: state.knownFacts,
                                    isLast: index == state.knownFacts.count - 1,
                                    onTogglePin: {
                                        if let idx = state.knownFacts.firstIndex(where: { $0.id == fact.id }) {
                                            state.knownFacts[idx].isPinned.toggle()
                                        }
                                    },
                                    onRestore: {
                                        if let idx = state.knownFacts.firstIndex(where: { $0.id == fact.id }) {
                                            state.knownFacts[idx].status = .active
                                            state.knownFacts[idx].supersededByID = nil
                                        }
                                    },
                                    onSaveEdit: { updatedText in
                                        if let idx = state.knownFacts.firstIndex(where: { $0.id == fact.id }) {
                                            state.knownFacts[idx].content = updatedText
                                        }
                                    },
                                    onPromoteToMemory: {
                                        PersonaManager.shared.convertFactToMemory(
                                            personaID: persona.id,
                                            fact: fact,
                                            category: fact.entities.first ?? "用户画像",
                                            importance: fact.isPinned ? 9 : 6
                                        )
                                        Util.message("⭐ 事实已成功升华至私域长期记忆库")
                                    },
                                    onDelete: {
                                        withAnimation {
                                            state.knownFacts.removeAll { $0.id == fact.id }
                                        }
                                    }
                                )
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                
                Divider().opacity(0.4)
                
                // 认知盲区
                VStack(alignment: .leading, spacing: 6) {
                    Text("❓ 认知盲区 (基于已知背景构建局部认知)").font(.system(size: 11, weight: .bold)).foregroundStyle(.orange)
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
                    ForEach(Array(state.blindSpots.enumerated()), id: \.offset) { idx, blind in
                        EditableListRow(
                            text: blind,
                            prefix: "❓ ",
                            onSave: { updated in
                                if idx < state.blindSpots.count {
                                    state.blindSpots[idx] = updated
                                }
                            },
                            onDelete: {
                                if idx < state.blindSpots.count {
                                    state.blindSpots.remove(at: idx)
                                }
                            }
                        )
                    }
                }
            }
        }
    }
    
    private func addNewFact() {
        let clean = newKnownFact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        
        var content = clean
        var entities: [String] = []
        
        if content.hasPrefix("["), let closingIdx = content.firstIndex(of: "]") {
            let entityStr = String(content[content.index(after: content.startIndex)..<closingIdx])
            entities = entityStr.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            content = String(content[content.index(after: closingIdx)...]).trimmingCharacters(in: .whitespaces)
        }
        
        let fact = TemporalFact(
            content: content,
            entities: entities,
            status: .active,
            timestamp: Date()
        )
        state.knownFacts.append(fact)
        newKnownFact = ""
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

/// 现代 macOS 质感时序因果时间线节点 (带具象覆盖指针与恢复回退)
struct TemporalFactTimelineRow: View {
    let index: Int
    let fact: TemporalFact
    let allFacts: [TemporalFact]
    let isLast: Bool
    var onTogglePin: () -> Void
    var onRestore: () -> Void
    var onSaveEdit: (String) -> Void
    var onPromoteToMemory: () -> Void
    var onDelete: () -> Void
    
    @State private var isHovered: Bool = false
    @State private var isEditing: Bool = false
    @State private var draftText: String = ""
    
    private var isSuperseded: Bool { fact.status == .superseded }
    private var isInvalidated: Bool { fact.status == .invalidated }
    
    private var supersedingPointerText: String? {
        guard let supersededByID = fact.supersededByID,
              let idx = allFacts.firstIndex(where: { $0.id == supersededByID }) else { return nil }
        return "[#\(idx + 1)]"
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(nodeColor.opacity(0.18))
                        .frame(width: 16, height: 16)
                    
                    if fact.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundColor(.purple)
                    } else if isSuperseded || isInvalidated {
                        Circle()
                            .fill(Color.secondary.opacity(0.6))
                            .frame(width: 6, height: 6)
                    } else {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                    }
                }
                .padding(.top, 4)
                
                if !isLast {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 1.2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 16)
            
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("[#\(index)]")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundColor(nodeColor)
                    
                    ForEach(fact.entities, id: \.self) { entity in
                        Text(entity)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 4.5)
                            .padding(.vertical, 1.5)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(Capsule())
                            .foregroundColor(.secondary)
                    }
                    
                    if isSuperseded {
                        Text(supersedingPointerText.map { "已被 \($0) 修正" } ?? "已被新因果修正")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary.opacity(0.7))
                            .padding(.horizontal, 4)
                            .background(Color.primary.opacity(0.04))
                            .cornerRadius(3)
                    } else if isInvalidated {
                        Text("已物理注销")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.red.opacity(0.7))
                            .padding(.horizontal, 4)
                            .background(Color.red.opacity(0.06))
                            .cornerRadius(3)
                    }
                    
                    Spacer()
                    
                    if isHovered {
                        HStack(spacing: 4) {
                            if isSuperseded || isInvalidated {
                                Button(action: onRestore) {
                                    Image(systemName: "arrow.uturn.backward.circle")
                                        .font(.system(size: 10))
                                        .foregroundColor(.green.opacity(0.9))
                                }
                                .buttonStyle(.plain)
                                .help("撤销覆盖，恢复为生效状态")
                            }
                            
                            Button(action: onTogglePin) {
                                Image(systemName: fact.isPinned ? "pin.slash.fill" : "pin")
                                    .font(.system(size: 10))
                                    .foregroundColor(fact.isPinned ? .purple : .secondary)
                            }
                            .buttonStyle(.plain)
                            .help(fact.isPinned ? "取消置顶锁定" : "置顶锁定（免疫淘汰）")
                            
                            Button(action: onPromoteToMemory) {
                                Image(systemName: "brain.head.profile")
                                    .font(.system(size: 10))
                                    .foregroundColor(.cyan)
                            }
                            .buttonStyle(.plain)
                            .help("升华沉淀为私域长期记忆")
                            
                            Button(action: {
                                draftText = fact.content
                                isEditing = true
                            }) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 10))
                                    .foregroundColor(.blue.opacity(0.85))
                            }
                            .buttonStyle(.plain)
                            .help("编辑事实文本")
                            
                            Button(role: .destructive, action: onDelete) {
                                Image(systemName: "trash")
                                    .font(.system(size: 10))
                                    .foregroundColor(.red.opacity(0.85))
                            }
                            .buttonStyle(.plain)
                            .help("删除此事实")
                        }
                    }
                }
                
                if isEditing {
                    HStack {
                        TextField("", text: $draftText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                            .onSubmit { commitEdit() }
                        Button { commitEdit() } label: {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        }.buttonStyle(.plain)
                        Button { isEditing = false } label: {
                            Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                        }.buttonStyle(.plain)
                    }
                } else {
                    Text(fact.content)
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundColor((isSuperseded || isInvalidated) ? .secondary.opacity(0.6) : .primary)
                        .strikethrough(isSuperseded || isInvalidated, color: .secondary.opacity(0.5))
                        .lineSpacing(2)
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(isHovered ? Color.primary.opacity(0.03) : Color.clear)
            .cornerRadius(6)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
    
    private var nodeColor: Color {
        if fact.isPinned { return .purple }
        if isSuperseded || isInvalidated { return .secondary }
        return .green
    }
    
    private func commitEdit() {
        let clean = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { onSaveEdit(clean) }
        isEditing = false
    }
}

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
