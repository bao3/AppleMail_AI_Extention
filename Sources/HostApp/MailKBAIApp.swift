import SwiftUI

@main
struct MailKBAIApp: App {
    var body: some Scene {
        WindowGroup("MailKB AI") {
            HostDashboardView()
                .frame(minWidth: 920, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
    }
}
