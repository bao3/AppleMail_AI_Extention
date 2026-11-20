import CryptoKit
import Foundation

public struct AttachmentSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(filename)|\(mimeType)|\(approximateSizeBytes)|\(isInline)" }
    public let filename: String
    public let mimeType: String
    public let approximateSizeBytes: Int
    public let isInline: Bool

    public init(filename: String, mimeType: String, approximateSizeBytes: Int, isInline: Bool) {
        self.filename = filename
        self.mimeType = mimeType
        self.approximateSizeBytes = approximateSizeBytes
        self.isInline = isInline
    }

    public var formattedSize: String {
        guard approximateSizeBytes > 0 else { return "未知大小" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(approximateSizeBytes))
    }
}

public struct QuotedMessageBlock: Codable, Sendable, Hashable, Identifiable {
    public var id: Int { index }
    public let index: Int
    public let attribution: String
    public let content: String

    public init(index: Int, attribution: String, content: String) {
        self.index = index
        self.attribution = attribution
        self.content = content
    }
}

public struct ParsedEmailContext: Codable, Sendable, Hashable {
    public let messageID: String
    public let subject: String
    public let from: String
    public let to: [String]
    public let cc: [String]
    public let dateString: String
    public let inReplyTo: String?
    public let references: [String]
    public let plainBody: String
    public let quotedChain: [QuotedMessageBlock]
    public let attachments: [AttachmentSummary]

    public init(
        messageID: String,
        subject: String,
        from: String,
        to: [String],
        cc: [String],
        dateString: String,
        inReplyTo: String?,
        references: [String],
        plainBody: String,
        quotedChain: [QuotedMessageBlock],
        attachments: [AttachmentSummary]
    ) {
        self.messageID = Self.normalizeMessageID(messageID)
        self.subject = subject
        self.from = from
        self.to = to
        self.cc = cc
        self.dateString = dateString
        self.inReplyTo = inReplyTo.map { Self.normalizeMessageID($0) }
        self.references = references.map { Self.normalizeMessageID($0) }
        self.plainBody = plainBody
        self.quotedChain = quotedChain
        self.attachments = attachments
    }

    public static func normalizeMessageID(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<"), trimmed.hasSuffix(">"), trimmed.count >= 2 {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func fallbackMessageID(from rawData: Data) -> String {
        let digest = SHA256.hash(data: rawData)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "sha256:\(hex)"
    }

    public var nonInlineAttachments: [AttachmentSummary] {
        attachments.filter { !$0.isInline }
    }

    public func compactForXPCContext(maxBodyChars: Int = 24_000, maxQuoteChars: Int = 18_000) -> ParsedEmailContext {
        let truncatedBody = Self.truncate(plainBody, limit: maxBodyChars)
        var remainingQuoteBudget = maxQuoteChars
        var compactQuotes: [QuotedMessageBlock] = []
        for quote in quotedChain {
            guard remainingQuoteBudget > 0 else { break }
            let trimmedContent = Self.truncate(quote.content, limit: remainingQuoteBudget)
            remainingQuoteBudget -= trimmedContent.count
            compactQuotes.append(
                QuotedMessageBlock(
                    index: quote.index,
                    attribution: Self.truncate(quote.attribution, limit: 240),
                    content: trimmedContent
                )
            )
        }
        return ParsedEmailContext(
            messageID: messageID,
            subject: subject,
            from: from,
            to: to,
            cc: cc,
            dateString: dateString,
            inReplyTo: inReplyTo,
            references: references,
            plainBody: truncatedBody,
            quotedChain: compactQuotes,
            attachments: attachments
        )
    }

    public func formattedPromptInput(
        maxBodyChars: Int = 16_000,
        maxQuoteChars: Int = 10_000,
        maxQuoteBlocks: Int = 8
    ) -> String {
        var lines: [String] = []
        lines.append("Message-ID: \(messageID)")
        lines.append("Subject: \(subject.isEmpty ? "(无主题)" : subject)")
        lines.append("From: \(from.isEmpty ? "(未知发件人)" : from)")
        if !to.isEmpty {
            lines.append("To: \(to.joined(separator: ", "))")
        }
        if !cc.isEmpty {
            lines.append("Cc: \(cc.joined(separator: ", "))")
        }
        if !dateString.isEmpty {
            lines.append("Date: \(dateString)")
        }
        if attachments.isEmpty {
            lines.append("Attachments: (无)")
        } else {
            let desc = attachments.map { item in
                let tag = item.isInline ? "内嵌" : "附件"
                return "[\(tag)] \(item.filename) (\(item.mimeType), \(item.formattedSize))"
            }
            lines.append("Attachments: \(desc.joined(separator: "; "))")
        }

        let cleanedBody = Self.strippingTrailingDisclaimer(plainBody)
        let boundedBody = Self.truncate(cleanedBody, limit: maxBodyChars)
        lines.append("")
        lines.append("=== 最新正文 (Latest Message Body) ===")
        lines.append(boundedBody.isEmpty ? "(正文为空)" : boundedBody)

        if !quotedChain.isEmpty, maxQuoteBlocks > 0, maxQuoteChars > 0 {
            var remainingQuoteBudget = maxQuoteChars
            var includedLines: [String] = []
            for block in quotedChain.prefix(maxQuoteBlocks) {
                guard remainingQuoteBudget > 0 else { break }
                let cleanedQuote = Self.strippingTrailingDisclaimer(block.content)
                let content = Self.truncate(cleanedQuote, limit: remainingQuoteBudget)
                remainingQuoteBudget -= content.count
                includedLines.append("--- 引用段 #\(block.index): \(Self.truncate(block.attribution, limit: 240)) ---")
                includedLines.append(content)
            }
            if !includedLines.isEmpty {
                lines.append("")
                lines.append("=== 历史引用链 (Quoted Thread History, 按原文从近到远) ===")
                lines.append(contentsOf: includedLines)
                if quotedChain.count > maxQuoteBlocks || remainingQuoteBudget <= 0 {
                    lines.append("...（其余更早引用已省略）")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static let disclaimerAnchorRegexes: [NSRegularExpression] = [
        #"(?i)^(?:[-_=*]{2,}\s*)?(?:confidentiality\s+notice|confidentiality\s+disclaimer|privilege\s+and\s+confidentiality(?:\s+notice)?|notice\s+of\s+confidentiality|legal\s+disclaimer|e-?mail\s+disclaimer)\b"#,
        #"(?i)^this\s+(?:e-?mail|message|communication|transmission)(?:\s+and\s+any\s+(?:attachments?|files?)(?:\s+thereto|\s+transmitted\s+with\s+it)?)?\s+(?:is|are)\s+(?:strictly\s+)?(?:confidential|privileged|intended\s+(?:only|solely))\b"#,
        #"(?i)^the\s+information\s+(?:contained|transmitted)\s+in\s+this\s+(?:e-?mail|message|transmission)\s+is\s+(?:strictly\s+)?(?:confidential|privileged|intended\s+(?:only|solely))\b"#,
        #"(?i)^(?:important\s+notice|disclaimer)\s*[:\-]\s*this\s+(?:e-?mail|message|information)\b"#,
        #"(?i)^please\s+consider\s+the\s+environment\s+before\s+printing\s+this\s+(?:e-?mail|email|message)\b"#,
        #"^(?:保密声明|保密聲明|免责声明|免責聲明|机密声明|機密聲明)\s*[:：]"#,
        #"^(?:本邮件|本電子郵件|本电子邮件|此邮件|本郵件)(?:及其|及任何|及所附|內容|内容).*?(?:机密|保密|機密|仅供指定收件人)"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    private static let conditionalRecipientRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?i)^if\s+you\s+(?:are\s+not|have\s+received\s+this\s+(?:e-?mail|message)\s+in\s+error)\b"#
    )

    private static let separatorLineRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^\s*[-_=*~]{2,}\s*$"#
    )

    /// Removes trailing legal/confidentiality boilerplate disclaimers while preserving genuine email content.
    public static func strippingTrailingDisclaimer(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard !lines.isEmpty else { return "" }

        var cutIndex: Int?
        let maxTrailingBoilerplateChars = 2_800

        for idx in lines.indices {
            let trimmed = lines[idx].trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let tail = lines[idx...].joined(separator: "\n")
            guard tail.count <= maxTrailingBoilerplateChars else { continue }

            let nsLine = trimmed as NSString
            let range = NSRange(location: 0, length: nsLine.length)

            let matchesStrongAnchor = disclaimerAnchorRegexes.contains {
                $0.firstMatch(in: trimmed, options: [], range: range) != nil
            }

            let matchesRecipientFallback: Bool
            if !matchesStrongAnchor,
               let condRegex = conditionalRecipientRegex,
               condRegex.firstMatch(in: trimmed, options: [], range: range) != nil
            {
                let lowerTail = tail.lowercased()
                matchesRecipientFallback = lowerTail.contains("confidential")
                    || lowerTail.contains("delete")
                    || lowerTail.contains("notify")
                    || lowerTail.contains("prohibited")
                    || lowerTail.contains("unauthorized")
            } else {
                matchesRecipientFallback = false
            }

            if matchesStrongAnchor || matchesRecipientFallback {
                cutIndex = idx
                break
            }
        }

        guard var finalCut = cutIndex else {
            return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Also drop blank lines and horizontal separator lines immediately preceding the disclaimer block
        while finalCut > 0 {
            let prev = lines[finalCut - 1].trimmingCharacters(in: .whitespaces)
            if prev.isEmpty {
                finalCut -= 1
                continue
            }
            if let sepRegex = separatorLineRegex {
                let nsPrev = prev as NSString
                if sepRegex.firstMatch(in: prev, options: [], range: NSRange(location: 0, length: nsPrev.length)) != nil {
                    finalCut -= 1
                    continue
                }
            }
            break
        }

        return lines[..<finalCut]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        guard limit > 0, text.count > limit else { return text }
        let idx = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<idx]) + "\n...[已截断]"
    }
}
