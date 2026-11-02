import SwiftUI

/// Sidebar listing all designs, with create / rename / reveal / delete.
struct DesignListView: View {
    let app: AppModel

    @State private var renaming: Workspace?
    @State private var newName = ""
    @State private var deleting: Workspace?

    var body: some View {
        List(selection: selection) {
            Section("Designs") {
                ForEach(app.designs) { design in
                    DesignRow(design: design)
                        .tag(design.id)
                        .contextMenu { menu(for: design) }
                }
            }
        }
        .listStyle(.sidebar)
        .disabled(!app.canSwitchDesigns)
        .safeAreaInset(edge: .bottom) {
            if !app.canSwitchDesigns {
                Text("Claude is working on this design.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
        .toolbar {
            ToolbarItem {
                Button("New Design", systemImage: "plus") {
                    Task { await app.createDesign() }
                }
                .disabled(!app.canSwitchDesigns)
                .help("New design (⌘N)")
            }
        }
        .alert("Rename Design", isPresented: isRenaming) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let renaming { app.rename(renaming, to: newName) }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Move “\(deleting?.name ?? "")” to the Trash?",
            isPresented: isDeleting,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let deleting { Task { await app.delete(deleting) } }
            }
        } message: {
            Text("The design's code, model and chat history go to the Trash. You can restore the folder from there.")
        }
    }

    @ViewBuilder
    private func menu(for design: Workspace) -> some View {
        Button("Rename…") {
            newName = design.name
            renaming = design
        }
        Button("Show in Finder") { app.reveal(design) }
        Divider()
        Button("Move to Trash…", role: .destructive) { deleting = design }
            .disabled(design.id == app.workspace?.id && !app.canSwitchDesigns)
    }

    private var selection: Binding<Workspace.ID?> {
        Binding(
            get: { app.workspace?.id },
            set: { id in
                guard let id else { return }
                Task { await app.openDesign(id: id) }
            }
        )
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var isDeleting: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }
}

private struct DesignRow: View {
    let design: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(design.name)
                .lineLimit(1)
            Text(design.metadata.lastOpenedAt, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
