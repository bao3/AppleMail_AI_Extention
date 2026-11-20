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

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 90
            config.timeoutIntervalForResource = 120
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
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

        let systemText = """
        你是一名资深 B2B 工业通信、硬件工程与外贸商务邮件分析助手。请严格依据提供的邮件原文（头信息、附件文件名、最新正文、历史引用链）提取高信息密度中文分析，禁止捏造邮件中未出现的数据。
        输出要求（必须严格遵循 JSON Schema）：
        1. headline：用一句话概括这封邮件最核心的结论或诉求。
        2. coreConclusions：3~6 条高凝练核心要点（直奔主题，突出决策、变更、风险、交期或报价变化）。
        3. todos：提取明确或隐含的待办事项（task、owner 负责方、deadline 截止时间若无填 ""、priority 仅可为 "high" / "medium" / "low"）。
        4. businessElements：
           - projects：提及的项目名称、项目编号或客户内部代号；
           - customers：客户公司、终端用户、相关团队或联系人；
           - models：产品型号、SKU、物料号（Part Number）、规格配置；
           - pricing：所有报价明细（itemOrModel、quantity、unitPrice、currency、termsOrLeadTime 贸易条款/交期、notes）。若某子项未提及填 ""。
        5. plainChineseTranslation：将邮件最新正文（以及关键英文内容）翻译为通俗、自然、符合中国工程师与商务习惯的中文；若原信已是纯中文，则整理为条理清晰的白话摘要，不丢失关键数字与技术名词。
        6. timeline：如果是长信或多轮往来邮件，按时间由早到晚梳理关键来往节点（timeOrStep、actor、summary）；如果是单封短邮件，则输出 1~2 条关键节点。
        """

        let bodyObject: [String: Any] = [
            "systemInstruction": [
                "parts": [
                    ["text": systemText]
                ]
            ],
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": email.formattedPromptInput()]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.2,
                "responseMimeType": "application/json",
                "responseSchema": Self.emailAnalysisResponseSchema()
            ]
        ]

        let started = Date()
        let responseData = try await sendRequest(
            url: model.generateContentURL(projectID: resolvedProjectID),
            apiKey: trimmedKey,
            bodyObject: bodyObject
        )
        let latencyMs = Int(Date().timeIntervalSince(started) * 1000)

        let extracted = try Self.extractJSONTextAndUsage(from: responseData)
        let payloadData = Data(extracted.jsonText.utf8)

        struct RawEmailAnalysisPayload: Decodable {
            let headline: String
            let coreConclusions: [String]
            let todos: [EmailTodoItem]
            let businessElements: BusinessElements
            let plainChineseTranslation: String
            let timeline: [TimelineEvent]
        }

        do {
            let decoded = try JSONDecoder().decode(RawEmailAnalysisPayload.self, from: payloadData)
            return EmailAIAnalysis(
                headline: decoded.headline,
                coreConclusions: decoded.coreConclusions,
                todos: decoded.todos,
                businessElements: decoded.businessElements,
                plainChineseTranslation: decoded.plainChineseTranslation,
                timeline: decoded.timeline,
                messageID: email.messageID,
                modelUsed: model.rawValue,
                analyzedAt: Date(),
                promptTokens: extracted.promptTokens,
                outputTokens: extracted.outputTokens,
                cachedTokens: extracted.cachedTokens,
                latencyMs: latencyMs
            )
        } catch {
            throw VertexGeminiError.malformedJSON(
                rawText: extracted.jsonText,
                underlyingError: error.localizedDescription
            )
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

        let systemText = """
        你是一名精通跨国商务与技术沟通的双语邮件撰写专家。请根据用户意图、收件人信息以及原邮件上下文，撰写专业、地道、直接可用的英文回复草稿、中文回复草稿，以及中英双语对照版。
        风格要求：语气「\(tone)」，准确核对并沿用原信中的项目名、型号、数量、单价、交期与条款（不可擅自篡改数字）。
        输出 JSON 字段：
        - suggestedSubject：建议邮件主题；
        - englishDraft：可直接发送的地道英文邮件正文（含称呼与落款占位）；
        - chineseDraft：对应语义自然准确的中文邮件正文；
        - bilingualCombinedDraft：便于双语留档或发给双语团队的中英双语合并版本；
        - keyPointsCovered：本次回复涵盖的关键要点列表。
        """

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

        let bodyObject: [String: Any] = [
            "systemInstruction": [
                "parts": [
                    ["text": systemText]
                ]
            ],
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": userPromptLines.joined(separator: "\n")]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.3,
                "responseMimeType": "application/json",
                "responseSchema": Self.composeReplyResponseSchema()
            ]
        ]

        let responseData = try await sendRequest(
            url: model.generateContentURL(projectID: resolvedProjectID),
            apiKey: trimmedKey,
            bodyObject: bodyObject
        )
        let extracted = try Self.extractJSONTextAndUsage(from: responseData)
        let payloadData = Data(extracted.jsonText.utf8)

        struct RawComposePayload: Decodable {
            let suggestedSubject: String
            let englishDraft: String
            let chineseDraft: String
            let bilingualCombinedDraft: String
            let keyPointsCovered: [String]
        }

        do {
            let decoded = try JSONDecoder().decode(RawComposePayload.self, from: payloadData)
            return ComposeReplyDraft(
                suggestedSubject: decoded.suggestedSubject,
                englishDraft: decoded.englishDraft,
                chineseDraft: decoded.chineseDraft,
                bilingualCombinedDraft: decoded.bilingualCombinedDraft,
                keyPointsCovered: decoded.keyPointsCovered,
                modelUsed: model.rawValue,
                generatedAt: Date()
            )
        } catch {
            throw VertexGeminiError.malformedJSON(
                rawText: extracted.jsonText,
                underlyingError: error.localizedDescription
            )
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
            let serverMsg = extractServerErrorMessage(from: data)
            throw VertexGeminiError.httpError(statusCode: http.statusCode, message: serverMsg)
        }

        return data
    }

    private func extractServerErrorMessage(from data: Data) -> String {
        struct ErrorEnvelope: Decodable {
            struct Inner: Decodable {
                let message: String?
                let status: String?
            }
            let error: Inner?
        }
        if let parsed = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
           let message = parsed.error?.message
        {
            if let status = parsed.error?.status, !status.isEmpty {
                return "[\(status)] \(message)"
            }
            return message
        }
        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "未知服务端错误" : String(raw.prefix(400))
    }

    // MARK: - OpenAPI Subset Schemas for Vertex AI v1beta1

    private static func emailAnalysisResponseSchema() -> [String: Any] {
        [
            "type": "OBJECT",
            "properties": [
                "headline": ["type": "STRING"],
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
                            "priority": ["type": "STRING"]
                        ],
                        "required": ["task", "owner", "deadline", "priority"]
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
                "coreConclusions",
                "todos",
                "businessElements",
                "plainChineseTranslation",
                "timeline"
            ]
        ]
    }

    private static func composeReplyResponseSchema() -> [String: Any] {
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
}
