import CryptoKit
import Foundation

/// Thread-safe local JSON cache keyed by SHA-256 of the normalized RFC 5322 `Message-ID`.
public final class AnalysisCacheStore: @unchecked Sendable {
    public static let shared = AnalysisCacheStore(warmHeadlinesAsync: true)

    private struct HeadlinePreview: Decodable {
        let headline: String?
    }

    private let cacheDirectory: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var knownCachedKeys: Set<String> = []
    private var cachedHeadlinesByKey: [String: String] = [:]

    public init(baseDirectory: URL? = nil, warmHeadlinesAsync: Bool = false) {
        let root = baseDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory

        self.cacheDirectory = root
            .appendingPathComponent("AppleMailAI", isDirectory: true)
            .appendingPathComponent("MessageCache", isDirectory: true)

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec

        // Warm in-memory cache key index via directory listing only (no file content reads).
        if let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for file in files where file.pathExtension.lowercased() == "json" {
                knownCachedKeys.insert(file.deletingPathExtension().lastPathComponent)
            }
        }

        if warmHeadlinesAsync {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.warmHeadlinesFromDisk()
            }
        }
    }

    public static func cacheKey(forMessageID rawMessageID: String) -> String {
        let normalized = ParsedEmailContext.normalizeMessageID(rawMessageID).lowercased()
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(forMessageID messageID: String) -> URL {
        cacheDirectory.appendingPathComponent("\(Self.cacheKey(forMessageID: messageID)).json", isDirectory: false)
    }

    /// Zero-disk-I/O check safe to call on `MEMessageDecoder.decodedMessage(forMessageData:)` hot path.
    public func hasCachedAnalysisInMemory(forMessageID messageID: String) -> Bool {
        let normalized = ParsedEmailContext.normalizeMessageID(messageID)
        guard !normalized.isEmpty else { return false }
        let key = Self.cacheKey(forMessageID: normalized)
        lock.lock()
        defer { lock.unlock() }
        return knownCachedKeys.contains(key)
    }

    /// Zero-disk-I/O headline lookup for `MEMessageDecoder.decodedMessage(forMessageData:)` banner rendering.
    public func cachedHeadlineInMemory(forMessageID messageID: String) -> String? {
        let normalized = ParsedEmailContext.normalizeMessageID(messageID)
        guard !normalized.isEmpty else { return nil }
        let key = Self.cacheKey(forMessageID: normalized)
        lock.lock()
        defer { lock.unlock() }
        return cachedHeadlinesByKey[key]
    }

    /// Reads headlines from all existing `.json` cache files into `cachedHeadlinesByKey`.
    public func warmHeadlinesFromDisk() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let localDecoder = JSONDecoder()
        for file in files where file.pathExtension.lowercased() == "json" {
            let key = file.deletingPathExtension().lastPathComponent
            lock.lock()
            let alreadyLoaded = cachedHeadlinesByKey[key] != nil
            lock.unlock()
            if alreadyLoaded { continue }

            guard let data = try? Data(contentsOf: file),
                  let preview = try? localDecoder.decode(HeadlinePreview.self, from: data)
            else {
                continue
            }
            lock.lock()
            knownCachedKeys.insert(key)
            if let headline = preview.headline {
                cachedHeadlinesByKey[key] = headline
            }
            lock.unlock()
        }
    }

    /// Returns an in-memory headline if available, otherwise performs a single per-file `stat` and lightweight decode
    /// so externally pre-cached JSON summaries immediately show headlines on Mail banners without extension restart.
    public func cachedOrDiskHeadline(forMessageID messageID: String) -> String? {
        let normalized = ParsedEmailContext.normalizeMessageID(messageID)
        guard !normalized.isEmpty else { return nil }
        let key = Self.cacheKey(forMessageID: normalized)

        lock.lock()
        if let inMemory = cachedHeadlinesByKey[key] {
            lock.unlock()
            return inMemory
        }
        lock.unlock()

        let url = fileURL(forMessageID: normalized)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else {
            return nil
        }

        let preview = try? JSONDecoder().decode(HeadlinePreview.self, from: data)
        lock.lock()
        knownCachedKeys.insert(key)
        if let headline = preview?.headline {
            cachedHeadlinesByKey[key] = headline
        }
        lock.unlock()
        return preview?.headline
    }

    /// Synchronous disk existence check for UI / HostApp / tests.
    public func hasCachedAnalysis(forMessageID messageID: String) -> Bool {
        let normalized = ParsedEmailContext.normalizeMessageID(messageID)
        guard !normalized.isEmpty else { return false }
        let key = Self.cacheKey(forMessageID: normalized)
        let url = fileURL(forMessageID: normalized)
        lock.lock()
        defer { lock.unlock() }
        let exists = FileManager.default.fileExists(atPath: url.path)
        if exists {
            knownCachedKeys.insert(key)
        } else {
            knownCachedKeys.remove(key)
            cachedHeadlinesByKey.removeValue(forKey: key)
        }
        return exists
    }

    public func load(forMessageID messageID: String) -> EmailAIAnalysis? {
        let normalized = ParsedEmailContext.normalizeMessageID(messageID)
        guard !normalized.isEmpty else { return nil }
        let key = Self.cacheKey(forMessageID: normalized)
        let url = fileURL(forMessageID: normalized)

        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else {
            knownCachedKeys.remove(key)
            cachedHeadlinesByKey.removeValue(forKey: key)
            return nil
        }
        if let decoded = try? decoder.decode(EmailAIAnalysis.self, from: data) {
            knownCachedKeys.insert(key)
            cachedHeadlinesByKey[key] = decoded.headline
            return decoded
        }
        return nil
    }

    public func save(_ analysis: EmailAIAnalysis, forMessageID messageID: String) throws {
        let normalized = ParsedEmailContext.normalizeMessageID(messageID)
        guard !normalized.isEmpty else { return }
        var toPersist = analysis
        toPersist.messageID = normalized

        let key = Self.cacheKey(forMessageID: normalized)
        let url = fileURL(forMessageID: normalized)
        let data = try encoder.encode(toPersist)

        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        knownCachedKeys.insert(key)
        cachedHeadlinesByKey[key] = toPersist.headline
    }

    public func remove(forMessageID messageID: String) {
        let normalized = ParsedEmailContext.normalizeMessageID(messageID)
        guard !normalized.isEmpty else { return }
        let key = Self.cacheKey(forMessageID: normalized)
        let url = fileURL(forMessageID: normalized)

        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
        knownCachedKeys.remove(key)
        cachedHeadlinesByKey.removeValue(forKey: key)
    }

    @discardableResult
    public func clearAll() -> Int {
        lock.lock()
        defer { lock.unlock() }
        knownCachedKeys.removeAll()
        cachedHeadlinesByKey.removeAll()
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) else {
            return 0
        }
        var removed = 0
        for file in files where file.pathExtension.lowercased() == "json" {
            if (try? FileManager.default.removeItem(at: file)) != nil {
                removed += 1
            }
        }
        return removed
    }

    public func cacheStats() -> (count: Int, totalBytes: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else {
            return (0, 0)
        }
        var count = 0
        var bytes: Int64 = 0
        for file in files where file.pathExtension.lowercased() == "json" {
            count += 1
            if let values = try? file.resourceValues(forKeys: [.fileSizeKey]),
               let fileSize = values.fileSize
            {
                bytes += Int64(fileSize)
            }
        }
        return (count, bytes)
    }
}
