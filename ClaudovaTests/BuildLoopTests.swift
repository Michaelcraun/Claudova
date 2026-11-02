import Foundation
import Synchronization
import Testing
@testable import Claudova

@MainActor
private func waitUntilIdle(_ store: ChatStore) async throws {
    for _ in 0..<500 where store.isRunning {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!store.isRunning)
}

private func testWorkspace() -> Workspace {
    Workspace(
        url: URL(filePath: "/tmp/claudova-test-ws"),
        metadata: .init(name: "Test", createdAt: .now, lastOpenedAt: .now, claudeSessionID: "s")
    )
}

/// The follow-up mechanics in ChatStore, with a scripted `afterTurn`.
@MainActor
struct ChatFollowUpTests {
    @Test func sendFollowUpResumesSessionWithPrompt() async throws {
        let fake = FakeClaude(turns: [[.textDelta("v1"), turnResult()], [.textDelta("fixed"), turnResult()]])
        let store = ChatStore(client: fake)
        var calls: [Int] = []
        store.afterTurn = { _, remaining in
            calls.append(remaining)
            return calls.count == 1 ? .send(prompt: "please fix", notice: "Fixing…") : .none
        }
        store.open(testWorkspace())
        store.send("make a thing")
        try await waitUntilIdle(store)

        #expect(fake.prompts == ["make a thing", "please fix"])
        #expect(fake.sessions == [.resume("s"), .resume("s")])
        #expect(calls == [2, 1])
        // The automatic prompt isn't shown as a user bubble; the notice is.
        #expect(!store.items.contains { $0.kind == .user("please fix") })
        #expect(store.items.contains { $0.kind == .notice("Fixing…", isError: true) })
        #expect(store.items.last?.kind == .assistant("fixed"))
    }

    @Test func automaticFollowUpsAreBounded() async throws {
        let fake = FakeClaude(turns: Array(repeating: [turnResult()], count: 5))
        let store = ChatStore(client: fake)
        var remainingSeen: [Int] = []
        store.afterTurn = { _, remaining in
            remainingSeen.append(remaining)
            return .send(prompt: "fix", notice: "again")
        }
        store.open(testWorkspace())
        store.send("go")
        try await waitUntilIdle(store)

        #expect(fake.prompts == ["go", "fix", "fix"])
        #expect(remainingSeen == [2, 1, 0])

        // A new user message gets a fresh budget.
        remainingSeen = []
        store.send("again")
        try await waitUntilIdle(store)
        #expect(remainingSeen.first == 2)
    }

    @Test func noticeFollowUpIsShown() async throws {
        let store = ChatStore(client: FakeClaude(turns: [[turnResult()]]))
        store.afterTurn = { _, _ in .notice("Doesn't build.", isError: true) }
        store.open(testWorkspace())
        store.send("go")
        try await waitUntilIdle(store)
        #expect(store.items.last?.kind == .notice("Doesn't build.", isError: true))
    }

    @Test func afterTurnSkippedWhenClaudeProducedNoResult() async throws {
        let store = ChatStore(client: FakeClaude(turns: [[.diagnostic("crash")]]))
        var called = false
        store.afterTurn = { _, _ in called = true; return .none }
        store.open(testWorkspace())
        store.send("go")
        try await waitUntilIdle(store)
        #expect(!called)
    }
}

/// AppModel's post-turn build check and fix loop, against a real (temporary) workspace on disk.
@MainActor
struct AppModelBuildLoopTests {
    private func makeApp(builds: [Bool], turns: [[ClaudeEvent]]) async throws -> (AppModel, FakeBuilder, FakeClaude, Workspace, URL) {
        let (manager, root) = try makeTemporaryManager()
        let workspace = try manager.create(named: "Loop")
        // Pretend the workspace has been built before, so opening doesn't count as a first build.
        try FileManager.default.createDirectory(at: workspace.buildDirectoryURL, withIntermediateDirectories: true)
        let builder = FakeBuilder(builds)
        let claude = FakeClaude(turns: turns)
        let app = AppModel(manager: manager, chat: ChatStore(client: claude), builder: builder)
        await app.open(workspace)
        return (app, builder, claude, workspace, root)
    }

    @Test func upToDateOutputSkipsTheBuild() async throws {
        let (app, builder, _, _, root) = try await makeApp(builds: [true], turns: [])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(builder.callCount.withLock { $0 } == 1)  // opening built the missing model

        let followUp = await app.afterClaudeTurn(.init(isError: false, subtype: "success", resultText: nil, sessionID: nil,
                                                       durationMS: nil, costUSD: nil, permissionDenials: 0), remainingFixes: 2)
        #expect(followUp == .none)
        #expect(builder.callCount.withLock { $0 } == 1)
        #expect(app.status == .ready)
    }

    @Test func staleOutputIsRebuilt() async throws {
        let (app, builder, _, workspace, root) = try await makeApp(builds: [true, true], turns: [])
        defer { try? FileManager.default.removeItem(at: root) }
        try touch(workspace.mainSourceURL)

        let followUp = await app.afterClaudeTurn(.init(isError: false, subtype: "success", resultText: nil, sessionID: nil,
                                                       durationMS: nil, costUSD: nil, permissionDenials: 0), remainingFixes: 2)
        #expect(followUp == .none)
        #expect(builder.callCount.withLock { $0 } == 2)
        #expect(ModelBuilder.isOutputUpToDate(workspace))
    }

    @Test func failedBuildAsksClaudeToFix() async throws {
        let (app, _, _, workspace, root) = try await makeApp(builds: [true, false], turns: [])
        defer { try? FileManager.default.removeItem(at: root) }
        try touch(workspace.mainSourceURL)

        let success = ClaudeEvent.TurnResult(isError: false, subtype: "success", resultText: nil, sessionID: nil,
                                             durationMS: nil, costUSD: nil, permissionDenials: 0)
        guard case .send(let prompt, let notice) = await app.afterClaudeTurn(success, remainingFixes: 2) else {
            Issue.record("expected a fix request"); return
        }
        #expect(prompt.contains("cannot find 'Boxx' in scope"))
        #expect(prompt.hasPrefix("[Automatic message from the Claudova app"))
        #expect(notice.contains("attempt 1 of 2"))
    }

    @Test func noAutoFixAfterClaudeErrorOrWhenOutOfAttempts() async throws {
        let (app, _, _, workspace, root) = try await makeApp(builds: [true, false, false], turns: [])
        defer { try? FileManager.default.removeItem(at: root) }
        try touch(workspace.mainSourceURL)

        let failed = ClaudeEvent.TurnResult(isError: true, subtype: "error", resultText: nil, sessionID: nil,
                                            durationMS: nil, costUSD: nil, permissionDenials: 0)
        guard case .notice = await app.afterClaudeTurn(failed, remainingFixes: 2) else {
            Issue.record("expected a notice"); return
        }
        let success = ClaudeEvent.TurnResult(isError: false, subtype: "success", resultText: nil, sessionID: nil,
                                             durationMS: nil, costUSD: nil, permissionDenials: 0)
        guard case .notice = await app.afterClaudeTurn(success, remainingFixes: 0) else {
            Issue.record("expected a notice"); return
        }
    }

    /// The whole loop: Claude's edit breaks the build, the app asks for a fix, the fix builds.
    @Test func endToEndFixLoop() async throws {
        let (app, builder, claude, workspace, root) = try await makeApp(
            builds: [true, false, true],
            turns: [
                [.sessionStarted(sessionID: "sess", model: nil), .textDelta("Added a box."), turnResult()],
                [.textDelta("Fixed the typo."), turnResult()],
            ]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        // Claude "edits" the source during its turn.
        try touch(workspace.mainSourceURL)
        app.chat.send("add a box")
        try await waitUntilIdle(app.chat)

        #expect(claude.prompts.count == 2)
        #expect(claude.prompts.last?.hasPrefix("[Automatic message") == true)
        #expect(claude.sessions.last == .resume("sess"))
        #expect(builder.callCount.withLock { $0 } == 3)  // open, failed check, successful check
        #expect(app.status == .ready)
        #expect(app.chat.items.contains { if case .notice(let text, true) = $0.kind { text.contains("attempt 1 of 2") } else { false } })
        #expect(app.chat.items.last?.kind == .assistant("Fixed the typo."))
    }
}

struct OutputFreshnessTests {
    @Test func comparesModelAgainstNewestSource() throws {
        let (manager, root) = try makeTemporaryManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try manager.create(named: "Fresh")

        #expect(!ModelBuilder.isOutputUpToDate(workspace))  // no model yet

        try FileManager.default.createDirectory(at: workspace.modelOutputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: workspace.modelOutputURL)
        try touch(workspace.modelOutputURL, at: .now.addingTimeInterval(10))
        #expect(ModelBuilder.isOutputUpToDate(workspace))

        // A new file in a subdirectory of Sources counts too.
        let nested = workspace.url.appending(path: "Sources/Model/Parts/Bracket.swift")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: nested)
        try touch(nested, at: .now.addingTimeInterval(20))
        #expect(!ModelBuilder.isOutputUpToDate(workspace))
    }
}
