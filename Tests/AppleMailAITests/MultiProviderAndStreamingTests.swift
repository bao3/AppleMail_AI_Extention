import Foundation
import XCTest

private final class StreamingMockURLProtocol: URLProtocol, @unchecked Sendable {
    private final class HandlerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, [Data]))?

        func set(_ newHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, [Data]))?) {
            lock.lock()
            handler = newHandler
            lock.unlock()
        }

        func get() -> (@Sendable (URLRequest) throws -> (HTTPURLResponse, [Data]))? {
            lock.lock()
            defer { lock.unlock() }
            return handler
        }
    }

    private static let handlerBox = HandlerBox()

    static func setHandler(_ handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, [Data]))?) {
        handlerBox.set(handler)
    }

    private static func currentHandler() -> (@Sendable (URLRequest) throws -> (HTTPURLResponse, [Data]))? {
        handlerBox.get()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.currentHandler() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, chunks) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks where !chunk.isEmpty {
                client?.urlProtocol(self, didLoad: chunk)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class LockedCollector<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []

    func append(_ item: Element) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    func snapshot() -> [Element] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

final class MultiProviderAndStreamingTests: XCTestCase {
    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StreamingMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suite = "com.bao3.AppleMailAI.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private static func requestBodyJSON(_ request: URLRequest) -> [String: Any]? {
        let data: Data?
        if let body = request.httpBody {
            data = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var collected = Data()
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                collected.append(buffer, count: read)
            }
            data = collected
        } else {
            data = nil
        }
        guard let data else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func makeSampleEmail(body: String = "Please review Moxa_ENISA_SRP.pdf and quote 100x EDS-4012.") -> ParsedEmailContext {
        ParsedEmailContext(
            messageID: "<stream-test-1@moxa.com>",
            subject: "ENISA SRP & EDS-4012 Quote",
            from: "Marcus <marcus@acme.example>",
            to: ["sales@moxa.com"],
            cc: [],
            dateString: "Fri, 20 Nov 2026 10:00:00 +0800",
            inReplyTo: nil,
            references: [],
            plainBody: body,
            quotedChain: [],
            attachments: []
        )
    }

    // MARK: - PartialEmailAnalysisExtractor

    func testPartialExtractorHandlesEscapesSurrogatesAndNestedObjects() {
        XCTAssertEqual(PartialEmailAnalysisExtractor.extract(from: "{\"head"), .empty)

        // Partial headline with escapes and incomplete \u4e at boundary
        let p1 = #"{"headline": "客户反馈 \"Moxa_ENISA_SRP\" \n ==内容过于简单== \u4e"#
        let s1 = PartialEmailAnalysisExtractor.extract(from: p1)
        XCTAssertEqual(s1.headline, "客户反馈 \"Moxa_ENISA_SRP\" \n ==内容过于简单== ")
        XCTAssertNil(s1.suggestedFlag)

        // Complete \u4e2d\u6587 + surrogate emoji + unclosed suggestedFlag
        let p2 = #"```json"# + "\n" + #"{"headline": "\u4e2d\u6587标题 \uD83D\uDE80", "suggestedFlag": "yel"#
        let s2 = PartialEmailAnalysisExtractor.extract(from: p2)
        XCTAssertEqual(s2.headline, "中文标题 🚀")
        XCTAssertNil(s2.suggestedFlag)

        // Closed suggestedFlag + partial flagReason + partial coreConclusions + nested object ignored
        let p3 = """
        {
          "headline": "客户要求**提供正式PDF**",
          "suggestedFlag": "blue",
          "flagReason": "技术文档卡点",
          "coreConclusions": ["第1条：\\"报价\\", 确认", "第2条：交期\\
        """
        let s3 = PartialEmailAnalysisExtractor.extract(from: p3)
        XCTAssertEqual(s3.headline, "客户要求**提供正式PDF**")
        XCTAssertEqual(s3.suggestedFlag, "blue")
        XCTAssertEqual(s3.flagReason, "技术文档卡点")
        XCTAssertEqual(s3.coreConclusions, ["第1条：\"报价\", 确认", "第2条：交期"])

        // Nested "headline" inside todos must not clobber top-level headline; translation after nested fields still extracts
        let p4 = """
        {
          "headline": "顶层标题",
          "suggestedFlag": "yellow",
          "flagReason": "核价跟进",
          "coreConclusions": ["结论A"],
          "todos": [{"task": "check \\"headline\\": fake", "owner": "Sales", "deadline": "", "dueDateISO": "", "priority": "high"}],
          "businessElements": {"projects": ["P1"], "customers": [], "models": ["EDS-4012"], "pricing": []},
          "plainChineseTranslation": "请尽快确认 `EDS-4012` 单价
        """
        let s4 = PartialEmailAnalysisExtractor.extract(from: p4)
        XCTAssertEqual(s4.headline, "顶层标题")
        XCTAssertEqual(s4.suggestedFlag, "yellow")
        XCTAssertEqual(s4.coreConclusions, ["结论A"])
        XCTAssertEqual(s4.plainChineseTranslation, "请尽快确认 `EDS-4012` 单价")
    }

    // MARK: - AIProviderStore Migration & KeychainStore Compatibility

    func testAIProviderStoreMigratesLegacyVertexDefaultsAndSwitchesProfiles() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("legacy-gcp-proj", forKey: KeychainStore.userDefaultsProjectIDKey)
        defaults.set(GeminiModel.carbon4.rawValue, forKey: KeychainStore.userDefaultsModelKey)

        let store = AIProviderStore(userDefaults: defaults)
        XCTAssertEqual(store.activeProfileID, AIProviderProfile.defaultVertexProfileID)
        XCTAssertEqual(store.preferredTier, .deep)
        XCTAssertEqual(store.activeProfile.kind, .vertexAI)
        XCTAssertEqual(store.activeProfile.projectID, "legacy-gcp-proj")
        XCTAssertEqual(store.activeProfile.location, "global")
        XCTAssertEqual(store.activeProfile.fastModel, "gemini-3.8-flash")
        XCTAssertEqual(store.activeProfile.deepModel, "gemini-4-carbon")
        XCTAssertEqual(store.activeModelName(), "gemini-4-carbon")

        let customOpenAI = AIProviderProfile(
            id: "openai-custom",
            name: "DeepSeek Prod",
            kind: .openAICompatible,
            baseURL: "https://api.deepseek.com/v1/",
            fastModel: "deepseek-chat",
            deepModel: "deepseek-reasoner",
            customHeaders: ["X-Workspace": "moxa-tw"]
        )
        store.upsertProfile(customOpenAI, makeActive: true)
        store.setPreferredTier(.fast)

        // Reload in a fresh store backed by same UserDefaults
        let reloaded = AIProviderStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.profiles.count, 2)
        XCTAssertEqual(reloaded.activeProfileID, "openai-custom")
        XCTAssertEqual(reloaded.preferredTier, .fast)
        XCTAssertEqual(reloaded.activeProfile.normalizedBaseURL, "https://api.deepseek.com/v1")
        XCTAssertEqual(reloaded.activeModelName(), "deepseek-chat")
        XCTAssertEqual(AIProviderProfile.builtInPresets.count, 6)
    }

    func testKeychainPerProfileIsolationAndV1BackwardCompatibility() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let testService = "com.bao3.AppleMailAI.keychain-test.\(UUID().uuidString)"
        let keychain = KeychainStore(service: testService, userDefaults: defaults)
        defer {
            try? keychain.deleteAPIKey(forProfileID: AIProviderProfile.defaultVertexProfileID)
            try? keychain.deleteAPIKey(forProfileID: "openai-work")
        }

        XCTAssertEqual(
            KeychainStore.accountName(forProfileID: AIProviderProfile.defaultVertexProfileID),
            KeychainStore.apiKeyAccount
        )
        XCTAssertEqual(
            KeychainStore.accountName(forProfileID: "openai-work"),
            "provider-key-openai-work"
        )

        // Write with v1 method, read with v2 per-profile method
        try keychain.saveAPIKey("AQ.legacy-vertex-123456")
        XCTAssertEqual(
            keychain.loadAPIKey(forProfileID: AIProviderProfile.defaultVertexProfileID),
            "AQ.legacy-vertex-123456"
        )
        XCTAssertTrue(keychain.hasAPIKey(forProfileID: AIProviderProfile.defaultVertexProfileID))
        XCTAssertEqual(
            keychain.maskedAPIKeyStatus(forProfileID: AIProviderProfile.defaultVertexProfileID),
            "AQ.leg...3456 (已存入 Keychain)"
        )

        // Separate profile key does not overwrite default vertex key
        try keychain.saveAPIKey("sk-openai-abcdef9999", forProfileID: "openai-work")
        XCTAssertEqual(keychain.loadAPIKey(forProfileID: "openai-work"), "sk-openai-abcdef9999")
        XCTAssertEqual(keychain.loadAPIKey(), "AQ.legacy-vertex-123456")

        try keychain.deleteAPIKey(forProfileID: "openai-work")
        XCTAssertFalse(keychain.hasAPIKey(forProfileID: "openai-work"))
        XCTAssertTrue(keychain.hasAPIKey())
    }

    // MARK: - AIServiceClient Multi-Provider Streaming & Fallback

    func testVertexAISSEStreamingAndThoughtFiltering() async throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AIProviderStore(userDefaults: defaults)
        let client = AIServiceClient(session: makeMockSession(), providerStore: store)
        let vertexProfile = AIProviderProfile.defaultVertexProfile(projectID: "proj-vertex-1")

        let jsonPart1 = #"{"headline": "客户指出 `Moxa_ENISA_SRP` ==内容过于简单==", "suggestedFlag": "red", "#
        let jsonPart2 = #""flagReason": "需补正式合规PDF", "coreConclusions": ["要求**提供详细漏洞管理流程的正式PDF文档**"], "#
        let jsonPart3 = #""todos": [{"task": "**输出正式PDF流程文档**", "owner": "PSIRT", "deadline": "本周五", "dueDateISO": "2026-11-27", "priority": "high"}], "#
        let jsonPart4 = #""businessElements": {"projects": ["ENISA"], "customers": ["Acme"], "models": ["EDS-4012"], "pricing": []}, "plainChineseTranslation": "请提供完整漏洞管理文档。", "timeline": [{"timeOrStep": "11-20", "actor": "Marcus", "summary": "反馈==文档过简=="}]}"#

        StreamingMockURLProtocol.setHandler { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://aiplatform.googleapis.com/v1beta1/projects/proj-vertex-1/locations/global/publishers/google/models/gemini-3.8-flash:streamGenerateContent?alt=sse"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "AQ.test-key")

            let reqJSON = Self.requestBodyJSON(request)
            let genConfig = reqJSON?["generationConfig"] as? [String: Any]
            let thinking = genConfig?["thinkingConfig"] as? [String: Any]
            XCTAssertEqual(thinking?["thinkingBudget"] as? Int, 0)

            func sseLine(_ text: String, thought: Bool = false, usage: Bool = false) throws -> Data {
                var part: [String: Any] = ["text": text]
                if thought { part["thought"] = true }
                var obj: [String: Any] = [
                    "candidates": [["content": ["parts": [part]]]]
                ]
                if usage {
                    obj["usageMetadata"] = ["promptTokenCount": 210, "candidatesTokenCount": 95]
                }
                let raw = try JSONSerialization.data(withJSONObject: obj)
                return Data("data: \(String(decoding: raw, as: UTF8.self))\n\n".utf8)
            }

            let chunks: [Data] = [
                try sseLine("internal thinking must be ignored", thought: true),
                try sseLine(jsonPart1),
                try sseLine(jsonPart2),
                try sseLine(jsonPart3),
                try sseLine(jsonPart4, usage: true)
            ]
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (resp, chunks)
        }

        let snapshots = LockedCollector<PartialAnalysisSnapshot>()
        let analysis = try await client.analyzeEmail(
            makeSampleEmail(),
            profile: vertexProfile,
            tier: .fast,
            apiKeyOverride: "AQ.test-key"
        ) { snapshot in
            snapshots.append(snapshot)
        }

        let seen = snapshots.snapshot()
        XCTAssertGreaterThanOrEqual(seen.count, 3)
        XCTAssertEqual(seen.first?.suggestedFlag, "red")
        XCTAssertEqual(seen.first?.headline, "客户指出 `Moxa_ENISA_SRP` ==内容过于简单==")
        XCTAssertEqual(analysis.headline, "客户指出 `Moxa_ENISA_SRP` ==内容过于简单==")
        XCTAssertEqual(analysis.resolvedFlag, .red)
        XCTAssertEqual(analysis.promptTokens, 210)
        XCTAssertEqual(analysis.outputTokens, 95)
        XCTAssertEqual(analysis.modelUsed, "gemini-3.8-flash")
    }

    func testGeminiDeveloperSSEAndVerifyConnection() async throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let client = AIServiceClient(session: makeMockSession(), providerStore: AIProviderStore(userDefaults: defaults))
        let devProfile = AIProviderProfile(
            id: "gem-dev",
            name: "Gemini Dev",
            kind: .geminiDeveloper,
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            fastModel: "gemini-3.8-flash",
            deepModel: "gemini-4-carbon"
        )

        StreamingMockURLProtocol.setHandler { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "AIzaTest")
            let urlStr = request.url?.absoluteString ?? ""
            if urlStr.hasSuffix(":countTokens") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (resp, [Data(#"{"totalTokens": 7}"#.utf8)])
            }

            XCTAssertEqual(urlStr, "https://generativelanguage.googleapis.com/v1beta/models/gemini-4-carbon:streamGenerateContent?alt=sse")
            let reqJSON = Self.requestBodyJSON(request)
            let genConfig = reqJSON?["generationConfig"] as? [String: Any]
            let thinking = genConfig?["thinkingConfig"] as? [String: Any]
            XCTAssertEqual(thinking?["thinkingLevel"] as? String, "LOW")

            let payload = #"{"headline":"开发板确认","suggestedFlag":"green","flagReason":"重点项目推进","coreConclusions":["已确认"],"todos":[],"businessElements":{"projects":[],"customers":[],"models":[],"pricing":[]},"plainChineseTranslation":"确认无误。","timeline":[]}"#
            let sseObj: [String: Any] = ["candidates": [["content": ["parts": [["text": payload]]]]]]
            let sseRaw = try JSONSerialization.data(withJSONObject: sseObj)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            return (resp, [Data("data: \(String(decoding: sseRaw, as: UTF8.self))\n\n".utf8)])
        }

        let status = try await client.verifyConnection(profile: devProfile, apiKey: "AIzaTest", tier: .fast)
        XCTAssertTrue(status.contains("countTokens = 7"))

        let result = try await client.analyzeEmail(
            makeSampleEmail(),
            profile: devProfile,
            tier: .deep,
            apiKeyOverride: "AIzaTest"
        )
        XCTAssertEqual(result.headline, "开发板确认")
        XCTAssertEqual(result.resolvedFlag, .green)
        XCTAssertEqual(result.modelUsed, "gemini-4-carbon")
    }

    func testOpenAICompatibleSSEStreamingAndNonStreamingJSONFallback() async throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let client = AIServiceClient(session: makeMockSession(), providerStore: AIProviderStore(userDefaults: defaults))
        let openAIProfile = AIProviderProfile(
            id: "or-1",
            name: "OpenRouter",
            kind: .openAICompatible,
            baseURL: "https://openrouter.ai/api/v1",
            fastModel: "openai/gpt-4o-mini",
            deepModel: "openai/gpt-4o",
            customHeaders: ["X-Title": "AppleMailAI"]
        )

        // 1. Streaming SSE
        StreamingMockURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-or-test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Title"), "AppleMailAI")

            let reqJSON = Self.requestBodyJSON(request)
            XCTAssertEqual(reqJSON?["stream"] as? Bool, true)
            let respFmt = reqJSON?["response_format"] as? [String: Any]
            XCTAssertEqual(respFmt?["type"] as? String, "json_object")

            func chunk(_ content: String) throws -> Data {
                let obj: [String: Any] = ["choices": [["delta": ["content": content]]]]
                let raw = try JSONSerialization.data(withJSONObject: obj)
                return Data("data: \(String(decoding: raw, as: UTF8.self))\n\n".utf8)
            }

            let c1 = try chunk(#"{"headline":"OpenAI 流式结论","#)
            let c2 = try chunk(#""suggestedFlag":"yellow","flagReason":"核价中","coreConclusions":["单价确认"],"todos":[],"businessElements":{"projects":[],"customers":[],"models":["EDS-4012"],"pricing":[]},"plainChineseTranslation":"请确认价格。","timeline":[]}"#)
            let c3 = Data("data: [DONE]\n\n".utf8)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            return (resp, [c1, c2, c3])
        }

        let partials = LockedCollector<PartialAnalysisSnapshot>()
        let streamedResult = try await client.analyzeEmail(
            makeSampleEmail(),
            profile: openAIProfile,
            tier: .fast,
            apiKeyOverride: "sk-or-test"
        ) { snap in
            partials.append(snap)
        }
        XCTAssertEqual(streamedResult.headline, "OpenAI 流式结论")
        XCTAssertEqual(streamedResult.resolvedFlag, .yellow)
        XCTAssertFalse(partials.snapshot().isEmpty)
        XCTAssertEqual(partials.snapshot().first?.headline, "OpenAI 流式结论")

        // 2. Non-streaming application/json fallback
        StreamingMockURLProtocol.setHandler { request in
            let inner = """
            ```json
            {"headline":"非流式兜底成功","suggestedFlag":"orange","flagReason":"等审批","coreConclusions":["待主管审批"],"plainChineseTranslation":"请审批特价。"}
            ```
            """
            let envelope: [String: Any] = [
                "choices": [["message": ["content": inner]]],
                "usage": ["prompt_tokens": 100, "completion_tokens": 45]
            ]
            let data = try JSONSerialization.data(withJSONObject: envelope)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (resp, [data])
        }

        let fallbackResult = try await client.analyzeEmail(
            makeSampleEmail(),
            profile: openAIProfile,
            tier: .deep,
            apiKeyOverride: "sk-or-test"
        )
        XCTAssertEqual(fallbackResult.headline, "非流式兜底成功")
        XCTAssertEqual(fallbackResult.resolvedFlag, .orange)
        XCTAssertEqual(fallbackResult.promptTokens, 100)
        XCTAssertEqual(fallbackResult.outputTokens, 45)
        XCTAssertEqual(fallbackResult.modelUsed, "openai/gpt-4o")
    }

    func testAnthropicSSEFallbackReplyDraftAndGenerateJSONText() async throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AIProviderStore(userDefaults: defaults)
        let anthropicProfile = AIProviderProfile(
            id: "claude-prod",
            name: "Anthropic",
            kind: .anthropic,
            baseURL: "https://api.anthropic.com/v1",
            fastModel: "claude-3-5-haiku-latest",
            deepModel: "claude-sonnet-4-20250514",
            customHeaders: ["X-Proxy-Tag": "corp"]
        )
        store.upsertProfile(anthropicProfile, makeActive: true)

        let client = AIServiceClient(session: makeMockSession(), providerStore: store)

        // 1. SSE with thinking_delta ignored + content_block_delta text_delta
        StreamingMockURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Proxy-Tag"), "corp")

            let reqJSON = Self.requestBodyJSON(request)
            XCTAssertEqual(reqJSON?["max_tokens"] as? Int, 4096)
            XCTAssertEqual(reqJSON?["stream"] as? Bool, true)

            let e0 = Data("event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":180}}}\n\n".utf8)
            let e1 = Data("event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"secret\"}}\n\n".utf8)
            let e2 = Data("event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"{\\\"headline\\\":\\\"Claude 结论\\\",\\\"suggestedFlag\\\":\\\"purple\\\",\\\"flagReason\\\":\\\"PCN 变更\\\",\\\"coreConclusions\\\":[\\\"物料切换\\\"],\"}}\n\n".utf8)
            let e3 = Data("event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"\\\"plainChineseTranslation\\\":\\\"通知变更。\\\"}\"}}\n\n".utf8)
            let e4 = Data("event: message_delta\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":62}}\n\n".utf8)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            return (resp, [e0, e1, e2, e3, e4])
        }

        let snaps = LockedCollector<PartialAnalysisSnapshot>()
        let analysis = try await client.analyzeEmail(
            makeSampleEmail(),
            profile: anthropicProfile,
            tier: .fast,
            apiKeyOverride: "sk-ant-test"
        ) { snap in
            snaps.append(snap)
        }
        XCTAssertEqual(analysis.headline, "Claude 结论")
        XCTAssertEqual(analysis.resolvedFlag, .purple)
        XCTAssertEqual(analysis.promptTokens, 180)
        XCTAssertEqual(analysis.outputTokens, 62)
        XCTAssertFalse(snaps.snapshot().isEmpty)

        // 2. Non-streaming JSON fallback for generateReplyDraft
        StreamingMockURLProtocol.setHandler { request in
            let replyJSON = #"{"suggestedSubject":"Re: ENISA SRP","englishDraft":"Dear Marcus,\nPlease find attached.","chineseDraft":"尊敬的 Marcus：\n请查收附件。","bilingualCombinedDraft":"Dear Marcus...\n---\n请查收附件。","keyPointsCovered":["提供 PDF 文档"]}"#
            let bodyObj: [String: Any] = [
                "content": [
                    ["type": "thinking", "thinking": "ignored"],
                    ["type": "text", "text": replyJSON]
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: bodyObj)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (resp, [data])
        }

        let draft = try await client.generateReplyDraft(
            originalEmail: makeSampleEmail(),
            draftSubject: "ENISA SRP",
            recipients: ["marcus@acme.example"],
            userIntent: "发送正式 PDF 文档",
            tone: "商务专业",
            profile: anthropicProfile,
            tier: .deep,
            apiKeyOverride: "sk-ant-test"
        )
        XCTAssertEqual(draft.suggestedSubject, "Re: ENISA SRP")
        XCTAssertEqual(draft.modelUsed, "claude-sonnet-4-20250514")
        XCTAssertEqual(draft.keyPointsCovered, ["提供 PDF 文档"])

        // 3. generateJSONText using Keychain key & active profile
        let testService = "com.bao3.AppleMailAI.json-text-test.\(UUID().uuidString)"
        let testKeychain = KeychainStore(service: testService, userDefaults: defaults)
        try testKeychain.saveAPIKey("sk-ant-kc", forProfileID: "claude-prod")
        defer { try? testKeychain.deleteAPIKey(forProfileID: "claude-prod") }

        let kcClient = AIServiceClient(session: makeMockSession(), providerStore: store, keychainStore: testKeychain)
        StreamingMockURLProtocol.setHandler { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-kc")
            let data = Data("event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"{\\\"folder\\\":\\\"9_产品文件\\\"}\"}}\n\n".utf8)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            return (resp, [data])
        }

        let jsonStr = try await kcClient.generateJSONText(
            systemPrompt: "Return JSON.",
            userPrompt: "Pick folder."
        )
        XCTAssertEqual(jsonStr, #"{"folder":"9_产品文件"}"#)
    }

    // MARK: - Disclaimer Stripping & Background Coordinator

    func testFormattedPromptInputStripsTrailingConfidentialityDisclaimer() {
        let bodyWithEnglishFooter = """
        Hi Team,
        Please confirm USD 485 for 120 units of EDS-4012.

        Best regards,
        Alice

        --
        CONFIDENTIALITY NOTICE: This email and any attachments are confidential and may be legally privileged. If you are not the intended recipient, please notify the sender immediately and delete this message.
        """
        let email = makeSampleEmail(body: bodyWithEnglishFooter)
        let prompt = email.formattedPromptInput()
        XCTAssertTrue(prompt.contains("Please confirm USD 485"))
        XCTAssertTrue(prompt.contains("Best regards"))
        XCTAssertFalse(prompt.contains("CONFIDENTIALITY NOTICE"))
        XCTAssertFalse(prompt.contains("not the intended recipient"))

        let bodyWithChineseFooter = """
        您好，请审批特价。

        ___
        本邮件及其附件包含保密信息，仅供指定收件人使用。如误收请立即删除。
        """
        let emailCN = makeSampleEmail(body: bodyWithChineseFooter)
        let promptCN = emailCN.formattedPromptInput()
        XCTAssertTrue(promptCN.contains("您好，请审批特价。"))
        XCTAssertFalse(promptCN.contains("本邮件及其附件包含保密信息"))

        // Legitimate body text mentioning "confidential" mid-message stays intact
        let legitimateBody = """
        Please review our confidential pricing schedule for Q4 in Section 2.
        We need your approval by Friday.
        """
        let legitEmail = makeSampleEmail(body: legitimateBody)
        XCTAssertTrue(legitEmail.formattedPromptInput().contains("confidential pricing schedule"))
    }

    func testBackgroundAnalysisCoordinatorUsesMaxConcurrent3AndMultiProviderClient() async throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BgCoordCache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testService = "com.bao3.AppleMailAI.bg-test.\(UUID().uuidString)"
        let keychain = KeychainStore(service: testService, userDefaults: defaults)
        try keychain.saveAPIKey("sk-bg-test", forProfileID: "openai-bg")
        defer { try? keychain.deleteAPIKey(forProfileID: "openai-bg") }

        let store = AIProviderStore(userDefaults: defaults, keychainStore: keychain)
        let openAI = AIProviderProfile(
            id: "openai-bg",
            name: "OpenAI BG",
            kind: .openAICompatible,
            fastModel: "gpt-4o-mini",
            deepModel: "gpt-4o"
        )
        store.upsertProfile(openAI, makeActive: true)

        let aiClient = AIServiceClient(session: makeMockSession(), providerStore: store, keychainStore: keychain)
        let cache = AnalysisCacheStore(baseDirectory: tempDir)
        let coordinator = BackgroundAnalysisCoordinator(aiClient: aiClient, cacheStore: cache)
        XCTAssertEqual(coordinator.maxConcurrent, 3)

        StreamingMockURLProtocol.setHandler { request in
            let inner = #"{"headline":"后台多服务商预分析成功","suggestedFlag":"yellow","flagReason":"跟进报价","coreConclusions":["OK"],"todos":[],"businessElements":{"projects":[],"customers":[],"models":[],"pricing":[]},"plainChineseTranslation":"摘要。","timeline":[]}"#
            let env: [String: Any] = ["choices": [["message": ["content": inner]]]]
            let data = try JSONSerialization.data(withJSONObject: env)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (resp, [data])
        }

        let email = makeSampleEmail()
        let result = try await coordinator.analyzeIfNeeded(email: email, tier: .fast)
        XCTAssertEqual(result.headline, "后台多服务商预分析成功")
        XCTAssertEqual(result.modelUsed, "gpt-4o-mini")
        XCTAssertNotNil(cache.load(forMessageID: email.messageID))
    }

    @MainActor
    func testKeychainSettingsViewModelInitializesAndRefreshesActiveNonVertexProfile() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let testService = "com.bao3.AppleMailAI.settings-vm-test.\(UUID().uuidString)"
        let keychain = KeychainStore(service: testService, userDefaults: defaults)
        try keychain.saveAPIKey("sk-openai-12345678", forProfileID: "preset-openai")
        defer {
            try? keychain.deleteAPIKey(forProfileID: "preset-openai")
            try? keychain.deleteAPIKey(forProfileID: AIProviderProfile.defaultVertexProfileID)
        }

        let store = AIProviderStore(userDefaults: defaults, keychainStore: keychain)
        let openAIPreset = try XCTUnwrap(AIProviderProfile.builtInPresets.first(where: { $0.id == "preset-openai" }))
        store.upsertProfile(openAIPreset, makeActive: true)
        XCTAssertEqual(store.activeProfile.id, "preset-openai")

        let aiClient = AIServiceClient(session: makeMockSession(), providerStore: store, keychainStore: keychain)
        let bookmarkStore = WorkspaceBookmarkStore(userDefaults: defaults)
        let vm = KeychainSettingsViewModel(
            keychain: keychain,
            providerStore: store,
            aiClient: aiClient,
            bookmarkStore: bookmarkStore
        )

        XCTAssertEqual(vm.activeProfileID, "preset-openai")
        XCTAssertEqual(vm.editingProfile.id, "preset-openai")
        XCTAssertEqual(vm.editingProfile.kind, .openAICompatible)
        XCTAssertTrue(vm.maskedKeyStatus?.contains("sk-ope") == true)

        // Unsaved edits must survive .onAppear refreshState() while activeProfileID stays unchanged.
        vm.editingProfile.fastModel = "gpt-4.1-mini"
        vm.refreshState()
        XCTAssertEqual(vm.editingProfile.id, "preset-openai")
        XCTAssertEqual(vm.editingProfile.fastModel, "gpt-4.1-mini")
    }

    func testOpenAICompatibleLossyNumericFieldsDecodeCleanly() async throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let client = AIServiceClient(session: makeMockSession(), providerStore: AIProviderStore(userDefaults: defaults))
        let magpieProfile = AIProviderProfile(
            id: "magpie-test",
            name: "Magpie",
            kind: .openAICompatible,
            baseURL: "http://192.168.50.60:3425/v1",
            fastModel: "group/smart-split",
            deepModel: "google-vertex/gemini-4-hydrogen"
        )

        StreamingMockURLProtocol.setHandler { request in
            let inner = """
            {
              "headline": "TN-4908 报价确认",
              "suggestedFlag": "yellow",
              "flagReason": "报价跟进",
              "coreConclusions": ["数量 60 台"],
              "todos": [{"task": "确认报价单", "owner": "商务", "deadline": 1125, "dueDateISO": null, "priority": "high"}],
              "businessElements": {
                "projects": ["Wavelet"],
                "customers": ["CRRC"],
                "models": ["TN-4908-4GTX-WV-CT-T"],
                "pricing": [{"itemOrModel": "TN-4908-4GTX-WV-CT-T", "quantity": 60, "unitPrice": 16350.5, "currency": "RMB", "termsOrLeadTime": 4, "notes": false}]
              },
              "plainChineseTranslation": "确认价格与数量。",
              "timeline": [{"timeOrStep": 1, "actor": "销售", "summary": "提交特价"}]
            }
            """
            let envelope: [String: Any] = ["choices": [["message": ["content": inner]]]]
            let data = try JSONSerialization.data(withJSONObject: envelope)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (resp, [data])
        }

        let result = try await client.analyzeEmail(
            makeSampleEmail(),
            profile: magpieProfile,
            tier: .fast,
            apiKeyOverride: "sk-magpie-test"
        )
        XCTAssertEqual(result.todos.first?.deadline, "1125")
        XCTAssertNil(result.todos.first?.dueDateISO)
        XCTAssertEqual(result.businessElements.pricing.first?.quantity, "60")
        XCTAssertEqual(result.businessElements.pricing.first?.unitPrice, "16350.5")
        XCTAssertEqual(result.businessElements.pricing.first?.termsOrLeadTime, "4")
        XCTAssertEqual(result.businessElements.pricing.first?.notes, "false")
        XCTAssertEqual(result.timeline.first?.timeOrStep, "1")
    }

    func testVerifyConnectionSendsHelloAndAcceptsAnyNonErrorServerResponse() async throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let client = AIServiceClient(session: makeMockSession(), providerStore: AIProviderStore(userDefaults: defaults))
        let openAIProfile = AIProviderProfile(
            id: "openai-hello",
            name: "OpenAI Proxy",
            kind: .openAICompatible,
            baseURL: "https://example.com/v1",
            fastModel: "deepseek-reasoner",
            deepModel: "gpt-5"
        )

        // 1. Reasoning-only / empty content response still counts as available
        StreamingMockURLProtocol.setHandler { request in
            let reqJSON = Self.requestBodyJSON(request)
            let messages = reqJSON?["messages"] as? [[String: Any]]
            XCTAssertEqual(messages?.first?["content"] as? String, "hello")

            let envelope: [String: Any] = ["choices": [["message": ["content": NSNull(), "reasoning_content": "thinking..."]]]]
            let data = try JSONSerialization.data(withJSONObject: envelope)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (resp, [data])
        }

        let ok = try await client.verifyConnection(profile: openAIProfile, apiKey: "sk-test", tier: .fast)
        XCTAssertTrue(ok.contains("连接正常"))

        // 2. Embedded JSON error object on HTTP 200 still fails
        StreamingMockURLProtocol.setHandler { request in
            let envelope: [String: Any] = ["error": ["code": 401, "message": "Invalid API Key"]]
            let data = try JSONSerialization.data(withJSONObject: envelope)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (resp, [data])
        }

        do {
            _ = try await client.verifyConnection(profile: openAIProfile, apiKey: "sk-bad", tier: .fast)
            XCTFail("Expected embedded error to throw")
        } catch let error as AIServiceError {
            if case let .httpError(code, msg) = error {
                XCTAssertEqual(code, 401)
                XCTAssertEqual(msg, "Invalid API Key")
            } else {
                XCTFail("Unexpected AIServiceError: \(error)")
            }
        }
    }

    func testAnalyzeEmailReportsConnectionStateChangedOnHTTP200() async throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let client = AIServiceClient(session: makeMockSession(), providerStore: AIProviderStore(userDefaults: defaults))
        let profile = AIProviderProfile(
            id: "conn-test",
            name: "Conn",
            kind: .openAICompatible,
            baseURL: "https://example.com/v1",
            fastModel: "gpt-4o-mini",
            deepModel: "gpt-4o"
        )

        StreamingMockURLProtocol.setHandler { request in
            let payload = #"{"headline":"OK","suggestedFlag":"none","flagReason":"","coreConclusions":[],"todos":[],"businessElements":{"projects":[],"customers":[],"models":[],"pricing":[]},"plainChineseTranslation":"好","timeline":[]}"#
            let envelope: [String: Any] = ["choices": [["message": ["content": payload]]]]
            let data = try JSONSerialization.data(withJSONObject: envelope)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (resp, [data])
        }

        let box = ConnectionFlagBox()
        _ = try await client.analyzeEmail(
            makeSampleEmail(),
            profile: profile,
            tier: .fast,
            apiKeyOverride: "sk-test",
            onConnectionStateChanged: { connected in
                box.set(connected)
            }
        )
        XCTAssertTrue(box.value)
    }

    func testSharedAppGroupLegacyMigrationMergesHostAndExtensionWithoutLosingMagpie() throws {
        let (hostLegacy, hostSuite) = makeIsolatedDefaults()
        let (extLegacy, extSuite) = makeIsolatedDefaults()
        let (sharedGroup, sharedSuite) = makeIsolatedDefaults()
        defer {
            hostLegacy.removePersistentDomain(forName: hostSuite)
            extLegacy.removePersistentDomain(forName: extSuite)
            sharedGroup.removePersistentDomain(forName: sharedSuite)
        }

        let encoder = JSONEncoder()
        let hostVertex = AIProviderProfile.defaultVertexProfile(projectID: "")
        hostLegacy.set(try encoder.encode([hostVertex]), forKey: AIProviderStore.profilesDefaultsKey)
        hostLegacy.set(AIProviderProfile.defaultVertexProfileID, forKey: AIProviderStore.activeProfileIDDefaultsKey)

        let extVertex = AIProviderProfile.defaultVertexProfile(projectID: "gen-lang-client-test")
        let magpieProfile = AIProviderProfile(
            id: "magpie-profile-id",
            name: "Magpie",
            kind: .openAICompatible,
            baseURL: "http://192.168.50.60:3425/v1",
            fastModel: "group/smart-split",
            deepModel: "google-vertex/gemini-4-hydrogen"
        )
        extLegacy.set(try encoder.encode([extVertex, magpieProfile]), forKey: AIProviderStore.profilesDefaultsKey)
        extLegacy.set(magpieProfile.id, forKey: AIProviderStore.activeProfileIDDefaultsKey)
        extLegacy.set("gen-lang-client-test", forKey: KeychainStore.userDefaultsProjectIDKey)
        extLegacy.set(["k1", "k2"], forKey: ReminderService.addedKeysDefaultsKey)
        extLegacy.set(false, forKey: ExtensionOpsConfig.autoFlagMoxaPrimaryKey)

        SharedAppGroup.migrateLegacyDefaultsIfNeeded(from: hostLegacy, to: sharedGroup)
        SharedAppGroup.migrateLegacyDefaultsIfNeeded(from: extLegacy, to: sharedGroup)

        let store = AIProviderStore(userDefaults: sharedGroup)
        XCTAssertEqual(store.profiles.count, 2)
        XCTAssertEqual(store.activeProfile.id, magpieProfile.id)
        XCTAssertEqual(store.activeProfile.name, "Magpie")
        XCTAssertEqual(store.profile(forID: AIProviderProfile.defaultVertexProfileID)?.projectID, "gen-lang-client-test")
        XCTAssertEqual(sharedGroup.stringArray(forKey: ReminderService.addedKeysDefaultsKey), ["k1", "k2"])
        XCTAssertEqual(sharedGroup.object(forKey: ExtensionOpsConfig.autoFlagMoxaPrimaryKey) as? Bool, false)

        // Verify idempotency when re-run
        SharedAppGroup.migrateLegacyDefaultsIfNeeded(from: hostLegacy, to: sharedGroup)
        SharedAppGroup.migrateLegacyDefaultsIfNeeded(from: extLegacy, to: sharedGroup)
        let storeReloaded = AIProviderStore(userDefaults: sharedGroup)
        XCTAssertEqual(storeReloaded.profiles.count, 2)
        XCTAssertEqual(storeReloaded.activeProfile.id, magpieProfile.id)
    }

    func testSharedAppGroupLegacyCacheMigrationCopiesMissingFilesNonDestructively() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("AppGroupCacheMig-\(UUID().uuidString)", isDirectory: true)
        let legacyAppSupport = tempRoot.appendingPathComponent("LegacySupport", isDirectory: true)
        let sharedAppSupport = tempRoot.appendingPathComponent("SharedSupport", isDirectory: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let legacyCache = legacyAppSupport.appendingPathComponent("AppleMailAI/MessageCache", isDirectory: true)
        let sharedCache = sharedAppSupport.appendingPathComponent("AppleMailAI/MessageCache", isDirectory: true)
        try fm.createDirectory(at: legacyCache, withIntermediateDirectories: true)
        try fm.createDirectory(at: sharedCache, withIntermediateDirectories: true)

        try Data("old-a".utf8).write(to: legacyCache.appendingPathComponent("a.json"))
        try Data("from-legacy-b".utf8).write(to: legacyCache.appendingPathComponent("b.json"))
        try Data("new-a".utf8).write(to: sharedCache.appendingPathComponent("a.json"))

        SharedAppGroup.migrateLegacyCacheDirectoryIfNeeded(from: legacyAppSupport, to: sharedAppSupport)

        let aData = try Data(contentsOf: sharedCache.appendingPathComponent("a.json"))
        let bData = try Data(contentsOf: sharedCache.appendingPathComponent("b.json"))
        XCTAssertEqual(String(decoding: aData, as: UTF8.self), "new-a")
        XCTAssertEqual(String(decoding: bData, as: UTF8.self), "from-legacy-b")

        let markerURL = legacyAppSupport.appendingPathComponent("AppleMailAI/.migrated-to-app-group")
        XCTAssertTrue(fm.fileExists(atPath: markerURL.path))
    }

    func testFetchAvailableModelsSupportsOpenAIGeminiAndAnthropicResponses() async throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let client = AIServiceClient(session: makeMockSession(), providerStore: AIProviderStore(userDefaults: defaults))

        // 1. OpenAI-compatible with /chat/completions suffix stripped -> /models
        let openAIProfile = AIProviderProfile(
            id: "openai-models",
            name: "Magpie",
            kind: .openAICompatible,
            baseURL: "http://192.168.50.60:3425/v1/chat/completions"
        )
        StreamingMockURLProtocol.setHandler { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "http://192.168.50.60:3425/v1/models")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
            let body: [String: Any] = [
                "data": [
                    ["id": "gpt-4o"],
                    ["id": "group/smart-split"],
                    ["id": "gpt-4o"],
                    ["id": "google-vertex/gemini-4-hydrogen"]
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: body)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (resp, [data])
        }
        let openAIModels = try await client.fetchAvailableModels(profile: openAIProfile, apiKey: "sk-test")
        XCTAssertEqual(openAIModels, ["google-vertex/gemini-4-hydrogen", "gpt-4o", "group/smart-split"])

        // 2. Gemini Developer strips "models/" and filters by generateContent
        let geminiProfile = AIProviderProfile(
            id: "gemini-models",
            name: "Gemini",
            kind: .geminiDeveloper,
            baseURL: "https://generativelanguage.googleapis.com/v1beta"
        )
        StreamingMockURLProtocol.setHandler { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "AIzaTest")
            let body: [String: Any] = [
                "models": [
                    ["name": "models/embedding-001", "supportedGenerationMethods": ["embedContent"]],
                    ["name": "models/gemini-2.5-pro", "supportedGenerationMethods": ["generateContent"]],
                    ["name": "models/gemini-2.5-flash", "supportedGenerationMethods": ["generateContent", "countTokens"]]
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: body)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (resp, [data])
        }
        let geminiModels = try await client.fetchAvailableModels(profile: geminiProfile, apiKey: "AIzaTest")
        XCTAssertEqual(geminiModels, ["gemini-2.5-flash", "gemini-2.5-pro"])

        // 3. Anthropic models endpoint
        let anthropicProfile = AIProviderProfile(
            id: "claude-models",
            name: "Claude",
            kind: .anthropic,
            baseURL: "https://api.anthropic.com/v1"
        )
        StreamingMockURLProtocol.setHandler { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/models")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            let body: [String: Any] = [
                "data": [
                    ["id": "claude-sonnet-4-20250514"],
                    ["id": "claude-3-5-haiku-latest"]
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: body)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (resp, [data])
        }
        let anthropicModels = try await client.fetchAvailableModels(profile: anthropicProfile, apiKey: "sk-ant-test")
        XCTAssertEqual(anthropicModels, ["claude-3-5-haiku-latest", "claude-sonnet-4-20250514"])

        // 4. Embedded JSON error payload on HTTP 200 throws AIServiceError.httpError
        StreamingMockURLProtocol.setHandler { request in
            let body: [String: Any] = ["error": ["code": 403, "message": "Forbidden"]]
            let data = try JSONSerialization.data(withJSONObject: body)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (resp, [data])
        }
        do {
            _ = try await client.fetchAvailableModels(profile: openAIProfile, apiKey: "sk-bad")
            XCTFail("Expected embedded error to throw")
        } catch let error as AIServiceError {
            if case let .httpError(code, msg) = error {
                XCTAssertEqual(code, 403)
                XCTAssertEqual(msg, "Forbidden")
            } else {
                XCTFail("Unexpected AIServiceError: \(error)")
            }
        }
    }
}

private final class ConnectionFlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func set(_ newValue: Bool) {
        lock.lock()
        defer { lock.unlock() }
        _value = newValue
    }
}
