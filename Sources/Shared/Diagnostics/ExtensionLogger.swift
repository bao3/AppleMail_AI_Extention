import Foundation
import OSLog

/// Centralized Unified Logging (`os.Logger`) for operational troubleshooting.
/// Inspect live logs on macOS with:
/// `log stream --predicate 'subsystem == "com.bao3.AppleMailAI"' --level debug`
public enum ExtensionLogger {
    public static let subsystem = "com.bao3.AppleMailAI"

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
    public static let disableSecurityBannerKey = "com.bao3.AppleMailAI.disableSecurityBanner"
    /// Toggle for Moxa Primary background pre-analysis via `MEMessageActionHandler` (defaults to `true`).
    public static let autoAnalyzeMoxaPrimaryKey = "com.bao3.AppleMailAI.autoAnalyzeMoxaPrimary"
    /// Toggle for automatic 7-color Mail flag assignment after Moxa Primary background analysis (defaults to `true`).
    public static let autoFlagMoxaPrimaryKey = "com.bao3.AppleMailAI.autoFlagMoxaPrimary"

    private static var defaults: UserDefaults {
        SharedAppGroup.sharedUserDefaults
    }

    public static var isSecurityBannerDisabled: Bool {
        defaults.bool(forKey: disableSecurityBannerKey)
    }

    public static var isAutoAnalyzeMoxaPrimaryEnabled: Bool {
        if defaults.object(forKey: autoAnalyzeMoxaPrimaryKey) == nil {
            return true
        }
        return defaults.bool(forKey: autoAnalyzeMoxaPrimaryKey)
    }

    public static func setAutoAnalyzeMoxaPrimaryEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: autoAnalyzeMoxaPrimaryKey)
        SharedAppGroup.postDistributedConfigDidChange()
    }

    public static var isAutoFlagMoxaPrimaryEnabled: Bool {
        if defaults.object(forKey: autoFlagMoxaPrimaryKey) == nil {
            return true
        }
        return defaults.bool(forKey: autoFlagMoxaPrimaryKey)
    }

    public static func setAutoFlagMoxaPrimaryEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: autoFlagMoxaPrimaryKey)
        SharedAppGroup.postDistributedConfigDidChange()
    }
}
