import Foundation
import MailKit
import OSLog

/// Provides a toolbar button in Apple Mail's compose window to assist drafting bilingual replies
/// based on the original email context, without interfering with address validation, headers, or sending.
final class ComposeSessionHandler: NSObject, MEComposeSessionHandler {
    nonisolated override init() {
        super.init()
    }

    nonisolated func mailComposeSessionDidBegin(_ session: MEComposeSession) {
        ExtensionLogger.compose.info("mailComposeSessionDidBegin (mainThread=\(Thread.isMainThread, privacy: .public))")
    }

    nonisolated func mailComposeSessionDidEnd(_ session: MEComposeSession) {
        ExtensionLogger.compose.info("mailComposeSessionDidEnd (mainThread=\(Thread.isMainThread, privacy: .public))")
    }

    @MainActor
    func viewController(for session: MEComposeSession) -> MEExtensionViewController {
        ExtensionLogger.compose.info("viewController(for: MEComposeSession) requested")
        let originalEmail = extractOriginalEmail(from: session)
        let draftSubject = session.mailMessage.subject
        let recipients = session.mailMessage.allRecipientAddresses.map(\.rawString)
        return ComposeAssistantViewController(
            originalEmail: originalEmail,
            draftSubject: draftSubject,
            recipients: recipients
        )
    }

    @MainActor
    private func extractOriginalEmail(from session: MEComposeSession) -> ParsedEmailContext? {
        if let original = session.composeContext.originalMessage {
            if let rawData = original.rawData, !rawData.isEmpty {
                let parsed = MIMEParser.parse(rawData: rawData)
                ParsedEmailStore.shared.store(parsed)
                return parsed
            }

            // Fallback: try looking up from ParsedEmailStore using headers or Message-ID
            var candidateIDs: [String] = []
            if let msgIDs = original.headers?["message-id"] {
                candidateIDs.append(contentsOf: msgIDs)
            }
            if let inReply = session.mailMessage.headers?["in-reply-to"] {
                candidateIDs.append(contentsOf: inReply)
            }
            if let refs = session.mailMessage.headers?["references"] {
                candidateIDs.append(contentsOf: refs)
            }
            if let cachedParsed = ParsedEmailStore.shared.lookupAny(messageIDs: candidateIDs) {
                return cachedParsed
            }

            // Last-resort metadata-only context from MEMessage properties
            let messageID = original.headers?["message-id"]?.first ?? UUID().uuidString
            return ParsedEmailContext(
                messageID: messageID,
                subject: original.subject,
                from: original.fromAddress.rawString,
                to: original.toAddresses.map(\.rawString),
                cc: original.ccAddresses.map(\.rawString),
                dateString: "",
                inReplyTo: nil,
                references: [],
                plainBody: "(Apple Mail 未向下传原信原始 MIME 正文；仅获取到主题与收发件人头信息，如需补充可直接在下方粘贴原信片段)",
                quotedChain: [],
                attachments: []
            )
        }
        return nil
    }
}
