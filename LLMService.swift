//////////////////////////////////////////////////////////////////
// 文件名：LLMService.swift
// 文件说明：适用于 macOS 14+ 的大模型多协议通信引擎与流式事件分流中心 (Swift 6 Ready)
//
// 核心架构与协议调度说明：
// 1. 协议解耦与策略工厂架构 (Protocol-Oriented Adapter Pattern):
//    - 统一抽象 LLMProtocolAdapter 协议，隔离 OpenAI、Gemini (GenerateContent)、Gemini Interactions 与 Ollama 底层协议差异。
//    - LLMAdapterFactory 单例工厂动态注册与路由适配器，保持无侵入式通道扩充能力。
// 2. 新一代 Gemini Interactions 协议原生支持 (Interactions API / Typed Item Stream):
//    - 严格遵循 /v1beta/interactions 标准，将历史消息无损序列化为扁平化类型化原子项 (Typed Items: text, image, document, function_call, function_result, thought)。
//    - 支持通道级 Google 原生内置工具 (google_search, url_context, code_execution, google_maps 等) 与自定义 Function Calling 混合下发。
// 3. 流式工具分块聚合机制 (Multi-Tool Call Accumulator):
//    - 解决 SSE 流式传输中 arguments_delta 参数分块截断与提前触发执行漏洞，内存流式累加并延迟反序列化。
//    - 跨 Step 暂存并传递 thought_signature，并在上下文组装时作为独立 thought 原子项注入，确保多轮验证链闭环。
// 4. 原子级思维链分流与防截断机制 (Native Deep Thinking & Reasoning Stream):
//    - 源头拦截并分流 reasoning_content / thought / thought_delta 增量，并向 UI 投递独立的 reasoning 事件流。
// 5. 跨平台多模态高保真编排 (Multimodal Pipeline):
//    - 支持图片 Base64 编码、Docling 结构化解析降级、PDFKit 纯文本抽取与原生 Document 直传。
// 6. 健壮的网络安全与 SSL 质询拦截:
//    - 统一实现 URLSessionDelegate 质询校验，支持内网自签名证书与企业级安全网关穿透。
//////////////////////////////////////////////////////////////////

import SwiftUI
import Foundation
import Combine
import UniformTypeIdentifiers
import AppKit
import QuickLookThumbnailing
import PDFKit

// MARK: - ==================== 1. 协议定义 (Protocol Definition) ====================

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

// MARK: - ==================== 2. 策略工厂 (Adapter Registry) ====================

final class LLMAdapterFactory: @unchecked Sendable {
    static let shared = LLMAdapterFactory()
    
    private var adapters: [String: LLMProtocolAdapter] = [:]
    
    private init() {
        register(OpenAIProtocolAdapter())
        register(GeminiProtocolAdapter())
        register(GeminiInteractionsProtocolAdapter())
        register(OllamaProtocolAdapter())
    }
    
    func register(_ adapter: LLMProtocolAdapter) {
        adapters[adapter.protocolType.lowercased()] = adapter
    }
    
    func adapter(for protocolType: String) -> LLMProtocolAdapter {
        adapters[protocolType.lowercased()] ?? adapters["openai"]!
    }
}

// MARK: - ==================== 3. Google Gemini 传统流式协议适配器 (generateContent) ====================

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
        let baseHost = host.isEmpty ? "https://generativelanguage.googleapis.com" : host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(baseHost)/\(apiVersion)/models/\(model):streamGenerateContent?alt=sse&key=\(apiKey)") else {
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
            let sortedSkills = activeSkills.sorted { $0.name.lowercased() < $1.name.lowercased() }
            let declarations = sortedSkills.map { $0.toFunctionDeclaration(isGemini: true) }
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

// MARK: - ==================== 3.1 Google Gemini Interactions 协议适配器 (Interactions API) ====================

struct GeminiInteractionsProtocolAdapter: LLMProtocolAdapter {
    let protocolType: String = "interactions"
    
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
        let baseHost = host.isEmpty ? "https://generativelanguage.googleapis.com" : host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpointString: String
        if baseHost.contains("/interactions") {
            endpointString = baseHost
        } else {
            endpointString = "\(baseHost)/v1beta/interactions"
        }
        
        guard let url = URL(string: endpointString) else {
            throw NSError(domain: "GeminiInteractionsAdapter", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 Interactions API 接口地址"])
        }
        
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("keep-alive", forHTTPHeaderField: "Connection")
        request.addValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        
        // 1. 将上下文多轮历史转换为 Interactions 标准原子项列表
        var inputItems: [[String: Any]] = []
        let userMessagesCount = messages.filter { $0.role == .user }.count
        var currentUserIndex = 0
        
        for msg in messages {
            switch msg.role {
            case .system:
                if let text = msg.content, !text.isEmpty {
                    inputItems.append([
                        "type": "text",
                        "text": "【系统指引】: \(text)"
                    ])
                }
                
            case .user:
                currentUserIndex += 1
                if let text = msg.content, !text.isEmpty {
                    inputItems.append([
                        "type": "text",
                        "text": text
                    ])
                }
                
                if currentUserIndex == userMessagesCount {
                    for img in images {
                        if let base64 = img.toBase64JPEG() {
                            inputItems.append([
                                "type": "image",
                                "data": base64,
                                "mime_type": "image/jpeg"
                            ])
                        }
                    }
                    for fileURL in fileURLs where fileURL.pathExtension.lowercased() == "pdf" {
                        if let fileData = try? Data(contentsOf: fileURL) {
                            inputItems.append([
                                "type": "document",
                                "data": fileData.base64EncodedString(),
                                "mime_type": "application/pdf"
                            ])
                        }
                    }
                }
                
            case .assistant:
                if let text = msg.content, !text.isEmpty {
                    inputItems.append([
                        "type": "text",
                        "text": text
                    ])
                }
                
                if let toolCalls = msg.toolCalls {
                    for tc in toolCalls {
                        // 🌟 若存在加密思维链签名，作为独立的 thought 项在 function_call 前先行注入
                        if let sig = tc.thoughtSignature, !sig.isEmpty {
                            inputItems.append([
                                "type": "thought",
                                "signature": sig
                            ])
                        }
                        
                        let argsDict = (try? JSONSerialization.jsonObject(with: Data(tc.arguments.utf8))) as? [String: Any] ?? [:]
                        let fcItem: [String: Any] = [
                            "type": "function_call",
                            "name": tc.name,
                            "arguments": argsDict
                        ]
                        inputItems.append(fcItem)
                    }
                }
                
            case .tool:
                var resultData: Any = [:]
                if let content = msg.content,
                   let data = content.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    resultData = parsed
                } else {
                    resultData = ["output": msg.content ?? "ok"]
                }
                
                let frItem: [String: Any] = [
                    "type": "function_result",
                    "name": msg.name ?? "",
                    "result": resultData
                ]
                inputItems.append(frItem)
            }
        }
        
        if inputItems.isEmpty {
            inputItems.append(["type": "text", "text": ""])
        }
        
        var requestBody: [String: Any] = [
            "model": model,
            "input": inputItems,
            "stream": true
        ]
        
        if !instruction.isEmpty {
            requestBody["system_instruction"] = instruction
        }
        
        // 2. 混合装配 Google 原生内置工具与自定义 Function Calling
        var toolDeclarations: [[String: Any]] = []
        
        // A. 挂载通道级别的 Google 原生内置工具 (google_search, url_context, code_execution 等)
        if let currentConfig = ConfigManager.shared.app.aiConfigs.first(where: { $0.models.contains(model) }) {
            for toolName in currentConfig.builtinTools {
                let trimmedToolName = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedToolName.isEmpty {
                    toolDeclarations.append(["type": trimmedToolName])
                }
            }
        }
        
        // B. 挂载 Agent 自定义本地技能
        if !activeSkills.isEmpty {
            let sortedSkills = activeSkills.sorted { $0.name.lowercased() < $1.name.lowercased() }
            for skill in sortedSkills {
                let decl = skill.toFunctionDeclaration(isGemini: true)
                toolDeclarations.append([
                    "type": "function",
                    "name": skill.name,
                    "description": skill.description,
                    "parameters": decl["parameters"] ?? [
                        "type": "object",
                        "properties": [String: Any](),
                        "required": [String]()
                    ]
                ])
            }
        }
        
        if !toolDeclarations.isEmpty {
            requestBody["tools"] = toolDeclarations
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        return request
    }
    
    func parseSSEPayload(json: [String: Any]) -> [LLMRawEvent] {
        var events: [LLMRawEvent] = []
        
        // 1. 显式捕获并上报 Interactions API 内部下发的错误事件
        if let errorObj = json["error"] as? [String: Any] {
            let errorMsg = errorObj["message"] as? String ?? "未知服务端请求异常"
            let errorCode = errorObj["code"] as? String ?? "error"
            events.append(.text("\n\n> ❌ **Google API 拒绝请求 (\(errorCode))**: \(errorMsg)"))
            return events
        }
        
        // 2. Usage 统计解析
        if let usage = (json["usage"] as? [String: Any])
            ?? (json["usageMetadata"] as? [String: Any])
            ?? ((json["interaction"] as? [String: Any])?["usage"] as? [String: Any]) {
            if let total = (usage["total_tokens"] as? Int)
                ?? (usage["totalTokenCount"] as? Int)
                ?? (usage["total_token_count"] as? Int) {
                events.append(.usage(total))
            }
        }
        
        // 3. 解析 Step 结构 (Interactions 原生 step.start / step.delta / step.stop)
        if let step = json["step"] as? [String: Any] {
            let stepType = step["type"] as? String ?? ""
            if stepType == "function_call" {
                let id = step["id"] as? String ?? ""
                let name = step["name"] as? String ?? ""
                let argsDict = step["arguments"] as? [String: Any] ?? [:]
                events.append(.toolCall(id: id, name: name, args: argsDict, thoughtSignature: nil))
            }
        }
        
        // 4. 解析 Delta 结构 (Interactions 原生增量事件)
        if let delta = json["delta"] as? [String: Any] {
            let deltaType = delta["type"] as? String ?? ""
            
            // A. 思想签名独立事件
            if deltaType == "thought_signature" || delta["signature"] != nil {
                if let sig = (delta["signature"] as? String) ?? (delta["thought_signature"] as? String), !sig.isEmpty {
                    events.append(.toolCall(id: "", name: "", args: [:], thoughtSignature: sig))
                }
            }
            // B. 参数增量分块事件 (精准捕获 arguments_delta)
            else if deltaType == "arguments_delta" || delta["arguments"] != nil {
                if let argsStr = delta["arguments"] as? String {
                    events.append(.toolCall(id: "", name: "", args: ["__raw_stream_chunk__": argsStr], thoughtSignature: nil))
                } else if let argsDict = delta["arguments"] as? [String: Any] {
                    events.append(.toolCall(id: "", name: "", args: argsDict, thoughtSignature: nil))
                }
            }
            // C. 文本增量事件
            else if deltaType == "text_delta" || deltaType == "text" || delta["text"] != nil {
                if let text = (delta["text"] as? String) ?? (delta["content"] as? String), !text.isEmpty {
                    events.append(.text(text))
                }
            }
            // D. 思考链增量事件
            else if deltaType == "thought_delta" || deltaType == "thought" || delta["thought"] != nil || delta["reasoning_content"] != nil {
                if let thought = (delta["thought"] as? String) ?? (delta["reasoning_content"] as? String) ?? (delta["text"] as? String), !thought.isEmpty {
                    events.append(.reasoning(thought))
                }
            }
            // E. Google 原生内置工具执行事件
            else if deltaType == "code_execution_call" || delta["code_execution_call"] != nil {
                if let code = (delta["code"] as? String) ?? ((delta["code_execution_call"] as? [String: Any])?["code"] as? String) {
                    events.append(.text("\n```python\n# 正在执行 Python 沙盒运算...\n\(code)\n```\n"))
                }
            } else if deltaType == "code_execution_result" || delta["code_execution_result"] != nil {
                if let output = (delta["output"] as? String) ?? ((delta["code_execution_result"] as? [String: Any])?["output"] as? String) {
                    events.append(.text("\n> 💻 **[沙盒输出]**:\n```\n\(output)\n```\n\n"))
                }
            } else if deltaType == "google_search_result" || delta["google_search_result"] != nil {
                events.append(.reasoning("🔍 [已完成 Google 联网事实检索]\n"))
            } else if deltaType == "url_context_result" || delta["url_context_result"] != nil {
                events.append(.reasoning("🌐 [已提取网页链接正文]\n"))
            }
            // F. 常规 function_call 增量
            else if deltaType == "function_call" {
                let name = delta["name"] as? String ?? ""
                let id = delta["id"] as? String ?? delta["call_id"] as? String ?? ""
                events.append(.toolCall(id: id, name: name, args: [:], thoughtSignature: nil))
            }
        }
        
        // 5. 兼容老版本 choices / candidates 响应结构
        if let candidates = json["candidates"] as? [[String: Any]], let first = candidates.first {
            if let content = first["content"] as? [String: Any], let parts = content["parts"] as? [[String: Any]] {
                for part in parts {
                    if let text = part["text"] as? String, !text.isEmpty {
                        let isThought = part["thought"] as? Bool ?? false
                        if isThought { events.append(.reasoning(text)) } else { events.append(.text(text)) }
                    } else if let fc = part["functionCall"] as? [String: Any] {
                        let name = fc["name"] as? String ?? ""
                        let args = fc["args"] as? [String: Any] ?? [:]
                        let sig = (part["thoughtSignature"] as? String) ?? (part["thought_signature"] as? String)
                        events.append(.toolCall(id: "call_\(UUID().uuidString.prefix(8))", name: name, args: args, thoughtSignature: sig))
                    }
                }
            }
        }
        
        return events
    }
}

// MARK: - ==================== 4. OpenAI / 通用兼容协议适配器 ====================

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
            
            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                for tc in toolCalls {
                    let id = tc["id"] as? String ?? ""
                    let function = tc["function"] as? [String: Any] ?? [:]
                    let name = function["name"] as? String ?? ""
                    let argsStr = function["arguments"] as? String ?? ""
                    
                    var argsDict: [String: Any] = [:]
                    if let parsed = (try? JSONSerialization.jsonObject(with: Data(argsStr.utf8))) as? [String: Any] {
                        argsDict = parsed
                    } else if !argsStr.isEmpty {
                        argsDict["__raw_stream_chunk__"] = argsStr
                    }
                    
                    if !name.isEmpty || !argsDict.isEmpty {
                        events.append(.toolCall(id: id, name: name, args: argsDict, thoughtSignature: nil))
                    }
                }
            }
        }
        return events
    }
}

// MARK: - ==================== 5. Ollama 本地协议适配器 ====================

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

// MARK: - ==================== 6. 辅助能力扩展与核心数据模型 ====================

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
    func toFunctionDeclaration(isGemini: Bool = false) -> [String: Any] {
        var properties: [String: Any] = [:]
        var required: [String] = []
        
        let sortedParams = self.parameters.sorted { $0.name.lowercased() < $1.name.lowercased() }
        
        for param in sortedParams {
            var mappedType = param.type.rawValue.lowercased()
            if mappedType == "enum" { mappedType = "string" }
            
            var paramDef: [String: Any] = ["type": mappedType, "description": param.description]
            if mappedType == "object" {
                paramDef["properties"] = [String: Any]()
                if !isGemini {
                    paramDef["additionalProperties"] = true
                }
            } else if mappedType == "array" {
                if param.name == "tasks" {
                    let taskProps: [String: Any] = [
                        "id": ["type": "string", "description": "任务节点 ID"],
                        "status": ["type": "string", "description": "填: '等待中'"],
                        "text": ["type": "string", "description": "任务描述"]
                    ]
                    paramDef["items"] = [
                        "type": "object",
                        "properties": taskProps,
                        "required": ["id", "status", "text"]
                    ]
                } else {
                    paramDef["items"] = ["type": "string"]
                }
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
                "required": required.sorted()
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

public struct LLMToolCall: Codable, Equatable, Sendable {
    public var id: String
    public var type: String = "function"
    public var name: String
    public var arguments: String
    public var thoughtSignature: String?
    
    public init(id: String, name: String, arguments: String, thoughtSignature: String? = nil) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.thoughtSignature = thoughtSignature
    }
}

public struct ContextMessage: Codable, Equatable, Sendable {
    public var role: MessageRole
    public var content: String?
    public var toolCalls: [LLMToolCall]?
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

enum LLMRawEvent {
    case text(String)
    case reasoning(String)
    case toolCall(id: String, name: String, args: [String: Any], thoughtSignature: String?)
    case usage(Int)
}

// MARK: - ==================== 7. 多槽位流式工具调用累加器 (MultiToolCallAccumulator) ====================

private final class MultiToolCallAccumulator {
    private struct ToolCallSlot {
        var id: String
        var name: String
        var rawArgs: String
        var dictArgs: [String: Any]
        var thoughtSignature: String?
    }
    
    private var slots: [ToolCallSlot] = []
    private var currentSlotIndex: Int = -1
    private var latestThoughtSignature: String? = nil
    
    func record(id: String, name: String, rawArgsChunk: String?, dictArgs: [String: Any]?, thoughtSignature: String?) {
        // 1. 跨 Step 暂存并传递思维链防篡改签名
        if let sig = thoughtSignature, !sig.isEmpty {
            self.latestThoughtSignature = sig
            if currentSlotIndex >= 0 && slots[currentSlotIndex].thoughtSignature == nil {
                slots[currentSlotIndex].thoughtSignature = sig
            }
        }
        
        // 2. 定位或新建对应 Slot
        var targetIndex = -1
        if !id.isEmpty, let idx = slots.firstIndex(where: { $0.id == id }) {
            targetIndex = idx
        } else if !name.isEmpty && currentSlotIndex >= 0 && (slots[currentSlotIndex].name.isEmpty || slots[currentSlotIndex].name == name) {
            targetIndex = currentSlotIndex
        } else if !name.isEmpty {
            let newId = id.isEmpty ? "call_\(UUID().uuidString.prefix(8))" : id
            slots.append(ToolCallSlot(id: newId, name: name, rawArgs: "", dictArgs: [:], thoughtSignature: thoughtSignature ?? latestThoughtSignature))
            targetIndex = slots.count - 1
            currentSlotIndex = targetIndex
        } else if currentSlotIndex >= 0 {
            targetIndex = currentSlotIndex
        } else {
            let newId = id.isEmpty ? "call_\(UUID().uuidString.prefix(8))" : id
            slots.append(ToolCallSlot(id: newId, name: "", rawArgs: "", dictArgs: [:], thoughtSignature: thoughtSignature ?? latestThoughtSignature))
            targetIndex = slots.count - 1
            currentSlotIndex = targetIndex
        }
        
        // 3. 累加参数与元数据
        if !id.isEmpty { slots[targetIndex].id = id }
        if !name.isEmpty { slots[targetIndex].name = name }
        if slots[targetIndex].thoughtSignature == nil {
            slots[targetIndex].thoughtSignature = thoughtSignature ?? latestThoughtSignature
        }
        if let chunk = rawArgsChunk, !chunk.isEmpty { slots[targetIndex].rawArgs += chunk }
        if let dict = dictArgs, !dict.isEmpty {
            for (k, v) in dict { slots[targetIndex].dictArgs[k] = v }
        }
    }
    
    func finalizeAll() -> [(id: String, name: String, args: [String: Any], thoughtSignature: String?)] {
        var results: [(id: String, name: String, args: [String: Any], thoughtSignature: String?)] = []
        for slot in slots {
            guard !slot.name.isEmpty else { continue }
            var finalArgs = slot.dictArgs
            let raw = slot.rawArgs.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if !raw.isEmpty {
                // 1. 标准 JSON 反序列化
                if let data = raw.data(using: .utf8),
                   let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    for (k, v) in parsed { finalArgs[k] = v }
                }
                // 2. 剥离 Markdown 代码块后反序列化
                else if raw.contains("```") {
                    let cleaned = raw.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if let data = cleaned.data(using: .utf8),
                       let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                        for (k, v) in parsed { finalArgs[k] = v }
                    } else if finalArgs.isEmpty {
                        finalArgs["query"] = cleaned
                        finalArgs["input"] = cleaned
                    }
                }
                // 3. 纯文本作为兜底 query 注入
                else if finalArgs.isEmpty {
                    finalArgs["query"] = raw
                    finalArgs["input"] = raw
                }
            }
            
            let effectiveSig = slot.thoughtSignature ?? latestThoughtSignature
            results.append((id: slot.id, name: slot.name, args: finalArgs, thoughtSignature: effectiveSig))
        }
        return results
    }
}

// MARK: - ==================== 8. LLMService (核心执行中枢) ====================

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
        if ["pdf", "docx", "doc", "pptx", "xlsx"].contains(ext) {
            if let structuredMarkdown = try? await DoclingBridge.parseTo(fileURL: url),
               !structuredMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return structuredMarkdown
            }
        }
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
    
    func ask(
        messages: [ContextMessage],
        model: String = "",
        images: [NSImage] = [],
        fileURLs: [URL] = [],
        instruction: String = "",
        activeSkills: [AgentSkill] = []
    ) -> AsyncThrowingStream<AgentStep, Error> {
        
        var rawModelInput = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawModelInput.isEmpty {
            let appConfig = ConfigManager.shared.app
            let defaultAgentID = appConfig.generalConfig.defaultAgentID
            if let defaultAgent = appConfig.agentProfiles.first(where: { $0.id == defaultAgentID }) {
                rawModelInput = defaultAgent.baseModel
            } else if let firstAgent = appConfig.agentProfiles.first {
                rawModelInput = firstAgent.baseModel
            }
        }
        
        // 1. 核心：复合 Key 寻址解析 (格式: "配置UUID/真实模型名" 或 纯 "真实模型名")
        var matchedConfig: AiConfig? = nil
        var actualModelName = rawModelInput
        
        if rawModelInput.contains("/") {
            let segments = rawModelInput.split(separator: "/", maxSplits: 1).map(String.init)
            if segments.count == 2, let configUUID = UUID(uuidString: segments[0]) {
                if let config = ConfigManager.shared.app.aiConfigs.first(where: { $0.id == configUUID }) {
                    matchedConfig = config
                    actualModelName = segments[1]
                }
            }
        }
        
        // 2. 降级兜底：兼容旧版未包含 UUID 的配置（按模型名匹配首个节点）
        if matchedConfig == nil {
            matchedConfig = ConfigManager.shared.app.aiConfigs.first(where: { $0.models.contains(rawModelInput) })
            actualModelName = rawModelInput
        }
        
        guard let config = matchedConfig else {
            return AsyncThrowingStream<AgentStep, Error> {
                $0.yield(.error("❌ [网络通道阻断]: 找不到模型 '\(rawModelInput)' 对应的引擎配置节点。"))
                $0.finish()
            }
        }
        
        let hostConfig = config.isagent ? config.agenthost : config.host
        let apiKey = config.apikey.isEmpty ? "sk-local-token" : config.apikey
        let protocolType = config.protocolType.lowercased()
        
        return AsyncThrowingStream<AgentStep, Error> { continuation in
            let requestTask = Task { @MainActor in
                
                var autoCreatedSessionID: UUID? = nil
                if LogManager.shared.activeContextID == nil {
                    let userQuery = messages.last(where: { $0.role == .user })?.content ?? "单次模型请求"
                    autoCreatedSessionID = LogManager.shared.startSession(
                        query: userQuery,
                        agentName: "\(config.name.isEmpty ? protocolType : config.name): \(actualModelName)",
                        category: .singleLLM
                    )
                }
                
                let parentContextID = LogManager.shared.activeContextID
                var finalMessages = messages
                var injectedContext = ""
                
                let isDirectGeminiMedia = (protocolType == "gemini" || protocolType == "interactions")
                for fileURL in fileURLs {
                    if isDirectGeminiMedia && fileURL.pathExtension.lowercased() == "pdf" { continue }
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
                        model: actualModelName,
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
            
            await MainActor.run {
                LogManager.shared.error("❌ LLM API 异常", detail: finalErrorMsg, parentID: parentLogID)
                let isTransient = [502, 503, 504, 429].contains(httpResponse.statusCode)
                let friendlyText = isTransient ? "LLM 服务暂态负载波动 (HTTP \(httpResponse.statusCode)) · 正在自愈重试..." : "LLM 接口异常 (HTTP \(httpResponse.statusCode))"
                AiChatStore.shared.showLLMIndicator(message: friendlyText, isWarning: isTransient)
            }
            throw NSError(domain: "LLMClient", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: finalErrorMsg])
        }
        
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let accumulator = MultiToolCallAccumulator()
                    
                    for try await line in result.lines {
                        if Task.isCancelled { break }
                        var jsonString = line.trimmingCharacters(in: .whitespaces)
                        if jsonString.hasPrefix("data: ") { jsonString = String(jsonString.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
                        if jsonString == "[DONE]" || jsonString.isEmpty { continue }
                        
                        guard let data = jsonString.data(using: .utf8),
                              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        
                        let events = await adapter.parseSSEPayload(json: decoded)
                        for event in events {
                            switch event {
                            case .text(let t):
                                continuation.yield(.text(t))
                            case .reasoning(let r):
                                continuation.yield(.reasoning(r))
                            case .usage(let u):
                                continuation.yield(.usage(u))
                            case .toolCall(let id, let name, let args, let sig):
                                let rawChunk = args["__raw_stream_chunk__"] as? String
                                var cleanArgs = args
                                cleanArgs.removeValue(forKey: "__raw_stream_chunk__")
                                accumulator.record(
                                    id: id,
                                    name: name,
                                    rawArgsChunk: rawChunk,
                                    dictArgs: cleanArgs.isEmpty ? nil : cleanArgs,
                                    thoughtSignature: sig
                                )
                            }
                        }
                    }
                    
                    // 流完全结束后，统一派发反序列化聚合完成的完整 Tool Call
                    let finalCalls = accumulator.finalizeAll()
                    for call in finalCalls {
                        continuation.yield(.toolCall(id: call.id, name: call.name, args: call.args, thoughtSignature: call.thoughtSignature))
                    }
                    
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
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
