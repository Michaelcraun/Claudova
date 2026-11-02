import Foundation
import Testing
@testable import Claudova

struct WorkspaceManagerTests {
    /// A manager rooted in a fresh temp directory, using the template bundled in the host app.
    private func makeManager() throws -> (WorkspaceManager, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ClaudovaTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let bundled = try WorkspaceManager.makeDefault()
        return (WorkspaceManager(projectsDirectory: root, templateURL: bundled.templateURL), root)
    }

    @Test func createCopiesTemplateAndWritesMetadata() throws {
        let (manager, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let workspace = try manager.create(named: "Phone Stand", now: date)

        let fm = FileManager.default
        #expect(workspace.url.lastPathComponent == "phone-stand")
        #expect(fm.fileExists(atPath: workspace.url.appending(path: "Package.swift").path))
        #expect(fm.fileExists(atPath: workspace.mainSourceURL.path))
        #expect(fm.fileExists(atPath: workspace.url.appending(path: "CLAUDE.md").path))
        #expect(fm.fileExists(atPath: workspace.url.appending(path: ".claude/skills/cadova/SKILL.md").path))
        // Permissions are passed on the claude command line, not via an (untrusted, ignored) settings file.
        #expect(!fm.fileExists(atPath: workspace.url.appending(path: ".claude/settings.json").path))
        #expect(!fm.fileExists(atPath: workspace.buildDirectoryURL.path))

        let loaded = try manager.load(at: workspace.url)
        #expect(loaded.metadata == workspace.metadata)
        #expect(loaded.name == "Phone Stand")
    }

    @Test func copiedSkillIsWritable() throws {
        let (manager, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = try manager.create(named: "Writable")
        let skill = workspace.url.appending(path: ".claude/skills/cadova/SKILL.md")
        #expect(FileManager.default.isWritableFile(atPath: skill.path))
    }

    @Test func duplicateNamesGetUniqueDirectories() throws {
        let (manager, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try manager.create(named: "Box")
        let second = try manager.create(named: "Box")
        #expect(first.url.lastPathComponent == "box")
        #expect(second.url.lastPathComponent == "box-2")
    }

    @Test func emptyNameIsRejected() throws {
        let (manager, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: WorkspaceError.self) { try manager.create(named: "   ") }
    }

    @Test func listIsSortedByLastOpened() throws {
        let (manager, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        let old = try manager.create(named: "Old", now: Date(timeIntervalSince1970: 1_000))
        _ = try manager.create(named: "Middle", now: Date(timeIntervalSince1970: 2_000))
        _ = try manager.markOpened(old, now: Date(timeIntervalSince1970: 3_000))

        #expect(manager.list().map(\.name) == ["Old", "Middle"])
    }

    @Test(arguments: [
        ("Phone Stand", "phone-stand"),
        ("  Café — Mug Holder! ", "cafe-mug-holder"),
        ("M3 bolt / spacer", "m3-bolt-spacer"),
        ("!!!", "design"),
    ])
    func slug(name: String, expected: String) {
        #expect(WorkspaceManager.slug(for: name) == expected)
    }
}
