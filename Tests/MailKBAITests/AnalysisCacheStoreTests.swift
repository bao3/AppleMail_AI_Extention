import Foundation
import XCTest

final class AnalysisCacheStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: AnalysisCacheStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("MailKBAITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = AnalysisCacheStore(baseDirectory: tempDir)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testSaveLoadOverwriteAndClearByNormalizedMessageID() throws {
        let rawID = "  <ABC-123@Example.COM>  "
        let normalizedLookupID = "abc-123@example.com"

        XCTAssertFalse(store.hasCachedAnalysis(forMessageID: rawID))
        XCTAssertNil(store.load(forMessageID: normalizedLookupID))

        let first = EmailAIAnalysis(
            headline: "确认 120 台 EDS-4012 报价 USD 485",
            coreConclusions: ["交期 4 周", "FOB Taipei"],
            todos: [EmailTodoItem(task: "发送 PI", owner: "我方商务", deadline: "周五", priority: "high")],
            businessElements: BusinessElements(
                projects: ["Helios-III"],
                customers: ["Acme Grid"],
                models: ["EDS-4012"],
                pricing: [PricingElement(itemOrModel: "EDS-4012", quantity: "120", unitPrice: "485", currency: "USD", termsOrLeadTime: "FOB Taipei / 4 weeks")]
            ),
            plainChineseTranslation: "对方确认接受单价 485 美元。",
            timeline: [TimelineEvent(timeOrStep: "11-19", actor: "Marcus", summary: "确认批量价")],
            messageID: rawID,
            modelUsed: GeminiModel.flash38.rawValue
        )

        try store.save(first, forMessageID: rawID)
        XCTAssertTrue(store.hasCachedAnalysis(forMessageID: normalizedLookupID))

        let loaded = store.load(forMessageID: normalizedLookupID)
        XCTAssertEqual(loaded?.headline, first.headline)
        XCTAssertEqual(loaded?.modelUsed, GeminiModel.flash38.rawValue)
        XCTAssertEqual(loaded?.businessElements.pricing.first?.unitPrice, "485")

        // Overwrite with Carbon 4 analysis
        let second = EmailAIAnalysis(
            headline: "深度复核版结论",
            coreConclusions: ["补充证书条款"],
            todos: [],
            businessElements: first.businessElements,
            plainChineseTranslation: "更新译文",
            timeline: first.timeline,
            messageID: normalizedLookupID,
            modelUsed: GeminiModel.carbon4.rawValue
        )
        try store.save(second, forMessageID: normalizedLookupID)
        let reloaded = store.load(forMessageID: rawID)
        XCTAssertEqual(reloaded?.modelUsed, GeminiModel.carbon4.rawValue)
        XCTAssertEqual(reloaded?.headline, "深度复核版结论")

        let stats = store.cacheStats()
        XCTAssertEqual(stats.count, 1)
        XCTAssertGreaterThan(stats.totalBytes, 0)
        XCTAssertEqual(store.cachedHeadlineInMemory(forMessageID: rawID), "深度复核版结论")

        // Fresh store instance warms knownCachedKeys from existing JSON files on disk (without reading payloads)
        let warmedStore = AnalysisCacheStore(baseDirectory: tempDir)
        XCTAssertTrue(warmedStore.hasCachedAnalysisInMemory(forMessageID: rawID))
        XCTAssertNil(warmedStore.cachedHeadlineInMemory(forMessageID: rawID))
        let loadedFromWarmed = warmedStore.load(forMessageID: rawID)
        XCTAssertEqual(loadedFromWarmed?.headline, "深度复核版结论")
        XCTAssertEqual(warmedStore.cachedHeadlineInMemory(forMessageID: rawID), "深度复核版结论")

        let cleared = store.clearAll()
        XCTAssertEqual(cleared, 1)
        XCTAssertFalse(store.hasCachedAnalysis(forMessageID: rawID))
        XCTAssertNil(store.cachedHeadlineInMemory(forMessageID: rawID))
    }

    func testCachedOrDiskHeadlineAndWarmHeadlinesFromDisk() throws {
        let msgID1 = "external-write-1@moxa.com"
        let msgID2 = "external-write-2@moxa.com"

        // Simulate an external writer persisting JSONs before any in-memory lookup
        let writerStore = AnalysisCacheStore(baseDirectory: tempDir)
        try writerStore.save(
            EmailAIAnalysis(
                headline: "紧急确认 `EDS-4012` **特价**",
                coreConclusions: ["确认价格"],
                todos: [],
                businessElements: BusinessElements(),
                plainChineseTranslation: "",
                timeline: [],
                messageID: msgID1,
                modelUsed: "group/smart-split"
            ),
            forMessageID: msgID1
        )
        try writerStore.save(
            EmailAIAnalysis(
                headline: "第二个外部缓存结论",
                coreConclusions: ["跟进交期"],
                todos: [],
                businessElements: BusinessElements(),
                plainChineseTranslation: "",
                timeline: [],
                messageID: msgID2,
                modelUsed: "group/smart-split"
            ),
            forMessageID: msgID2
        )

        let coldReader = AnalysisCacheStore(baseDirectory: tempDir)
        XCTAssertNil(coldReader.cachedHeadlineInMemory(forMessageID: msgID1))
        XCTAssertEqual(coldReader.cachedOrDiskHeadline(forMessageID: msgID1), "紧急确认 `EDS-4012` **特价**")
        XCTAssertEqual(coldReader.cachedHeadlineInMemory(forMessageID: msgID1), "紧急确认 `EDS-4012` **特价**")

        XCTAssertNil(coldReader.cachedHeadlineInMemory(forMessageID: msgID2))
        coldReader.warmHeadlinesFromDisk()
        XCTAssertEqual(coldReader.cachedHeadlineInMemory(forMessageID: msgID2), "第二个外部缓存结论")
    }
}
