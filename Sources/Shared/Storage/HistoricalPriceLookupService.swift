import Darwin
import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A single historical SKU price row retrieved read-only from the staged `mailkb.sqlite` (or legacy `outlook.sqlite`) cache.
public struct HistoricalPriceRecord: Identifiable, Sendable, Hashable {
    public let id: String
    public let sku: String
    public let currency: String
    public let unitPrice: Double
    public let quantity: Double?
    public let priceType: String
    public let priceTypeLabel: String
    public let taxMode: String
    public let customerOrg: String
    public let projectName: String
    public let quoteDateISO: String
    public let subject: String
    public let rfcMessageID: String
    public let evidenceSnippet: String
    public let confidence: String
    public let isExactSKUMatch: Bool
    public let occurrenceCount: Int
    public let mailJumpURL: URL?
    public let sourceMessageRowID: Int64?
    public let mergedMessageRowIDs: [Int64]

    public init(
        id: String? = nil,
        sku: String,
        currency: String,
        unitPrice: Double,
        quantity: Double? = nil,
        priceType: String = "",
        priceTypeLabel: String? = nil,
        taxMode: String = "",
        customerOrg: String = "",
        projectName: String = "",
        quoteDateISO: String = "",
        subject: String = "",
        rfcMessageID: String = "",
        evidenceSnippet: String = "",
        confidence: String = "medium",
        isExactSKUMatch: Bool = true,
        occurrenceCount: Int = 1,
        mailJumpURL: URL? = nil,
        sourceMessageRowID: Int64? = nil,
        mergedMessageRowIDs: [Int64] = []
    ) {
        self.sku = sku
        self.currency = currency
        self.unitPrice = unitPrice
        self.quantity = quantity
        self.priceType = priceType
        self.priceTypeLabel = priceTypeLabel ?? HistoricalPriceLookupService.priceTypeDisplayLabel(for: priceType)
        self.taxMode = taxMode
        self.customerOrg = customerOrg
        self.projectName = projectName
        self.quoteDateISO = quoteDateISO
        self.subject = subject
        self.rfcMessageID = rfcMessageID
        self.evidenceSnippet = evidenceSnippet
        self.confidence = confidence
        self.isExactSKUMatch = isExactSKUMatch
        self.occurrenceCount = max(1, occurrenceCount)
        self.mailJumpURL = mailJumpURL
        self.sourceMessageRowID = sourceMessageRowID ?? mergedMessageRowIDs.first
        if !mergedMessageRowIDs.isEmpty {
            self.mergedMessageRowIDs = mergedMessageRowIDs
        } else if let sourceMessageRowID {
            self.mergedMessageRowIDs = [sourceMessageRowID]
        } else {
            self.mergedMessageRowIDs = []
        }
        self.id = id ?? [
            sku.uppercased(),
            currency.uppercased(),
            String(format: "%.6f", unitPrice),
            quoteDateISO,
            customerOrg,
            projectName,
            priceType,
            rfcMessageID,
            isExactSKUMatch ? "exact" : "series"
        ].joined(separator: "|")
    }
}

/// Price evidence extracted from a historical email body, HTML table, or attachment spreadsheet.
public struct HistoricalEmailPriceEvidence: Identifiable, Sendable, Hashable {
    public let id: String
    public let sku: String
    public let currency: String
    public let unitPrice: Double
    public let quantity: Double?
    public let totalAmount: Double?
    public let priceType: String
    public let priceTypeLabel: String
    public let taxMode: String
    public let customerOrg: String
    public let projectName: String
    public let sourceKind: String
    public let sourceKindLabel: String
    public let evidenceSnippet: String

    public init(
        id: String,
        sku: String,
        currency: String,
        unitPrice: Double,
        quantity: Double? = nil,
        totalAmount: Double? = nil,
        priceType: String = "",
        priceTypeLabel: String? = nil,
        taxMode: String = "",
        customerOrg: String = "",
        projectName: String = "",
        sourceKind: String = "",
        sourceKindLabel: String? = nil,
        evidenceSnippet: String = ""
    ) {
        self.id = id
        self.sku = sku
        self.currency = currency
        self.unitPrice = unitPrice
        self.quantity = quantity
        self.totalAmount = totalAmount
        self.priceType = priceType
        self.priceTypeLabel = priceTypeLabel ?? HistoricalPriceLookupService.priceTypeDisplayLabel(for: priceType)
        self.taxMode = taxMode
        self.customerOrg = customerOrg
        self.projectName = projectName
        self.sourceKind = sourceKind
        self.sourceKindLabel = sourceKindLabel ?? HistoricalPriceLookupService.sourceKindDisplayLabel(for: sourceKind)
        self.evidenceSnippet = evidenceSnippet
    }
}

/// Non-inline attachment metadata recorded for a historical message in `mailkb.sqlite`.
public struct HistoricalEmailAttachmentInfo: Identifiable, Sendable, Hashable {
    public let id: String
    public let filename: String
    public let sizeBytes: Int64
    public let textPreview: String

    public init(id: String, filename: String, sizeBytes: Int64 = 0, textPreview: String = "") {
        self.id = id
        self.filename = filename
        self.sizeBytes = max(0, sizeBytes)
        self.textPreview = textPreview
    }
}

/// Full read-only source email record & extracted price evidence loaded from `mailkb.sqlite`.
public struct HistoricalEmailDetail: Identifiable, Sendable, Hashable {
    public let id: Int64
    public let source: String
    public let sourceLabel: String
    public let rfcMessageID: String
    public let subject: String
    public let sender: String
    public let recipients: String
    public let cc: String
    public let dateISO: String
    public let folderPath: String
    public let projectName: String
    public let customersOrgs: String
    public let mainMeaning: String
    public let bodyLatest: String
    public let bodyQuoted: String
    public let priceEvidences: [HistoricalEmailPriceEvidence]
    public let attachments: [HistoricalEmailAttachmentInfo]
    public let mailJumpURL: URL?

    public init(
        id: Int64,
        source: String,
        sourceLabel: String? = nil,
        rfcMessageID: String = "",
        subject: String = "",
        sender: String = "",
        recipients: String = "",
        cc: String = "",
        dateISO: String = "",
        folderPath: String = "",
        projectName: String = "",
        customersOrgs: String = "",
        mainMeaning: String = "",
        bodyLatest: String = "",
        bodyQuoted: String = "",
        priceEvidences: [HistoricalEmailPriceEvidence] = [],
        attachments: [HistoricalEmailAttachmentInfo] = [],
        mailJumpURL: URL? = nil
    ) {
        self.id = id
        self.source = source
        self.sourceLabel = sourceLabel ?? HistoricalPriceLookupService.mailSourceDisplayLabel(for: source)
        self.rfcMessageID = rfcMessageID
        self.subject = subject
        self.sender = sender
        self.recipients = recipients
        self.cc = cc
        self.dateISO = dateISO
        self.folderPath = folderPath
        self.projectName = projectName
        self.customersOrgs = customersOrgs
        self.mainMeaning = mainMeaning
        self.bodyLatest = bodyLatest
        self.bodyQuoted = bodyQuoted
        self.priceEvidences = priceEvidences
        self.attachments = attachments
        self.mailJumpURL = mailJumpURL
    }
}

/// Historical price comparison group for a candidate model/SKU found in an email.
public struct SKUPriceComparisonGroup: Identifiable, Sendable, Hashable {
    public let id: String
    public let queriedSKU: String
    public let currentEmailPriceHint: String?
    public let minUnitPrice: Double?
    public let maxUnitPrice: Double?
    public let primaryCurrency: String
    public let records: [HistoricalPriceRecord]

    public init(
        id: String? = nil,
        queriedSKU: String,
        currentEmailPriceHint: String? = nil,
        minUnitPrice: Double? = nil,
        maxUnitPrice: Double? = nil,
        primaryCurrency: String,
        records: [HistoricalPriceRecord]
    ) {
        self.id = id ?? queriedSKU
        self.queriedSKU = queriedSKU
        self.currentEmailPriceHint = currentEmailPriceHint
        self.minUnitPrice = minUnitPrice
        self.maxUnitPrice = maxUnitPrice
        self.primaryCurrency = primaryCurrency
        self.records = records
    }
}

/// Strictly read-only lookup service querying historical SKU prices from the staged `mailkb_db.sqlite`
/// (with `mailkb.sqlite` and legacy `outlook.sqlite` fallback) runtime cache.
/// Never opens `.mailkb_db/*.sqlite`, `.mailkb/*.sqlite`, or `.moxa-kb/*.sqlite` directly; opens
/// `~/.cache/mailkb_db/mailkb_db.sqlite` (or `~/.cache/mailkb/mailkb.sqlite` / `~/.cache/moxa-kb-runtime/outlook.sqlite` / staged cold copy)
/// via SQLite URI `?mode=ro&immutable=1`.
public final class HistoricalPriceLookupService: Sendable {
    public static let shared = HistoricalPriceLookupService()

    private static let maxCandidateSKUs = 8
    private static let maxExactMatchesPerSKU = 8
    private static let maxSeriesSupplementPerSKU = 5
    private static let exactThresholdForSeriesFallback = 3
    private static let sqlScanLimit = 400
    private static let sqliteMagicHeader = Array("SQLite format 3\0".utf8)

    private static let chinesePricingKeywords: [String] = [
        "报价", "价格", "特价", "单价", "含税", "未税", "折扣",
        "核价", "询价", "目标价", "阶梯价", "集采", "比价"
    ]

    // Word-bounded on ASCII letters so technical prose like "specification" or "spring"
    // never false-positives on "cif" or "spr".
    private static let englishPricingRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?<![a-z])(quote|quotes|quotation|pricing|price|prices|spr|discount|discounts|fob|cif|moq)(?![a-z])"#,
        options: [.caseInsensitive]
    )

    private static let excludedSKUPrefixes: Set<String> = [
        "EN", "IEC", "IEEE", "ISO", "RFC", "ANSI", "ASTM", "DIN",
        "UTF", "SHA", "TLS", "SSL", "HTTP", "HTTPS", "MIME", "COVID",
        "ISBN", "ISSN", "JIRA", "CASE", "TKT", "PO", "SO", "PI", "RFQ", "PR", "SPR"
    ]

    // Matches standard hyphenated SKUs (TN-4908-4GTX-WV-CT-T, EDS-4012-8GT4XS-HV-T, TAP-M310R, DA-682B-FEP, SFP-1GLXLC-T),
    // V-series embedded SKUs (V1222-CT-T, V2406C-KL5-T), A-series accessories (A-ADP-QMAM-RF, A-PLG-WPM23-01-IP67),
    // and space-delimited Moxa product families (NPort 5610-8-DT-J, ioLogik R1241, MGate MB3180).
    private static let skuRegexes: [NSRegularExpression] = {
        let patterns = [
            #"(?<![A-Za-z0-9_@-])[A-Za-z][A-Za-z0-9]{1,6}-(?:[A-Za-z]?\d{3,5}[A-Za-z0-9]*|[A-Za-z]{1,2}\d{2,5}[A-Za-z0-9]*|\d{1,2}[A-Za-z]{1,6}[A-Za-z0-9]*)(?:-[A-Za-z0-9]{1,12})*(?![A-Za-z0-9_@-])"#,
            #"(?<![A-Za-z0-9_@-])V\d{3,4}[A-Za-z]?(?:-[A-Za-z0-9]{1,12})*(?![A-Za-z0-9_@-])"#,
            #"(?<![A-Za-z0-9_@-])A-(?:ADP|CAP|CRF|PLG)-[A-Za-z0-9]{1,12}(?:-[A-Za-z0-9]{1,12})*(?![A-Za-z0-9_@-])"#,
            #"(?<![A-Za-z0-9_@-])(?:NPort|MGate|ioLogik|ioThinx|ioPAC|OnCell|UPort|MXview)\s+[A-Za-z]?\d{3,4}[A-Za-z0-9]*(?:-[A-Za-z0-9]{1,12})*(?![A-Za-z0-9_@-])"#
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }()

    // Strips leading external tags and stacked Re:/Fw:/Fwd:/回复:/答复:/转发: prefixes (ASCII & CJK colons).
    private static let subjectPrefixRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^(?:\s*(?:(?:\[external\]|【外部邮件】|\[外部邮件\])\s*|(?:re|fw|fwd|回复|回覆|答复|答復|转发|轉發)(?:\[\d+\])?\s*[:：]\s*))+"#,
        options: [.caseInsensitive]
    )

    private static let substantialPriceContextRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?:\b\d{1,3}(?:,\d{3})+|\b\d{3,6})(?:\.\d{1,2})?\s*(?:/\s*(?:pc|pcs|台|套))?\s*(?:\(?\s*)?(?:CNY|RMB|未税|未稅|含税|含稅|元)"#,
        options: [.caseInsensitive]
    )

    private let stagingDirectoryURL: URL?

    public init(stagingDirectoryURL: URL? = nil) {
        self.stagingDirectoryURL = stagingDirectoryURL
    }

    // MARK: - Public Helpers

    public static func priceTypeDisplayLabel(for rawPriceType: String) -> String {
        switch rawPriceType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "order_price":
            return "订单价"
        case "quote":
            return "报价"
        case "spr_request":
            return "特价申请"
        case "spr_support":
            return "特价支持"
        case "cost":
            return "成本价"
        case "historical_price":
            return "历史参考价"
        case "competitor_quote":
            return "竞品报价"
        case "project_bid_total":
            return "项目投标价"
        case "list_price":
            return "目录价"
        case "":
            return "报价记录"
        default:
            return rawPriceType
        }
    }

    public static func sourceKindDisplayLabel(for rawSourceKind: String) -> String {
        switch rawSourceKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "mime_attachment":
            return "附件表格"
        case "html_table":
            return "邮件表格"
        case "body_latest", "body":
            return "邮件正文"
        case "body_quoted":
            return "引用对话"
        case "":
            return "邮件提取"
        default:
            return rawSourceKind
        }
    }

    public static func mailSourceDisplayLabel(for rawSource: String) -> String {
        let trimmed = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "apple_mail":
            return "Apple Mail"
        case "outlook":
            return "Outlook"
        case "thunderbird":
            return "Thunderbird"
        case "":
            return "邮件库"
        default:
            return trimmed
        }
    }

    public static func formatUnitPrice(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    public static func containsPricingIntent(email: ParsedEmailContext, analysis: EmailAIAnalysis? = nil) -> Bool {
        if let analysis {
            if analysis.resolvedFlag == .yellow || analysis.resolvedFlag == .orange {
                return true
            }
            if !analysis.businessElements.pricing.isEmpty {
                return true
            }
        }

        var corpusParts: [String] = [email.subject, email.plainBody]
        for quote in email.quotedChain {
            corpusParts.append(quote.content)
        }
        for attachment in email.attachments where !attachment.isInline {
            corpusParts.append(attachment.filename)
        }

        let corpus = corpusParts.joined(separator: "\n")
        guard !corpus.isEmpty else { return false }

        if chinesePricingKeywords.contains(where: { corpus.contains($0) }) {
            return true
        }

        if let regex = englishPricingRegex {
            let ns = corpus as NSString
            let range = NSRange(location: 0, length: ns.length)
            if regex.firstMatch(in: corpus, options: [], range: range) != nil {
                return true
            }
        }

        return false
    }

    public static func extractCandidateSKUs(from email: ParsedEmailContext, analysis: EmailAIAnalysis? = nil) -> [String] {
        var candidates: [String] = []
        var seenUppercased: Set<String> = []

        func appendCandidate(_ raw: String) {
            let normalized = normalizeCandidateSKU(raw)
            guard !normalized.isEmpty else { return }
            let key = normalized.uppercased()
            guard !isExcludedCandidate(key) else { return }
            if seenUppercased.insert(key).inserted {
                candidates.append(normalized)
            }
        }

        func extractFromText(_ text: String, acceptWholeFallback: Bool = false) {
            guard !text.isEmpty, candidates.count < maxCandidateSKUs else { return }
            let ns = text as NSString
            let fullRange = NSRange(location: 0, length: ns.length)
            var matchedAny = false

            var allMatches: [(range: NSRange, value: String)] = []
            for regex in skuRegexes {
                for match in regex.matches(in: text, options: [], range: fullRange) {
                    let matchedText = ns.substring(with: match.range)
                    allMatches.append((match.range, matchedText))
                }
            }

            // Preserve left-to-right appearance order inside each text block.
            allMatches.sort { lhs, rhs in
                if lhs.range.location != rhs.range.location {
                    return lhs.range.location < rhs.range.location
                }
                return lhs.range.length > rhs.range.length
            }

            var acceptedEnd = 0
            for item in allMatches {
                guard candidates.count < maxCandidateSKUs else { break }
                guard item.range.location >= acceptedEnd else { continue }
                guard !isPartOfDomainOrEmail(ns: ns, matchRange: item.range) else { continue }
                matchedAny = true
                acceptedEnd = item.range.location + item.range.length
                appendCandidate(item.value)
            }

            if acceptWholeFallback, !matchedAny, candidates.count < maxCandidateSKUs {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if isPlausibleDirectModelToken(trimmed) {
                    appendCandidate(trimmed)
                }
            }
        }

        if let analysis {
            for model in analysis.businessElements.models {
                extractFromText(model, acceptWholeFallback: true)
                if candidates.count >= maxCandidateSKUs { return candidates }
            }
            for pricing in analysis.businessElements.pricing {
                extractFromText(pricing.itemOrModel, acceptWholeFallback: true)
                if candidates.count >= maxCandidateSKUs { return candidates }
            }
        }

        extractFromText(email.subject)
        if candidates.count >= maxCandidateSKUs { return candidates }

        extractFromText(email.plainBody)
        if candidates.count >= maxCandidateSKUs { return candidates }

        for block in email.quotedChain {
            extractFromText(block.content)
            if candidates.count >= maxCandidateSKUs { return candidates }
        }

        return Array(candidates.prefix(maxCandidateSKUs))
    }

    // MARK: - Lookup Execution

    public func lookupRelatedPrices(
        for email: ParsedEmailContext,
        analysis: EmailAIAnalysis? = nil,
        runtimeDBPath: String? = nil,
        coldDBURL: URL? = nil,
        forceLookup: Bool = false
    ) async -> [SKUPriceComparisonGroup] {
        guard forceLookup || Self.containsPricingIntent(email: email, analysis: analysis) else {
            return []
        }

        let candidateSKUs = Self.extractCandidateSKUs(from: email, analysis: analysis)
        guard !candidateSKUs.isEmpty else {
            return []
        }

        let stagingDir = self.stagingDirectoryURL
        let rawGroups: [SKUPriceComparisonGroup] = await Task.detached(priority: .userInitiated) {
            guard let resolvedPath = Self.resolveReadableRuntimeDBPath(
                explicitRuntimeDBPath: runtimeDBPath,
                coldDBURL: coldDBURL,
                stagingDirectoryURL: stagingDir
            ),
            let db = Self.openReadOnlyDatabase(atPath: resolvedPath)
            else {
                return []
            }
            defer { sqlite3_close(db) }

            let normalizedSelfID = ParsedEmailContext.normalizeMessageID(email.messageID).lowercased()
            return Self.buildComparisonGroups(
                for: candidateSKUs,
                analysis: analysis,
                normalizedSelfMessageID: normalizedSelfID,
                db: db
            )
        }.value

        guard !rawGroups.isEmpty else {
            return []
        }

        // ReminderService.mailMessageURL(forMessageID:) is @MainActor-isolated in Swift 6;
        // perform a single lightweight MainActor hop to resolve jump URLs without duplicating URL logic.
        return await MainActor.run {
            rawGroups.map { group in
                let enrichedRecords = group.records.map { record in
                    HistoricalPriceRecord(
                        id: record.id,
                        sku: record.sku,
                        currency: record.currency,
                        unitPrice: record.unitPrice,
                        quantity: record.quantity,
                        priceType: record.priceType,
                        priceTypeLabel: record.priceTypeLabel,
                        taxMode: record.taxMode,
                        customerOrg: record.customerOrg,
                        projectName: record.projectName,
                        quoteDateISO: record.quoteDateISO,
                        subject: record.subject,
                        rfcMessageID: record.rfcMessageID,
                        evidenceSnippet: record.evidenceSnippet,
                        confidence: record.confidence,
                        isExactSKUMatch: record.isExactSKUMatch,
                        occurrenceCount: record.occurrenceCount,
                        mailJumpURL: ReminderService.mailMessageURL(forMessageID: record.rfcMessageID),
                        sourceMessageRowID: record.sourceMessageRowID,
                        mergedMessageRowIDs: record.mergedMessageRowIDs
                    )
                }
                return SKUPriceComparisonGroup(
                    id: group.id,
                    queriedSKU: group.queriedSKU,
                    currentEmailPriceHint: group.currentEmailPriceHint,
                    minUnitPrice: group.minUnitPrice,
                    maxUnitPrice: group.maxUnitPrice,
                    primaryCurrency: group.primaryCurrency,
                    records: enrichedRecords
                )
            }
        }
    }

    /// Loads full read-only source emails, extracted price evidence snippets, and attachment metadata
    /// from the staged `mailkb.sqlite` (or fallback `outlook.sqlite`) cache so users can inspect historical emails inside the AI panel
    /// without hitting Apple Mail's modal-window rendering lock.
    public func loadHistoricalEmailDetails(
        for record: HistoricalPriceRecord,
        runtimeDBPath: String? = nil,
        coldDBURL: URL? = nil,
        maxMessages: Int = 8
    ) async -> [HistoricalEmailDetail] {
        let stagingDir = self.stagingDirectoryURL
        let cappedMaxMessages = max(1, maxMessages)
        let rawDetails: [HistoricalEmailDetail] = await Task.detached(priority: .userInitiated) {
            guard let resolvedPath = Self.resolveReadableRuntimeDBPath(
                explicitRuntimeDBPath: runtimeDBPath,
                coldDBURL: coldDBURL,
                stagingDirectoryURL: stagingDir
            ),
            let db = Self.openReadOnlyDatabase(atPath: resolvedPath)
            else {
                return []
            }
            defer { sqlite3_close(db) }

            return Self.queryHistoricalEmailDetails(
                db: db,
                record: record,
                maxMessages: cappedMaxMessages
            )
        }.value

        guard !rawDetails.isEmpty else {
            return []
        }

        return await MainActor.run {
            rawDetails.map { detail in
                HistoricalEmailDetail(
                    id: detail.id,
                    source: detail.source,
                    sourceLabel: detail.sourceLabel,
                    rfcMessageID: detail.rfcMessageID,
                    subject: detail.subject,
                    sender: detail.sender,
                    recipients: detail.recipients,
                    cc: detail.cc,
                    dateISO: detail.dateISO,
                    folderPath: detail.folderPath,
                    projectName: detail.projectName,
                    customersOrgs: detail.customersOrgs,
                    mainMeaning: detail.mainMeaning,
                    bodyLatest: detail.bodyLatest,
                    bodyQuoted: detail.bodyQuoted,
                    priceEvidences: detail.priceEvidences,
                    attachments: detail.attachments,
                    mailJumpURL: ReminderService.mailMessageURL(forMessageID: detail.rfcMessageID)
                )
            }
        }
    }

    // MARK: - SQLite Read-Only & Safe Cold Staging

    private static func resolveReadableRuntimeDBPath(
        explicitRuntimeDBPath: String?,
        coldDBURL: URL?,
        stagingDirectoryURL: URL?
    ) -> String? {
        resolveReadableRuntimeDBPath(
            explicitRuntimeDBPath: explicitRuntimeDBPath,
            coldDBURL: coldDBURL,
            stagingDirectoryURL: stagingDirectoryURL,
            environment: ProcessInfo.processInfo.environment,
            containerHomeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            realHomeDirectory: realUserHomeDirectoryPath()
        )
    }

    static func resolveReadableRuntimeDBPath(
        explicitRuntimeDBPath: String?,
        coldDBURL: URL?,
        stagingDirectoryURL: URL?,
        environment: [String: String],
        containerHomeDirectory: URL,
        realHomeDirectory: String?
    ) -> String? {
        if let explicit = explicitRuntimeDBPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty
        {
            let expanded = (explicit as NSString).expandingTildeInPath
            let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
            if !isForbiddenDirectKBPath(standardized),
               FileManager.default.isReadableFile(atPath: standardized),
               hasValidSQLiteHeader(atPath: standardized)
            {
                return standardized
            }
            if let coldDBURL, let staged = stageColdDatabase(from: coldDBURL, stagingDirectoryURL: stagingDirectoryURL) {
                return staged
            }
            return nil
        }

        let candidates = candidateRuntimeDBPaths(
            environment: environment,
            containerHomeDirectory: containerHomeDirectory,
            realHomeDirectory: realHomeDirectory
        )
        for candidate in candidates {
            if !isForbiddenDirectKBPath(candidate),
               FileManager.default.isReadableFile(atPath: candidate),
               hasValidSQLiteHeader(atPath: candidate)
            {
                return candidate
            }
        }

        if let coldDBURL, let staged = stageColdDatabase(from: coldDBURL, stagingDirectoryURL: stagingDirectoryURL) {
            return staged
        }

        for fallbackStaged in fallbackStagedRuntimeDBPaths(stagingDirectoryURL: stagingDirectoryURL) {
            if !isForbiddenDirectKBPath(fallbackStaged),
               FileManager.default.isReadableFile(atPath: fallbackStaged),
               hasValidSQLiteHeader(atPath: fallbackStaged)
            {
                return fallbackStaged
            }
        }

        return nil
    }

    private static func realUserHomeDirectoryPath() -> String? {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else {
            return nil
        }
        return String(cString: dir)
    }

    static func candidateRuntimeDBPaths(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        containerHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        realHomeDirectory: String? = realUserHomeDirectoryPath()
    ) -> [String] {
        var candidates: [String] = []
        var seen = Set<String>()

        func appendCandidate(_ path: String) {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            if seen.insert(standardized).inserted {
                candidates.append(standardized)
            }
        }

        if let envDir = environment["MAILKB_DB_RUNTIME_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envDir.isEmpty
        {
            let expanded = (envDir as NSString).expandingTildeInPath
            let base = URL(fileURLWithPath: expanded, isDirectory: true)
            appendCandidate(base.appendingPathComponent("mailkb_db.sqlite", isDirectory: false).path)
            appendCandidate(base.appendingPathComponent("mailkb.sqlite", isDirectory: false).path)
            appendCandidate(base.appendingPathComponent("outlook.sqlite", isDirectory: false).path)
        }

        if let envDir = environment["MAILKB_RUNTIME_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envDir.isEmpty
        {
            let expanded = (envDir as NSString).expandingTildeInPath
            let base = URL(fileURLWithPath: expanded, isDirectory: true)
            appendCandidate(base.appendingPathComponent("mailkb_db.sqlite", isDirectory: false).path)
            appendCandidate(base.appendingPathComponent("mailkb.sqlite", isDirectory: false).path)
            appendCandidate(base.appendingPathComponent("outlook.sqlite", isDirectory: false).path)
        }

        appendCandidate(
            containerHomeDirectory
                .appendingPathComponent(".cache", isDirectory: true)
                .appendingPathComponent("mailkb_db", isDirectory: true)
                .appendingPathComponent("mailkb_db.sqlite", isDirectory: false)
                .path
        )

        // Inside macOS App Sandbox, homeDirectoryForCurrentUser points to the container Data folder,
        // whereas com.apple.security.temporary-exception.files.home-relative-path.read-only grants
        // read access to ~/.cache/mailkb_db/, ~/.cache/mailkb/, and ~/.cache/moxa-kb-runtime/ in the real user home directory.
        if let realHomeDirectory, !realHomeDirectory.isEmpty {
            appendCandidate(
                URL(fileURLWithPath: realHomeDirectory, isDirectory: true)
                    .appendingPathComponent(".cache", isDirectory: true)
                    .appendingPathComponent("mailkb_db", isDirectory: true)
                    .appendingPathComponent("mailkb_db.sqlite", isDirectory: false)
                    .path
            )
        }

        appendCandidate(
            containerHomeDirectory
                .appendingPathComponent(".cache", isDirectory: true)
                .appendingPathComponent("mailkb", isDirectory: true)
                .appendingPathComponent("mailkb.sqlite", isDirectory: false)
                .path
        )

        if let realHomeDirectory, !realHomeDirectory.isEmpty {
            appendCandidate(
                URL(fileURLWithPath: realHomeDirectory, isDirectory: true)
                    .appendingPathComponent(".cache", isDirectory: true)
                    .appendingPathComponent("mailkb", isDirectory: true)
                    .appendingPathComponent("mailkb.sqlite", isDirectory: false)
                    .path
            )
        }

        if let legacyEnvDir = environment["MOXA_KB_RUNTIME_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !legacyEnvDir.isEmpty
        {
            let expanded = (legacyEnvDir as NSString).expandingTildeInPath
            appendCandidate(
                URL(fileURLWithPath: expanded, isDirectory: true)
                    .appendingPathComponent("outlook.sqlite", isDirectory: false)
                    .path
            )
        }

        appendCandidate(
            containerHomeDirectory
                .appendingPathComponent(".cache", isDirectory: true)
                .appendingPathComponent("moxa-kb-runtime", isDirectory: true)
                .appendingPathComponent("outlook.sqlite", isDirectory: false)
                .path
        )

        if let realHomeDirectory, !realHomeDirectory.isEmpty {
            appendCandidate(
                URL(fileURLWithPath: realHomeDirectory, isDirectory: true)
                    .appendingPathComponent(".cache", isDirectory: true)
                    .appendingPathComponent("moxa-kb-runtime", isDirectory: true)
                    .appendingPathComponent("outlook.sqlite", isDirectory: false)
                    .path
            )
        }

        return candidates
    }

    private static func fallbackStagedRuntimeDBPaths(stagingDirectoryURL: URL?) -> [String] {
        var paths: [String] = []
        if let primaryDir = resolvedStagingDir(override: stagingDirectoryURL) {
            paths.append(primaryDir.appendingPathComponent("mailkb_db.sqlite", isDirectory: false).standardizedFileURL.path)
            paths.append(primaryDir.appendingPathComponent("mailkb.sqlite", isDirectory: false).standardizedFileURL.path)
            paths.append(primaryDir.appendingPathComponent("outlook.sqlite", isDirectory: false).standardizedFileURL.path)
        }
        if stagingDirectoryURL == nil,
           let cachesRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        {
            paths.append(
                cachesRoot
                    .appendingPathComponent("mailkb", isDirectory: true)
                    .appendingPathComponent("mailkb.sqlite", isDirectory: false)
                    .standardizedFileURL.path
            )
            paths.append(
                cachesRoot
                    .appendingPathComponent("moxa-kb-runtime", isDirectory: true)
                    .appendingPathComponent("outlook.sqlite", isDirectory: false)
                    .standardizedFileURL.path
            )
        }
        return paths
    }

    private static func resolvedStagingDir(override: URL?) -> URL? {
        if let override {
            return override
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("mailkb_db", isDirectory: true)
    }

    private static func stageColdDatabase(from coldDBURL: URL, stagingDirectoryURL: URL?) -> String? {
        guard coldDBURL.isFileURL else { return nil }
        guard let stagingDir = resolvedStagingDir(override: stagingDirectoryURL) else { return nil }
        let standardizedStaging = stagingDir.standardizedFileURL
        guard !isForbiddenDirectKBPath(standardizedStaging.path),
              !isInsideMailContainer(standardizedStaging.path)
        else {
            ExtensionLogger.cache.error("Refused staging directory inside forbidden path")
            return nil
        }

        let didAccess = coldDBURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                coldDBURL.stopAccessingSecurityScopedResource()
            }
        }

        let sourceFD = Darwin.open(coldDBURL.path, O_RDONLY | O_NOFOLLOW)
        guard sourceFD >= 0 else {
            ExtensionLogger.cache.warning("Failed safe O_RDONLY|O_NOFOLLOW open for coldDBURL: errno=\(errno)")
            return nil
        }
        defer { Darwin.close(sourceFD) }

        var statBuf = stat()
        guard Darwin.fstat(sourceFD, &statBuf) == 0,
              (statBuf.st_mode & S_IFMT) == S_IFREG,
              statBuf.st_size >= 100
        else {
            return nil
        }

        var headerBuffer = [UInt8](repeating: 0, count: sqliteMagicHeader.count)
        guard readExactBytes(fd: sourceFD, into: &headerBuffer, count: sqliteMagicHeader.count),
              headerBuffer == sqliteMagicHeader
        else {
            ExtensionLogger.cache.warning("Rejected coldDBURL: invalid SQLite format 3 header")
            return nil
        }

        do {
            try FileManager.default.createDirectory(
                at: standardizedStaging,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            ExtensionLogger.cache.error("Failed creating staging directory: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let destURL = standardizedStaging.appendingPathComponent("mailkb_db.sqlite", isDirectory: false)
        let stampURL = standardizedStaging.appendingPathComponent("mailkb_db.sqlite.stamp", isDirectory: false)
        let expectedStamp = "\(coldDBURL.path)|\(statBuf.st_size)|\(statBuf.st_mtimespec.tv_sec)|\(statBuf.st_mtimespec.tv_nsec)"

        if FileManager.default.isReadableFile(atPath: destURL.path),
           hasValidSQLiteHeader(atPath: destURL.path),
           (try? String(contentsOf: stampURL, encoding: .utf8)) == expectedStamp
        {
            return destURL.path
        }

        let tempURL = standardizedStaging.appendingPathComponent("mailkb_db.sqlite.tmp.\(UUID().uuidString)", isDirectory: false)
        let destFD = Darwin.open(tempURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard destFD >= 0 else {
            return nil
        }

        var copySucceeded = false
        defer {
            Darwin.close(destFD)
            if !copySucceeded {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        guard writeAllBytes(fd: destFD, buffer: headerBuffer, count: headerBuffer.count) else {
            return nil
        }

        let chunkSize = 1_048_576
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let bytesRead = chunk.withUnsafeMutableBytes { rawPtr -> Int in
                guard let base = rawPtr.baseAddress else { return -1 }
                while true {
                    let n = Darwin.read(sourceFD, base, chunkSize)
                    if n < 0, errno == EINTR { continue }
                    return n
                }
            }
            if bytesRead < 0 {
                return nil
            }
            if bytesRead == 0 {
                break
            }
            guard writeAllBytes(fd: destFD, buffer: chunk, count: bytesRead) else {
                return nil
            }
        }

        guard Darwin.rename(tempURL.path, destURL.path) == 0 else {
            return nil
        }
        copySucceeded = true
        try? expectedStamp.write(to: stampURL, atomically: true, encoding: .utf8)
        return destURL.path
    }

    private static func openReadOnlyDatabase(atPath path: String) -> OpaquePointer? {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !isForbiddenDirectKBPath(standardized) else {
            ExtensionLogger.cache.error("Blocked direct sqlite3 open inside .mailkb_db/.mailkb/.moxa-kb sync directory")
            return nil
        }
        guard FileManager.default.isReadableFile(atPath: standardized),
              hasValidSQLiteHeader(atPath: standardized)
        else {
            return nil
        }

        let uri = "\(URL(fileURLWithPath: standardized).absoluteString)?mode=ro&immutable=1"
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI
        let rc = sqlite3_open_v2(uri, &db, flags, nil)
        if rc != SQLITE_OK {
            if let db {
                let errMsg = String(cString: sqlite3_errmsg(db))
                ExtensionLogger.cache.warning("sqlite3_open_v2 failed (\(rc)): \(errMsg, privacy: .public)")
                sqlite3_close(db)
            }
            return nil
        }
        return db
    }

    // MARK: - Query & Aggregation

    private static func buildComparisonGroups(
        for candidateSKUs: [String],
        analysis: EmailAIAnalysis?,
        normalizedSelfMessageID: String,
        db: OpaquePointer
    ) -> [SKUPriceComparisonGroup] {
        var groups: [SKUPriceComparisonGroup] = []

        for queriedSKU in candidateSKUs {
            var seenRecordIDs: Set<String> = []
            let exactRows = queryPriceRows(
                db: db,
                skuPattern: queriedSKU,
                excludedSKUPrefix: nil,
                isExactSKUMatch: true,
                normalizedSelfMessageID: normalizedSelfMessageID,
                maxResults: maxExactMatchesPerSKU,
                seenRecordIDs: &seenRecordIDs
            )

            var combinedRows = exactRows
            if exactRows.count < exactThresholdForSeriesFallback,
               let seriesBase = seriesFallbackBase(for: queriedSKU)
            {
                let seriesRows = queryPriceRows(
                    db: db,
                    skuPattern: seriesBase,
                    excludedSKUPrefix: queriedSKU,
                    isExactSKUMatch: false,
                    normalizedSelfMessageID: normalizedSelfMessageID,
                    maxResults: maxSeriesSupplementPerSKU,
                    seenRecordIDs: &seenRecordIDs
                )
                combinedRows.append(contentsOf: seriesRows)
            }

            guard !combinedRows.isEmpty else { continue }

            let primaryCurrency = resolvePrimaryCurrency(from: combinedRows)
            let canonicalPrimary = canonicalCurrency(primaryCurrency)
            let comparablePrices = combinedRows
                .filter { canonicalPrimary.isEmpty || canonicalCurrency($0.currency) == canonicalPrimary }
                .map(\.unitPrice)
            let minPrice = comparablePrices.min()
            let maxPrice = comparablePrices.max()
            let hint = currentEmailPriceHint(for: queriedSKU, analysis: analysis)

            groups.append(
                SKUPriceComparisonGroup(
                    queriedSKU: queriedSKU,
                    currentEmailPriceHint: hint,
                    minUnitPrice: minPrice,
                    maxUnitPrice: maxPrice,
                    primaryCurrency: primaryCurrency,
                    records: combinedRows
                )
            )
        }

        return groups
    }

    private struct RawPriceRow {
        let messageRowID: Int64
        let sku: String
        let rawCurrency: String
        let currency: String
        let unitPrice: Double
        let quantity: Double?
        let priceType: String
        let taxMode: String
        let customerOrg: String
        let customerTokens: [String]
        let canonicalCustomerSet: Set<String>
        let projectName: String
        let canonicalProject: String
        let quoteDateISO: String
        let subject: String
        let normalizedSubject: String
        let threadTopic: String
        let normalizedThreadTopic: String
        let displayTopic: String
        let rfcMessageID: String
        let normalizedRFCMessageID: String
        let evidenceSnippet: String
        let confidence: String
        let priceKey: String
    }

    private struct PriceDedupBucket {
        private static let maxStoredMessageIDs = 12

        let priceKey: String
        let groupKey: String
        var sku: String
        var currency: String
        var unitPrice: Double
        var quantity: Double?
        var priceType: String
        var taxMode: String
        var orderedCustomers: [String]
        var seenCanonicalCustomers: Set<String>
        var orderedMessageRowIDs: [Int64]
        var seenMessageRowIDs: Set<Int64>
        var projectName: String
        var displayTopic: String
        var quoteDateISO: String
        var subject: String
        var rfcMessageID: String
        var evidenceSnippet: String
        var confidence: String
        var occurrenceCount: Int

        init(from row: RawPriceRow, groupKey: String) {
            self.priceKey = row.priceKey
            self.groupKey = groupKey
            self.sku = row.sku
            self.currency = row.currency.isEmpty ? row.rawCurrency : row.currency
            self.unitPrice = row.unitPrice
            self.quantity = row.quantity
            self.priceType = row.priceType
            self.taxMode = row.taxMode
            self.orderedCustomers = []
            self.seenCanonicalCustomers = []
            self.orderedMessageRowIDs = []
            self.seenMessageRowIDs = []
            self.projectName = row.projectName
            self.displayTopic = row.displayTopic
            self.quoteDateISO = row.quoteDateISO
            self.subject = row.subject
            self.rfcMessageID = row.rfcMessageID
            self.evidenceSnippet = row.evidenceSnippet
            self.confidence = row.confidence.isEmpty ? "medium" : row.confidence
            self.occurrenceCount = 1
            appendCustomers(row.customerTokens)
            appendMessageRowID(row.messageRowID)
        }

        mutating func merge(from row: RawPriceRow) {
            occurrenceCount += 1
            let isIncomingNewer = row.quoteDateISO > quoteDateISO
            if isIncomingNewer {
                quoteDateISO = row.quoteDateISO
                if !row.subject.isEmpty { subject = row.subject }
                if !row.rfcMessageID.isEmpty { rfcMessageID = row.rfcMessageID }
                if !row.evidenceSnippet.isEmpty { evidenceSnippet = row.evidenceSnippet }
            }
            if taxMode.isEmpty, !row.taxMode.isEmpty {
                taxMode = row.taxMode
            }
            appendCustomers(row.customerTokens)
            appendMessageRowID(row.messageRowID, prioritizeFront: isIncomingNewer)
            if projectName.isEmpty, !row.projectName.isEmpty {
                projectName = row.projectName
            }
            if displayTopic.isEmpty, !row.displayTopic.isEmpty {
                displayTopic = row.displayTopic
            }
            if quantity == nil, orderedCustomers.count <= 1, let incomingQty = row.quantity {
                quantity = incomingQty
            }
            if priceTypeRank(row.priceType) < priceTypeRank(priceType) {
                priceType = row.priceType
            }
            let normalizedConf = row.confidence.isEmpty ? "medium" : row.confidence
            if confidenceRank(normalizedConf) < confidenceRank(confidence) {
                confidence = normalizedConf
            }
        }

        mutating func merge(from incoming: PriceDedupBucket) {
            occurrenceCount += incoming.occurrenceCount
            let isIncomingNewer = incoming.quoteDateISO > quoteDateISO
            if isIncomingNewer {
                quoteDateISO = incoming.quoteDateISO
                if !incoming.subject.isEmpty { subject = incoming.subject }
                if !incoming.rfcMessageID.isEmpty { rfcMessageID = incoming.rfcMessageID }
                if !incoming.evidenceSnippet.isEmpty { evidenceSnippet = incoming.evidenceSnippet }
            }
            if taxMode.isEmpty, !incoming.taxMode.isEmpty {
                taxMode = incoming.taxMode
            }
            appendCustomers(incoming.orderedCustomers)
            if isIncomingNewer {
                for rowID in incoming.orderedMessageRowIDs.reversed() {
                    appendMessageRowID(rowID, prioritizeFront: true)
                }
            } else {
                for rowID in incoming.orderedMessageRowIDs {
                    appendMessageRowID(rowID)
                }
            }
            if projectName.isEmpty, !incoming.projectName.isEmpty {
                projectName = incoming.projectName
            }
            if displayTopic.isEmpty, !incoming.displayTopic.isEmpty {
                displayTopic = incoming.displayTopic
            }
            if quantity == nil,
               orderedCustomers.count <= 1,
               incoming.orderedCustomers.count <= 1,
               let incomingQty = incoming.quantity
            {
                quantity = incomingQty
            }
            if priceTypeRank(incoming.priceType) < priceTypeRank(priceType) {
                priceType = incoming.priceType
            }
            if confidenceRank(incoming.confidence) < confidenceRank(confidence) {
                confidence = incoming.confidence
            }
        }

        private mutating func appendCustomers(_ tokens: [String]) {
            for token in tokens {
                let canonical = HistoricalPriceLookupService.canonicalEntityText(token)
                guard !canonical.isEmpty else { continue }
                if seenCanonicalCustomers.insert(canonical).inserted {
                    orderedCustomers.append(token)
                }
            }
        }

        private mutating func appendMessageRowID(_ rowID: Int64, prioritizeFront: Bool = false) {
            guard rowID > 0 else { return }
            if seenMessageRowIDs.insert(rowID).inserted {
                if prioritizeFront {
                    orderedMessageRowIDs.insert(rowID, at: 0)
                    if orderedMessageRowIDs.count > Self.maxStoredMessageIDs {
                        let dropped = orderedMessageRowIDs.removeLast()
                        seenMessageRowIDs.remove(dropped)
                    }
                } else if orderedMessageRowIDs.count < Self.maxStoredMessageIDs {
                    orderedMessageRowIDs.append(rowID)
                } else {
                    seenMessageRowIDs.remove(rowID)
                }
            } else if prioritizeFront, let existingIndex = orderedMessageRowIDs.firstIndex(of: rowID), existingIndex > 0 {
                orderedMessageRowIDs.remove(at: existingIndex)
                orderedMessageRowIDs.insert(rowID, at: 0)
            }
        }

        private func priceTypeRank(_ type: String) -> Int {
            switch type.lowercased() {
            case "order_price": return 0
            case "spr_support": return 1
            case "spr_request": return 2
            case "quote": return 3
            case "historical_price": return 4
            case "": return 9
            default: return 5
            }
        }

        private func confidenceRank(_ conf: String) -> Int {
            switch conf.lowercased() {
            case "high": return 0
            case "medium": return 1
            default: return 2
            }
        }
    }

    private static func preparePriceQueryStatement(db: OpaquePointer) -> OpaquePointer? {
        let primarySQL = """
        SELECT
            v.sku,
            v.currency,
            v.unit_price,
            v.quantity,
            v.price_type,
            v.tax_mode,
            v.customer_org,
            v.project_name,
            v.quote_date_iso,
            v.subject,
            m.message_id AS rfc_message_id,
            v.evidence_snippet,
            v.confidence,
            COALESCE(m.thread_topic, '') AS thread_topic,
            v.message_id AS message_row_id
        FROM v_sku_price_history v
        JOIN messages m ON m.id = v.message_id
        WHERE v.unit_price IS NOT NULL
          AND v.unit_price > 0
          AND (UPPER(v.sku) = UPPER(?1) OR UPPER(v.sku) LIKE UPPER(?2) || '%' ESCAPE '\\')
        ORDER BY v.quote_date_iso DESC,
                 CASE LOWER(v.confidence) WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END,
                 v.message_id DESC
        LIMIT \(sqlScanLimit)
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, primarySQL, -1, &stmt, nil) == SQLITE_OK, let stmt {
            return stmt
        }

        // Fallback for older or minimal mock schemas lacking `messages.thread_topic`.
        let fallbackSQL = """
        SELECT
            v.sku,
            v.currency,
            v.unit_price,
            v.quantity,
            v.price_type,
            v.tax_mode,
            v.customer_org,
            v.project_name,
            v.quote_date_iso,
            v.subject,
            m.message_id AS rfc_message_id,
            v.evidence_snippet,
            v.confidence,
            '' AS thread_topic,
            v.message_id AS message_row_id
        FROM v_sku_price_history v
        JOIN messages m ON m.id = v.message_id
        WHERE v.unit_price IS NOT NULL
          AND v.unit_price > 0
          AND (UPPER(v.sku) = UPPER(?1) OR UPPER(v.sku) LIKE UPPER(?2) || '%' ESCAPE '\\')
        ORDER BY v.quote_date_iso DESC,
                 CASE LOWER(v.confidence) WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END,
                 v.message_id DESC
        LIMIT \(sqlScanLimit)
        """
        if sqlite3_prepare_v2(db, fallbackSQL, -1, &stmt, nil) == SQLITE_OK, let stmt {
            return stmt
        }
        return nil
    }

    private static func queryPriceRows(
        db: OpaquePointer,
        skuPattern: String,
        excludedSKUPrefix: String?,
        isExactSKUMatch: Bool,
        normalizedSelfMessageID: String,
        maxResults: Int,
        seenRecordIDs: inout Set<String>
    ) -> [HistoricalPriceRecord] {
        guard let stmt = preparePriceQueryStatement(db: db) else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        let escapedLike = escapeSQLLike(skuPattern)
        skuPattern.withCString { cStr in
            _ = sqlite3_bind_text(stmt, 1, cStr, -1, sqliteTransient)
        }
        escapedLike.withCString { cStr in
            _ = sqlite3_bind_text(stmt, 2, cStr, -1, sqliteTransient)
        }

        var rowsByPriceKey: [String: [RawPriceRow]] = [:]
        var priceKeyOrder: [String] = []
        let excludedUpperPrefix = excludedSKUPrefix?.uppercased()

        while sqlite3_step(stmt) == SQLITE_ROW {
            let sku = columnString(stmt, index: 0).trimmingCharacters(in: .whitespacesAndNewlines)
            if let excludedUpperPrefix, sku.uppercased().hasPrefix(excludedUpperPrefix) {
                continue
            }
            let rawCurrency = columnString(stmt, index: 1).trimmingCharacters(in: .whitespacesAndNewlines)
            let currency = canonicalCurrency(rawCurrency)
            guard sqlite3_column_type(stmt, 2) != SQLITE_NULL else { continue }
            let unitPrice = sqlite3_column_double(stmt, 2)
            guard unitPrice > 0 else { continue }

            let quantity: Double? = sqlite3_column_type(stmt, 3) == SQLITE_NULL
                ? nil
                : sqlite3_column_double(stmt, 3)
            let priceType = columnString(stmt, index: 4).trimmingCharacters(in: .whitespacesAndNewlines)
            let taxMode = columnString(stmt, index: 5).trimmingCharacters(in: .whitespacesAndNewlines)
            let customerOrg = columnString(stmt, index: 6).trimmingCharacters(in: .whitespacesAndNewlines)
            let projectName = columnString(stmt, index: 7).trimmingCharacters(in: .whitespacesAndNewlines)
            let quoteDateISO = columnString(stmt, index: 8).trimmingCharacters(in: .whitespacesAndNewlines)
            let subject = columnString(stmt, index: 9).trimmingCharacters(in: .whitespacesAndNewlines)
            let rfcMessageID = ParsedEmailContext.normalizeMessageID(columnString(stmt, index: 10))
            let evidenceSnippet = columnString(stmt, index: 11).trimmingCharacters(in: .whitespacesAndNewlines)
            let confidence = columnString(stmt, index: 12).trimmingCharacters(in: .whitespacesAndNewlines)
            let threadTopic = columnString(stmt, index: 13).trimmingCharacters(in: .whitespacesAndNewlines)
            let messageRowID = sqlite3_column_int64(stmt, 14)

            let normalizedRFCMessageID = rfcMessageID.lowercased()
            if !normalizedSelfMessageID.isEmpty,
               !normalizedSelfMessageID.hasPrefix("sha256:"),
               normalizedRFCMessageID == normalizedSelfMessageID
            {
                continue
            }

            if isBogusTinyRMBArtifact(
                unitPrice: unitPrice,
                canonicalCurrency: currency,
                evidenceSnippet: evidenceSnippet
            ) {
                continue
            }

            let customerTokens = splitCustomerTokens(customerOrg)
            let canonicalCustomerSet = Set(customerTokens.map(canonicalEntityText).filter { !$0.isEmpty })
            let cleanedThread = cleanDisplayTopic(threadTopic)
            let cleanedSubject = cleanDisplayTopic(subject)
            let displayTopic = cleanedThread.isEmpty ? cleanedSubject : cleanedThread

            let roundedPrice = String(format: "%.2f", (unitPrice * 100).rounded() / 100)
            let priceKey = "\(sku.uppercased())|\(currency)|\(roundedPrice)"

            let row = RawPriceRow(
                messageRowID: messageRowID,
                sku: sku,
                rawCurrency: rawCurrency,
                currency: currency,
                unitPrice: unitPrice,
                quantity: quantity,
                priceType: priceType,
                taxMode: taxMode,
                customerOrg: customerOrg,
                customerTokens: customerTokens,
                canonicalCustomerSet: canonicalCustomerSet,
                projectName: projectName,
                canonicalProject: canonicalEntityText(projectName),
                quoteDateISO: quoteDateISO,
                subject: subject,
                normalizedSubject: cleanedSubject.lowercased(),
                threadTopic: threadTopic,
                normalizedThreadTopic: cleanedThread.lowercased(),
                displayTopic: displayTopic,
                rfcMessageID: rfcMessageID,
                normalizedRFCMessageID: normalizedRFCMessageID,
                evidenceSnippet: evidenceSnippet,
                confidence: confidence,
                priceKey: priceKey
            )

            if rowsByPriceKey[priceKey] == nil {
                priceKeyOrder.append(priceKey)
            }
            rowsByPriceKey[priceKey, default: []].append(row)
        }

        // Stage 1: Merge rows within each priceKey across same thread, same normalized subject,
        // overlapping customers, or matching project-only entities.
        var stage1Buckets: [PriceDedupBucket] = []
        for priceKey in priceKeyOrder {
            guard let groupRows = rowsByPriceKey[priceKey], !groupRows.isEmpty else { continue }
            let count = groupRows.count
            var parent = Array(0..<count)

            func find(_ x: Int) -> Int {
                var node = x
                while parent[node] != node {
                    parent[node] = parent[parent[node]]
                    node = parent[node]
                }
                return node
            }

            func union(_ a: Int, _ b: Int) {
                let ra = find(a)
                let rb = find(b)
                if ra != rb {
                    if ra < rb {
                        parent[rb] = ra
                    } else {
                        parent[ra] = rb
                    }
                }
            }

            for i in 0..<count {
                let lhs = groupRows[i]
                for j in (i + 1)..<count {
                    if shouldMergeSamePriceRows(lhs, groupRows[j]) {
                        union(i, j)
                    }
                }
            }

            var componentsByRoot: [Int: [RawPriceRow]] = [:]
            var componentOrder: [Int] = []
            for idx in 0..<count {
                let root = find(idx)
                if componentsByRoot[root] == nil {
                    componentOrder.append(root)
                }
                componentsByRoot[root, default: []].append(groupRows[idx])
            }

            for root in componentOrder {
                guard let componentRows = componentsByRoot[root], let first = componentRows.first else { continue }
                let seedKey = componentGroupKey(for: first)
                if seenRecordIDs.contains(seedKey) {
                    continue
                }
                var bucket = PriceDedupBucket(from: first, groupKey: seedKey)
                for row in componentRows.dropFirst() {
                    bucket.merge(from: row)
                }
                stage1Buckets.append(bucket)
            }
        }

        // Stage 2: Collapse sparse rows (empty customerOrg) into a richer record at the same priceKey
        // when project names overlap or when the sparse row has no project metadata at all.
        var richBuckets: [PriceDedupBucket] = []
        var sparseBuckets: [PriceDedupBucket] = []
        for bucket in stage1Buckets {
            if !bucket.orderedCustomers.isEmpty {
                richBuckets.append(bucket)
            } else {
                sparseBuckets.append(bucket)
            }
        }

        let orderedSparse = sparseBuckets.filter { !$0.projectName.isEmpty }
            + sparseBuckets.filter { $0.projectName.isEmpty }
        var remainingSparse: [PriceDedupBucket] = []
        for sparse in orderedSparse {
            if let richIdx = richBuckets.firstIndex(where: { rich in
                rich.priceKey == sparse.priceKey
                    && (sparse.projectName.isEmpty || projectsOverlap(rich.projectName, sparse.projectName))
            }) {
                richBuckets[richIdx].merge(from: sparse)
            } else if sparse.projectName.isEmpty,
                      let anySamePriceIdx = remainingSparse.firstIndex(where: { $0.priceKey == sparse.priceKey })
            {
                remainingSparse[anySamePriceIdx].merge(from: sparse)
            } else {
                remainingSparse.append(sparse)
            }
        }

        var mergedBuckets = richBuckets + remainingSparse
        mergedBuckets.sort { lhs, rhs in
            if lhs.quoteDateISO != rhs.quoteDateISO {
                return lhs.quoteDateISO > rhs.quoteDateISO
            }
            if lhs.occurrenceCount != rhs.occurrenceCount {
                return lhs.occurrenceCount > rhs.occurrenceCount
            }
            return lhs.groupKey < rhs.groupKey
        }

        let limited = Array(mergedBuckets.prefix(maxResults))
        for bucket in limited {
            seenRecordIDs.insert(bucket.groupKey)
        }

        return limited.map { bucket in
            let formattedCustomer = formatCustomerSummary(bucket.orderedCustomers)
            let resolvedProject: String
            if !bucket.projectName.isEmpty {
                resolvedProject = bucket.projectName
            } else if bucket.orderedCustomers.count != 1 {
                resolvedProject = bucket.displayTopic
            } else {
                resolvedProject = ""
            }

            return HistoricalPriceRecord(
                sku: bucket.sku,
                currency: bucket.currency,
                unitPrice: bucket.unitPrice,
                quantity: bucket.quantity,
                priceType: bucket.priceType,
                taxMode: bucket.taxMode,
                customerOrg: formattedCustomer,
                projectName: resolvedProject,
                quoteDateISO: bucket.quoteDateISO,
                subject: bucket.subject,
                rfcMessageID: bucket.rfcMessageID,
                evidenceSnippet: bucket.evidenceSnippet,
                confidence: bucket.confidence,
                isExactSKUMatch: isExactSKUMatch,
                occurrenceCount: bucket.occurrenceCount,
                mailJumpURL: nil,
                sourceMessageRowID: bucket.orderedMessageRowIDs.first,
                mergedMessageRowIDs: bucket.orderedMessageRowIDs
            )
        }
    }

    // MARK: - Source Email Detail Queries

    private static func queryHistoricalEmailDetails(
        db: OpaquePointer,
        record: HistoricalPriceRecord,
        maxMessages: Int
    ) -> [HistoricalEmailDetail] {
        let rowIDs = resolveMessageRowIDs(db: db, record: record, maxMessages: maxMessages)
        guard !rowIDs.isEmpty else { return [] }

        var details: [HistoricalEmailDetail] = []
        details.reserveCapacity(rowIDs.count)
        for rowID in rowIDs {
            if let detail = querySingleEmailDetail(db: db, messageRowID: rowID, targetSKU: record.sku) {
                details.append(detail)
            }
        }
        return details
    }

    private static func resolveMessageRowIDs(
        db: OpaquePointer,
        record: HistoricalPriceRecord,
        maxMessages: Int
    ) -> [Int64] {
        var resolved: [Int64] = []
        var seen: Set<Int64> = []

        func appendRowID(_ id: Int64?) {
            guard let id, id > 0, resolved.count < maxMessages else { return }
            if seen.insert(id).inserted {
                resolved.append(id)
            }
        }

        for id in record.mergedMessageRowIDs {
            appendRowID(id)
        }
        appendRowID(record.sourceMessageRowID)

        if resolved.isEmpty {
            let normalizedID = ParsedEmailContext.normalizeMessageID(record.rfcMessageID)
            if !normalizedID.isEmpty, !normalizedID.hasPrefix("sha256:") {
                let sql = """
                SELECT id
                FROM messages
                WHERE LOWER(TRIM(message_id, '<> ')) = LOWER(?1)
                ORDER BY date_iso DESC, id DESC
                LIMIT ?2
                """
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
                    defer { sqlite3_finalize(stmt) }
                    normalizedID.withCString { cStr in
                        _ = sqlite3_bind_text(stmt, 1, cStr, -1, sqliteTransient)
                    }
                    sqlite3_bind_int(stmt, 2, Int32(maxMessages))
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        appendRowID(sqlite3_column_int64(stmt, 0))
                    }
                }
            }
        }

        return resolved
    }

    private static func prepareSingleMessageStatement(db: OpaquePointer) -> OpaquePointer? {
        let primarySQL = """
        SELECT
            id,
            source,
            message_id,
            subject,
            sender,
            recipients,
            cc,
            date_iso,
            COALESCE(folder_path, '') AS folder_path,
            project_name,
            customers_orgs,
            COALESCE(main_meaning, '') AS main_meaning,
            body_latest,
            body_quoted
        FROM messages
        WHERE id = ?1
        LIMIT 1
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, primarySQL, -1, &stmt, nil) == SQLITE_OK, let stmt {
            return stmt
        }

        // Fallback for minimal mock schemas lacking `folder_path` or `main_meaning`.
        let fallbackSQL = """
        SELECT
            id,
            source,
            message_id,
            subject,
            sender,
            recipients,
            cc,
            date_iso,
            '' AS folder_path,
            project_name,
            customers_orgs,
            '' AS main_meaning,
            body_latest,
            body_quoted
        FROM messages
        WHERE id = ?1
        LIMIT 1
        """
        if sqlite3_prepare_v2(db, fallbackSQL, -1, &stmt, nil) == SQLITE_OK, let stmt {
            return stmt
        }
        return nil
    }

    private static func querySingleEmailDetail(
        db: OpaquePointer,
        messageRowID: Int64,
        targetSKU: String
    ) -> HistoricalEmailDetail? {
        guard let stmt = prepareSingleMessageStatement(db: db) else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, messageRowID)
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }

        let id = sqlite3_column_int64(stmt, 0)
        let source = columnString(stmt, index: 1).trimmingCharacters(in: .whitespacesAndNewlines)
        let rfcMessageID = ParsedEmailContext.normalizeMessageID(columnString(stmt, index: 2))
        let subject = columnString(stmt, index: 3).trimmingCharacters(in: .whitespacesAndNewlines)
        let sender = columnString(stmt, index: 4).trimmingCharacters(in: .whitespacesAndNewlines)
        let recipients = columnString(stmt, index: 5).trimmingCharacters(in: .whitespacesAndNewlines)
        let cc = columnString(stmt, index: 6).trimmingCharacters(in: .whitespacesAndNewlines)
        let dateISO = columnString(stmt, index: 7).trimmingCharacters(in: .whitespacesAndNewlines)
        let folderPath = columnString(stmt, index: 8).trimmingCharacters(in: .whitespacesAndNewlines)
        let projectName = columnString(stmt, index: 9).trimmingCharacters(in: .whitespacesAndNewlines)
        let customersOrgs = columnString(stmt, index: 10).trimmingCharacters(in: .whitespacesAndNewlines)
        let mainMeaning = columnString(stmt, index: 11).trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyLatest = columnString(stmt, index: 12).trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyQuoted = columnString(stmt, index: 13).trimmingCharacters(in: .whitespacesAndNewlines)

        let evidences = queryPriceEvidences(db: db, messageRowID: id, targetSKU: targetSKU)
        let attachments = queryEmailAttachments(db: db, messageRowID: id)

        return HistoricalEmailDetail(
            id: id,
            source: source,
            rfcMessageID: rfcMessageID,
            subject: subject,
            sender: sender,
            recipients: recipients,
            cc: cc,
            dateISO: dateISO,
            folderPath: folderPath,
            projectName: projectName,
            customersOrgs: customersOrgs,
            mainMeaning: mainMeaning,
            bodyLatest: bodyLatest,
            bodyQuoted: bodyQuoted,
            priceEvidences: evidences,
            attachments: attachments,
            mailJumpURL: nil
        )
    }

    private static func queryPriceEvidences(
        db: OpaquePointer,
        messageRowID: Int64,
        targetSKU: String
    ) -> [HistoricalEmailPriceEvidence] {
        let sql = """
        SELECT
            id,
            sku,
            currency,
            unit_price,
            quantity,
            total_amount,
            price_type,
            tax_mode,
            customer_org,
            project_name,
            source_kind,
            evidence_snippet
        FROM message_prices
        WHERE message_id = ?1
          AND unit_price IS NOT NULL
          AND unit_price > 0
        ORDER BY
            CASE
                WHEN UPPER(sku) = UPPER(?2) THEN 0
                WHEN UPPER(sku) LIKE UPPER(?3) || '%' ESCAPE '\\' THEN 1
                ELSE 2
            END,
            id ASC
        LIMIT 24
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        let escapedSKU = escapeSQLLike(targetSKU)
        sqlite3_bind_int64(stmt, 1, messageRowID)
        targetSKU.withCString { cStr in
            _ = sqlite3_bind_text(stmt, 2, cStr, -1, sqliteTransient)
        }
        escapedSKU.withCString { cStr in
            _ = sqlite3_bind_text(stmt, 3, cStr, -1, sqliteTransient)
        }

        var evidences: [HistoricalEmailPriceEvidence] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let priceRowID = sqlite3_column_int64(stmt, 0)
            let sku = columnString(stmt, index: 1).trimmingCharacters(in: .whitespacesAndNewlines)
            let rawCurrency = columnString(stmt, index: 2).trimmingCharacters(in: .whitespacesAndNewlines)
            let currency = canonicalCurrency(rawCurrency)
            guard sqlite3_column_type(stmt, 3) != SQLITE_NULL else { continue }
            let unitPrice = sqlite3_column_double(stmt, 3)
            guard unitPrice > 0 else { continue }

            let quantity: Double? = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                ? nil
                : sqlite3_column_double(stmt, 4)
            let totalAmount: Double? = sqlite3_column_type(stmt, 5) == SQLITE_NULL
                ? nil
                : sqlite3_column_double(stmt, 5)
            let priceType = columnString(stmt, index: 6).trimmingCharacters(in: .whitespacesAndNewlines)
            let taxMode = columnString(stmt, index: 7).trimmingCharacters(in: .whitespacesAndNewlines)
            let customerOrg = columnString(stmt, index: 8).trimmingCharacters(in: .whitespacesAndNewlines)
            let projectName = columnString(stmt, index: 9).trimmingCharacters(in: .whitespacesAndNewlines)
            let sourceKind = columnString(stmt, index: 10).trimmingCharacters(in: .whitespacesAndNewlines)
            let evidenceSnippet = columnString(stmt, index: 11).trimmingCharacters(in: .whitespacesAndNewlines)

            if isBogusTinyRMBArtifact(
                unitPrice: unitPrice,
                canonicalCurrency: currency,
                evidenceSnippet: evidenceSnippet
            ) {
                continue
            }

            evidences.append(
                HistoricalEmailPriceEvidence(
                    id: "\(messageRowID)|\(priceRowID)",
                    sku: sku,
                    currency: currency.isEmpty ? rawCurrency : currency,
                    unitPrice: unitPrice,
                    quantity: quantity,
                    totalAmount: totalAmount,
                    priceType: priceType,
                    taxMode: taxMode,
                    customerOrg: customerOrg,
                    projectName: projectName,
                    sourceKind: sourceKind,
                    evidenceSnippet: evidenceSnippet
                )
            )
        }
        return evidences
    }

    private static func queryEmailAttachments(
        db: OpaquePointer,
        messageRowID: Int64
    ) -> [HistoricalEmailAttachmentInfo] {
        let sql = """
        SELECT
            id,
            filename,
            COALESCE(size_bytes, 0),
            COALESCE(text_preview, '')
        FROM message_attachments_mime
        WHERE message_id = ?1
          AND COALESCE(is_inline, 0) = 0
        ORDER BY id ASC
        LIMIT 16
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, messageRowID)
        var result: [HistoricalEmailAttachmentInfo] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowID = sqlite3_column_int64(stmt, 0)
            let filename = columnString(stmt, index: 1).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !filename.isEmpty else { continue }
            let sizeBytes = sqlite3_column_int64(stmt, 2)
            let textPreview = columnString(stmt, index: 3).trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(
                HistoricalEmailAttachmentInfo(
                    id: "\(messageRowID)|\(rowID)",
                    filename: filename,
                    sizeBytes: sizeBytes,
                    textPreview: textPreview
                )
            )
        }
        return result
    }

    // MARK: - Private Utilities

    private static func shouldMergeSamePriceRows(_ lhs: RawPriceRow, _ rhs: RawPriceRow) -> Bool {
        if !lhs.normalizedRFCMessageID.isEmpty, lhs.normalizedRFCMessageID == rhs.normalizedRFCMessageID {
            return true
        }
        if !lhs.normalizedThreadTopic.isEmpty, lhs.normalizedThreadTopic == rhs.normalizedThreadTopic {
            return true
        }
        if !lhs.normalizedSubject.isEmpty, lhs.normalizedSubject == rhs.normalizedSubject {
            return true
        }
        if (!lhs.normalizedThreadTopic.isEmpty && lhs.normalizedThreadTopic == rhs.normalizedSubject)
            || (!rhs.normalizedThreadTopic.isEmpty && rhs.normalizedThreadTopic == lhs.normalizedSubject)
        {
            return true
        }
        if !lhs.canonicalCustomerSet.isEmpty,
           !rhs.canonicalCustomerSet.isEmpty,
           !lhs.canonicalCustomerSet.isDisjoint(with: rhs.canonicalCustomerSet)
        {
            return true
        }
        if lhs.canonicalCustomerSet.isEmpty,
           rhs.canonicalCustomerSet.isEmpty,
           !lhs.canonicalProject.isEmpty,
           lhs.canonicalProject == rhs.canonicalProject
        {
            return true
        }
        return false
    }

    private static func componentGroupKey(for row: RawPriceRow) -> String {
        if let firstCust = row.customerTokens.first {
            return "\(row.priceKey)|cust:\(canonicalEntityText(firstCust))"
        }
        if !row.canonicalProject.isEmpty {
            return "\(row.priceKey)|proj:\(row.canonicalProject)"
        }
        if !row.normalizedThreadTopic.isEmpty {
            return "\(row.priceKey)|topic:\(row.normalizedThreadTopic)"
        }
        if !row.normalizedSubject.isEmpty {
            return "\(row.priceKey)|subj:\(row.normalizedSubject)"
        }
        return "\(row.priceKey)|mid:\(row.normalizedRFCMessageID)"
    }

    private static func cleanDisplayTopic(_ raw: String) -> String {
        var working = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !working.isEmpty else { return "" }
        if let regex = subjectPrefixRegex {
            let ns = working as NSString
            working = regex.stringByReplacingMatches(
                in: working,
                options: [],
                range: NSRange(location: 0, length: ns.length),
                withTemplate: ""
            )
        }
        return working
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeThreadOrSubject(_ raw: String) -> String {
        cleanDisplayTopic(raw).lowercased()
    }

    private static func splitCustomerTokens(_ raw: String) -> [String] {
        raw.components(separatedBy: CharacterSet(charactersIn: ",，、;；"))
            .map {
                $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }

    private static func formatCustomerSummary(_ orderedUniqueCustomers: [String]) -> String {
        switch orderedUniqueCustomers.count {
        case 0:
            return ""
        case 1:
            return orderedUniqueCustomers[0]
        case 2:
            return "\(orderedUniqueCustomers[0])、\(orderedUniqueCustomers[1])"
        default:
            return "\(orderedUniqueCustomers[0])、\(orderedUniqueCustomers[1]) 等 \(orderedUniqueCustomers.count) 家"
        }
    }

    private static func isBogusTinyRMBArtifact(
        unitPrice: Double,
        canonicalCurrency: String,
        evidenceSnippet: String
    ) -> Bool {
        guard canonicalCurrency == "RMB",
              unitPrice > 0,
              unitPrice < 20,
              abs(unitPrice - unitPrice.rounded()) < 0.000_001,
              !evidenceSnippet.isEmpty,
              let priceContextRegex = substantialPriceContextRegex
        else {
            return false
        }

        let ns = evidenceSnippet as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        guard priceContextRegex.firstMatch(in: evidenceSnippet, options: [], range: fullRange) != nil else {
            return false
        }

        let n = Int(unitPrice.rounded())
        let tokenPattern = #"(?<![A-Za-z0-9./-])0*"# + String(n) + #"(?![A-Za-z0-9./-]|\s*(?:pcs|pc|台|套|个|支|根|条)(?![A-Za-z]))"#
        guard let tokenRegex = try? NSRegularExpression(pattern: tokenPattern, options: [.caseInsensitive]) else {
            return false
        }
        return tokenRegex.firstMatch(in: evidenceSnippet, options: [], range: fullRange) == nil
    }

    private static func canonicalCurrency(_ raw: String) -> String {
        let upper = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch upper {
        case "CNY", "RMB", "人民币", "¥":
            return "RMB"
        default:
            return upper
        }
    }

    private static func canonicalEntityText(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
    }

    private static func projectsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        let a = canonicalEntityText(lhs)
        let b = canonicalEntityText(rhs)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let shorter = a.count <= b.count ? a : b
        let longer = a.count <= b.count ? b : a
        guard shorter.count >= 3 else { return false }
        return longer.contains(shorter)
    }

    private static func seriesFallbackBase(for sku: String) -> String? {
        let segments = sku.split(separator: "-", omittingEmptySubsequences: true)
        guard segments.count >= 2 else { return nil }
        let base = segments.prefix(2).joined(separator: "-")
        guard base.caseInsensitiveCompare(sku) != .orderedSame else { return nil }
        return base
    }

    private static func resolvePrimaryCurrency(from records: [HistoricalPriceRecord]) -> String {
        var counts: [String: Int] = [:]
        var firstSeenByCanonical: [String: String] = [:]
        for record in records {
            let trimmed = record.currency.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let canonical = canonicalCurrency(trimmed)
            counts[canonical, default: 0] += 1
            if firstSeenByCanonical[canonical] == nil {
                firstSeenByCanonical[canonical] = canonical == "RMB" ? "RMB" : trimmed
            }
        }
        guard let best = counts.max(by: { lhs, rhs in
            if lhs.value != rhs.value {
                return lhs.value < rhs.value
            }
            if lhs.key == "RMB" { return false }
            if rhs.key == "RMB" { return true }
            return lhs.key > rhs.key
        }) else {
            return ""
        }
        return firstSeenByCanonical[best.key] ?? best.key
    }

    private static func currentEmailPriceHint(for queriedSKU: String, analysis: EmailAIAnalysis?) -> String? {
        guard let pricing = analysis?.businessElements.pricing, !pricing.isEmpty else {
            return nil
        }
        let targetUpper = queriedSKU.uppercased()
        let match = pricing.first(where: {
            $0.itemOrModel.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == targetUpper
        }) ?? pricing.first(where: { item in
            let itemUpper = item.itemOrModel.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard itemUpper.count >= 4 else { return false }
            return targetUpper.hasPrefix(itemUpper) || itemUpper.hasPrefix(targetUpper)
        })

        guard let match else { return nil }
        let unitPrice = match.unitPrice?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let currency = match.currency?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let quantity = match.quantity?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let terms = match.termsOrLeadTime?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !unitPrice.isEmpty {
            let base = currency.isEmpty ? unitPrice : "\(currency) \(unitPrice)"
            let extras = [quantity.isEmpty ? nil : "x\(quantity)", terms.isEmpty ? nil : terms].compactMap { $0 }
            return extras.isEmpty ? base : "\(base) (\(extras.joined(separator: " · ")))"
        }

        let fallbackParts = [
            quantity.isEmpty ? nil : "数量 \(quantity)",
            terms.isEmpty ? nil : terms,
            match.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        ].compactMap { $0 }.filter { !$0.isEmpty }
        return fallbackParts.isEmpty ? nil : fallbackParts.joined(separator: " · ")
    }

    private static func normalizeCandidateSKU(_ raw: String) -> String {
        let collapsedSpaces = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !collapsedSpaces.isEmpty else { return "" }

        if let spaceIndex = collapsedSpaces.firstIndex(of: " ") {
            let family = String(collapsedSpaces[..<spaceIndex])
            let suffix = String(collapsedSpaces[collapsedSpaces.index(after: spaceIndex)...]).uppercased()
            return "\(canonicalFamilyCasing(family)) \(suffix)"
        }
        return collapsedSpaces.uppercased()
    }

    private static func canonicalFamilyCasing(_ family: String) -> String {
        switch family.lowercased() {
        case "nport": return "NPort"
        case "mgate": return "MGate"
        case "iologik": return "ioLogik"
        case "iothinx": return "ioThinx"
        case "iopac": return "ioPAC"
        case "oncell": return "OnCell"
        case "uport": return "UPort"
        case "mxview": return "MXview"
        default: return family
        }
    }

    private static func isExcludedCandidate(_ uppercasedSKU: String) -> Bool {
        let separators = CharacterSet(charactersIn: "- ")
        if let firstSegment = uppercasedSKU.components(separatedBy: separators).first,
           excludedSKUPrefixes.contains(firstSegment)
        {
            return true
        }
        return false
    }

    private static func isPartOfDomainOrEmail(ns: NSString, matchRange: NSRange) -> Bool {
        if matchRange.location > 0 {
            let prev = ns.substring(with: NSRange(location: matchRange.location - 1, length: 1))
            if prev == "@" {
                return true
            }
        }
        let end = matchRange.location + matchRange.length
        if end < ns.length {
            let tail = ns.substring(from: end).lowercased()
            if tail.hasPrefix("@") || tail.hasPrefix(".com") || tail.hasPrefix(".cn")
                || tail.hasPrefix(".net") || tail.hasPrefix(".org") || tail.hasPrefix(".tw")
            {
                return true
            }
        }
        return false
    }

    private static func isPlausibleDirectModelToken(_ raw: String) -> Bool {
        guard (3...64).contains(raw.count) else { return false }
        let hasLetter = raw.rangeOfCharacter(from: .letters) != nil
        let hasDigit = raw.rangeOfCharacter(from: .decimalDigits) != nil
        guard hasLetter, hasDigit else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ ()"))
        guard raw.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        return !isExcludedCandidate(raw.uppercased())
    }

    private static func isForbiddenDirectKBPath(_ path: String) -> Bool {
        let forbiddenDirs: Set<String> = [".mailkb_db", ".mailkb", ".moxa-kb"]
        let standardizedComponents = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        if standardizedComponents.contains(where: { forbiddenDirs.contains($0) }) {
            return true
        }
        let resolvedComponents = URL(fileURLWithPath: path).resolvingSymlinksInPath().pathComponents
        return resolvedComponents.contains(where: { forbiddenDirs.contains($0) })
    }

    private static func isInsideMailContainer(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return resolved.contains("/Library/Mail")
            || resolved.contains("/Library/Group Containers/UBF8T346G9.Office")
            || resolved.contains("/Library/Thunderbird")
    }

    private static func hasValidSQLiteHeader(atPath path: String) -> Bool {
        let fd = Darwin.open(path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var buf = [UInt8](repeating: 0, count: sqliteMagicHeader.count)
        guard readExactBytes(fd: fd, into: &buf, count: sqliteMagicHeader.count) else {
            return false
        }
        return buf == sqliteMagicHeader
    }

    private static func readExactBytes(fd: Int32, into buffer: inout [UInt8], count: Int) -> Bool {
        var totalRead = 0
        while totalRead < count {
            let n = buffer.withUnsafeMutableBytes { rawPtr -> Int in
                guard let base = rawPtr.baseAddress else { return -1 }
                while true {
                    let res = Darwin.read(fd, base.advanced(by: totalRead), count - totalRead)
                    if res < 0, errno == EINTR { continue }
                    return res
                }
            }
            if n <= 0 { return false }
            totalRead += n
        }
        return true
    }

    private static func writeAllBytes(fd: Int32, buffer: [UInt8], count: Int) -> Bool {
        var totalWritten = 0
        while totalWritten < count {
            let n = buffer.withUnsafeBytes { rawPtr -> Int in
                guard let base = rawPtr.baseAddress else { return -1 }
                while true {
                    let res = Darwin.write(fd, base.advanced(by: totalWritten), count - totalWritten)
                    if res < 0, errno == EINTR { continue }
                    return res
                }
            }
            if n <= 0 { return false }
            totalWritten += n
        }
        return true
    }

    private static func escapeSQLLike(_ input: String) -> String {
        input
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func columnString(_ stmt: OpaquePointer?, index: Int32) -> String {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let cStr = sqlite3_column_text(stmt, index)
        else {
            return ""
        }
        return String(cString: cStr)
    }
}
