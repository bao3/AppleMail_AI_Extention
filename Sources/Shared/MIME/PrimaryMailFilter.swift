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

public struct PrimaryMailFilterScope: Codable, Equatable, Sendable {
    public var allowedDomains: [String]
    public var allowedTenantIDs: [String]
    public var selfAddresses: [String]
    public var customBotAddresses: [String]

    public init(
        allowedDomains: [String] = [],
        allowedTenantIDs: [String] = [],
        selfAddresses: [String] = [],
        customBotAddresses: [String] = []
    ) {
        self.allowedDomains = Self.normalizeItems(allowedDomains, stripLeadingAt: true)
        self.allowedTenantIDs = Self.normalizeItems(allowedTenantIDs, stripLeadingAt: false)
        self.selfAddresses = Self.normalizeItems(selfAddresses, stripLeadingAt: false)
        self.customBotAddresses = Self.normalizeItems(customBotAddresses, stripLeadingAt: false)
    }

    public var hasAccountRestriction: Bool {
        !allowedDomains.isEmpty || !allowedTenantIDs.isEmpty
    }

    public func matchesAllowedDomain(_ email: String) -> Bool {
        let lower = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let atIdx = lower.lastIndex(of: "@") else { return false }
        let domain = String(lower[lower.index(after: atIdx)...])
        guard !domain.isEmpty else { return false }
        return allowedDomains.contains { allowed in
            domain == allowed || domain.hasSuffix(".\(allowed)")
        }
    }

    public static func parseCommaSeparated(_ raw: String, stripLeadingAt: Bool = false) -> [String] {
        let parts = raw.components(separatedBy: CharacterSet(charactersIn: ",，;\n"))
        return normalizeItems(parts, stripLeadingAt: stripLeadingAt)
    }

    private static func normalizeItems(_ rawItems: [String], stripLeadingAt: Bool) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in rawItems {
            var cleaned = item.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if stripLeadingAt, cleaned.hasPrefix("@") {
                cleaned = String(cleaned.dropFirst())
            }
            guard !cleaned.isEmpty, seen.insert(cleaned).inserted else { continue }
            result.append(cleaned)
        }
        return result
    }
}

public enum FilterSkipReason: Equatable, Sendable {
    case notReceivedState
    case encrypted
    case tooOld
    case outOfScopeAccount(String)
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
        case let .outOfScopeAccount(detail):
            return "outOfScopeAccount(\(detail))"
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
    case allowPrimary
    case skip(FilterSkipReason)
}

/// Deterministic filter restricting background AI pre-analysis to recent, non-bulk Primary messages,
/// with optional domain/tenant/self-address scoping configured by the user.
public enum PrimaryMailFilter {
    public static let scopeDefaultsKey = "com.bao3.MailKBAI.primaryFilterScope.v1"
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
        "bounces",
        "portal.admin",
        "oa.admin"
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

    public static func loadScope(
        from defaults: UserDefaults = SharedAppGroup.sharedUserDefaults
    ) -> PrimaryMailFilterScope {
        guard let data = defaults.data(forKey: scopeDefaultsKey),
              let decoded = try? JSONDecoder().decode(PrimaryMailFilterScope.self, from: data)
        else {
            return PrimaryMailFilterScope()
        }
        return PrimaryMailFilterScope(
            allowedDomains: decoded.allowedDomains,
            allowedTenantIDs: decoded.allowedTenantIDs,
            selfAddresses: decoded.selfAddresses,
            customBotAddresses: decoded.customBotAddresses
        )
    }

    public static func saveScope(
        _ scope: PrimaryMailFilterScope,
        to defaults: UserDefaults = SharedAppGroup.sharedUserDefaults
    ) {
        let normalized = PrimaryMailFilterScope(
            allowedDomains: scope.allowedDomains,
            allowedTenantIDs: scope.allowedTenantIDs,
            selfAddresses: scope.selfAddresses,
            customBotAddresses: scope.customBotAddresses
        )
        if let encoded = try? JSONEncoder().encode(normalized) {
            defaults.set(encoded, forKey: scopeDefaultsKey)
            if defaults === SharedAppGroup.sharedUserDefaults {
                SharedAppGroup.postDistributedConfigDidChange()
            }
        }
    }

    public static func evaluate(
        _ input: MessageFilterInput,
        scope: PrimaryMailFilterScope? = nil,
        now: Date = Date()
    ) -> FilterDecision {
        let resolvedScope = scope ?? loadScope()

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

        // 1. Optional account/domain/tenant scope check when configured by user.
        let deliveredToValues = headerValues("delivered-to", in: input.headers)
        if resolvedScope.hasAccountRestriction {
            let deliveredEmails = extractEmailAddresses(from: deliveredToValues)
            if !deliveredEmails.isEmpty,
               !resolvedScope.allowedDomains.isEmpty,
               !deliveredEmails.contains(where: { resolvedScope.matchesAllowedDomain($0) })
            {
                return .skip(.outOfScopeAccount("delivered-to outside allowed domains"))
            }

            let tenantIDs = headerValues("x-ms-exchange-crosstenant-id", in: input.headers)
            let hasAllowedTenant = !resolvedScope.allowedTenantIDs.isEmpty && tenantIDs.contains { raw in
                let lower = raw.lowercased()
                return resolvedScope.allowedTenantIDs.contains { lower.contains($0) }
            }

            let recipientPool = input.allRecipientAddresses
                + input.toAddresses
                + input.ccAddresses
                + input.bccAddresses
                + deliveredToValues
                + headerValues("to", in: input.headers)
                + headerValues("cc", in: input.headers)
            let recipientEmails = extractEmailAddresses(from: recipientPool)
            let hasAllowedRecipient = !resolvedScope.allowedDomains.isEmpty
                && recipientEmails.contains(where: { resolvedScope.matchesAllowedDomain($0) })

            guard hasAllowedTenant || hasAllowedRecipient else {
                return .skip(.outOfScopeAccount("outside configured scope"))
            }
        }

        // 2. Self-sent exclusion (when user configures selfAddresses).
        let senderCandidates = extractEmailAddresses(
            from: [input.fromAddress] + headerValues("from", in: input.headers)
        )
        if !resolvedScope.selfAddresses.isEmpty {
            let selfSet = Set(resolvedScope.selfAddresses)
            if senderCandidates.contains(where: { selfSet.contains($0) }) {
                return .skip(.selfSent)
            }
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

        let customBots = Set(resolvedScope.customBotAddresses)
        for sender in senderCandidates {
            if isBotSender(sender, customBots: customBots) {
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
            if (combinedTokens.contains("oof") || combinedTokens.contains("autoreply")),
               !resolvedScope.selfAddresses.isEmpty
            {
                let selfSet = Set(resolvedScope.selfAddresses)
                let directRecipientEmails = extractEmailAddresses(
                    from: input.toAddresses
                        + input.ccAddresses
                        + headerValues("to", in: input.headers)
                        + headerValues("cc", in: input.headers)
                )
                if !directRecipientEmails.contains(where: { selfSet.contains($0) }) {
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

        return .allowPrimary
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

    private static func isBotSender(_ email: String, customBots: Set<String>) -> Bool {
        let lower = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if customBots.contains(lower) || lower.hasSuffix("@teams.mail.microsoft") {
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
