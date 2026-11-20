import CryptoKit
import Darwin
import Foundation
import OSLog
import SQLite3

public enum AttachmentFilingConflict: Equatable, Sendable, Hashable {
    case none
    case identicalAlreadyExists(existingURL: URL)
    case renamedToAvoidOverwrite(suggestedFilename: String)
}

public struct AttachmentFilingPlanItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let payloadID: String
    public let originalFilename: String
    public var proposedRelativeFolder: String
    public var proposedFilename: String
    public var reason: String
    public var confidence: String
    public var conflict: AttachmentFilingConflict
    public var isSelected: Bool
    public var candidateFolders: [String]

    public var effectiveFilename: String {
        if case let .renamedToAvoidOverwrite(suggestedFilename) = conflict,
           !suggestedFilename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return suggestedFilename
        }
        return proposedFilename
    }

    public var destinationRelativePath: String {
        let trimmedFolder = proposedRelativeFolder.hasSuffix("/")
            ? String(proposedRelativeFolder.dropLast())
            : proposedRelativeFolder
        return trimmedFolder.isEmpty ? effectiveFilename : "\(trimmedFolder)/\(effectiveFilename)"
    }

    public init(
        id: String? = nil,
        payloadID: String,
        originalFilename: String,
        proposedRelativeFolder: String,
        proposedFilename: String,
        reason: String = "",
        confidence: String = "medium",
        conflict: AttachmentFilingConflict = .none,
        isSelected: Bool = true,
        candidateFolders: [String] = []
    ) {
        self.id = id ?? payloadID
        self.payloadID = payloadID
        self.originalFilename = originalFilename
        self.proposedRelativeFolder = proposedRelativeFolder
        self.proposedFilename = proposedFilename
        self.reason = reason
        self.confidence = confidence
        self.conflict = conflict
        self.isSelected = isSelected
        self.candidateFolders = candidateFolders
    }
}

public enum AttachmentOrganizerError: LocalizedError, Equatable, Sendable {
    case invalidWorkspaceRoot(URL)
    case unsafeRelativePath(String)
    case hiddenDirectoryForbidden(String)
    case symlinkEscapeDetected(String)
    case missingPayload(String)
    case destinationCollisionExhausted(String)
    case writeFailed(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidWorkspaceRoot(url):
            return "工作区根目录无效或不存在：\(url.path)"
        case let .unsafeRelativePath(path):
            return "拒绝不安全的相对路径（不允许绝对路径、空段或 `..` 跳转）：\(path)"
        case let .hiddenDirectoryForbidden(path):
            return "安全红线拦截：禁止读取或写入隐藏目录（如 `.moxa-kb`）：\(path)"
        case let .symlinkEscapeDetected(path):
            return "安全红线拦截：检测到符号链接越界到工作区外部：\(path)"
        case let .missingPayload(payloadID):
            return "未找到待归档附件的内存数据（payloadID=\(payloadID)）。"
        case let .destinationCollisionExhausted(path):
            return "无法为目标文件分配不冲突的文件名：\(path)"
        case let .writeFailed(path, reason):
            return "写入附件失败（\(path)）：\(reason)"
        }
    }
}

/// Discovers Moxa/workspace folders safely, proposes attachment filing destinations,
/// detects SHA-256 duplicates / name collisions, and writes attachments atomically without overwriting.
public final class AttachmentOrganizerService: Sendable {
    public static let shared = AttachmentOrganizerService()

    private struct CandidateFolderMeta: Sendable {
        let relativePath: String
        let depth: Int
        var existsOnDisk: Bool
        var projects: Set<String> = []
        var skus: Set<String> = []
        var standards: Set<String> = []
        var docTypes: Set<String> = []
        var fileCount: Int = 0
    }

    private struct FolderScoreResult: Sendable {
        let relativePath: String
        let score: Int
        let reasons: [String]
    }

    private struct AIRouterResponse: Decodable {
        struct Item: Decodable {
            let payloadID: String?
            let filename: String?
            let folder: String?
            let reason: String?
            let confidence: String?
        }
        let items: [Item]?
        let assignments: [Item]?
    }

    private let aiTimeoutSeconds: TimeInterval

    private static let skuRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\b([A-Z]{2,5}[- ]?\d{3,4}[A-Z0-9]*(?:-[A-Z0-9]+)*)\b"#,
        options: [.caseInsensitive]
    )

    private static let standardAliases: [(canonical: String, patterns: [String])] = [
        ("62443", ["62443", "iec 62443", "iec62443", "iec-62443", "62443-4-2", "62443-4-1", "62443-3-3"]),
        ("en50155", ["en 50155", "en50155", "en-50155", "50155"]),
        ("en50121", ["en 50121", "en50121", "en-50121", "50121"]),
        ("en45545", ["en 45545", "en45545", "en-45545", "45545"]),
        ("iec61375", ["61375", "iec 61375", "iec61375", "trdp"]),
        ("enisa", ["enisa", "srp", "nis2"]),
        ("cra", ["cra", "cyber resilience act"]),
        ("63452", ["63452", "iec 63452", "iec63452"])
    ]

    private static let securityKeywords: [String] = [
        "enisa", "srp", "62443", "cra", "63452", "信息安全", "网络安全",
        "漏洞", "vulnerability", "cyber", "security", "psirt", "nis2", "ccop"
    ]

    private static let pricingKeywords: [String] = [
        "报价", "特价", "核价", "询价", "单价", "价格", "折扣", "目标价",
        "quote", "quotation", "pricing", "price", "spr", "discount", "rfq"
    ]

    public init(aiTimeoutSeconds: TimeInterval = 5.0) {
        self.aiTimeoutSeconds = max(0.1, aiTimeoutSeconds)
    }

    // MARK: - Public API

    /// Proposes filing destinations for extracted attachments by combining deterministic scoring
    /// (live 2-level directory scan + optional read-only runtime `moxa_kb.sqlite` clues)
    /// and optional AI refinement over the top 25 candidate folders.
    public func proposeFilingPlan(
        payloads: [ExtractedAttachmentPayload],
        email: ParsedEmailContext,
        analysis: EmailAIAnalysis?,
        workspaceRootURL: URL,
        runtimeMoxaDBPath: String? = nil,
        aiRouter: (@Sendable (_ systemPrompt: String, _ userPrompt: String) async throws -> String)? = nil
    ) async -> [AttachmentFilingPlanItem] {
        guard !payloads.isEmpty else { return [] }

        let discovery = await Task.detached(priority: .userInitiated) { [workspaceRootURL, runtimeMoxaDBPath] in
            Self.discoverCandidateFolders(
                workspaceRootURL: workspaceRootURL,
                runtimeMoxaDBPath: runtimeMoxaDBPath
            )
        }.value

        let orderedCandidates = discovery.values.sorted { lhs, rhs in
            if lhs.existsOnDisk != rhs.existsOnDisk {
                return lhs.existsOnDisk && !rhs.existsOnDisk
            }
            if lhs.fileCount != rhs.fileCount {
                return lhs.fileCount > rhs.fileCount
            }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }

        let allFolderPaths = orderedCandidates.map(\.relativePath)
        var initialItems: [AttachmentFilingPlanItem] = []
        var unionTopFolders: [String] = []
        var seenTopFolders = Set<String>()

        for payload in payloads {
            let scored = Self.scoreCandidates(
                orderedCandidates,
                payload: payload,
                email: email,
                analysis: analysis
            )

            var perItemCandidates: [String] = []
            var seenPerItem = Set<String>()
            for entry in scored.prefix(25) {
                if seenPerItem.insert(entry.relativePath).inserted {
                    perItemCandidates.append(entry.relativePath)
                }
                if seenTopFolders.insert(entry.relativePath).inserted {
                    unionTopFolders.append(entry.relativePath)
                }
            }
            for fallbackPath in allFolderPaths where perItemCandidates.count < 25 {
                if seenPerItem.insert(fallbackPath).inserted {
                    perItemCandidates.append(fallbackPath)
                }
                if seenTopFolders.count < 25, seenTopFolders.insert(fallbackPath).inserted {
                    unionTopFolders.append(fallbackPath)
                }
            }

            let best = scored.first
            let chosenFolder = best?.relativePath ?? ""
            let bestScore = best?.score ?? 0
            let reasonText: String
            if let best, !best.reasons.isEmpty {
                reasonText = best.reasons.joined(separator: " · ")
            } else if chosenFolder.isEmpty {
                reasonText = "工作区暂无子目录，将暂存于根目录"
            } else {
                reasonText = "默认匹配工作区目录"
            }

            let confidence: String
            if bestScore >= 55 {
                confidence = "high"
            } else if bestScore >= 22 {
                confidence = "medium"
            } else {
                confidence = "low"
            }

            let safeFilename = Self.sanitizeTargetFilename(payload.filename)
            let draftItem = AttachmentFilingPlanItem(
                payloadID: payload.id,
                originalFilename: payload.filename,
                proposedRelativeFolder: chosenFolder,
                proposedFilename: safeFilename,
                reason: reasonText,
                confidence: confidence,
                conflict: .none,
                isSelected: true,
                candidateFolders: perItemCandidates
            )
            initialItems.append(
                refreshConflictStatus(for: draftItem, payload: payload, workspaceRootURL: workspaceRootURL)
            )
        }

        // Optional AI refinement over top 25 candidate folders with strict timeout fallback.
        guard let aiRouter, !unionTopFolders.isEmpty else {
            return initialItems
        }

        let top25ForAI = Array(unionTopFolders.prefix(25))
        let allowedFolderSet = Set(top25ForAI)
        let (systemPrompt, userPrompt) = Self.buildAIRouterPrompts(
            payloads: payloads,
            initialItems: initialItems,
            email: email,
            analysis: analysis,
            candidateFolders: top25ForAI
        )

        guard let aiRaw = await Self.invokeAIRouterWithTimeout(
            timeoutSeconds: aiTimeoutSeconds,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            aiRouter: aiRouter
        ) else {
            return initialItems
        }

        let overrides = Self.parseAIRouterOverrides(aiRaw, allowedFolders: allowedFolderSet)
        guard !overrides.isEmpty else {
            return initialItems
        }

        let payloadByID = Dictionary(uniqueKeysWithValues: payloads.map { ($0.id, $0) })
        return initialItems.map { item in
            guard let override = overrides[item.payloadID] ?? overrides[item.originalFilename],
                  let folder = override.folder,
                  allowedFolderSet.contains(folder),
                  (try? Self.validateRelativeFolder(folder)) != nil
            else {
                return item
            }

            var updated = item
            updated.proposedRelativeFolder = folder
            if let reason = override.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
                updated.reason = reason
            }
            if let conf = override.confidence?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               ["high", "medium", "low"].contains(conf)
            {
                updated.confidence = conf
            }

            if let payload = payloadByID[item.payloadID] {
                return refreshConflictStatus(for: updated, payload: payload, workspaceRootURL: workspaceRootURL)
            }
            return updated
        }
    }

    /// Recomputes `.none`, `.identicalAlreadyExists`, or `.renamedToAvoidOverwrite`
    /// for `item` against current disk state in `workspaceRootURL`.
    public func refreshConflictStatus(
        for item: AttachmentFilingPlanItem,
        payload: ExtractedAttachmentPayload,
        workspaceRootURL: URL
    ) -> AttachmentFilingPlanItem {
        var updated = item
        guard let canonicalRoot = try? Self.validateWorkspaceRoot(workspaceRootURL),
              let folderSegments = try? Self.validateRelativeFolder(item.proposedRelativeFolder),
              let safeFilename = try? Self.validateTargetFilename(item.proposedFilename)
        else {
            updated.conflict = .none
            return updated
        }

        guard let folderURL = try? Self.resolveFolderCheckingExistingSymlinks(
            root: canonicalRoot,
            segments: folderSegments
        ) else {
            updated.conflict = .none
            return updated
        }

        let targetSHA = payload.sha256Hex.isEmpty
            ? MIMEAttachmentExtractor.sha256Hex(of: payload.data)
            : payload.sha256Hex

        updated.conflict = Self.inspectDestinationConflict(
            inFolder: folderURL,
            canonicalRoot: canonicalRoot,
            desiredFilename: safeFilename,
            payloadSHA256: targetSHA
        )
        return updated
    }

    /// Validates all relative paths against traversal/hidden/symlink redlines,
    /// skips files whose destination already has an identical SHA-256 (returning the existing URL),
    /// and writes new or renamed files atomically without ever overwriting existing files.
    public func executeFilingPlan(
        items: [AttachmentFilingPlanItem],
        payloads: [ExtractedAttachmentPayload],
        workspaceRootURL: URL
    ) throws -> [URL] {
        let canonicalRoot = try Self.validateWorkspaceRoot(workspaceRootURL)
        let payloadMap = Dictionary(uniqueKeysWithValues: payloads.map { ($0.id, $0) })

        var results: [URL] = []

        for item in items where item.isSelected {
            guard let payload = payloadMap[item.payloadID] else {
                throw AttachmentOrganizerError.missingPayload(item.payloadID)
            }

            let folderSegments = try Self.validateRelativeFolder(item.proposedRelativeFolder)
            let baseFilename = try Self.validateTargetFilename(item.proposedFilename)
            let desiredFilename: String
            if case let .renamedToAvoidOverwrite(suggested) = item.conflict,
               !suggested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                desiredFilename = try Self.validateTargetFilename(suggested)
            } else {
                desiredFilename = baseFilename
            }

            let folderURL = try Self.ensureSafeDirectory(
                root: canonicalRoot,
                segments: folderSegments
            )

            let payloadSHA = payload.sha256Hex.isEmpty
                ? MIMEAttachmentExtractor.sha256Hex(of: payload.data)
                : payload.sha256Hex

            let conflict = Self.inspectDestinationConflict(
                inFolder: folderURL,
                canonicalRoot: canonicalRoot,
                desiredFilename: desiredFilename,
                payloadSHA256: payloadSHA
            )

            switch conflict {
            case let .identicalAlreadyExists(existingURL):
                results.append(existingURL)
                continue
            case let .renamedToAvoidOverwrite(suggestedFilename):
                let safeSuggested = try Self.validateTargetFilename(suggestedFilename)
                let destURL = folderURL.appendingPathComponent(safeSuggested, isDirectory: false)
                try Self.writeAtomicallyWithoutOverwriting(
                    data: payload.data,
                    to: destURL,
                    canonicalRoot: canonicalRoot
                )
                results.append(destURL)
            case .none:
                let destURL = folderURL.appendingPathComponent(desiredFilename, isDirectory: false)
                try Self.writeAtomicallyWithoutOverwriting(
                    data: payload.data,
                    to: destURL,
                    canonicalRoot: canonicalRoot
                )
                results.append(destURL)
            }
        }

        return results
    }

    // MARK: - Candidate Folder Discovery (SQLite Read-Only + Live Scan)

    private static func discoverCandidateFolders(
        workspaceRootURL: URL,
        runtimeMoxaDBPath: String?
    ) -> [String: CandidateFolderMeta] {
        var map: [String: CandidateFolderMeta] = [:]

        // 1. Live 2-level directory scan of workspaceRootURL (ignoring hidden '.' dirs & escaping symlinks).
        var liveTopDirs = Set<String>()
        var liveFoldersEmpty = true
        if let canonicalRoot = try? validateWorkspaceRoot(workspaceRootURL) {
            let l1Dirs = listSafeSubdirectories(in: canonicalRoot, canonicalRoot: canonicalRoot)
            for l1Name in l1Dirs {
                liveTopDirs.insert(l1Name)
                liveFoldersEmpty = false
                map[l1Name] = CandidateFolderMeta(
                    relativePath: l1Name,
                    depth: 1,
                    existsOnDisk: true
                )

                let l1URL = canonicalRoot.appendingPathComponent(l1Name, isDirectory: true)
                let l2Dirs = listSafeSubdirectories(in: l1URL, canonicalRoot: canonicalRoot)
                for l2Name in l2Dirs {
                    let rel2 = "\(l1Name)/\(l2Name)"
                    map[rel2] = CandidateFolderMeta(
                        relativePath: rel2,
                        depth: 2,
                        existsOnDisk: true
                    )
                }
            }
        }

        // 2. Read-only immutable SQLite clues from runtime moxa_kb.sqlite (NEVER .moxa-kb directly).
        let explicitDB = runtimeMoxaDBPath != nil
        if let resolvedDBPath = resolveSafeRuntimeDBPath(explicitPath: runtimeMoxaDBPath) {
            let sqliteRecords = loadFoldersFromRuntimeSQLite(atPath: resolvedDBPath)
            for (relFolder, meta) in sqliteRecords {
                let topDir = relFolder.split(separator: "/", maxSplits: 1).first.map(String.init) ?? relFolder
                let shouldInclude = map[relFolder] != nil
                    || explicitDB
                    || liveTopDirs.contains(topDir)
                    || liveFoldersEmpty

                guard shouldInclude else { continue }

                if var existing = map[relFolder] {
                    existing.projects.formUnion(meta.projects)
                    existing.skus.formUnion(meta.skus)
                    existing.standards.formUnion(meta.standards)
                    existing.docTypes.formUnion(meta.docTypes)
                    existing.fileCount += meta.fileCount
                    map[relFolder] = existing
                } else {
                    map[relFolder] = meta
                }
            }
        }

        return map
    }

    private static func listSafeSubdirectories(in directory: URL, canonicalRoot: URL) -> [String] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var names: [String] = []
        for child in children {
            let name = child.lastPathComponent
            guard !name.isEmpty, !name.hasPrefix("."), name != ".", name != ".." else {
                continue
            }

            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                let resolved = child.resolvingSymlinksInPath().standardizedFileURL
                guard isPath(resolved.path, insideRoot: canonicalRoot.path) else {
                    continue
                }
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            names.append(name)
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func resolveSafeRuntimeDBPath(explicitPath: String?) -> String? {
        let candidates: [String]
        if let explicitPath {
            let expanded = (explicitPath as NSString).expandingTildeInPath
            candidates = [expanded]
        } else {
            let homeRuntime = (NSString(string: "~/.cache/moxa-kb-runtime/moxa_kb.sqlite")).expandingTildeInPath
            let realHomeRuntime: String? = {
                guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return nil }
                return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
                    .appendingPathComponent(".cache/moxa-kb-runtime/moxa_kb.sqlite", isDirectory: false)
                    .path
            }()
            let cachesRuntime = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
                .first?
                .appendingPathComponent("moxa-kb-runtime/moxa_kb.sqlite")
                .path
            candidates = [homeRuntime, realHomeRuntime, cachesRuntime].compactMap { $0 }
        }

        for candidate in candidates {
            let normalized = (candidate as NSString).standardizingPath
            if normalized.contains("/.moxa-kb/") || normalized.hasSuffix("/.moxa-kb") || normalized.contains(".moxa-kb/") {
                ExtensionLogger.cache.error(
                    "Blocked unsafe direct open of cold .moxa-kb database: \(normalized, privacy: .public)"
                )
                continue
            }
            if FileManager.default.fileExists(atPath: normalized) {
                return normalized
            }
        }
        return nil
    }

    private static func sqliteImmutableReadOnlyURI(forFilePath path: String) -> String {
        let escaped = path
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "?", with: "%3F")
            .replacingOccurrences(of: "#", with: "%23")
            .replacingOccurrences(of: " ", with: "%20")
        return "file:\(escaped)?mode=ro&immutable=1"
    }

    private static func loadFoldersFromRuntimeSQLite(atPath path: String) -> [String: CandidateFolderMeta] {
        var db: OpaquePointer?
        let uri = sqliteImmutableReadOnlyURI(forFilePath: path)
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI
        let rc = sqlite3_open_v2(uri, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return [:]
        }
        defer { sqlite3_close(db) }

        let primarySQL = """
            SELECT relpath, top_dir, product_family, sku_guess, doc_type, subsystems, standards, project_name
            FROM files
            WHERE COALESCE(is_obsolete, 0) = 0
            """
        let fallbackSQL = """
            SELECT relpath, '', '', sku_guess, '', '', standards, project_name
            FROM files
            """

        var stmt: OpaquePointer?
        var prepared = sqlite3_prepare_v2(db, primarySQL, -1, &stmt, nil)
        if prepared != SQLITE_OK {
            if let stmt { sqlite3_finalize(stmt) }
            stmt = nil
            prepared = sqlite3_prepare_v2(db, fallbackSQL, -1, &stmt, nil)
        }
        guard prepared == SQLITE_OK, let stmt else {
            if let stmt { sqlite3_finalize(stmt) }
            return [:]
        }
        defer { sqlite3_finalize(stmt) }

        var folders: [String: CandidateFolderMeta] = [:]

        while sqlite3_step(stmt) == SQLITE_ROW {
            let relpath = columnText(stmt, index: 0)
            let productFamily = columnText(stmt, index: 2)
            let skuGuess = columnText(stmt, index: 3)
            let docType = columnText(stmt, index: 4)
            let subsystems = columnText(stmt, index: 5)
            let standards = columnText(stmt, index: 6)
            let projectName = columnText(stmt, index: 7)

            let rawComponents = relpath.split(separator: "/").map(String.init)
            guard rawComponents.count >= 2 else { continue }
            let dirComponents = Array(rawComponents.dropLast())

            // Strictly skip any hidden '.' components or traversal segments.
            if dirComponents.contains(where: { $0.isEmpty || $0.hasPrefix(".") || $0 == "." || $0 == ".." }) {
                continue
            }

            let l1 = dirComponents[0]
            var entry1 = folders[l1] ?? CandidateFolderMeta(relativePath: l1, depth: 1, existsOnDisk: false)
            entry1.fileCount += 1
            if dirComponents.count == 1 {
                appendClues(
                    to: &entry1,
                    projectName: projectName,
                    skuGuess: skuGuess,
                    productFamily: productFamily,
                    standards: standards,
                    docType: docType,
                    subsystems: subsystems
                )
            }
            folders[l1] = entry1

            if dirComponents.count >= 2 {
                let l2 = "\(dirComponents[0])/\(dirComponents[1])"
                var entry2 = folders[l2] ?? CandidateFolderMeta(relativePath: l2, depth: 2, existsOnDisk: false)
                entry2.fileCount += 1
                appendClues(
                    to: &entry2,
                    projectName: projectName,
                    skuGuess: skuGuess,
                    productFamily: productFamily,
                    standards: standards,
                    docType: docType,
                    subsystems: subsystems
                )
                folders[l2] = entry2
            }
        }

        return folders
    }

    private static func columnText(_ stmt: OpaquePointer, index: Int32) -> String {
        guard let cStr = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cStr)
    }

    private static func appendClues(
        to meta: inout CandidateFolderMeta,
        projectName: String,
        skuGuess: String,
        productFamily: String,
        standards: String,
        docType: String,
        subsystems: String
    ) {
        for item in splitMetadataList(projectName) {
            meta.projects.insert(item)
            if item.hasPrefix("客户:") || item.hasPrefix("客户：") {
                let stripped = String(item.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !stripped.isEmpty { meta.projects.insert(stripped) }
            }
        }
        for item in splitMetadataList(skuGuess) { meta.skus.insert(item) }
        for item in splitMetadataList(productFamily) { meta.skus.insert(item) }
        for item in splitMetadataList(standards) { meta.standards.insert(item) }
        for item in splitMetadataList(docType) { meta.docTypes.insert(item) }
        for item in splitMetadataList(subsystems) { meta.projects.insert(item) }
    }

    private static func splitMetadataList(_ raw: String) -> [String] {
        raw.split { $0 == "," || $0 == ";" || $0 == "、" || $0 == "\n" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Deterministic Folder Scoring

    private static func scoreCandidates(
        _ candidates: [CandidateFolderMeta],
        payload: ExtractedAttachmentPayload,
        email: ParsedEmailContext,
        analysis: EmailAIAnalysis?
    ) -> [FolderScoreResult] {
        let filenameLower = payload.filename.lowercased()
        let filenameStem = ((payload.filename as NSString).deletingPathExtension).lowercased()
        let subjectLower = email.subject.lowercased()
        let headlineLower = (analysis?.headline ?? "").lowercased()
        let bodyLower = String(email.plainBody.prefix(4000)).lowercased()
        let combinedContext = [filenameStem, subjectLower, headlineLower, bodyLower].joined(separator: "\n")

        let projects = (analysis?.businessElements.projects ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let customers = (analysis?.businessElements.customers ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var models = Set<String>()
        for m in analysis?.businessElements.models ?? [] {
            let trimmed = m.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { models.insert(trimmed) }
        }
        for p in analysis?.businessElements.pricing ?? [] {
            let trimmed = p.itemOrModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { models.insert(trimmed) }
        }
        for extractedSKU in extractSKUTokens(from: "\(payload.filename) \(email.subject) \(String(email.plainBody.prefix(2000)))") {
            models.insert(extractedSKU)
        }

        let filenameStandards = detectStandards(in: filenameLower)
        let contextStandards = detectStandards(in: "\(subjectLower)\n\(headlineLower)\n\(bodyLower)")

        let isYellowFlag = analysis?.resolvedFlag == .yellow
        let hasPricingElements = !(analysis?.businessElements.pricing.isEmpty ?? true)
        let hasPricingKeyword = pricingKeywords.contains { kw in
            filenameLower.contains(kw) || subjectLower.contains(kw) || headlineLower.contains(kw)
        }
        let isPricingEmail = isYellowFlag || hasPricingElements || hasPricingKeyword

        let isSecurityAttachment = securityKeywords.contains { kw in
            filenameLower.contains(kw) || subjectLower.contains(kw) || headlineLower.contains(kw)
        }

        let filenameTokens = tokenizeMeaningful(filenameStem)

        var scored: [FolderScoreResult] = []
        scored.reserveCapacity(candidates.count)

        for candidate in candidates {
            let folderLower = candidate.relativePath.lowercased()
            let folderNormalized = normalizeCompact(folderLower)
            var score = 0
            var reasons: [String] = []

            let sqliteProjectsLower = candidate.projects.map { $0.lowercased() }
            let sqliteSKUsLower = candidate.skus.map { $0.lowercased() }
            let sqliteStandardsLower = candidate.standards.map { $0.lowercased() }

            // 1. Project matches
            var projectScore = 0
            for project in projects {
                let pLower = project.lowercased()
                let pNorm = normalizeCompact(pLower)
                if folderLower.contains(pLower) || (!pNorm.isEmpty && folderNormalized.contains(pNorm)) {
                    projectScore += 48
                    reasons.append("匹配项目「\(project)」")
                } else if sqliteProjectsLower.contains(where: { $0.contains(pLower) || pLower.contains($0) }) {
                    projectScore += 40
                    reasons.append("知识库项目线索「\(project)」")
                } else {
                    let overlap = tokenizeMeaningful(pLower).filter { folderLower.contains($0) }
                    if !overlap.isEmpty {
                        projectScore += min(32, overlap.count * 16)
                        reasons.append("项目关键词匹配(\(overlap.joined(separator: "/")))")
                    }
                }
            }
            score += min(65, projectScore)

            // 2. Customer matches
            var customerScore = 0
            for customer in customers {
                let cLower = customer.lowercased()
                let cNorm = normalizeCompact(cLower)
                if folderLower.contains(cLower) || (!cNorm.isEmpty && folderNormalized.contains(cNorm)) {
                    customerScore += 38
                    reasons.append("匹配客户「\(customer)」")
                } else if sqliteProjectsLower.contains(where: { $0.contains(cLower) || cLower.contains($0) }) {
                    customerScore += 34
                    reasons.append("知识库客户线索「\(customer)」")
                }
            }
            score += min(52, customerScore)

            // 3. Model / SKU matches
            var modelScore = 0
            for model in models {
                let mLower = model.lowercased()
                let baseSeries = skuBaseSeries(mLower)
                if folderLower.contains(mLower) || (!baseSeries.isEmpty && folderLower.contains(baseSeries)) {
                    modelScore += 26
                    reasons.append("匹配型号「\(model)」")
                } else if sqliteSKUsLower.contains(where: {
                    $0 == mLower || $0.contains(mLower) || (!baseSeries.isEmpty && $0.contains(baseSeries))
                }) {
                    modelScore += 22
                    reasons.append("知识库型号线索「\(model)」")
                }
            }
            score += min(36, modelScore)

            // 4. Standards & cybersecurity document matches (62443, EN 50155, ENISA, CRA, 63452)
            var stdScore = 0
            for std in filenameStandards {
                let aliases = standardAliases.first(where: { $0.canonical == std })?.patterns ?? [std]
                if folderMatchesAny(folderLower: folderLower, folderCompact: folderNormalized, patterns: aliases) {
                    stdScore += 42
                    reasons.append("附件标准匹配(\(std.uppercased()))")
                } else if sqliteStandardsLower.contains(where: { s in aliases.contains(where: { s.contains($0) }) }) {
                    stdScore += 24
                    reasons.append("知识库标准线索(\(std.uppercased()))")
                }
            }
            for std in contextStandards where !filenameStandards.contains(std) {
                let aliases = standardAliases.first(where: { $0.canonical == std })?.patterns ?? [std]
                if folderMatchesAny(folderLower: folderLower, folderCompact: folderNormalized, patterns: aliases) {
                    stdScore += 26
                    reasons.append("邮件标准匹配(\(std.uppercased()))")
                } else if sqliteStandardsLower.contains(where: { s in aliases.contains(where: { s.contains($0) }) }) {
                    stdScore += 16
                    reasons.append("知识库标准匹配(\(std.uppercased()))")
                }
            }
            if isSecurityAttachment {
                let folderIsSecurity = folderLower.contains("信息安全")
                    || folderLower.contains("安全标准")
                    || folderLower.contains("62443")
                    || folderLower.contains("cra")
                    || folderLower.contains("enisa")
                if folderIsSecurity {
                    stdScore += 32
                    reasons.append("匹配信息安全合规目录")
                }
            }
            score += min(75, stdScore)

            // 5. Filename token overlap against folder path
            var tokenScore = 0
            var matchedFileTokens: [String] = []
            for token in filenameTokens {
                if folderLower.contains(token) {
                    tokenScore += 20
                    matchedFileTokens.append(token)
                }
            }
            if !matchedFileTokens.isEmpty {
                score += min(40, tokenScore)
                reasons.append("文件名关键词匹配(\(matchedFileTokens.prefix(2).joined(separator: ", ")))")
            }

            // 6. Flag & pricing intent ('yellow' pricing -> '2_项目' or '8_特价邮件')
            if isPricingEmail {
                let isSpecialPriceDir = folderLower == "8_特价邮件" || folderLower.hasPrefix("8_特价邮件/")
                let isProjectRoot = folderLower == "2_项目"
                let isMatchedProjectSubdir = folderLower.hasPrefix("2_项目/") && (projectScore > 0 || customerScore > 0)
                let isPriceCompanyDir = folderLower.contains("价格")

                let isExplicitSPR = filenameLower.contains("特价")
                    || filenameLower.contains("spr")
                    || subjectLower.contains("特价")
                    || subjectLower.contains("spr")

                if isMatchedProjectSubdir {
                    score += 20
                    reasons.append("报价归入关联项目目录")
                } else if isSpecialPriceDir {
                    score += isExplicitSPR ? 36 : 30
                    reasons.append("报价/黄色旗标匹配特价邮件目录")
                } else if isProjectRoot {
                    score += 24
                    reasons.append("报价/黄色旗标匹配项目总目录")
                } else if isPriceCompanyDir {
                    score += 18
                    reasons.append("匹配价格资料目录")
                }
            }

            // 7. General top-level category affinities when specific match is modest
            if !customers.isEmpty && (folderLower == "1_客户资料" || folderLower.hasPrefix("1_客户资料/")) && customerScore == 0 {
                if folderLower == "1_客户资料" {
                    score += 12
                }
            }
            if !projects.isEmpty && folderLower == "2_项目" && projectScore == 0 {
                score += 12
            }
            if !contextStandards.isEmpty && (folderLower == "7_标准" || folderLower.hasPrefix("7_标准/")) {
                score += 14
                reasons.append("标准文档归档目录")
            }
            if (combinedContext.contains("datasheet") || combinedContext.contains("manual") || combinedContext.contains("手册") || combinedContext.contains("规格书"))
                && (folderLower == "9_产品文件" || folderLower.hasPrefix("9_产品文件/"))
            {
                score += 14
                if reasons.isEmpty { reasons.append("产品手册/规格书目录") }
            }

            // 8. Specificity & existence tie-breakers
            if score > 0 && candidate.depth == 2 {
                score += 6
            }
            if candidate.existsOnDisk {
                score += 4
            }

            scored.append(FolderScoreResult(relativePath: candidate.relativePath, score: score, reasons: reasons))
        }

        return scored.sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
    }

    private static func folderMatchesAny(
        folderLower: String,
        folderCompact: String,
        patterns: [String]
    ) -> Bool {
        for pat in patterns {
            if folderLower.contains(pat) { return true }
            let patCompact = normalizeCompact(pat)
            if !patCompact.isEmpty && folderCompact.contains(patCompact) { return true }
        }
        return false
    }

    private static func detectStandards(in text: String) -> Set<String> {
        let lower = text.lowercased()
        let compact = normalizeCompact(lower)
        var found = Set<String>()
        for (canonical, aliases) in standardAliases {
            for alias in aliases {
                let aliasCompact = normalizeCompact(alias)
                if lower.contains(alias) || (!aliasCompact.isEmpty && compact.contains(aliasCompact)) {
                    found.insert(canonical)
                    break
                }
            }
        }
        return found
    }

    private static func extractSKUTokens(from text: String) -> [String] {
        guard let regex = skuRegex else { return [] }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        var out: [String] = []
        var seen = Set<String>()
        for match in regex.matches(in: text, options: [], range: range) {
            let token = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            if token.count >= 4, seen.insert(token.uppercased()).inserted {
                out.append(token)
            }
        }
        return out
    }

    private static func skuBaseSeries(_ skuLower: String) -> String {
        let parts = skuLower.split(separator: "-")
        guard parts.count >= 2 else { return "" }
        return "\(parts[0])-\(parts[1])"
    }

    private static func normalizeCompact(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private static func tokenizeMeaningful(_ text: String) -> [String] {
        let separators = CharacterSet.alphanumerics.inverted
        let rawTokens = text
            .lowercased()
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let stopwords: Set<String> = [
            "pdf", "xlsx", "xls", "docx", "doc", "pptx", "ppt", "zip", "rar",
            "moxa", "final", "draft", "copy", "attachment", "file", "mail", "re", "fw",
            "v1", "v2", "v3", "v4", "2024", "2025", "2026"
        ]

        var result: [String] = []
        var seen = Set<String>()
        for token in rawTokens {
            guard !stopwords.contains(token) else { continue }
            let hasCJK = token.unicodeScalars.contains { scalar in
                (0x4E00...0x9FFF).contains(scalar.value)
            }
            let minLen = hasCJK ? 2 : 3
            guard token.count >= minLen else { continue }
            if seen.insert(token).inserted {
                result.append(token)
            }
        }
        return result
    }

    // MARK: - Optional AI Router Refinement (5s Timeout Fallback)

    private static func buildAIRouterPrompts(
        payloads: [ExtractedAttachmentPayload],
        initialItems: [AttachmentFilingPlanItem],
        email: ParsedEmailContext,
        analysis: EmailAIAnalysis?,
        candidateFolders: [String]
    ) -> (systemPrompt: String, userPrompt: String) {
        let systemPrompt = """
        You are a workspace attachment filing router.
        Pick the single best relative folder for each attachment strictly from the provided `candidateFolders` list.
        NEVER invent paths outside `candidateFolders`, NEVER output absolute paths, `..`, or hidden `.` directories.
        Respond with strict JSON only:
        {"items":[{"payloadID":"...","folder":"<exact entry from candidateFolders>","reason":"简短中文理由","confidence":"high|medium|low"}]}
        """

        let itemLines = zip(payloads, initialItems).map { payload, item in
            "- payloadID: \"\(payload.id)\", filename: \"\(payload.filename)\", mime: \"\(payload.mimeType)\", deterministicDefault: \"\(item.proposedRelativeFolder)\""
        }.joined(separator: "\n")

        let folderLines = candidateFolders.enumerated().map { idx, folder in
            "\(idx + 1). \(folder)"
        }.joined(separator: "\n")

        let projects = analysis?.businessElements.projects.joined(separator: ", ") ?? ""
        let customers = analysis?.businessElements.customers.joined(separator: ", ") ?? ""
        let models = analysis?.businessElements.models.joined(separator: ", ") ?? ""
        let flag = analysis?.resolvedFlag.rawValue ?? "none"

        let userPrompt = """
        Subject: \(email.subject)
        From: \(email.from)
        Flag: \(flag)
        Headline: \(analysis?.headline ?? "")
        Projects: \(projects)
        Customers: \(customers)
        Models: \(models)

        Attachments:
        \(itemLines)

        candidateFolders (pick exact strings from this list):
        \(folderLines)
        """
        return (systemPrompt, userPrompt)
    }

    private static func invokeAIRouterWithTimeout(
        timeoutSeconds: TimeInterval,
        systemPrompt: String,
        userPrompt: String,
        aiRouter: @escaping @Sendable (_ systemPrompt: String, _ userPrompt: String) async throws -> String
    ) async -> String? {
        let ns = UInt64(max(0.05, timeoutSeconds) * 1_000_000_000)
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                try? await aiRouter(systemPrompt, userPrompt)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: ns)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func parseAIRouterOverrides(
        _ rawJSON: String,
        allowedFolders: Set<String>
    ) -> [String: AIRouterResponse.Item] {
        var cleaned = rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            let lines = cleaned.components(separatedBy: "\n")
            let stripped = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            cleaned = stripped.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = cleaned.data(using: .utf8) else { return [:] }

        var parsedItems: [AIRouterResponse.Item] = []
        if let envelope = try? JSONDecoder().decode(AIRouterResponse.self, from: data) {
            parsedItems = envelope.items ?? envelope.assignments ?? []
        } else if let array = try? JSONDecoder().decode([AIRouterResponse.Item].self, from: data) {
            parsedItems = array
        }

        var result: [String: AIRouterResponse.Item] = [:]
        for entry in parsedItems {
            guard let folder = entry.folder?.trimmingCharacters(in: .whitespacesAndNewlines),
                  allowedFolders.contains(folder)
            else {
                continue
            }
            if let pid = entry.payloadID, !pid.isEmpty {
                result[pid] = entry
            }
            if let fname = entry.filename, !fname.isEmpty, result[fname] == nil {
                result[fname] = entry
            }
        }
        return result
    }

    // MARK: - Path Validation, Symlink Guards, and Conflict Resolution

    private static func validateWorkspaceRoot(_ workspaceRootURL: URL) throws -> URL {
        guard workspaceRootURL.isFileURL else {
            throw AttachmentOrganizerError.invalidWorkspaceRoot(workspaceRootURL)
        }
        let canonical = workspaceRootURL.resolvingSymlinksInPath().standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDir), isDir.boolValue else {
            throw AttachmentOrganizerError.invalidWorkspaceRoot(workspaceRootURL)
        }
        if canonical.lastPathComponent.lowercased() == ".moxa-kb" || canonical.lastPathComponent.hasPrefix(".") {
            throw AttachmentOrganizerError.hiddenDirectoryForbidden(canonical.path)
        }
        return canonical
    }

    private static func validateRelativeFolder(_ rawFolder: String) throws -> [String] {
        if rawFolder.contains("\0") || rawFolder.contains("\\") {
            throw AttachmentOrganizerError.unsafeRelativePath(rawFolder)
        }
        if rawFolder.hasPrefix("/") || rawFolder.hasPrefix("~") {
            throw AttachmentOrganizerError.unsafeRelativePath(rawFolder)
        }
        if rawFolder.isEmpty {
            return []
        }

        let trimmedTrailing = rawFolder.hasSuffix("/") ? String(rawFolder.dropLast()) : rawFolder
        if trimmedTrailing.isEmpty {
            throw AttachmentOrganizerError.unsafeRelativePath(rawFolder)
        }

        let components = trimmedTrailing.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for comp in components {
            if comp.isEmpty || comp == "." || comp == ".." {
                throw AttachmentOrganizerError.unsafeRelativePath(rawFolder)
            }
            if comp.hasPrefix(".") || comp.lowercased() == ".moxa-kb" {
                throw AttachmentOrganizerError.hiddenDirectoryForbidden(rawFolder)
            }
        }
        return components
    }

    private static func validateTargetFilename(_ rawFilename: String) throws -> String {
        let trimmed = rawFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains("\0") || trimmed.contains("/") || trimmed.contains("\\") {
            throw AttachmentOrganizerError.unsafeRelativePath(rawFilename)
        }
        if trimmed == "." || trimmed == ".." {
            throw AttachmentOrganizerError.unsafeRelativePath(rawFilename)
        }
        if trimmed.hasPrefix(".") || trimmed.lowercased() == ".moxa-kb" {
            throw AttachmentOrganizerError.hiddenDirectoryForbidden(rawFilename)
        }
        return trimmed
    }

    private static func sanitizeTargetFilename(_ rawFilename: String) -> String {
        let replaced = rawFilename
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let terminal = replaced.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? replaced
        let cleaned = terminal.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            return "attachment.bin"
        }
        if cleaned.hasPrefix(".") {
            return "attachment\(cleaned)"
        }
        return cleaned
    }

    private static func resolveFolderCheckingExistingSymlinks(
        root: URL,
        segments: [String]
    ) throws -> URL {
        var current = root
        for segment in segments {
            current = current.appendingPathComponent(segment, isDirectory: true)
            var st = stat()
            if lstat(current.path, &st) == 0 {
                if (st.st_mode & S_IFMT) == S_IFLNK {
                    let resolved = current.resolvingSymlinksInPath().standardizedFileURL
                    guard isPath(resolved.path, insideRoot: root.path) else {
                        throw AttachmentOrganizerError.symlinkEscapeDetected(current.path)
                    }
                }
            }
        }
        return current
    }

    private static func ensureSafeDirectory(
        root: URL,
        segments: [String]
    ) throws -> URL {
        var current = root
        for segment in segments {
            current = current.appendingPathComponent(segment, isDirectory: true)
            var st = stat()
            if lstat(current.path, &st) == 0 {
                if (st.st_mode & S_IFMT) == S_IFLNK {
                    let resolved = current.resolvingSymlinksInPath().standardizedFileURL
                    guard isPath(resolved.path, insideRoot: root.path) else {
                        throw AttachmentOrganizerError.symlinkEscapeDetected(current.path)
                    }
                }
            } else {
                do {
                    try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
                } catch {
                    var retryStat = stat()
                    if lstat(current.path, &retryStat) != 0 {
                        throw AttachmentOrganizerError.writeFailed(
                            path: current.path,
                            reason: error.localizedDescription
                        )
                    }
                }
            }
        }

        let resolvedFinal = current.resolvingSymlinksInPath().standardizedFileURL
        guard isPath(resolvedFinal.path, insideRoot: root.path) else {
            throw AttachmentOrganizerError.symlinkEscapeDetected(current.path)
        }
        return current
    }

    private static func isPath(_ path: String, insideRoot rootPath: String) -> Bool {
        let normalizedRoot = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        let normalizedPath = path.hasSuffix("/") ? String(path.dropLast()) : path
        if normalizedPath == normalizedRoot {
            return true
        }
        let prefix = normalizedRoot + "/"
        return normalizedPath.hasPrefix(prefix)
    }

    private static func inspectDestinationConflict(
        inFolder folderURL: URL,
        canonicalRoot: URL,
        desiredFilename: String,
        payloadSHA256: String
    ) -> AttachmentFilingConflict {
        let primaryURL = folderURL.appendingPathComponent(desiredFilename, isDirectory: false)
        var st = stat()
        guard lstat(primaryURL.path, &st) == 0 else {
            return .none
        }

        // Primary path exists (regular file, directory, or symlink).
        if (st.st_mode & S_IFMT) == S_IFREG,
           let existingSHA = sha256HexOfFile(at: primaryURL),
           existingSHA.lowercased() == payloadSHA256.lowercased()
        {
            return .identicalAlreadyExists(existingURL: primaryURL)
        }

        // Different content (or symlink/dir): find collision-safe suffix (_YYYYMMDD, _YYYYMMDD_2, ...).
        let dateStamp = currentDateStamp()
        let nsName = desiredFilename as NSString
        let ext = nsName.pathExtension
        let stem = nsName.deletingPathExtension
        let dotExt = ext.isEmpty ? "" : ".\(ext)"

        var candidates: [String] = []
        if !stem.hasSuffix("_\(dateStamp)") {
            candidates.append("\(stem)_\(dateStamp)\(dotExt)")
            for idx in 2...500 {
                candidates.append("\(stem)_\(dateStamp)_\(idx)\(dotExt)")
            }
        } else {
            for idx in 2...500 {
                candidates.append("\(stem)_\(idx)\(dotExt)")
            }
        }

        for candidate in candidates {
            let candidateURL = folderURL.appendingPathComponent(candidate, isDirectory: false)
            var candidateStat = stat()
            if lstat(candidateURL.path, &candidateStat) != 0 {
                return .renamedToAvoidOverwrite(suggestedFilename: candidate)
            }
            if (candidateStat.st_mode & S_IFMT) == S_IFREG,
               let existingSHA = sha256HexOfFile(at: candidateURL),
               existingSHA.lowercased() == payloadSHA256.lowercased()
            {
                let resolved = candidateURL.resolvingSymlinksInPath().standardizedFileURL
                if isPath(resolved.path, insideRoot: canonicalRoot.path) {
                    return .identicalAlreadyExists(existingURL: candidateURL)
                }
            }
        }

        return .renamedToAvoidOverwrite(suggestedFilename: "\(stem)_\(UUID().uuidString.prefix(8))\(dotExt)")
    }

    private static func sha256HexOfFile(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try? handle.read(upToCount: 256 * 1024)
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func currentDateStamp(now: Date = Date()) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let comps = cal.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d%02d%02d", comps.year ?? 2026, comps.month ?? 1, comps.day ?? 1)
    }

    private static func writeAtomicallyWithoutOverwriting(
        data: Data,
        to destURL: URL,
        canonicalRoot: URL
    ) throws {
        // Verify destination does not already exist or escape via symlink.
        var destStat = stat()
        if lstat(destURL.path, &destStat) == 0 {
            throw AttachmentOrganizerError.destinationCollisionExhausted(destURL.path)
        }

        let parentURL = destURL.deletingLastPathComponent()
        let resolvedParent = parentURL.resolvingSymlinksInPath().standardizedFileURL
        guard isPath(resolvedParent.path, insideRoot: canonicalRoot.path) else {
            throw AttachmentOrganizerError.symlinkEscapeDetected(destURL.path)
        }

        // Write to a non-hidden staging file in the same directory, then atomically link/rename with RENAME_EXCL.
        let tempName = "_moxa_tmp_\(UUID().uuidString)"
        let tempURL = parentURL.appendingPathComponent(tempName, isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            try data.write(to: tempURL, options: .withoutOverwriting)
        } catch {
            throw AttachmentOrganizerError.writeFailed(path: destURL.path, reason: error.localizedDescription)
        }

        let rc = renamex_np(tempURL.path, destURL.path, UInt32(RENAME_EXCL))
        if rc == 0 {
            return
        }

        let err = errno
        if err == EEXIST {
            throw AttachmentOrganizerError.destinationCollisionExhausted(destURL.path)
        }
        if err == ENOTSUP || err == EINVAL {
            // Fallback for filesystems without RENAME_EXCL: O_CREAT | O_EXCL.
            let fd = open(destURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            guard fd >= 0 else {
                let openErr = errno
                if openErr == EEXIST {
                    throw AttachmentOrganizerError.destinationCollisionExhausted(destURL.path)
                }
                throw AttachmentOrganizerError.writeFailed(
                    path: destURL.path,
                    reason: String(cString: strerror(openErr))
                )
            }
            defer { close(fd) }
            try data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var written = 0
                while written < rawBuffer.count {
                    let n = write(fd, base.advanced(by: written), rawBuffer.count - written)
                    if n <= 0 {
                        throw AttachmentOrganizerError.writeFailed(
                            path: destURL.path,
                            reason: String(cString: strerror(errno))
                        )
                    }
                    written += n
                }
            }
            return
        }

        throw AttachmentOrganizerError.writeFailed(
            path: destURL.path,
            reason: String(cString: strerror(err))
        )
    }
}
