import CryptoKit
import Foundation

/// Decoded attachment payload extracted locally from an RFC 5322 MIME message.
public struct ExtractedAttachmentPayload: Identifiable, Sendable, Hashable {
    public let id: String
    public let filename: String
    public let mimeType: String
    public let data: Data
    public let isInline: Bool
    public let sha256Hex: String

    public init(
        id: String? = nil,
        filename: String,
        mimeType: String,
        data: Data,
        isInline: Bool,
        sha256Hex: String? = nil
    ) {
        let computedSHA = sha256Hex ?? MIMEAttachmentExtractor.sha256Hex(of: data)
        self.sha256Hex = computedSHA
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.isInline = isInline
        self.id = id ?? "\(computedSHA.prefix(16))-\(filename)"
    }
}

/// Pure-Swift local RFC 5322 MIME attachment extractor.
/// Walks `multipart/*` and nested `message/rfc822` entities, decodes transfer encodings and
/// RFC 2047 / RFC 2231 filenames, and computes SHA-256 digests without touching disk or network.
public enum MIMEAttachmentExtractor {
    private struct HeaderSection {
        let headers: [String: String]
        let bodyData: Data
    }

    private struct ContentType {
        let mimeType: String
        let mediaType: String
        let subtype: String
        let parameters: [String: String]

        var isMultipart: Bool { mediaType == "multipart" }
        var boundary: String? { parameters["boundary"] }
    }

    private static let maxMultipartParts = 128
    private static let maxRecursionDepth = 16

    private static let signatureMimeTypes: Set<String> = [
        "application/pkcs7-signature",
        "application/x-pkcs7-signature",
        "application/pgp-signature"
    ]

    private static let documentMimeTypes: Set<String> = [
        "application/pdf",
        "application/msword",
        "application/vnd.ms-excel",
        "application/vnd.ms-powerpoint",
        "application/zip",
        "application/x-zip-compressed",
        "application/x-rar-compressed",
        "application/vnd.rar",
        "application/x-7z-compressed",
        "application/x-tar",
        "application/gzip",
        "text/csv"
    ]

    private static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "xlsm", "xlsb",
        "ppt", "pptx", "csv", "zip", "rar", "7z", "tar", "gz",
        "dwg", "dxf", "stp", "step", "igs", "iges", "drawio",
        "eml", "msg", "img", "bin", "fw", "fwr", "hex", "mib"
    ]

    public static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Extracts attachment payloads from raw RFC 5322 message data.
    /// When `includeInline` is `false`, inline images (e.g. signature logos / CID images)
    /// and cryptographic signature parts (`pkcs7-signature`, `pgp-signature`) are skipped.
    public static func extractAttachments(
        from rawData: Data,
        includeInline: Bool = false
    ) -> [ExtractedAttachmentPayload] {
        guard let root = splitHeadersAndBody(rawData) else {
            return []
        }

        var collected: [ExtractedAttachmentPayload] = []
        var partCounter = 0
        walkEntity(
            headers: root.headers,
            bodyData: root.bodyData,
            insideRelated: false,
            includeInline: includeInline,
            depth: 0,
            partCounter: &partCounter,
            into: &collected
        )
        return collected
    }

    // MARK: - Recursive MIME Tree Walk

    private static func walkEntity(
        headers: [String: String],
        bodyData: Data,
        insideRelated: Bool,
        includeInline: Bool,
        depth: Int,
        partCounter: inout Int,
        into results: inout [ExtractedAttachmentPayload]
    ) {
        guard depth < maxRecursionDepth else { return }

        let contentType = parseContentType(headers["content-type"])
        let disposition = parseDisposition(headers["content-disposition"] ?? "")
        let transferEncoding = (headers["content-transfer-encoding"] ?? "7bit")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // 1. Multipart container
        if contentType.isMultipart, let boundary = contentType.boundary, !boundary.isEmpty {
            let childRelated = insideRelated || contentType.subtype == "related"
            let parts = splitMultipartBody(bodyData, boundary: boundary)
            for partData in parts {
                guard let partSection = splitHeadersAndBody(partData) else { continue }
                walkEntity(
                    headers: partSection.headers,
                    bodyData: partSection.bodyData,
                    insideRelated: childRelated,
                    includeInline: includeInline,
                    depth: depth + 1,
                    partCounter: &partCounter,
                    into: &results
                )
            }
            return
        }

        // 2. Embedded message/rfc822
        if contentType.mimeType == "message/rfc822" {
            let decodedMessage = MIMEParser.decodeTransferEncoding(bodyData, encoding: transferEncoding)
            let explicitFilename = extractFilename(
                dispositionParams: disposition.parameters,
                contentTypeParams: contentType.parameters
            )
            if disposition.type == "attachment", let rawName = explicitFilename {
                let name = sanitizeFilename(rawName, fallbackMimeType: contentType.mimeType)
                let digest = sha256Hex(of: decodedMessage)
                partCounter += 1
                results.append(
                    ExtractedAttachmentPayload(
                        id: "\(partCounter)-\(digest.prefix(16))-\(name)",
                        filename: name,
                        mimeType: contentType.mimeType,
                        data: decodedMessage,
                        isInline: false,
                        sha256Hex: digest
                    )
                )
                return
            }

            if let nested = splitHeadersAndBody(decodedMessage) {
                walkEntity(
                    headers: nested.headers,
                    bodyData: nested.bodyData,
                    insideRelated: false,
                    includeInline: includeInline,
                    depth: depth + 1,
                    partCounter: &partCounter,
                    into: &results
                )
            }
            return
        }

        // 3. Leaf part classification
        let rawFilename = extractFilename(
            dispositionParams: disposition.parameters,
            contentTypeParams: contentType.parameters
        )
        let isExplicitAttachment = disposition.type == "attachment"
        let isInlineDisposition = disposition.type == "inline"
        let hasContentID = !(headers["content-id"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let isSignaturePart = signatureMimeTypes.contains(contentType.mimeType)
        let isTextBodyCandidate = contentType.mediaType == "text"
            && (contentType.subtype == "plain" || contentType.subtype == "html")

        let isAttachmentCandidate: Bool
        if isExplicitAttachment {
            isAttachmentCandidate = true
        } else if isSignaturePart {
            isAttachmentCandidate = true
        } else if isTextBodyCandidate {
            // Only extract text/plain or text/html if explicitly marked as Content-Disposition: attachment.
            isAttachmentCandidate = false
        } else if contentType.mediaType == "text" {
            // e.g. text/csv or text/xml with a filename or inline disposition
            isAttachmentCandidate = (rawFilename != nil) || isInlineDisposition
        } else {
            isAttachmentCandidate = (rawFilename != nil)
                || (!contentType.mimeType.isEmpty && contentType.mimeType != "text/plain")
        }

        guard isAttachmentCandidate else { return }

        let resolvedName = sanitizeFilename(
            rawFilename ?? defaultFilename(forMimeType: contentType.mimeType),
            fallbackMimeType: contentType.mimeType
        )
        let ext = (resolvedName as NSString).pathExtension.lowercased()
        let isDocument = documentMimeTypes.contains(contentType.mimeType)
            || contentType.mimeType.hasPrefix("application/vnd.openxmlformats-officedocument.")
            || documentExtensions.contains(ext)

        // Classify inline signature / embedded image parts vs real attachments.
        // Apple Mail often tags attached PDFs/Office docs with Content-Disposition: inline;
        // preserve document types as non-inline while treating inline images, CID resources,
        // and S/MIME / PGP signature parts as inline.
        let isInlinePart: Bool
        if isExplicitAttachment {
            isInlinePart = false
        } else if isSignaturePart {
            isInlinePart = true
        } else if contentType.mediaType == "image" && (isInlineDisposition || hasContentID || insideRelated) {
            isInlinePart = true
        } else if isInlineDisposition && !isDocument {
            isInlinePart = true
        } else if hasContentID && !isDocument {
            isInlinePart = true
        } else {
            isInlinePart = false
        }

        if isInlinePart && !includeInline {
            return
        }

        let decodedData = MIMEParser.decodeTransferEncoding(bodyData, encoding: transferEncoding)
        let digest = sha256Hex(of: decodedData)
        partCounter += 1
        results.append(
            ExtractedAttachmentPayload(
                id: "\(partCounter)-\(digest.prefix(16))-\(resolvedName)",
                filename: resolvedName,
                mimeType: contentType.mimeType,
                data: decodedData,
                isInline: isInlinePart,
                sha256Hex: digest
            )
        )
    }

    // MARK: - Header & Parameter Parsing

    private static func splitHeadersAndBody(_ data: Data) -> HeaderSection? {
        guard !data.isEmpty else { return nil }

        let separators: [Data] = [
            Data([0x0D, 0x0A, 0x0D, 0x0A]), // CRLF CRLF
            Data([0x0A, 0x0A]),             // LF LF
            Data([0x0A, 0x0D, 0x0A]),       // LF CRLF (mixed)
            Data([0x0D, 0x0A, 0x0A])        // CRLF LF (mixed)
        ]

        var earliestRange: Range<Data.Index>?
        for sep in separators {
            if let found = data.range(of: sep) {
                if let current = earliestRange {
                    if found.lowerBound < current.lowerBound {
                        earliestRange = found
                    }
                } else {
                    earliestRange = found
                }
            }
        }

        let headerEnd: Data.Index
        let bodyStart: Data.Index

        if let sepRange = earliestRange {
            headerEnd = sepRange.lowerBound
            bodyStart = sepRange.upperBound
        } else {
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
        for line in unfoldedLines {
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let key = line[..<colonIdx].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let val = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty && headers[key] == nil {
                headers[key] = val
            }
        }

        let bodySlice = bodyStart < data.endIndex ? Data(data[bodyStart...]) : Data()
        return HeaderSection(headers: headers, bodyData: bodySlice)
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
                rawVal = rawVal
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }

            if let starIdx = rawKey.firstIndex(of: "*") {
                let baseKey = String(rawKey[..<starIdx])
                let suffix = String(rawKey[rawKey.index(after: starIdx)...])
                if suffix.isEmpty {
                    // Single RFC 2231 parameter: filename*=UTF-8''...
                    params[rawKey] = decodeRFC2231Value(rawVal)
                } else {
                    // RFC 2231 continuation: filename*0*=..., filename*1*=..., filename*1=...
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
            if sorted.contains(where: \.encoded) {
                params["\(baseKey)*"] = decodeRFC2231Continuation(sorted)
            } else if params[baseKey] == nil {
                params[baseKey] = sorted.map(\.value).joined()
            }
        }

        return params
    }

    private static func decodeRFC2231Value(_ raw: String) -> String {
        MIMEParser.decodeRFC2231(raw)
    }

    /// Decodes multi-segment RFC 2231 continuations (`*0*=`, `*1*=`, `*1=`) at the raw byte level
    /// before charset conversion so multi-byte characters split across continuations remain intact.
    private static func decodeRFC2231Continuation(
        _ sortedParts: [(index: Int, value: String, encoded: Bool)]
    ) -> String {
        var charset = "utf-8"
        var combinedBytes = Data()

        for (idx, part) in sortedParts.enumerated() {
            var payload = part.value
            if idx == 0, part.encoded {
                let comps = payload.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                if comps.count == 3 {
                    let parsedCharset = String(comps[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !parsedCharset.isEmpty {
                        charset = parsedCharset
                    }
                    payload = String(comps[2])
                }
            }

            if part.encoded {
                combinedBytes.append(decodePercentBytes(payload))
            } else {
                combinedBytes.append(Data(payload.utf8))
            }
        }

        return MIMEParser.decodeText(combinedBytes, charset: charset)
    }

    private static func decodePercentBytes(_ input: String) -> Data {
        var bytes = Data()
        let utf8 = Array(input.utf8)
        bytes.reserveCapacity(utf8.count)
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

    private static func hexValue(_ ascii: UInt8) -> UInt8? {
        switch ascii {
        case 0x30...0x39: return ascii - 0x30
        case 0x41...0x46: return ascii - 0x41 + 10
        case 0x61...0x66: return ascii - 0x61 + 10
        default: return nil
        }
    }

    private static func extractFilename(
        dispositionParams: [String: String],
        contentTypeParams: [String: String]
    ) -> String? {
        if let rfc2231 = dispositionParams["filename*"] ?? contentTypeParams["name*"] {
            let trimmed = rfc2231.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let rawName = dispositionParams["filename"] ?? contentTypeParams["name"] {
            let decoded = MIMEParser.decodeRFC2047(rawName).trimmingCharacters(in: .whitespacesAndNewlines)
            if !decoded.isEmpty { return decoded }
        }
        return nil
    }

    private static func sanitizeFilename(_ raw: String, fallbackMimeType: String) -> String {
        let normalizedSeparators = raw
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Take only the terminal filename component to neutralize any embedded path segments.
        let lastComponent = normalizedSeparators
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? normalizedSeparators

        let cleanedScalars = lastComponent.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && scalar != "/" && scalar != "\\"
        }
        let cleaned = String(String.UnicodeScalarView(cleanedScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.isEmpty || cleaned == "." || cleaned == ".." || cleaned.hasPrefix(".") {
            let fallback = defaultFilename(forMimeType: fallbackMimeType)
            if cleaned.hasPrefix("."), cleaned.count > 1, cleaned != ".." {
                return "attachment\(cleaned)"
            }
            return fallback
        }
        return cleaned
    }

    private static func defaultFilename(forMimeType mimeType: String) -> String {
        let lower = mimeType.lowercased()
        switch lower {
        case "application/pdf": return "attachment.pdf"
        case "image/png": return "attachment.png"
        case "image/jpeg", "image/jpg": return "attachment.jpg"
        case "image/gif": return "attachment.gif"
        case "application/msword": return "attachment.doc"
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document": return "attachment.docx"
        case "application/vnd.ms-excel": return "attachment.xls"
        case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": return "attachment.xlsx"
        case "application/vnd.ms-powerpoint": return "attachment.ppt"
        case "application/vnd.openxmlformats-officedocument.presentationml.presentation": return "attachment.pptx"
        case "application/zip", "application/x-zip-compressed": return "attachment.zip"
        case "text/csv": return "attachment.csv"
        case "message/rfc822": return "attachment.eml"
        case "application/pkcs7-signature", "application/x-pkcs7-signature": return "smime.p7s"
        case "application/pgp-signature": return "signature.asc"
        default:
            let ext = lower.split(separator: "/").last.map(String.init) ?? "bin"
            let safeExt = ext.filter { $0.isLetter || $0.isNumber }
            return "attachment.\(safeExt.isEmpty ? "bin" : safeExt)"
        }
    }

    // MARK: - Multipart Splitting

    private static func splitMultipartBody(_ bodyData: Data, boundary: String) -> [Data] {
        guard let boundaryBytes = "--\(boundary)".data(using: .utf8), !bodyData.isEmpty else {
            return []
        }
        var parts: [Data] = []
        var searchStart = bodyData.startIndex

        while parts.count < maxMultipartParts,
              let boundaryRange = findBoundaryLine(boundaryBytes, in: bodyData, from: searchStart)
        {
            let afterBoundary = boundaryRange.upperBound
            if afterBoundary + 1 < bodyData.endIndex,
               bodyData[afterBoundary] == 0x2D,
               bodyData[afterBoundary + 1] == 0x2D
            {
                break
            }

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

            guard let nextBoundary = findBoundaryLine(boundaryBytes, in: bodyData, from: partStart) else {
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

    private static func findBoundaryLine(
        _ boundaryBytes: Data,
        in data: Data,
        from start: Data.Index
    ) -> Range<Data.Index>? {
        var cursor = start
        while cursor < data.endIndex,
              let range = data.range(of: boundaryBytes, in: cursor..<data.endIndex)
        {
            let isLineStart = range.lowerBound == data.startIndex
                || data[data.index(before: range.lowerBound)] == 0x0A
                || data[data.index(before: range.lowerBound)] == 0x0D
            if isLineStart {
                return range
            }
            cursor = range.upperBound
        }
        return nil
    }
}
