import AppKit
import MailKit
import SwiftUI

final class MessageAnalysisViewController: MEExtensionViewController {
    private let emailContext: ParsedEmailContext

    init(emailContext: ParsedEmailContext) {
        self.emailContext = emailContext
        super.init(nibName: nil, bundle: nil)
        self.preferredContentSize = NSSize(width: 560, height: 640)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))
        let hostingView = NSHostingView(rootView: EmailAnalysisPanelView(email: emailContext))
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
