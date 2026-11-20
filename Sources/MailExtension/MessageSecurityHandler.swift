import Foundation
import MailKit
import OSLog

/// Uses `MEMessageSecurityHandler` + `MEDecodedMessageBanner` strictly for read-only local MIME extraction
/// and presenting the "AI 汇总分析" top banner button.
/// Never signs, encrypts, decrypts, or alters any email payload (`rawData` returns the original `data` bytes
/// unchanged so Apple Mail renders the full body alongside our banner, while skipping >25 MB messages).
final class MessageSecurityHandler: NSObject, MEMessageSecurityHandler, @unchecked Sendable {
    nonisolated static let shared = MessageSecurityHandler()

    private struct SendableBox<Value>: @unchecked Sendable {
        let value: Value
    }

    /// Maximum raw MIME payload passed back via `MEDecodedMessage(data:)` over XPC (25 MB).
    nonisolated static let maxPassthroughRawBytes = 25 * 1024 * 1024

    /// Maximum JSON bytes placed into `MEDecodedMessage.context` for XPC transport.
    private nonisolated static let maxXPCContextBytes = 16 * 1024

    private let cacheStore: AnalysisCacheStore

    nonisolated init(cacheStore: AnalysisCacheStore = .shared) {
        self.cacheStore = cacheStore
        super.init()
    }

    // MARK: - Outgoing Encoding (Explicit Pass-Through)

    nonisolated func getEncodingStatus(
        for message: MEMessage,
        composeContext: MEComposeContext,
        completionHandler: @escaping (MEOutgoingMessageEncodingStatus) -> Void
    ) {
        let status = MEOutgoingMessageEncodingStatus(
            canSign: false,
            canEncrypt: false,
            securityError: nil,
            addressesFailingEncryption: []
        )
        completionHandler(status)
    }

    nonisolated func encode(
        _ message: MEMessage,
        composeContext: MEComposeContext,
        completionHandler: @escaping (MEMessageEncodingResult) -> Void
    ) {
        // Returning nil encodedMessage instructs Mail to send the message unchanged.
        let result = MEMessageEncodingResult(
            encodedMessage: nil,
            signingError: nil,
            encryptionError: nil
        )
        completionHandler(result)
    }

    // MARK: - Incoming Local Extraction & Banner Injection

    nonisolated func decodedMessage(forMessageData data: Data) -> MEDecodedMessage? {
        if ExtensionOpsConfig.isSecurityBannerDisabled {
            ExtensionLogger.security.info("decodedMessage skipped: disableSecurityBanner kill-switch is enabled")
            return nil
        }

        guard !data.isEmpty else {
            ExtensionLogger.security.debug("decodedMessage skipped: empty raw data")
            return nil
        }

        if data.count > Self.maxPassthroughRawBytes {
            ExtensionLogger.security.warning(
                "decodedMessage skipped: raw payload exceeds \(Self.maxPassthroughRawBytes, privacy: .public) bytes (\(data.count, privacy: .public)); letting Mail render natively"
            )
            return nil
        }

        // Leave S/MIME and PGP encrypted or signed envelopes untouched so Mail's native security pipeline handles them.
        if MIMEParser.isProtectedSecurityEnvelope(data) {
            ExtensionLogger.security.debug("decodedMessage skipped: protected S/MIME or PGP envelope (bytes=\(data.count, privacy: .public))")
            return nil
        }

        let started = CFAbsoluteTimeGetCurrent()

        // Pure local CPU extraction: zero network calls, zero body tampering.
        let parsed = MIMEParser.parse(rawData: data)
        ParsedEmailStore.shared.store(parsed)

        // Keep XPC context payload compact; full parsed context lives in ParsedEmailStore.shared.
        let contextData = makeCompactXPCContextData(for: parsed)

        // Check in-memory cache hint only (no synchronous disk I/O on Mail's decode hot path).
        let cachedHeadline = cacheStore.cachedHeadlineInMemory(forMessageID: parsed.messageID)
        let hasCached = cachedHeadline != nil || cacheStore.hasCachedAnalysisInMemory(forMessageID: parsed.messageID)
        let attachmentSuffix = parsed.attachments.isEmpty ? "" : " · \(parsed.attachments.count) 附件"
        let bannerTitle: String
        if let headline = cachedHeadline?.trimmingCharacters(in: .whitespacesAndNewlines), !headline.isEmpty {
            let headlineShort = headline.count > 56 ? String(headline.prefix(55)) + "…" : headline
            bannerTitle = "AI 已分析：\(headlineShort)\(attachmentSuffix)"
        } else {
            let cacheSuffix = hasCached ? " · 已缓存" : ""
            bannerTitle = "AI 邮件助手 · 本地已提取正文\(attachmentSuffix)\(cacheSuffix)"
        }

        let banner = MEDecodedMessageBanner(
            title: bannerTitle,
            primaryActionTitle: "AI 汇总分析",
            dismissable: true
        )

        let securityInfo = MEMessageSecurityInformation(
            signers: [],
            isEncrypted: false,
            signingError: nil,
            encryptionError: nil
        )

        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
        if elapsedMs > 50 {
            ExtensionLogger.security.warning(
                "decodedMessage slow parse: \(elapsedMs, privacy: .public)ms, rawBytes=\(data.count, privacy: .public), contextBytes=\(contextData.count, privacy: .public)"
            )
        } else {
            ExtensionLogger.security.debug(
                "decodedMessage completed in \(elapsedMs, privacy: .public)ms, rawBytes=\(data.count, privacy: .public), contextBytes=\(contextData.count, privacy: .public)"
            )
        }

        // Pass `data` back unchanged: per MailKit's `MEDecodedMessage` contract, returning a non-nil
        // `MEDecodedMessage` with `rawData == nil` causes Mail to render an empty body.
        return MEDecodedMessage(
            data: data,
            securityInformation: securityInfo,
            context: contextData,
            banner: banner
        )
    }

    // MARK: - View Controllers

    @MainActor
    func extensionViewController(signers messageSigners: [MEMessageSigner]) -> MEExtensionViewController? {
        nil
    }

    @MainActor
    func extensionViewController(messageContext context: Data) -> MEExtensionViewController? {
        ExtensionLogger.security.info("extensionViewController(messageContext:) called (bytes=\(context.count, privacy: .public))")
        let emailContext = resolveEmailContext(from: context)
        return MessageAnalysisViewController(emailContext: emailContext)
    }

    nonisolated func primaryActionClicked(
        forMessageContext context: Data,
        completionHandler: @escaping (MEExtensionViewController?) -> Void
    ) {
        ExtensionLogger.security.info(
            "primaryActionClicked invoked (bytes=\(context.count, privacy: .public), mainThread=\(Thread.isMainThread, privacy: .public))"
        )
        let emailContext = resolveEmailContext(from: context)
        let callbackBox = SendableBox(value: completionHandler)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let controller = MessageAnalysisViewController(emailContext: emailContext)
                callbackBox.value(controller)
            }
        }
    }

    // MARK: - Context Serialization Helpers

    private nonisolated func makeCompactXPCContextData(for parsed: ParsedEmailContext) -> Data {
        let compact = parsed.compactForXPCContext(maxBodyChars: 4_000, maxQuoteChars: 2_000)
        if let encoded = try? JSONEncoder().encode(compact), encoded.count <= Self.maxXPCContextBytes {
            return encoded
        }
        // Fallback to minimal metadata-only token if compact JSON still exceeds XPC budget.
        let minimal = ParsedEmailContext(
            messageID: parsed.messageID,
            subject: String(parsed.subject.prefix(240)),
            from: String(parsed.from.prefix(160)),
            to: [],
            cc: [],
            dateString: parsed.dateString,
            inReplyTo: parsed.inReplyTo,
            references: [],
            plainBody: String(parsed.plainBody.prefix(1_200)),
            quotedChain: [],
            attachments: Array(parsed.attachments.prefix(16))
        )
        return (try? JSONEncoder().encode(minimal)) ?? Data()
    }

    private nonisolated func resolveEmailContext(from contextData: Data) -> ParsedEmailContext {
        if let decoded = try? JSONDecoder().decode(ParsedEmailContext.self, from: contextData) {
            if let full = ParsedEmailStore.shared.lookup(messageID: decoded.messageID) {
                return full
            }
            return decoded
        }
        return ParsedEmailStore.shared.mostRecentParsedEmail ?? ParsedEmailContext(
            messageID: ParsedEmailContext.fallbackMessageID(from: contextData),
            subject: "无法读取邮件上下文",
            from: "",
            to: [],
            cc: [],
            dateString: "",
            inReplyTo: nil,
            references: [],
            plainBody: "MailKit 未提供有效的邮件上下文数据，请尝试重新打开该邮件。",
            quotedChain: [],
            attachments: []
        )
    }
}
