import Foundation
import MailKit
import OSLog

/// Principal class registered in `Extension-Info.plist` (`NSExtensionPrincipalClass`).
final class MailExtension: NSObject, MEExtension {
    nonisolated override init() {
        super.init()
        ExtensionLogger.lifecycle.info("MailExtension principal initialized (mainThread=\(Thread.isMainThread, privacy: .public))")
    }

    nonisolated func handlerForMessageSecurity() -> any MEMessageSecurityHandler {
        ExtensionLogger.lifecycle.debug("handlerForMessageSecurity requested (mainThread=\(Thread.isMainThread, privacy: .public))")
        return MessageSecurityHandler.shared
    }

    nonisolated func handler(for session: MEComposeSession) -> any MEComposeSessionHandler {
        ExtensionLogger.lifecycle.info("handler(for: MEComposeSession) requested (mainThread=\(Thread.isMainThread, privacy: .public))")
        return ComposeSessionHandler()
    }
}
