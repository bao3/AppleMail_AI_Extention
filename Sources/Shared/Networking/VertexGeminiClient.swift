import Foundation

public enum VertexGeminiError: LocalizedError {
    case missingAPIKey
    case missingProjectID
    case invalidResponse
    case httpError(statusCode: Int, message: String)
    case emptyModelOutput
    case malformedJSON(rawText: String, underlyingError: String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "未在 macOS Keychain 中找到 Vertex AI API Key，请先配置。"
        case .missingProjectID:
            return "未配置 Vertex AI GCP Project ID，请先在配置面板中填写。"
        case .invalidResponse:
            return "Vertex AI 返回了无效的网络响应。"
        case let .httpError(statusCode, message):
            return "Vertex AI 请求失败 (HTTP \(statusCode))：\(message)"
        case .emptyModelOutput:
            return "Gemini 未返回有效内容。"
        case let .malformedJSON(_, underlyingError):
            return "无法解析 Gemini 返回的结构化结果：\(underlyingError)"
        }
    }
}

public final class VertexGeminiClient: Sendable {
    public static let shared = VertexGeminiClient()

    private let session: URLSession
    private let aiClient: AIServiceClient

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
            self.aiClient = AIServiceClient(session: session)
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 120
            config.httpMaximumConnectionsPerHost = 6
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            let createdSession = URLSession(configuration: config)
            self.session = createdSession
            self.aiClient = AIServiceClient(session: createdSession)
        }
    }

    // MARK: - Zero-Cost Connection Verification

    public func verifyAPIKeyAndModel(
        apiKey: String,
        model: GeminiModel,
        projectID: String? = nil
    ) async throws -> Int {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw VertexGeminiError.missingAPIKey
        }
        let resolvedProjectID = (projectID ?? KeychainStore.shared.loadProjectID())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedProjectID.isEmpty else {
            throw VertexGeminiError.missingProjectID
        }

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

        let data = try await sendRequest(
            url: model.countTokensURL(projectID: resolvedProjectID),
            apiKey: trimmedKey,
            bodyObject: payload
        )
        struct CountTokensResponse: Decodable {
            let totalTokens: Int?
        }
        let decoded = try JSONDecoder().decode(CountTokensResponse.self, from: data)
        return decoded.totalTokens ?? 0
    }

    // MARK: - Email Summary Analysis

    public func analyzeEmail(
        _ email: ParsedEmailContext,
        model: GeminiModel,
        apiKey: String,
        projectID: String? = nil
    ) async throws -> EmailAIAnalysis {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw VertexGeminiError.missingAPIKey
        }
        let resolvedProjectID = (projectID ?? KeychainStore.shared.loadProjectID())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedProjectID.isEmpty else {
            throw VertexGeminiError.missingProjectID
        }

        let profile = AIProviderProfile(
            id: AIProviderProfile.defaultVertexProfileID,
            name: "Vertex AI",
            kind: .vertexAI,
            projectID: resolvedProjectID,
            location: GeminiModel.vertexLocation,
            fastModel: model.rawValue,
            deepModel: model.rawValue
        )

        do {
            return try await aiClient.analyzeEmail(
                email,
                profile: profile,
                tier: AIModelTier(legacyModel: model),
                apiKeyOverride: trimmedKey
            )
        } catch let error as AIServiceError {
            throw Self.mapAIServiceError(error)
        }
    }

    // MARK: - Bilingual Reply Draft Generation

    public func generateReplyDraft(
        originalEmail: ParsedEmailContext?,
        draftSubject: String,
        recipients: [String],
        userIntent: String,
        tone: String,
        model: GeminiModel,
        apiKey: String,
        projectID: String? = nil
    ) async throws -> ComposeReplyDraft {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw VertexGeminiError.missingAPIKey
        }
        let resolvedProjectID = (projectID ?? KeychainStore.shared.loadProjectID())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedProjectID.isEmpty else {
            throw VertexGeminiError.missingProjectID
        }

        let profile = AIProviderProfile(
            id: AIProviderProfile.defaultVertexProfileID,
            name: "Vertex AI",
            kind: .vertexAI,
            projectID: resolvedProjectID,
            location: GeminiModel.vertexLocation,
            fastModel: model.rawValue,
            deepModel: model.rawValue
        )

        do {
            return try await aiClient.generateReplyDraft(
                originalEmail: originalEmail,
                draftSubject: draftSubject,
                recipients: recipients,
                userIntent: userIntent,
                tone: tone,
                profile: profile,
                tier: AIModelTier(legacyModel: model),
                apiKeyOverride: trimmedKey
            )
        } catch let error as AIServiceError {
            throw Self.mapAIServiceError(error)
        }
    }

    private static func mapAIServiceError(_ error: AIServiceError) -> VertexGeminiError {
        switch error {
        case .missingAPIKey:
            return .missingAPIKey
        case .missingProjectID:
            return .missingProjectID
        case .invalidBaseURL, .invalidResponse:
            return .invalidResponse
        case let .httpError(statusCode, message):
            return .httpError(statusCode: statusCode, message: message)
        case .emptyModelOutput:
            return .emptyModelOutput
        case let .malformedJSON(rawText, underlyingError):
            return .malformedJSON(rawText: rawText, underlyingError: underlyingError)
        }
    }

    // MARK: - Response Parsing (Handles Gemini 3.8 / Gemini 4 Thinking Parts)

    public struct ExtractedGeneration: Sendable {
        public let jsonText: String
        public let promptTokens: Int?
        public let outputTokens: Int?
        public let cachedTokens: Int?
    }

    public static func extractJSONTextAndUsage(from data: Data) throws -> ExtractedGeneration {
        struct VertexResponse: Decodable {
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

        let decoded = try JSONDecoder().decode(VertexResponse.self, from: data)
        let parts = decoded.candidates?.first?.content?.parts ?? []

        // Exclude reasoning/thought parts emitted by Gemini 3.8 / Gemini 4 models
        let nonThoughtTexts = parts
            .filter { $0.thought != true }
            .compactMap(\.text)

        let rawJoined = nonThoughtTexts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawJoined.isEmpty else {
            throw VertexGeminiError.emptyModelOutput
        }

        let cleaned = stripMarkdownCodeFence(rawJoined)
        return ExtractedGeneration(
            jsonText: cleaned,
            promptTokens: decoded.usageMetadata?.promptTokenCount,
            outputTokens: decoded.usageMetadata?.candidatesTokenCount,
            cachedTokens: decoded.usageMetadata?.cachedContentTokenCount
        )
    }

    public static func stripMarkdownCodeFence(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            if let firstNewline = trimmed.firstIndex(of: "\n") {
                trimmed = String(trimmed[trimmed.index(after: firstNewline)...])
            }
            if trimmed.hasSuffix("```") {
                trimmed = String(trimmed.dropLast(3))
            }
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    // MARK: - HTTP Transport

    private func sendRequest(url: URL, apiKey: String, bodyObject: [String: Any]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyObject, options: [])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VertexGeminiError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let serverMsg = AIServiceClient.extractServerErrorMessage(from: data)
            throw VertexGeminiError.httpError(statusCode: http.statusCode, message: serverMsg)
        }

        return data
    }
}
