import Foundation

public struct MessageFilterInput: Sendable {
    public let isReceivedState: Bool
    public let isEncrypted: Bool
    public let subject: String
    public let fromAddress: String
    public let toAddresses: [String]
    public let ccAddresses: [String]
    public let bccAddresses: [String]
    public let allRecipientAddresses: [String]
    public let dateReceived: Date?
    public let headers: [String: [String]]

    public init(
        isReceivedState: Bool,
        isEncrypted: Bool,
        subject: String,
        fromAddress: String,
        toAddresses: [String] = [],
        ccAddresses: [String] = [],
        bccAddresses: [String] = [],
        allRecipientAddresses: [String] = [],
        dateReceived: Date? = nil,
        headers: [String: [String]] = [:]
    ) {
        self.isReceivedState = isReceivedState
        self.isEncrypted = isEncrypted
        self.subject = subject
        self.fromAddress = fromAddress
        self.toAddresses = toAddresses
        self.ccAddresses = ccAddresses
        self.bccAddresses = bccAddresses
        self.allRecipientAddresses = allRecipientAddresses
        self.dateReceived = dateReceived
        var normalized: [String: [String]] = [:]
        for (key, values) in headers {
            normalized[key.lowercased(), default: []].append(contentsOf: values)
        }
        self.headers = normalized
    }
}

public enum FilterSkipReason: Equatable, Sendable {
    case notReceivedState
    case encrypted
    case tooOld
    case nonMoxaAccount(String)
    case selfSent
    case spamOrBulk(String)
    case newsletterOrPromotion(String)
    case automatedSystem(String)
    case calendarNotification

    public var logDescription: String {
        switch self {
        case .notReceivedState:
            return "notReceivedState"
        case .encrypted:
            return "encrypted"
        case .tooOld:
            return "tooOld(>48h)"
        case let .nonMoxaAccount(detail):
            return "nonMoxaAccount(\(detail))"
        case .selfSent:
            return "selfSent"
        case let .spamOrBulk(detail):
            return "spamOrBulk(\(detail))"
        case let .newsletterOrPromotion(detail):
            return "newsletterOrPromotion(\(detail))"
        case let .automatedSystem(detail):
            return "automatedSystem(\(detail))"
        case .calendarNotification:
            return "calendarNotification"
        }
    }
}

public enum FilterDecision: Equatable, Sendable {
    case allowMoxaPrimary
    case skip(FilterSkipReason)
}

/// Deterministic filter restricting background AI pre-analysis strictly to Moxa mailbox Primary messages.
public enum MoxaPrimaryFilter {
    public static let moxaTenantID = "5571c7d4-286b-47f6-9dd5-0aa688773c8e"
    public static let userMoxaAddress = "baoshan.wang@moxa.com"
    public static let maxAutoAnalyzeAgeSeconds: TimeInterval = 48 * 3600

    public static let requiredHeaders: [String] = [
        "message-id",
        "from",
        "to",
        "cc",
        "delivered-to",
        "x-ms-exchange-crosstenant-id",
        "x-ms-exchange-organization-scl",
        "list-unsubscribe",
        "list-id",
        "precedence",
        "auto-submitted",
        "x-auto-response-suppress"
    ]

    private static let botAddresses: Set<String> = [
        "portal.admin@moxa.com",
        "oa.admin@moxa.com",
        "it@moxa.com"
    ]

    private static let botLocalSubstrings: [String] = [
        "noreply",
        "no-reply",
        "donotreply",
        "do-not-reply",
        "mailer-daemon",
        "postmaster"
    ]

    private static let botExactLocals: Set<String> = [
        "notification",
        "notifications",
        "alert",
        "alerts",
        "system",
        "daemon",
        "bounces"
    ]

    private static let calendarPrefixes: [String] = [
        "accepted:",
        "declined:",
        "tentative:",
        "canceled:",
        "cancelled:",
        "已接受:",
        "已拒绝:",
        "暂定:",
        "已取消:",
        "已接受：",
        "已拒绝：",
        "暂定：",
        "已取消："
    ]

    public static func evaluate(_ input: MessageFilterInput, now: Date = Date()) -> FilterDecision {
        guard input.isReceivedState else {
            return .skip(.notReceivedState)
        }
        guard !input.isEncrypted else {
            return .skip(.encrypted)
        }

        if let dateReceived = input.dateReceived,
           now.timeIntervalSince(dateReceived) > maxAutoAnalyzeAgeSeconds
        {
            return .skip(.tooOld)
        }

        // 1. Moxa mailbox scope check (with Delivered-To guard against forwarded personal mailbox copies).
        let deliveredToValues = headerValues("delivered-to", in: input.headers)
        let deliveredEmails = extractEmailAddresses(from: deliveredToValues)
        if !deliveredEmails.isEmpty && !deliveredEmails.contains(where: isMoxaDomain) {
            return .skip(.nonMoxaAccount("delivered-to non-moxa"))
        }

        let tenantIDs = headerValues("x-ms-exchange-crosstenant-id", in: input.headers)
        let hasMoxaTenant = tenantIDs.contains { $0.lowercased().contains(moxaTenantID) }

        let recipientPool = input.allRecipientAddresses
            + input.toAddresses
            + input.ccAddresses
            + input.bccAddresses
            + deliveredToValues
            + headerValues("to", in: input.headers)
            + headerValues("cc", in: input.headers)
        let recipientEmails = extractEmailAddresses(from: recipientPool)
        let hasMoxaRecipient = recipientEmails.contains(where: isMoxaDomain)

        guard hasMoxaTenant || hasMoxaRecipient else {
            return .skip(.nonMoxaAccount("not moxa"))
        }

        // 2. Self-sent exclusion.
        let senderCandidates = extractEmailAddresses(
            from: [input.fromAddress] + headerValues("from", in: input.headers)
        )
        if senderCandidates.contains(userMoxaAddress) {
            return .skip(.selfSent)
        }

        // 3. Primary classification filters (spam / bulk / newsletter / automated / calendar).
        for sclRaw in headerValues("x-ms-exchange-organization-scl", in: input.headers) {
            if let scl = Int(sclRaw.trimmingCharacters(in: .whitespacesAndNewlines)), scl >= 5 {
                return .skip(.spamOrBulk("scl"))
            }
        }

        if hasNonEmptyHeader("list-unsubscribe", in: input.headers) {
            return .skip(.newsletterOrPromotion("list-unsubscribe"))
        }
        if hasNonEmptyHeader("list-id", in: input.headers) {
            return .skip(.newsletterOrPromotion("list-id"))
        }

        let precedenceValues = headerValues("precedence", in: input.headers)
        for val in precedenceValues {
            let tokens = val.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).inverted)
                .filter { !$0.isEmpty }
            if tokens.contains(where: { ["bulk", "list", "junk", "auto_reply"].contains($0) }) {
                return .skip(.spamOrBulk("precedence"))
            }
        }

        for autoSubRaw in headerValues("auto-submitted", in: input.headers) {
            let primaryValue = autoSubRaw
                .split(separator: ";", maxSplits: 1)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            if !primaryValue.isEmpty && primaryValue != "no" {
                return .skip(.automatedSystem("auto-submitted"))
            }
        }

        for sender in senderCandidates {
            if isBotSender(sender) {
                return .skip(.automatedSystem("bot sender"))
            }
        }

        let autoSuppressValues = headerValues("x-auto-response-suppress", in: input.headers)
        if !autoSuppressValues.isEmpty {
            let combinedTokens = autoSuppressValues
                .flatMap {
                    $0.lowercased()
                        .components(separatedBy: CharacterSet.alphanumerics.inverted)
                }
                .filter { !$0.isEmpty }
            if combinedTokens.contains("all") {
                return .skip(.automatedSystem("suppress-all"))
            }
            if combinedTokens.contains("oof") || combinedTokens.contains("autoreply") {
                let directRecipientEmails = extractEmailAddresses(
                    from: input.toAddresses
                        + input.ccAddresses
                        + headerValues("to", in: input.headers)
                        + headerValues("cc", in: input.headers)
                )
                if !directRecipientEmails.contains(userMoxaAddress) {
                    return .skip(.automatedSystem("mass-broadcast"))
                }
            }
        }

        let subjectText = (input.subject.isEmpty ? (headerValues("subject", in: input.headers).first ?? "") : input.subject)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if calendarPrefixes.contains(where: { subjectText.hasPrefix($0) }) {
            return .skip(.calendarNotification)
        }

        return .allowMoxaPrimary
    }

    // MARK: - Helpers

    private static func headerValues(_ key: String, in headers: [String: [String]]) -> [String] {
        headers[key.lowercased()] ?? []
    }

    private static func hasNonEmptyHeader(_ key: String, in headers: [String: [String]]) -> Bool {
        headerValues(key, in: headers).contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func isMoxaDomain(_ email: String) -> Bool {
        let lower = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasSuffix("@moxa.com") || lower.hasSuffix(".moxa.com")
    }

    private static func isBotSender(_ email: String) -> Bool {
        let lower = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if botAddresses.contains(lower) || lower.hasSuffix("@teams.mail.microsoft") {
            return true
        }
        guard let atIdx = lower.firstIndex(of: "@") else { return false }
        let localPart = String(lower[..<atIdx])
        if botLocalSubstrings.contains(where: { localPart.contains($0) }) {
            return true
        }
        return botExactLocals.contains(localPart)
    }

    private static let emailRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"[A-Z0-9a-z._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#,
        options: []
    )

    static func extractEmailAddresses(from rawStrings: [String]) -> [String] {
        guard let regex = emailRegex else { return [] }
        var seen: Set<String> = []
        var result: [String] = []
        for raw in rawStrings where !raw.isEmpty {
            let ns = raw as NSString
            let range = NSRange(location: 0, length: ns.length)
            for match in regex.matches(in: raw, options: [], range: range) {
                let email = ns.substring(with: match.range).lowercased()
                if seen.insert(email).inserted {
                    result.append(email)
                }
            }
        }
        return result
    }
}
