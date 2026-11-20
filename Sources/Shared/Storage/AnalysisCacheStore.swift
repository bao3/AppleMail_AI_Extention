import CryptoKit
import Foundation

/// Thread-safe local JSON cache keyed by SHA-256 of the normalized RFC 5322 `Message-ID`.
public final class AnalysisCacheStore: @unchecked Sendable {
    public static let shared = AnalysisCacheStore()

    private let cacheDirectory: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var knownCachedKeys: Set<String> = []

    public init(baseDirectory: URL? = nil) {
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
            return nil
        }
        if let decoded = try? decoder.decode(EmailAIAnalysis.self, from: data) {
            knownCachedKeys.insert(key)
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
    }

    @discardableResult
    public func clearAll() -> Int {
        lock.lock()
        defer { lock.unlock() }
        knownCachedKeys.removeAll()
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
