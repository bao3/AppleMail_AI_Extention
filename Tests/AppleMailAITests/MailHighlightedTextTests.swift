import AppKit
import SwiftUI
import XCTest

final class MailHighlightedTextTests: XCTestCase {
    private let exactExample =
        "客户认为当前提供的漏洞管理PPT（`Moxa_ENISA_SRP`）==内容过于简单==，明确要求**提供详细漏洞管理流程的正式PDF文档**。"

    func testParseSegmentsWithExactExample() {
        let segments = MailHighlightedText.parseSegments(exactExample)

        XCTAssertEqual(segments, [
            .plain("客户认为当前提供的漏洞管理PPT（"),
            .code("Moxa_ENISA_SRP"),
            .plain("）"),
            .highlight("内容过于简单"),
            .plain("，明确要求"),
            .strong("提供详细漏洞管理流程的正式PDF文档"),
            .plain("。")
        ])
    }

    func testMakeAttributedStringWithExactExample() throws {
        let attr = MailHighlightedText.makeAttributedString(exactExample)
        XCTAssertEqual(
            String(attr.characters),
            "客户认为当前提供的漏洞管理PPT（Moxa_ENISA_SRP）内容过于简单，明确要求提供详细漏洞管理流程的正式PDF文档。"
        )

        let runs = Array(attr.runs)
        XCTAssertEqual(runs.count, 7)

        let expectedPlainFont = Font(NSFont.systemFont(ofSize: 12.5, weight: .regular))
        let expectedSemiboldFont = Font(NSFont.systemFont(ofSize: 12.5, weight: .semibold))
        let expectedCodeFont = Font(NSFont.monospacedSystemFont(ofSize: 12.0, weight: .medium))

        // 0: plain prefix
        XCTAssertEqual(String(attr[runs[0].range].characters), "客户认为当前提供的漏洞管理PPT（")
        XCTAssertEqual(runs[0].font, expectedPlainFont)
        XCTAssertNil(runs[0].foregroundColor)
        XCTAssertNil(runs[0].backgroundColor)

        // 1: code (`Moxa_ENISA_SRP`)
        XCTAssertEqual(String(attr[runs[1].range].characters), "Moxa_ENISA_SRP")
        XCTAssertEqual(runs[1].font, expectedCodeFont)
        XCTAssertNil(runs[1].foregroundColor)
        XCTAssertNotNil(runs[1].backgroundColor)

        // 2: plain punctuation
        XCTAssertEqual(String(attr[runs[2].range].characters), "）")
        XCTAssertEqual(runs[2].font, expectedPlainFont)

        // 3: highlight (==内容过于简单==)
        XCTAssertEqual(String(attr[runs[3].range].characters), "内容过于简单")
        XCTAssertEqual(runs[3].font, expectedSemiboldFont)
        let highlightFG = try XCTUnwrap(runs[3].foregroundColor)
        let highlightBG = try XCTUnwrap(runs[3].backgroundColor)

        // Verify adaptive foreground resolves differently in Light vs Dark Aqua
        let resolvedFG = NSColor(highlightFG)
        var lightRGB: NSColor?
        var darkRGB: NSColor?
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            lightRGB = resolvedFG.usingColorSpace(.sRGB)
        }
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            darkRGB = resolvedFG.usingColorSpace(.sRGB)
        }
        let lightColor = try XCTUnwrap(lightRGB)
        let darkColor = try XCTUnwrap(darkRGB)
        XCTAssertGreaterThan(darkColor.redComponent, lightColor.redComponent)
        XCTAssertGreaterThan(lightColor.redComponent, 0.65)
        XCTAssertLessThan(lightColor.blueComponent, 0.05)

        // Verify highlight background alpha is subtle (~0.22)
        var bgAlpha: CGFloat = 0
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            bgAlpha = NSColor(highlightBG).usingColorSpace(.sRGB)?.alphaComponent ?? 0
        }
        XCTAssertEqual(bgAlpha, 0.22, accuracy: 0.02)

        // 4: plain connector
        XCTAssertEqual(String(attr[runs[4].range].characters), "，明确要求")
        XCTAssertEqual(runs[4].font, expectedPlainFont)

        // 5: strong (**提供详细漏洞管理流程的正式PDF文档**)
        XCTAssertEqual(String(attr[runs[5].range].characters), "提供详细漏洞管理流程的正式PDF文档")
        XCTAssertEqual(runs[5].font, expectedSemiboldFont)
        XCTAssertEqual(runs[5].foregroundColor, .primary)
        XCTAssertNil(runs[5].backgroundColor)

        // 6: trailing period
        XCTAssertEqual(String(attr[runs[6].range].characters), "。")
        XCTAssertEqual(runs[6].font, expectedPlainFont)
    }

    func testCodeFontClampsMinimumSizeAndHeadlinePromotesStrongWeight() {
        let smallCodeAttr = MailHighlightedText.makeAttributedString("`SKU`", fontSize: 9.0)
        let codeRun = smallCodeAttr.runs.first
        XCTAssertEqual(
            codeRun?.font,
            Font(NSFont.monospacedSystemFont(ofSize: 10.0, weight: .medium))
        )

        let headlineAttr = MailHighlightedText.makeAttributedString(
            "确认**正式报价**",
            fontSize: 13.5,
            baseWeight: .semibold
        )
        let runs = Array(headlineAttr.runs)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].font, Font(NSFont.systemFont(ofSize: 13.5, weight: .semibold)))
        XCTAssertEqual(runs[1].font, Font(NSFont.systemFont(ofSize: 13.5, weight: .bold)))
        XCTAssertEqual(runs[1].foregroundColor, .primary)
    }

    func testAdjacentMarkers() {
        let input = "==紧急阻断==**立刻确认**`TN-4908-4GTX-WV-CT-T`"
        XCTAssertEqual(MailHighlightedText.parseSegments(input), [
            .highlight("紧急阻断"),
            .strong("立刻确认"),
            .code("TN-4908-4GTX-WV-CT-T")
        ])

        let attr = MailHighlightedText.makeAttributedString(input)
        XCTAssertEqual(String(attr.characters), "紧急阻断立刻确认TN-4908-4GTX-WV-CT-T")
        XCTAssertEqual(Array(attr.runs).count, 3)

        let backToBackSameKind = "==A====B==**C****D**`E``F`"
        XCTAssertEqual(MailHighlightedText.parseSegments(backToBackSameKind), [
            .highlight("A"),
            .highlight("B"),
            .strong("C"),
            .strong("D"),
            .code("E"),
            .code("F")
        ])
    }

    func testUnclosedAndEmptyMarkersRenderLiterally() {
        let cases: [(String, [MailHighlightSegment])] = [
            ("价格 * 10 = 100 美元", [.plain("价格 * 10 = 100 美元")]),
            ("进度==卡在法务审核", [.plain("进度==卡在法务审核")]),
            ("**重要待确认", [.plain("**重要待确认")]),
            ("型号 `TN-4908 待确认", [.plain("型号 `TN-4908 待确认")]),
            ("== ** `", [.plain("== ** `")]),
            ("==== **** ``", [.plain("==== **** ``")]),
            ("注意 ==未闭合 **关键动作** 结束", [.plain("注意 ==未闭合 "), .strong("关键动作"), .plain(" 结束")]),
            ("第一段 ==未闭合\n第二段 ==真实风险== 结束", [.plain("第一段 ==未闭合\n第二段 "), .highlight("真实风险"), .plain(" 结束")]),
            ("==单价=485过高== **2*3=6**", [.highlight("单价=485过高"), .plain(" "), .strong("2*3=6")])
        ]

        for (input, expected) in cases {
            XCTAssertEqual(MailHighlightedText.parseSegments(input), expected, "Input: \(input)")
            let attr = MailHighlightedText.makeAttributedString(input)
            let expectedText = expected.map { segment -> String in
                switch segment {
                case .plain(let s), .highlight(let s), .strong(let s), .code(let s):
                    return s
                }
            }.joined()
            XCTAssertEqual(String(attr.characters), expectedText, "AttributedString text mismatch for: \(input)")
        }
    }

    func testPlainTextAndEmptyInput() {
        XCTAssertEqual(MailHighlightedText.parseSegments(""), [])
        XCTAssertTrue(MailHighlightedText.makeAttributedString("").characters.isEmpty)

        let plain = "纯中文邮件摘要文本，没有任何内联标记。"
        XCTAssertEqual(MailHighlightedText.parseSegments(plain), [.plain(plain)])

        let attr = MailHighlightedText.makeAttributedString(plain)
        XCTAssertEqual(String(attr.characters), plain)
        XCTAssertEqual(Array(attr.runs).count, 1)
    }

    @MainActor
    func testMailHighlightedTextViewWrapsInsideConstrainedPopoverCard() {
        let wideHost = NSHostingView(
            rootView: MailHighlightedText(exactExample)
                .frame(width: 720, alignment: .leading)
        )
        let narrowHost = NSHostingView(
            rootView: MailHighlightedText(exactExample)
                .frame(width: 220, alignment: .leading)
        )

        wideHost.layoutSubtreeIfNeeded()
        narrowHost.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(narrowHost.fittingSize.height, wideHost.fittingSize.height)
        XCTAssertLessThanOrEqual(narrowHost.fittingSize.width, 221)
    }

    func testPlainTextStripsInlineMarkersCleanly() {
        XCTAssertEqual(
            MailHighlightedText.plainText(exactExample),
            "客户认为当前提供的漏洞管理PPT（Moxa_ENISA_SRP）内容过于简单，明确要求提供详细漏洞管理流程的正式PDF文档。"
        )
        XCTAssertEqual(MailHighlightedText.plainText("==紧急== **处理** `TN-4908`"), "紧急 处理 TN-4908")
        XCTAssertEqual(MailHighlightedText.plainText("进度==未闭合"), "进度==未闭合")
    }
}
