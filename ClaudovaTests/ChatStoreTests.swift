import Foundation
import Testing
@testable import Claudova

private func workspace(sessionID: String? = nil) -> Workspace {
    Workspace(
        url: URL(filePath: "/tmp/claudova-test-ws"),
        metadata: .init(name: "Test", createdAt: .now, lastOpenedAt: .now, claudeSessionID: sessionID)
    )
}

@MainActor
struct ChatStoreTests {
    private func waitForTurn(_ store: ChatStore) async throws {
        for _ in 0..<300 where store.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!store.isRunning)
    }

    private var transcript: (ChatStore) -> [ChatItem.Kind] { { $0.items.map(\.kind) } }

    @Test func rejectsBlankInputAndRequiresWorkspace() {
        let store = ChatStore(client: FakeClaude(turns: []))
        #expect(!store.send("hello"))          // no workspace yet
        store.open(workspace())
        #expect(!store.send("   \n"))
    }

    @Test func streamsTextAndToolActivity() async throws {
        let fake = FakeClaude(turns: [[
            .sessionStarted(sessionID: "s1", model: "m"),
            .thinking,
            .textStarted, .textDelta("Making a "), .textDelta("cube."),
            .tool(.init(id: "t1", name: "Edit", detail: nil)),
            .tool(.init(id: "t1", name: "Edit", detail: "main.swift")),
            .toolResult(id: "t1", isError: false, output: "ok"),
            .tool(.init(id: "t2", name: "Bash", detail: "Build")),
            .toolResult(id: "t2", isError: true, output: "error: boom\nmore"),
            .textStarted, .textDelta("Done!"),
            turnResult(),
        ]])
        let store = ChatStore(client: fake)
        var savedSession: String?
        var finished = 0
        store.onSessionStarted = { savedSession = $0 }
        store.afterTurn = { _, _ in finished += 1; return .none }
        store.open(workspace())

        #expect(store.send("  a 20 mm cube "))
        try await waitForTurn(store)

        #expect(Array(transcript(store).dropFirst()) == [
            .user("a 20 mm cube"),
            .assistant("Making a cube."),
            .tool(ToolActivity(toolUseID: "t1", name: "Edit", detail: "main.swift", status: .succeeded)),
            .tool(ToolActivity(toolUseID: "t2", name: "Bash", detail: "Build", status: .failed("error: boom"))),
            .assistant("Done!"),
        ])
        #expect(savedSession == "s1")
        #expect(store.sessionID == "s1")
        #expect(finished == 1)

        // First turn starts a new session.
        guard case .new = fake.calls.withLock({ $0[0].session }) else {
            Issue.record("expected a new session"); return
        }
    }

    @Test func resumesStoredSession() async throws {
        let fake = FakeClaude(turns: [[.textDelta("hi"), turnResult()]])
        let store = ChatStore(client: fake)
        store.open(workspace(sessionID: "existing"))
        store.send("again")
        try await waitForTurn(store)
        #expect(fake.calls.withLock { $0.map(\.session) } == [.resume("existing")])
    }

    @Test func startsNewSessionWhenResumeFails() async throws {
        let fake = FakeClaude(turns: [
            [.diagnostic("No conversation found with session ID: gone"), turnResult(isError: true, text: nil)],
            [.sessionStarted(sessionID: "fresh", model: nil), .textDelta("ok"), turnResult()],
        ])
        let store = ChatStore(client: fake)
        var saved: [String] = []
        store.onSessionStarted = { saved.append($0) }
        store.open(workspace(sessionID: "gone"))
        store.send("hello")
        try await waitForTurn(store)

        let sessions = fake.calls.withLock { $0.map(\.session) }
        #expect(sessions.count == 2)
        #expect(sessions.first == .resume("gone"))
        guard case .new = sessions.last else { Issue.record("expected retry with new session"); return }
        #expect(fake.calls.withLock { $0.map(\.prompt) } == ["hello", "hello"])
        #expect(saved == ["fresh"])
        #expect(store.items.contains { $0.kind == .assistant("ok") })
    }

    @Test func reportsErrorResultAndCrashDiagnostics() async throws {
        let fake = FakeClaude(turns: [
            [.tool(.init(id: "t", name: "Bash", detail: nil)), turnResult(isError: true, text: "Rate limited")],
            [.diagnostic("segfault"), .diagnostic("claude exited with status 1")],
        ])
        let store = ChatStore(client: fake)
        store.open(workspace(sessionID: "s"))

        store.send("one")
        try await waitForTurn(store)
        #expect(store.items.contains { $0.kind == .notice("Rate limited", isError: true) })
        // A tool that never reported back isn't left spinning.
        #expect(store.items.contains {
            if case .tool(let activity) = $0.kind { activity.status == .failed("Interrupted") } else { false }
        })

        store.send("two")
        try await waitForTurn(store)
        #expect(store.items.last?.kind == .notice("segfault\nclaude exited with status 1", isError: true))
    }
}
