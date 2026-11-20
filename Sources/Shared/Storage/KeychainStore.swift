import Foundation
import OSLog
import Security

public enum KeychainError: LocalizedError {
    case emptyAPIKey
    case unexpectedData
    case osStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .emptyAPIKey:
            return "API Key 不能为空。"
        case .unexpectedData:
            return "Keychain 返回了无法识别的数据格式。"
        case let .osStatus(status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "Keychain 操作失败 (\(status)): \(message)"
            }
            return "Keychain 操作失败 (OSStatus: \(status))"
        }
    }
}

/// Manages Vertex AI API Key & preferred model in the macOS Login Keychain.
/// Uses the file-based Keychain (no `kSecUseDataProtectionKeychain` / `keychain-access-groups`)
/// so both the sandboxed host app and MailKit appex work cleanly with Apple Development signing.
public final class KeychainStore: @unchecked Sendable {
    public static let shared = KeychainStore()

    public static let defaultService = "com.bao3.AppleMailAI.vertex-api-key"
    public static let apiKeyAccount = "vertex-api-key"
    public static let modelPrefAccount = "preferred-gemini-model"
    public static let userDefaultsModelKey = "com.bao3.AppleMailAI.preferredModel"
    public static let userDefaultsProjectIDKey = "com.bao3.AppleMailAI.vertexProjectID"

    public let service: String
    private let userDefaults: UserDefaults

    public init(service: String = KeychainStore.defaultService, userDefaults: UserDefaults = .standard) {
        self.service = service
        self.userDefaults = userDefaults
    }

    public static func accountName(forProfileID profileID: String) -> String {
        let trimmed = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == AIProviderProfile.defaultVertexProfileID {
            return apiKeyAccount
        }
        return "provider-key-\(trimmed)"
    }

    // MARK: - API Key (Default Vertex Profile & Per-Profile)

    public func saveAPIKey(_ rawKey: String) throws {
        try saveAPIKey(rawKey, forProfileID: AIProviderProfile.defaultVertexProfileID)
    }

    public func loadAPIKey() -> String? {
        loadAPIKey(forProfileID: AIProviderProfile.defaultVertexProfileID)
    }

    public func deleteAPIKey() throws {
        try deleteAPIKey(forProfileID: AIProviderProfile.defaultVertexProfileID)
    }

    public func hasAPIKey() -> Bool {
        hasAPIKey(forProfileID: AIProviderProfile.defaultVertexProfileID)
    }

    public func maskedAPIKeyStatus() -> String? {
        maskedAPIKeyStatus(forProfileID: AIProviderProfile.defaultVertexProfileID)
    }

    public func saveAPIKey(_ rawKey: String, forProfileID profileID: String) throws {
        let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KeychainError.emptyAPIKey
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw KeychainError.unexpectedData
        }
        try upsertGenericPassword(data: data, account: Self.accountName(forProfileID: profileID))
    }

    public func loadAPIKey(forProfileID profileID: String) -> String? {
        let account = Self.accountName(forProfileID: profileID)
        guard let data = readGenericPasswordData(account: account),
              let str = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func deleteAPIKey(forProfileID profileID: String) throws {
        try deleteGenericPassword(account: Self.accountName(forProfileID: profileID))
    }

    public func hasAPIKey(forProfileID profileID: String) -> Bool {
        loadAPIKey(forProfileID: profileID) != nil
    }

    public func maskedAPIKeyStatus(forProfileID profileID: String) -> String? {
        guard let key = loadAPIKey(forProfileID: profileID) else { return nil }
        if key.count <= 10 {
            return "•••• (已存入 Keychain)"
        }
        let prefix = key.prefix(6)
        let suffix = key.suffix(4)
        return "\(prefix)...\(suffix) (已存入 Keychain)"
    }

    // MARK: - Preferred Gemini Model

    /// Stored in UserDefaults (non-secret) to avoid cross-binary Login Keychain ACL prompts/blocks
    /// when the sandboxed MailKit `.appex` initializes its popover UI.
    public func loadPreferredModel() -> GeminiModel {
        if let raw = userDefaults.string(forKey: Self.userDefaultsModelKey),
           let model = GeminiModel(rawValue: raw)
        {
            return model
        }
        return GeminiModel.defaultModel
    }

    public func savePreferredModel(_ model: GeminiModel) {
        userDefaults.set(model.rawValue, forKey: Self.userDefaultsModelKey)
    }

    // MARK: - Vertex AI GCP Project ID

    public func loadProjectID() -> String {
        if let stored = userDefaults.string(forKey: Self.userDefaultsProjectIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty
        {
            return stored
        }
        if let env = ProcessInfo.processInfo.environment["VERTEX_PROJECT_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty
        {
            return env
        }
        return ""
    }

    public func saveProjectID(_ rawProjectID: String) {
        let trimmed = rawProjectID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            userDefaults.removeObject(forKey: Self.userDefaultsProjectIDKey)
        } else {
            userDefaults.set(trimmed, forKey: Self.userDefaultsProjectIDKey)
        }
    }

    // MARK: - Low-level Keychain Operations

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func readGenericPasswordData(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                ExtensionLogger.keychain.error(
                    "SecItemCopyMatching failed for account=\(account, privacy: .public), OSStatus=\(status, privacy: .public)"
                )
            }
            return nil
        }
        return item as? Data
    }

    private func upsertGenericPassword(data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus != errSecItemNotFound {
            throw KeychainError.osStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.osStatus(addStatus)
        }
    }

    private func deleteGenericPassword(account: String) throws {
        let query = baseQuery(account: account)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.osStatus(status)
        }
    }
}
