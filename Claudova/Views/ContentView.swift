import SwiftUI

struct ContentView: View {
    let app: AppModel
    @State private var preview = ModelPreview()

    var body: some View {
        // Three columns: designs | chat | 3D preview.
        NavigationSplitView {
            DesignListView(app: app)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 320)
        } content: {
            ChatView(store: app.chat)
                .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 600)
        } detail: {
            ModelViewerView(preview: preview)
                .frame(minWidth: 360)
                .toolbar {
                ToolbarItem(placement: .status) {
                    WorkspaceStatusView(app: app)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Rebuild", systemImage: "hammer") {
                        Task { await app.build() }
                    }
                    .disabled(app.workspace == nil || app.status.isBusy || app.chat.isRunning)
                    .help("Rebuild the model")

                    Button("Show in Finder", systemImage: "folder") {
                        app.revealWorkspaceInFinder()
                    }
                    .disabled(app.workspace == nil)
                    .help("Show the design's source in Finder")

                    Button("Reset View", systemImage: "scope") {
                        preview.scene.resetCamera()
                    }
                    .help("Re-frame the model")
                }
            }
        }
        .navigationTitle(app.workspace?.name ?? "Claudova")
        // Watch the open design's output file; the preview reloads whenever a build rewrites it.
        .onChange(of: app.workspace?.modelOutputURL, initial: true) { _, url in
            preview.show(url)
        }
        .task { await app.start() }
    }
}
