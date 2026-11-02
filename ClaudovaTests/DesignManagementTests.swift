import Foundation
import Testing
@testable import Claudova

struct WorkspaceManagementTests {
    @Test func renameKeepsDirectoryAndPersists() throws {
        let (manager, root) = try makeTemporaryManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let design = try manager.create(named: "Box")

        let renamed = try manager.rename(design, to: "  Phone Stand ")
        #expect(renamed.name == "Phone Stand")
        #expect(renamed.url == design.url)
        #expect(try manager.load(at: design.url).name == "Phone Stand")
        #expect(throws: WorkspaceError.self) { try manager.rename(design, to: " ") }
    }

    @Test func deleteRemovesDesign() throws {
        let (manager, root) = try makeTemporaryManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let design = try manager.create(named: "Doomed")

        try manager.delete(design, moveToTrash: false)  // tests must not litter the real Trash
        #expect(!FileManager.default.fileExists(atPath: design.url.path))
        #expect(manager.list().isEmpty)
    }

    @Test func untitledNamesAreNumbered() throws {
        let (manager, root) = try makeTemporaryManager()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(manager.nextUntitledName() == "Untitled Design")
        _ = try manager.create(named: manager.nextUntitledName())
        #expect(manager.nextUntitledName() == "Untitled Design 2")
        _ = try manager.create(named: manager.nextUntitledName())
        #expect(manager.nextUntitledName() == "Untitled Design 3")
    }

    @Test func transcriptRoundTrips() throws {
        let (manager, root) = try makeTemporaryManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let design = try manager.create(named: "Chatty")

        #expect(manager.loadTranscript(for: design).isEmpty)
        let items = [
            ChatItem(.user("a cube")),
            ChatItem(.assistant("Done **cube**.")),
            ChatItem(.tool(ToolActivity(toolUseID: "t", name: "Bash", detail: "Build", status: .failed("boom")))),
            ChatItem(.notice("Stopped.", isError: false)),
        ]
        try manager.saveTranscript(items, for: design)
        #expect(manager.loadTranscript(for: design) == items)
    }
}

@MainActor
struct ChatTranscriptTests {
    private func workspace(sessionID: String? = "s") -> Workspace {
        Workspace(url: URL(filePath: "/tmp/claudova-ws-\(UUID().uuidString)"),
                  metadata: .init(name: "T", createdAt: .now, lastOpenedAt: .now, claudeSessionID: sessionID))
    }

    @Test func restoresTranscriptAndMarksUnfinishedToolsInterrupted() {
        let store = ChatStore(client: FakeClaude(turns: []))
        let saved = [
            ChatItem(.user("hi")),
            ChatItem(.tool(ToolActivity(toolUseID: "t", name: "Edit", detail: nil, status: .running))),
        ]
        store.open(workspace(), transcript: saved)

        #expect(store.items.count == 3)  // intro + 2
        #expect(store.persistableItems.map(\.id) == saved.map(\.id))
        guard case .tool(let activity) = store.items.last?.kind else { Issue.record("expected tool"); return }
        #expect(activity.status == .failed("Interrupted"))
        // With a transcript there's no need for the "continuing" hint.
        #expect(!store.items.contains { if case .notice(let text, _) = $0.kind { text.contains("Continuing") } else { false } })
    }

    @Test func savesAfterSendAndAfterTurn() async throws {
        let store = ChatStore(client: FakeClaude(turns: [[.textDelta("reply"), turnResult()]]))
        var saves: [[ChatItem]] = []
        store.onTranscriptChanged = { saves.append($0) }
        store.open(workspace())
        store.send("hello")
        for _ in 0..<300 where store.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(20))

        #expect(saves.count == 2)
        #expect(saves.first?.map(\.kind) == [.user("hello")])
        #expect(saves.last?.map(\.kind) == [.user("hello"), .assistant("reply")])
    }
}

@MainActor
struct AppDesignManagementTests {
    private func makeApp() async throws -> (AppModel, WorkspaceManager, URL) {
        let (manager, root) = try makeTemporaryManager()
        let app = AppModel(manager: manager, chat: ChatStore(client: FakeClaude(turns: [])), builder: FakeBuilder([]))
        return (app, manager, root)
    }

    @Test func createOpenRenameAndSwitch() async throws {
        let (app, _, root) = try await makeApp()
        defer { try? FileManager.default.removeItem(at: root) }

        await app.createDesign()
        let first = try #require(app.workspace)
        #expect(first.name == "Untitled Design")

        await app.createDesign()
        let second = try #require(app.workspace)
        #expect(second.name == "Untitled Design 2")
        #expect(app.designs.map(\.name) == ["Untitled Design 2", "Untitled Design"])  // newest first

        app.rename(first, to: "Bracket")
        #expect(app.designs.map(\.name) == ["Untitled Design 2", "Bracket"])

        await app.openDesign(id: first.id)
        #expect(app.workspace?.name == "Bracket")
        #expect(app.chat.workspace?.id == first.id)
        // Opening doesn't reorder the sidebar.
        #expect(app.designs.map(\.name) == ["Untitled Design 2", "Bracket"])
    }

    @Test func deletingOpenDesignOpensAnother() async throws {
        let (app, _, root) = try await makeApp()
        defer { try? FileManager.default.removeItem(at: root) }

        await app.createDesign()
        let first = try #require(app.workspace)
        await app.createDesign()
        let second = try #require(app.workspace)

        await app.delete(second, moveToTrash: false)
        #expect(app.workspace?.id == first.id)
        #expect(app.designs.map(\.id) == [first.id])

        // Deleting the last design leaves a fresh one rather than nothing.
        await app.delete(first, moveToTrash: false)
        // (It reuses the freed "untitled-design" folder name, so the ID may match the old one.)
        #expect(app.designs.count == 1)
        let replacement = try #require(app.workspace)
        #expect(FileManager.default.fileExists(atPath: replacement.metadataURL.path))
        #expect(app.chat.persistableItems.isEmpty)
    }

    @Test func transcriptFollowsTheDesign() async throws {
        let claude = FakeClaude(turns: [[.sessionStarted(sessionID: "a", model: nil), .textDelta("A reply"), turnResult()]])
        let (manager, root) = try makeTemporaryManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(manager: manager, chat: ChatStore(client: claude), builder: FakeBuilder([]))

        await app.createDesign()
        let first = try #require(app.workspace)
        app.chat.send("design A")
        for _ in 0..<300 where app.chat.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(20))

        await app.createDesign()
        #expect(!app.chat.items.contains { $0.kind == .user("design A") })

        await app.openDesign(id: first.id)
        #expect(app.chat.items.contains { $0.kind == .user("design A") })
        #expect(app.chat.items.contains { $0.kind == .assistant("A reply") })
        #expect(app.workspace?.metadata.claudeSessionID == "a")
    }
}
