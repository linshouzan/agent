//////////////////////////////////////////////////////////////////
// 文件名：LLMService.swift
// 文件说明：这是适用于 macos 14+ 的大模型服务调用方法
// 关联说明：ConfigManager为配置存储管理对应的通知也已另外定义，不需要补充定义
// 代码要求：请保证代码的逻辑和完整性，保留代码中的所有注释内容
// 核心架构及升级功能说明：
// 1. 彻底修复 Gemma 4 / Gemini 推理模型流式响应的“思维链被截断洗白”恶疾。
// 2. 网络层原子分流：从源头解析 "thought": true 协议并转化为 .reasoning 事件投递。
// 3. 完美兼容 Swift 6 Strict Concurrency 模式，规避跨线程闭包数据竞争。
// 4. 端到端透传 Gemini thought_signature 防篡改数字签名，彻底杜绝 HTTP 400 拒服。
//////////////////////////////////////////////////////////////////

import SwiftUI
import Foundation
import Combine
import UniformTypeIdentifiers
import AppKit
import QuickLookThumbnailing
import PDFKit

// MARK: - 1. 协议定义 (Protocol Definition)

protocol LLMProtocolAdapter: Sendable {
    var protocolType: String { get }
    
    func buildURLRequest(
        host: String,
        model: String,
        apiKey: String,
        messages: [ContextMessage],
        images: [NSImage],
        fileURLs: [URL],
        instruction: String,
        activeSkills: [AgentSkill],
        isthink: Bool
    ) throws -> URLRequest
    
    func parseSSEPayload(json: [String: Any]) -> [LLMRawEvent]
}

// MARK: - 2. 策略工厂 (Adapter Registry)

final class LLMAdapterFactory: @unchecked Sendable {
    static let shared = LLMAdapterFactory()
    
    private var adapters: [String: LLMProtocolAdapter] = [:]
    
    private init() {
        register(OpenAIProtocolAdapter())
        register(GeminiProtocolAdapter())
        register(OllamaProtocolAdapter())
    }
    
    func register(_ adapter: LLMProtocolAdapter) {
        adapters[adapter.protocolType.lowercased()] = adapter
    }
    
    func adapter(for protocolType: String) -> LLMProtocolAdapter {
        adapters[protocolType.lowercased()] ?? adapters["openai"]!
    }
}

// MARK: - 3. Google Gemini 协议适配器

struct GeminiProtocolAdapter: LLMProtocolAdapter {
    let protocolType: String = "gemini"
    
    func buildURLRequest(
        host: String,
        model: String,
        apiKey: String,
        messages: [ContextMessage],
        images: [NSImage],
        fileURLs: [URL],
        instruction: String,
        activeSkills: [AgentSkill],
        isthink: Bool
    ) throws -> URLRequest {
        let apiVersion = (model.contains("exp") || model.contains("preview")) ? "v1alpha" : "v1beta"
        guard let url = URL(string: "\(host)/\(apiVersion)/models/\(model):streamGenerateContent?alt=sse&key=\(apiKey)") else {
            throw NSError(domain: "GeminiAdapter", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 Gemini 接口地址"])
        }
        
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("keep-alive", forHTTPHeaderField: "Connection")
        
        var contents: [[String: Any]] = []
        let userMessagesCount = messages.filter { $0.role == .user }.count
        var currentUserIndex = 0
        
        for msg in messages {
            var currentParts: [[String: Any]] = []
            var targetRole = "user"
            
            switch msg.role {
            case .user, .system:
                targetRole = "user"
                if let text = msg.content, !text.isEmpty {
                    currentParts.append(["text": text])
                }
                
                if msg.role == .user {
                    currentUserIndex += 1
                    if currentUserIndex == userMessagesCount {
                        for img in images {
                            if let base64 = img.toBase64JPEG() {
                                currentParts.append(["inlineData": ["mimeType": "image/jpeg", "data": base64]])
                            }
                        }
                        for fileURL in fileURLs where fileURL.pathExtension.lowercased() == "pdf" {
                            if let fileData = try? Data(contentsOf: fileURL) {
                                currentParts.append(["inlineData": ["mimeType": "application/pdf", "data": fileData.base64EncodedString()]])
                            }
                        }
                    }
                }
                
            case .assistant:
                targetRole = "model"
                if let text = msg.content, !text.isEmpty {
                    currentParts.append(["text": text])
                }
                if let toolCalls = msg.toolCalls {
                    for call in toolCalls {
                        let argsDict = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
                        var functionCallPart: [String: Any] = [
                            "functionCall": [
                                "name": call.name,
                                "args": argsDict
                            ]
                        ]
                        if let signature = call.thoughtSignature, !signature.isEmpty {
                            functionCallPart["thoughtSignature"] = signature
                            functionCallPart["thought_signature"] = signature
                        }
                        currentParts.append(functionCallPart)
                    }
                }
                
            case .tool:
                targetRole = "user"
                if let name = msg.name, let content = msg.content {
                    var responseObj: Any = ["result": content]
                    if let data = content.data(using: .utf8), let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        responseObj = dict
                    }
                    currentParts.append(["functionResponse": ["name": name, "response": responseObj]])
                }
            }
            
            guard !currentParts.isEmpty else { continue }
            
            if let lastIndex = contents.indices.last, contents[lastIndex]["role"] as? String == targetRole {
                var existingParts = contents[lastIndex]["parts"] as? [[String: Any]] ?? []
                existingParts.append(contentsOf: currentParts)
                contents[lastIndex]["parts"] = existingParts
            } else {
                contents.append(["role": targetRole, "parts": currentParts])
            }
        }
        
        var requestBody: [String: Any] = ["contents": contents]
        if !instruction.isEmpty {
            requestBody["systemInstruction"] = ["parts": [["text": instruction]]]
        }
        
        if !activeSkills.isEmpty {
            // 🌟 确定性字典序排列，确保 Tools Schema 签名绝对一致
            let sortedSkills = activeSkills.sorted { $0.name.lowercased() < $1.name.lowercased() }
            let declarations = sortedSkills.map { $0.toFunctionDeclaration() }
            requestBody["tools"] = [["functionDeclarations": declarations]]
            requestBody["toolConfig"] = ["functionCallingConfig": ["mode": "AUTO"]]
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        return request
    }
    
    func parseSSEPayload(json: [String: Any]) -> [LLMRawEvent] {
        var events: [LLMRawEvent] = []
        
        if let usageMeta = json["usageMetadata"] as? [String: Any], let total = usageMeta["totalTokenCount"] as? Int {
            events.append(.usage(total))
        }
        
        guard let candidates = json["candidates"] as? [[String: Any]], let firstCandidate = candidates.first else {
            return events
        }
        
        if let finishReason = firstCandidate["finishReason"] as? String,
           ["PROHIBITED_CONTENT", "SAFETY", "SPII", "OTHER"].contains(finishReason) {
            events.append(.text("\n\n> 🛡️ **[AI 核心安全审查提示]**: 触发了 Google 合规审查政策（`\(finishReason)`）。"))
            return events
        }
        
        if let content = firstCandidate["content"] as? [String: Any],
           let parts = content["parts"] as? [[String: Any]] {
            for part in parts {
                if let text = part["text"] as? String, !text.isEmpty {
                    let isThought = part["thought"] as? Bool ?? false
                    let reasoningContent = part["reasoning_content"] as? String
                    if isThought || reasoningContent != nil {
                        events.append(.reasoning(reasoningContent ?? text))
                    } else {
                        events.append(.text(text))
                    }
                } else if let functionCall = part["functionCall"] as? [String: Any] {
                    let name = functionCall["name"] as? String ?? ""
                    let args = functionCall["args"] as? [String: Any] ?? [:]
                    let signature = (part["thoughtSignature"] as? String)
                        ?? (part["thought_signature"] as? String)
                        ?? (functionCall["thoughtSignature"] as? String)
                        ?? (functionCall["thought_signature"] as? String)
                    
                    events.append(.toolCall(id: UUID().uuidString, name: name, args: args, thoughtSignature: signature))
                }
            }
        }
        return events
    }
}

// MARK: - 4. OpenAI / 通用兼容协议适配器

struct OpenAIProtocolAdapter: LLMProtocolAdapter {
    let protocolType: String = "openai"
    
    func buildURLRequest(
        host: String,
        model: String,
        apiKey: String,
        messages: [ContextMessage],
        images: [NSImage],
        fileURLs: [URL],
        instruction: String,
        activeSkills: [AgentSkill],
        isthink: Bool
    ) throws -> URLRequest {
        let finalHost = host.isEmpty ? "https://api.openai.com/v1/chat/completions" : host
        guard let url = URL(string: finalHost) else {
            throw NSError(domain: "OpenAIAdapter", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 API 接口地址"])
        }
        
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("keep-alive", forHTTPHeaderField: "Connection")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        var apiMessages: [[String: Any]] = []
        if !instruction.isEmpty { apiMessages.append(["role": "system", "content": instruction]) }
        
        let userMessagesCount = messages.filter { $0.role == .user }.count
        var currentUserIndex = 0
        
        for msg in messages {
            switch msg.role {
            case .system:
                if let text = msg.content, !text.isEmpty {
                    apiMessages.append(["role": "system", "content": text])
                }
            case .user:
                currentUserIndex += 1
                if currentUserIndex == userMessagesCount && !images.isEmpty {
                    var contentArray: [[String: Any]] = []
                    if let text = msg.content, !text.isEmpty {
                        contentArray.append(["type": "text", "text": text])
                    }
                    for img in images {
                        if let base64 = img.toBase64JPEG() {
                            contentArray.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64)"]])
                        }
                    }
                    apiMessages.append(["role": "user", "content": contentArray])
                } else if let text = msg.content, !text.isEmpty {
                    apiMessages.append(["role": "user", "content": text])
                }
            case .assistant:
                var dict: [String: Any] = ["role": "assistant"]
                if let text = msg.content, !text.isEmpty { dict["content"] = text }
                if let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                    dict["tool_calls"] = toolCalls.map { call in
                        [
                            "id": call.id,
                            "type": "function",
                            "function": [
                                "name": call.name,
                                "arguments": call.arguments
                            ]
                        ]
                    }
                }
                apiMessages.append(dict)
            case .tool:
                apiMessages.append([
                    "role": "tool",
                    "tool_call_id": msg.toolCallId ?? "",
                    "content": msg.content ?? "{\"status\": \"ok\"}"
                ])
            }
        }
        
        var requestBody: [String: Any] = [
            "model": model,
            "messages": apiMessages,
            "stream": true,
            "stream_options": ["include_usage": true]
        ]
        
        if isthink {
            requestBody["think"] = true
        }
        
        if !activeSkills.isEmpty {
            // 🌟 确定性字典序排列
            let sortedSkills = activeSkills.sorted { $0.name.lowercased() < $1.name.lowercased() }
            requestBody["tools"] = sortedSkills.map { ["type": "function", "function": $0.toFunctionDeclaration()] }
            requestBody["tool_choice"] = "auto"
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        return request
    }
    
    func parseSSEPayload(json: [String: Any]) -> [LLMRawEvent] {
        var events: [LLMRawEvent] = []
        
        if let usage = json["usage"] as? [String: Any], let total = usage["total_tokens"] as? Int {
            events.append(.usage(total))
        }
        
        if let choices = json["choices"] as? [[String: Any]], let firstChoice = choices.first {
            let delta = (firstChoice["delta"] as? [String: Any]) ?? (firstChoice["message"] as? [String: Any]) ?? [:]
            
            if let reasoningText = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String), !reasoningText.isEmpty {
                events.append(.reasoning(reasoningText))
            }
            
            if let content = delta["content"] as? String, !content.isEmpty {
                events.append(.text(content))
            }
            
            if let toolCalls = delta["tool_calls"] as? [[String: Any]], let firstCall = toolCalls.first,
               let function = firstCall["function"] as? [String: Any] {
                let id = firstCall["id"] as? String ?? UUID().uuidString
                let name = function["name"] as? String ?? ""
                let argsStr = function["arguments"] as? String ?? "{}"
                let argsDict = (try? JSONSerialization.jsonObject(with: Data(argsStr.utf8))) as? [String: Any] ?? [:]
                events.append(.toolCall(id: id, name: name, args: argsDict, thoughtSignature: nil))
            }
        }
        return events
    }
}

// MARK: - 5. Ollama 本地协议适配器

struct OllamaProtocolAdapter: LLMProtocolAdapter {
    let protocolType: String = "ollama"
    
    func buildURLRequest(
        host: String,
        model: String,
        apiKey: String,
        messages: [ContextMessage],
        images: [NSImage],
        fileURLs: [URL],
        instruction: String,
        activeSkills: [AgentSkill],
        isthink: Bool
    ) throws -> URLRequest {
        let finalHost = host.isEmpty ? "http://127.0.0.1:11434/api/chat" : host
        guard let url = URL(string: finalHost) else {
            throw NSError(domain: "OllamaAdapter", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 Ollama 接口地址"])
        }
        
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var ollamaMessages: [[String: Any]] = []
        if !instruction.isEmpty { ollamaMessages.append(["role": "system", "content": instruction]) }
        
        for msg in messages {
            var dict: [String: Any] = ["role": msg.role.rawValue, "content": msg.content ?? ""]
            if msg.role == .user && !images.isEmpty {
                dict["images"] = images.compactMap { $0.toBase64JPEG() }
            }
            ollamaMessages.append(dict)
        }
        
        let requestBody: [String: Any] = [
            "model": model,
            "messages": ollamaMessages,
            "stream": true
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        return request
    }
    
    func parseSSEPayload(json: [String: Any]) -> [LLMRawEvent] {
        var events: [LLMRawEvent] = []
        if let message = json["message"] as? [String: Any], let content = message["content"] as? String, !content.isEmpty {
            events.append(.text(content))
        }
        return events
    }
}

// MARK: - 6. 辅助能力扩展

private extension NSImage {
    func toBase64JPEG() -> String? {
        guard let tiff = self.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            return nil
        }
        return data.base64EncodedString()
    }
}

private extension AgentSkill {
    func toFunctionDeclaration() -> [String: Any] {
        var properties: [String: Any] = [:]
        var required: [String] = []
        
        for param in self.parameters {
            var mappedType = param.type.rawValue.lowercased()
            if mappedType == "enum" { mappedType = "string" }
            
            var paramDef: [String: Any] = ["type": mappedType, "description": param.description]
            if mappedType == "object" {
                paramDef["properties"] = [String: Any]()
                paramDef["additionalProperties"] = true
            } else if mappedType == "array" {
                paramDef["items"] = ["type": "string"]
            }
            properties[param.name] = paramDef
            if param.isRequired { required.append(param.name) }
        }
        
        return [
            "name": self.name,
            "description": self.description,
            "parameters": [
                "type": "object",
                "properties": properties,
                "required": required
            ]
        ]
    }
}

public enum MessageRole: String, Codable, Sendable {
    case system = "system"
    case user = "user"
    case assistant = "assistant"
    case tool = "tool"
}

// MARK: - 升级 LLMToolCall：携带 Google Gemini 的 thoughtSignature 凭据
public struct LLMToolCall: Codable, Equatable, Sendable {
    public var id: String
    public var type: String = "function"
    public var name: String
    public var arguments: String // 标准 JSON 字符串
    public var thoughtSignature: String? // Google Gemini 防篡改加密签名
    
    public init(id: String, name: String, arguments: String, thoughtSignature: String? = nil) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.thoughtSignature = thoughtSignature
    }
}

/// 标准化的上下文消息对象，彻底替代扁平化的 String
public struct ContextMessage: Codable, Equatable, Sendable {
    public var role: MessageRole
    public var content: String?
    
    // 用于 assistant 角色发起调用
    public var toolCalls: [LLMToolCall]?
    
    // 用于 tool 角色返回结果
    public var toolCallId: String?
    public var name: String?
    
    public init(role: MessageRole, content: String? = nil, toolCalls: [LLMToolCall]? = nil, toolCallId: String? = nil, name: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.name = name
    }
    
    public static func user(_ text: String) -> ContextMessage { ContextMessage(role: .user, content: text) }
    public static func system(_ text: String) -> ContextMessage { ContextMessage(role: .system, content: text) }
    public static func assistant(text: String? = nil, toolCalls: [LLMToolCall]? = nil) -> ContextMessage { ContextMessage(role: .assistant, content: text, toolCalls: toolCalls) }
    public static func tool(id: String, name: String, result: String) -> ContextMessage { ContextMessage(role: .tool, content: result, toolCallId: id, name: name) }
}

/// 底层网络请求的原子事件封装
enum LLMRawEvent {
    case text(String)
    case reasoning(String)
    case toolCall(id: String, name: String, args: [String: Any], thoughtSignature: String?)
    case usage(Int)
}

// MARK: - ==========================================
// MARK: LLM Service (彻底解耦版：结构化网络流客户端)
// MARK: ==========================================
final class LLMService: NSObject, @unchecked Sendable, URLSessionDelegate {
    
    static let shared = LLMService()
    
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    
    private override init() {
        super.init()
    }
    
    // MARK: - 辅助解析方法
    
    private func getBase64(from image: NSImage) -> String? {
        guard let tiffRepresentation = image.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffRepresentation),
              let data = bitmapImage.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            return nil
        }
        return data.base64EncodedString().replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
    }
    
    private func extractTextContent(from url: URL) async -> String? {
        let ext = url.pathExtension.lowercased()
        
        // 1. 复杂排版文档优先尝试 Docling 高保真结构化解析 (表格/标题树保留)
        if ["pdf", "docx", "doc", "pptx", "xlsx"].contains(ext) {
            if let structuredMarkdown = try? await DoclingBridge.parseTo(fileURL: url),
               !structuredMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return structuredMarkdown
            }
        }
        
        // 2. 降级：系统原生解析规则兜底
        return extractNativeTextContent(from: url, ext: ext)
    }
    
    private func extractNativeTextContent(from url: URL, ext: String) -> String? {
        if ext == "pdf", let pdf = PDFDocument(url: url) {
            return (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
        }
        if ["txt", "csv", "md", "json", "swift", "py", "js"].contains(ext) {
            let encodings: [String.Encoding] = [.utf8, .ascii, .isoLatin1, .macOSRoman]
            for encoding in encodings {
                if let text = try? String(contentsOf: url, encoding: encoding) { return text }
            }
        }
        do {
            var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
            if ext == "docx" { options[.documentType] = NSAttributedString.DocumentType.officeOpenXML }
            else if ext == "doc" { options[.documentType] = NSAttributedString.DocumentType.docFormat }
            else if ext == "rtf" { options[.documentType] = NSAttributedString.DocumentType.rtf }
            
            let attrString = try NSAttributedString(url: url, options: options, documentAttributes: nil)
            let extractedText = attrString.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return extractedText.isEmpty ? nil : extractedText
        } catch {
            return nil
        }
    }
    
    // MARK: - 单次请求
    
    func askSimple(prompt: String, model: String = "", images: [NSImage] = [], fileURLs: [URL] = [], instruction: String = "", activeSkills: [AgentSkill] = []) async -> String {
        do {
            let stream = await ask(messages: [ContextMessage.user(prompt)], model: model, images: images, fileURLs: fileURLs, instruction: instruction, activeSkills: activeSkills)
            var response = ""
            for try await step in stream {
                if case .textDelta(let t) = step { response += t }
            }
            return response
        } catch {
            print("❌ 调用模型失败: \(error.localizedDescription)")
            return ""
        }
    }
    
    // MARK: - 单轮纯粹的 LLM 流式请求方法
    
    func ask(
        messages: [ContextMessage],
        model: String = "",
        images: [NSImage] = [],
        fileURLs: [URL] = [],
        instruction: String = "",
        activeSkills: [AgentSkill] = []
    ) -> AsyncThrowingStream<AgentStep, Error> {
        
        var resolvedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if resolvedModel.isEmpty {
            let appConfig = ConfigManager.shared.app
            let defaultAgentID = appConfig.generalConfig.defaultAgentID
            if let defaultAgent = appConfig.agentProfiles.first(where: { $0.id == defaultAgentID }) {
                resolvedModel = defaultAgent.baseModel
            } else if let firstAgent = appConfig.agentProfiles.first {
                resolvedModel = firstAgent.baseModel
            }
        }
        
        guard let config = ConfigManager.shared.app.aiConfigs.first(where: { $0.models.contains(resolvedModel) }) else {
            return AsyncThrowingStream<AgentStep, Error> { $0.yield(.error("❌ [网络通道阻断]: 找不到模型 '\(resolvedModel)' 配置。")); $0.finish() }
        }
        
        let hostConfig = config.isagent ? config.agenthost : config.host
        let apiKey = config.apikey.isEmpty ? "sk-local-token" : config.apikey
        let protocolType = config.protocolType.lowercased()
        
        return AsyncThrowingStream<AgentStep, Error> { continuation in
            let requestTask = Task { @MainActor in
                
                // 若当前没有处于活动 Session（说明是单线程独立调用），自动创建单次 LLM 卡片
                var autoCreatedSessionID: UUID? = nil
                if LogManager.shared.activeContextID == nil {
                    let userQuery = messages.last(where: { $0.role == .user })?.content ?? "单次模型请求"
                    autoCreatedSessionID = LogManager.shared.startSession(
                        query: userQuery,
                        agentName: resolvedModel,
                        category: .singleLLM
                    )
                }
                
                let parentContextID = LogManager.shared.activeContextID
                var finalMessages = messages
                var injectedContext = ""
                
                for fileURL in fileURLs {
                    if protocolType == "gemini" && fileURL.pathExtension.lowercased() == "pdf" { continue }
                    if let documentText = await self.extractTextContent(from: fileURL) {
                        injectedContext += "\n\n--- [附带文件: \(fileURL.lastPathComponent)] ---\n\(documentText)\n"
                    }
                }
                
                if !injectedContext.isEmpty, let lastIdx = finalMessages.lastIndex(where: { $0.role == .user }) {
                    finalMessages[lastIdx].content = (finalMessages[lastIdx].content ?? "") + injectedContext
                }
                
                var accumulatedResponse = ""
                var isSuccess = false
                var errorSummary: String? = nil
                
                defer {
                    if let sessionID = autoCreatedSessionID {
                        LogManager.shared.endSession(
                            sessionID: sessionID,
                            isSuccess: isSuccess,
                            detail: isSuccess ? accumulatedResponse : errorSummary
                        )
                    }
                }
                
                do {
                    let finalHost = (protocolType == "openai" && hostConfig.isEmpty) ? "http://127.0.0.1:11434/v1/chat/completions" : hostConfig
                    
                    let rawStream = try await self.fetchRawStream(
                        protocolType: protocolType,
                        messages: finalMessages,
                        images: images,
                        fileURLs: fileURLs,
                        model: resolvedModel,
                        apiKey: apiKey,
                        host: finalHost,
                        instruction: instruction,
                        activeSkills: activeSkills,
                        isthink: config.isthink,
                        parentLogID: parentContextID
                    )
                    
                    var reasoningTriggered = false
                    
                    for try await event in rawStream {
                        if Task.isCancelled { break }
                        
                        switch event {
                        case .text(let t):
                            if reasoningTriggered {
                                continuation.yield(.reasoningDone)
                                reasoningTriggered = false
                            }
                            accumulatedResponse += t
                            continuation.yield(.textDelta(t))
                            
                        case .reasoning(let r):
                            reasoningTriggered = true
                            continuation.yield(.reasoningDelta(r))
                            
                        case .toolCall(let id, let name, let args, let thoughtSignature):
                            if reasoningTriggered {
                                continuation.yield(.reasoningDone)
                                reasoningTriggered = false
                            }
                            continuation.yield(.toolCallInfo(id: id, name: name, args: args, thoughtSignature: thoughtSignature))
                            
                        case .usage(let tokens):
                            continuation.yield(.usageUpdate(tokens))
                            if let pid = parentContextID {
                                LogManager.shared.updateTokens(nodeID: pid, tokens: tokens)
                            }
                        }
                    }
                    
                    if reasoningTriggered { continuation.yield(.reasoningDone) }
                    isSuccess = true
                    continuation.yield(.done)
                    continuation.finish()
                    
                } catch {
                    if !(error is CancellationError) {
                        let readableErrMsg = error.localizedDescription
                        errorSummary = readableErrMsg
                        LogManager.shared.error("❌ 模型响应中断", detail: readableErrMsg, parentID: parentContextID)
                        continuation.yield(.error(readableErrMsg))
                        continuation.finish(throwing: error)
                    }
                    continuation.finish()
                }
            }
            
            continuation.onTermination = { _ in requestTask.cancel() }
        }
    }
    
    // MARK: - 底层协议拆包流请求器
    
    private func fetchRawStream(
        protocolType: String,
        messages: [ContextMessage],
        images: [NSImage],
        fileURLs: [URL],
        model: String,
        apiKey: String,
        host: String,
        instruction: String,
        activeSkills: [AgentSkill],
        isthink: Bool,
        parentLogID: UUID?
    ) async throws -> AsyncThrowingStream<LLMRawEvent, Error> {
        
        let adapter = await LLMAdapterFactory.shared.adapter(for: protocolType)
        let request = try await adapter.buildURLRequest(
            host: host,
            model: model,
            apiKey: apiKey,
            messages: messages,
            images: images,
            fileURLs: fileURLs,
            instruction: instruction,
            activeSkills: activeSkills,
            isthink: isthink
        )
        
        let requestBodyString = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? "无请求体"
        
        // 挂载为当前会话树的子节点，避免泄漏到全局 root
        await MainActor.run {
            LogManager.shared.info(
                "💬 发起网络请求 [\(model)]",
                detail: requestBodyString,
                parentID: parentLogID
            )
        }
        
        let result: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (result, response) = try await session.bytes(for: request)
        } catch {
            let nsErr = error as NSError
            let friendlyMsg = (nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorTimedOut) ? "连接超时: 目标服务未在预定时间内响应。" : error.localizedDescription
            await MainActor.run { LogManager.shared.error("❌ 网络连接异常", detail: friendlyMsg, parentID: parentLogID) }
            throw error
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "LLMClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的网络响应"])
        }
        
        if !(200...299).contains(httpResponse.statusCode) {
            var errorDetail = ""
            for try await line in result.lines { errorDetail += line + "\n" }
            let finalErrorMsg = "HTTP \(httpResponse.statusCode): \(errorDetail.trimmingCharacters(in: .whitespacesAndNewlines))"
            await MainActor.run { LogManager.shared.error("❌ LLM API 拒绝服务", detail: finalErrorMsg, parentID: parentLogID) }
            throw NSError(domain: "LLMClient", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: finalErrorMsg])
        }
        
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await line in result.lines {
                        if Task.isCancelled { break }
                        var jsonString = line.trimmingCharacters(in: .whitespaces)
                        if jsonString.hasPrefix("data: ") { jsonString = String(jsonString.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
                        if jsonString == "[DONE]" || jsonString.isEmpty { continue }
                        
                        guard let data = jsonString.data(using: .utf8),
                              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        
                        let events = await adapter.parseSSEPayload(json: decoded)
                        for event in events { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    // MARK: - 结构化请求报文组装
    
    private func buildRequestBody(protocolType: String, messages: [ContextMessage], images: [NSImage], fileURLs: [URL], model: String, instruction: String, activeSkills: [AgentSkill], isthink: Bool, host: String) -> [String: Any] {
        var requestBody: [String: Any] = [:]
        let userMessagesCount = messages.filter { $0.role == .user }.count
        var currentUserIndex = 0
        
        let isOllamaNative = protocolType == "ollama"
        let isGemini = protocolType == "gemini"
        
        if isGemini {
            var contents: [[String: Any]] = []
            
            for msg in messages {
                var currentParts: [[String: Any]] = []
                var targetRole = "user"
                
                switch msg.role {
                case .user, .system:
                    targetRole = "user"
                    if let text = msg.content, !text.isEmpty {
                        currentParts.append(["text": text])
                    }
                    
                    if msg.role == .user {
                        currentUserIndex += 1
                        if currentUserIndex == userMessagesCount {
                            for img in images {
                                if let base64 = getBase64(from: img) {
                                    currentParts.append(["inlineData": ["mimeType": "image/jpeg", "data": base64]])
                                }
                            }
                            for fileURL in fileURLs where fileURL.pathExtension.lowercased() == "pdf" {
                                if let fileData = try? Data(contentsOf: fileURL) {
                                    currentParts.append(["inlineData": ["mimeType": "application/pdf", "data": fileData.base64EncodedString()]])
                                }
                            }
                        }
                    }
                    
                case .assistant:
                    targetRole = "model"
                    if let text = msg.content, !text.isEmpty {
                        currentParts.append(["text": text])
                    }
                    if let toolCalls = msg.toolCalls {
                        for call in toolCalls {
                            let argsDict = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
                            
                            // MARK: - [Modified] 向 Gemini 回传 functionCall 时原样挂载 thoughtSignature 签名
                            var functionCallPart: [String: Any] = [
                                "functionCall": [
                                    "name": call.name,
                                    "args": argsDict
                                ]
                            ]
                            
                            if let signature = call.thoughtSignature, !signature.isEmpty {
                                functionCallPart["thoughtSignature"] = signature
                                functionCallPart["thought_signature"] = signature
                            }
                            
                            currentParts.append(functionCallPart)
                        }
                    }
                    
                case .tool:
                    // Gemini v1beta 规范要求 functionResponse 节点归属于 "user" 角色
                    targetRole = "user"
                    if let name = msg.name, let content = msg.content {
                        var responseObj: Any = ["result": content]
                        if let data = content.data(using: .utf8), let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            responseObj = dict
                        }
                        currentParts.append(["functionResponse": ["name": name, "response": responseObj]])
                    }
                }
                
                guard !currentParts.isEmpty else { continue }
                
                // 自动合并同角色的连续 parts 节点，保证 user / model 严格轮替
                if let lastIndex = contents.indices.last, contents[lastIndex]["role"] as? String == targetRole {
                    var existingParts = contents[lastIndex]["parts"] as? [[String: Any]] ?? []
                    existingParts.append(contentsOf: currentParts)
                    contents[lastIndex]["parts"] = existingParts
                } else {
                    contents.append(["role": targetRole, "parts": currentParts])
                }
            }
            
            requestBody["contents"] = contents
            if !instruction.isEmpty { requestBody["systemInstruction"] = ["parts": [["text": instruction]]] }
            
        } else {
            var apiMessages: [[String: Any]] = []
            if !instruction.isEmpty { apiMessages.append(["role": "system", "content": instruction]) }
            
            for msg in messages {
                switch msg.role {
                case .system:
                    if let text = msg.content, !text.isEmpty {
                        apiMessages.append(["role": "system", "content": text])
                    }
                    
                case .user:
                    currentUserIndex += 1
                    if isOllamaNative {
                        var dict: [String: Any] = ["role": "user"]
                        dict["content"] = msg.content ?? ""
                        if currentUserIndex == userMessagesCount && !images.isEmpty {
                            var base64Images: [String] = []
                            for img in images {
                                if let base64 = self.getBase64(from: img) { base64Images.append(base64) }
                            }
                            dict["images"] = base64Images
                        }
                        apiMessages.append(dict)
                    } else {
                        var contentArray: [[String: Any]] = []
                        if let text = msg.content, !text.isEmpty {
                            contentArray.append(["type": "text", "text": text])
                        }
                        if currentUserIndex == userMessagesCount && !images.isEmpty {
                            for img in images {
                                if let base64 = self.getBase64(from: img) {
                                    contentArray.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64)"]])
                                }
                            }
                            apiMessages.append(["role": "user", "content": contentArray])
                        } else if let text = msg.content, !text.isEmpty {
                            apiMessages.append(["role": "user", "content": text])
                        }
                    }
                    
                case .assistant:
                    var dict: [String: Any] = ["role": "assistant"]
                    if let text = msg.content, !text.isEmpty { dict["content"] = text }
                    else if isOllamaNative { dict["content"] = "" }
                    
                    if let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                        let callsArray = toolCalls.compactMap { call -> [String: Any]? in
                            var safeArgsDict: [String: Any] = [:]
                            if let data = call.arguments.data(using: .utf8),
                               let parsedDict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                                safeArgsDict = parsedDict
                            }
                            
                            if isOllamaNative {
                                return ["function": ["name": call.name, "arguments": safeArgsDict]]
                            } else {
                                let argsString = String(data: (try? JSONSerialization.data(withJSONObject: safeArgsDict)) ?? Data(), encoding: .utf8) ?? "{}"
                                return ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": argsString]]
                            }
                        }
                        dict["tool_calls"] = callsArray
                    }
                    apiMessages.append(dict)
                    
                case .tool:
                    var dict: [String: Any] = ["role": "tool"]
                    let toolOutput = (msg.content == nil || msg.content!.isEmpty) ? "{\"status\": \"ok\"}" : msg.content!
                    dict["content"] = toolOutput
                    if !isOllamaNative, let callId = msg.toolCallId { dict["tool_call_id"] = callId }
                    apiMessages.append(dict)
                }
            }
            
            requestBody["model"] = model
            if protocolType == "chatgpt" { requestBody["input"] = apiMessages }
            else { requestBody["messages"] = apiMessages }
            requestBody["stream"] = true
            
            if !isOllamaNative && protocolType != "chatgpt" {
                requestBody["think"] = isthink
                requestBody["stream_options"] = ["include_usage": true]
            }
        }
        
        if !activeSkills.isEmpty {
            var functionDeclarations: [[String: Any]] = []
            for skill in activeSkills {
                var properties: [String: Any] = [:]
                var required: [String] = []
                for param in skill.parameters {
                    var mappedType = param.type.rawValue.lowercased()
                    if mappedType == "enum" { mappedType = "string" }
                    
                    var paramDef: [String: Any] = ["type": mappedType, "description": param.description]
                    if mappedType == "object" {
                        paramDef["properties"] = [String: Any]()
                        paramDef["additionalProperties"] = true
                    } else if mappedType == "array" {
                        if param.name == "tasks" {
                            paramDef["items"] = [
                                "type": "object",
                                "properties": [
                                    "id": ["type": "string", "description": "任务节点 ID"],
                                    "text": ["type": "string", "description": "任务描述"],
                                    "status": ["type": "string", "description": "填: '等待中'"]
                                ],
                                "required": ["id", "text", "status"]
                            ]
                        } else {
                            paramDef["items"] = ["type": "string"]
                        }
                    }
                    properties[param.name] = paramDef
                    if param.isRequired { required.append(param.name) }
                }
                
                let functionDict: [String: Any] = [
                    "name": skill.name,
                    "description": skill.description,
                    "parameters": ["type": "object", "properties": properties, "required": required]
                ]
                functionDeclarations.append(functionDict)
            }
            
            if isGemini {
                requestBody["tools"] = [["functionDeclarations": functionDeclarations]]
                requestBody["toolConfig"] = ["functionCallingConfig": ["mode": "AUTO"]]
            } else {
                requestBody["tools"] = functionDeclarations.map { ["type": "function", "function": $0] }
                requestBody["tool_choice"] = "auto"
            }
        }
        
        return requestBody
    }
    
    // MARK: - 🎯 核心 SSL/TLS 质询无条件放行拦截器 (全局统一 SSL 放行出口)
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            
            let basicPolicy = SecPolicyCreateBasicX509()
            SecTrustSetPolicies(serverTrust, basicPolicy)
            
            if let certChain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate], !certChain.isEmpty {
                SecTrustSetAnchorCertificates(serverTrust, certChain as CFArray)
                SecTrustSetAnchorCertificatesOnly(serverTrust, false)
            }
            
            var evalError: CFError?
            if !SecTrustEvaluateWithError(serverTrust, &evalError) {
                if let exceptions = SecTrustCopyExceptions(serverTrust) {
                    SecTrustSetExceptions(serverTrust, exceptions)
                }
            }
            
            _ = SecTrustEvaluateWithError(serverTrust, nil)
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
