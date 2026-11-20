import AppKit
import SwiftUI

/// Parsed semantic inline segment inside AI-generated mail summaries and translations.
public enum MailHighlightSegment: Equatable, Sendable {
    case plain(String)
    case highlight(String)
    case strong(String)
    case code(String)
}

/// Renders AI summary text with lightweight semantic inline styling:
/// - `==...==` -> warm amber/orange emphasis on subtle yellow highlight
/// - `**...**` -> semibold primary emphasis (bold when base weight is already semibold+)
/// - `` `...` `` -> medium monospaced chip for SKUs, standards, document names, and key prices
public struct MailHighlightedText: View {
    public let text: String
    public let fontSize: CGFloat
    public let baseWeight: NSFont.Weight
    public let baseColor: Color
    public let lineSpacing: CGFloat

    public init(
        _ text: String,
        fontSize: CGFloat = 12.5,
        baseWeight: NSFont.Weight = .regular,
        baseColor: Color = .primary,
        lineSpacing: CGFloat = 2
    ) {
        self.text = text
        self.fontSize = fontSize
        self.baseWeight = baseWeight
        self.baseColor = baseColor
        self.lineSpacing = lineSpacing
    }

    public var body: some View {
        Text(Self.makeAttributedString(text, fontSize: fontSize, baseWeight: baseWeight))
            .foregroundStyle(baseColor)
            .lineSpacing(lineSpacing)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    // Dynamic NSColors preserve Light/Dark Aqua updates inside SwiftUI Text.
    private nonisolated static let highlightForegroundNSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.systemOrange
            : NSColor(calibratedRed: 0.72, green: 0.34, blue: 0.0, alpha: 1.0)
    }

    private nonisolated static let highlightBackgroundNSColor = NSColor(name: nil) { _ in
        NSColor.systemYellow.withAlphaComponent(0.22)
    }

    private nonisolated static let codeBackgroundNSColor = NSColor(name: nil) { _ in
        NSColor.labelColor.withAlphaComponent(0.07)
    }

    /// Tokenizes `==...==`, `**...**`, and `` `...` `` spans cleanly.
    /// Unclosed or empty markers are emitted literally so streaming or stray punctuation never drops text.
    nonisolated public static func parseSegments(_ input: String) -> [MailHighlightSegment] {
        guard !input.isEmpty else { return [] }

        var segments: [MailHighlightSegment] = []
        var plainBuffer = ""

        func flushPlain() {
            if !plainBuffer.isEmpty {
                segments.append(.plain(plainBuffer))
                plainBuffer.removeAll(keepingCapacity: true)
            }
        }

        var index = input.startIndex
        while index < input.endIndex {
            if input[index] == "`" {
                var contentStart = index
                var tickCount = 0
                while contentStart < input.endIndex && input[contentStart] == "`" {
                    tickCount += 1
                    contentStart = input.index(after: contentStart)
                }
                let lineEnd = input[contentStart...].firstIndex(where: { $0.isNewline }) ?? input.endIndex

                if tickCount == 1 {
                    if contentStart < lineEnd,
                       let closeRange = input.range(of: "`", range: contentStart..<lineEnd) {
                        let inner = String(input[contentStart..<closeRange.lowerBound])
                        if !inner.isEmpty {
                            flushPlain()
                            segments.append(.code(inner))
                            index = closeRange.upperBound
                            continue
                        }
                    }
                    plainBuffer.append("`")
                    index = contentStart
                    continue
                }

                // Multi-backtick span (e.g., `` `AES-256-CBC` ``, ``DA-682B-PMU-C3``, ```AWK```)
                var cursor = contentStart
                var didMatchMultiTick = false
                while cursor < lineEnd {
                    if input[cursor] == "`" {
                        let closeStart = cursor
                        var closeEnd = cursor
                        var closeCount = 0
                        while closeEnd < lineEnd && input[closeEnd] == "`" {
                            closeCount += 1
                            closeEnd = input.index(after: closeEnd)
                        }
                        if closeCount == tickCount {
                            let cleaned = Self.unwrapNestedCodeSpanContent(String(input[contentStart..<closeStart]))
                            if !cleaned.isEmpty {
                                flushPlain()
                                segments.append(.code(cleaned))
                                index = closeEnd
                                didMatchMultiTick = true
                                break
                            }
                        }
                        cursor = closeEnd
                    } else {
                        cursor = input.index(after: cursor)
                    }
                }

                if didMatchMultiTick {
                    continue
                }

                plainBuffer.append(contentsOf: input[index..<contentStart])
                index = contentStart
                continue
            }

            let remaining = input[index...]

            let matchedMarker: (delimiter: String, makeSegment: (String) -> MailHighlightSegment)?
            if remaining.hasPrefix("==") {
                matchedMarker = ("==", MailHighlightSegment.highlight)
            } else if remaining.hasPrefix("**") {
                matchedMarker = ("**", MailHighlightSegment.strong)
            } else {
                matchedMarker = nil
            }

            if let (delimiter, makeSegment) = matchedMarker {
                let contentStart = input.index(index, offsetBy: delimiter.count)
                // Restrict inline spans to a single line so an unclosed delimiter cannot swallow later paragraphs.
                let lineEnd = input[contentStart...].firstIndex(where: { $0.isNewline }) ?? input.endIndex

                if contentStart < lineEnd,
                   let closeRange = input.range(of: delimiter, range: contentStart..<lineEnd) {
                    let inner = String(input[contentStart..<closeRange.lowerBound])
                    if !inner.isEmpty {
                        flushPlain()
                        segments.append(makeSegment(inner))
                        index = closeRange.upperBound
                        continue
                    }
                }

                plainBuffer.append(delimiter)
                index = contentStart
                continue
            }

            plainBuffer.append(input[index])
            index = input.index(after: index)
        }

        flushPlain()
        return segments
    }

    private nonisolated static func unwrapNestedCodeSpanContent(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        while value.count >= 2, value.hasPrefix("`"), value.hasSuffix("`") {
            let leadingTicks = value.prefix(while: { $0 == "`" }).count
            let trailingTicks = value.reversed().prefix(while: { $0 == "`" }).count
            let stripCount = min(leadingTicks, trailingTicks)
            guard stripCount > 0, value.count > stripCount * 2 else {
                break
            }
            let startIdx = value.index(value.startIndex, offsetBy: stripCount)
            let endIdx = value.index(value.endIndex, offsetBy: -stripCount)
            let unwrapped = String(value[startIdx..<endIdx]).trimmingCharacters(in: .whitespaces)
            guard !unwrapped.isEmpty else {
                break
            }
            value = unwrapped
        }
        if value.allSatisfy({ $0 == "`" }) {
            return ""
        }
        return value
    }

    /// Strips semantic inline highlight markers (`==...==`, `**...**`, `` `...` ``) into clean plain text.
    nonisolated public static func plainText(_ input: String) -> String {
        parseSegments(input).map { segment in
            switch segment {
            case .plain(let value), .highlight(let value), .strong(let value), .code(let value):
                return value
            }
        }.joined()
    }

    /// Builds a SwiftUI-compatible `AttributedString` from inline-marked text.
    nonisolated public static func makeAttributedString(
        _ input: String,
        fontSize: CGFloat = 12.5,
        baseWeight: NSFont.Weight = .regular
    ) -> AttributedString {
        let segments = parseSegments(input)
        guard !segments.isEmpty else { return AttributedString() }

        let baseFont = Font(NSFont.systemFont(ofSize: fontSize, weight: baseWeight))
        let highlightWeight: NSFont.Weight = baseWeight.rawValue >= NSFont.Weight.bold.rawValue ? baseWeight : .semibold
        let highlightFont = Font(NSFont.systemFont(ofSize: fontSize, weight: highlightWeight))
        let strongWeight: NSFont.Weight = if baseWeight.rawValue >= NSFont.Weight.bold.rawValue {
            baseWeight
        } else if baseWeight.rawValue >= NSFont.Weight.semibold.rawValue {
            .bold
        } else {
            .semibold
        }
        let strongFont = Font(NSFont.systemFont(ofSize: fontSize, weight: strongWeight))
        let codeFont = Font(NSFont.monospacedSystemFont(ofSize: max(10, fontSize - 0.5), weight: .medium))

        let highlightFG = Color(nsColor: highlightForegroundNSColor)
        let highlightBG = Color(nsColor: highlightBackgroundNSColor)
        let codeBG = Color(nsColor: codeBackgroundNSColor)

        var output = AttributedString()
        for segment in segments {
            switch segment {
            case .plain(let value):
                var part = AttributedString(value)
                part.font = baseFont
                output.append(part)

            case .highlight(let value):
                var part = AttributedString(value)
                part.font = highlightFont
                part.foregroundColor = highlightFG
                part.backgroundColor = highlightBG
                output.append(part)

            case .strong(let value):
                var part = AttributedString(value)
                part.font = strongFont
                part.foregroundColor = .primary
                output.append(part)

            case .code(let value):
                var part = AttributedString(value)
                part.font = codeFont
                part.backgroundColor = codeBG
                output.append(part)
            }
        }

        return output
    }
}
