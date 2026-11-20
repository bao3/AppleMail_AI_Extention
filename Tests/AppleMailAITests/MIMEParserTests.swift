import Foundation
import MailKit
import XCTest

final class MIMEParserTests: XCTestCase {
    func testMultipartMixedWithQuotedPrintableSplitUTF8AndRFC2231Attachment() {
        // Quoted-printable splits a 3-byte UTF-8 Chinese char across soft line break =\r\n
        // "报价单" in UTF-8 hex: E6 8A A5 E4 BB B7 E5 8D 95
        let eml = """
        Message-ID: <Quote-2026-001@Example.COM>
        From: =?UTF-8?B?5byg5LiJ?= <zhangsan@example.com>
        To: Sales <sales@example.com>
        Subject: =?UTF-8?Q?Re:_Project_Helios_=E6=8A=A5=E4=BB=B7=E5=8D=95?=
        Date: Thu, 19 Nov 2026 10:30:00 +0800
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="B1"

        --B1
        Content-Type: multipart/alternative; boundary="B2"

        --B2
        Content-Type: text/plain; charset="UTF-8"
        Content-Transfer-Encoding: quoted-printable

        Hi Team,
        Please find the latest =E6=8A=A5=E4=BB=B7=
        =E5=8D=95 below:
        Model EDS-4012 @ USD 485/unit.

        On Wed, Nov 18, 2026 at 09:00 AM, Alice <alice@example.com> wrote:
        > Please send updated pricing for EDS-4012.

        --B2
        Content-Type: text/html; charset="UTF-8"
        Content-Transfer-Encoding: 8bit

        <html><body><p>Hi Team</p></body></html>
        --B2--

        --B1
        Content-Type: application/pdf; name="Helios.pdf"
        Content-Disposition: attachment; filename*0*=UTF-8''%E6%8A%A5%E4%BB%B7; filename*1*=%E6%98%8E%E7%BB%86.pdf
        Content-Transfer-Encoding: base64

        JVBERi0xLjQK
        --B1--
        """
        let rawData = Data(eml.utf8)
        XCTAssertFalse(MIMEParser.isEncryptedEnvelope(rawData))

        let parsed = MIMEParser.parse(rawData: rawData)
        XCTAssertEqual(parsed.messageID, "Quote-2026-001@Example.COM")
        XCTAssertEqual(parsed.subject, "Re: Project Helios 报价单")
        XCTAssertTrue(parsed.from.contains("张三"))
        XCTAssertTrue(parsed.plainBody.contains("报价单"))
        XCTAssertTrue(parsed.plainBody.contains("USD 485/unit"))
        XCTAssertEqual(parsed.quotedChain.count, 1)
        XCTAssertTrue(parsed.quotedChain[0].content.contains("Please send updated pricing"))
        XCTAssertEqual(parsed.attachments.count, 1)
        XCTAssertEqual(parsed.attachments[0].filename, "报价明细.pdf")
        XCTAssertEqual(parsed.attachments[0].mimeType, "application/pdf")
        XCTAssertFalse(parsed.attachments[0].isInline)
    }

    func testGB18030CharsetAndChineseQuoteChain() {
        let gbEncoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let chineseBody = "您好，请确认型号 EDS-4012 的交期。\n\n------------------ 原始邮件 ------------------\n发件人: 李四 <lisi@example.com>\n发送时间: 2026年11月18日 15:00\n主题: 询价单\n\n请提供 100 台报价。"
        let bodyBytes = chineseBody.data(using: String.Encoding(rawValue: gbEncoding))!
        let b64 = bodyBytes.base64EncodedString()

        let eml = """
        Message-ID: <gb18030-test@example.com>
        Subject: GB18030 Test
        Content-Type: text/plain; charset="gb2312"
        Content-Transfer-Encoding: base64

        \(b64)
        """
        let parsed = MIMEParser.parse(rawData: Data(eml.utf8))
        XCTAssertTrue(parsed.plainBody.contains("EDS-4012"))
        XCTAssertEqual(parsed.quotedChain.count, 1)
        XCTAssertTrue(parsed.quotedChain[0].content.contains("100 台报价"))
    }

    func testHTMLTableExtractionOverStubPlainText() {
        let eml = """
        Message-ID: <html-table@example.com>
        Subject: Quote Table
        MIME-Version: 1.0
        Content-Type: multipart/alternative; boundary="ALT"

        --ALT
        Content-Type: text/plain; charset="UTF-8"

        See HTML
        --ALT
        Content-Type: text/html; charset="UTF-8"

        <html><head><style>table{border:1px}</style></head><body>
        <p>Updated pricing table:</p>
        <table>
          <tr><th>Model</th><th>Qty</th><th>Price</th></tr>
          <tr><td>EDS-4012</td><td>120</td><td>USD 485</td></tr>
        </table>
        </body></html>
        --ALT--
        """
        let parsed = MIMEParser.parse(rawData: Data(eml.utf8))
        XCTAssertTrue(parsed.plainBody.contains("EDS-4012 | 120 | USD 485"))
        XCTAssertFalse(parsed.plainBody.contains("border:1px"))
    }

    func testEncryptedEnvelopeDetectionAndPassthroughHandler() {
        let smime = """
        Message-ID: <smime@example.com>
        Content-Type: application/pkcs7-mime; smime-type=enveloped-data; name="smime.p7m"

        MIAGCSqGSIb3DQEHAqCAMIACAQExCzAJBgUrDgMCGgUAMIAGCSqGSIb3DQEHAaCAJIAEgg==
        """
        let smimeData = Data(smime.utf8)
        XCTAssertTrue(MIMEParser.isEncryptedEnvelope(smimeData))
        XCTAssertTrue(MIMEParser.isProtectedSecurityEnvelope(smimeData))
        XCTAssertNil(MessageSecurityHandler.shared.decodedMessage(forMessageData: smimeData))

        let signedMail = """
        Message-ID: <signed@example.com>
        Content-Type: multipart/signed; protocol="application/pkcs7-signature"; micalg=sha-256; boundary="SIG"

        --SIG
        Content-Type: text/plain; charset="UTF-8"

        Signed content
        --SIG--
        """
        let signedData = Data(signedMail.utf8)
        XCTAssertTrue(MIMEParser.isProtectedSecurityEnvelope(signedData))
        XCTAssertNil(MessageSecurityHandler.shared.decodedMessage(forMessageData: signedData))

        let normalEML = """
        Message-ID: <plain-pass@example.com>
        From: sender@example.com
        Subject: Normal Mail
        Content-Type: text/plain; charset="UTF-8"

        Hello, please review Project Apollo.
        """
        let normalData = Data(normalEML.utf8)
        let decoded = MessageSecurityHandler.shared.decodedMessage(forMessageData: normalData)
        XCTAssertNotNil(decoded)
        // rawData must pass original MIME bytes unchanged so Mail renders the full message body alongside the banner.
        XCTAssertEqual(decoded?.rawData, normalData)
        XCTAssertEqual(decoded?.securityInformation.isEncrypted, false)
        XCTAssertEqual(decoded?.banner?.primaryActionTitle, "AI 汇总分析")
        XCTAssertEqual(decoded?.banner?.isDismissable, true)
    }

    func testSecurityHandlerCachedHeadlineBannerRendering() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecurityHandlerBannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tempStore = AnalysisCacheStore(baseDirectory: tempDir)
        let handler = MessageSecurityHandler(cacheStore: tempStore)

        let eml = """
        Message-ID: <banner-headline-test@moxa.com>
        From: Alice <alice@moxa.com>
        Subject: CRH380D Test
        Content-Type: text/plain; charset="UTF-8"

        Please check TM-1520 delivery schedule.
        """
        let rawData = Data(eml.utf8)

        let longHeadline = "客户确认 CRH380D 娱乐系统改造项目 120 台 TM-1520-4GTX 订单并于本周五前完成正式报价审批确认"
        let analysis = EmailAIAnalysis(
            headline: longHeadline,
            coreConclusions: ["确认单价"],
            todos: [],
            businessElements: BusinessElements(),
            plainChineseTranslation: "请确认交期。",
            timeline: [],
            messageID: "banner-headline-test@moxa.com",
            modelUsed: GeminiModel.flash38.rawValue
        )
        try tempStore.save(analysis, forMessageID: "banner-headline-test@moxa.com")

        let decodedWithHeadline = handler.decodedMessage(forMessageData: rawData)
        XCTAssertEqual(decodedWithHeadline?.rawData, rawData)
        XCTAssertTrue(decodedWithHeadline?.banner?.title.hasPrefix("AI 已分析：") == true)
        XCTAssertTrue(decodedWithHeadline?.banner?.title.contains("…") == true)

        // Fresh store warms only key index on init, then resolves persisted headline from disk on demand and strips inline markers
        let warmedStore = AnalysisCacheStore(baseDirectory: tempDir)
        XCTAssertNil(warmedStore.cachedHeadlineInMemory(forMessageID: "banner-headline-test@moxa.com"))
        let warmedHandler = MessageSecurityHandler(cacheStore: warmedStore)
        let decodedWarmed = warmedHandler.decodedMessage(forMessageData: rawData)
        XCTAssertTrue(decodedWarmed?.banner?.title.hasPrefix("AI 已分析：") == true)
        XCTAssertTrue(decodedWarmed?.banner?.title.contains("…") == true)

        // Empty-headline cached entry falls back to "· 已缓存"
        let emptyHeadlineEML = Data("""
        Message-ID: <banner-empty-headline@moxa.com>
        From: Alice <alice@moxa.com>
        Subject: Empty headline cache test
        Content-Type: text/plain; charset="UTF-8"

        Body text.
        """.utf8)
        try tempStore.save(
            EmailAIAnalysis(
                headline: "   ",
                coreConclusions: ["结论"],
                todos: [],
                businessElements: BusinessElements(),
                plainChineseTranslation: "",
                timeline: [],
                messageID: "banner-empty-headline@moxa.com",
                modelUsed: GeminiModel.flash38.rawValue
            ),
            forMessageID: "banner-empty-headline@moxa.com"
        )
        let decodedEmpty = handler.decodedMessage(forMessageData: emptyHeadlineEML)
        XCTAssertEqual(decodedEmpty?.banner?.title, "AI 邮件助手 · 本地已提取正文 · 已缓存")

        // Marked headline is stripped cleanly in banner title
        let markedEML = Data("""
        Message-ID: <banner-marked-headline@moxa.com>
        From: Alice <alice@moxa.com>
        Subject: Marked headline test
        Content-Type: text/plain; charset="UTF-8"

        Body text.
        """.utf8)
        try tempStore.save(
            EmailAIAnalysis(
                headline: "==紧急==请审批 `EDS-4012` **特价**",
                coreConclusions: ["审批"],
                todos: [],
                businessElements: BusinessElements(),
                plainChineseTranslation: "",
                timeline: [],
                messageID: "banner-marked-headline@moxa.com",
                modelUsed: "group/smart-split"
            ),
            forMessageID: "banner-marked-headline@moxa.com"
        )
        let decodedMarked = handler.decodedMessage(forMessageData: markedEML)
        XCTAssertEqual(decodedMarked?.banner?.title, "AI 已分析：紧急请审批 EDS-4012 特价")
    }

    func testPartialEmlxAppleContentLengthAttachmentFallback() {
        let partialEml = Data("""
        Message-ID: <partial-att-test@moxa.com>
        Subject: Partial EMLX Test
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="PARTIALB"

        --PARTIALB
        Content-Type: text/plain; charset="UTF-8"

        Body present.
        --PARTIALB
        Content-Type: application/pdf; name="Quote.pdf"
        Content-Disposition: attachment; filename="Quote.pdf"
        X-Apple-Content-Length: 245760

        --PARTIALB--
        """.utf8)

        let parsed = MIMEParser.parse(rawData: partialEml)
        XCTAssertEqual(parsed.attachments.count, 1)
        XCTAssertEqual(parsed.attachments.first?.filename, "Quote.pdf")
        XCTAssertEqual(parsed.attachments.first?.approximateSizeBytes, 245760)
    }

    func testSecurityHandlerStoresRawDataOnlyForNonInlineAttachments() {
        RawEmailDataStore.shared.clearAll()

        let noAttachmentEML = Data("""
        Message-ID: <no-att-raw-store@example.com>
        Subject: Plain text only
        Content-Type: text/plain; charset="UTF-8"

        No attachments here.
        """.utf8)
        XCTAssertNotNil(MessageSecurityHandler.shared.decodedMessage(forMessageData: noAttachmentEML))
        XCTAssertNil(RawEmailDataStore.shared.lookup(messageID: "no-att-raw-store@example.com"))

        let withAttachmentEML = Data("""
        Message-ID: <with-att-raw-store@example.com>
        Subject: Attachment Mail
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="ATTB"

        --ATTB
        Content-Type: text/plain; charset="UTF-8"

        Please see attached spec.
        --ATTB
        Content-Type: application/pdf; name="spec.pdf"
        Content-Disposition: attachment; filename="spec.pdf"
        Content-Transfer-Encoding: base64

        JVBERi0xLjQK
        --ATTB--
        """.utf8)
        XCTAssertNotNil(MessageSecurityHandler.shared.decodedMessage(forMessageData: withAttachmentEML))
        XCTAssertEqual(RawEmailDataStore.shared.lookup(messageID: "with-att-raw-store@example.com"), withAttachmentEML)
        RawEmailDataStore.shared.clearAll()
    }
}
