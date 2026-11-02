import SwiftUI

@main
struct ClaudovaApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        // A single window: one AppModel drives one chat/viewer.
        Window("Claudova", id: "main") {
            // Unit tests are hosted in the app; don't create workspaces or start builds for them.
            if Self.isHostingTests {
                Text("Running tests…")
            } else {
                ContentView(app: app)
                    .frame(minWidth: 1000, minHeight: 560)
            }
        }
        .windowToolbarStyle(.unified)
        // A `Window` scene otherwise restores its last open/closed state, so after a crash or
        // force-quit the app could launch with no window at all.
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Design") {
                    Task { await app.createDesign() }
                }
                .keyboardShortcut("n")
                .disabled(!app.canSwitchDesigns)
            }
        }
    }

    private static let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}
