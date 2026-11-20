import SwiftUI

@main
struct AppleMailAIApp: App {
    var body: some Scene {
        WindowGroup("Apple Mail AI 助手") {
            HostDashboardView()
                .frame(minWidth: 920, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
    }
}
