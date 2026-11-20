import Foundation
import MailKit
import OSLog

/// Automatically triggers background Gemini pre-analysis when Apple Mail downloads
/// new Moxa mailbox Primary messages, warming `AnalysisCacheStore` before the user opens them.
final class MessageActionHandler: NSObject, MEMessageActionHandler, @unchecked Sendable {
    nonisolated static let shared = MessageActionHandler()

    /// Soft timeout before returning `nil` to Mail so background pre-analysis never stalls Mail's download queue.
    private nonisolated static let decideActionSoftTimeoutSeconds: Double = 12

    private final class DecisionOnceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: ((MEMessageActionDecision?) -> Void)?

        init(_ handler: @escaping (MEMessageActionDecision?) -> Void) {
            self.handler = handler
        }

        func finish(_ decision: MEMessageActionDecision?) {
            lock.lock()
            let callback = handler
            handler = nil
            lock.unlock()
            callback?(decision)
        }
    }

    nonisolated override init() {
        super.init()
    }

    nonisolated var requiredHeaders: [String] {
        MoxaPrimaryFilter.requiredHeaders
    }

    nonisolated func decideAction(
        for message: MEMessage,
        completionHandler: @escaping (MEMessageActionDecision?) -> Void
    ) {
        let once = DecisionOnceBox(completionHandler)

        guard ExtensionOpsConfig.isAutoAnalyzeMoxaPrimaryEnabled else {
            ExtensionLogger.action.debug("decideAction skipped: autoAnalyzeMoxaPrimary disabled")
            once.finish(nil)
            return
        }

        guard hasConfiguredCredentials() else {
            ExtensionLogger.action.debug("decideAction skipped: API key or GCP Project ID not configured")
            once.finish(nil)
            return
        }

        // Pass 1: Metadata-only check before body download; ask Mail for body only if Moxa Primary passes.
        guard let rawData = message.rawData else {
            let input = makeFilterInput(from: message)
            switch MoxaPrimaryFilter.evaluate(input) {
            case let .skip(reason):
                ExtensionLogger.action.debug(
                    "decideAction skipped (no-body pass): \(reason.logDescription, privacy: .public)"
                )
                once.finish(nil)
            case .allowMoxaPrimary:
                if let headerMessageID = headerMessageID(from: message),
                   AnalysisCacheStore.shared.hasCachedAnalysis(forMessageID: headerMessageID)
                {
                    ExtensionLogger.action.debug("decideAction skipped (no-body pass): already cached")
                    once.finish(nil)
                    return
                }
                ExtensionLogger.action.info("decideAction requesting full body via invokeAgainWithBody for Moxa Primary message")
                once.finish(.invokeAgainWithBody)
            }
            return
        }

        // Pass 2: Full RFC 5322 rawData available.
        guard !rawData.isEmpty else {
            ExtensionLogger.action.debug("decideAction skipped: empty rawData")
            once.finish(nil)
            return
        }

        guard rawData.count <= MessageSecurityHandler.maxPassthroughRawBytes else {
            ExtensionLogger.action.warning(
                "decideAction skipped: rawData exceeds \(MessageSecurityHandler.maxPassthroughRawBytes, privacy: .public) bytes"
            )
            once.finish(nil)
            return
        }

        guard !MIMEParser.isProtectedSecurityEnvelope(rawData) else {
            ExtensionLogger.action.debug("decideAction skipped: protected S/MIME or PGP envelope")
            once.finish(nil)
            return
        }

        let mimeHeaders = MIMEParser.extractTopLevelHeaders(rawData)
        let fullInput = makeFilterInput(from: message, extraHeaders: mimeHeaders)
        if case let .skip(reason) = MoxaPrimaryFilter.evaluate(fullInput) {
            ExtensionLogger.action.debug(
                "decideAction skipped (full-body pass): \(reason.logDescription, privacy: .public)"
            )
            once.finish(nil)
            return
        }

        let parsed = MIMEParser.parse(rawData: rawData)
        ParsedEmailStore.shared.store(parsed)

        let hasTextContent = !parsed.plainBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !parsed.quotedChain.isEmpty
        guard hasTextContent else {
            ExtensionLogger.action.debug("decideAction skipped: empty plainBody and quotedChain")
            once.finish(nil)
            return
        }

        guard !AnalysisCacheStore.shared.hasCachedAnalysis(forMessageID: parsed.messageID) else {
            ExtensionLogger.action.debug("decideAction skipped (full-body pass): already cached")
            once.finish(nil)
            return
        }

        ExtensionLogger.action.info(
            "Starting background pre-analysis for Moxa Primary message (messageID=\(parsed.messageID, privacy: .private), bodyChars=\(parsed.plainBody.count, privacy: .public))"
        )

        Task.detached(priority: .utility) {
            do {
                _ = try await BackgroundAnalysisCoordinator.shared.analyzeIfNeeded(
                    email: parsed,
                    model: .flash38
                )
            } catch {
                ExtensionLogger.action.warning(
                    "Background pre-analysis failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            once.finish(nil)
        }

        let timeoutSeconds = Self.decideActionSoftTimeoutSeconds
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            once.finish(nil)
        }
    }

    // MARK: - Helpers

    private nonisolated func hasConfiguredCredentials() -> Bool {
        guard KeychainStore.shared.hasAPIKey() else { return false }
        let projectID = KeychainStore.shared.loadProjectID().trimmingCharacters(in: .whitespacesAndNewlines)
        return !projectID.isEmpty
    }

    private nonisolated func headerMessageID(from message: MEMessage) -> String? {
        guard let headers = message.headers else { return nil }
        for (key, values) in headers where key.lowercased() == "message-id" {
            for value in values {
                let normalized = ParsedEmailContext.normalizeMessageID(value)
                if !normalized.isEmpty {
                    return normalized
                }
            }
        }
        return nil
    }

    private nonisolated func makeFilterInput(
        from message: MEMessage,
        extraHeaders: [String: [String]] = [:]
    ) -> MessageFilterInput {
        var mergedHeaders: [String: [String]] = [:]
        if let msgHeaders = message.headers {
            for (key, values) in msgHeaders {
                mergedHeaders[key.lowercased(), default: []].append(contentsOf: values)
            }
        }
        for (key, values) in extraHeaders {
            let lower = key.lowercased()
            let existing = Set(mergedHeaders[lower] ?? [])
            let additions = values.filter { !existing.contains($0) }
            if !additions.isEmpty {
                mergedHeaders[lower, default: []].append(contentsOf: additions)
            }
        }

        return MessageFilterInput(
            isReceivedState: message.state == .received,
            isEncrypted: message.encryptionState == .encrypted,
            subject: message.subject,
            fromAddress: message.fromAddress.rawString,
            toAddresses: message.toAddresses.map(\.rawString),
            ccAddresses: message.ccAddresses.map(\.rawString),
            bccAddresses: message.bccAddresses.map(\.rawString),
            allRecipientAddresses: message.allRecipientAddresses.map(\.rawString),
            dateReceived: message.__dateReceived,
            headers: mergedHeaders
        )
    }
}
