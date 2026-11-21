import AppKit
import Combine
import Foundation
import OSLog

public enum WorkspaceBookmarkError: LocalizedError, Equatable, Sendable {
    case noWorkspaceSelected
    case invalidDirectory(URL)
    case bookmarkCreationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noWorkspaceSelected:
            return "尚未选择附件归档工作区目录，请先选择工作区根目录。"
        case let .invalidDirectory(url):
            return "所选工作区目录不存在或不是文件夹：\(url.path)"
        case let .bookmarkCreationFailed(reason):
            return "保存工作区安全作用域书签失败：\(reason)"
        }
    }
}

/// Manages the user-authorized workspace root folder via a persistent macOS security-scoped bookmark.
@MainActor
public final class WorkspaceBookmarkStore: ObservableObject {
    public static let shared = WorkspaceBookmarkStore()
    public static let bookmarkDefaultsKey = "com.bao3.MailKBAI.workspaceRootBookmark"
    public static let legacyBookmarkDefaultsKey = "com.bao3.AppleMailAI.workspaceRootBookmark"

    @Published public private(set) var workspaceURL: URL?

    public var workspaceDisplayPath: String? {
        workspaceURL?.path
    }

    private let userDefaults: UserDefaults

    /// Intentionally stays on per-container `UserDefaults.standard`: macOS app-scoped security
    /// bookmarks (`com.apple.security.files.bookmarks.app-scope`) are cryptographically bound to
    /// the creating sandbox container/binary and cannot be resolved across Host App and Extension.
    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.workspaceURL = resolvePersistedBookmark()
    }

    /// Presents an `NSOpenPanel` folder picker defaulting to `~/Documents` if present,
    /// and persists a security-scoped bookmark for the selected directory.
    @discardableResult
    public func chooseWorkspaceDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择附件归档工作区根目录"
        panel.message = "请选择要保存邮件附件的工作区目录（例如 Documents 下的项目归档目录）。仅在您点击确认后按选定目录写入。"
        panel.prompt = "授权此目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        let defaultDocumentsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
        if FileManager.default.fileExists(atPath: defaultDocumentsURL.path) {
            panel.directoryURL = defaultDocumentsURL
        }

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return nil
        }

        do {
            try saveWorkspaceURL(selectedURL)
            return workspaceURL
        } catch {
            ExtensionLogger.cache.error(
                "Failed to persist workspace bookmark for \(selectedURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Persists a security-scoped bookmark for `url` and updates `workspaceURL`.
    public func saveWorkspaceURL(_ url: URL) throws {
        var isDir: ObjCBool = false
        guard url.isFileURL,
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue
        else {
            throw WorkspaceBookmarkError.invalidDirectory(url)
        }

        let bookmarkData: Data
        do {
            bookmarkData = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            do {
                bookmarkData = try url.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            } catch let fallbackError {
                throw WorkspaceBookmarkError.bookmarkCreationFailed(fallbackError.localizedDescription)
            }
        }

        userDefaults.set(bookmarkData, forKey: Self.bookmarkDefaultsKey)
        workspaceURL = url
    }

    public func clearWorkspace() {
        userDefaults.removeObject(forKey: Self.bookmarkDefaultsKey)
        userDefaults.removeObject(forKey: Self.legacyBookmarkDefaultsKey)
        workspaceURL = nil
    }

    /// Executes `body` while holding security-scoped access to the authorized workspace root URL.
    public func withScopedWorkspaceAccess<T>(_ body: (URL) throws -> T) throws -> T {
        guard let url = workspaceURL else {
            throw WorkspaceBookmarkError.noWorkspaceSelected
        }

        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw WorkspaceBookmarkError.invalidDirectory(url)
        }

        return try body(url)
    }

    // MARK: - Private

    private func resolvePersistedBookmark() -> URL? {
        let activeKey: String
        let data: Data
        if let primaryData = userDefaults.data(forKey: Self.bookmarkDefaultsKey) {
            activeKey = Self.bookmarkDefaultsKey
            data = primaryData
        } else if let legacyData = userDefaults.data(forKey: Self.legacyBookmarkDefaultsKey) {
            activeKey = Self.legacyBookmarkDefaultsKey
            data = legacyData
        } else {
            return nil
        }

        var isStale = false
        let resolvedURL: URL?
        if let scoped = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            resolvedURL = scoped
        } else if let plain = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            resolvedURL = plain
        } else {
            ExtensionLogger.cache.warning("Failed to resolve persisted workspace bookmark; clearing stale entry")
            userDefaults.removeObject(forKey: activeKey)
            return nil
        }

        guard let url = resolvedURL else { return nil }

        if activeKey == Self.legacyBookmarkDefaultsKey {
            userDefaults.set(data, forKey: Self.bookmarkDefaultsKey)
        }

        if isStale {
            let didStart = url.startAccessingSecurityScopedResource()
            defer {
                if didStart { url.stopAccessingSecurityScopedResource() }
            }
            if let refreshed = try? url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                userDefaults.set(refreshed, forKey: Self.bookmarkDefaultsKey)
            }
        }

        return url
    }
}
