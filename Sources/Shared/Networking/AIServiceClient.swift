import Foundation

public enum AIServiceError: LocalizedError, Sendable {
    case missingAPIKey(providerName: String)
    case missingProjectID
    case invalidBaseURL(String)
    case invalidResponse
    case httpError(statusCode: Int, message: String)
    case emptyModelOutput
    case malformedJSON(rawText: String, underlyingError: String)

    public var errorDescription: String? {
        switch self {
        case let .missingAPIKey(providerName):
            return "未在 macOS Keychain 中找到「\(providerName)」的 API Key，请先配置。"
        case .missingProjectID:
            return "未配置 Vertex AI GCP Project ID，请先在配置面板中填写。"
        case let .invalidBaseURL(url):
            return "无效的接口地址（Base URL）：\(url)"
        case .invalidResponse:
            return "AI 服务返回了无效的网络响应。"
        case let .httpError(statusCode, message):
            return "AI 请求失败 (HTTP \(statusCode))：\(message)"
        case .emptyModelOutput:
            return "AI 模型未返回有效内容。"
        case let .malformedJSON(_, underlyingError):
            return "无法解析 AI 返回的结构化结果：\(underlyingError)"
        }
    }
}

/// Unified multi-provider AI client supporting SSE streaming and non-streaming JSON fallback
/// across Vertex AI, Gemini Developer API, OpenAI-compatible endpoints, and Anthropic Claude.
public final class AIServiceClient: Sendable {
    public static let shared = AIServiceClient()

    private let session: URLSession
    private let providerStore: AIProviderStore
    private let keychainStore: KeychainStore

    public init(
        session: URLSession? = nil,
        providerStore: AIProviderStore = .shared,
        keychainStore: KeychainStore = .shared
    ) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpMaximumConnectionsPerHost = 6
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 120
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
        self.providerStore = providerStore
        self.keychainStore = keychainStore
    }

    // MARK: - Public API

    public func verifyConnection(
        profile: AIProviderProfile,
        apiKey: String,
        tier: AIModelTier = .fast
    ) async throws -> String {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw AIServiceError.missingAPIKey(providerName: profile.name)
        }

        let resolvedProfile = resolveProjectFallback(profile)
        let model = resolvedProfile.modelName(for: tier)

        switch resolvedProfile.kind {
        case .vertexAI:
            let projectID = resolvedProfile.projectID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !projectID.isEmpty else {
                throw AIServiceError.missingProjectID
            }
            let url = try buildGeminiEndpointURL(profile: resolvedProfile, model: model, action: "countTokens")
            let count = try await sendGeminiCountTokens(url: url, apiKey: trimmedKey, customHeaders: resolvedProfile.customHeaders)
            return "Vertex AI (\(model)) 连接正常 · countTokens = \(count)"

        case .geminiDeveloper:
            let countURL = try buildGeminiEndpointURL(profile: resolvedProfile, model: model, action: "countTokens")
            do {
                let count = try await sendGeminiCountTokens(url: countURL, apiKey: trimmedKey, customHeaders: resolvedProfile.customHeaders)
                return "Gemini Developer (\(model)) 连接正常 · countTokens = \(count)"
            } catch let error as AIServiceError {
                if case let .httpError(statusCode, _) = error,
                   statusCode == 404 || statusCode == 405 || statusCode == 501
                {
                    let genURL = try buildGeminiEndpointURL(profile: resolvedProfile, model: model, action: "generateContent")
                    let body: [String: Any] = [
                        "contents": [["role": "user", "parts": [["text": "Reply with OK"]]]],
                        "generationConfig": ["maxOutputTokens": 16, "temperature": 0]
                    ]
                    let data = try await sendJSONRequest(
                        url: genURL,
                        headers: geminiHeaders(apiKey: trimmedKey, customHeaders: resolvedProfile.customHeaders),
                        bodyObject: body
                    )
                    _ = try Self.extractGeminiJSONResponse(from: data)
                    return "Gemini Developer (\(model)) 连接正常"
                }
                throw error
            }

        case .openAICompatible:
            let url = try buildOpenAIChatCompletionsURL(profile: resolvedProfile)
            let body: [String: Any] = [
                "model": model,
                "messages": [
                    ["role": "user", "content": "Reply with OK"]
                ],
                "max_tokens": 16,
                "temperature": 0,
                "stream": false
            ]
            let data = try await sendJSONRequest(
                url: url,
                headers: openAIHeaders(apiKey: trimmedKey, customHeaders: resolvedProfile.customHeaders),
                bodyObject: body
            )
            _ = try Self.extractOpenAINonStreamingResponse(from: data)
            return "OpenAI 兼容接口 (\(model)) 连接正常"

        case .anthropic:
            let url = try buildAnthropicMessagesURL(profile: resolvedProfile)
            let body: [String: Any] = [
                "model": model,
                "max_tokens": 16,
                "messages": [
                    ["role": "user", "content": "Reply with OK"]
                ],
                "stream": false
            ]
            let data = try await sendJSONRequest(
                url: url,
                headers: anthropicHeaders(apiKey: trimmedKey, customHeaders: resolvedProfile.customHeaders),
                bodyObject: body
            )
            _ = try Self.extractAnthropicNonStreamingResponse(from: data)
            return "Anthropic Claude (\(model)) 连接正常"
        }
    }

    public func analyzeEmail(
        _ email: ParsedEmailContext,
        profile: AIProviderProfile? = nil,
        tier: AIModelTier? = nil,
        apiKeyOverride: String? = nil,
        onPartial: (@Sendable (PartialAnalysisSnapshot) -> Void)? = nil
    ) async throws -> EmailAIAnalysis {
        let resolvedProfile = resolveProjectFallback(profile ?? providerStore.activeProfile)
        let resolvedTier = tier ?? providerStore.preferredTier
        let apiKey = try resolveAPIKey(for: resolvedProfile, override: apiKeyOverride)
        let model = resolvedProfile.modelName(for: resolvedTier)

        let systemPrompt = Self.emailAnalysisSystemPrompt()
        let userPrompt = email.formattedPromptInput()

        let started = Date()
        let streamed = try await executeJSONStreamingRequest(
            profile: resolvedProfile,
            model: model,
            apiKey: apiKey,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            temperature: 0.2,
            geminiResponseSchema: Self.emailAnalysisResponseSchema(),
            onPartial: onPartial
        )
        let latencyMs = Int(Date().timeIntervalSince(started) * 1000)

        let cleanedJSON = Self.extractJSONObjectText(from: streamed.text)
        let payloadData = Data(cleanedJSON.utf8)

        do {
            let decoded = try JSONDecoder().decode(ResilientEmailAnalysisPayload.self, from: payloadData)
            guard !decoded.isCompletelyEmpty else {
                throw AIServiceError.malformedJSON(
                    rawText: cleanedJSON,
                    underlyingError: "模型返回的 JSON 缺少核心分析字段。"
                )
            }
            return decoded.toEmailAIAnalysis(
                messageID: email.messageID,
                modelUsed: model,
                promptTokens: streamed.promptTokens,
                outputTokens: streamed.outputTokens,
                cachedTokens: streamed.cachedTokens,
                latencyMs: latencyMs
            )
        } catch let error as AIServiceError {
            throw error
        } catch {
            throw AIServiceError.malformedJSON(
                rawText: cleanedJSON,
                underlyingError: error.localizedDescription
            )
        }
    }

    public func generateReplyDraft(
        originalEmail: ParsedEmailContext?,
        draftSubject: String,
        recipients: [String],
        userIntent: String,
        tone: String,
        profile: AIProviderProfile? = nil,
        tier: AIModelTier? = nil,
        apiKeyOverride: String? = nil
    ) async throws -> ComposeReplyDraft {
        let resolvedProfile = resolveProjectFallback(profile ?? providerStore.activeProfile)
        let resolvedTier = tier ?? providerStore.preferredTier
        let apiKey = try resolveAPIKey(for: resolvedProfile, override: apiKeyOverride)
        let model = resolvedProfile.modelName(for: resolvedTier)

        let systemPrompt = Self.replyDraftSystemPrompt(tone: tone)
        var userPromptLines: [String] = []
        userPromptLines.append("当前草稿主题：\(draftSubject.isEmpty ? "(未填写)" : draftSubject)")
        if !recipients.isEmpty {
            userPromptLines.append("收件人：\(recipients.joined(separator: ", "))")
        }
        userPromptLines.append("回复语气：\(tone)")
        userPromptLines.append("用户希望表达的核心意图 / 回复要点：\n\(userIntent.trimmingCharacters(in: .whitespacesAndNewlines))")

        if let originalEmail {
            userPromptLines.append("")
            userPromptLines.append("=== 原信上下文 ===")
            userPromptLines.append(originalEmail.formattedPromptInput())
        }

        let streamed = try await executeJSONStreamingRequest(
            profile: resolvedProfile,
            model: model,
            apiKey: apiKey,
            systemPrompt: systemPrompt,
            userPrompt: userPromptLines.joined(separator: "\n"),
            temperature: 0.3,
            geminiResponseSchema: Self.composeReplyResponseSchema(),
            onPartial: nil
        )

        let cleanedJSON = Self.extractJSONObjectText(from: streamed.text)
        let payloadData = Data(cleanedJSON.utf8)

        do {
            let decoded = try JSONDecoder().decode(ResilientComposePayload.self, from: payloadData)
            return ComposeReplyDraft(
                suggestedSubject: decoded.suggestedSubject ?? draftSubject,
                englishDraft: decoded.englishDraft ?? "",
                chineseDraft: decoded.chineseDraft ?? "",
                bilingualCombinedDraft: decoded.bilingualCombinedDraft ?? "",
                keyPointsCovered: decoded.keyPointsCovered ?? [],
                modelUsed: model,
                generatedAt: Date()
            )
        } catch {
            throw AIServiceError.malformedJSON(
                rawText: cleanedJSON,
                underlyingError: error.localizedDescription
            )
        }
    }

    public func generateJSONText(
        systemPrompt: String,
        userPrompt: String,
        profile: AIProviderProfile? = nil,
        tier: AIModelTier = .fast
    ) async throws -> String {
        let resolvedProfile = resolveProjectFallback(profile ?? providerStore.activeProfile)
        let apiKey = try resolveAPIKey(for: resolvedProfile, override: nil)
        let model = resolvedProfile.modelName(for: tier)

        let streamed = try await executeJSONStreamingRequest(
            profile: resolvedProfile,
            model: model,
            apiKey: apiKey,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            temperature: 0.2,
            geminiResponseSchema: nil,
            onPartial: nil
        )

        let cleaned = Self.extractJSONObjectText(from: streamed.text)
        guard !cleaned.isEmpty else {
            throw AIServiceError.emptyModelOutput
        }
        return cleaned
    }

    // MARK: - Internal Request Execution & SSE Streaming

    private struct StreamedResult {
        let text: String
        let promptTokens: Int?
        let outputTokens: Int?
        let cachedTokens: Int?
    }

    private func resolveProjectFallback(_ profile: AIProviderProfile) -> AIProviderProfile {
        guard profile.kind == .vertexAI,
              profile.projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              profile.id == AIProviderProfile.defaultVertexProfileID
        else {
            return profile
        }
        let fallbackID = keychainStore.loadProjectID().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallbackID.isEmpty else { return profile }
        var copy = profile
        copy.projectID = fallbackID
        return copy
    }

    private func resolveAPIKey(for profile: AIProviderProfile, override: String?) throws -> String {
        if let override = override?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return override
        }
        if let stored = keychainStore.loadAPIKey(forProfileID: profile.id), !stored.isEmpty {
            return stored
        }
        throw AIServiceError.missingAPIKey(providerName: profile.name)
    }

    private func executeJSONStreamingRequest(
        profile: AIProviderProfile,
        model: String,
        apiKey: String,
        systemPrompt: String,
        userPrompt: String,
        temperature: Double,
        geminiResponseSchema: [String: Any]?,
        onPartial: (@Sendable (PartialAnalysisSnapshot) -> Void)?
    ) async throws -> StreamedResult {
        let request = try buildStreamingRequest(
            profile: profile,
            model: model,
            apiKey: apiKey,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            temperature: temperature,
            geminiResponseSchema: geminiResponseSchema
        )

        let (asyncBytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            var errorData = Data()
            for try await byte in asyncBytes {
                errorData.append(byte)
            }
            let message = Self.extractServerErrorMessage(from: errorData)
            throw AIServiceError.httpError(statusCode: http.statusCode, message: message)
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let isExplicitJSON = contentType.contains("application/json") && !contentType.contains("text/event-stream")

        if isExplicitJSON {
            var bodyData = Data()
            for try await byte in asyncBytes {
                bodyData.append(byte)
            }
            let result = try decodeNonStreamingResponse(kind: profile.kind, data: bodyData)
            if let onPartial {
                let snapshot = PartialEmailAnalysisExtractor.extract(from: result.text)
                if !snapshot.isEmpty {
                    onPartial(snapshot)
                }
            }
            return result
        }

        // Stream line-by-line while keeping a raw buffer fallback in case a proxy/mock returns non-SSE JSON without Content-Type
        var lineBuffer = Data()
        var rawFallbackBuffer = Data()
        var sawSSEDirective = contentType.contains("text/event-stream")
        var accumulatedText = ""
        var promptTokens: Int?
        var outputTokens: Int?
        var cachedTokens: Int?
        var lastSnapshot: PartialAnalysisSnapshot?

        func processLineData(_ data: Data) throws {
            let line = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
            guard !line.isEmpty else { return }

            if line.hasPrefix("event:") || line.hasPrefix("id:") || line.hasPrefix("retry:") || line.hasPrefix(":") {
                sawSSEDirective = true
                return
            }

            if line.hasPrefix("data:") {
                sawSSEDirective = true
                let payloadStr = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                guard !payloadStr.isEmpty, payloadStr != "[DONE]" else { return }

                let chunk = try decodeSSEChunk(kind: profile.kind, jsonString: payloadStr)
                if let p = chunk.promptTokens { promptTokens = p }
                if let o = chunk.outputTokens { outputTokens = o }
                if let c = chunk.cachedTokens { cachedTokens = c }

                if !chunk.textDelta.isEmpty {
                    accumulatedText += chunk.textDelta
                    if let onPartial {
                        let snapshot = PartialEmailAnalysisExtractor.extract(from: accumulatedText)
                        if !snapshot.isEmpty && snapshot != lastSnapshot {
                            lastSnapshot = snapshot
                            onPartial(snapshot)
                        }
                    }
                }
            }
        }

        for try await byte in asyncBytes {
            if !sawSSEDirective {
                rawFallbackBuffer.append(byte)
            }
            if byte == 0x0A { // '\n'
                try processLineData(lineBuffer)
                lineBuffer.removeAll(keepingCapacity: true)
            } else {
                lineBuffer.append(byte)
            }
        }

        if !lineBuffer.isEmpty {
            try processLineData(lineBuffer)
        }

        if sawSSEDirective {
            let trimmed = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw AIServiceError.emptyModelOutput
            }
            return StreamedResult(
                text: trimmed,
                promptTokens: promptTokens,
                outputTokens: outputTokens,
                cachedTokens: cachedTokens
            )
        }

        let result = try decodeNonStreamingResponse(kind: profile.kind, data: rawFallbackBuffer)
        if let onPartial {
            let snapshot = PartialEmailAnalysisExtractor.extract(from: result.text)
            if !snapshot.isEmpty && snapshot != lastSnapshot {
                onPartial(snapshot)
            }
        }
        return result
    }

    // MARK: - Request Builders

    private func buildStreamingRequest(
        profile: AIProviderProfile,
        model: String,
        apiKey: String,
        systemPrompt: String,
        userPrompt: String,
        temperature: Double,
        geminiResponseSchema: [String: Any]?
    ) throws -> URLRequest {
        let url: URL
        let headers: [String: String]
        let bodyObject: [String: Any]

        switch profile.kind {
        case .vertexAI:
            let projectID = profile.projectID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !projectID.isEmpty else {
                throw AIServiceError.missingProjectID
            }
            url = try buildGeminiEndpointURL(profile: profile, model: model, action: "streamGenerateContent?alt=sse")
            headers = geminiHeaders(apiKey: apiKey, customHeaders: profile.customHeaders)
            var generationConfig: [String: Any] = [
                "temperature": temperature,
                "responseMimeType": "application/json",
                "thinkingConfig": Self.geminiThinkingConfig(for: model, isVertex: true)
            ]
            if let geminiResponseSchema {
                generationConfig["responseSchema"] = geminiResponseSchema
            }
            bodyObject = [
                "systemInstruction": [
                    "parts": [["text": systemPrompt]]
                ],
                "contents": [
                    [
                        "role": "user",
                        "parts": [["text": userPrompt]]
                    ]
                ],
                "generationConfig": generationConfig
            ]

        case .geminiDeveloper:
            url = try buildGeminiEndpointURL(profile: profile, model: model, action: "streamGenerateContent?alt=sse")
            headers = geminiHeaders(apiKey: apiKey, customHeaders: profile.customHeaders)
            var generationConfig: [String: Any] = [
                "temperature": temperature,
                "responseMimeType": "application/json"
            ]
            if let geminiResponseSchema {
                generationConfig["responseSchema"] = geminiResponseSchema
            }
            if let thinkingConfig = Self.geminiThinkingConfigIfSupported(for: model) {
                generationConfig["thinkingConfig"] = thinkingConfig
            }
            bodyObject = [
                "systemInstruction": [
                    "parts": [["text": systemPrompt]]
                ],
                "contents": [
                    [
                        "role": "user",
                        "parts": [["text": userPrompt]]
                    ]
                ],
                "generationConfig": generationConfig
            ]

        case .openAICompatible:
            url = try buildOpenAIChatCompletionsURL(profile: profile)
            headers = openAIHeaders(apiKey: apiKey, customHeaders: profile.customHeaders)
            bodyObject = [
                "model": model,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userPrompt]
                ],
                "temperature": temperature,
                "stream": true,
                "response_format": ["type": "json_object"]
            ]

        case .anthropic:
            url = try buildAnthropicMessagesURL(profile: profile)
            headers = anthropicHeaders(apiKey: apiKey, customHeaders: profile.customHeaders)
            bodyObject = [
                "model": model,
                "max_tokens": 4096,
                "temperature": temperature,
                "system": systemPrompt,
                "messages": [
                    ["role": "user", "content": userPrompt]
                ],
                "stream": true
            ]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyObject, options: [])
        return request
    }

    private func buildGeminiEndpointURL(
        profile: AIProviderProfile,
        model: String,
        action: String
    ) throws -> URL {
        let base = profile.normalizedBaseURL
        let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        let urlString: String
        switch profile.kind {
        case .vertexAI:
            let projectID = profile.projectID.trimmingCharacters(in: .whitespacesAndNewlines)
            let location = profile.location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? GeminiModel.vertexLocation
                : profile.location.trimmingCharacters(in: .whitespacesAndNewlines)
            let encodedProject = projectID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? projectID
            let encodedLocation = location.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? location
            urlString = "\(base)/projects/\(encodedProject)/locations/\(encodedLocation)/publishers/google/models/\(encodedModel):\(action)"
        case .geminiDeveloper:
            urlString = "\(base)/models/\(encodedModel):\(action)"
        case .openAICompatible, .anthropic:
            throw AIServiceError.invalidBaseURL(base)
        }

        guard let url = URL(string: urlString), url.scheme != nil, url.host != nil else {
            throw AIServiceError.invalidBaseURL(urlString)
        }
        return url
    }

    private func buildOpenAIChatCompletionsURL(profile: AIProviderProfile) throws -> URL {
        let base = profile.normalizedBaseURL
        let urlString = base.hasSuffix("/chat/completions") ? base : "\(base)/chat/completions"
        guard let url = URL(string: urlString), url.scheme != nil, url.host != nil else {
            throw AIServiceError.invalidBaseURL(urlString)
        }
        return url
    }

    private func buildAnthropicMessagesURL(profile: AIProviderProfile) throws -> URL {
        let base = profile.normalizedBaseURL
        let urlString = base.hasSuffix("/messages") ? base : "\(base)/messages"
        guard let url = URL(string: urlString), url.scheme != nil, url.host != nil else {
            throw AIServiceError.invalidBaseURL(urlString)
        }
        return url
    }

    private func geminiHeaders(apiKey: String, customHeaders: [String: String]) -> [String: String] {
        var headers = [
            "Content-Type": "application/json",
            "x-goog-api-key": apiKey
        ]
        mergeCustomHeaders(customHeaders, into: &headers)
        return headers
    }

    private func openAIHeaders(apiKey: String, customHeaders: [String: String]) -> [String: String] {
        var headers = [
            "Content-Type": "application/json",
            "Authorization": "Bearer \(apiKey)"
        ]
        mergeCustomHeaders(customHeaders, into: &headers)
        return headers
    }

    private func anthropicHeaders(apiKey: String, customHeaders: [String: String]) -> [String: String] {
        var headers = [
            "Content-Type": "application/json",
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01"
        ]
        mergeCustomHeaders(customHeaders, into: &headers)
        return headers
    }

    private func mergeCustomHeaders(_ customHeaders: [String: String], into headers: inout [String: String]) {
        for (key, value) in customHeaders {
            let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !k.isEmpty && !v.isEmpty {
                headers[k] = v
            }
        }
    }

    private static func geminiThinkingConfig(for model: String, isVertex: Bool) -> [String: Any] {
        if model.lowercased().contains("flash") {
            return ["thinkingBudget": 0]
        }
        return isVertex ? ["thinkingLevel": "LOW"] : ["thinkingLevel": "LOW"]
    }

    private static func geminiThinkingConfigIfSupported(for model: String) -> [String: Any]? {
        let lower = model.lowercased()
        if lower.contains("gemini-3") || lower.contains("gemini-4") || lower.contains("carbon") {
            return lower.contains("flash") ? ["thinkingBudget": 0] : ["thinkingLevel": "LOW"]
        }
        if lower.contains("gemini-2.5") && lower.contains("flash") {
            return ["thinkingBudget": 0]
        }
        return nil
    }

    // MARK: - Non-Streaming Request Helpers

    private func sendGeminiCountTokens(url: URL, apiKey: String, customHeaders: [String: String]) async throws -> Int {
        let payload: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": "ping"]
                    ]
                ]
            ]
        ]
        let data = try await sendJSONRequest(
            url: url,
            headers: geminiHeaders(apiKey: apiKey, customHeaders: customHeaders),
            bodyObject: payload
        )
        struct CountTokensResponse: Decodable {
            let totalTokens: Int?
        }
        let decoded = try JSONDecoder().decode(CountTokensResponse.self, from: data)
        return decoded.totalTokens ?? 0
    }

    private func sendJSONRequest(
        url: URL,
        headers: [String: String],
        bodyObject: [String: Any]
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyObject, options: [])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AIServiceError.httpError(
                statusCode: http.statusCode,
                message: Self.extractServerErrorMessage(from: data)
            )
        }
        return data
    }

    // MARK: - SSE & Non-Streaming Decoders

    private struct SSEChunkDelta {
        let textDelta: String
        let promptTokens: Int?
        let outputTokens: Int?
        let cachedTokens: Int?
    }

    private func decodeSSEChunk(kind: AIProviderKind, jsonString: String) throws -> SSEChunkDelta {
        let data = Data(jsonString.utf8)

        // Check for inline SSE error payloads
        if let errEnvelope = try? JSONDecoder().decode(GenericSSEErrorEnvelope.self, from: data),
           let err = errEnvelope.error,
           let message = err.message,
           !message.isEmpty
        {
            throw AIServiceError.httpError(statusCode: err.code ?? 500, message: message)
        }

        switch kind {
        case .vertexAI, .geminiDeveloper:
            let decoded = try JSONDecoder().decode(GeminiEnvelope.self, from: data)
            let parts = decoded.candidates?.first?.content?.parts ?? []
            let textDelta = parts
                .filter { $0.thought != true }
                .compactMap(\.text)
                .joined()
            return SSEChunkDelta(
                textDelta: textDelta,
                promptTokens: decoded.usageMetadata?.promptTokenCount,
                outputTokens: decoded.usageMetadata?.candidatesTokenCount,
                cachedTokens: decoded.usageMetadata?.cachedContentTokenCount
            )

        case .openAICompatible:
            let decoded = try JSONDecoder().decode(OpenAIStreamChunk.self, from: data)
            let choice = decoded.choices?.first
            let deltaText = choice?.delta?.content ?? choice?.message?.content ?? ""
            return SSEChunkDelta(
                textDelta: deltaText,
                promptTokens: decoded.usage?.promptTokens,
                outputTokens: decoded.usage?.completionTokens,
                cachedTokens: decoded.usage?.promptTokensDetails?.cachedTokens
            )

        case .anthropic:
            let decoded = try JSONDecoder().decode(AnthropicStreamEvent.self, from: data)
            let deltaText: String
            if decoded.type == "content_block_delta" || decoded.delta != nil {
                if decoded.delta?.type == "thinking_delta" {
                    deltaText = ""
                } else {
                    deltaText = decoded.delta?.text ?? ""
                }
            } else {
                deltaText = ""
            }
            let inputTokens = decoded.message?.usage?.inputTokens ?? decoded.usage?.inputTokens
            let outputTokens = decoded.usage?.outputTokens ?? decoded.message?.usage?.outputTokens
            return SSEChunkDelta(
                textDelta: deltaText,
                promptTokens: inputTokens,
                outputTokens: outputTokens,
                cachedTokens: decoded.message?.usage?.cacheReadInputTokens ?? decoded.usage?.cacheReadInputTokens
            )
        }
    }

    private func decodeNonStreamingResponse(kind: AIProviderKind, data: Data) throws -> StreamedResult {
        switch kind {
        case .vertexAI, .geminiDeveloper:
            return try Self.extractGeminiJSONResponse(from: data)
        case .openAICompatible:
            return try Self.extractOpenAINonStreamingResponse(from: data)
        case .anthropic:
            return try Self.extractAnthropicNonStreamingResponse(from: data)
        }
    }

    private static func extractGeminiJSONResponse(from data: Data) throws -> StreamedResult {
        if let single = try? JSONDecoder().decode(GeminiEnvelope.self, from: data),
           single.candidates != nil
        {
            let parts = single.candidates?.first?.content?.parts ?? []
            let nonThought = parts
                .filter { $0.thought != true }
                .compactMap(\.text)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !nonThought.isEmpty else {
                throw AIServiceError.emptyModelOutput
            }
            return StreamedResult(
                text: nonThought,
                promptTokens: single.usageMetadata?.promptTokenCount,
                outputTokens: single.usageMetadata?.candidatesTokenCount,
                cachedTokens: single.usageMetadata?.cachedContentTokenCount
            )
        }

        // Some Gemini streaming endpoints return a JSON array of response envelopes when ?alt=sse is omitted
        if let array = try? JSONDecoder().decode([GeminiEnvelope].self, from: data) {
            var texts: [String] = []
            var promptTokens: Int?
            var outputTokens: Int?
            var cachedTokens: Int?
            for item in array {
                let parts = item.candidates?.first?.content?.parts ?? []
                texts.append(contentsOf: parts.filter { $0.thought != true }.compactMap(\.text))
                if let p = item.usageMetadata?.promptTokenCount { promptTokens = p }
                if let o = item.usageMetadata?.candidatesTokenCount { outputTokens = o }
                if let c = item.usageMetadata?.cachedContentTokenCount { cachedTokens = c }
            }
            let joined = texts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !joined.isEmpty else {
                throw AIServiceError.emptyModelOutput
            }
            return StreamedResult(
                text: joined,
                promptTokens: promptTokens,
                outputTokens: outputTokens,
                cachedTokens: cachedTokens
            )
        }

        throw AIServiceError.malformedJSON(
            rawText: String(decoding: data, as: UTF8.self),
            underlyingError: "无法解码 Gemini 响应体"
        )
    }

    private static func extractOpenAINonStreamingResponse(from data: Data) throws -> StreamedResult {
        let decoded = try JSONDecoder().decode(OpenAICompletionResponse.self, from: data)
        let text = (decoded.choices?.first?.message?.content ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AIServiceError.emptyModelOutput
        }
        return StreamedResult(
            text: text,
            promptTokens: decoded.usage?.promptTokens,
            outputTokens: decoded.usage?.completionTokens,
            cachedTokens: decoded.usage?.promptTokensDetails?.cachedTokens
        )
    }

    private static func extractAnthropicNonStreamingResponse(from data: Data) throws -> StreamedResult {
        let decoded = try JSONDecoder().decode(AnthropicMessageResponse.self, from: data)
        let text = (decoded.content ?? [])
            .filter { $0.type == "text" || $0.type == nil }
            .compactMap(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AIServiceError.emptyModelOutput
        }
        return StreamedResult(
            text: text,
            promptTokens: decoded.usage?.inputTokens,
            outputTokens: decoded.usage?.outputTokens,
            cachedTokens: decoded.usage?.cacheReadInputTokens
        )
    }

    public static func extractJSONObjectText(from raw: String) -> String {
        let stripped = VertexGeminiClient.stripMarkdownCodeFence(raw)
        if stripped.hasPrefix("{") && stripped.hasSuffix("}") {
            return stripped
        }
        guard let firstBrace = stripped.firstIndex(of: "{"),
              let lastBrace = stripped.lastIndex(of: "}"),
              firstBrace <= lastBrace
        else {
            return stripped
        }
        return String(stripped[firstBrace...lastBrace]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func extractServerErrorMessage(from data: Data) -> String {
        struct ErrorEnvelope: Decodable {
            struct Inner: Decodable {
                let message: String?
                let status: String?
                let type: String?
            }
            let error: Inner?
            let message: String?
        }

        if let parsed = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
            if let message = parsed.error?.message, !message.isEmpty {
                let tag = parsed.error?.status ?? parsed.error?.type
                if let tag, !tag.isEmpty {
                    return "[\(tag)] \(message)"
                }
                return message
            }
            if let message = parsed.message, !message.isEmpty {
                return message
            }
        }
        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "未知服务端错误" : String(raw.prefix(400))
    }

    // MARK: - Prompts & Schemas

    public static func emailAnalysisSystemPrompt() -> String {
        """
        你是一名资深 B2B 工业通信、硬件工程与外贸商务邮件分析助手。请严格依据提供的邮件原文（头信息、附件文件名、最新正文、历史引用链）提取高信息密度中文分析，禁止捏造邮件中未出现的数据。
        严格输出一个合法 JSON 对象（不要包含 Markdown 代码块围栏或额外说明文字），并且必须严格按照以下字段顺序从上到下输出，以便流式首屏最快呈现结论与旗标：
        `headline` → `suggestedFlag` → `flagReason` → `coreConclusions` → `todos` → `businessElements` → `plainChineseTranslation` → `timeline`

        语义高亮标记规则（仅用于 `headline`、`coreConclusions`、`todos[].task`、`plainChineseTranslation` 和 `timeline[].summary` 文本内，每句克制标记 1~3 处关键短语，切勿整句套壳）：
        - `==...==` 标记严重痛点、阻塞项、拒绝原因、异议或风险（例如：`==内容过于简单==`、`==交期延迟2周==`）
        - `**...**` 标记核心诉求、明确决策或关键动作（例如：`**提供详细漏洞管理流程的正式PDF文档**`）
        - `` `...` `` 标记产品型号/SKU、文档名、标准规范或关键报价数值（例如：`` `Moxa_ENISA_SRP` ``、`` `EDS-4012` ``、`` `USD 485` ``）

        各字段规范与 JSON Schema 定义：
        1. `headline` (string): 用一句话概括这封邮件最核心的结论或诉求（可使用语义高亮标记）。
        2. `suggestedFlag` (string): 仅可为以下 8 个枚举值之一：
           - "red"（紧急待回：需要尽快回复、有紧迫截止时间或高优阻塞项）
           - "orange"（等审批：特价申请、MOQ 调整、用印/合同/流程签核）
           - "yellow"（跟报价：询价、报价单、BOM 核价、PI、折扣或交期谈判）
           - "green"（重点项目：核心轨交/工业项目推进、招投标、重要里程碑）
           - "blue"（技术卡点：软硬件故障、规格确认、安规认证/测试报告卡点）
           - "purple"（产品变更：PCN / EOL、Label 变更、新产品大类或物料变更）
           - "gray"（发票报销：发票、差旅报销、付款结算提醒）
           - "none"（一般知悉类邮件，无需打标）
        3. `flagReason` (string): 用不超过 18 个汉字说明选择该旗标的原因。
        4. `coreConclusions` (string[]): 3~6 条高凝练核心要点（直奔主题，突出决策、变更、风险、交期或报价变化，支持语义高亮）。
        5. `todos` (object[]): 提取明确或隐含的待办事项，每项包含：
           - `task` (string, 支持语义高亮)
           - `owner` (string, 负责方)
           - `deadline` (string, 截止时间原文描述，无则填 "")
           - `dueDateISO` (string, 若明确提及或可依据邮件 Date 推算出具体任务日期则填 "YYYY-MM-DD"，否则必须填 "")
           - `priority` (string, 仅可为 "high" / "medium" / "low")
        6. `businessElements` (object):
           - `projects` (string[]): 项目名称、编号或客户内部代号
           - `customers` (string[]): 客户公司、终端用户、相关团队或联系人
           - `models` (string[]): 产品型号、SKU、物料号、规格配置
           - `pricing` (object[]): 报价明细，每项含 `itemOrModel`, `quantity`, `unitPrice`, `currency`, `termsOrLeadTime`, `notes`（未提及子项填 ""）
        7. `plainChineseTranslation` (string): 若最新正文包含英文或外文，准确翻译为通俗、自然、符合中国工程师与商务习惯的简体中文；若原信已是简体中文，仅输出 2~3 句精炼白话摘要（不要逐字复述中文原文），不丢失关键数字与技术名词（支持语义高亮）。
        8. `timeline` (object[]): 长信或多轮往来按时间由早到晚梳理最多 5 个关键节点（`timeOrStep`, `actor`, `summary` 支持语义高亮）；单封短邮件仅输出 1 个关键节点。
        """
    }

    public static func replyDraftSystemPrompt(tone: String) -> String {
        """
        你是一名精通跨国商务与技术沟通的双语邮件撰写专家。请根据用户意图、收件人信息以及原邮件上下文，撰写专业、地道、直接可用的英文回复草稿、中文回复草稿，以及中英双语对照版。
        风格要求：语气「\(tone)」，准确核对并沿用原信中的项目名、型号、数量、单价、交期与条款（不可擅自篡改数字）。
        请严格输出一个合法 JSON 对象（不要包含 Markdown 代码块围栏或额外说明文字），包含以下字段：
        - `suggestedSubject` (string): 建议邮件主题
        - `englishDraft` (string): 可直接发送的地道英文邮件正文（含称呼与落款占位）
        - `chineseDraft` (string): 对应语义自然准确的中文邮件正文
        - `bilingualCombinedDraft` (string): 便于双语留档或发给双语团队的中英双语合并版本
        - `keyPointsCovered` (string[]): 本次回复涵盖的关键要点列表
        """
    }

    public static func emailAnalysisResponseSchema() -> [String: Any] {
        [
            "type": "OBJECT",
            "properties": [
                "headline": ["type": "STRING"],
                "suggestedFlag": ["type": "STRING"],
                "flagReason": ["type": "STRING"],
                "coreConclusions": [
                    "type": "ARRAY",
                    "items": ["type": "STRING"]
                ],
                "todos": [
                    "type": "ARRAY",
                    "items": [
                        "type": "OBJECT",
                        "properties": [
                            "task": ["type": "STRING"],
                            "owner": ["type": "STRING"],
                            "deadline": ["type": "STRING"],
                            "dueDateISO": ["type": "STRING"],
                            "priority": ["type": "STRING"]
                        ],
                        "required": ["task", "owner", "deadline", "dueDateISO", "priority"]
                    ]
                ],
                "businessElements": [
                    "type": "OBJECT",
                    "properties": [
                        "projects": ["type": "ARRAY", "items": ["type": "STRING"]],
                        "customers": ["type": "ARRAY", "items": ["type": "STRING"]],
                        "models": ["type": "ARRAY", "items": ["type": "STRING"]],
                        "pricing": [
                            "type": "ARRAY",
                            "items": [
                                "type": "OBJECT",
                                "properties": [
                                    "itemOrModel": ["type": "STRING"],
                                    "quantity": ["type": "STRING"],
                                    "unitPrice": ["type": "STRING"],
                                    "currency": ["type": "STRING"],
                                    "termsOrLeadTime": ["type": "STRING"],
                                    "notes": ["type": "STRING"]
                                ],
                                "required": ["itemOrModel", "quantity", "unitPrice", "currency", "termsOrLeadTime", "notes"]
                            ]
                        ]
                    ],
                    "required": ["projects", "customers", "models", "pricing"]
                ],
                "plainChineseTranslation": ["type": "STRING"],
                "timeline": [
                    "type": "ARRAY",
                    "items": [
                        "type": "OBJECT",
                        "properties": [
                            "timeOrStep": ["type": "STRING"],
                            "actor": ["type": "STRING"],
                            "summary": ["type": "STRING"]
                        ],
                        "required": ["timeOrStep", "actor", "summary"]
                    ]
                ]
            ],
            "required": [
                "headline",
                "suggestedFlag",
                "flagReason",
                "coreConclusions",
                "todos",
                "businessElements",
                "plainChineseTranslation",
                "timeline"
            ]
        ]
    }

    public static func composeReplyResponseSchema() -> [String: Any] {
        [
            "type": "OBJECT",
            "properties": [
                "suggestedSubject": ["type": "STRING"],
                "englishDraft": ["type": "STRING"],
                "chineseDraft": ["type": "STRING"],
                "bilingualCombinedDraft": ["type": "STRING"],
                "keyPointsCovered": [
                    "type": "ARRAY",
                    "items": ["type": "STRING"]
                ]
            ],
            "required": [
                "suggestedSubject",
                "englishDraft",
                "chineseDraft",
                "bilingualCombinedDraft",
                "keyPointsCovered"
            ]
        ]
    }

    // MARK: - Provider Wire Envelopes

    private struct GenericSSEErrorEnvelope: Decodable {
        struct ErrorBody: Decodable {
            let message: String?
            let code: Int?
        }
        let error: ErrorBody?
    }

    private struct GeminiEnvelope: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable {
                    let text: String?
                    let thought: Bool?
                }
                let parts: [Part]?
            }
            let content: Content?
        }
        struct UsageMetadata: Decodable {
            let promptTokenCount: Int?
            let candidatesTokenCount: Int?
            let cachedContentTokenCount: Int?
        }
        let candidates: [Candidate]?
        let usageMetadata: UsageMetadata?
    }

    private struct OpenAIUsage: Decodable {
        struct PromptTokensDetails: Decodable {
            let cachedTokens: Int?
            enum CodingKeys: String, CodingKey {
                case cachedTokens = "cached_tokens"
            }
        }
        let promptTokens: Int?
        let completionTokens: Int?
        let promptTokensDetails: PromptTokensDetails?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case promptTokensDetails = "prompt_tokens_details"
        }
    }

    private struct OpenAIStreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
            }
            struct Message: Decodable {
                let content: String?
            }
            let delta: Delta?
            let message: Message?
        }
        let choices: [Choice]?
        let usage: OpenAIUsage?
    }

    private struct OpenAICompletionResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }
            let message: Message?
        }
        let choices: [Choice]?
        let usage: OpenAIUsage?
    }

    private struct AnthropicUsage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadInputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
        }
    }

    private struct AnthropicStreamEvent: Decodable {
        struct Delta: Decodable {
            let type: String?
            let text: String?
        }
        struct MessageContainer: Decodable {
            let usage: AnthropicUsage?
        }
        let type: String?
        let delta: Delta?
        let message: MessageContainer?
        let usage: AnthropicUsage?
    }

    private struct AnthropicMessageResponse: Decodable {
        struct ContentBlock: Decodable {
            let type: String?
            let text: String?
        }
        let content: [ContentBlock]?
        let usage: AnthropicUsage?
    }

    // MARK: - Resilient Model Decoding

    private struct LossyString: Decodable {
        let value: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self.value = nil
            } else if let str = try? container.decode(String.self) {
                self.value = str
            } else if let intVal = try? container.decode(Int64.self) {
                self.value = String(intVal)
            } else if let doubleVal = try? container.decode(Double.self) {
                if doubleVal.isFinite,
                   doubleVal.rounded() == doubleVal,
                   doubleVal >= Double(Int64.min),
                   doubleVal <= Double(Int64.max)
                {
                    self.value = String(Int64(doubleVal))
                } else {
                    self.value = String(doubleVal)
                }
            } else if let boolVal = try? container.decode(Bool.self) {
                self.value = boolVal ? "true" : "false"
            } else {
                self.value = nil
            }
        }
    }

    private struct ResilientTodoItem: Decodable {
        let task: LossyString?
        let owner: LossyString?
        let deadline: LossyString?
        let dueDateISO: LossyString?
        let priority: LossyString?

        func toEmailTodoItem() -> EmailTodoItem? {
            let cleanTask = (task?.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanTask.isEmpty else { return nil }
            let cleanOwner = (owner?.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanPriority = (priority?.value ?? "medium").trimmingCharacters(in: .whitespacesAndNewlines)
            return EmailTodoItem(
                task: cleanTask,
                owner: cleanOwner.isEmpty ? "相关方" : cleanOwner,
                deadline: deadline?.value,
                dueDateISO: dueDateISO?.value,
                priority: cleanPriority.isEmpty ? "medium" : cleanPriority
            )
        }
    }

    private struct ResilientPricingElement: Decodable {
        let itemOrModel: LossyString?
        let quantity: LossyString?
        let unitPrice: LossyString?
        let currency: LossyString?
        let termsOrLeadTime: LossyString?
        let notes: LossyString?

        func toPricingElement() -> PricingElement? {
            let item = (itemOrModel?.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !item.isEmpty else { return nil }
            return PricingElement(
                itemOrModel: item,
                quantity: quantity?.value,
                unitPrice: unitPrice?.value,
                currency: currency?.value,
                termsOrLeadTime: termsOrLeadTime?.value,
                notes: notes?.value
            )
        }
    }

    private struct ResilientBusinessElements: Decodable {
        let projects: [String]?
        let customers: [String]?
        let models: [String]?
        let pricing: [ResilientPricingElement]?

        func toBusinessElements() -> BusinessElements {
            BusinessElements(
                projects: projects ?? [],
                customers: customers ?? [],
                models: models ?? [],
                pricing: (pricing ?? []).compactMap { $0.toPricingElement() }
            )
        }
    }

    private struct ResilientTimelineEvent: Decodable {
        let timeOrStep: LossyString?
        let actor: LossyString?
        let summary: LossyString?

        func toTimelineEvent() -> TimelineEvent? {
            let cleanSummary = (summary?.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanSummary.isEmpty else { return nil }
            return TimelineEvent(
                timeOrStep: timeOrStep?.value ?? "",
                actor: actor?.value ?? "",
                summary: cleanSummary
            )
        }
    }

    private struct ResilientEmailAnalysisPayload: Decodable {
        let headline: String?
        let coreConclusions: [String]?
        let todos: [ResilientTodoItem]?
        let businessElements: ResilientBusinessElements?
        let plainChineseTranslation: String?
        let timeline: [ResilientTimelineEvent]?
        let suggestedFlag: String?
        let flagReason: String?

        var isCompletelyEmpty: Bool {
            let h = (headline ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let p = (plainChineseTranslation ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let c = (coreConclusions ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return h.isEmpty && p.isEmpty && c.isEmpty
        }

        func toEmailAIAnalysis(
            messageID: String,
            modelUsed: String,
            promptTokens: Int?,
            outputTokens: Int?,
            cachedTokens: Int?,
            latencyMs: Int
        ) -> EmailAIAnalysis {
            EmailAIAnalysis(
                headline: headline ?? "",
                coreConclusions: coreConclusions ?? [],
                todos: (todos ?? []).compactMap { $0.toEmailTodoItem() },
                businessElements: businessElements?.toBusinessElements() ?? BusinessElements(),
                plainChineseTranslation: plainChineseTranslation ?? "",
                timeline: (timeline ?? []).compactMap { $0.toTimelineEvent() },
                suggestedFlag: suggestedFlag,
                flagReason: flagReason,
                messageID: messageID,
                modelUsed: modelUsed,
                analyzedAt: Date(),
                promptTokens: promptTokens,
                outputTokens: outputTokens,
                cachedTokens: cachedTokens,
                latencyMs: latencyMs
            )
        }
    }

    private struct ResilientComposePayload: Decodable {
        let suggestedSubject: String?
        let englishDraft: String?
        let chineseDraft: String?
        let bilingualCombinedDraft: String?
        let keyPointsCovered: [String]?
    }
}
