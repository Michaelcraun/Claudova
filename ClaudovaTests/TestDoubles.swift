import Foundation
import Synchronization
@testable import Claudova

/// Replays scripted Claude turns and records what it was asked to send.
final class FakeClaude: ClaudeTurnRunning {
    private let turns: Mutex<[[ClaudeEvent]]>
    let calls = Mutex<[(prompt: String, session: ClaudeClient.Session)]>([])

    init(turns: [[ClaudeEvent]]) {
        self.turns = Mutex(turns)
    }

    var prompts: [String] { calls.withLock { $0.map(\.prompt) } }
    var sessions: [ClaudeClient.Session] { calls.withLock { $0.map(\.session) } }

    func send(_ prompt: String, session: ClaudeClient.Session, in workspaceURL: URL) -> AsyncThrowingStream<ClaudeEvent, Error> {
        calls.withLock { $0.append((prompt, session)) }
        let events = turns.withLock { $0.isEmpty ? [] : $0.removeFirst() }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

/// Scripted builds. A successful build writes the model file with a modification date just after
/// the newest source, so `ModelBuilder.isOutputUpToDate` sees it as fresh.
final class FakeBuilder: ModelBuilding {
    private let outcomes: Mutex<[Bool]>
    let callCount = Mutex(0)

    init(_ outcomes: [Bool]) {
        self.outcomes = Mutex(outcomes)
    }

    func build(_ workspace: Workspace, onLine: (@Sendable (String) -> Void)?) async throws -> BuildOutcome {
        callCount.withLock { $0 += 1 }
        let succeeds = outcomes.withLock { $0.isEmpty ? true : $0.removeFirst() }
        guard succeeds else {
            return BuildOutcome(
                result: ProcessResult(exitCode: 1, output: "Building…\n/w/Sources/Model/main.swift:3:5: error: cannot find 'Boxx' in scope"),
                modelURL: nil, duration: .zero
            )
        }
        let url = workspace.modelOutputURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("3mf".utf8).write(to: url)
        let stamp = (ModelBuilder.newestInputDate(in: workspace) ?? .now).addingTimeInterval(1)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
        return BuildOutcome(result: ProcessResult(exitCode: 0, output: "Wrote model to \(url.path)"), modelURL: url, duration: .zero)
    }
}

func turnResult(isError: Bool = false, text: String? = "done") -> ClaudeEvent {
    .finished(.init(isError: isError, subtype: isError ? "error_during_execution" : "success", resultText: text,
                    sessionID: nil, durationMS: 10, costUSD: 0, permissionDenials: 0))
}

/// A workspace manager rooted in a fresh temporary directory, using the bundled template.
func makeTemporaryManager() throws -> (WorkspaceManager, URL) {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "ClaudovaTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let bundled = try WorkspaceManager.makeDefault()
    return (WorkspaceManager(projectsDirectory: root, templateURL: bundled.templateURL), root)
}

/// Marks a file as edited at `date` (default: a minute from now, i.e. newer than any build).
func touch(_ url: URL, at date: Date = .now.addingTimeInterval(60)) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}
