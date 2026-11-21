import CryptoKit
import Foundation
import SQLite3
import XCTest

final class AttachmentOrganizerTests: XCTestCase {
    private var tempRoot: URL!
    private var workspaceURL: URL!
    private var defaultsSuiteName: String!
    private var testDefaults: UserDefaults!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachmentOrganizerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        tempRoot = base

        workspaceURL = base.appendingPathComponent("MockMoxaWorkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        defaultsSuiteName = "com.bao3.MailKBAI.Tests.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: defaultsSuiteName)!
    }

    override func tearDownWithError() throws {
        if let defaultsSuiteName {
            UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
        }
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    // MARK: - MIMEAttachmentExtractor Tests

    func testMIMEAttachmentExtractorBase64RFC2231ChineseFilenameAndInlineSkip() {
        let pdfBytes = Data("%PDF-1.4\nMoxa ENISA SRP Quote Payload\n".utf8)
        let pdfBase64 = pdfBytes.base64EncodedString()
        let expectedPDFSHA = MIMEAttachmentExtractor.sha256Hex(of: pdfBytes)

        let csvText = "Model,Qty,UnitPrice\r\nEDS-4012,120,485\r\n"
        let csvFilenameB64 = Data("型号清单.csv".utf8).base64EncodedString()
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01])
        let pngBase64 = pngBytes.base64EncodedString()
        let sigBytes = Data("PKCS7-DETACHED-SIG".utf8).base64EncodedString()

        // "报价明细_2026.pdf" split across RFC 2231 continuations right inside a UTF-8 char ("报" = E6 8A A5):
        let eml = """
        Message-ID: <att-extract-001@moxa.com>
        From: Sales <sales@example.com>
        Subject: Quote and Attachments
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="MIXED_B1"

        --MIXED_B1
        Content-Type: multipart/related; boundary="REL_B2"

        --REL_B2
        Content-Type: text/plain; charset="UTF-8"

        Please find the quotation attached.
        --REL_B2
        Content-Type: image/png; name="signature_logo.png"
        Content-Disposition: inline; filename="signature_logo.png"
        Content-ID: <sig-logo@example.com>
        Content-Transfer-Encoding: base64

        \(pngBase64)
        --REL_B2--

        --MIXED_B1
        Content-Type: application/pdf
        Content-Disposition: attachment;
         filename*0*=UTF-8''%E6%8A;
         filename*1*=%A5%E4%BB%B7%E6%98%8E%E7%BB%86_2026.pdf
        Content-Transfer-Encoding: base64

        \(pdfBase64)
        --MIXED_B1
        Content-Type: text/csv; charset="UTF-8"; name="=?UTF-8?B?\(csvFilenameB64)?="
        Content-Disposition: attachment; filename="=?UTF-8?B?\(csvFilenameB64)?="
        Content-Transfer-Encoding: 7bit

        \(csvText)
        --MIXED_B1
        Content-Type: application/pkcs7-signature; name="smime.p7s"
        Content-Transfer-Encoding: base64

        \(sigBytes)
        --MIXED_B1--
        """

        let rawData = Data(eml.utf8)

        // Default includeInline == false skips inline signature PNG and pkcs7-signature
        let regularOnly = MIMEAttachmentExtractor.extractAttachments(from: rawData)
        XCTAssertEqual(regularOnly.count, 2)
        XCTAssertEqual(regularOnly[0].filename, "报价明细_2026.pdf")
        XCTAssertEqual(regularOnly[0].mimeType, "application/pdf")
        XCTAssertEqual(regularOnly[0].data, pdfBytes)
        XCTAssertEqual(regularOnly[0].sha256Hex, expectedPDFSHA)
        XCTAssertFalse(regularOnly[0].isInline)

        XCTAssertEqual(regularOnly[1].filename, "型号清单.csv")
        XCTAssertEqual(regularOnly[1].mimeType, "text/csv")
        XCTAssertEqual(String(data: regularOnly[1].data, encoding: .utf8), csvText)
        XCTAssertFalse(regularOnly[1].isInline)

        // includeInline == true retains inline signature PNG and p7s with isInline == true
        let withInline = MIMEAttachmentExtractor.extractAttachments(from: rawData, includeInline: true)
        XCTAssertEqual(withInline.count, 4)
        XCTAssertTrue(withInline.contains { $0.filename == "signature_logo.png" && $0.isInline })
        XCTAssertTrue(withInline.contains { $0.filename == "smime.p7s" && $0.isInline })
    }

    func testMIMEAttachmentExtractorQuotedPrintableAndBinary() {
        let qpPayload = "Line1=3DValue=0D=0A=E4=B8=AD=\r\n=E6=96=87"
        let eml = """
        Message-ID: <qp-att@example.com>
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="QP_B"

        --QP_B
        Content-Type: text/plain; charset="UTF-8"

        Body text
        --QP_B
        Content-Type: text/plain; charset="UTF-8"; name="notes.txt"
        Content-Disposition: attachment; filename="notes.txt"
        Content-Transfer-Encoding: quoted-printable

        \(qpPayload)
        --QP_B--
        """

        let extracted = MIMEAttachmentExtractor.extractAttachments(from: Data(eml.utf8))
        XCTAssertEqual(extracted.count, 1)
        XCTAssertEqual(extracted[0].filename, "notes.txt")
        XCTAssertEqual(String(data: extracted[0].data, encoding: .utf8), "Line1=Value\r\n中文")

        // Single-parameter RFC 2231 + Apple Mail inline PDF (should NOT be hidden when includeInline == false)
        let binaryPDF = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x37, 0x00, 0xFF])
        let singleParamEML = Data("""
        Message-ID: <inline-pdf@example.com>
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="BIN_B"

        --BIN_B
        Content-Type: application/pdf; name*=UTF-8''%E6%B5%8B%E8%AF%95.pdf
        Content-Disposition: inline; filename*=UTF-8''%E6%B5%8B%E8%AF%95.pdf
        Content-Transfer-Encoding: binary

        """.utf8) + Data("\n".utf8) + binaryPDF + Data("\r\n--BIN_B--\r\n".utf8)

        let extractedPDF = MIMEAttachmentExtractor.extractAttachments(from: singleParamEML)
        XCTAssertEqual(extractedPDF.count, 1)
        XCTAssertEqual(extractedPDF[0].filename, "测试.pdf")
        XCTAssertEqual(extractedPDF[0].data, binaryPDF)
        XCTAssertFalse(extractedPDF[0].isInline)
    }

    // MARK: - RawEmailDataStore Tests

    func testRawEmailDataStoreLRUAndByteCap() {
        let store = RawEmailDataStore(maxEntries: 3, maxTotalBytes: 20)
        let d1 = Data(repeating: 0x01, count: 8)
        let d2 = Data(repeating: 0x02, count: 8)
        let d3 = Data(repeating: 0x03, count: 8) // triggers byte eviction of d1 (8+8+8 = 24 > 20)

        store.store(rawData: d1, forMessageID: "<MSG-1@Example.COM>")
        store.store(rawData: d2, forMessageID: "msg-2@example.com")
        XCTAssertEqual(store.currentEntryCount, 2)
        XCTAssertEqual(store.currentTotalBytes, 16)

        // Touch msg-1 so msg-2 becomes least-recently-used
        XCTAssertEqual(store.lookup(messageID: "msg-1@example.com"), d1)

        store.store(rawData: d3, forMessageID: "msg-3@example.com")
        XCTAssertEqual(store.currentEntryCount, 2)
        XCTAssertEqual(store.currentTotalBytes, 16)
        XCTAssertNotNil(store.lookup(messageID: "<msg-1@example.com>"))
        XCTAssertNil(store.lookup(messageID: "msg-2@example.com"))
        XCTAssertEqual(store.lookup(messageID: "msg-3@example.com"), d3)

        // Oversized single payload (> maxTotalBytes) should not evict existing valid items
        let oversized = Data(repeating: 0xFF, count: 32)
        store.store(rawData: oversized, forMessageID: "oversized@example.com")
        XCTAssertNil(store.lookup(messageID: "oversized@example.com"))
        XCTAssertEqual(store.currentEntryCount, 2)
    }

    // MARK: - WorkspaceBookmarkStore Tests

    @MainActor
    func testWorkspaceBookmarkStorePersistenceAndScopedAccess() throws {
        let store = WorkspaceBookmarkStore(userDefaults: testDefaults)
        XCTAssertNil(store.workspaceURL)
        XCTAssertNil(store.workspaceDisplayPath)
        XCTAssertThrowsError(try store.withScopedWorkspaceAccess { _ in () }) { error in
            XCTAssertEqual(error as? WorkspaceBookmarkError, .noWorkspaceSelected)
        }

        try store.saveWorkspaceURL(workspaceURL)
        XCTAssertEqual(store.workspaceURL?.standardizedFileURL, workspaceURL.standardizedFileURL)
        XCTAssertEqual(store.workspaceDisplayPath, workspaceURL.path)

        let probedPath = try store.withScopedWorkspaceAccess { url in
            url.standardizedFileURL.path
        }
        XCTAssertEqual(probedPath, workspaceURL.standardizedFileURL.path)

        // Rehydrate from persisted UserDefaults bookmark
        let reloadedStore = WorkspaceBookmarkStore(userDefaults: testDefaults)
        XCTAssertEqual(
            reloadedStore.workspaceURL?.resolvingSymlinksInPath().standardizedFileURL.path,
            workspaceURL.resolvingSymlinksInPath().standardizedFileURL.path
        )

        reloadedStore.clearWorkspace()
        XCTAssertNil(reloadedStore.workspaceURL)
        XCTAssertNil(reloadedStore.workspaceDisplayPath)
    }

    // MARK: - AttachmentOrganizerService Folder Matching & Execution Tests

    func testFolderMatchingWithMockSQLiteAndMoxaDirectories() async throws {
        // Build Moxa-style directory hierarchy inside temp workspace
        let dirs = [
            "2_项目/20250920_迪拜蓝线_CASCO",
            "2_项目/20231017-CRH1_TN-5305A交换机-四方AST",
            "1_客户资料/交控科技",
            "1_客户资料/中车浦镇",
            "8_特价邮件",
            "9_产品文件/信息安全相关文档(62443 CRA 63452)",
            ".moxa-kb" // Hidden folder MUST be ignored!
        ]
        for rel in dirs {
            try FileManager.default.createDirectory(
                at: workspaceURL.appendingPathComponent(rel, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        // Create mock runtime moxa_kb.sqlite in tempRoot (NOT inside workspace/.moxa-kb)
        let mockDBURL = tempRoot.appendingPathComponent("mock_moxa_kb.sqlite")
        try createMockMoxaKB(at: mockDBURL)

        let organizer = AttachmentOrganizerService.shared

        // Case 1: Security / ENISA / 62443 attachment -> 9_产品文件/信息安全相关文档(62443 CRA 63452)
        let securityPayload = ExtractedAttachmentPayload(
            filename: "Moxa_ENISA_SRP_v4_漏洞管理流程.pdf",
            mimeType: "application/pdf",
            data: Data("%PDF-1.4 ENISA SRP 62443".utf8),
            isInline: false
        )
        let securityEmail = ParsedEmailContext(
            messageID: "<sec-001@moxa.com>",
            subject: "Re: IEC 62443 & ENISA 漏洞管理流程正式文档",
            from: "Customer <sec@client.com>",
            to: ["alex.chen@acme.example"],
            cc: [],
            dateString: "Fri, 20 Nov 2026 10:00:00 +0800",
            inReplyTo: nil,
            references: [],
            plainBody: "请补充符合 IEC 62443 与 CRA 要求的正式漏洞管理 PDF。",
            quotedChain: [],
            attachments: []
        )
        let securityAnalysis = EmailAIAnalysis(
            headline: "客户要求补充 ENISA / IEC 62443 漏洞管理流程 PDF",
            coreConclusions: ["提供正式 PDF"],
            todos: [],
            businessElements: BusinessElements(projects: [], customers: [], models: []),
            plainChineseTranslation: "",
            timeline: [],
            suggestedFlag: "blue"
        )

        let secPlan = await organizer.proposeFilingPlan(
            payloads: [securityPayload],
            email: securityEmail,
            analysis: securityAnalysis,
            workspaceRootURL: workspaceURL,
            runtimeWorkspaceDBPath: mockDBURL.path
        )
        XCTAssertEqual(secPlan.count, 1)
        XCTAssertEqual(secPlan[0].proposedRelativeFolder, "9_产品文件/信息安全相关文档(62443 CRA 63452)")
        XCTAssertFalse(secPlan[0].candidateFolders.contains(where: { $0.contains(".moxa-kb") }))

        // Case 2: Project + Customer email -> 2_项目/20250920_迪拜蓝线_CASCO
        let projectPayload = ExtractedAttachmentPayload(
            filename: "迪拜蓝线_DCS交换机配置清单.xlsx",
            mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            data: Data("PK\u{03}\u{04}DubaiBlueLine".utf8),
            isInline: false
        )
        let projectEmail = ParsedEmailContext(
            messageID: "<dubai-001@moxa.com>",
            subject: "迪拜蓝线 CASCO DCS Switch 报价确认",
            from: "CASCO <pm@casco.com>",
            to: ["alex.chen@acme.example"],
            cc: [],
            dateString: "Fri, 20 Nov 2026 11:00:00 +0800",
            inReplyTo: nil,
            references: [],
            plainBody: "请核对迪拜蓝线项目交换机配置与单价。",
            quotedChain: [],
            attachments: []
        )
        let projectAnalysis = EmailAIAnalysis(
            headline: "迪拜蓝线 CASCO 核对交换机报价",
            coreConclusions: ["确认配置"],
            todos: [],
            businessElements: BusinessElements(
                projects: ["迪拜蓝线"],
                customers: ["CASCO"],
                models: ["TN-4908"]
            ),
            plainChineseTranslation: "",
            timeline: [],
            suggestedFlag: "yellow"
        )

        let projPlan = await organizer.proposeFilingPlan(
            payloads: [projectPayload],
            email: projectEmail,
            analysis: projectAnalysis,
            workspaceRootURL: workspaceURL,
            runtimeWorkspaceDBPath: mockDBURL.path
        )
        XCTAssertEqual(projPlan.count, 1)
        XCTAssertEqual(projPlan[0].proposedRelativeFolder, "2_项目/20250920_迪拜蓝线_CASCO")

        // Case 3: Yellow pricing email with no specific project subfolder -> 8_特价邮件 or 2_项目
        let sprPayload = ExtractedAttachmentPayload(
            filename: "EDS-4012_特价申请报价单.pdf",
            mimeType: "application/pdf",
            data: Data("%PDF-1.4 SPR Quote".utf8),
            isInline: false
        )
        let sprEmail = ParsedEmailContext(
            messageID: "<spr-001@moxa.com>",
            subject: "特价报价单 EDS-4012",
            from: "Sales <sales@moxa.com>",
            to: ["alex.chen@acme.example"],
            cc: [],
            dateString: "Fri, 20 Nov 2026 12:00:00 +0800",
            inReplyTo: nil,
            references: [],
            plainBody: "申请 EDS-4012 批量特价。",
            quotedChain: [],
            attachments: []
        )
        let sprAnalysis = EmailAIAnalysis(
            headline: "EDS-4012 特价申请",
            coreConclusions: ["含税单价待批"],
            todos: [],
            businessElements: BusinessElements(
                projects: [],
                customers: [],
                models: ["EDS-4012"],
                pricing: [PricingElement(itemOrModel: "EDS-4012", unitPrice: "485", currency: "USD")]
            ),
            plainChineseTranslation: "",
            timeline: [],
            suggestedFlag: "yellow"
        )

        let sprPlan = await organizer.proposeFilingPlan(
            payloads: [sprPayload],
            email: sprEmail,
            analysis: sprAnalysis,
            workspaceRootURL: workspaceURL,
            runtimeWorkspaceDBPath: mockDBURL.path
        )
        XCTAssertEqual(sprPlan.count, 1)
        XCTAssertTrue(
            sprPlan[0].proposedRelativeFolder == "8_特价邮件"
                || sprPlan[0].proposedRelativeFolder == "2_项目"
        )
    }

    func testAIRouterTimeoutFallsBackToDeterministicPlan() async throws {
        try FileManager.default.createDirectory(
            at: workspaceURL.appendingPathComponent("1_客户资料/交控科技", isDirectory: true),
            withIntermediateDirectories: true
        )
        let payload = ExtractedAttachmentPayload(
            filename: "交控科技_产品规格书.pdf",
            mimeType: "application/pdf",
            data: Data("%PDF-1.4 TCT".utf8),
            isInline: false
        )
        let email = ParsedEmailContext(
            messageID: "<tct-timeout@moxa.com>",
            subject: "交控科技产品资料",
            from: "tct@example.com",
            to: [],
            cc: [],
            dateString: "",
            inReplyTo: nil,
            references: [],
            plainBody: "请查阅交控科技资料。",
            quotedChain: [],
            attachments: []
        )
        let analysis = EmailAIAnalysis(
            headline: "交控科技资料",
            coreConclusions: [],
            todos: [],
            businessElements: BusinessElements(customers: ["交控科技"]),
            plainChineseTranslation: "",
            timeline: []
        )

        let fastTimeoutOrganizer = AttachmentOrganizerService(aiTimeoutSeconds: 0.15)
        let plan = await fastTimeoutOrganizer.proposeFilingPlan(
            payloads: [payload],
            email: email,
            analysis: analysis,
            workspaceRootURL: workspaceURL,
            aiRouter: { _, _ in
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return "{\"items\":[]}"
            }
        )
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].proposedRelativeFolder, "1_客户资料/交控科技")
    }

    func testOpenSourceModeWithoutSQLiteAndAIRouterValidation() async throws {
        try FileManager.default.createDirectory(
            at: workspaceURL.appendingPathComponent("Projects/Helios", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: workspaceURL.appendingPathComponent("Clients/Acme", isDirectory: true),
            withIntermediateDirectories: true
        )

        let payload = ExtractedAttachmentPayload(
            filename: "Helios_BOM.xlsx",
            mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            data: Data("BOM".utf8),
            isInline: false
        )
        let email = ParsedEmailContext(
            messageID: "<oss-mode@example.com>",
            subject: "Helios BOM update",
            from: "pm@acme.com",
            to: [],
            cc: [],
            dateString: "",
            inReplyTo: nil,
            references: [],
            plainBody: "Updated BOM for Helios.",
            quotedChain: [],
            attachments: []
        )
        let analysis = EmailAIAnalysis(
            headline: "Helios BOM",
            coreConclusions: [],
            todos: [],
            businessElements: BusinessElements(projects: ["Helios"], customers: ["Acme"]),
            plainChineseTranslation: "",
            timeline: []
        )

        // 1. No SQLite (non-existent path) + unsafe AI hallucination -> rejected, keeps deterministic Projects/Helios
        let missingDBPath = tempRoot.appendingPathComponent("nonexistent.sqlite").path
        let safePlan = await AttachmentOrganizerService.shared.proposeFilingPlan(
            payloads: [payload],
            email: email,
            analysis: analysis,
            workspaceRootURL: workspaceURL,
            runtimeWorkspaceDBPath: missingDBPath,
            aiRouter: { _, _ in
                #"{"items":[{"payloadID":"\#(payload.id)","folder":"../outside","reason":"bad","confidence":"high"}]}"#
            }
        )
        XCTAssertEqual(safePlan.count, 1)
        XCTAssertEqual(safePlan[0].proposedRelativeFolder, "Projects/Helios")

        // 2. Valid AI refinement picking from candidateFolders overrides cleanly
        let aiRefinedPlan = await AttachmentOrganizerService.shared.proposeFilingPlan(
            payloads: [payload],
            email: email,
            analysis: analysis,
            workspaceRootURL: workspaceURL,
            runtimeWorkspaceDBPath: missingDBPath,
            aiRouter: { _, _ in
                """
                ```json
                {"items":[{"payloadID":"\(payload.id)","folder":"Clients/Acme","reason":"客户主档优先","confidence":"high"}]}
                ```
                """
            }
        )
        XCTAssertEqual(aiRefinedPlan.count, 1)
        XCTAssertEqual(aiRefinedPlan[0].proposedRelativeFolder, "Clients/Acme")
        XCTAssertEqual(aiRefinedPlan[0].reason, "客户主档优先")
        XCTAssertEqual(aiRefinedPlan[0].confidence, "high")

        // 3. Passing cold .moxa-kb, .mailkb, or .mailkb_db DB path must be blocked safely without crashing or reading cold dir
        for hiddenFolder in [".moxa-kb", ".mailkb", ".mailkb_db"] {
            let coldDBDir = workspaceURL.appendingPathComponent(hiddenFolder, isDirectory: true)
            try FileManager.default.createDirectory(at: coldDBDir, withIntermediateDirectories: true)
            let coldFilename: String
            switch hiddenFolder {
            case ".mailkb_db": coldFilename = "mailkb_db.sqlite"
            case ".mailkb": coldFilename = "mailkb.sqlite"
            default: coldFilename = "moxa_kb.sqlite"
            }
            let coldDB = coldDBDir.appendingPathComponent(coldFilename)
            try createMockMoxaKB(at: coldDB)

            let blockedColdPlan = await AttachmentOrganizerService.shared.proposeFilingPlan(
                payloads: [payload],
                email: email,
                analysis: analysis,
                workspaceRootURL: workspaceURL,
                runtimeWorkspaceDBPath: coldDB.path
            )
            XCTAssertEqual(blockedColdPlan.count, 1)
            XCTAssertFalse(blockedColdPlan[0].candidateFolders.contains(where: { $0.contains(hiddenFolder) }))
            XCTAssertFalse(blockedColdPlan[0].candidateFolders.contains(where: { $0.contains("信息安全") }))
        }
    }

    func testSHA256IdenticalSkipAndCollisionAutoRename() throws {
        let targetDirRel = "2_项目/Helios"
        let targetDirURL = workspaceURL.appendingPathComponent(targetDirRel, isDirectory: true)
        try FileManager.default.createDirectory(at: targetDirURL, withIntermediateDirectories: true)

        let existingContentV1 = Data("%PDF-1.4 Version 1 Original".utf8)
        let existingFileURL = targetDirURL.appendingPathComponent("Helios_Quote.pdf")
        try existingContentV1.write(to: existingFileURL)

        let organizer = AttachmentOrganizerService.shared

        // 1. Identical SHA-256 -> .identicalAlreadyExists & skips write while returning existing URL
        let identicalPayload = ExtractedAttachmentPayload(
            filename: "Helios_Quote.pdf",
            mimeType: "application/pdf",
            data: existingContentV1,
            isInline: false
        )
        var identicalItem = AttachmentFilingPlanItem(
            payloadID: identicalPayload.id,
            originalFilename: identicalPayload.filename,
            proposedRelativeFolder: targetDirRel,
            proposedFilename: "Helios_Quote.pdf"
        )
        identicalItem = organizer.refreshConflictStatus(
            for: identicalItem,
            payload: identicalPayload,
            workspaceRootURL: workspaceURL
        )
        if case let .identicalAlreadyExists(foundURL) = identicalItem.conflict {
            XCTAssertEqual(
                foundURL.resolvingSymlinksInPath().standardizedFileURL.path,
                existingFileURL.resolvingSymlinksInPath().standardizedFileURL.path
            )
        } else {
            XCTFail("Expected .identicalAlreadyExists, got \(identicalItem.conflict)")
        }

        let identicalWritten = try organizer.executeFilingPlan(
            items: [identicalItem],
            payloads: [identicalPayload],
            workspaceRootURL: workspaceURL
        )
        XCTAssertEqual(identicalWritten.count, 1)
        XCTAssertEqual(
            identicalWritten[0].resolvingSymlinksInPath().standardizedFileURL.path,
            existingFileURL.resolvingSymlinksInPath().standardizedFileURL.path
        )
        XCTAssertEqual(try Data(contentsOf: existingFileURL), existingContentV1)

        // 2. Different SHA-256 -> .renamedToAvoidOverwrite & writes collision-safe file without touching original
        let modifiedContentV2 = Data("%PDF-1.4 Version 2 Updated".utf8)
        let modifiedPayload = ExtractedAttachmentPayload(
            filename: "Helios_Quote.pdf",
            mimeType: "application/pdf",
            data: modifiedContentV2,
            isInline: false
        )
        var renameItem = AttachmentFilingPlanItem(
            payloadID: modifiedPayload.id,
            originalFilename: modifiedPayload.filename,
            proposedRelativeFolder: targetDirRel,
            proposedFilename: "Helios_Quote.pdf"
        )
        renameItem = organizer.refreshConflictStatus(
            for: renameItem,
            payload: modifiedPayload,
            workspaceRootURL: workspaceURL
        )
        guard case let .renamedToAvoidOverwrite(suggested1) = renameItem.conflict else {
            XCTFail("Expected .renamedToAvoidOverwrite, got \(renameItem.conflict)")
            return
        }
        XCTAssertNotEqual(suggested1, "Helios_Quote.pdf")
        XCTAssertTrue(suggested1.hasPrefix("Helios_Quote_"))
        XCTAssertTrue(suggested1.hasSuffix(".pdf"))

        let renamedURLs1 = try organizer.executeFilingPlan(
            items: [renameItem],
            payloads: [modifiedPayload],
            workspaceRootURL: workspaceURL
        )
        XCTAssertEqual(renamedURLs1.count, 1)
        XCTAssertEqual(renamedURLs1[0].lastPathComponent, suggested1)
        XCTAssertEqual(try Data(contentsOf: renamedURLs1[0]), modifiedContentV2)
        // Original file MUST remain completely untouched!
        XCTAssertEqual(try Data(contentsOf: existingFileURL), existingContentV1)

        // 3. Third distinct version on same day -> auto-increments _2 without overwriting V1 or V2
        let modifiedContentV3 = Data("%PDF-1.4 Version 3 Final".utf8)
        let payloadV3 = ExtractedAttachmentPayload(
            filename: "Helios_Quote.pdf",
            mimeType: "application/pdf",
            data: modifiedContentV3,
            isInline: false
        )
        var renameItemV3 = AttachmentFilingPlanItem(
            payloadID: payloadV3.id,
            originalFilename: payloadV3.filename,
            proposedRelativeFolder: targetDirRel,
            proposedFilename: "Helios_Quote.pdf"
        )
        renameItemV3 = organizer.refreshConflictStatus(
            for: renameItemV3,
            payload: payloadV3,
            workspaceRootURL: workspaceURL
        )
        guard case let .renamedToAvoidOverwrite(suggested2) = renameItemV3.conflict else {
            XCTFail("Expected .renamedToAvoidOverwrite for v3, got \(renameItemV3.conflict)")
            return
        }
        XCTAssertTrue(suggested2.hasSuffix("_2.pdf"))
        let renamedURLs2 = try organizer.executeFilingPlan(
            items: [renameItemV3],
            payloads: [payloadV3],
            workspaceRootURL: workspaceURL
        )
        XCTAssertEqual(try Data(contentsOf: renamedURLs2[0]), modifiedContentV3)
        XCTAssertEqual(try Data(contentsOf: renamedURLs1[0]), modifiedContentV2)
        XCTAssertEqual(try Data(contentsOf: existingFileURL), existingContentV1)
    }

    func testPathTraversalHiddenDirectoryAndSymlinkEscapeRejection() throws {
        let organizer = AttachmentOrganizerService.shared
        let payload = ExtractedAttachmentPayload(
            filename: "secret.pdf",
            mimeType: "application/pdf",
            data: Data("Payload".utf8),
            isInline: false
        )

        let badFolders = [
            "../outside",
            "2_项目/../../outside",
            "/tmp/absolute",
            ".mailkb_db",
            "2_项目/.mailkb_db",
            ".mailkb",
            "2_项目/.mailkb",
            ".moxa-kb",
            "2_项目/.moxa-kb",
            ".git/hooks",
            "~/Documents"
        ]

        for badFolder in badFolders {
            let badItem = AttachmentFilingPlanItem(
                payloadID: payload.id,
                originalFilename: payload.filename,
                proposedRelativeFolder: badFolder,
                proposedFilename: "secret.pdf"
            )
            XCTAssertThrowsError(
                try organizer.executeFilingPlan(
                    items: [badItem],
                    payloads: [payload],
                    workspaceRootURL: workspaceURL
                ),
                "Expected unsafe folder rejection for \(badFolder)"
            )
        }

        let badFilenames = [
            "../escape.pdf",
            "sub/file.pdf",
            ".hidden.pdf",
            ".mailkb_db",
            ".mailkb",
            ".moxa-kb"
        ]
        for badFilename in badFilenames {
            let badItem = AttachmentFilingPlanItem(
                payloadID: payload.id,
                originalFilename: payload.filename,
                proposedRelativeFolder: "2_项目",
                proposedFilename: badFilename
            )
            XCTAssertThrowsError(
                try organizer.executeFilingPlan(
                    items: [badItem],
                    payloads: [payload],
                    workspaceRootURL: workspaceURL
                ),
                "Expected unsafe filename rejection for \(badFilename)"
            )
        }

        // Symlink escape test: workspace/escape_dir -> tempRoot/outside_target
        let outsideTarget = tempRoot.appendingPathComponent("outside_target", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideTarget, withIntermediateDirectories: true)
        let escapeSymlink = workspaceURL.appendingPathComponent("escape_dir", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: escapeSymlink, withDestinationURL: outsideTarget)

        let symlinkItem = AttachmentFilingPlanItem(
            payloadID: payload.id,
            originalFilename: payload.filename,
            proposedRelativeFolder: "escape_dir",
            proposedFilename: "escaped.pdf"
        )
        XCTAssertThrowsError(
            try organizer.executeFilingPlan(
                items: [symlinkItem],
                payloads: [payload],
                workspaceRootURL: workspaceURL
            )
        ) { error in
            guard case .symlinkEscapeDetected = error as? AttachmentOrganizerError else {
                XCTFail("Expected symlinkEscapeDetected, got \(error)")
                return
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outsideTarget.appendingPathComponent("escaped.pdf").path
            )
        )
    }

    // MARK: - Helpers

    private func createMockMoxaKB(at dbURL: URL) throws {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(
            dbURL.path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        )
        guard rc == SQLITE_OK, let db else {
            throw NSError(domain: "MockSQLite", code: Int(rc))
        }
        defer { sqlite3_close(db) }

        let schemaSQL = """
        CREATE TABLE files (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            relpath TEXT NOT NULL UNIQUE,
            abs_path TEXT NOT NULL,
            filename TEXT NOT NULL,
            top_dir TEXT NOT NULL,
            ext TEXT NOT NULL,
            size_bytes INTEGER NOT NULL,
            mtime INTEGER NOT NULL,
            mtime_iso TEXT NOT NULL,
            product_family TEXT NOT NULL,
            sku_guess TEXT NOT NULL,
            doc_level INTEGER NOT NULL,
            doc_type TEXT NOT NULL,
            subsystems TEXT NOT NULL,
            standards TEXT NOT NULL,
            project_name TEXT NOT NULL,
            is_obsolete INTEGER NOT NULL DEFAULT 0,
            summary TEXT NOT NULL,
            tags TEXT NOT NULL
        );
        INSERT INTO files (relpath, abs_path, filename, top_dir, ext, size_bytes, mtime, mtime_iso, product_family, sku_guess, doc_level, doc_type, subsystems, standards, project_name, is_obsolete, summary, tags)
        VALUES
        ('9_产品文件/信息安全相关文档(62443 CRA 63452)/Moxa_ENISA_SRP_v3_简体.pdf', '/tmp/a', 'Moxa_ENISA_SRP_v3_简体.pdf', '9_产品文件', '.pdf', 1024, 1700000000, '2026-11-01', 'Cybersecurity', '', 2, 'Compliance', '', 'IEC 62443,ENISA,CRA', '', 0, 'ENISA SRP', 'cybersecurity'),
        ('2_项目/20250920_迪拜蓝线_CASCO/DCS Switch/spec.pdf', '/tmp/b', 'spec.pdf', '2_项目', '.pdf', 2048, 1700000000, '2026-11-01', 'TN-4908', 'TN-4908', 3, 'Spec', 'DCS', 'IEC 62443,EN 50155', '迪拜蓝线', 0, 'Dubai Blue Line', 'project'),
        ('1_客户资料/交控科技/MPC_datasheet.pdf', '/tmp/c', 'MPC_datasheet.pdf', '1_客户资料', '.pdf', 512, 1700000000, '2026-11-01', 'MPC-2121', 'MPC-2121', 2, 'Datasheet', '', 'EN 50155', '客户:交控科技', 0, 'TCT', 'customer');
        """

        var errMsg: UnsafeMutablePointer<CChar>?
        let execRC = sqlite3_exec(db, schemaSQL, nil, nil, &errMsg)
        if execRC != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown sqlite error"
            sqlite3_free(errMsg)
            throw NSError(domain: "MockSQLite", code: Int(execRC), userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }
}
