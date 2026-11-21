import Foundation
import OSLog

/// Centralized Unified Logging (`os.Logger`) for operational troubleshooting.
/// Inspect live logs on macOS with:
/// `log stream --predicate 'subsystem == "com.bao3.MailKBAI"' --level debug`
public enum ExtensionLogger {
    public static let subsystem = "com.bao3.MailKBAI"

    public static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    public static let security = Logger(subsystem: subsystem, category: "security")
    public static let action = Logger(subsystem: subsystem, category: "action")
    public static let compose = Logger(subsystem: subsystem, category: "compose")
    public static let mime = Logger(subsystem: subsystem, category: "mime")
    public static let keychain = Logger(subsystem: subsystem, category: "keychain")
    public static let cache = Logger(subsystem: subsystem, category: "cache")
    public static let network = Logger(subsystem: subsystem, category: "network")
    public static let reminders = Logger(subsystem: subsystem, category: "reminders")
}

/// Ops kill-switch flags readable via shared App Group `UserDefaults` (falling back to `.standard` outside signed app/extension).
public enum ExtensionOpsConfig {
    /// Set to `true` to disable `MEMessageSecurityHandler` banner injection while keeping `MEComposeSessionHandler` active.
    public static let disableSecurityBannerKey = "com.bao3.MailKBAI.disableSecurityBanner"
    public static let legacyDisableSecurityBannerKey = "com.bao3.AppleMailAI.disableSecurityBanner"
    /// Toggle for Primary background pre-analysis via `MEMessageActionHandler` (defaults to `true`).
    public static let autoAnalyzePrimaryKey = "com.bao3.MailKBAI.autoAnalyzePrimary"
    public static let legacyAutoAnalyzeMoxaPrimaryKey = "com.bao3.AppleMailAI.autoAnalyzeMoxaPrimary"
    /// Toggle for automatic 7-color Mail flag assignment after Primary background analysis (defaults to `true`).
    public static let autoFlagPrimaryKey = "com.bao3.MailKBAI.autoFlagPrimary"
    public static let legacyAutoFlagMoxaPrimaryKey = "com.bao3.AppleMailAI.autoFlagMoxaPrimary"

    private static var defaults: UserDefaults {
        SharedAppGroup.sharedUserDefaults
    }

    public static var isSecurityBannerDisabled: Bool {
        if defaults.object(forKey: disableSecurityBannerKey) != nil {
            return defaults.bool(forKey: disableSecurityBannerKey)
        }
        return defaults.bool(forKey: legacyDisableSecurityBannerKey)
    }

    public static var isAutoAnalyzePrimaryEnabled: Bool {
        if defaults.object(forKey: autoAnalyzePrimaryKey) != nil {
            return defaults.bool(forKey: autoAnalyzePrimaryKey)
        }
        if defaults.object(forKey: legacyAutoAnalyzeMoxaPrimaryKey) != nil {
            return defaults.bool(forKey: legacyAutoAnalyzeMoxaPrimaryKey)
        }
        return true
    }

    public static func setAutoAnalyzePrimaryEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: autoAnalyzePrimaryKey)
        SharedAppGroup.postDistributedConfigDidChange()
    }

    public static var isAutoFlagPrimaryEnabled: Bool {
        if defaults.object(forKey: autoFlagPrimaryKey) != nil {
            return defaults.bool(forKey: autoFlagPrimaryKey)
        }
        if defaults.object(forKey: legacyAutoFlagMoxaPrimaryKey) != nil {
            return defaults.bool(forKey: legacyAutoFlagMoxaPrimaryKey)
        }
        return true
    }

    public static func setAutoFlagPrimaryEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: autoFlagPrimaryKey)
        SharedAppGroup.postDistributedConfigDidChange()
    }
}
