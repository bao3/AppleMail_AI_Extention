import Foundation

/// Progressive snapshot extracted from incomplete streaming JSON returned by an LLM.
public struct PartialAnalysisSnapshot: Sendable, Equatable {
    public let headline: String?
    public let suggestedFlag: String?
    public let flagReason: String?
    public let coreConclusions: [String]
    public let plainChineseTranslation: String?

    public static let empty = PartialAnalysisSnapshot()

    public init(
        headline: String? = nil,
        suggestedFlag: String? = nil,
        flagReason: String? = nil,
        coreConclusions: [String] = [],
        plainChineseTranslation: String? = nil
    ) {
        self.headline = headline
        self.suggestedFlag = suggestedFlag
        self.flagReason = flagReason
        self.coreConclusions = coreConclusions
        self.plainChineseTranslation = plainChineseTranslation
    }

    public var isEmpty: Bool {
        headline == nil
            && suggestedFlag == nil
            && flagReason == nil
            && coreConclusions.isEmpty
            && plainChineseTranslation == nil
    }
}

/// Depth-aware incremental JSON scanner that extracts top-level `EmailAIAnalysis` fields
/// from incomplete streaming text while handling escape sequences (`\"`, `\\`, `\n`, `\uXXXX`)
/// and partial strings safely.
public enum PartialEmailAnalysisExtractor {
    public static func extract(from partialJSON: String) -> PartialAnalysisSnapshot {
        let scalars = prepareRootScalars(from: partialJSON)
        guard !scalars.isEmpty else { return .empty }

        var idx = 0
        // Locate root '{'
        while idx < scalars.count && scalars[idx] != "{" {
            idx += 1
        }
        guard idx < scalars.count else { return .empty }
        idx += 1 // step inside root object

        var headline: String?
        var suggestedFlag: String?
        var flagReason: String?
        var coreConclusions: [String] = []
        var plainChineseTranslation: String?

        while idx < scalars.count {
            skipWhitespaceAndCommas(scalars, &idx)
            guard idx < scalars.count else { break }

            if scalars[idx] == "}" {
                break
            }

            guard scalars[idx] == "\"" else {
                break
            }

            guard let keyParsed = parseJSONString(scalars, &idx), keyParsed.isComplete else {
                break
            }
            let key = keyParsed.value

            skipWhitespace(scalars, &idx)
            guard idx < scalars.count, scalars[idx] == ":" else {
                break
            }
            idx += 1 // step past ':'
            skipWhitespace(scalars, &idx)
            guard idx < scalars.count else { break }

            switch key {
            case "headline":
                if scalars[idx] == "\"" {
                    if let parsed = parseJSONString(scalars, &idx) {
                        if !parsed.value.isEmpty {
                            headline = parsed.value
                        }
                        if !parsed.isComplete {
                            return PartialAnalysisSnapshot(
                                headline: headline,
                                suggestedFlag: suggestedFlag,
                                flagReason: flagReason,
                                coreConclusions: coreConclusions,
                                plainChineseTranslation: plainChineseTranslation
                            )
                        }
                    }
                } else if !skipJSONValue(scalars, &idx) {
                    return PartialAnalysisSnapshot(
                        headline: headline,
                        suggestedFlag: suggestedFlag,
                        flagReason: flagReason,
                        coreConclusions: coreConclusions,
                        plainChineseTranslation: plainChineseTranslation
                    )
                }

            case "suggestedFlag":
                if scalars[idx] == "\"" {
                    if let parsed = parseJSONString(scalars, &idx) {
                        if parsed.isComplete, !parsed.value.isEmpty {
                            suggestedFlag = parsed.value
                        }
                        if !parsed.isComplete {
                            return PartialAnalysisSnapshot(
                                headline: headline,
                                suggestedFlag: suggestedFlag,
                                flagReason: flagReason,
                                coreConclusions: coreConclusions,
                                plainChineseTranslation: plainChineseTranslation
                            )
                        }
                    }
                } else if !skipJSONValue(scalars, &idx) {
                    return PartialAnalysisSnapshot(
                        headline: headline,
                        suggestedFlag: suggestedFlag,
                        flagReason: flagReason,
                        coreConclusions: coreConclusions,
                        plainChineseTranslation: plainChineseTranslation
                    )
                }

            case "flagReason":
                if scalars[idx] == "\"" {
                    if let parsed = parseJSONString(scalars, &idx) {
                        if !parsed.value.isEmpty {
                            flagReason = parsed.value
                        }
                        if !parsed.isComplete {
                            return PartialAnalysisSnapshot(
                                headline: headline,
                                suggestedFlag: suggestedFlag,
                                flagReason: flagReason,
                                coreConclusions: coreConclusions,
                                plainChineseTranslation: plainChineseTranslation
                            )
                        }
                    }
                } else if !skipJSONValue(scalars, &idx) {
                    return PartialAnalysisSnapshot(
                        headline: headline,
                        suggestedFlag: suggestedFlag,
                        flagReason: flagReason,
                        coreConclusions: coreConclusions,
                        plainChineseTranslation: plainChineseTranslation
                    )
                }

            case "plainChineseTranslation":
                if scalars[idx] == "\"" {
                    if let parsed = parseJSONString(scalars, &idx) {
                        if !parsed.value.isEmpty {
                            plainChineseTranslation = parsed.value
                        }
                        if !parsed.isComplete {
                            return PartialAnalysisSnapshot(
                                headline: headline,
                                suggestedFlag: suggestedFlag,
                                flagReason: flagReason,
                                coreConclusions: coreConclusions,
                                plainChineseTranslation: plainChineseTranslation
                            )
                        }
                    }
                } else if !skipJSONValue(scalars, &idx) {
                    return PartialAnalysisSnapshot(
                        headline: headline,
                        suggestedFlag: suggestedFlag,
                        flagReason: flagReason,
                        coreConclusions: coreConclusions,
                        plainChineseTranslation: plainChineseTranslation
                    )
                }

            case "coreConclusions":
                if scalars[idx] == "[" {
                    idx += 1 // step inside array
                    while idx < scalars.count {
                        skipWhitespaceAndCommas(scalars, &idx)
                        guard idx < scalars.count else {
                            return PartialAnalysisSnapshot(
                                headline: headline,
                                suggestedFlag: suggestedFlag,
                                flagReason: flagReason,
                                coreConclusions: coreConclusions,
                                plainChineseTranslation: plainChineseTranslation
                            )
                        }
                        if scalars[idx] == "]" {
                            idx += 1
                            break
                        }
                        if scalars[idx] == "\"" {
                            if let item = parseJSONString(scalars, &idx) {
                                if !item.value.isEmpty {
                                    coreConclusions.append(item.value)
                                }
                                if !item.isComplete {
                                    return PartialAnalysisSnapshot(
                                        headline: headline,
                                        suggestedFlag: suggestedFlag,
                                        flagReason: flagReason,
                                        coreConclusions: coreConclusions,
                                        plainChineseTranslation: plainChineseTranslation
                                    )
                                }
                            }
                        } else if !skipJSONValue(scalars, &idx) {
                            return PartialAnalysisSnapshot(
                                headline: headline,
                                suggestedFlag: suggestedFlag,
                                flagReason: flagReason,
                                coreConclusions: coreConclusions,
                                plainChineseTranslation: plainChineseTranslation
                            )
                        }
                    }
                } else if !skipJSONValue(scalars, &idx) {
                    return PartialAnalysisSnapshot(
                        headline: headline,
                        suggestedFlag: suggestedFlag,
                        flagReason: flagReason,
                        coreConclusions: coreConclusions,
                        plainChineseTranslation: plainChineseTranslation
                    )
                }

            default:
                if !skipJSONValue(scalars, &idx) {
                    return PartialAnalysisSnapshot(
                        headline: headline,
                        suggestedFlag: suggestedFlag,
                        flagReason: flagReason,
                        coreConclusions: coreConclusions,
                        plainChineseTranslation: plainChineseTranslation
                    )
                }
            }
        }

        return PartialAnalysisSnapshot(
            headline: headline,
            suggestedFlag: suggestedFlag,
            flagReason: flagReason,
            coreConclusions: coreConclusions,
            plainChineseTranslation: plainChineseTranslation
        )
    }

    // MARK: - Private JSON Scanner Primitives

    private static func prepareRootScalars(from raw: String) -> [UnicodeScalar] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let newlineIdx = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: newlineIdx)...])
            } else {
                return []
            }
        }
        return Array(text.unicodeScalars)
    }

    private static func isWhitespace(_ scalar: UnicodeScalar) -> Bool {
        scalar == " " || scalar == "\n" || scalar == "\r" || scalar == "\t"
    }

    private static func skipWhitespace(_ scalars: [UnicodeScalar], _ idx: inout Int) {
        while idx < scalars.count && isWhitespace(scalars[idx]) {
            idx += 1
        }
    }

    private static func skipWhitespaceAndCommas(_ scalars: [UnicodeScalar], _ idx: inout Int) {
        while idx < scalars.count && (isWhitespace(scalars[idx]) || scalars[idx] == ",") {
            idx += 1
        }
    }

    private static func parseJSONString(
        _ scalars: [UnicodeScalar],
        _ idx: inout Int
    ) -> (value: String, isComplete: Bool)? {
        guard idx < scalars.count, scalars[idx] == "\"" else { return nil }
        idx += 1 // consume opening quote

        var out = String.UnicodeScalarView()

        while idx < scalars.count {
            let scalar = scalars[idx]
            if scalar == "\"" {
                idx += 1
                return (String(out), true)
            }

            if scalar == "\\" {
                guard idx + 1 < scalars.count else {
                    // Trailing backslash waiting for the next streamed chunk
                    return (String(out), false)
                }
                let esc = scalars[idx + 1]
                switch esc {
                case "\"":
                    out.append("\"")
                    idx += 2
                case "\\":
                    out.append("\\")
                    idx += 2
                case "/":
                    out.append("/")
                    idx += 2
                case "b":
                    out.append(UnicodeScalar(0x0008))
                    idx += 2
                case "f":
                    out.append(UnicodeScalar(0x000C))
                    idx += 2
                case "n":
                    out.append("\n")
                    idx += 2
                case "r":
                    out.append("\r")
                    idx += 2
                case "t":
                    out.append("\t")
                    idx += 2
                case "u":
                    guard idx + 5 < scalars.count else {
                        // Incomplete \uXXXX escape sequence at chunk boundary
                        return (String(out), false)
                    }
                    guard let codeUnit = parseHexUInt16(scalars, start: idx + 2) else {
                        out.append(esc)
                        idx += 2
                        continue
                    }

                    if (0xD800...0xDBFF).contains(codeUnit) {
                        // UTF-16 high surrogate; wait for low surrogate \uYYYY if trailing
                        if idx + 11 < scalars.count {
                            if scalars[idx + 6] == "\\",
                               scalars[idx + 7] == "u",
                               let lowUnit = parseHexUInt16(scalars, start: idx + 8),
                               (0xDC00...0xDFFF).contains(lowUnit)
                            {
                                let combined = 0x10000
                                    + ((UInt32(codeUnit) - 0xD800) << 10)
                                    + (UInt32(lowUnit) - 0xDC00)
                                if let combinedScalar = UnicodeScalar(combined) {
                                    out.append(combinedScalar)
                                }
                                idx += 12
                            } else {
                                idx += 6
                            }
                        } else {
                            // Stream might still be emitting the matching low surrogate
                            return (String(out), false)
                        }
                    } else if let decoded = UnicodeScalar(codeUnit) {
                        out.append(decoded)
                        idx += 6
                    } else {
                        idx += 6
                    }
                default:
                    out.append(esc)
                    idx += 2
                }
                continue
            }

            out.append(scalar)
            idx += 1
        }

        return (String(out), false)
    }

    private static func parseHexUInt16(_ scalars: [UnicodeScalar], start: Int) -> UInt16? {
        var value: UInt16 = 0
        for offset in 0..<4 {
            let s = scalars[start + offset]
            let digit: UInt16
            switch s.value {
            case 0x30...0x39:
                digit = UInt16(s.value - 0x30)
            case 0x41...0x46:
                digit = UInt16(s.value - 0x41 + 10)
            case 0x61...0x66:
                digit = UInt16(s.value - 0x61 + 10)
            default:
                return nil
            }
            value = (value << 4) | digit
        }
        return value
    }

    private static func skipJSONValue(_ scalars: [UnicodeScalar], _ idx: inout Int) -> Bool {
        skipWhitespace(scalars, &idx)
        guard idx < scalars.count else { return false }

        let first = scalars[idx]
        if first == "\"" {
            return parseJSONString(scalars, &idx)?.isComplete ?? false
        }

        if first == "{" || first == "[" {
            var depth = 0
            while idx < scalars.count {
                let c = scalars[idx]
                if c == "\"" {
                    guard let parsed = parseJSONString(scalars, &idx), parsed.isComplete else {
                        return false
                    }
                    continue
                }
                if c == "{" || c == "[" {
                    depth += 1
                } else if c == "}" || c == "]" {
                    depth -= 1
                    if depth == 0 {
                        idx += 1
                        return true
                    }
                }
                idx += 1
            }
            return false
        }

        while idx < scalars.count {
            let c = scalars[idx]
            if c == "," || c == "}" || c == "]" || isWhitespace(c) {
                return true
            }
            idx += 1
        }
        return false
    }
}
