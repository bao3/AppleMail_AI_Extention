import Foundation

/// Bounded in-memory LRU cache mapping normalized Message-IDs to full `ParsedEmailContext`.
/// Preserves untruncated email content in the extension process while keeping XPC context payloads small,
/// and provides fallback lookup for `MEComposeSessionHandler`.
public final class ParsedEmailStore: @unchecked Sendable {
    public static let shared = ParsedEmailStore(capacity: 64)

    private let capacity: Int
    private let lock = NSLock()
    private var entries: [String: ParsedEmailContext] = [:]
    private var order: [String] = []
    private var lastStoredKey: String?

    public init(capacity: Int = 64) {
        self.capacity = max(1, capacity)
    }

    public func store(_ context: ParsedEmailContext) {
        let key = ParsedEmailContext.normalizeMessageID(context.messageID).lowercased()
        guard !key.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        entries[key] = context
        order.removeAll { $0 == key }
        order.append(key)
        lastStoredKey = key

        while order.count > capacity {
            let oldest = order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    public func lookup(messageID: String) -> ParsedEmailContext? {
        let key = ParsedEmailContext.normalizeMessageID(messageID).lowercased()
        guard !key.isEmpty else { return nil }

        lock.lock()
        defer { lock.unlock() }
        guard let hit = entries[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return hit
    }

    public func lookupAny(messageIDs: [String]) -> ParsedEmailContext? {
        for raw in messageIDs {
            if let hit = lookup(messageID: raw) {
                return hit
            }
        }
        return nil
    }

    public var mostRecentParsedEmail: ParsedEmailContext? {
        lock.lock()
        defer { lock.unlock() }
        guard let key = lastStoredKey else { return nil }
        return entries[key]
    }
}
