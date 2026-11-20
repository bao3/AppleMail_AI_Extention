import Foundation
import Security

/// Coordinates shared preferences, cached analyses, and cross-process change notifications
/// between the sandboxed Host App (`AppleMailAI.app`) and MailKit Extension (`MailAIExtension.appex`)
/// using a Team-ID-prefixed macOS App Group container.
public enum SharedAppGroup {
    public static let groupSuffix = "com.bao3.AppleMailAI"
    public static let migrationMarkerKey = "com.bao3.AppleMailAI.migratedToAppGroup.v1"
    public static let distributedConfigDidChangeNotification = Notification.Name("com.bao3.AppleMailAI.sharedConfigDidChange")

    private static let cacheMigrationMarkerFilename = ".migrated-to-app-group"

    /// Resolves the active App Group identifier from the running binary's signed entitlements
    /// (falling back to `AppleMailAIAppGroup` in `Info.plist`), verifying that macOS resolves
    /// a real group container URL. Returns `nil` for unsigned/ad-hoc test & CLI binaries.
    public static let resolvedGroupIdentifier: String? = {
        let candidate = readGroupIdentifierFromSignedEntitlements() ?? readGroupIdentifierFromInfoPlist()
        guard let id = candidate,
              isValidGroupIdentifier(id),
              FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) != nil
        else {
            return nil
        }
        return id
    }()

    public static var containerURL: URL? {
        resolvedGroupIdentifier.flatMap {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        }
    }

    /// Shared `UserDefaults` backed by the App Group suite when running inside a signed
    /// Host App or MailKit extension, falling back to `.standard` for unit tests / CLI tools.
    public nonisolated(unsafe) static let sharedUserDefaults: UserDefaults = {
        guard let id = resolvedGroupIdentifier,
              containerURL != nil,
              let suite = UserDefaults(suiteName: id)
        else {
            return .standard
        }
        migrateLegacyDefaultsIfNeeded(from: .standard, to: suite)
        return suite
    }()

    public static var isUsingSharedGroup: Bool {
        sharedUserDefaults !== UserDefaults.standard
    }

    public static var sharedApplicationSupportURL: URL {
        if let container = containerURL {
            return container
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    public static func postDistributedConfigDidChange() {
        guard isUsingSharedGroup else { return }
        // App Sandbox requires object: nil and userInfo: nil on DistributedNotificationCenter posts.
        DistributedNotificationCenter.default().postNotificationName(
            distributedConfigDidChangeNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    // MARK: - One-Time Non-Destructive Legacy Migration

    /// Migrates legacy per-container `UserDefaults` values into the shared App Group suite once,
    /// merging profiles non-destructively so neither Host App nor Extension overwrites the other.
    public static func migrateLegacyDefaultsIfNeeded(from legacy: UserDefaults, to shared: UserDefaults) {
        guard legacy !== shared, !legacy.bool(forKey: migrationMarkerKey) else {
            return
        }

        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        let legacyProfiles: [AIProviderProfile] = {
            guard let data = legacy.data(forKey: AIProviderStore.profilesDefaultsKey),
                  let decoded = try? decoder.decode([AIProviderProfile].self, from: data)
            else {
                return []
            }
            return decoded
        }()

        let sharedProfiles: [AIProviderProfile] = {
            guard let data = shared.data(forKey: AIProviderStore.profilesDefaultsKey),
                  let decoded = try? decoder.decode([AIProviderProfile].self, from: data)
            else {
                return []
            }
            return decoded
        }()

        if !legacyProfiles.isEmpty {
            if sharedProfiles.isEmpty {
                if let encoded = try? encoder.encode(legacyProfiles) {
                    shared.set(encoded, forKey: AIProviderStore.profilesDefaultsKey)
                }
                if let legacyActive = legacy.string(forKey: AIProviderStore.activeProfileIDDefaultsKey),
                   !legacyActive.isEmpty
                {
                    shared.set(legacyActive, forKey: AIProviderStore.activeProfileIDDefaultsKey)
                }
                if let legacyTier = legacy.string(forKey: AIProviderStore.preferredTierDefaultsKey),
                   !legacyTier.isEmpty
                {
                    shared.set(legacyTier, forKey: AIProviderStore.preferredTierDefaultsKey)
                }
            } else {
                var merged = sharedProfiles
                for legacyProfile in legacyProfiles {
                    if let idx = merged.firstIndex(where: { $0.id == legacyProfile.id }) {
                        if legacyProfile.id == AIProviderProfile.defaultVertexProfileID {
                            merged[idx] = mergeDefaultVertexProfile(existing: merged[idx], legacy: legacyProfile)
                        }
                    } else {
                        merged.append(legacyProfile)
                    }
                }
                if let encoded = try? encoder.encode(merged) {
                    shared.set(encoded, forKey: AIProviderStore.profilesDefaultsKey)
                }

                let sharedActive = shared.string(forKey: AIProviderStore.activeProfileIDDefaultsKey) ?? ""
                let legacyActive = legacy.string(forKey: AIProviderStore.activeProfileIDDefaultsKey) ?? ""
                if (sharedActive.isEmpty || sharedActive == AIProviderProfile.defaultVertexProfileID),
                   !legacyActive.isEmpty,
                   legacyActive != AIProviderProfile.defaultVertexProfileID,
                   merged.contains(where: { $0.id == legacyActive })
                {
                    shared.set(legacyActive, forKey: AIProviderStore.activeProfileIDDefaultsKey)
                } else if sharedActive.isEmpty,
                          !legacyActive.isEmpty,
                          merged.contains(where: { $0.id == legacyActive })
                {
                    shared.set(legacyActive, forKey: AIProviderStore.activeProfileIDDefaultsKey)
                }

                if shared.string(forKey: AIProviderStore.preferredTierDefaultsKey) == nil,
                   let legacyTier = legacy.string(forKey: AIProviderStore.preferredTierDefaultsKey),
                   !legacyTier.isEmpty
                {
                    shared.set(legacyTier, forKey: AIProviderStore.preferredTierDefaultsKey)
                }
            }
        }

        // Migrate legacy KeychainStore non-secret metadata
        let sharedProjectID = (shared.string(forKey: KeychainStore.userDefaultsProjectIDKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if sharedProjectID.isEmpty,
           let legacyProjectID = legacy.string(forKey: KeychainStore.userDefaultsProjectIDKey)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !legacyProjectID.isEmpty
        {
            shared.set(legacyProjectID, forKey: KeychainStore.userDefaultsProjectIDKey)
        }

        let sharedModel = (shared.string(forKey: KeychainStore.userDefaultsModelKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if sharedModel.isEmpty,
           let legacyModel = legacy.string(forKey: KeychainStore.userDefaultsModelKey)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !legacyModel.isEmpty
        {
            shared.set(legacyModel, forKey: KeychainStore.userDefaultsModelKey)
        }

        // Migrate ExtensionOpsConfig flags if unset in shared suite
        let opsBoolKeys = [
            ExtensionOpsConfig.disableSecurityBannerKey,
            ExtensionOpsConfig.autoAnalyzeMoxaPrimaryKey,
            ExtensionOpsConfig.autoFlagMoxaPrimaryKey
        ]
        for key in opsBoolKeys {
            if shared.object(forKey: key) == nil, legacy.object(forKey: key) != nil {
                shared.set(legacy.bool(forKey: key), forKey: key)
            }
        }

        // Union added reminder keys without duplicates
        let existingKeys = shared.stringArray(forKey: ReminderService.addedKeysDefaultsKey) ?? []
        let legacyKeys = legacy.stringArray(forKey: ReminderService.addedKeysDefaultsKey) ?? []
        if !legacyKeys.isEmpty {
            var seen = Set<String>()
            var combined: [String] = []
            for key in existingKeys + legacyKeys where seen.insert(key).inserted {
                combined.append(key)
            }
            if combined.count > ReminderService.maxStoredAddedKeys {
                combined.removeFirst(combined.count - ReminderService.maxStoredAddedKeys)
            }
            if !combined.isEmpty {
                shared.set(combined, forKey: ReminderService.addedKeysDefaultsKey)
            }
        }

        legacy.set(true, forKey: migrationMarkerKey)
    }

    /// Copies missing `.json` analysis cache files from a legacy per-container `Application Support`
    /// folder into the shared App Group `Application Support` folder once.
    public static func migrateLegacyCacheDirectoryIfNeeded(from legacyAppSupport: URL, to sharedAppSupport: URL) {
        guard legacyAppSupport.standardizedFileURL != sharedAppSupport.standardizedFileURL else {
            return
        }

        let legacyRoot = legacyAppSupport.appendingPathComponent("AppleMailAI", isDirectory: true)
        let markerURL = legacyRoot.appendingPathComponent(cacheMigrationMarkerFilename, isDirectory: false)
        let fm = FileManager.default
        if fm.fileExists(atPath: markerURL.path) {
            return
        }

        let legacyCacheDir = legacyRoot.appendingPathComponent("MessageCache", isDirectory: true)
        let sharedCacheDir = sharedAppSupport
            .appendingPathComponent("AppleMailAI", isDirectory: true)
            .appendingPathComponent("MessageCache", isDirectory: true)

        var isDir: ObjCBool = false
        if fm.fileExists(atPath: legacyCacheDir.path, isDirectory: &isDir), isDir.boolValue {
            try? fm.createDirectory(at: sharedCacheDir, withIntermediateDirectories: true)
            if let files = try? fm.contentsOfDirectory(
                at: legacyCacheDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                for src in files where src.pathExtension.lowercased() == "json" {
                    let dst = sharedCacheDir.appendingPathComponent(src.lastPathComponent, isDirectory: false)
                    if !fm.fileExists(atPath: dst.path) {
                        try? fm.copyItem(at: src, to: dst)
                    }
                }
            }
        }

        try? fm.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        fm.createFile(atPath: markerURL.path, contents: Data("1\n".utf8))
    }

    // MARK: - Private Helpers

    private static func mergeDefaultVertexProfile(
        existing: AIProviderProfile,
        legacy: AIProviderProfile
    ) -> AIProviderProfile {
        let existingProj = existing.projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyProj = legacy.projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard existingProj.isEmpty, !legacyProj.isEmpty else {
            return existing
        }
        var merged = existing
        merged.projectID = legacyProj
        let defaults = AIProviderProfile.defaultVertexProfile()
        if merged.baseURL == defaults.baseURL, !legacy.baseURL.isEmpty {
            merged.baseURL = legacy.baseURL
        }
        if merged.location == defaults.location, !legacy.location.isEmpty {
            merged.location = legacy.location
        }
        if merged.fastModel == defaults.fastModel, !legacy.fastModel.isEmpty {
            merged.fastModel = legacy.fastModel
        }
        if merged.deepModel == defaults.deepModel, !legacy.deepModel.isEmpty {
            merged.deepModel = legacy.deepModel
        }
        return merged
    }

    private static func isValidGroupIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && !value.hasPrefix(".")
            && !value.contains("$(")
            && value.hasSuffix(".\(groupSuffix)")
    }

    private static func readGroupIdentifierFromSignedEntitlements() -> String? {
        var selfCode: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &selfCode) == errSecSuccess,
              let code = selfCode
        else {
            return nil
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let resolvedStaticCode = staticCode
        else {
            return nil
        }

        var infoCF: CFDictionary?
        let status = SecCodeCopySigningInformation(
            resolvedStaticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &infoCF
        )
        guard status == errSecSuccess,
              let info = infoCF as? [String: Any],
              let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String]
        else {
            return nil
        }

        return groups.first { isValidGroupIdentifier($0) }
    }

    private static func readGroupIdentifierFromInfoPlist() -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "AppleMailAIAppGroup") as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return isValidGroupIdentifier(trimmed) ? trimmed : nil
    }
}
