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

/// Ops kill-switch flags readable via `UserDefaults.standard` (e.g., `defaults write com.bao3.AppleMailAI.Extension ...`).
public enum ExtensionOpsConfig {
    /// Set to `true` to disable `MEMessageSecurityHandler` banner injection while keeping `MEComposeSessionHandler` active.
    public static let disableSecurityBannerKey = "com.bao3.AppleMailAI.disableSecurityBanner"
    /// Toggle for Moxa Primary background pre-analysis via `MEMessageActionHandler` (defaults to `true`).
    public static let autoAnalyzeMoxaPrimaryKey = "com.bao3.AppleMailAI.autoAnalyzeMoxaPrimary"
    /// Toggle for automatic 7-color Mail flag assignment after Moxa Primary background analysis (defaults to `true`).
    public static let autoFlagMoxaPrimaryKey = "com.bao3.AppleMailAI.autoFlagMoxaPrimary"

    public static var isSecurityBannerDisabled: Bool {
        UserDefaults.standard.bool(forKey: disableSecurityBannerKey)
    }

    public static var isAutoAnalyzeMoxaPrimaryEnabled: Bool {
        if UserDefaults.standard.object(forKey: autoAnalyzeMoxaPrimaryKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: autoAnalyzeMoxaPrimaryKey)
    }

    public static func setAutoAnalyzeMoxaPrimaryEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: autoAnalyzeMoxaPrimaryKey)
    }

    public static var isAutoFlagMoxaPrimaryEnabled: Bool {
        if UserDefaults.standard.object(forKey: autoFlagMoxaPrimaryKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: autoFlagMoxaPrimaryKey)
    }

    public static func setAutoFlagMoxaPrimaryEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: autoFlagMoxaPrimaryKey)
    }
}
