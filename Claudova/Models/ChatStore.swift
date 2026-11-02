import Foundation
import Observation

/// Abstraction over `ClaudeClient` so the store can be tested with scripted events.
protocol ClaudeTurnRunning: Sendable {
    func send(_ prompt: String, session: ClaudeClient.Session, in workspaceURL: URL) -> AsyncThrowingStream<ClaudeEvent, Error>
}

extension ClaudeClient: ClaudeTurnRunning {}

/// What the app wants to happen after a Claude turn (see `ChatStore.afterTurn`).
enum TurnFollowUp: Equatable, Sendable {
    /// Nothing to add.
    case none
    /// Show a status line in the chat.
    case notice(String, isError: Bool)
    /// Show a status line, then automatically send `prompt` to Claude in the same conversation
    /// (used to ask Claude to fix a failed build).
    case send(prompt: String, notice: String)
}

/// The conversation with Claude for the open design workspace.
@MainActor
@Observable
final class ChatStore {
    static let welcome = "Describe a 3D model you'd like to design, including any sizes that matter."

    private(set) var items: [ChatItem] = [ChatItem(.notice(welcome, isError: false))]
    private(set) var isRunning = false
    /// True while Claude is working but hasn't produced visible text for the current step yet.
    private(set) var isWaitingForText = false
    /// What the working indicator says while a turn (or its post-turn check) is running.
    private(set) var activity: String?
    /// True while the post-turn check (`afterTurn`) runs.
    private(set) var isCheckingBuild = false
    private(set) var workspace: Workspace?
    private(set) var sessionID: String?

    /// Called when Claude Code reports a (new) session ID, so it can be persisted for `--resume`.
    @ObservationIgnored var onSessionStarted: ((String) -> Void)?
    /// Called with the transcript (minus the intro line) whenever it should be saved: after the
    /// user sends a message and when a turn ends.
    @ObservationIgnored var onTranscriptChanged: (([ChatItem]) -> Void)?
    /// Runs after every turn Claude completed (not after Stop), while the chat stays busy.
    /// The second argument is how many automatic follow-ups are still allowed for the current
    /// user message; a `.send` is ignored once that reaches zero.
    @ObservationIgnored var afterTurn: ((ClaudeEvent.TurnResult, Int) async -> TurnFollowUp)?
    /// Automatic follow-ups (fix attempts) allowed per user message.
    static let maxAutomaticFollowUps = 2
    @ObservationIgnored private var remainingFollowUps = 0

    @ObservationIgnored private let client: any ClaudeTurnRunning
    @ObservationIgnored private var turnTask: Task<Void, Never>?
    /// Index into `items` of the assistant message currently receiving text deltas.
    @ObservationIgnored private var streamingIndex: Int?
    @ObservationIgnored private var diagnostics: [String] = []
    @ObservationIgnored private var lastResult: ClaudeEvent.TurnResult?
    @ObservationIgnored private var introIDs: Set<UUID> = []
    /// Bumped when switching workspaces; a turn from an older generation must not touch state.
    @ObservationIgnored private var generation = 0

    init(client: any ClaudeTurnRunning = ClaudeClient()) {
        self.client = client
    }

    /// Switches the chat to a workspace, showing its saved transcript and resuming its stored
    /// Claude session on the next message.
    func open(_ workspace: Workspace, transcript: [ChatItem] = []) {
        guard workspace.id != self.workspace?.id else { return }
        stop()
        turnTask = nil
        generation += 1
        isRunning = false
        isWaitingForText = false
        isCheckingBuild = false
        activity = nil
        self.workspace = workspace
        sessionID = workspace.metadata.claudeSessionID

        // A transcript saved mid-turn may have tools that never finished.
        let restored = transcript.map { item -> ChatItem in
            guard case .tool(var activity) = item.kind, activity.status == .running else { return item }
            activity.status = .failed("Interrupted")
            return ChatItem(id: item.id, .tool(activity))
        }
        var intro = [ChatItem(.notice(Self.welcome, isError: false))]
        if sessionID != nil, restored.isEmpty {
            // E.g. designs from before transcripts were saved.
            intro.append(ChatItem(.notice("Continuing your previous conversation about this design.", isError: false)))
        }
        introIDs = Set(intro.map(\.id))
        items = intro + restored
    }

    /// The transcript as saved: everything except the intro lines, which are rebuilt on open.
    var persistableItems: [ChatItem] {
        items.filter { !introIDs.contains($0.id) }
    }

    private func persist() {
        onTranscriptChanged?(persistableItems)
    }

    // MARK: - Turns

    /// Sends a user message. Returns false if it was empty or a turn is already running.
    @discardableResult
    func send(_ text: String) -> Bool {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isRunning, let workspace else { return false }
        items.append(ChatItem(.user(prompt)))
        persist()
        let session: ClaudeClient.Session = sessionID.map { .resume($0) } ?? .new(UUID().uuidString.lowercased())
        remainingFollowUps = Self.maxAutomaticFollowUps
        isRunning = true
        turnTask = Task {
            await runTurn(prompt, session: session, workspaceURL: workspace.url)
            // Only save into the workspace this turn belonged to.
            if self.workspace?.id == workspace.id { persist() }
        }
        return true
    }

    /// Cancels the running turn (terminates the `claude` process).
    func stop() {
        turnTask?.cancel()
        turnTask = nil
    }

    private func runTurn(_ prompt: String, session: ClaudeClient.Session, workspaceURL: URL) async {
        let generation = generation
        beginTurn()
        do {
            for try await event in client.send(prompt, session: session, in: workspaceURL) {
                guard generation == self.generation else { return }
                apply(event)
            }
        } catch is CancellationError {
            // Handled below.
        } catch {
            guard generation == self.generation else { return }
            appendNotice(error.localizedDescription, isError: true)
        }
        // The chat moved on to another workspace while this turn was ending.
        guard generation == self.generation else { return }

        if Task.isCancelled {
            endTurn(toolStatus: .failed("Stopped"))
            appendNotice("Stopped.", isError: false)
            return
        }

        // An unknown/expired session: start a new conversation and resend the message.
        if case .resume = session, lastResult?.isError ?? true,
           diagnostics.contains(where: { $0.contains("No conversation found") }) {
            sessionID = nil
            appendNotice("Couldn't resume the previous conversation, so I started a new one.", isError: false)
            await runTurn(prompt, session: .new(UUID().uuidString.lowercased()), workspaceURL: workspaceURL)
            return
        }

        endTurn(toolStatus: .failed("Interrupted"))
        guard let result = lastResult else {
            if !diagnostics.isEmpty {
                appendNotice(diagnostics.suffix(5).joined(separator: "\n"), isError: true)
            }
            return
        }
        if result.isError {
            let message = result.resultText.flatMap { $0.isEmpty ? nil : $0 } ?? "Claude stopped with an error (\(result.subtype))."
            appendNotice(message, isError: true)
        }

        // Post-turn check (the app's build), still inside the turn so Stop cancels it too.
        guard let afterTurn else { return }
        isRunning = true
        isCheckingBuild = true
        activity = "Checking the build…"
        let followUp = await afterTurn(result, remainingFollowUps)
        guard generation == self.generation else { return }
        isRunning = false
        isCheckingBuild = false
        activity = nil
        guard !Task.isCancelled else {
            appendNotice("Stopped.", isError: false)
            return
        }
        switch followUp {
        case .none:
            break
        case .notice(let text, let isError):
            appendNotice(text, isError: isError)
        case .send(let prompt, let notice):
            guard remainingFollowUps > 0, let sessionID else { return }
            remainingFollowUps -= 1
            appendNotice(notice, isError: true)
            isRunning = true
            await runTurn(prompt, session: .resume(sessionID), workspaceURL: workspaceURL)
        }
    }

    private func beginTurn() {
        isRunning = true
        isWaitingForText = true
        activity = "Claude is working…"
        streamingIndex = nil
        diagnostics = []
        lastResult = nil
    }

    private func endTurn(toolStatus: ToolActivity.Status) {
        // Any tool still marked running never reported back.
        for index in items.indices {
            if case .tool(var activity) = items[index].kind, activity.status == .running {
                activity.status = toolStatus
                items[index].kind = .tool(activity)
            }
        }
        streamingIndex = nil
        isWaitingForText = false
        isRunning = false
        activity = nil
    }

    // MARK: - Events

    /// Applies one stream event to the transcript. Internal for testing.
    func apply(_ event: ClaudeEvent) {
        switch event {
        case .sessionStarted(let id, _):
            if id != sessionID {
                sessionID = id
                onSessionStarted?(id)
            }

        case .thinking:
            isWaitingForText = true

        case .textStarted:
            streamingIndex = nil

        case .textDelta(let text):
            isWaitingForText = false
            if let index = streamingIndex, case .assistant(let existing) = items[index].kind {
                items[index].kind = .assistant(existing + text)
            } else {
                items.append(ChatItem(.assistant(text)))
                streamingIndex = items.count - 1
            }

        case .tool(let call):
            streamingIndex = nil
            isWaitingForText = true
            if let index = toolIndex(call.id), case .tool(var activity) = items[index].kind {
                activity.detail = call.detail ?? activity.detail
                items[index].kind = .tool(activity)
            } else {
                items.append(ChatItem(.tool(ToolActivity(toolUseID: call.id, name: call.name, detail: call.detail, status: .running))))
            }

        case .toolResult(let id, let isError, let output):
            guard let index = toolIndex(id), case .tool(var activity) = items[index].kind else { return }
            activity.status = isError ? .failed(Self.firstLine(of: output)) : .succeeded
            items[index].kind = .tool(activity)

        case .finished(let result):
            lastResult = result

        case .diagnostic(let line):
            diagnostics.append(line)
        }
    }

    private func toolIndex(_ id: String) -> Int? {
        items.lastIndex { item in
            if case .tool(let activity) = item.kind { activity.toolUseID == id } else { false }
        }
    }

    private func appendNotice(_ text: String, isError: Bool) {
        items.append(ChatItem(.notice(text, isError: isError)))
    }

    private static func firstLine(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 200 ? String(line.prefix(200)) + "…" : line
    }
}
