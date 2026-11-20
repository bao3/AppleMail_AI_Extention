import CoreFoundation
import Foundation

/// Pure-Swift local RFC 5322 / MIME parser.
/// Performs zero network I/O and never retains raw attachment payloads in memory.
public enum MIMEParser {
    private struct HeaderSection {
        let headers: [String: String]
        let rawHeaderValues: [String: [String]]
        let bodyData: Data
    }

    private struct ContentType {
        let mimeType: String
        let mediaType: String
        let subtype: String
        let parameters: [String: String]

        var isMultipart: Bool { mediaType == "multipart" }
        var boundary: String? { parameters["boundary"] }
        var charset: String? { parameters["charset"] }
        var name: String? { parameters["name"] }
    }

    private struct ExtractedContent {
        var plainCandidates: [String] = []
        var htmlCandidates: [String] = []
        var attachments: [AttachmentSummary] = []
    }

    // MARK: - Safety Limits for MailKit Hot Path

    /// Maximum raw bytes decoded for a single text/plain or text/html leaf part.
    private static let maxTextLeafRawBytes = 256 * 1024
    /// Maximum characters processed by HTML-to-text regexes.
    private static let maxHTMLInputChars = 160_000
    /// Maximum number of MIME parts processed in a single multipart container.
    private static let maxMultipartParts = 64

    // MARK: - Public Entry Points

    /// Checks only top-level MIME headers to avoid intercepting S/MIME or PGP encrypted envelopes.
    public static func isEncryptedEnvelope(_ rawData: Data) -> Bool {
        guard let headerSection = splitHeadersAndBody(rawData, bodySliceNeeded: false) else {
            return false
        }
        let ctRaw = headerSection.headers["content-type"]?.lowercased() ?? ""
        if ctRaw.contains("application/pkcs7-mime")
            || ctRaw.contains("application/x-pkcs7-mime")
            || ctRaw.contains("multipart/encrypted")
            || ctRaw.contains("application/pgp-encrypted")
        {
            return true
        }
        return false
    }

    /// Checks top-level MIME headers for any S/MIME or PGP encrypted OR signed envelope
    /// so Mail's native cryptographic verification/decryption pipeline handles them untouched.
    public static func isProtectedSecurityEnvelope(_ rawData: Data) -> Bool {
        if isEncryptedEnvelope(rawData) {
            return true
        }
        guard let headerSection = splitHeadersAndBody(rawData, bodySliceNeeded: false) else {
            return false
        }
        let ctRaw = headerSection.headers["content-type"]?.lowercased() ?? ""
        if ctRaw.contains("multipart/signed")
            || ctRaw.contains("application/pkcs7-signature")
            || ctRaw.contains("application/x-pkcs7-signature")
            || ctRaw.contains("application/pgp-signature")
        {
            return true
        }
        return false
    }

    /// Extracts lowercased RFC 5322 top-level header arrays without decoding the message body.
    public static func extractTopLevelHeaders(_ rawData: Data) -> [String: [String]] {
        splitHeadersAndBody(rawData, bodySliceNeeded: false)?.rawHeaderValues ?? [:]
    }

    /// Parses raw RFC 5322 MIME data locally into headers, body, reply chain, and attachment summaries.
    public static func parse(rawData: Data) -> ParsedEmailContext {
        guard let root = splitHeadersAndBody(rawData, bodySliceNeeded: true) else {
            let fallbackText = decodeText(rawData, charset: "utf-8")
            let (latest, quotes) = splitReplyChain(fallbackText)
            return ParsedEmailContext(
                messageID: ParsedEmailContext.fallbackMessageID(from: rawData),
                subject: "",
                from: "",
                to: [],
                cc: [],
                dateString: "",
                inReplyTo: nil,
                references: [],
                plainBody: latest,
                quotedChain: quotes,
                attachments: []
            )
        }

        let rawMessageID = root.headers["message-id"] ?? ""
        let messageID = rawMessageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ParsedEmailContext.fallbackMessageID(from: rawData)
            : ParsedEmailContext.normalizeMessageID(rawMessageID)

        let subject = decodeRFC2047(root.headers["subject"] ?? "")
        let from = decodeRFC2047(root.headers["from"] ?? "")
        let to = splitAddressList(decodeRFC2047(root.headers["to"] ?? ""))
        let cc = splitAddressList(decodeRFC2047(root.headers["cc"] ?? ""))
        let dateString = root.headers["date"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let inReplyTo = root.headers["in-reply-to"].flatMap { val -> String? in
            let cleaned = ParsedEmailContext.normalizeMessageID(val)
            return cleaned.isEmpty ? nil : cleaned
        }
        let references = extractMessageIDs(from: root.headers["references"] ?? "")

        var extracted = ExtractedContent()
        extractEntity(
            headers: root.headers,
            bodyData: root.bodyData,
            into: &extracted,
            depth: 0
        )

        let chosenBody = selectBestBody(
            plainCandidates: extracted.plainCandidates,
            htmlCandidates: extracted.htmlCandidates
        )
        let (latestBody, quotedChain) = splitReplyChain(chosenBody)

        return ParsedEmailContext(
            messageID: messageID,
            subject: subject,
            from: from,
            to: to,
            cc: cc,
            dateString: dateString,
            inReplyTo: inReplyTo,
            references: references,
            plainBody: latestBody,
            quotedChain: quotedChain,
            attachments: deduplicateAttachments(extracted.attachments)
        )
    }

    // MARK: - Recursive MIME Tree Extraction

    private static func extractEntity(
        headers: [String: String],
        bodyData: Data,
        into extracted: inout ExtractedContent,
        depth: Int
    ) {
        guard depth < 16 else { return }

        let contentType = parseContentType(headers["content-type"])
        let dispositionHeader = headers["content-disposition"] ?? ""
        let disposition = parseDisposition(dispositionHeader)
        let transferEncoding = (headers["content-transfer-encoding"] ?? "7bit")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // 1. Multipart container
        if contentType.isMultipart, let boundary = contentType.boundary, !boundary.isEmpty {
            let parts = splitMultipartBody(bodyData, boundary: boundary)
            if contentType.subtype == "alternative" {
                var altExtracted = ExtractedContent()
                for partData in parts {
                    guard let partSection = splitHeadersAndBody(partData, bodySliceNeeded: true) else { continue }
                    extractEntity(
                        headers: partSection.headers,
                        bodyData: partSection.bodyData,
                        into: &altExtracted,
                        depth: depth + 1
                    )
                }
                let bestAlt = selectBestBody(
                    plainCandidates: altExtracted.plainCandidates,
                    htmlCandidates: altExtracted.htmlCandidates
                )
                if !bestAlt.isEmpty {
                    extracted.plainCandidates.append(bestAlt)
                }
                extracted.attachments.append(contentsOf: altExtracted.attachments)
                return
            }

            for partData in parts {
                guard let partSection = splitHeadersAndBody(partData, bodySliceNeeded: true) else { continue }
                extractEntity(
                    headers: partSection.headers,
                    bodyData: partSection.bodyData,
                    into: &extracted,
                    depth: depth + 1
                )
            }
            return
        }

        // 2. Embedded message/rfc822
        if contentType.mimeType == "message/rfc822" {
            let decodedData = decodeTransferEncoding(bodyData, encoding: transferEncoding)
            if let nestedSection = splitHeadersAndBody(decodedData, bodySliceNeeded: true) {
                var nested = ExtractedContent()
                extractEntity(
                    headers: nestedSection.headers,
                    bodyData: nestedSection.bodyData,
                    into: &nested,
                    depth: depth + 1
                )
                let nestedBody = selectBestBody(
                    plainCandidates: nested.plainCandidates,
                    htmlCandidates: nested.htmlCandidates
                )
                if !nestedBody.isEmpty {
                    let subSubject = decodeRFC2047(nestedSection.headers["subject"] ?? "")
                    let subFrom = decodeRFC2047(nestedSection.headers["from"] ?? "")
                    let headerLine = [subFrom, subSubject].filter { !$0.isEmpty }.joined(separator: " | ")
                    let prefix = headerLine.isEmpty ? "[嵌套邮件]" : "[嵌套邮件: \(headerLine)]"
                    extracted.plainCandidates.append("\(prefix)\n\(nestedBody)")
                }
                extracted.attachments.append(contentsOf: nested.attachments)
            }
            return
        }

        // 3. Attachment / non-text leaf
        let filename = extractFilename(dispositionParams: disposition.parameters, contentTypeParams: contentType.parameters)
        let isExplicitAttachment = disposition.type == "attachment"
        let isInlineDisposition = disposition.type == "inline"
        let isTextPart = contentType.mediaType == "text"

        if isExplicitAttachment || (!isTextPart && filename != nil) || (!isTextPart && !contentType.mimeType.isEmpty && contentType.mimeType != "text/plain") {
            let resolvedName = filename ?? defaultFilename(forMimeType: contentType.mimeType)
            let decodedApprox = approximateDecodedSize(rawSize: bodyData.count, transferEncoding: transferEncoding)
            let appleLength = bodyData.isEmpty
                ? (headers["x-apple-content-length"].flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0)
                : 0
            let approxBytes = bodyData.isEmpty && appleLength > 0 ? appleLength : decodedApprox
            let summary = AttachmentSummary(
                filename: resolvedName,
                mimeType: contentType.mimeType,
                approximateSizeBytes: approxBytes,
                isInline: isInlineDisposition && !isExplicitAttachment
            )
            extracted.attachments.append(summary)
            return
        }

        // 4. Text leaf (text/plain or text/html or text/*)
        let decodedBytes = decodeTransferEncoding(bodyData, encoding: transferEncoding)
        let decodedString = decodeText(decodedBytes, charset: contentType.charset ?? "utf-8")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        if contentType.subtype == "html" {
            if !decodedString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                extracted.htmlCandidates.append(decodedString)
            }
        } else {
            if !decodedString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                extracted.plainCandidates.append(decodedString)
            }
        }
    }

    private static func selectBestBody(plainCandidates: [String], htmlCandidates: [String]) -> String {
        let joinedPlain = plainCandidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        let convertedHTML = htmlCandidates
            .map { htmlToReadableText($0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        if joinedPlain.isEmpty {
            return convertedHTML
        }
        if convertedHTML.isEmpty {
            return joinedPlain
        }

        // Prefer HTML table-rich text if plain text is only a stub or lacks pipe-delimited rows that HTML has
        let htmlHasTable = htmlCandidates.contains { $0.lowercased().contains("<table") && $0.lowercased().contains("<tr") }
        if htmlHasTable && convertedHTML.contains(" | ") && !joinedPlain.contains(" | ") && convertedHTML.count >= joinedPlain.count / 2 {
            return convertedHTML
        }
        if joinedPlain.count < 40 && convertedHTML.count > joinedPlain.count * 3 {
            return convertedHTML
        }
        return joinedPlain
    }

    // MARK: - Header & Parameter Parsing

    private static func splitHeadersAndBody(_ data: Data, bodySliceNeeded: Bool) -> HeaderSection? {
        guard !data.isEmpty else { return nil }

        // Search for CRLFCRLF or LFLF
        let crlfSep = Data([0x0D, 0x0A, 0x0D, 0x0A])
        let lfSep = Data([0x0A, 0x0A])

        let headerEnd: Data.Index
        let bodyStart: Data.Index

        let crlfRange = data.range(of: crlfSep)
        let lfRange = data.range(of: lfSep)

        switch (crlfRange, lfRange) {
        case let (r1?, r2?):
            if r1.lowerBound <= r2.lowerBound {
                headerEnd = r1.lowerBound
                bodyStart = r1.upperBound
            } else {
                headerEnd = r2.lowerBound
                bodyStart = r2.upperBound
            }
        case let (r1?, nil):
            headerEnd = r1.lowerBound
            bodyStart = r1.upperBound
        case let (nil, r2?):
            headerEnd = r2.lowerBound
            bodyStart = r2.upperBound
        case (nil, nil):
            // Could be headers-only or body-only; check if first line looks like an RFC5322 header
            let preview = String(decoding: data.prefix(512), as: UTF8.self)
            if preview.contains(":") && !preview.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
                headerEnd = data.endIndex
                bodyStart = data.endIndex
            } else {
                return nil
            }
        }

        let headerData = data[..<headerEnd]
        let headerText = String(decoding: headerData, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var unfoldedLines: [String] = []
        for line in headerText.split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = line.first, first == " " || first == "\t", !unfoldedLines.isEmpty {
                let continuation = line.drop(while: { $0 == " " || $0 == "\t" })
                unfoldedLines[unfoldedLines.count - 1] += " " + continuation
            } else if !line.isEmpty {
                unfoldedLines.append(String(line))
            }
        }

        var headers: [String: String] = [:]
        var rawHeaderValues: [String: [String]] = [:]
        for line in unfoldedLines {
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let key = line[..<colonIdx].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let val = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                if headers[key] == nil {
                    headers[key] = val
                }
                rawHeaderValues[key, default: []].append(val)
            }
        }

        let bodySlice = bodySliceNeeded && bodyStart < data.endIndex ? Data(data[bodyStart...]) : Data()
        return HeaderSection(headers: headers, rawHeaderValues: rawHeaderValues, bodyData: bodySlice)
    }

    private static func parseContentType(_ raw: String?) -> ContentType {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ContentType(mimeType: "text/plain", mediaType: "text", subtype: "plain", parameters: [:])
        }
        let segments = splitSemicolonHeader(raw)
        let mimeRaw = (segments.first ?? "text/plain").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = mimeRaw.split(separator: "/", maxSplits: 1).map(String.init)
        let mediaType = parts.first ?? "text"
        let subtype = parts.count > 1 ? parts[1] : "plain"
        let params = parseHeaderParameters(Array(segments.dropFirst()))
        return ContentType(mimeType: "\(mediaType)/\(subtype)", mediaType: mediaType, subtype: subtype, parameters: params)
    }

    private static func parseDisposition(_ raw: String) -> (type: String, parameters: [String: String]) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", [:]) }
        let segments = splitSemicolonHeader(trimmed)
        let dispType = (segments.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let params = parseHeaderParameters(Array(segments.dropFirst()))
        return (dispType, params)
    }

    private static func splitSemicolonHeader(_ input: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false

        for ch in input {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" && inQuotes {
                escaped = true
                current.append(ch)
                continue
            }
            if ch == "\"" {
                inQuotes.toggle()
                current.append(ch)
                continue
            }
            if ch == ";" && !inQuotes {
                result.append(current)
                current = ""
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    private static func parseHeaderParameters(_ segments: [String]) -> [String: String] {
        var params: [String: String] = [:]
        var rfc2231Segments: [String: [(index: Int, value: String, encoded: Bool)]] = [:]

        for seg in segments {
            guard let eqIdx = seg.firstIndex(of: "=") else { continue }
            let rawKey = seg[..<eqIdx].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var rawVal = seg[seg.index(after: eqIdx)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if rawVal.hasPrefix("\""), rawVal.hasSuffix("\""), rawVal.count >= 2 {
                rawVal = String(rawVal.dropFirst().dropLast())
            }

            // Handle RFC 2231 e.g. filename*=UTF-8''... or filename*0*=UTF-8''...
            if let starIdx = rawKey.firstIndex(of: "*") {
                let baseKey = String(rawKey[..<starIdx])
                let suffix = String(rawKey[rawKey.index(after: starIdx)...])
                if suffix.isEmpty {
                    params[rawKey] = rawVal
                } else {
                    let isEncoded = suffix.hasSuffix("*")
                    let indexDigits = suffix.replacingOccurrences(of: "*", with: "")
                    let partIndex = Int(indexDigits) ?? 0
                    rfc2231Segments[baseKey, default: []].append((partIndex, rawVal, isEncoded))
                }
            } else {
                params[rawKey] = rawVal
            }
        }

        for (baseKey, parts) in rfc2231Segments {
            let sorted = parts.sorted { $0.index < $1.index }
            let joined = sorted.map(\.value).joined()
            if sorted.contains(where: \.encoded) {
                params["\(baseKey)*"] = joined
            } else if params[baseKey] == nil {
                params[baseKey] = joined
            }
        }

        return params
    }

    private static func extractFilename(dispositionParams: [String: String], contentTypeParams: [String: String]) -> String? {
        if let rfc2231 = dispositionParams["filename*"] ?? contentTypeParams["name*"] {
            let decoded = decodeRFC2231(rfc2231)
            if !decoded.isEmpty { return decoded }
        }
        if let rawName = dispositionParams["filename"] ?? contentTypeParams["name"] {
            let decoded = decodeRFC2047(rawName).trimmingCharacters(in: .whitespacesAndNewlines)
            if !decoded.isEmpty { return decoded }
        }
        return nil
    }

    private static func defaultFilename(forMimeType mimeType: String) -> String {
        let ext = mimeType.split(separator: "/").last.map(String.init) ?? "bin"
        return "attachment.\(ext)"
    }

    // MARK: - Multipart Splitting

    private static func splitMultipartBody(_ bodyData: Data, boundary: String) -> [Data] {
        guard let boundaryBytes = "--\(boundary)".data(using: .utf8), !bodyData.isEmpty else {
            return []
        }
        var parts: [Data] = []
        var searchStart = bodyData.startIndex

        while parts.count < maxMultipartParts,
              let boundaryRange = bodyData.range(of: boundaryBytes, in: searchStart..<bodyData.endIndex)
        {
            let afterBoundary = boundaryRange.upperBound
            if afterBoundary + 1 < bodyData.endIndex,
               bodyData[afterBoundary] == 0x2D,
               bodyData[afterBoundary + 1] == 0x2D
            {
                // Closing boundary `--boundary--`
                break
            }

            // Skip optional spaces/tabs and CRLF or LF immediately after boundary
            var partStart = afterBoundary
            while partStart < bodyData.endIndex, bodyData[partStart] == 0x20 || bodyData[partStart] == 0x09 {
                partStart = bodyData.index(after: partStart)
            }
            if partStart < bodyData.endIndex, bodyData[partStart] == 0x0D {
                partStart = bodyData.index(after: partStart)
            }
            if partStart < bodyData.endIndex, bodyData[partStart] == 0x0A {
                partStart = bodyData.index(after: partStart)
            }

            guard let nextBoundary = bodyData.range(of: boundaryBytes, in: partStart..<bodyData.endIndex) else {
                // Take remaining data up to end if closing boundary was omitted
                if partStart < bodyData.endIndex {
                    parts.append(Data(bodyData[partStart..<bodyData.endIndex]))
                }
                break
            }

            var partEnd = nextBoundary.lowerBound
            if partEnd > partStart, bodyData[bodyData.index(before: partEnd)] == 0x0A {
                partEnd = bodyData.index(before: partEnd)
                if partEnd > partStart, bodyData[bodyData.index(before: partEnd)] == 0x0D {
                    partEnd = bodyData.index(before: partEnd)
                }
            }
            if partEnd > partStart {
                parts.append(Data(bodyData[partStart..<partEnd]))
            }
            searchStart = nextBoundary.lowerBound
        }

        return parts
    }

    // MARK: - Transfer Encodings & Charsets

    private static func approximateDecodedSize(rawSize: Int, transferEncoding: String) -> Int {
        switch transferEncoding {
        case "base64":
            return max(0, (rawSize * 3) / 4)
        default:
            return rawSize
        }
    }

    public static func decodeTransferEncoding(_ data: Data, encoding: String) -> Data {
        switch encoding.lowercased() {
        case "base64":
            // Strip CR/LF/spaces without failing on whitespace inside MIME base64 blocks
            let cleaned = data.filter { byte in
                byte != 0x0D && byte != 0x0A && byte != 0x20 && byte != 0x09
            }
            return Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters) ?? data
        case "quoted-printable":
            return decodeQuotedPrintableBytes(data, underscoreAsSpace: false)
        default:
            return data
        }
    }

    /// Decodes Quoted-Printable at the raw byte level BEFORE charset conversion
    /// so multi-byte UTF-8 or GB18030 characters split across `=\r\n` soft line breaks stay intact.
    public static func decodeQuotedPrintableBytes(_ data: Data, underscoreAsSpace: Bool) -> Data {
        var out = Data()
        out.reserveCapacity(data.count)

        var i = data.startIndex
        let end = data.endIndex

        while i < end {
            let byte = data[i]
            if underscoreAsSpace && byte == 0x5F { // '_'
                out.append(0x20)
                i = data.index(after: i)
                continue
            }
            if byte == 0x3D { // '='
                let next1 = data.index(after: i)
                if next1 < end {
                    let b1 = data[next1]
                    // Soft line break: =\r\n or =\n
                    if b1 == 0x0A {
                        i = data.index(after: next1)
                        continue
                    }
                    if b1 == 0x0D {
                        let next2 = data.index(after: next1)
                        if next2 < end && data[next2] == 0x0A {
                            i = data.index(after: next2)
                        } else {
                            i = next2
                        }
                        continue
                    }
                    let next2 = data.index(after: next1)
                    if next2 < end, let hi = hexValue(b1), let lo = hexValue(data[next2]) {
                        out.append((hi << 4) | lo)
                        i = data.index(after: next2)
                        continue
                    }
                }
            }
            out.append(byte)
            i = data.index(after: i)
        }
        return out
    }

    private static func hexValue(_ ascii: UInt8) -> UInt8? {
        switch ascii {
        case 0x30...0x39: return ascii - 0x30
        case 0x41...0x46: return ascii - 0x41 + 10
        case 0x61...0x66: return ascii - 0x61 + 10
        default: return nil
        }
    }

    public static func decodeText(_ data: Data, charset: String) -> String {
        guard !data.isEmpty else { return "" }
        let normalized = charset
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .lowercased()

        if normalized.isEmpty || normalized == "utf-8" || normalized == "utf8" {
            if let s = String(data: data, encoding: .utf8) { return s }
        }

        // Map common Chinese / legacy mail charsets reliably via CoreFoundation
        let mappedName: String
        switch normalized {
        case "gb2312", "gb_2312-80", "gbk", "cp936", "x-gbk":
            mappedName = "GB18030"
        default:
            mappedName = normalized
        }

        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(mappedName as CFString)
        if cfEncoding != kCFStringEncodingInvalidId {
            let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            if let str = String(data: data, encoding: String.Encoding(rawValue: nsEncoding)) {
                return str
            }
        }

        // Fallback chain: UTF-8 -> GB18030 -> ISO-8859-1 -> lossy UTF-8
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        let gbEncoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let gb = String(data: data, encoding: String.Encoding(rawValue: gbEncoding)) { return gb }
        if let latin = String(data: data, encoding: .isoLatin1) { return latin }
        return String(decoding: data, as: UTF8.self)
    }

    /// Decodes RFC 2047 `=?charset?B|Q?payload?=` words, collapsing whitespace between adjacent encoded words.
    public static func decodeRFC2047(_ input: String) -> String {
        let pattern = #"=\?([^?\s]+)\?([bBqQ])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return input
        }

        let nsInput = input as NSString
        let fullRange = NSRange(location: 0, length: nsInput.length)
        let matches = regex.matches(in: input, range: fullRange)
        guard !matches.isEmpty else { return input }

        var output = ""
        var cursor = 0

        for (idx, match) in matches.enumerated() {
            let matchRange = match.range
            if matchRange.location > cursor {
                let betweenRange = NSRange(location: cursor, length: matchRange.location - cursor)
                let between = nsInput.substring(with: betweenRange)
                // RFC 2047 section 6.2: whitespace solely between two encoded words is ignored
                let isWhitespaceOnly = between.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if !(idx > 0 && isWhitespaceOnly) {
                    output += between
                }
            }

            let charset = nsInput.substring(with: match.range(at: 1))
            let encodingFlag = nsInput.substring(with: match.range(at: 2)).uppercased()
            let payload = nsInput.substring(with: match.range(at: 3))

            if encodingFlag == "B", let rawBytes = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) {
                output += decodeText(rawBytes, charset: charset)
            } else if encodingFlag == "Q", let payloadBytes = payload.data(using: .ascii) {
                let decodedBytes = decodeQuotedPrintableBytes(payloadBytes, underscoreAsSpace: true)
                output += decodeText(decodedBytes, charset: charset)
            } else {
                output += nsInput.substring(with: matchRange)
            }

            cursor = matchRange.location + matchRange.length
        }

        if cursor < nsInput.length {
            output += nsInput.substring(from: cursor)
        }
        return output
    }

    /// Decodes RFC 2231 `charset'lang'percent-encoded` parameter strings.
    public static func decodeRFC2231(_ raw: String) -> String {
        let components = raw.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        guard components.count == 3 else {
            return decodeRFC2047(raw.removingPercentEncoding ?? raw)
        }
        let charset = String(components[0])
        let encodedPayload = String(components[2])
        let bytes = decodePercentBytes(encodedPayload)
        return decodeText(bytes, charset: charset.isEmpty ? "utf-8" : charset)
    }

    private static func decodePercentBytes(_ input: String) -> Data {
        var bytes = Data()
        let utf8 = Array(input.utf8)
        var i = 0
        while i < utf8.count {
            if utf8[i] == 0x25, i + 2 < utf8.count,
               let hi = hexValue(utf8[i + 1]),
               let lo = hexValue(utf8[i + 2])
            {
                bytes.append((hi << 4) | lo)
                i += 3
            } else {
                bytes.append(utf8[i])
                i += 1
            }
        }
        return bytes
    }

    // MARK: - HTML to Readable Text

    private static let htmlDropRegexes: [NSRegularExpression] = [
        #"(?is)<head\b[^>]*>.*?</head>"#,
        #"(?is)<style\b[^>]*>.*?</style>"#,
        #"(?is)<script\b[^>]*>.*?</script>"#,
        #"(?s)<!--.*?-->"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    private static let htmlReplacementRules: [(NSRegularExpression, String)] = [
        (#"(?i)</t[dh]\s*>"#, " | "),
        (#"(?i)</tr\s*>"#, "\n"),
        (#"(?i)<br\s*/?>"#, "\n"),
        (#"(?i)</(p|div|li|h[1-6]|blockquote|section|article)\s*>"#, "\n"),
        (#"(?i)<li\b[^>]*>"#, "• "),
        (#"(?i)<hr\b[^>]*>"#, "\n---\n"),
        (#"(?s)<[^>]+>"#, "")
    ].compactMap { pattern, template in
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return (regex, template)
    }

    private static func applying(_ regex: NSRegularExpression, to text: String, template: String) -> String {
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    private static func collapseHorizontalSpaces(_ line: String) -> String {
        var result = ""
        result.reserveCapacity(line.count)
        var lastWasSpace = false
        for ch in line {
            if ch == " " || ch == "\t" {
                if !lastWasSpace {
                    result.append(" ")
                    lastWasSpace = true
                }
            } else {
                result.append(ch)
                lastWasSpace = false
            }
        }
        return result
    }

    public static func htmlToReadableText(_ html: String) -> String {
        var text: String
        if html.count > maxHTMLInputChars {
            let cut = html.index(html.startIndex, offsetBy: maxHTMLInputChars)
            text = String(html[..<cut])
        } else {
            text = html
        }

        // Remove <head>, <style>, <script>, and HTML comments
        for regex in htmlDropRegexes {
            text = applying(regex, to: text, template: "")
        }

        // Convert table cells and block boundaries, then strip remaining tags
        for (regex, replacement) in htmlReplacementRules {
            text = applying(regex, to: text, template: replacement)
        }

        // Decode HTML entities
        text = decodeHTMLEntities(text)

        // Clean up line whitespace while preserving table pipes
        let cleanedLines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var s = collapseHorizontalSpaces(String(line)).trimmingCharacters(in: .whitespaces)
                while s.hasSuffix(" |") {
                    s = String(s.dropLast(2)).trimmingCharacters(in: .whitespaces)
                }
                return s
            }

        var collapsed: [String] = []
        var blankRun = 0
        for line in cleanedLines {
            if line.isEmpty {
                blankRun += 1
                if blankRun <= 1 { collapsed.append("") }
            } else {
                blankRun = 0
                collapsed.append(line)
            }
        }
        return collapsed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeHTMLEntities(_ input: String) -> String {
        var s = input
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&mdash;", with: "—")
            .replacingOccurrences(of: "&ndash;", with: "–")

        // Numeric decimal &#1234; and hex &#x4E2D;
        guard let regex = try? NSRegularExpression(pattern: #"&#(x?[0-9a-fA-F]+);"#) else {
            return s
        }
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }

        var mutable = s
        for match in matches.reversed() {
            let token = ns.substring(with: match.range(at: 1))
            let codePoint: UInt32?
            if token.lowercased().hasPrefix("x") {
                codePoint = UInt32(token.dropFirst(), radix: 16)
            } else {
                codePoint = UInt32(token, radix: 10)
            }
            if let cp = codePoint, let scalar = UnicodeScalar(cp),
               let swiftRange = Range(match.range, in: mutable)
            {
                mutable.replaceSubrange(swiftRange, with: String(scalar))
            }
        }
        s = mutable
        return s
    }

    // MARK: - Reply Chain Splitting

    /// Separates the latest message body from historical quoted thread blocks.
    public static func splitReplyChain(_ text: String) -> (latestBody: String, quotes: [QuotedMessageBlock]) {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else { return ("", []) }

        let lines = normalized.components(separatedBy: "\n")
        var sections: [(attribution: String, lines: [String])] = [("", [])]
        var idx = 0

        while idx < lines.count {
            let line = lines[idx]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 1. Explicit Outlook / Apple Mail / QQ / NetEase separators
            if isSeparatorBanner(trimmed) {
                sections.append((trimmed, []))
                idx += 1
                continue
            }

            // 2. "On ... wrote:" or "在 ... 写道：" (sometimes wrapped across 2 lines)
            if isAttributionLine(trimmed) {
                sections.append((trimmed, []))
                idx += 1
                continue
            }
            if idx + 1 < lines.count {
                let twoLine = trimmed + " " + lines[idx + 1].trimmingCharacters(in: .whitespaces)
                if isAttributionLine(twoLine) && !trimmed.isEmpty && trimmed.count < 160 {
                    sections.append((twoLine, []))
                    idx += 2
                    continue
                }
            }

            // 3. Header block like "From: ..." followed within 3 lines by "Sent:/Date:" or "发件人:" + "发送时间:"
            if idx > 0 && looksLikeQuotedHeaderBlock(lines: lines, startIndex: idx) {
                let lastSectionIsEmpty = sections.count > 1 && sections[sections.count - 1].lines.allSatisfy {
                    $0.trimmingCharacters(in: .whitespaces).isEmpty
                }
                if lastSectionIsEmpty {
                    sections[sections.count - 1].lines.append(line)
                } else {
                    sections.append((trimmed, [line]))
                }
                idx += 1
                continue
            }

            // 4. First transition into `> ` quoted block when current section has real body text
            if trimmed.hasPrefix(">") {
                let stripped = stripLeadingQuoteMarkers(line)
                if sections.count == 1 && !sections[0].lines.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    sections.append(("引用内容", [stripped]))
                    idx += 1
                    continue
                } else if sections.count > 1 {
                    sections[sections.count - 1].lines.append(stripped)
                    idx += 1
                    continue
                }
            }

            sections[sections.count - 1].lines.append(line)
            idx += 1
        }

        let latestBody = sections[0].lines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var quotes: [QuotedMessageBlock] = []
        for (offset, sec) in sections.dropFirst().enumerated() {
            let content = sec.lines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty || !sec.attribution.isEmpty {
                quotes.append(
                    QuotedMessageBlock(
                        index: offset + 1,
                        attribution: sec.attribution.isEmpty ? "历史引用 #\(offset + 1)" : sec.attribution,
                        content: content
                    )
                )
            }
        }

        return (latestBody, quotes)
    }

    private static func isSeparatorBanner(_ line: String) -> Bool {
        let lower = line.lowercased()
        if lower.contains("-----original message-----")
            || lower.contains("-----原始邮件-----")
            || lower.contains("------------------ 原始邮件 ------------------")
            || lower.contains("forwarded message")
            || lower.contains("转发的邮件")
        {
            return true
        }
        return false
    }

    private static func isAttributionLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 10, trimmed.count <= 260 else { return false }
        if trimmed.range(of: #"^(On\s+.+\s+wrote:|Am\s+.+\s+schrieb\s+.+:)$"#, options: .regularExpression) != nil {
            return true
        }
        if trimmed.range(of: #"^在\s+.+\s*(写道|回复道|来信中提到)[:：]?$"#, options: .regularExpression) != nil {
            return true
        }
        if trimmed.hasSuffix("wrote:") && (trimmed.hasPrefix("On ") || trimmed.contains("@")) {
            return true
        }
        return false
    }

    private static func looksLikeQuotedHeaderBlock(lines: [String], startIndex: Int) -> Bool {
        let first = lines[startIndex].trimmingCharacters(in: .whitespaces).lowercased()
        let isFrom = first.hasPrefix("from:") || first.hasPrefix("发件人:") || first.hasPrefix("发件人：")
        guard isFrom else { return false }
        let upper = min(lines.count, startIndex + 5)
        for j in (startIndex + 1)..<upper {
            let l = lines[j].trimmingCharacters(in: .whitespaces).lowercased()
            if l.hasPrefix("sent:") || l.hasPrefix("date:") || l.hasPrefix("发送时间:") || l.hasPrefix("发送时间：") || l.hasPrefix("日期:") || l.hasPrefix("日期：") {
                return true
            }
        }
        return false
    }

    private static func stripLeadingQuoteMarkers(_ line: String) -> String {
        var s = line
        while let first = s.trimmingCharacters(in: .whitespaces).first, first == ">" {
            s = s.trimmingCharacters(in: .whitespaces)
            s.removeFirst()
            if s.hasPrefix(" ") { s.removeFirst() }
        }
        return s
    }

    // MARK: - Helpers

    private static func splitAddressList(_ raw: String) -> [String] {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var items: [String] = []
        var current = ""
        var inQuotes = false
        for ch in raw {
            if ch == "\"" {
                inQuotes.toggle()
                current.append(ch)
            } else if ch == "," && !inQuotes {
                let item = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !item.isEmpty { items.append(item) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        let last = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty { items.append(last) }
        return items
    }

    private static func extractMessageIDs(from raw: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"<([^>]+)>"#) else { return [] }
        let ns = raw as NSString
        return regex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            .map { ParsedEmailContext.normalizeMessageID(ns.substring(with: $0.range(at: 1))) }
            .filter { !$0.isEmpty }
    }

    private static func deduplicateAttachments(_ items: [AttachmentSummary]) -> [AttachmentSummary] {
        var seen = Set<AttachmentSummary>()
        var result: [AttachmentSummary] = []
        for item in items where seen.insert(item).inserted {
            result.append(item)
        }
        return result
    }
}
