import AppKit
import MailKit
import SwiftUI

final class ComposeAssistantViewController: MEExtensionViewController {
    private let originalEmail: ParsedEmailContext?
    private let draftSubject: String
    private let recipients: [String]

    init(originalEmail: ParsedEmailContext?, draftSubject: String, recipients: [String]) {
        self.originalEmail = originalEmail
        self.draftSubject = draftSubject
        self.recipients = recipients
        super.init(nibName: nil, bundle: nil)
        self.preferredContentSize = NSSize(width: 520, height: 580)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))
        let rootView = ComposeReplyPanelView(
            originalEmail: originalEmail,
            draftSubject: draftSubject,
            recipients: recipients
        )
        let hostingView = NSHostingView(rootView: rootView)
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
}
