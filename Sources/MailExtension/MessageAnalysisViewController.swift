import AppKit
import MailKit
import OSLog
import SwiftUI

final class MessageAnalysisViewController: MEExtensionViewController {
    private let emailContext: ParsedEmailContext
    private let openDelaySeconds: TimeInterval
    private let urlOpener: @MainActor @Sendable (URL) -> Void
    private var isDismissingForExternalOpen = false

    init(
        emailContext: ParsedEmailContext,
        openDelaySeconds: TimeInterval = 0.15,
        urlOpener: @escaping @MainActor @Sendable (URL) -> Void = { @MainActor url in
            MessageAnalysisViewController.defaultOpenURL(url)
        }
    ) {
        self.emailContext = emailContext
        self.openDelaySeconds = max(0, openDelaySeconds)
        self.urlOpener = urlOpener
        super.init(nibName: nil, bundle: nil)
        self.preferredContentSize = NSSize(width: 540, height: 620)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))
        let panelView = EmailAnalysisPanelView(
            email: emailContext,
            onOpenExternalURL: { [weak self] url in
                self?.dismissPopoverAndOpenURL(url)
            }
        )
        let hostingView = NSHostingView(rootView: panelView)
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        self.view = container
    }

    @MainActor
    func dismissPopoverAndOpenURL(_ url: URL) {
        guard !isDismissingForExternalOpen else { return }
        isDismissingForExternalOpen = true

        let resetDelay = max(0.5, openDelaySeconds + 0.2)
        DispatchQueue.main.asyncAfter(deadline: .now() + resetDelay) { [weak self] in
            MainActor.assumeIsolated {
                self?.isDismissingForExternalOpen = false
            }
        }

        ExtensionLogger.lifecycle.info(
            "Dismissing analysis popover before opening URL (scheme=\(url.scheme ?? "", privacy: .public))"
        )

        // Tear down MailKit's remote ViewBridge popover before Mail opens another SingleMessageViewer window,
        // otherwise Mail holds its newly opened viewer blank until the popover XPC connection closes.
        let dismissSel = NSSelectorFromString("dismissPopover")
        let invalidateSel = NSSelectorFromString("invalidate")
        if let parent = self.parent,
           parent.responds(to: invalidateSel),
           self.responds(to: dismissSel)
        {
            _ = self.perform(dismissSel)
        } else if let presenter = self.presentingViewController {
            presenter.dismiss(self)
        } else if let window = self.viewIfLoaded?.window, window.isVisible {
            window.performClose(nil)
            if window.isVisible {
                window.orderOut(nil)
            }
        }

        let fallbackDelay = min(0.06, openDelaySeconds * 0.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + fallbackDelay) { [weak self] in
            MainActor.assumeIsolated {
                if let window = self?.viewIfLoaded?.window, window.isVisible {
                    _ = window.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil)
                    window.performClose(nil)
                    if window.isVisible {
                        window.orderOut(nil)
                    }
                }
            }
        }

        // Strongly capture opener & URL because Mail deallocates this VC as soon as the popover closes.
        let opener = self.urlOpener
        DispatchQueue.main.asyncAfter(deadline: .now() + openDelaySeconds) {
            MainActor.assumeIsolated {
                opener(url)
            }
        }
    }

    @MainActor
    static func defaultOpenURL(_ url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if url.scheme?.lowercased() == "message" {
            let mailAppURL = URL(fileURLWithPath: "/System/Applications/Mail.app")
            if FileManager.default.fileExists(atPath: mailAppURL.path) {
                NSWorkspace.shared.open([url], withApplicationAt: mailAppURL, configuration: config, completionHandler: nil)
                return
            }
        }
        NSWorkspace.shared.open(url, configuration: config, completionHandler: nil)
    }
}
