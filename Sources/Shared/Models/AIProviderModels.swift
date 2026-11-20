import Foundation

/// Supported AI provider backends for email analysis, translation, and reply drafting.
public enum AIProviderKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case vertexAI
    case geminiDeveloper
    case openAICompatible
    case anthropic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .vertexAI:
            return "Vertex AI (Google Cloud)"
        case .geminiDeveloper:
            return "Gemini Developer API"
        case .openAICompatible:
            return "OpenAI 兼容接口"
        case .anthropic:
            return "Anthropic Claude"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .vertexAI:
            return "https://aiplatform.googleapis.com/v1beta1"
        case .geminiDeveloper:
            return "https://generativelanguage.googleapis.com/v1beta"
        case .openAICompatible:
            return "https://api.openai.com/v1"
        case .anthropic:
            return "https://api.anthropic.com/v1"
        }
    }

    public var defaultFastModel: String {
        switch self {
        case .vertexAI:
            return GeminiModel.flash38.rawValue
        case .geminiDeveloper:
            return "gemini-2.5-flash"
        case .openAICompatible:
            return "gpt-4o-mini"
        case .anthropic:
            return "claude-3-5-haiku-latest"
        }
    }

    public var defaultDeepModel: String {
        switch self {
        case .vertexAI:
            return GeminiModel.carbon4.rawValue
        case .geminiDeveloper:
            return "gemini-2.5-pro"
        case .openAICompatible:
            return "gpt-4o"
        case .anthropic:
            return "claude-sonnet-4-20250514"
        }
    }

    public var requiresProjectID: Bool {
        self == .vertexAI
    }

    public var supportsLocation: Bool {
        self == .vertexAI
    }
}

/// Abstracted two-tier model selector mapped onto each provider profile's fast/deep models.
public enum AIModelTier: String, Codable, CaseIterable, Sendable, Identifiable {
    case fast
    case deep

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fast:
            return "极速主力"
        case .deep:
            return "深度推理"
        }
    }

    public var shortLabel: String {
        switch self {
        case .fast:
            return "⚡ 极速主力"
        case .deep:
            return "🧠 深度推理"
        }
    }

    public var subtitle: String {
        switch self {
        case .fast:
            return "快速响应 · 日常分析与预打标"
        case .deep:
            return "深度推理 · 复杂长信与商务核价"
        }
    }

    public var legacyGeminiModel: GeminiModel {
        switch self {
        case .fast:
            return .flash38
        case .deep:
            return .carbon4
        }
    }

    public init(legacyModel: GeminiModel) {
        switch legacyModel {
        case .flash38:
            self = .fast
        case .carbon4:
            self = .deep
        }
    }
}

/// A configurable AI provider profile (credentials stored separately in `KeychainStore`).
public struct AIProviderProfile: Codable, Sendable, Hashable, Identifiable {
    public static let defaultVertexProfileID = "default-vertex"

    public var id: String
    public var name: String
    public var kind: AIProviderKind
    public var baseURL: String
    public var projectID: String
    public var location: String
    public var fastModel: String
    public var deepModel: String
    public var customHeaders: [String: String]

    public init(
        id: String = UUID().uuidString,
        name: String,
        kind: AIProviderKind,
        baseURL: String? = nil,
        projectID: String = "",
        location: String = "global",
        fastModel: String? = nil,
        deepModel: String? = nil,
        customHeaders: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        let trimmedBase = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.baseURL = trimmedBase.isEmpty ? kind.defaultBaseURL : trimmedBase
        self.projectID = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)
        self.location = trimmedLocation.isEmpty ? "global" : trimmedLocation
        let trimmedFast = fastModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.fastModel = trimmedFast.isEmpty ? kind.defaultFastModel : trimmedFast
        let trimmedDeep = deepModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.deepModel = trimmedDeep.isEmpty ? kind.defaultDeepModel : trimmedDeep
        self.customHeaders = customHeaders
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case baseURL
        case projectID
        case location
        case fastModel
        case deepModel
        case customHeaders
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(AIProviderKind.self, forKey: .kind)
        self.kind = kind
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? kind.displayName
        let decodedBase = try container.decodeIfPresent(String.self, forKey: .baseURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.baseURL = decodedBase.isEmpty ? kind.defaultBaseURL : decodedBase
        self.projectID = try container.decodeIfPresent(String.self, forKey: .projectID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let decodedLocation = try container.decodeIfPresent(String.self, forKey: .location)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.location = decodedLocation.isEmpty ? "global" : decodedLocation
        let decodedFast = try container.decodeIfPresent(String.self, forKey: .fastModel)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.fastModel = decodedFast.isEmpty ? kind.defaultFastModel : decodedFast
        let decodedDeep = try container.decodeIfPresent(String.self, forKey: .deepModel)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.deepModel = decodedDeep.isEmpty ? kind.defaultDeepModel : decodedDeep
        self.customHeaders = try container.decodeIfPresent([String: String].self, forKey: .customHeaders) ?? [:]
    }

    public func modelName(for tier: AIModelTier) -> String {
        switch tier {
        case .fast:
            let trimmed = fastModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? kind.defaultFastModel : trimmed
        case .deep:
            let trimmed = deepModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? kind.defaultDeepModel : trimmed
        }
    }

    public var normalizedBaseURL: String {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        if trimmed.isEmpty {
            return kind.defaultBaseURL
        }
        return trimmed
    }

    public static func defaultVertexProfile(projectID: String = "") -> AIProviderProfile {
        AIProviderProfile(
            id: defaultVertexProfileID,
            name: "Vertex AI (Google Cloud)",
            kind: .vertexAI,
            baseURL: AIProviderKind.vertexAI.defaultBaseURL,
            projectID: projectID,
            location: GeminiModel.vertexLocation,
            fastModel: GeminiModel.flash38.rawValue,
            deepModel: GeminiModel.carbon4.rawValue
        )
    }

    public static let builtInPresets: [AIProviderProfile] = [
        defaultVertexProfile(),
        AIProviderProfile(
            id: "preset-gemini-developer",
            name: "Gemini Developer API",
            kind: .geminiDeveloper,
            baseURL: AIProviderKind.geminiDeveloper.defaultBaseURL,
            fastModel: "gemini-2.5-flash",
            deepModel: "gemini-2.5-pro"
        ),
        AIProviderProfile(
            id: "preset-openai",
            name: "OpenAI",
            kind: .openAICompatible,
            baseURL: "https://api.openai.com/v1",
            fastModel: "gpt-4o-mini",
            deepModel: "gpt-4o"
        ),
        AIProviderProfile(
            id: "preset-deepseek",
            name: "DeepSeek",
            kind: .openAICompatible,
            baseURL: "https://api.deepseek.com/v1",
            fastModel: "deepseek-chat",
            deepModel: "deepseek-reasoner"
        ),
        AIProviderProfile(
            id: "preset-openrouter",
            name: "OpenRouter",
            kind: .openAICompatible,
            baseURL: "https://openrouter.ai/api/v1",
            fastModel: "google/gemini-2.5-flash",
            deepModel: "anthropic/claude-sonnet-4"
        ),
        AIProviderProfile(
            id: "preset-anthropic",
            name: "Anthropic Claude",
            kind: .anthropic,
            baseURL: "https://api.anthropic.com/v1",
            fastModel: "claude-3-5-haiku-latest",
            deepModel: "claude-sonnet-4-20250514"
        )
    ]
}

/// Thread-safe persistent store for AI provider profiles, active selection, and model tier preference.
/// Automatically migrates v1.0.0 Vertex AI `projectID` and `preferredModel` settings on first load.
public final class AIProviderStore: @unchecked Sendable {
    public static let shared = AIProviderStore()

    public static let profilesDefaultsKey = "com.bao3.AppleMailAI.aiProviderProfiles.v1"
    public static let activeProfileIDDefaultsKey = "com.bao3.AppleMailAI.activeProviderProfileID.v1"
    public static let preferredTierDefaultsKey = "com.bao3.AppleMailAI.preferredModelTier.v1"
    public static let didChangeNotification = Notification.Name("com.bao3.AppleMailAI.AIProviderStoreDidChange")

    private let userDefaults: UserDefaults
    private let keychainStore: KeychainStore
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var _profiles: [AIProviderProfile] = []
    private var _activeProfileID: String = AIProviderProfile.defaultVertexProfileID
    private var _preferredTier: AIModelTier = .fast

    public init(userDefaults: UserDefaults = .standard, keychainStore: KeychainStore? = nil) {
        self.userDefaults = userDefaults
        if let keychainStore {
            self.keychainStore = keychainStore
        } else if userDefaults === UserDefaults.standard {
            self.keychainStore = KeychainStore.shared
        } else {
            self.keychainStore = KeychainStore(service: KeychainStore.defaultService, userDefaults: userDefaults)
        }
        loadOrMigrateLocked()
    }

    public var profiles: [AIProviderProfile] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _profiles
        }
        set {
            lock.lock()
            _profiles = newValue.isEmpty ? [AIProviderProfile.defaultVertexProfile(projectID: keychainStore.loadProjectID())] : newValue
            if !_profiles.contains(where: { $0.id == _activeProfileID }) {
                _activeProfileID = _profiles[0].id
            }
            persistLocked()
            lock.unlock()
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    public var activeProfileID: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _activeProfileID
        }
        set {
            setActiveProfile(id: newValue)
        }
    }

    public var preferredTier: AIModelTier {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _preferredTier
        }
        set {
            setPreferredTier(newValue)
        }
    }

    public var activeProfile: AIProviderProfile {
        lock.lock()
        defer { lock.unlock() }
        if let match = _profiles.first(where: { $0.id == _activeProfileID }) {
            return resolveLegacyProjectFallbackIfNeeded(match)
        }
        if let first = _profiles.first {
            return resolveLegacyProjectFallbackIfNeeded(first)
        }
        return AIProviderProfile.defaultVertexProfile(projectID: keychainStore.loadProjectID())
    }

    public func profile(forID id: String) -> AIProviderProfile? {
        lock.lock()
        defer { lock.unlock() }
        return _profiles.first(where: { $0.id == id }).map(resolveLegacyProjectFallbackIfNeeded)
    }

    public func upsertProfile(_ profile: AIProviderProfile, makeActive: Bool = false) {
        lock.lock()
        if let idx = _profiles.firstIndex(where: { $0.id == profile.id }) {
            _profiles[idx] = profile
        } else {
            _profiles.append(profile)
        }
        if makeActive {
            _activeProfileID = profile.id
        }
        if profile.id == AIProviderProfile.defaultVertexProfileID {
            keychainStore.saveProjectID(profile.projectID)
        }
        persistLocked()
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    public func deleteProfile(id: String) {
        lock.lock()
        guard _profiles.count > 1 else {
            lock.unlock()
            return
        }
        _profiles.removeAll { $0.id == id }
        if _profiles.isEmpty {
            _profiles = [AIProviderProfile.defaultVertexProfile(projectID: keychainStore.loadProjectID())]
        }
        if !_profiles.contains(where: { $0.id == _activeProfileID }) {
            _activeProfileID = _profiles[0].id
        }
        persistLocked()
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    public func setActiveProfile(id: String) {
        lock.lock()
        if _profiles.contains(where: { $0.id == id }) {
            _activeProfileID = id
            persistLocked()
        }
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    public func setPreferredTier(_ tier: AIModelTier) {
        lock.lock()
        _preferredTier = tier
        if _activeProfileID == AIProviderProfile.defaultVertexProfileID {
            keychainStore.savePreferredModel(tier.legacyGeminiModel)
        }
        persistLocked()
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    public func activeModelName(for tier: AIModelTier? = nil) -> String {
        let profile = activeProfile
        let resolvedTier = tier ?? preferredTier
        return profile.modelName(for: resolvedTier)
    }

    public func reload() {
        lock.lock()
        loadOrMigrateLocked()
        lock.unlock()
    }

    // MARK: - Private Helpers

    private func resolveLegacyProjectFallbackIfNeeded(_ profile: AIProviderProfile) -> AIProviderProfile {
        guard profile.id == AIProviderProfile.defaultVertexProfileID, profile.projectID.isEmpty else {
            return profile
        }
        let legacyProjectID = keychainStore.loadProjectID().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !legacyProjectID.isEmpty else { return profile }
        var copy = profile
        copy.projectID = legacyProjectID
        return copy
    }

    private func loadOrMigrateLocked() {
        if let data = userDefaults.data(forKey: Self.profilesDefaultsKey),
           let decoded = try? decoder.decode([AIProviderProfile].self, from: data),
           !decoded.isEmpty
        {
            _profiles = decoded
            let storedActive = userDefaults.string(forKey: Self.activeProfileIDDefaultsKey) ?? ""
            if decoded.contains(where: { $0.id == storedActive }) {
                _activeProfileID = storedActive
            } else {
                _activeProfileID = decoded[0].id
            }

            if let tierRaw = userDefaults.string(forKey: Self.preferredTierDefaultsKey),
               let tier = AIModelTier(rawValue: tierRaw)
            {
                _preferredTier = tier
            } else {
                _preferredTier = AIModelTier(legacyModel: keychainStore.loadPreferredModel())
            }
            return
        }

        // Migrate from v1.0.0 KeychainStore settings
        let legacyProjectID = keychainStore.loadProjectID()
        let legacyModel = keychainStore.loadPreferredModel()
        let migratedVertex = AIProviderProfile.defaultVertexProfile(projectID: legacyProjectID)

        _profiles = [migratedVertex]
        _activeProfileID = AIProviderProfile.defaultVertexProfileID
        _preferredTier = AIModelTier(legacyModel: legacyModel)
        persistLocked()
    }

    private func persistLocked() {
        if let encoded = try? encoder.encode(_profiles) {
            userDefaults.set(encoded, forKey: Self.profilesDefaultsKey)
        }
        userDefaults.set(_activeProfileID, forKey: Self.activeProfileIDDefaultsKey)
        userDefaults.set(_preferredTier.rawValue, forKey: Self.preferredTierDefaultsKey)
    }
}
