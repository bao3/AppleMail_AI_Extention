import Foundation
import XCTest

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class VertexGeminiClientTests: XCTestCase {
    private func makeMockClient() -> VertexGeminiClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return VertexGeminiClient(session: URLSession(configuration: config))
    }

    func testVertexGlobalEndpoints() {
        let projectID = "your-gcp-project-id"
        XCTAssertEqual(
            GeminiModel.flash38.generateContentURL(projectID: projectID).absoluteString,
            "https://aiplatform.googleapis.com/v1beta1/projects/your-gcp-project-id/locations/global/publishers/google/models/gemini-3.8-flash:generateContent"
        )
        XCTAssertEqual(
            GeminiModel.carbon4.generateContentURL(projectID: projectID).absoluteString,
            "https://aiplatform.googleapis.com/v1beta1/projects/your-gcp-project-id/locations/global/publishers/google/models/gemini-4-carbon:generateContent"
        )
        XCTAssertEqual(
            GeminiModel.flash38.countTokensURL(projectID: projectID).absoluteString,
            "https://aiplatform.googleapis.com/v1beta1/projects/your-gcp-project-id/locations/global/publishers/google/models/gemini-3.8-flash:countTokens"
        )
    }

    func testVerifyCountTokensAndAnalyzeFiltersThoughtParts() async throws {
        let client = makeMockClient()

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "AQ.test-key")
            let urlStr = request.url?.absoluteString ?? ""
            if urlStr.hasSuffix(":countTokens") {
                let body = Data(#"{"totalTokens": 1}"#.utf8)
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, body)
            }

            let innerJSON = """
            ```json
            {
              "headline": "客户确认批量采购 120 台 EDS-4012",
              "coreConclusions": ["单价 USD 485 FOB Taipei", "要求周五前开立 PI"],
              "todos": [
                {"task": "开立 PI", "owner": "我方商务", "deadline": "本周五", "priority": "high"}
              ],
              "businessElements": {
                "projects": ["Helios-III"],
                "customers": ["Acme Grid"],
                "models": ["EDS-4012-8GT4XS-HV-T"],
                "pricing": [
                  {"itemOrModel": "EDS-4012", "quantity": "120", "unitPrice": "485", "currency": "USD", "termsOrLeadTime": "FOB Taipei / 4 weeks", "notes": ""}
                ]
              },
              "plainChineseTranslation": "我们采购委员会已批准试产批次采购。",
              "timeline": [
                {"timeOrStep": "11-18", "actor": "Sales", "summary": "提交初步报价 USD 498"},
                {"timeOrStep": "11-19", "actor": "Marcus", "summary": "确认 120 台目标价 USD 485"}
              ]
            }
            ```
            """

            let envelope: [String: Any] = [
                "candidates": [
                    [
                        "content": [
                            "parts": [
                                ["text": "Internal reasoning trace that must be ignored", "thought": true],
                                ["text": innerJSON]
                            ]
                        ]
                    ]
                ],
                "usageMetadata": [
                    "promptTokenCount": 320,
                    "candidatesTokenCount": 140,
                    "cachedContentTokenCount": 64
                ]
            ]
            let body = try JSONSerialization.data(withJSONObject: envelope)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, body)
        }

        let tokenCount = try await client.verifyAPIKeyAndModel(
            apiKey: "AQ.test-key",
            model: .flash38,
            projectID: "your-gcp-project-id"
        )
        XCTAssertEqual(tokenCount, 1)

        let email = ParsedEmailContext(
            messageID: "<msg-1@example.com>",
            subject: "Helios-III",
            from: "marcus@acme.example",
            to: ["sales@example.com"],
            cc: [],
            dateString: "Thu, 19 Nov 2026 16:40:00 +0800",
            inReplyTo: nil,
            references: [],
            plainBody: "Proceed with 120 units @ USD 485.",
            quotedChain: [],
            attachments: []
        )

        let result = try await client.analyzeEmail(
            email,
            model: .carbon4,
            apiKey: "AQ.test-key",
            projectID: "your-gcp-project-id"
        )
        XCTAssertEqual(result.headline, "客户确认批量采购 120 台 EDS-4012")
        XCTAssertEqual(result.modelUsed, "gemini-4-carbon")
        XCTAssertEqual(result.messageID, "msg-1@example.com")
        XCTAssertEqual(result.promptTokens, 320)
        XCTAssertEqual(result.outputTokens, 140)
        XCTAssertEqual(result.cachedTokens, 64)
        XCTAssertEqual(result.timeline.count, 2)
    }

    func testGenerateBilingualReplyDraftAndHTTPErrorHandling() async throws {
        let client = makeMockClient()

        MockURLProtocol.requestHandler = { request in
            let innerJSON = """
            {
              "suggestedSubject": "Re: [Project Helios-III] Proforma Invoice & Compliance Reports",
              "englishDraft": "Dear Marcus,\\nThank you for confirming the 120-unit order...",
              "chineseDraft": "尊敬的 Marcus：\\n感谢确认 120 台订单……",
              "bilingualCombinedDraft": "Dear Marcus...\\n\\n---\\n中文对照：尊敬的 Marcus……",
              "keyPointsCovered": ["确认 USD 485 单价", "承诺周五前发送 PI 与测试报告"]
            }
            """
            let envelope: [String: Any] = [
                "candidates": [
                    ["content": ["parts": [["text": innerJSON]]]]
                ]
            ]
            let body = try JSONSerialization.data(withJSONObject: envelope)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, body)
        }

        let draft = try await client.generateReplyDraft(
            originalEmail: nil,
            draftSubject: "Helios-III",
            recipients: ["marcus@acme.example"],
            userIntent: "确认单价并在周五前发送 PI",
            tone: "商务专业",
            model: .flash38,
            apiKey: "AQ.test-key",
            projectID: "your-gcp-project-id"
        )
        XCTAssertEqual(draft.modelUsed, "gemini-3.8-flash")
        XCTAssertTrue(draft.englishDraft.contains("Dear Marcus"))
        XCTAssertEqual(draft.keyPointsCovered.count, 2)
    }
}
