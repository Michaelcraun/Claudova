import Foundation

/// One design project: a SwiftPM package (copied from `WorkspaceTemplate`) that Claude edits
/// and the app builds into `Models/model.3mf`.
struct Workspace: Identifiable, Hashable, Sendable {
    struct Metadata: Codable, Hashable, Sendable {
        var name: String
        var createdAt: Date
        var lastOpenedAt: Date
        /// Claude Code session for this design, resumed with `--resume` on each turn.
        var claudeSessionID: String?
    }

    let url: URL
    var metadata: Metadata

    /// `url` is normalized (symlinks resolved, e.g. `/var` → `/private/var`) because it doubles
    /// as the identity: the same folder reached via different paths must compare equal.
    init(url: URL, metadata: Metadata) {
        self.url = url.standardizedFileURL.resolvingSymlinksInPath()
        self.metadata = metadata
    }

    var id: URL { url }
    var name: String { metadata.name }

    var mainSourceURL: URL { url.appending(path: "Sources/Model/main.swift") }
    /// The file Cadova writes; the workspace CLAUDE.md requires `Model("model")`.
    var modelOutputURL: URL { url.appending(path: "Models/model.3mf") }
    var buildDirectoryURL: URL { url.appending(path: ".build", directoryHint: .isDirectory) }
    var metadataURL: URL { Self.metadataURL(in: url) }

    static func metadataURL(in workspaceURL: URL) -> URL {
        workspaceURL.appending(path: ".claudova/project.json")
    }
}
