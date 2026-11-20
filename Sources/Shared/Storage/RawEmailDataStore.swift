import Foundation
import OSLog

/// Thread-safe bounded LRU cache mapping normalized RFC 5322 `Message-ID`s
/// to raw MIME `Data` bytes for on-demand local attachment extraction.
public final class RawEmailDataStore: @unchecked Sendable {
    public static let shared = RawEmailDataStore(
        maxEntries: 10,
        maxTotalBytes: 40 * 1024 * 1024
    )

    public let maxEntries: Int
    public let maxTotalBytes: Int

    private let lock = NSLock()
    private var entries: [String: Data] = [:]
    private var order: [String] = []
    private var totalBytes: Int = 0

    public init(maxEntries: Int = 10, maxTotalBytes: Int = 40 * 1024 * 1024) {
        self.maxEntries = max(1, maxEntries)
        self.maxTotalBytes = max(1, maxTotalBytes)
    }

    public func store(rawData: Data, forMessageID messageID: String) {
        let key = ParsedEmailContext.normalizeMessageID(messageID).lowercased()
        guard !key.isEmpty else { return }

        guard rawData.count <= maxTotalBytes else {
            ExtensionLogger.cache.warning(
                "RawEmailDataStore skipped storing oversized messageID=\(key, privacy: .public), bytes=\(rawData.count, privacy: .public)"
            )
            return
        }

        lock.lock()
        defer { lock.unlock() }

        if let existing = entries[key] {
            totalBytes -= existing.count
            order.removeAll { $0 == key }
        }

        entries[key] = rawData
        order.append(key)
        totalBytes += rawData.count

        evictIfNeededLocked()
    }

    public func lookup(messageID: String) -> Data? {
        let key = ParsedEmailContext.normalizeMessageID(messageID).lowercased()
        guard !key.isEmpty else { return nil }

        lock.lock()
        defer { lock.unlock() }

        guard let hit = entries[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return hit
    }

    public func remove(messageID: String) {
        let key = ParsedEmailContext.normalizeMessageID(messageID).lowercased()
        guard !key.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        if let existing = entries.removeValue(forKey: key) {
            totalBytes = max(0, totalBytes - existing.count)
        }
        order.removeAll { $0 == key }
    }

    public func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        order.removeAll()
        totalBytes = 0
    }

    public var currentEntryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    public var currentTotalBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalBytes
    }

    private func evictIfNeededLocked() {
        while order.count > maxEntries || totalBytes > maxTotalBytes {
            guard let oldest = order.first else { break }
            order.removeFirst()
            if let evicted = entries.removeValue(forKey: oldest) {
                totalBytes = max(0, totalBytes - evicted.count)
            }
        }
    }
}
