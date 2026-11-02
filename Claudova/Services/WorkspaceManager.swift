import Foundation

enum WorkspaceError: LocalizedError {
    case templateMissing
    case invalidName

    var errorDescription: String? {
        switch self {
        case .templateMissing: "The model workspace template is missing from the app bundle."
        case .invalidName: "A design name can't be empty."
        }
    }
}

/// Creates, lists and updates design workspaces on disk.
struct WorkspaceManager: Sendable {
    /// Directory holding one subdirectory per workspace.
    let projectsDirectory: URL
    /// The pristine workspace template (bundled `WorkspaceTemplate`).
    let templateURL: URL

    /// Template entries that are never copied: build products and editor state.
    static let excludedTemplateEntries: Set<String> = [".build", ".swiftpm", "Models", ".DS_Store"]

    /// `~/Library/Application Support/Claudova/Projects`, using the template bundled in the app.
    static func makeDefault(bundle: Bundle = .main) throws -> WorkspaceManager {
        guard let template = bundle.url(forResource: "WorkspaceTemplate", withExtension: nil) else {
            throw WorkspaceError.templateMissing
        }
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return WorkspaceManager(
            projectsDirectory: support.appending(path: "Claudova/Projects", directoryHint: .isDirectory),
            templateURL: template
        )
    }

    // MARK: - Creating

    func create(named name: String, now: Date = .now) throws -> Workspace {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WorkspaceError.invalidName }
        let fm = FileManager.default
        guard fm.fileExists(atPath: templateURL.path) else { throw WorkspaceError.templateMissing }

        try fm.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
        let destination = uniqueDirectory(for: trimmed)
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)

        do {
            for entry in try fm.contentsOfDirectory(atPath: templateURL.path)
            where !Self.excludedTemplateEntries.contains(entry) {
                try fm.copyItem(at: templateURL.appending(path: entry), to: destination.appending(path: entry))
            }
            let workspace = Workspace(
                url: destination,
                metadata: .init(name: trimmed, createdAt: now, lastOpenedAt: now)
            )
            try save(workspace)
            return workspace
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    /// A not-yet-existing directory named after `name`, e.g. `phone-stand`, `phone-stand-2`, …
    func uniqueDirectory(for name: String) -> URL {
        let base = Self.slug(for: name)
        var candidate = projectsDirectory.appending(path: base, directoryHint: .isDirectory)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = projectsDirectory.appending(path: "\(base)-\(counter)", directoryHint: .isDirectory)
            counter += 1
        }
        return candidate
    }

    static func slug(for name: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let parts = name.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .unicodeScalars
            .split { !allowed.contains($0) }
            .map { String(String.UnicodeScalarView($0)) }
        let slug = parts.joined(separator: "-")
        return slug.isEmpty ? "design" : String(slug.prefix(60))
    }

    // MARK: - Reading and updating

    /// All workspaces with readable metadata, most recently opened first.
    func list() -> [Workspace] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: projectsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return [] }
        return entries
            .compactMap { try? load(at: $0) }
            .sorted { $0.metadata.lastOpenedAt > $1.metadata.lastOpenedAt }
    }

    func load(at url: URL) throws -> Workspace {
        let data = try Data(contentsOf: Workspace.metadataURL(in: url))
        let metadata = try Self.decoder.decode(Workspace.Metadata.self, from: data)
        return Workspace(url: url, metadata: metadata)
    }

    func save(_ workspace: Workspace) throws {
        let url = workspace.metadataURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(workspace.metadata).write(to: url, options: .atomic)
    }

    /// Records that the workspace was opened now.
    func markOpened(_ workspace: Workspace, now: Date = .now) throws -> Workspace {
        var updated = workspace
        updated.metadata.lastOpenedAt = now
        try save(updated)
        return updated
    }

    /// Changes a design's display name (its directory keeps its original name).
    func rename(_ workspace: Workspace, to name: String) throws -> Workspace {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WorkspaceError.invalidName }
        var updated = workspace
        updated.metadata.name = trimmed
        try save(updated)
        return updated
    }

    /// Removes a design. By default it goes to the Trash so it can be restored.
    func delete(_ workspace: Workspace, moveToTrash: Bool = true) throws {
        if moveToTrash {
            try FileManager.default.trashItem(at: workspace.url, resultingItemURL: nil)
        } else {
            try FileManager.default.removeItem(at: workspace.url)
        }
    }

    /// "Untitled Design", or "Untitled Design 2", 3, … if that name is taken.
    func nextUntitledName(base: String = "Untitled Design") -> String {
        let names = Set(list().map(\.name))
        guard names.contains(base) else { return base }
        var counter = 2
        while names.contains("\(base) \(counter)") { counter += 1 }
        return "\(base) \(counter)"
    }

    // MARK: - Chat transcript

    func transcriptURL(for workspace: Workspace) -> URL {
        workspace.url.appending(path: ".claudova/chat.json")
    }

    func loadTranscript(for workspace: Workspace) -> [ChatItem] {
        guard let data = try? Data(contentsOf: transcriptURL(for: workspace)) else { return [] }
        return (try? Self.decoder.decode([ChatItem].self, from: data)) ?? []
    }

    func saveTranscript(_ items: [ChatItem], for workspace: Workspace) throws {
        let url = transcriptURL(for: workspace)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(items).write(to: url, options: .atomic)
    }

    // MARK: - Cadova skill

    /// Replaces the workspace's vendored Cadova skill with the one shipped in the resolved
    /// Cadova checkout, so the guidance matches the Cadova version actually in use.
    /// Returns false if there's no checkout yet (before the first build).
    @discardableResult
    func refreshCadovaSkill(in workspace: Workspace) -> Bool {
        let fm = FileManager.default
        let source = workspace.buildDirectoryURL.appending(path: "checkouts/Cadova/Skills/cadova/SKILL.md")
        guard let data = fm.contents(atPath: source.path) else { return false }
        let destination = workspace.url.appending(path: ".claude/skills/cadova/SKILL.md")
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Checkout files are read-only; write a fresh writable copy rather than copying attributes.
            try data.write(to: destination, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Coding

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
