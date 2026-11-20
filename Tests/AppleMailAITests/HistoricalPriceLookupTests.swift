import Foundation
import SQLite3
import XCTest

final class HistoricalPriceLookupTests: XCTestCase {
    private var tempDir: URL!
    private var stagingDir: URL!
    private var dbURL: URL!
    private var service: HistoricalPriceLookupService!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoricalPriceLookupTests-\(UUID().uuidString)", isDirectory: true)
        stagingDir = tempDir.appendingPathComponent("runtime-staging", isDirectory: true)
        dbURL = tempDir.appendingPathComponent("outlook-test.sqlite", isDirectory: false)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        service = HistoricalPriceLookupService(stagingDirectoryURL: stagingDir)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Pricing Intent Detection

    func testContainsPricingIntentKeywordsAndAnalysisSignals() {
        let cnQuoteEmail = makeEmail(
            subject: "请核价：轨交车载交换机",
            plainBody: "请尽快提供 TN-4908-4GTX-WV-CT-T 未税单价及阶梯价，谢谢。"
        )
        XCTAssertTrue(HistoricalPriceLookupService.containsPricingIntent(email: cnQuoteEmail))

        let enQuoteEmail = makeEmail(
            subject: "RFQ for railway project",
            plainBody: "Please share FOB Taipei quotation, MOQ 20 pcs, and SPR discount."
        )
        XCTAssertTrue(HistoricalPriceLookupService.containsPricingIntent(email: enQuoteEmail))

        // Word-boundary check: "specification" contains "cif" and "spring" contains "spr",
        // so purely technical correspondence must NOT trigger pricing lookup.
        let technicalOnlyEmail = makeEmail(
            subject: "EN 50155 specification update",
            plainBody: "Please review the attached technical specification before the spring release."
        )
        XCTAssertFalse(HistoricalPriceLookupService.containsPricingIntent(email: technicalOnlyEmail))

        let yellowAnalysis = makeAnalysis(flag: "yellow")
        XCTAssertTrue(HistoricalPriceLookupService.containsPricingIntent(email: technicalOnlyEmail, analysis: yellowAnalysis))

        let orangeAnalysis = makeAnalysis(flag: "orange")
        XCTAssertTrue(HistoricalPriceLookupService.containsPricingIntent(email: technicalOnlyEmail, analysis: orangeAnalysis))

        let blueAnalysis = makeAnalysis(flag: "blue")
        XCTAssertFalse(HistoricalPriceLookupService.containsPricingIntent(email: technicalOnlyEmail, analysis: blueAnalysis))

        let pricingElementAnalysis = makeAnalysis(
            flag: "green",
            pricing: [PricingElement(itemOrModel: "TN-4908-4GTX-WV-CT-T", quantity: "10", unitPrice: "6500", currency: "RMB")]
        )
        XCTAssertTrue(HistoricalPriceLookupService.containsPricingIntent(email: technicalOnlyEmail, analysis: pricingElementAnalysis))
    }

    // MARK: - SKU Extraction

    func testExtractCandidateSKUsAcrossMoxaFormatsAndDeduplication() {
        let email = makeEmail(
            subject: "Re: TN-4908-4GTX-WV-CT-T & EDS-4012-8GT4XS-HV-T 报价申请",
            plainBody: """
            请核对以下型号（参考标准 EN-50155, IEC-62443-4-2, RFC-5322, 2026-11-20, PO-2026-001）：
            1. V1222-CT-T 20台
            2. TAP-M310R 和 DA-682B-FEP
            3. SFP-1GLXLC-T
            4. NPort 5610-8-DT-J 与 ioLogik R1241
            5. 重复型号 tn-4908-4gtx-wv-ct-t 与 A-PLG-WPM23-01-IP67
            6. 额外超限型号 EDS-528E-4GTXSFP-HV-T
            """,
            quotedChain: [
                QuotedMessageBlock(index: 1, attribution: "Alex", content: "早期提到过 IKS-G6524A-8GSFP-4GTXSFP-HV-HV-T")
            ]
        )

        let analysis = makeAnalysis(
            models: ["TN-4908-4GTX-WV-CT-T", "EN 50155"]
        )

        let skus = HistoricalPriceLookupService.extractCandidateSKUs(from: email, analysis: analysis)

        XCTAssertLessThanOrEqual(skus.count, 8)
        XCTAssertEqual(skus.count, 8)
        XCTAssertEqual(skus[0], "TN-4908-4GTX-WV-CT-T")
        XCTAssertTrue(skus.contains("EDS-4012-8GT4XS-HV-T"))
        XCTAssertTrue(skus.contains("V1222-CT-T"))
        XCTAssertTrue(skus.contains("TAP-M310R"))
        XCTAssertTrue(skus.contains("DA-682B-FEP"))
        XCTAssertTrue(skus.contains("SFP-1GLXLC-T"))
        XCTAssertTrue(skus.contains("NPort 5610-8-DT-J"))
        XCTAssertTrue(skus.contains("ioLogik R1241"))

        XCTAssertFalse(skus.contains(where: { $0.hasPrefix("EN") || $0.hasPrefix("IEC") || $0.hasPrefix("RFC") || $0.hasPrefix("PO-") }))
        // Case-insensitive deduplication
        XCTAssertEqual(skus.filter { $0.uppercased() == "TN-4908-4GTX-WV-CT-T" }.count, 1)
    }

    // MARK: - SQLite Query, Series Fallback, Self Exclusion, Jump URL

    func testLookupExactAndSeriesFallbackWithSelfExclusionAndDeduplication() async throws {
        try buildMockOutlookDatabase(at: dbURL) { db in
            // 1. Self message (must be excluded even though SKU matches)
            let selfMsgID = try insertMessage(
                db: db,
                messageID: "<current-mail-001@moxa.com>",
                subject: "Current Quote Inquiry TN-4908-4GTX-WV-CT-T",
                dateISO: "2026-11-20",
                projectName: "CurrentProj",
                customerOrg: "CurrentCustomer"
            )
            try insertPrice(
                db: db,
                messageRowID: selfMsgID,
                sku: "TN-4908-4GTX-WV-CT-T",
                currency: "RMB",
                unitPrice: 9999.0,
                quantity: 5,
                priceType: "quote",
                taxMode: "未税",
                customerOrg: "CurrentCustomer",
                projectName: "CurrentProj",
                quoteDateISO: "2026-11-20",
                evidenceSnippet: "Should never appear as self message",
                confidence: "high"
            )

            // 2. One exact SKU hit + one exact duplicate row (must deduplicate) + one invalid zero-price row
            let exactMsgID = try insertMessage(
                db: db,
                messageID: "exact-hit-100@moxa.com",
                subject: "RE: 宁波地铁3号线 TN-4908 订单核价",
                dateISO: "2026-10-15",
                projectName: "宁波地铁3号线",
                customerOrg: "中国通号"
            )
            try insertPrice(
                db: db,
                messageRowID: exactMsgID,
                sku: "TN-4908-4GTX-WV-CT-T",
                currency: "RMB",
                unitPrice: 6850.0,
                quantity: 40,
                priceType: "order_price",
                taxMode: "未税",
                customerOrg: "中国通号",
                projectName: "宁波地铁3号线",
                quoteDateISO: "2026-10-15",
                evidenceSnippet: "TN-4908-4GTX-WV-CT-T 未税单价 6850 RMB，数量 40 台",
                confidence: "high"
            )
            // Duplicate tuple (same sku, unit_price, currency, customer_org, project_name, quote_date_iso)
            try insertPrice(
                db: db,
                messageRowID: exactMsgID,
                sku: "TN-4908-4GTX-WV-CT-T",
                currency: "RMB",
                unitPrice: 6850.0,
                quantity: 40,
                priceType: "quote",
                taxMode: "未税",
                customerOrg: "中国通号",
                projectName: "宁波地铁3号线",
                quoteDateISO: "2026-10-15",
                evidenceSnippet: "Duplicate entry",
                confidence: "medium"
            )
            // Zero price must be ignored
            try insertPrice(
                db: db,
                messageRowID: exactMsgID,
                sku: "TN-4908-4GTX-WV-CT-T",
                currency: "RMB",
                unitPrice: 0.0,
                quantity: 1,
                priceType: "quote",
                taxMode: "未税",
                customerOrg: "中国通号",
                projectName: "宁波地铁3号线",
                quoteDateISO: "2026-10-14",
                evidenceSnippet: "Zero price row",
                confidence: "low"
            )

            // 3. Six series-level TN-4908-8GTX-WV-CT-T rows (because exact hits = 1 < 3, supplement up to 5)
            for idx in 1...6 {
                let seriesMsgID = try insertMessage(
                    db: db,
                    messageID: "series-hit-\(idx)@moxa.com",
                    subject: "TN-4908-8GTX-WV-CT-T 特价审批 #\(idx)",
                    dateISO: "2026-09-0\(idx)",
                    projectName: "成都地铁\(idx)号线",
                    customerOrg: "铁建重工"
                )
                try insertPrice(
                    db: db,
                    messageRowID: seriesMsgID,
                    sku: "TN-4908-8GTX-WV-CT-T",
                    currency: "RMB",
                    unitPrice: 7100.0 + Double(idx * 100),
                    quantity: 20,
                    priceType: idx % 2 == 0 ? "spr_support" : "spr_request",
                    taxMode: "含税",
                    customerOrg: "铁建重工",
                    projectName: "成都地铁\(idx)号线",
                    quoteDateISO: "2026-09-0\(idx)",
                    evidenceSnippet: "TN-4908-8GTX-WV-CT-T 报价 \(7100 + idx * 100)",
                    confidence: "high"
                )
            }
        }

        let email = makeEmail(
            messageID: "current-mail-001@moxa.com",
            subject: "核价：TN-4908-4GTX-WV-CT-T",
            plainBody: "请查询 TN-4908-4GTX-WV-CT-T 历史报价与未税单价。"
        )
        let analysis = makeAnalysis(
            flag: "yellow",
            models: ["TN-4908-4GTX-WV-CT-T"],
            pricing: [
                PricingElement(
                    itemOrModel: "TN-4908-4GTX-WV-CT-T",
                    quantity: "30",
                    unitPrice: "6950",
                    currency: "RMB",
                    termsOrLeadTime: "未税"
                )
            ]
        )

        let groups = await service.lookupRelatedPrices(
            for: email,
            analysis: analysis,
            runtimeDBPath: dbURL.path
        )

        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.queriedSKU, "TN-4908-4GTX-WV-CT-T")
        XCTAssertEqual(group.currentEmailPriceHint, "RMB 6950 (x30 · 未税)")
        XCTAssertEqual(group.primaryCurrency, "RMB")

        // 1 exact hit + up to 5 series hits = 6 total
        XCTAssertEqual(group.records.count, 6)

        let exactRecords = group.records.filter(\.isExactSKUMatch)
        let seriesRecords = group.records.filter { !$0.isExactSKUMatch }
        XCTAssertEqual(exactRecords.count, 1)
        XCTAssertEqual(seriesRecords.count, 5)

        let exact = try XCTUnwrap(exactRecords.first)
        XCTAssertEqual(exact.sku, "TN-4908-4GTX-WV-CT-T")
        XCTAssertEqual(exact.unitPrice, 6850.0, accuracy: 0.001)
        XCTAssertEqual(exact.quantity, 40.0)
        XCTAssertEqual(exact.priceType, "order_price")
        XCTAssertEqual(exact.priceTypeLabel, "订单价")
        XCTAssertEqual(exact.taxMode, "未税")
        XCTAssertEqual(exact.customerOrg, "中国通号")
        XCTAssertEqual(exact.projectName, "宁波地铁3号线")
        XCTAssertEqual(exact.quoteDateISO, "2026-10-15")
        XCTAssertEqual(exact.rfcMessageID, "exact-hit-100@moxa.com")
        XCTAssertEqual(exact.mailJumpURL, URL(string: "message://%3Cexact-hit-100@moxa.com%3E"))

        // Self message excluded
        XCTAssertFalse(group.records.contains(where: { $0.rfcMessageID == "current-mail-001@moxa.com" }))

        // Series records ordered descending by quote_date_iso (2026-09-06 down to 2026-09-02)
        XCTAssertEqual(seriesRecords.map(\.quoteDateISO), ["2026-09-06", "2026-09-05", "2026-09-04", "2026-09-03", "2026-09-02"])
        XCTAssertTrue(seriesRecords.allSatisfy { $0.sku == "TN-4908-8GTX-WV-CT-T" && !$0.isExactSKUMatch })
        XCTAssertEqual(group.minUnitPrice, 6850.0)
        XCTAssertEqual(group.maxUnitPrice, 7700.0)
    }

    func testLookupSkipsSeriesFallbackWhenThreeOrMoreExactHitsExist() async throws {
        try buildMockOutlookDatabase(at: dbURL) { db in
            for idx in 1...3 {
                let msgID = try insertMessage(
                    db: db,
                    messageID: "exact-\(idx)@moxa.com",
                    subject: "Exact Quote #\(idx)",
                    dateISO: "2026-10-0\(idx)",
                    projectName: "Proj-\(idx)",
                    customerOrg: "Cust-\(idx)"
                )
                try insertPrice(
                    db: db,
                    messageRowID: msgID,
                    sku: "TN-4908-4GTX-WV-CT-T",
                    currency: "RMB",
                    unitPrice: 6500.0 + Double(idx * 50),
                    quantity: 10,
                    priceType: "quote",
                    taxMode: "未税",
                    customerOrg: "Cust-\(idx)",
                    projectName: "Proj-\(idx)",
                    quoteDateISO: "2026-10-0\(idx)",
                    evidenceSnippet: "Exact \(idx)",
                    confidence: "high"
                )
            }

            let seriesMsgID = try insertMessage(
                db: db,
                messageID: "series-should-not-append@moxa.com",
                subject: "Series Quote",
                dateISO: "2026-11-01",
                projectName: "SeriesProj",
                customerOrg: "SeriesCust"
            )
            try insertPrice(
                db: db,
                messageRowID: seriesMsgID,
                sku: "TN-4908-8GTX-WV-CT-T",
                currency: "RMB",
                unitPrice: 7500.0,
                quantity: 10,
                priceType: "quote",
                taxMode: "未税",
                customerOrg: "SeriesCust",
                projectName: "SeriesProj",
                quoteDateISO: "2026-11-01",
                evidenceSnippet: "Series",
                confidence: "high"
            )
        }

        let email = makeEmail(
            subject: "报价 TN-4908-4GTX-WV-CT-T",
            plainBody: "请提供 TN-4908-4GTX-WV-CT-T 最新报价。"
        )
        let groups = await service.lookupRelatedPrices(for: email, runtimeDBPath: dbURL.path)

        XCTAssertEqual(groups.count, 1)
        let records = try XCTUnwrap(groups.first?.records)
        XCTAssertEqual(records.count, 3)
        XCTAssertTrue(records.allSatisfy(\.isExactSKUMatch))
        XCTAssertFalse(records.contains(where: { $0.sku == "TN-4908-8GTX-WV-CT-T" }))
    }

    func testLookupSkipsWithoutPricingIntentUnlessForced() async throws {
        try buildMockOutlookDatabase(at: dbURL) { db in
            let msgID = try insertMessage(
                db: db,
                messageID: "tech-test-1@moxa.com",
                subject: "TN-4908-4GTX-WV-CT-T Quote",
                dateISO: "2026-10-01",
                projectName: "Rail",
                customerOrg: "Client"
            )
            try insertPrice(
                db: db,
                messageRowID: msgID,
                sku: "TN-4908-4GTX-WV-CT-T",
                currency: "RMB",
                unitPrice: 6700.0,
                quantity: 5,
                priceType: "quote",
                taxMode: "未税",
                customerOrg: "Client",
                projectName: "Rail",
                quoteDateISO: "2026-10-01",
                evidenceSnippet: "6700 RMB",
                confidence: "high"
            )
        }

        let technicalEmail = makeEmail(
            subject: "TN-4908-4GTX-WV-CT-T EN 50155 specification",
            plainBody: "Please review the datasheet and mechanical dimensions before spring testing."
        )

        let skipped = await service.lookupRelatedPrices(for: technicalEmail, runtimeDBPath: dbURL.path)
        XCTAssertTrue(skipped.isEmpty)

        let forced = await service.lookupRelatedPrices(for: technicalEmail, runtimeDBPath: dbURL.path, forceLookup: true)
        XCTAssertEqual(forced.count, 1)
        XCTAssertEqual(forced.first?.records.first?.unitPrice, 6700.0)
    }

    // MARK: - Cold Staging, Header Guard, Symlink Guard & .moxa-kb Redline

    func testColdDBURLFallbackSafeCopyAndGuards() async throws {
        try buildMockOutlookDatabase(at: dbURL) { db in
            let msgID = try insertMessage(
                db: db,
                messageID: "cold-fallback-1@moxa.com",
                subject: "Cold DB Quote",
                dateISO: "2026-11-10",
                projectName: "Metro",
                customerOrg: "CRSC"
            )
            try insertPrice(
                db: db,
                messageRowID: msgID,
                sku: "TN-4908-4GTX-WV-CT-T",
                currency: "USD",
                unitPrice: 920.0,
                quantity: 12,
                priceType: "spr_support",
                taxMode: "",
                customerOrg: "CRSC",
                projectName: "Metro",
                quoteDateISO: "2026-11-10",
                evidenceSnippet: "USD 920",
                confidence: "high"
            )
        }

        let email = makeEmail(
            subject: "Quote request TN-4908-4GTX-WV-CT-T",
            plainBody: "Please provide unit price for TN-4908-4GTX-WV-CT-T."
        )

        // 1. Direct path containing ".moxa-kb" (inside temporaryDirectory) must be refused without coldDBURL.
        let fakeSyncDir = tempDir.appendingPathComponent(".moxa-kb", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeSyncDir, withIntermediateDirectories: true)
        let fakeSyncDB = fakeSyncDir.appendingPathComponent("outlook.sqlite")
        try FileManager.default.copyItem(at: dbURL, to: fakeSyncDB)

        let blockedDirect = await service.lookupRelatedPrices(
            for: email,
            runtimeDBPath: fakeSyncDB.path,
            coldDBURL: nil
        )
        XCTAssertTrue(blockedDirect.isEmpty)

        // 2. Non-SQLite file as coldDBURL must be rejected without staging anything.
        let invalidColdURL = tempDir.appendingPathComponent("invalid.sqlite")
        try Data("not a real sqlite database file at all — padding to exceed 100 bytes................................................".utf8)
            .write(to: invalidColdURL)
        let missingRuntime = tempDir.appendingPathComponent("missing-runtime.sqlite").path
        let invalidColdResult = await service.lookupRelatedPrices(
            for: email,
            runtimeDBPath: missingRuntime,
            coldDBURL: invalidColdURL
        )
        XCTAssertTrue(invalidColdResult.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDir.appendingPathComponent("outlook.sqlite").path))

        // 3. Symlink as coldDBURL must be rejected via O_RDONLY | O_NOFOLLOW.
        let symlinkColdURL = tempDir.appendingPathComponent("symlink-outlook.sqlite")
        try FileManager.default.createSymbolicLink(at: symlinkColdURL, withDestinationURL: dbURL)
        let symlinkResult = await service.lookupRelatedPrices(
            for: email,
            runtimeDBPath: missingRuntime,
            coldDBURL: symlinkColdURL
        )
        XCTAssertTrue(symlinkResult.isEmpty)

        // 4. Valid coldDBURL stages safely into stagingDir/outlook.sqlite and serves results.
        let coldResult = await service.lookupRelatedPrices(
            for: email,
            runtimeDBPath: missingRuntime,
            coldDBURL: dbURL
        )
        XCTAssertEqual(coldResult.count, 1)
        let stagedFile = stagingDir.appendingPathComponent("outlook.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedFile.path))
        let record = try XCTUnwrap(coldResult.first?.records.first)
        XCTAssertEqual(record.currency, "USD")
        XCTAssertEqual(record.unitPrice, 920.0, accuracy: 0.001)
        XCTAssertEqual(record.priceTypeLabel, "特价支持")
        XCTAssertEqual(record.mailJumpURL, URL(string: "message://%3Ccold-fallback-1@moxa.com%3E"))
    }

    func testDeduplicatesWeeklyBillingAndSparseAnonymousRowsAcrossDates() async throws {
        try buildMockOutlookDatabase(at: dbURL) { db in
            let dates = ["2026-10-21", "2026-09-14", "2026-08-10", "2026-07-08", "2026-06-15", "2026-05-29"]
            for (idx, date) in dates.enumerated() {
                let project = idx.isMultiple(of: 2)
                    ? "波尔图地铁首车-青岛四方所-TN-4908"
                    : "波尔图二期防火墙——四方所——TN-4908-4GTX-WV-CT-T *25"
                let msgID = try insertMessage(
                    db: db,
                    messageID: "weekly-billing-\(idx)@moxa.com",
                    subject: "【2026每周出货明细】\(date)",
                    dateISO: date,
                    projectName: project,
                    customerOrg: "浙江中自庆安新能源技术有限公司"
                )
                try insertPrice(
                    db: db,
                    messageRowID: msgID,
                    sku: "TN-4908-4GTX-WV-CT-T",
                    currency: idx == 1 ? "CNY" : "RMB",
                    unitPrice: 16350.0,
                    quantity: 2,
                    priceType: "order_price",
                    taxMode: idx == 2 ? "" : "未税",
                    customerOrg: "浙江中自庆安新能源技术有限公司",
                    projectName: project,
                    quoteDateISO: date,
                    evidenceSnippet: "Billing \(date)",
                    confidence: "high"
                )
            }

            // Anonymous metadata-sparse echo at the same 16350 price -> should merge into richer 16350 record
            let anonMsg = try insertMessage(
                db: db,
                messageID: "anon-echo-16350@moxa.com",
                subject: "Price note",
                dateISO: "2026-04-01",
                projectName: "",
                customerOrg: ""
            )
            try insertPrice(
                db: db,
                messageRowID: anonMsg,
                sku: "TN-4908-4GTX-WV-CT-T",
                currency: "RMB",
                unitPrice: 16350.0,
                quantity: nil,
                priceType: "quote",
                taxMode: "未税",
                customerOrg: "",
                projectName: "",
                quoteDateISO: "2026-04-01",
                evidenceSnippet: "16350 quote",
                confidence: "medium"
            )

            // Distinct customer + lower price
            let otherCustMsg = try insertMessage(
                db: db,
                messageID: "hangzhou-14400@moxa.com",
                subject: "杭州地铁 15 号线报价",
                dateISO: "2025-08-05",
                projectName: "杭州地铁 15 号线",
                customerOrg: "南京信源通"
            )
            try insertPrice(
                db: db,
                messageRowID: otherCustMsg,
                sku: "TN-4908-4GTX-WV-CT-T",
                currency: "RMB",
                unitPrice: 14400.0,
                quantity: 12,
                priceType: "quote",
                taxMode: "未税",
                customerOrg: "南京信源通",
                projectName: "杭州地铁 15 号线",
                quoteDateISO: "2025-08-05",
                evidenceSnippet: "14400 quote",
                confidence: "high"
            )

            // Distinct higher price with project name only
            let projectOnlyMsg = try insertMessage(
                db: db,
                messageID: "porto-16500@moxa.com",
                subject: "波尔图地铁二期(红宝石)",
                dateISO: "2026-01-15",
                projectName: "波尔图地铁二期(红宝石)",
                customerOrg: ""
            )
            try insertPrice(
                db: db,
                messageRowID: projectOnlyMsg,
                sku: "TN-4908-4GTX-WV-CT-T",
                currency: "CNY",
                unitPrice: 16500.0,
                quantity: 25,
                priceType: "quote",
                taxMode: "未税",
                customerOrg: "",
                projectName: "波尔图地铁二期(红宝石)",
                quoteDateISO: "2026-01-15",
                evidenceSnippet: "16500 quote",
                confidence: "high"
            )
        }

        let email = makeEmail(
            subject: "核价 TN-4908-4GTX-WV-CT-T",
            plainBody: "请查询 TN-4908-4GTX-WV-CT-T 历史报价。"
        )
        let groups = await service.lookupRelatedPrices(for: email, runtimeDBPath: dbURL.path)
        XCTAssertEqual(groups.count, 1)

        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.primaryCurrency, "RMB")
        XCTAssertEqual(group.minUnitPrice ?? 0, 14400.0, accuracy: 0.001)
        XCTAssertEqual(group.maxUnitPrice ?? 0, 16500.0, accuracy: 0.001)
        XCTAssertEqual(group.records.count, 3)

        let merged16350 = try XCTUnwrap(group.records.first(where: { abs($0.unitPrice - 16350.0) < 0.01 }))
        XCTAssertEqual(merged16350.occurrenceCount, 7)
        XCTAssertEqual(merged16350.quoteDateISO, "2026-10-21")
        XCTAssertEqual(merged16350.customerOrg, "浙江中自庆安新能源技术有限公司")
        XCTAssertEqual(merged16350.currency, "RMB")

        XCTAssertEqual(group.records.map(\.quoteDateISO), ["2026-10-21", "2026-01-15", "2025-08-05"])
    }

    func testMergesSameThreadAndSameSubjectWithIdenticalPriceAcrossMultipleCustomers() async throws {
        try buildMockOutlookDatabase(at: dbURL) { db in
            // 1. Six replies in the same Q4 FEP group-buy thread/subject at RMB 900.0 across 6 distributors
            let q4Replies: [(id: String, subject: String, topic: String, date: String, cust: String)] = [
                ("q4-1@moxajxtd.com", "2026 第四季度 Q4  FEP 数量统计", "2026 第四季度 Q4  FEP 数量统计", "2026-11-13", "北京佳信通达"),
                ("q4-2@qq.com", "Re: 2026 第四季度 Q4  FEP 数量统计", "2026 第四季度 Q4  FEP 数量统计", "2026-10-30", "浙江中自庆安 (WindIT)"),
                ("q4-3@haitun.com", "回复：2026 第四季度 Q4 FEP 数量统计", "2026 第四季度 Q4  FEP 数量统计", "2026-10-29", "郑州海豚科技"),
                ("q4-4@vip.163.com", "FW: [External] 2026 第四季度 Q4 FEP 数量统计", "2026 第四季度 Q4  FEP 数量统计", "2026-10-27", "北京时代佳业"),
                ("q4-5@mingit.com", "Re: 2026 第四季度 Q4 FEP 数量统计 - 补充", "2026 第四季度 Q4  FEP 数量统计", "2026-10-27", "南京明高科技,深圳市海豚科技"),
                ("q4-6@moxa.com", "回复: 2026 第四季度 Q4 FEP 数量统计", "", "2026-10-19", "")
            ]

            for item in q4Replies {
                let msgID = try insertMessage(
                    db: db,
                    messageID: item.id,
                    subject: item.subject,
                    threadTopic: item.topic,
                    dateISO: item.date,
                    projectName: "",
                    customerOrg: item.cust
                )
                try insertPrice(
                    db: db,
                    messageRowID: msgID,
                    sku: "DE-LN04-RJ",
                    currency: "RMB",
                    unitPrice: 900.0,
                    quantity: nil,
                    priceType: "quote",
                    taxMode: "未税",
                    customerOrg: item.cust,
                    projectName: "",
                    quoteDateISO: item.date,
                    evidenceSnippet: "DE-LN04-RJ: 900 CNY/pc(未稅)",
                    confidence: "high"
                )
            }

            // 2. Bogus tiny-integer RMB artifact parsed from SKU "DE-LN04-RJ" digits when real snippet price is 705/900
            let bogusMsgID = try insertMessage(
                db: db,
                messageID: "bogus-sku-digit@moxa.com",
                subject: "MCN FEP 机型 DA-682B 的价格调整共识",
                threadTopic: "MCN FEP 机型 DA-682B 的价格调整共识",
                dateISO: "2026-06-11",
                projectName: "",
                customerOrg: ""
            )
            try insertPrice(
                db: db,
                messageRowID: bogusMsgID,
                sku: "DE-LN04-RJ",
                currency: "RMB",
                unitPrice: 4.0,
                quantity: nil,
                priceType: "quote",
                taxMode: "未税",
                customerOrg: "",
                projectName: "",
                quoteDateISO: "2026-06-11",
                evidenceSnippet: "价格未税: DE-LN04-RJ: 705 CNY/pc(未稅) | DE-LN04-RJ: 900 CNY/pc(未稅)",
                confidence: "high"
            )

            // 3. Same subject/thread with DIFFERENT prices (RMB 700 vs RMB 800) must stay separate
            let multiPriceMsgID = try insertMessage(
                db: db,
                messageID: "rule-prices@moxa.com",
                subject: "FEP季度统一采购规则",
                threadTopic: "FEP季度统一采购规则",
                dateISO: "2026-01-04",
                projectName: "",
                customerOrg: "深圳市海豚科技"
            )
            try insertPrice(
                db: db,
                messageRowID: multiPriceMsgID,
                sku: "DE-LN04-RJ",
                currency: "RMB",
                unitPrice: 700.0,
                quantity: nil,
                priceType: "quote",
                taxMode: "未税",
                customerOrg: "深圳市海豚科技",
                projectName: "",
                quoteDateISO: "2026-01-04",
                evidenceSnippet: "FEP季度统一采购规则 700 RMB",
                confidence: "high"
            )
            try insertPrice(
                db: db,
                messageRowID: multiPriceMsgID,
                sku: "DE-LN04-RJ",
                currency: "RMB",
                unitPrice: 800.0,
                quantity: nil,
                priceType: "quote",
                taxMode: "未税",
                customerOrg: "深圳市海豚科技",
                projectName: "",
                quoteDateISO: "2026-01-04",
                evidenceSnippet: "FEP季度统一采购规则 800 RMB",
                confidence: "high"
            )

            // 4. Separate order price record at RMB 705
            let orderMsgID = try insertMessage(
                db: db,
                messageID: "order-705@moxa.com",
                subject: "【2026每周出货明细】",
                threadTopic: "【2026每周出货明细】",
                dateISO: "2026-10-21",
                projectName: "地铁项目模块补订",
                customerOrg: "杭州寰控物联智能技术有限公司"
            )
            try insertPrice(
                db: db,
                messageRowID: orderMsgID,
                sku: "DE-LN04-RJ",
                currency: "RMB",
                unitPrice: 705.0,
                quantity: 10,
                priceType: "order_price",
                taxMode: "未税",
                customerOrg: "杭州寰控物联智能技术有限公司",
                projectName: "地铁项目模块补订",
                quoteDateISO: "2026-10-21",
                evidenceSnippet: "DE-LN04-RJ 705 RMB",
                confidence: "high"
            )
        }

        let email = makeEmail(
            subject: "核价：DE-LN04-RJ",
            plainBody: "请核对 DE-LN04-RJ 特价与报价。"
        )
        let groups = await service.lookupRelatedPrices(for: email, runtimeDBPath: dbURL.path)
        XCTAssertEqual(groups.count, 1)

        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.records.count, 4)
        XCTAssertEqual(group.minUnitPrice ?? 0, 700.0, accuracy: 0.001)
        XCTAssertEqual(group.maxUnitPrice ?? 0, 900.0, accuracy: 0.001)

        // Bogus RMB 4.0 artifact must be filtered out
        XCTAssertFalse(group.records.contains(where: { abs($0.unitPrice - 4.0) < 0.01 }))

        let merged900 = try XCTUnwrap(group.records.first(where: { abs($0.unitPrice - 900.0) < 0.01 }))
        XCTAssertEqual(merged900.occurrenceCount, 6)
        XCTAssertEqual(merged900.quoteDateISO, "2026-11-13")
        XCTAssertEqual(merged900.customerOrg, "北京佳信通达、浙江中自庆安 (WindIT) 等 6 家")
        XCTAssertEqual(merged900.projectName, "2026 第四季度 Q4 FEP 数量统计")

        // Distinct prices under same subject remain distinct
        XCTAssertTrue(group.records.contains(where: { abs($0.unitPrice - 700.0) < 0.01 }))
        XCTAssertTrue(group.records.contains(where: { abs($0.unitPrice - 800.0) < 0.01 }))
        XCTAssertTrue(group.records.contains(where: { abs($0.unitPrice - 705.0) < 0.01 }))
    }

    func testSubjectNormalizationFallbackWithoutThreadTopicColumn() async throws {
        try buildMockOutlookDatabase(at: dbURL, includeThreadTopic: false) { db in
            let msg1 = try insertMessage(
                db: db,
                messageID: "legacy-1@moxa.com",
                subject: "Re: 2026 Q4 FEP 统计",
                dateISO: "2026-11-12",
                projectName: "",
                customerOrg: "客户甲",
                hasThreadTopicColumn: false
            )
            try insertPrice(
                db: db,
                messageRowID: msg1,
                sku: "DE-LN04-RJ",
                currency: "RMB",
                unitPrice: 900.0,
                quantity: nil,
                priceType: "quote",
                taxMode: "未税",
                customerOrg: "客户甲",
                projectName: "",
                quoteDateISO: "2026-11-12",
                evidenceSnippet: "900",
                confidence: "high"
            )

            let msg2 = try insertMessage(
                db: db,
                messageID: "legacy-2@moxa.com",
                subject: "回复：2026 Q4 FEP 统计",
                dateISO: "2026-11-10",
                projectName: "",
                customerOrg: "客户乙",
                hasThreadTopicColumn: false
            )
            try insertPrice(
                db: db,
                messageRowID: msg2,
                sku: "DE-LN04-RJ",
                currency: "RMB",
                unitPrice: 900.0,
                quantity: nil,
                priceType: "quote",
                taxMode: "未税",
                customerOrg: "客户乙",
                projectName: "",
                quoteDateISO: "2026-11-10",
                evidenceSnippet: "900",
                confidence: "high"
            )
        }

        let email = makeEmail(subject: "报价 DE-LN04-RJ", plainBody: "DE-LN04-RJ 报价")
        let groups = await service.lookupRelatedPrices(for: email, runtimeDBPath: dbURL.path)
        XCTAssertEqual(groups.count, 1)
        let record = try XCTUnwrap(groups.first?.records.first)
        XCTAssertEqual(groups.first?.records.count, 1)
        XCTAssertEqual(record.occurrenceCount, 2)
        XCTAssertEqual(record.customerOrg, "客户甲、客户乙")
        XCTAssertEqual(record.projectName, "2026 Q4 FEP 统计")
    }

    // MARK: - Helpers

    private func makeEmail(
        messageID: String = "default-email@example.com",
        subject: String,
        plainBody: String,
        quotedChain: [QuotedMessageBlock] = []
    ) -> ParsedEmailContext {
        ParsedEmailContext(
            messageID: messageID,
            subject: subject,
            from: "partner@example.com",
            to: ["baoshan.wang@moxa.com"],
            cc: [],
            dateString: "Fri, 20 Nov 2026 10:00:00 +0800",
            inReplyTo: nil,
            references: [],
            plainBody: plainBody,
            quotedChain: quotedChain,
            attachments: []
        )
    }

    private func makeAnalysis(
        flag: String? = nil,
        models: [String] = [],
        pricing: [PricingElement] = []
    ) -> EmailAIAnalysis {
        EmailAIAnalysis(
            headline: "测试结论",
            coreConclusions: [],
            todos: [],
            businessElements: BusinessElements(
                projects: [],
                customers: [],
                models: models,
                pricing: pricing
            ),
            plainChineseTranslation: "",
            timeline: [],
            suggestedFlag: flag,
            flagReason: nil
        )
    }

    private func buildMockOutlookDatabase(
        at url: URL,
        includeThreadTopic: Bool = true,
        populate: (OpaquePointer) throws -> Void
    ) throws {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(
            url.path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        )
        guard rc == SQLITE_OK, let db else {
            throw NSError(domain: "HistoricalPriceLookupTests", code: Int(rc), userInfo: [
                NSLocalizedDescriptionKey: "Failed to open temporary sqlite database"
            ])
        }
        defer { sqlite3_close(db) }

        let threadTopicColumnSQL = includeThreadTopic
            ? "\n            thread_topic TEXT NOT NULL DEFAULT '',"
            : ""

        let schemaSQL = """
        CREATE TABLE messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source TEXT NOT NULL DEFAULT 'apple_mail',
            source_ref TEXT NOT NULL DEFAULT '',
            efm_id TEXT NOT NULL DEFAULT '',
            message_id TEXT NOT NULL DEFAULT '',
            subject TEXT NOT NULL,
            sender TEXT NOT NULL DEFAULT '',
            recipients TEXT NOT NULL DEFAULT '',
            cc TEXT NOT NULL DEFAULT '',
            date_iso TEXT NOT NULL DEFAULT '',
            body_latest TEXT NOT NULL DEFAULT '',
            body_quoted TEXT NOT NULL DEFAULT '',
            content_hash TEXT NOT NULL UNIQUE,\(threadTopicColumnSQL)
            project_name TEXT NOT NULL DEFAULT '',
            customers_orgs TEXT NOT NULL DEFAULT ''
        );

        CREATE TABLE message_prices (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            message_id INTEGER NOT NULL REFERENCES messages(id),
            uid_key TEXT NOT NULL DEFAULT '',
            sku TEXT NOT NULL DEFAULT '',
            product_family TEXT NOT NULL DEFAULT 'General',
            project_name TEXT NOT NULL DEFAULT '',
            customer_org TEXT NOT NULL DEFAULT '',
            currency TEXT NOT NULL DEFAULT '',
            unit_price REAL,
            total_amount REAL,
            quantity REAL,
            price_type TEXT NOT NULL DEFAULT '',
            tax_mode TEXT NOT NULL DEFAULT '',
            moq TEXT NOT NULL DEFAULT '',
            lead_time TEXT NOT NULL DEFAULT '',
            discount_info TEXT NOT NULL DEFAULT '',
            valid_until TEXT NOT NULL DEFAULT '',
            quote_date_iso TEXT NOT NULL DEFAULT '',
            source_kind TEXT NOT NULL DEFAULT '',
            evidence_snippet TEXT NOT NULL DEFAULT '',
            confidence TEXT NOT NULL DEFAULT 'medium'
        );

        CREATE VIEW v_sku_price_history AS
        SELECT
            p.sku, p.product_family, p.currency, p.unit_price, p.total_amount, p.quantity,
            p.price_type, p.tax_mode, p.moq, p.lead_time, p.discount_info, p.valid_until,
            COALESCE(NULLIF(p.quote_date_iso, ''), m.date_iso) AS quote_date_iso,
            COALESCE(NULLIF(p.project_name, ''), m.project_name) AS project_name,
            COALESCE(NULLIF(p.customer_org, ''), m.customers_orgs) AS customer_org,
            p.confidence, p.source_kind, p.evidence_snippet, p.message_id, p.uid_key,
            m.subject, m.sender
        FROM message_prices p
        JOIN messages m ON m.id = p.message_id
        ORDER BY COALESCE(NULLIF(p.quote_date_iso, ''), m.date_iso) DESC, p.id DESC;
        """

        try execSQL(db: db, sql: schemaSQL)
        try populate(db)
    }

    private func execSQL(db: OpaquePointer, sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let reason = errMsg.map { String(cString: $0) } ?? "SQLite error \(rc)"
            sqlite3_free(errMsg)
            throw NSError(domain: "HistoricalPriceLookupTests", code: Int(rc), userInfo: [
                NSLocalizedDescriptionKey: reason
            ])
        }
    }

    private func insertMessage(
        db: OpaquePointer,
        messageID: String,
        subject: String,
        threadTopic: String = "",
        dateISO: String,
        projectName: String,
        customerOrg: String,
        hasThreadTopicColumn: Bool = true
    ) throws -> Int64 {
        let sql: String
        if hasThreadTopicColumn {
            sql = """
            INSERT INTO messages (source, source_ref, message_id, subject, sender, date_iso, body_latest, content_hash, project_name, customers_orgs, thread_topic)
            VALUES ('apple_mail', ?, ?, ?, 'sales@moxa.com', ?, 'body', ?, ?, ?, ?);
            """
        } else {
            sql = """
            INSERT INTO messages (source, source_ref, message_id, subject, sender, date_iso, body_latest, content_hash, project_name, customers_orgs)
            VALUES ('apple_mail', ?, ?, ?, 'sales@moxa.com', ?, 'body', ?, ?, ?);
            """
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw NSError(domain: "HistoricalPriceLookupTests", code: -1)
        }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let hash = UUID().uuidString
        "ref-\(hash)".withCString { _ = sqlite3_bind_text(stmt, 1, $0, -1, transient) }
        messageID.withCString { _ = sqlite3_bind_text(stmt, 2, $0, -1, transient) }
        subject.withCString { _ = sqlite3_bind_text(stmt, 3, $0, -1, transient) }
        dateISO.withCString { _ = sqlite3_bind_text(stmt, 4, $0, -1, transient) }
        hash.withCString { _ = sqlite3_bind_text(stmt, 5, $0, -1, transient) }
        projectName.withCString { _ = sqlite3_bind_text(stmt, 6, $0, -1, transient) }
        customerOrg.withCString { _ = sqlite3_bind_text(stmt, 7, $0, -1, transient) }
        if hasThreadTopicColumn {
            threadTopic.withCString { _ = sqlite3_bind_text(stmt, 8, $0, -1, transient) }
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(domain: "HistoricalPriceLookupTests", code: -2)
        }
        return sqlite3_last_insert_rowid(db)
    }

    private func insertPrice(
        db: OpaquePointer,
        messageRowID: Int64,
        sku: String,
        currency: String,
        unitPrice: Double,
        quantity: Double?,
        priceType: String,
        taxMode: String,
        customerOrg: String,
        projectName: String,
        quoteDateISO: String,
        evidenceSnippet: String,
        confidence: String
    ) throws {
        let sql = """
        INSERT INTO message_prices (
            message_id, uid_key, sku, product_family, project_name, customer_org,
            currency, unit_price, quantity, price_type, tax_mode, quote_date_iso,
            source_kind, evidence_snippet, confidence
        ) VALUES (?, ?, ?, 'TN', ?, ?, ?, ?, ?, ?, ?, ?, 'body', ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw NSError(domain: "HistoricalPriceLookupTests", code: -3)
        }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_int64(stmt, 1, messageRowID)
        UUID().uuidString.withCString { _ = sqlite3_bind_text(stmt, 2, $0, -1, transient) }
        sku.withCString { _ = sqlite3_bind_text(stmt, 3, $0, -1, transient) }
        projectName.withCString { _ = sqlite3_bind_text(stmt, 4, $0, -1, transient) }
        customerOrg.withCString { _ = sqlite3_bind_text(stmt, 5, $0, -1, transient) }
        currency.withCString { _ = sqlite3_bind_text(stmt, 6, $0, -1, transient) }
        sqlite3_bind_double(stmt, 7, unitPrice)
        if let quantity {
            sqlite3_bind_double(stmt, 8, quantity)
        } else {
            sqlite3_bind_null(stmt, 8)
        }
        priceType.withCString { _ = sqlite3_bind_text(stmt, 9, $0, -1, transient) }
        taxMode.withCString { _ = sqlite3_bind_text(stmt, 10, $0, -1, transient) }
        quoteDateISO.withCString { _ = sqlite3_bind_text(stmt, 11, $0, -1, transient) }
        evidenceSnippet.withCString { _ = sqlite3_bind_text(stmt, 12, $0, -1, transient) }
        confidence.withCString { _ = sqlite3_bind_text(stmt, 13, $0, -1, transient) }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(domain: "HistoricalPriceLookupTests", code: -4)
        }
    }
}
