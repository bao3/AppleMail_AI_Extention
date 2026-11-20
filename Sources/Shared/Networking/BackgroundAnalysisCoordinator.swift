import Foundation
import OSLog

public enum BackgroundAnalysisError: LocalizedError, Sendable {
    case queueFull
    case missingProjectID

    public var errorDescription: String? {
        switch self {
        case .queueFull:
            return "后台 AI 分析队列已满，已跳过本次自动预分析。"
        case .missingProjectID:
            return VertexGeminiError.missingProjectID.errorDescription
        }
    }
}

/// Coordinates background email analysis triggered by `MEMessageActionHandler`,
/// deduplicating in-flight requests by normalized `Message-ID` and bounding concurrency.
public actor BackgroundAnalysisCoordinator {
    public static let shared = BackgroundAnalysisCoordinator()

    private struct ActivityBox: @unchecked Sendable {
        let token: any NSObjectProtocol
    }

    public let maxConcurrent: Int
    public let maxQueued: Int

    private let client: VertexGeminiClient
    private let cacheStore: AnalysisCacheStore
    private let keychainStore: KeychainStore

    private var activeCount: Int = 0
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var inFlightTasks: [String: Task<EmailAIAnalysis, Error>] = [:]

    public init(
        maxConcurrent: Int = 2,
        maxQueued: Int = 12,
        client: VertexGeminiClient = .shared,
        cacheStore: AnalysisCacheStore = .shared,
        keychainStore: KeychainStore = .shared
    ) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.maxQueued = max(1, maxQueued)
        self.client = client
        self.cacheStore = cacheStore
        self.keychainStore = keychainStore
    }

    /// Returns any currently active or queued task for `messageID` so UI panels can attach instead of duplicating API calls.
    public func inFlightTask(forMessageID messageID: String) -> Task<EmailAIAnalysis, Error>? {
        let normalized = ParsedEmailContext.normalizeMessageID(messageID)
        guard !normalized.isEmpty else { return nil }
        let key = AnalysisCacheStore.cacheKey(forMessageID: normalized)
        return inFlightTasks[key]
    }

    /// Submits (or joins an existing) background analysis task for `email` and awaits its completion.
    public func analyzeIfNeeded(
        email: ParsedEmailContext,
        model: GeminiModel = .flash38
    ) async throws -> EmailAIAnalysis {
        if let cached = cacheStore.load(forMessageID: email.messageID) {
            return cached
        }
        let task = enqueueTaskIfNeeded(email: email, model: model)
        return try await task.value
    }

    /// Enqueues (or returns an existing) detached coordinator task without blocking the caller.
    @discardableResult
    public func enqueueTaskIfNeeded(
        email: ParsedEmailContext,
        model: GeminiModel = .flash38
    ) -> Task<EmailAIAnalysis, Error> {
        let key = AnalysisCacheStore.cacheKey(forMessageID: email.messageID)
        if let existing = inFlightTasks[key] {
            return existing
        }

        let task = Task<EmailAIAnalysis, Error> {
            try await self.performQueuedAnalysis(key: key, email: email, model: model)
        }
        inFlightTasks[key] = task
        return task
    }

    private func performQueuedAnalysis(
        key: String,
        email: ParsedEmailContext,
        model: GeminiModel
    ) async throws -> EmailAIAnalysis {
        defer {
            inFlightTasks.removeValue(forKey: key)
        }

        if let cached = cacheStore.load(forMessageID: email.messageID) {
            return cached
        }

        try await acquireSlot()
        defer {
            releaseSlot()
        }

        if let cached = cacheStore.load(forMessageID: email.messageID) {
            return cached
        }

        guard let apiKey = keychainStore.loadAPIKey() else {
            throw VertexGeminiError.missingAPIKey
        }
        let projectID = keychainStore.loadProjectID().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !projectID.isEmpty else {
            throw BackgroundAnalysisError.missingProjectID
        }

        let activity = ActivityBox(
            token: ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled],
                reason: "AppleMailAI background analysis"
            )
        )
        defer {
            ProcessInfo.processInfo.endActivity(activity.token)
        }

        let result = try await client.analyzeEmail(
            email,
            model: model,
            apiKey: apiKey,
            projectID: projectID
        )
        try cacheStore.save(result, forMessageID: email.messageID)
        ExtensionLogger.action.info(
            "Background analysis cached (messageID=\(email.messageID, privacy: .private), model=\(model.rawValue, privacy: .public), latencyMs=\(result.latencyMs ?? -1, privacy: .public))"
        )
        return result
    }

    private func acquireSlot() async throws {
        if activeCount < maxConcurrent {
            activeCount += 1
            return
        }
        guard waiters.count < maxQueued else {
            ExtensionLogger.action.warning(
                "Background analysis queue full (active=\(self.activeCount, privacy: .public), queued=\(self.waiters.count, privacy: .public)); dropping request"
            )
            throw BackgroundAnalysisError.queueFull
        }
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func releaseSlot() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            activeCount = max(0, activeCount - 1)
        }
    }
}
