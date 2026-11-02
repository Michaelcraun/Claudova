import SwiftUI

/// Compact toolbar indicator for workspace preparation/build state.
struct WorkspaceStatusView: View {
    let app: AppModel
    @State private var showingLog = false

    var body: some View {
        HStack(spacing: 6) {
            switch app.status {
            case .idle:
                EmptyView()
            case .preparing(let message):
                ProgressView().controlSize(.small)
                Text(message)
            case .ready:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(app.workspace?.name ?? "Ready")
            case .failed:
                Button {
                    showingLog = true
                } label: {
                    Label("Build failed", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .help("Show build errors")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize()
        .popover(isPresented: $showingLog, arrowEdge: .bottom) {
            BuildLogView(app: app)
        }
    }
}

private struct BuildLogView: View {
    let app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Build Errors").font(.headline)
            if case .failed(let summary) = app.status {
                ScrollView {
                    Text(summary)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                Button("Copy Full Log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(app.buildLog, forType: .string)
                }
                Spacer()
                Button("Retry") { Task { await app.build() } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 520, height: 300)
    }
}
