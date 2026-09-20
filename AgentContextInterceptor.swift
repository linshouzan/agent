//////////////////////////////////////////////////////////////////
// 文件名：AgentContextInterceptors.swift
// 文件说明：适用于 macOS 14+ 的 Agent 上下文双向拦截器插件化架构 (Swift 6 Ready)
//
// 核心解构架构拓扑 (Domain-Driven Architecture):
// ├── 1. AgentContextInterceptor          : 纯函数式上下文双向拦截器契约 (下发脱敏 + 输出捕获 + 历史自愈)
// ├── 2. AgentContextInterceptorPipeline  : 线程安全的全双工插件中枢调度器 (支持外部自由注册、热插拔)
// ├── 3. GenericTagBlock & Registry       : 纯通用复合主键分面状态机底账引擎 (无特定业务名词污染)
// └── 4. StructuredTagContextPlugin       : 开箱即用的结构化标签清洗与长效记忆分槽归集插件
//////////////////////////////////////////////////////////////////

import Foundation
import AppKit

// MARK: - ==================== 1. Interceptor Protocol (双向拦截器协议契约) ====================

/// 上下文双向拦截器协议：隔离具体业务标签，主干流水线仅通过协议驱动
@MainActor
protocol AgentContextInterceptor: Sendable {
    /// 插件唯一标识符
    var identifier: String { get }
    /// 执行优先级 (数值越小越优先执行)
    var priority: Int { get }
    
    /// 上下文下发前：净化并折叠历史消息中的大块结构体，释放模型 Attention 视界与 Token
    /// - Parameter text: 原始历史消息正文
    /// - Returns: 清洗脱敏后的安全文本
    func sanitizeHistory(text: String) -> String
    
    /// 模型输出落盘后：即时捕获新鲜生成的特征标签，沉淀至底账数据字典
    /// - Parameters:
    ///   - text: 模型刚生成的完整文本
    ///   - sharedContext: 智能体全局共享上下文引用
    func ingestEmitted(text: String, sharedContext: inout [String: String])
    
    /// 会话冷启动/恢复时：从历史消息流自愈复原结构化底账，杜绝旧会话载入时丢槽
    /// - Parameters:
    ///   - messages: 历史消息实体列表
    ///   - sharedContext: 智能体全局共享上下文引用
    func restoreFromHistory(messages: [ChatMessage], sharedContext: inout [String: String])
}

// MARK: - ==================== 2. Interceptor Pipeline (插件管线调度中枢) ====================

/// 上下文拦截器管线中枢：全局单例，集中管理所有插拔式插件
@MainActor
final class AgentContextInterceptorPipeline: Sendable {
    static let shared = AgentContextInterceptorPipeline()
    
    /// 已激活的拦截器插件列表 (按优先级升序排列)
    private var interceptors: [AgentContextInterceptor] = []
    
    private init() {
        // 默认装配结构化标签插件 (支持 <card>, <state>, <snapshot> 等)
        register(StructuredTagContextPlugin())
    }
    
    /// 动态注册新拦截器插件 (支持未来扩展，如 SQL 清洗器、代码 AST 提取器等)
    func register(_ interceptor: AgentContextInterceptor) {
        interceptors.removeAll { $0.identifier == interceptor.identifier }
        interceptors.append(interceptor)
        interceptors.sort { $0.priority < $1.priority }
    }
    
    /// 移除指定拦截器插件
    func unregister(identifier: String) {
        interceptors.removeAll { $0.identifier == identifier }
    }
    
    /// 历史消息流水线清洗：链式遍历所有插件执行脱敏
    func sanitizeHistory(_ text: String) -> String {
        var result = text
        for interceptor in interceptors {
            result = interceptor.sanitizeHistory(text: result)
        }
        return result
    }
    
    /// 模型输出实时捕获：分发给所有插件提取特征
    func ingestEmitted(_ text: String, sharedContext: inout [String: String]) {
        for interceptor in interceptors {
            interceptor.ingestEmitted(text: text, sharedContext: &sharedContext)
        }
    }
    
    /// 历史消息自愈恢复：驱动各插件重建专属底账
    func restoreFromHistory(messages: [ChatMessage], sharedContext: inout [String: String]) {
        for interceptor in interceptors {
            interceptor.restoreFromHistory(messages: messages, sharedContext: &sharedContext)
        }
    }
}

// MARK: - ==================== 3. Generic Tag Block & Registry (纯通用分面底账) ====================

/// 通用标签块数据容器：负责无损提取标签属性与内部载荷
struct GenericTagBlock: Sendable {
    let tagName: String
    let attributes: [String: String]
    let innerContent: String
    
    /// 提取该标签块的核心分槽主键，彻底隔离同一角色的不同阶段卡片，避免相互抹除覆写
    var primarySlotKey: String {
        let lowerContent = innerContent.lowercased()
        
        // 1. 世界网关：直接采用纯净标识符 [world_gateway]，消除“世界网关: [world_gateway]”冗余标题
        if attributes["type"]?.lowercased() == "world_gateway" ||
           innerContent.contains("故事初始化") ||
           innerContent.contains("大世界常识") ||
           innerContent.contains("WORLD_INITIALIZATION_GATEWAY") ||
           innerContent.contains("Era_Anchor") {
            return "[world_gateway]"
        }
        
        // 2. 角色名称提取：优先取 role 属性，兜底提取正文中的目标姓名
        var targetRole = attributes["role"]?.trimmingCharacters(in: CharacterSet(charactersIn: "[] \t\n\r")) ?? ""
        if targetRole.isEmpty {
            if let range = innerContent.range(of: #"Active_Target:\s*\[?([^\]\|\n\r]+)\]?"#, options: .regularExpression) {
                let sub = String(innerContent[range])
                targetRole = sub.replacingOccurrences(of: "Active_Target:", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[] \t\n\r"))
            } else if let range = innerContent.range(of: #"👤\s*(\S+)"#, options: .regularExpression) {
                let sub = String(innerContent[range])
                targetRole = sub.replacingOccurrences(of: "👤", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "*[] \t\n\r"))
            }
        }
        if targetRole.isEmpty { targetRole = "未命名目标" }
        
        // 3. 槽位分面推导：采用 "[角色名] · 分面" 形式，层次分明且视觉轻量
        let explicitType = attributes["type"]?.lowercased() ?? ""
        
        // A. 瞬态契约 (Phase 3 结合推进参数)
        if explicitType == "collision_snap" ||
           lowerContent.contains("phase 3") ||
           innerContent.contains("亲密契约") ||
           innerContent.contains("COLLISION_SNAP") ||
           innerContent.contains("策略参数") ||
           innerContent.contains("Posture_Sequence") {
            return "[\(targetRole)] · 瞬态契约"
        }
        
        // B. 离散结算网关
        if explicitType == "settlement" ||
           innerContent.contains("结算重载网关") ||
           innerContent.contains("SETTLEMENT_GATEWAY") ||
           innerContent.contains("离散状态一阶推理链") {
            return "[\(targetRole)] · 结算记录"
        }
        
        // C. 基础角色档案 (默认)
        return "[\(targetRole)] · 角色档案"
    }
}

/// 通用标签解析与分面状态注册器：维护物理持久化底账字典
struct GenericTagBlockRegistry: Sendable {
    /// 物理槽位数据底账字典：[SlotKey: 卡片原始内容]
    private(set) var stateSlots: [String: String] = [:]
    
    var isEmpty: Bool { stateSlots.isEmpty }
    
    init() {}
    
    init(slots: [String: String]) {
        self.stateSlots = slots
    }
    
    /// 从已持久化的 JSON 字符串无损复原槽位字典，消除从 Markdown 视图正则反解的结构断裂
    init(jsonString: String) {
        if let data = jsonString.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            self.stateSlots = dict
        }
    }
    
    /// 将内存槽位字典导出为持久化 JSON 字符串，供底层 Context 安全存取
    func toJSONString() -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: stateSlots, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
    
    /// 吞噬并解析文本中的全部 XML 风格自定义标签对 (默认识别 card, state, snapshot 等)
    mutating func ingest(text: String, targetTags: Set<String> = ["card", "state", "snapshot"]) {
        let pattern = #"(?s)<(?<tag>[a-zA-Z0-9_-]+)(?<attrs>[^>]*)>(?<content>.*?)</\k<tag>>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        
        for match in matches {
            guard let tagRange = Range(match.range(withName: "tag"), in: text),
                  let attrsRange = Range(match.range(withName: "attrs"), in: text),
                  let contentRange = Range(match.range(withName: "content"), in: text) else { continue }
            
            let tag = String(text[tagRange]).lowercased()
            guard targetTags.contains(tag) else { continue }
            
            let rawAttrs = String(text[attrsRange])
            let content = String(text[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let attrs = Self.parseAttributes(from: rawAttrs)
            
            let block = GenericTagBlock(tagName: tag, attributes: attrs, innerContent: content)
            
            // 归集至复合主键分面槽位：同名 Key 增量覆写更新，异名 Key 稳固并列共存
            let slotKey = block.primarySlotKey
            stateSlots[slotKey] = content
        }
    }
    
    /// 解析属性字符串，例如 role="林婉" type="character"
    private static func parseAttributes(from raw: String) -> [String: String] {
        var dict: [String: String] = [:]
        let attrPattern = #"([a-zA-Z0-9_-]+)=["']([^"']*)["']"#
        guard let regex = try? NSRegularExpression(pattern: attrPattern, options: []) else { return dict }
        let nsRaw = raw as NSString
        let matches = regex.matches(in: raw, options: [], range: NSRange(location: 0, length: nsRaw.length))
        for m in matches {
            if let kRange = Range(m.range(at: 1), in: raw),
               let vRange = Range(m.range(at: 2), in: raw) {
                let k = String(raw[kRange]).lowercased()
                let v = String(raw[vRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                dict[k] = v
            }
        }
        return dict
    }
    
    /// 按照业务语义优先级排版输出为 Markdown 视图，供大模型作为 Scratchpad 抬头读取
    func formattedMarkdown() -> String {
        guard !stateSlots.isEmpty else { return "" }
        var sections: [String] = ["## 状态基准底账 (Baseline Scratchpad)"]
        
        let sortedKeys = stateSlots.keys.sorted { k1, k2 in
            func priority(of key: String) -> Int {
                if key.contains("world_gateway") { return 0 }
                if key.contains("角色档案") || (!key.contains("瞬态契约") && !key.contains("结算记录")) { return 1 }
                if key.contains("瞬态契约") { return 2 }
                if key.contains("结算记录") { return 3 }
                return 4
            }
            let p1 = priority(of: k1)
            let p2 = priority(of: k2)
            if p1 != p2 { return p1 < p2 }
            return k1 < k2
        }
        
        for slotKey in sortedKeys {
            if let content = stateSlots[slotKey] {
                sections.append("### \(slotKey)\n\(content)")
            }
        }
        sections.append("## 状态校验\n- Buffer_Check: Pass (基准已同步)")
        return sections.joined(separator: "\n\n")
    }
}

// MARK: - ==================== 4. Structured Tag Plugin (结构化标签拦截器插件实现) ====================

/// 默认装配的结构化标签插件：负责对 <card>、<state> 等标签进行历史折叠脱敏与底账原子持久化
struct StructuredTagContextPlugin: AgentContextInterceptor, Sendable {
    let identifier: String = "StructuredTagContextPlugin"
    let priority: Int = 10
    
    static let structuredSlotsJsonKey = "AGENT_STRUCTURED_SLOTS_JSON"
    static let scratchpadKey = "AGENT_SCRATCHPAD"
    
    /// 核心单例内存底账：确保跨轮次、跨 Actor 调度时插槽单调递增，绝不丢槽
    private static var sharedRegistry = GenericTagBlockRegistry()
    
    public static var currentScratchpadMarkdown: String? {
        sharedRegistry.isEmpty ? nil : sharedRegistry.formattedMarkdown()
    }
    
    public static var currentSlotsJSON: String? {
        sharedRegistry.isEmpty ? nil : sharedRegistry.toJSONString()
    }
    
    public static func resetRegistry() {
        sharedRegistry = GenericTagBlockRegistry()
    }
    
    init() {}
    
    /// 净化历史：将已落盘的标签块折叠为 HTML 静默注释，释放 Attention 视界，防止模型模仿
    func sanitizeHistory(text: String) -> String {
        guard text.contains("<card") || text.contains("<state") else { return text }
        return text.replacingOccurrences(
            of: #"(?s)<(?:card|state)\b[^>]*>.*?</(?:card|state)>"#,
            with: "<!-- state_synced -->",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// 捕获生成：提取当前轮次模型输出的卡片并原子合并到底账中，多槽位永远并列共存
    func ingestEmitted(text: String, sharedContext: inout [String: String]) {
        guard text.contains("<card") || text.contains("<state") else { return }
        
        // 增量吞噬当前轮次最新生成的卡片 (复合主键自动实现异名共存、同名更新)
        Self.sharedRegistry.ingest(text: text)
        
        if !Self.sharedRegistry.isEmpty {
            let json = Self.sharedRegistry.toJSONString()
            let md = Self.sharedRegistry.formattedMarkdown()
            
            sharedContext[Self.structuredSlotsJsonKey] = json
            sharedContext[Self.scratchpadKey] = md
            
            // 双向安全同步至 AgentManager 运行时
            AgentManager.shared.agentVM.sharedContext[Self.structuredSlotsJsonKey] = json
            AgentManager.shared.agentVM.sharedContext[Self.scratchpadKey] = md
        }
    }
    
    /// 历史自愈：扫描历史会话中的全部卡片按时序重建物理底账
    func restoreFromHistory(messages: [ChatMessage], sharedContext: inout [String: String]) {
        Self.sharedRegistry = GenericTagBlockRegistry()
        for msg in messages where !msg.isUser && (msg.text.contains("<card") || msg.text.contains("<state")) {
            Self.sharedRegistry.ingest(text: msg.text)
        }
        if !Self.sharedRegistry.isEmpty {
            let json = Self.sharedRegistry.toJSONString()
            let md = Self.sharedRegistry.formattedMarkdown()
            sharedContext[Self.structuredSlotsJsonKey] = json
            sharedContext[Self.scratchpadKey] = md
            AgentManager.shared.agentVM.sharedContext[Self.structuredSlotsJsonKey] = json
            AgentManager.shared.agentVM.sharedContext[Self.scratchpadKey] = md
        }
    }
}
