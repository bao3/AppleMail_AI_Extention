import CryptoKit
import Foundation
import MailKit
import SQLite3

private enum BatchCLIError: LocalizedError {
    case invalidArguments(String)
    case missingConfigPlist(String)
    case missingMagpieProfile(String)
    case vertexForbidden(String)
    case missingAPIKey(String)
    case sqliteOpenFailed(String)
    case sqliteQueryFailed(String)
    case insufficientEmails(found: Int, required: Int)
    case tooManyConsecutiveFailures(Int, lastError: String)
    case appleScriptPermissionDenied(String)

    var errorDescription: String? {
        switch self {
        case let .invalidArguments(msg):
            return "参数错误: \(msg)"
        case let .missingConfigPlist(path):
            return "找不到扩展配置文件: \(path)"
        case let .missingMagpieProfile(msg):
            return "未在扩展配置中找到 Magpie 服务商配置: \(msg)"
        case let .vertexForbidden(msg):
            return "安全拦截：禁止调用 Google Vertex AI（\(msg)），必须使用 Magpie。"
        case let .missingAPIKey(msg):
            return "无法从 Keychain 读取 Magpie API Key: \(msg)"
        case let .sqliteOpenFailed(msg):
            return "只读打开 Apple Mail Envelope Index 失败: \(msg)"
        case let .sqliteQueryFailed(msg):
            return "查询 Apple Mail Envelope Index 失败: \(msg)"
        case let .insufficientEmails(found, required):
            return "Moxa 有效工作邮件数量不足：仅找到 \(found) 封（需要 \(required) 封）"
        case let .tooManyConsecutiveFailures(count, lastError):
            return "Magpie 接口连续失败 \(count) 次，中止批处理。最近错误: \(lastError)"
        case let .appleScriptPermissionDenied(msg):
            return "Apple Mail AppleScript 打标权限被拒绝或被阻塞: \(msg)"
        }
    }
}

private struct CLIOptions: Sendable {
    var limit: Int = 500
    var concurrency: Int = 8
    var applyFlags: Bool = true
    var reportJSONPath: String?

    static func parse(_ args: [String]) throws -> CLIOptions {
        var opts = CLIOptions()
        var idx = 1
        while idx < args.count {
            let arg = args[idx]
            switch arg {
            case "--limit":
                idx += 1
                guard idx < args.count, let val = Int(args[idx]), val > 0 else {
                    throw BatchCLIError.invalidArguments("--limit 需要正整数")
                }
                opts.limit = val
            case "--concurrency":
                idx += 1
                guard idx < args.count, let val = Int(args[idx]), (1...32).contains(val) else {
                    throw BatchCLIError.invalidArguments("--concurrency 需要 1~32 整数")
                }
                opts.concurrency = val
            case "--apply-flags":
                opts.applyFlags = true
            case "--no-apply-flags":
                opts.applyFlags = false
            case "--report-json":
                idx += 1
                guard idx < args.count, !args[idx].isEmpty else {
                    throw BatchCLIError.invalidArguments("--report-json 需要路径")
                }
                opts.reportJSONPath = args[idx]
            default:
                throw BatchCLIError.invalidArguments("未知参数: \(arg)")
            }
            idx += 1
        }
        return opts
    }
}

private struct CandidateEmail: Sendable {
    let rowID: Int64
    let dateReceivedUnix: Int64
    let dateReceivedISO: String
    let mailboxURL: String
    let mailboxName: String
    let wasFlaggedInMail: Bool
    let existingFlagColor: Int
    let sqlSubject: String
    let sqlSender: String
    let parsed: ParsedEmailContext
}

private struct BatchEmailResult: Codable, Sendable {
    let rowID: Int64
    let messageID: String
    let dateReceivedUnix: Int64
    let dateReceivedISO: String
    let mailboxURL: String
    let mailboxName: String
    let subject: String
    let from: String
    let wasFlaggedInMail: Bool
    let existingFlagColor: Int
    let wasAlreadyCached: Bool
    var appliedFlagName: String?
    var appliedFlagIndex: Int?
    let analysis: EmailAIAnalysis
    let plainHeadline: String
    let plainConclusions: [String]
}

private struct BatchReportDocument: Codable, Sendable {
    let generatedAtISO: String
    let providerName: String
    let providerBaseURL: String
    let modelName: String
    let targetCount: Int
    let collectedCount: Int
    let analyzedNewCount: Int
    let reusedCacheCount: Int
    let failedCount: Int
    let newlyFlaggedCount: Int
    let totalFlaggedInMailCount: Int
    let skipStats: [String: Int]
    let mailboxDistribution: [String: Int]
    let entries: [BatchEmailResult]
}

private actor BatchExecutionState {
    private var completed = 0
    private var newlyAnalyzed = 0
    private var reusedCache = 0
    private var failed = 0
    private var consecutiveFailures = 0
    private var abortRequested = false
    private var abortErrorMessage = ""
    private var resultsByRowID: [Int64: BatchEmailResult] = [:]

    func recordCached(_ entry: BatchEmailResult) {
        completed += 1
        reusedCache += 1
        consecutiveFailures = 0
        resultsByRowID[entry.rowID] = entry
    }

    func recordAnalyzed(_ entry: BatchEmailResult) {
        completed += 1
        newlyAnalyzed += 1
        consecutiveFailures = 0
        resultsByRowID[entry.rowID] = entry
    }

    func recordFailure(error: String, isAuthFatal: Bool) -> (shouldAbort: Bool, consecutive: Int) {
        completed += 1
        failed += 1
        consecutiveFailures += 1
        if isAuthFatal || consecutiveFailures >= 20 {
            abortRequested = true
            abortErrorMessage = error
        }
        return (abortRequested, consecutiveFailures)
    }

    func shouldAbort() -> (abort: Bool, consecutive: Int, reason: String) {
        (abortRequested, consecutiveFailures, abortErrorMessage)
    }

    func progressSnapshot() -> (completed: Int, newlyAnalyzed: Int, reusedCache: Int, failed: Int) {
        (completed, newlyAnalyzed, reusedCache, failed)
    }

    func orderedEntries(following candidates: [CandidateEmail]) -> [BatchEmailResult] {
        candidates.compactMap { resultsByRowID[$0.rowID] }
    }
}

@main
struct BatchSummarizeMain {
    private static let extensionPlistPath =
        "\(NSHomeDirectory())/Library/Containers/com.bao3.AppleMailAI.Extension/Data/Library/Preferences/com.bao3.AppleMailAI.Extension.plist"
    private static let extensionAppSupportDir =
        URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Containers/com.bao3.AppleMailAI.Extension/Data/Library/Application Support", isDirectory: true)
    private static let hostAppSupportDir =
        URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Containers/com.bao3.AppleMailAI/Data/Library/Application Support", isDirectory: true)
    private static let moxaMailDir =
        URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Mail/V10/E94D4074-9E81-4F1D-9310-9E94C36EDEA2", isDirectory: true)
    private static let envelopeIndexURI =
        "file://\(NSHomeDirectory())/Library/Mail/V10/MailData/Envelope%20Index?mode=ro"
    private static let moxaAccountPrefix =
        "ews://E94D4074-9E81-4F1D-9310-9E94C36EDEA2/"
    private static let maxPassthroughRawBytes = 25 * 1024 * 1024

    static func main() async {
        do {
            try await run()
        } catch {
            logLine("❌ \(error.localizedDescription)")
            exit(1)
        }
    }

    private static func run() async throws {
        let opts = try CLIOptions.parse(CommandLine.arguments)
        logLine("=== AppleMailAIBatch 启动 (limit=\(opts.limit), concurrency=\(opts.concurrency), applyFlags=\(opts.applyFlags)) ===")

        // (A) Strictly load Extension Magpie config & API key (forbid Vertex AI)
        let (magpieProfile, apiKey) = try loadAndValidateMagpieConfig()
        let modelName = magpieProfile.modelName(for: .fast)
        logLine("✅ 已锁定扩展服务商: \(magpieProfile.name) | kind=\(magpieProfile.kind.rawValue) | baseURL=\(magpieProfile.normalizedBaseURL) | model=\(modelName)")

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.httpMaximumConnectionsPerHost = max(12, opts.concurrency + 4)
        sessionConfig.timeoutIntervalForRequest = 180
        sessionConfig.timeoutIntervalForResource = 300
        sessionConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        let aiClient = AIServiceClient(session: URLSession(configuration: sessionConfig))

        // (B) Read-only scan of Moxa recent N valid working emails
        let emlxIndex = buildEmlxIndex(under: moxaMailDir)
        logLine("📁 已索引 Moxa 本地邮件文件数: \(emlxIndex.count)")

        let (candidates, skipStats) = try collectValidMoxaCandidates(limit: opts.limit, emlxIndex: emlxIndex)
        guard candidates.count == opts.limit else {
            throw BatchCLIError.insufficientEmails(found: candidates.count, required: opts.limit)
        }

        let mailboxDist = Dictionary(grouping: candidates, by: \.mailboxName).mapValues(\.count)
        logLine("📬 已筛选出 \(candidates.count) 封有效 Moxa 工作邮件（时间范围: \(candidates.last?.dateReceivedISO ?? "") .. \(candidates.first?.dateReceivedISO ?? "")）")
        logLine("   来源分布: \(formatCounts(mailboxDist))")
        logLine("   过滤跳过统计: \(formatCounts(skipStats))")

        // (C) Summarize concurrently with Magpie and persist into shared App Group + Extension + HostApp caches
        let groupAppSupportDir = findSharedAppGroupContainer()?
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        let groupCache = groupAppSupportDir.map { AnalysisCacheStore(baseDirectory: $0) }
        let extCache = AnalysisCacheStore(baseDirectory: extensionAppSupportDir)
        let hostCache = AnalysisCacheStore(baseDirectory: hostAppSupportDir)

        let state = BatchExecutionState()
        let total = candidates.count

        // First handle already-cached entries quickly and gather pending queue
        var pending: [CandidateEmail] = []
        pending.reserveCapacity(total)

        for candidate in candidates {
            if let existing = groupCache?.load(forMessageID: candidate.parsed.messageID)
                ?? extCache.load(forMessageID: candidate.parsed.messageID)
            {
                if let groupCache, !groupCache.hasCachedAnalysis(forMessageID: candidate.parsed.messageID) {
                    try? groupCache.save(existing, forMessageID: candidate.parsed.messageID)
                }
                if !hostCache.hasCachedAnalysis(forMessageID: candidate.parsed.messageID) {
                    try? hostCache.save(existing, forMessageID: candidate.parsed.messageID)
                }
                let entry = makeResultEntry(candidate: candidate, analysis: existing, wasAlreadyCached: true)
                await state.recordCached(entry)
            } else {
                pending.append(candidate)
            }
        }

        let initialSnap = await state.progressSnapshot()
        logLine("💾 命中现有缓存: \(initialSnap.reusedCache) 封 | 待调用 Magpie 总结: \(pending.count) 封")

        if !pending.isEmpty {
            let maxWorkers = min(opts.concurrency, pending.count)
            try await withThrowingTaskGroup(of: Void.self) { group in
                var nextIdx = 0

                func enqueueNext() {
                    guard nextIdx < pending.count else { return }
                    let candidate = pending[nextIdx]
                    nextIdx += 1
                    group.addTask {
                        let abortCheck = await state.shouldAbort()
                        if abortCheck.abort { return }

                        do {
                            let analysis = try await analyzeWithRetry(
                                email: candidate.parsed,
                                profile: magpieProfile,
                                apiKey: apiKey,
                                aiClient: aiClient
                            )
                            if let groupCache {
                                try groupCache.save(analysis, forMessageID: candidate.parsed.messageID)
                                try? extCache.save(analysis, forMessageID: candidate.parsed.messageID)
                            } else {
                                try extCache.save(analysis, forMessageID: candidate.parsed.messageID)
                            }
                            try? hostCache.save(analysis, forMessageID: candidate.parsed.messageID)

                            let entry = makeResultEntry(candidate: candidate, analysis: analysis, wasAlreadyCached: false)
                            await state.recordAnalyzed(entry)
                        } catch {
                            let errDesc = error.localizedDescription
                            let isAuthFatal = isFatalAuthOrQuotaError(error)
                            let failStatus = await state.recordFailure(error: errDesc, isAuthFatal: isAuthFatal)
                            logLine("⚠️ [ROWID \(candidate.rowID)] 总结失败: \(errDesc)")
                            if failStatus.shouldAbort {
                                throw BatchCLIError.tooManyConsecutiveFailures(failStatus.consecutive, lastError: errDesc)
                            }
                        }

                        let snap = await state.progressSnapshot()
                        let doneFromQueue = snap.newlyAnalyzed + snap.failed
                        if doneFromQueue % 10 == 0 || snap.completed == total {
                            logLine("⏳ 进度: \(snap.completed)/\(total) (新完成 \(snap.newlyAnalyzed), 复用缓存 \(snap.reusedCache), 失败 \(snap.failed))")
                        }
                    }
                }

                for _ in 0..<maxWorkers {
                    enqueueNext()
                }
                while let _ = try await group.next() {
                    let abortCheck = await state.shouldAbort()
                    if abortCheck.abort {
                        group.cancelAll()
                        throw BatchCLIError.tooManyConsecutiveFailures(abortCheck.consecutive, lastError: abortCheck.reason)
                    }
                    enqueueNext()
                }
            }
        }

        let finalSnap = await state.progressSnapshot()
        var orderedResults = await state.orderedEntries(following: candidates)
        logLine("🎯 AI 总结阶段完成: 总计 \(orderedResults.count)/\(total) 封 (新分析 \(finalSnap.newlyAnalyzed), 缓存复用 \(finalSnap.reusedCache), 失败 \(finalSnap.failed))")

        // (D) Auto-flag unflagged Moxa emails in Apple Mail (preserving any existing user flags)
        var newlyFlaggedCount = 0
        if opts.applyFlags {
            newlyFlaggedCount = try applyMailFlagsIfNeeded(&orderedResults)
            logLine("🚩 Apple Mail 自动打标完成: 本次新增 7 色旗标 \(newlyFlaggedCount) 封")
        }

        // Ask Apple Mail to refresh visible message banners if MailKit accepts notification
        await reloadMailExtensionBanners()

        // (E) Write structured report JSON
        let totalFlaggedInMailCount = orderedResults.filter { $0.wasFlaggedInMail || $0.appliedFlagIndex != nil }.count
        if let reportPath = opts.reportJSONPath {
            let doc = BatchReportDocument(
                generatedAtISO: ISO8601DateFormatter().string(from: Date()),
                providerName: magpieProfile.name,
                providerBaseURL: magpieProfile.normalizedBaseURL,
                modelName: modelName,
                targetCount: opts.limit,
                collectedCount: candidates.count,
                analyzedNewCount: finalSnap.newlyAnalyzed,
                reusedCacheCount: finalSnap.reusedCache,
                failedCount: finalSnap.failed,
                newlyFlaggedCount: newlyFlaggedCount,
                totalFlaggedInMailCount: totalFlaggedInMailCount,
                skipStats: skipStats,
                mailboxDistribution: mailboxDist,
                entries: orderedResults
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let outURL = URL(fileURLWithPath: reportPath)
            try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(doc)
            try data.write(to: outURL, options: .atomic)
            logLine("📄 已写出结构化报告 JSON: \(reportPath)")
        }
    }

    // MARK: - (A) Magpie Config & Keychain

    private static func findSharedAppGroupContainer() -> URL? {
        let groupContainersDir = URL(
            fileURLWithPath: "\(NSHomeDirectory())/Library/Group Containers",
            isDirectory: true
        )
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: groupContainersDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return entries.first { url in
            url.lastPathComponent.hasSuffix(".\(SharedAppGroup.groupSuffix)")
        }
    }

    private static func loadAndValidateMagpieConfig() throws -> (AIProviderProfile, String) {
        var candidatePlists: [String] = []
        if let groupURL = findSharedAppGroupContainer() {
            let groupID = groupURL.lastPathComponent
            let groupPlist = groupURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Preferences", isDirectory: true)
                .appendingPathComponent("\(groupID).plist", isDirectory: false)
                .path
            candidatePlists.append(groupPlist)
        }
        candidatePlists.append(extensionPlistPath)

        var lastError: Error?
        for plistPath in candidatePlists {
            do {
                return try loadAndValidateMagpieConfig(fromPlistAt: plistPath)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? BatchCLIError.missingConfigPlist(extensionPlistPath)
    }

    private static func loadAndValidateMagpieConfig(fromPlistAt plistPath: String) throws -> (AIProviderProfile, String) {
        let plistURL = URL(fileURLWithPath: plistPath)
        guard FileManager.default.fileExists(atPath: plistURL.path),
              let dict = NSDictionary(contentsOf: plistURL) as? [String: Any]
        else {
            throw BatchCLIError.missingConfigPlist(plistPath)
        }

        guard let profilesData = dict[AIProviderStore.profilesDefaultsKey] as? Data,
              let profiles = try? JSONDecoder().decode([AIProviderProfile].self, from: profilesData),
              !profiles.isEmpty
        else {
            throw BatchCLIError.missingMagpieProfile("无法解码 \(AIProviderStore.profilesDefaultsKey)")
        }

        let activeID = (dict[AIProviderStore.activeProfileIDDefaultsKey] as? String) ?? ""
        let activeMatch = profiles.first(where: { $0.id == activeID })
        let magpieMatch: AIProviderProfile?
        if let active = activeMatch,
           active.kind != .vertexAI && !active.baseURL.lowercased().contains("googleapis.com")
        {
            magpieMatch = active
        } else {
            magpieMatch = profiles.first {
                $0.name.localizedCaseInsensitiveContains("Magpie") || $0.baseURL.contains("192.168.50.60:3425")
            }
        }

        guard let profile = magpieMatch else {
            throw BatchCLIError.missingMagpieProfile("profiles 中无 Magpie 节点")
        }

        // Hard safety guard: strictly forbid Vertex AI
        guard profile.kind != .vertexAI && !profile.baseURL.lowercased().contains("googleapis.com") else {
            throw BatchCLIError.vertexForbidden("kind=\(profile.kind.rawValue), baseURL=\(profile.baseURL)")
        }

        let account = KeychainStore.accountName(forProfileID: profile.id)
        if let cliKey = loadKeyViaSecurityCLI(service: KeychainStore.defaultService, account: account),
           !cliKey.isEmpty
        {
            return (profile, cliKey)
        }

        throw BatchCLIError.missingAPIKey("service=\(KeychainStore.defaultService), account=\(account)")
    }

    private static func loadKeyViaSecurityCLI(service: String, account: String) -> String? {
        guard let result = try? runSubprocess(
            executablePath: "/usr/bin/security",
            arguments: ["find-generic-password", "-s", service, "-a", account, "-w"],
            stdinData: nil
        ),
        result.terminationStatus == 0
        else {
            return nil
        }
        let key = String(decoding: result.stdoutData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    // MARK: - (B) Read-Only EMLX Indexing & Envelope Index Filtering

    private static func buildEmlxIndex(under rootDir: URL) -> [Int64: URL] {
        var index: [Int64: (url: URL, isPartial: Bool)] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: rootDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            guard name.hasSuffix(".emlx") else { continue }
            if name.hasSuffix(".partial.emlx") {
                let rawID = String(name.dropLast(".partial.emlx".count))
                if let rowID = Int64(rawID), index[rowID] == nil {
                    index[rowID] = (fileURL, true)
                }
            } else {
                let rawID = String(name.dropLast(".emlx".count))
                if let rowID = Int64(rawID) {
                    index[rowID] = (fileURL, false)
                }
            }
        }
        return index.mapValues(\.url)
    }

    private static func collectValidMoxaCandidates(
        limit: Int,
        emlxIndex: [Int64: URL]
    ) throws -> ([CandidateEmail], [String: Int]) {
        var db: OpaquePointer?
        let openFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(envelopeIndexURI, &db, openFlags, nil) == SQLITE_OK, let db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 returned error"
            if let db { sqlite3_close(db) }
            throw BatchCLIError.sqliteOpenFailed(msg)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)

        let sql = """
        SELECT m.ROWID, m.date_received, mb.url, m.flagged, COALESCE(m.flag_color, -1), COALESCE(s.subject, ''), COALESCE(a.address, '')
        FROM messages m
        JOIN mailboxes mb ON m.mailbox = mb.ROWID
        LEFT JOIN subjects s ON m.subject = s.ROWID
        LEFT JOIN addresses a ON m.sender = a.ROWID
        WHERE m.deleted = 0
          AND mb.url LIKE 'ews://E94D4074-9E81-4F1D-9310-9E94C36EDEA2/%'
          AND mb.url NOT LIKE '%/%E5%B7%B2%E5%8F%91%E9%80%81%'
          AND mb.url NOT LIKE '%/%E8%8D%89%E7%A8%BF%'
          AND mb.url NOT LIKE '%/%E5%B7%B2%E5%88%A0%E9%99%A4%'
          AND mb.url NOT LIKE '%/%E5%9E%83%E5%9C%BE%'
          AND mb.url NOT LIKE '%/%E6%97%A5%E5%8E%86%'
          AND mb.url NOT LIKE '%/%E5%86%B2%E7%AA%81%'
          AND mb.url NOT LIKE '%/%E5%90%8C%E6%AD%A5%E9%97%AE%E9%A2%98%'
          AND mb.url NOT LIKE '%/%E5%AF%B9%E8%AF%9D%E5%8E%86%E5%8F%B2%'
        ORDER BY m.date_received DESC
        LIMIT 3000;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw BatchCLIError.sqliteQueryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current

        var candidates: [CandidateEmail] = []
        candidates.reserveCapacity(limit)
        var seenMessageIDs: Set<String> = []
        var skipStats: [String: Int] = [:]

        while sqlite3_step(stmt) == SQLITE_ROW {
            if candidates.count >= limit { break }

            let rowID = sqlite3_column_int64(stmt, 0)
            let dateUnix = sqlite3_column_int64(stmt, 1)
            let mailboxURL = columnString(stmt, 2)
            let flagged = sqlite3_column_int(stmt, 3) != 0
            let flagColor = Int(sqlite3_column_int(stmt, 4))
            let sqlSubject = columnString(stmt, 5)
            let sqlSender = columnString(stmt, 6)

            guard let emlxURL = emlxIndex[rowID] else {
                skipStats["missingEmlx", default: 0] += 1
                continue
            }

            guard let rfcData = extractRFCDataFromEmlx(at: emlxURL),
                  !rfcData.isEmpty
            else {
                skipStats["unreadableEmlx", default: 0] += 1
                continue
            }

            guard rfcData.count <= maxPassthroughRawBytes else {
                skipStats["oversizeRaw", default: 0] += 1
                continue
            }

            guard !MIMEParser.isProtectedSecurityEnvelope(rfcData) else {
                skipStats["protectedEnvelope", default: 0] += 1
                continue
            }

            let headers = MIMEParser.extractTopLevelHeaders(rfcData)
            let msgDate = Date(timeIntervalSince1970: TimeInterval(dateUnix))
            let filterInput = MessageFilterInput(
                isReceivedState: true,
                isEncrypted: false,
                subject: sqlSubject,
                fromAddress: sqlSender,
                dateReceived: msgDate,
                headers: headers
            )

            // Pass now: msgDate to apply full Moxa Primary rules while preserving historical emails
            if case let .skip(reason) = MoxaPrimaryFilter.evaluate(filterInput, now: msgDate) {
                skipStats[reason.logDescription, default: 0] += 1
                continue
            }

            let parsed = MIMEParser.parse(rawData: rfcData)
            let hasContent = !parsed.plainBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !parsed.quotedChain.isEmpty
            guard hasContent else {
                skipStats["emptyBody", default: 0] += 1
                continue
            }

            let normID = ParsedEmailContext.normalizeMessageID(parsed.messageID).lowercased()
            guard !normID.isEmpty else {
                skipStats["emptyMessageID", default: 0] += 1
                continue
            }
            guard seenMessageIDs.insert(normID).inserted else {
                skipStats["duplicateMessageID", default: 0] += 1
                continue
            }

            let mailboxName = decodedMailboxName(from: mailboxURL)
            candidates.append(
                CandidateEmail(
                    rowID: rowID,
                    dateReceivedUnix: dateUnix,
                    dateReceivedISO: isoFormatter.string(from: msgDate),
                    mailboxURL: mailboxURL,
                    mailboxName: mailboxName,
                    wasFlaggedInMail: flagged,
                    existingFlagColor: flagColor,
                    sqlSubject: sqlSubject,
                    sqlSender: sqlSender,
                    parsed: parsed
                )
            )
        }

        return (candidates, skipStats)
    }

    private static func extractRFCDataFromEmlx(at url: URL) -> Data? {
        guard let fileData = try? Data(contentsOf: url, options: .mappedIfSafe),
              let nlIndex = fileData.firstIndex(of: 0x0A)
        else {
            return nil
        }
        let lengthStr = String(decoding: fileData[..<nlIndex], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let byteCount = Int(lengthStr), byteCount > 0 else {
            return nil
        }
        let bodyStart = fileData.index(after: nlIndex)
        guard bodyStart < fileData.endIndex else { return nil }
        let available = fileData.distance(from: bodyStart, to: fileData.endIndex)
        let sliceLen = min(byteCount, available)
        let bodyEnd = fileData.index(bodyStart, offsetBy: sliceLen)
        return Data(fileData[bodyStart..<bodyEnd])
    }

    private static func decodedMailboxName(from mailboxURL: String) -> String {
        guard let range = mailboxURL.range(of: moxaAccountPrefix) else { return mailboxURL }
        let rawSub = String(mailboxURL[range.upperBound...])
        return rawSub.removingPercentEncoding ?? rawSub
    }

    private static func columnString(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let cStr = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cStr)
    }

    // MARK: - (C) Magpie Retry Wrapper & Result Shaping

    private static func analyzeWithRetry(
        email: ParsedEmailContext,
        profile: AIProviderProfile,
        apiKey: String,
        aiClient: AIServiceClient
    ) async throws -> EmailAIAnalysis {
        let backoffSeconds: [UInt64] = [2, 5, 12]
        var lastError: Error?

        for attempt in 0...backoffSeconds.count {
            try Task.checkCancellation()
            do {
                return try await aiClient.analyzeEmail(
                    email,
                    profile: profile,
                    tier: .fast,
                    apiKeyOverride: apiKey
                )
            } catch {
                lastError = error
                if isFatalAuthOrQuotaError(error) || attempt == backoffSeconds.count {
                    throw error
                }
                let delay = backoffSeconds[attempt]
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            }
        }
        throw lastError ?? AIServiceError.invalidResponse
    }

    private static func isFatalAuthOrQuotaError(_ error: Error) -> Bool {
        if case let AIServiceError.httpError(statusCode, message) = error {
            if statusCode == 401 || statusCode == 403 {
                return true
            }
            let lower = message.lowercased()
            if statusCode == 402 || lower.contains("insufficient quota") || lower.contains("invalid api key") {
                return true
            }
        }
        return false
    }

    private static func makeResultEntry(
        candidate: CandidateEmail,
        analysis: EmailAIAnalysis,
        wasAlreadyCached: Bool
    ) -> BatchEmailResult {
        let subj = candidate.parsed.subject.isEmpty ? candidate.sqlSubject : candidate.parsed.subject
        let sender = candidate.parsed.from.isEmpty ? candidate.sqlSender : candidate.parsed.from
        return BatchEmailResult(
            rowID: candidate.rowID,
            messageID: candidate.parsed.messageID,
            dateReceivedUnix: candidate.dateReceivedUnix,
            dateReceivedISO: candidate.dateReceivedISO,
            mailboxURL: candidate.mailboxURL,
            mailboxName: candidate.mailboxName,
            subject: subj,
            from: sender,
            wasFlaggedInMail: candidate.wasFlaggedInMail,
            existingFlagColor: candidate.existingFlagColor,
            wasAlreadyCached: wasAlreadyCached,
            appliedFlagName: nil,
            appliedFlagIndex: nil,
            analysis: analysis,
            plainHeadline: MailHighlightedText.plainText(analysis.headline).trimmingCharacters(in: .whitespacesAndNewlines),
            plainConclusions: analysis.coreConclusions.map {
                MailHighlightedText.plainText($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        )
    }

    // MARK: - (D) Apple Mail 7-Color Auto-Flagging (Unflagged Only)

    private static func mailFlagIndex(for category: MailFlagCategory) -> Int? {
        switch category {
        case .red: return 0
        case .orange: return 1
        case .yellow: return 2
        case .green: return 3
        case .blue: return 4
        case .purple: return 5
        case .gray: return 6
        case .none: return nil
        }
    }

    private static func applyMailFlagsIfNeeded(_ entries: inout [BatchEmailResult]) throws -> Int {
        // Group indices in `entries` by mailboxName for fast batch index lookup inside each mailbox
        var indicesByMailbox: [String: [Int]] = [:]
        for idx in entries.indices {
            let entry = entries[idx]
            guard !entry.wasFlaggedInMail,
                  mailFlagIndex(for: entry.analysis.resolvedFlag) != nil
            else {
                continue
            }
            indicesByMailbox[entry.mailboxName, default: []].append(idx)
        }

        guard !indicesByMailbox.isEmpty else {
            logLine("ℹ️ 无需新增旗标（均已有旗标或判定为无旗标）")
            return 0
        }

        let totalCandidates = indicesByMailbox.values.reduce(0) { $0 + $1.count }
        logLine("🏷️ 准备为 \(totalCandidates) 封未打标邮件写入 Apple Mail 7 色旗标（分布在 \(indicesByMailbox.count) 个邮箱目录）...")

        var totalFlagged = 0

        for (mailboxName, entryIndices) in indicesByMailbox.sorted(by: { $0.key < $1.key }) {
            let chunkSize = 15
            var doneInMailbox = 0
            var mailboxNewlyFlagged = 0
            let totalInMailbox = entryIndices.count

            for start in stride(from: 0, to: entryIndices.count, by: chunkSize) {
                let entrySlice = Array(entryIndices[start..<min(start + chunkSize, entryIndices.count)])
                // Refresh ordered ROWID mapping before every small chunk (2.2s even for 45k Archive)
                let orderedIDs = try fetchOrderedMessageIDs(forMailbox: mailboxName)
                var positionByRowID: [Int64: Int] = [:]
                positionByRowID.reserveCapacity(orderedIDs.count)
                for (offset, rowID) in orderedIDs.enumerated() {
                    positionByRowID[rowID] = offset + 1 // AppleScript lists are 1-based
                }

                var chunkTargets: [(entryIndex: Int, position: Int, rowID: Int64, flagIndex: Int, flagName: String)] = []
                var unmappedCount = 0
                for entryIdx in entrySlice {
                    let rowID = entries[entryIdx].rowID
                    let flagCat = entries[entryIdx].analysis.resolvedFlag
                    guard let pos = positionByRowID[rowID],
                          let flagIdx = mailFlagIndex(for: flagCat)
                    else {
                        unmappedCount += 1
                        continue
                    }
                    chunkTargets.append((entryIdx, pos, rowID, flagIdx, flagCat.label))
                }

                let batchReport = chunkTargets.isEmpty
                    ? FlagBatchOutcome()
                    : try executeFlagBatch(mailboxName: mailboxName, batch: chunkTargets)

                for item in chunkTargets where batchReport.okIDs.contains(item.rowID) {
                    entries[item.entryIndex].appliedFlagIndex = item.flagIndex
                    entries[item.entryIndex].appliedFlagName = item.flagName
                    totalFlagged += 1
                    mailboxNewlyFlagged += 1
                }

                doneInMailbox += entrySlice.count
                logLine("   [\(mailboxName) \(doneInMailbox)/\(totalInMailbox)] ok=\(batchReport.okIDs.count), already=\(batchReport.alreadyIDs.count), miss=\(batchReport.missIDs.count + unmappedCount), err=\(batchReport.errors.count)")
                if !batchReport.errors.isEmpty {
                    logLine("      ⚠️ 打标报错样本: \(batchReport.errors.prefix(3).joined(separator: " | "))")
                }
                Thread.sleep(forTimeInterval: 0.3)
            }
            logLine("   ✓ 邮箱「\(mailboxName)」打标完成 (新增 \(mailboxNewlyFlagged)/\(totalInMailbox))")
        }

        return totalFlagged
    }

    private struct FlagBatchOutcome {
        var okIDs: Set<Int64> = []
        var alreadyIDs: Set<Int64> = []
        var missIDs: [Int64] = []
        var errors: [String] = []
    }

    private static func appleScriptMailboxExpr(for mailboxName: String) -> String {
        let escapedFull = escapeAppleScriptString(mailboxName)
        let components = mailboxName.split(separator: "/").map(String.init)
        if components.count <= 1 {
            return "mailbox \"\(escapedFull)\" of acct"
        }
        // Try path literal first; fallback built into resolveTargetMailbox script
        return "mailbox \"\(escapedFull)\" of acct"
    }

    private static func appleScriptResolveMailboxBlock(for mailboxName: String) -> String {
        let escapedFull = escapeAppleScriptString(mailboxName)
        let components = mailboxName.split(separator: "/").map(String.init)
        var nested = "acct"
        for comp in components {
            nested = "mailbox \"\(escapeAppleScriptString(comp))\" of (\(nested))"
        }
        if components.count <= 1 {
            return """
            set targetMb to mailbox "\(escapedFull)" of acct
            """
        }
        return """
        set targetMb to missing value
        try
            set targetMb to mailbox "\(escapedFull)" of acct
        on error
            set targetMb to \(nested)
        end try
        """
    }

    private static func fetchOrderedMessageIDs(forMailbox mailboxName: String) throws -> [Int64] {
        let script = """
        with timeout of 120 seconds
            tell application "Mail"
                set acct to account "公司邮箱"
                \(appleScriptResolveMailboxBlock(for: mailboxName))
                set idList to id of every message of targetMb
                set AppleScript's text item delimiters to ","
                set joinedText to idList as text
                set AppleScript's text item delimiters to ""
                return joinedText
            end tell
        end timeout
        """
        let output = try runAppleScript(script)
        return output
            .split(separator: ",")
            .compactMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private static func executeFlagBatch(
        mailboxName: String,
        batch: [(entryIndex: Int, position: Int, rowID: Int64, flagIndex: Int, flagName: String)]
    ) throws -> FlagBatchOutcome {
        var perItemLines: [String] = []
        perItemLines.reserveCapacity(batch.count)
        for item in batch {
            perItemLines.append("""
            try
                set targetPos to \(item.position)
                set m to missing value
                set cand to message targetPos of targetMb
                if id of cand is \(item.rowID) then
                    set m to cand
                else
                    set totalMsgs to count of messages of targetMb
                    set loIdx to targetPos - 5
                    if loIdx < 1 then set loIdx to 1
                    set hiIdx to targetPos + 5
                    if hiIdx > totalMsgs then set hiIdx to totalMsgs
                    repeat with k from loIdx to hiIdx
                        if k is not targetPos then
                            set nearMsg to message k of targetMb
                            if id of nearMsg is \(item.rowID) then
                                set m to nearMsg
                                exit repeat
                            end if
                        end if
                    end repeat
                end if
                if m is missing value then
                    set end of outLines to "miss:\(item.rowID)"
                else
                    if flagged status of m is false then
                        set flag index of m to \(item.flagIndex)
                        set end of outLines to "ok:\(item.rowID)"
                    else
                        set end of outLines to "already:\(item.rowID)"
                    end if
                end if
            on error errMsg number errNum
                set end of outLines to ("err:\(item.rowID):" & errNum & ":" & errMsg)
            end try
            """)
        }

        let script = """
        with timeout of 300 seconds
            tell application "Mail"
                set acct to account "公司邮箱"
                \(appleScriptResolveMailboxBlock(for: mailboxName))
                set outLines to {}
                \(perItemLines.joined(separator: "\n                "))
                set AppleScript's text item delimiters to linefeed
                set outText to outLines as text
                set AppleScript's text item delimiters to ""
                return outText
            end tell
        end timeout
        """
        let output = try runAppleScript(script)
        var outcome = FlagBatchOutcome()
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("ok:"), let rid = Int64(line.dropFirst(3)) {
                outcome.okIDs.insert(rid)
            } else if line.hasPrefix("already:"), let rid = Int64(line.dropFirst(8)) {
                outcome.alreadyIDs.insert(rid)
            } else if line.hasPrefix("miss:"), let rid = Int64(line.dropFirst(5)) {
                outcome.missIDs.append(rid)
            } else if !line.isEmpty {
                outcome.errors.append(line)
            }
        }
        return outcome
    }

    private final class LockedDataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func set(_ data: Data) {
            lock.lock()
            storage = data
            lock.unlock()
        }

        func get() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private static func runSubprocess(
        executablePath: String,
        arguments: [String],
        stdinData: Data?
    ) throws -> (terminationStatus: Int32, stdoutData: Data, stderrData: Data) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = arguments

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        try proc.run()

        // Drain stdout & stderr concurrently BEFORE waitUntilExit() to avoid 64KB Pipe buffer deadlocks.
        let outBox = LockedDataBox()
        let errBox = LockedDataBox()
        let drainGroup = DispatchGroup()

        drainGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outBox.set(outPipe.fileHandleForReading.readDataToEndOfFile())
            drainGroup.leave()
        }

        drainGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile())
            drainGroup.leave()
        }

        if let stdinData, !stdinData.isEmpty {
            try inPipe.fileHandleForWriting.write(contentsOf: stdinData)
        }
        try inPipe.fileHandleForWriting.close()

        proc.waitUntilExit()
        drainGroup.wait()

        return (proc.terminationStatus, outBox.get(), errBox.get())
    }

    private static func runAppleScript(_ script: String) throws -> String {
        let result = try runSubprocess(
            executablePath: "/usr/bin/osascript",
            arguments: ["-"],
            stdinData: script.data(using: .utf8)
        )
        let outText = String(decoding: result.stdoutData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let errText = String(decoding: result.stderrData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if result.terminationStatus != 0 {
            let lowerErr = errText.lowercased()
            if lowerErr.contains("not authorized") || lowerErr.contains("-1743") || lowerErr.contains("not allowed assistive") {
                throw BatchCLIError.appleScriptPermissionDenied(errText)
            }
            throw BatchCLIError.appleScriptPermissionDenied("osascript exit \(result.terminationStatus): \(errText)")
        }
        return outText
    }

    private static func escapeAppleScriptString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Reload Banners & Logging Helpers

    private static func reloadMailExtensionBanners() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var completed = false
            let lock = NSLock()
            func finishOnce() {
                lock.lock()
                let shouldResume = !completed
                completed = true
                lock.unlock()
                if shouldResume {
                    continuation.resume()
                }
            }

            MEExtensionManager.reloadVisibleMessages { error in
                if let error {
                    logLine("ℹ️ 刷新 Apple Mail 可见横幅返回提示: \(error.localizedDescription)")
                } else {
                    logLine("🔄 已通知 Apple Mail 重新加载可见邮件横幅。")
                }
                finishOnce()
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 4.0) {
                finishOnce()
            }
        }
    }

    private static func formatCounts(_ dict: [String: Int]) -> String {
        dict.sorted { $0.value > $1.value }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
    }

    private static func logLine(_ message: String) {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        let stamp = df.string(from: Date())
        print("[\(stamp)] \(message)")
        fflush(stdout)
    }
}
