import Foundation

enum ClaudeClientError: LocalizedError {
    case executableNotFound

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "Couldn't find the `claude` command. Install Claude Code (https://claude.com/claude-code) and sign in, then try again."
        }
    }
}

/// Runs one headless Claude Code turn per call inside a design workspace.
struct ClaudeClient: Sendable {
    enum Session: Equatable, Sendable {
        /// Start a new conversation with this ID.
        case new(String)
        /// Continue an existing conversation.
        case resume(String)

        var id: String {
            switch self {
            case .new(let id), .resume(let id): id
            }
        }
    }

    /// Built-in tools Claude may use at all. (Grep/Glob aren't separate tools in current
    /// Claude Code builds; searching goes through Bash.) No Skill tool: `--safe-mode` disables
    /// skills, and the Cadova skill's text is appended to the system prompt instead.
    static let tools = ["Bash", "Read", "Edit", "Write"]

    /// Shell commands Claude may run (each becomes a `Bash(<prefix>:*)` permission rule and is
    /// listed in the system prompt, so Claude knows exactly what will work).
    static let allowedCommands = [
        "swift build", "swift run", "swift test", "swift package resolve",
        "ls", "cat", "head", "tail", "wc", "grep", "rg", "test", "mkdir",
        "\"/Applications/Cadova Viewer.app/Contents/Helpers/cadova-viewer\"",
    ]

    /// Tool uses that run without asking. With `--permission-mode dontAsk`, everything else is
    /// denied, and Claude is told so. These are passed on the command line because the workspace's
    /// own `.claude/settings.json` is ignored until the folder is trusted interactively, and
    /// because the app, not a file Claude can edit, should decide what's allowed.
    static let allowedTools = ["Read", "Edit", "Write"] + allowedCommands.map { "Bash(\($0):*)" }

    static func arguments(session: Session, model: String? = nil, systemPrompt: String? = nil) -> [String] {
        var arguments = [
            "-p",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--permission-mode", "dontAsk",
            "--permission-prompts", "none",
            // Ignore every CLAUDE.md, skill, hook, plugin and MCP server from the user's setup
            // (their global instructions are for their own coding work, not this app). Auth,
            // tools and permissions still work. The app supplies the context via --append-system-prompt.
            "--safe-mode",
            "--strict-mcp-config",
            "--tools", tools.joined(separator: ","),
            "--allowedTools",
        ]
        arguments += allowedTools
        switch session {
        case .new(let id): arguments += ["--session-id", id]
        case .resume(let id): arguments += ["--resume", id]
        }
        if let model { arguments += ["--model", model] }
        if let systemPrompt { arguments += ["--append-system-prompt", systemPrompt] }
        return arguments
    }

    var model: String?

    /// Streams the events of one turn. The prompt goes over stdin so it can never be mistaken
    /// for a flag. Cancelling the consuming task terminates the `claude` process.
    func send(_ prompt: String, session: Session, in workspaceURL: URL) -> AsyncThrowingStream<ClaudeEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ClaudeEvent.self)
        let arguments = Self.arguments(
            session: session, model: model, systemPrompt: Self.systemPrompt(forWorkspaceAt: workspaceURL)
        )
        let task = Task {
            do {
                let environment = await ShellEnvironment.shared.environment()
                guard let executable = await ShellEnvironment.shared.which("claude") else {
                    throw ClaudeClientError.executableNotFound
                }
                let result = try await ProcessRunner.run(
                    executable,
                    arguments: arguments,
                    currentDirectory: workspaceURL,
                    environment: environment,
                    input: Data(prompt.utf8),
                    onLine: { line in
                        for event in ClaudeEventParser.parse(line: line) { continuation.yield(event) }
                    }
                )
                if !result.succeeded {
                    continuation.yield(.diagnostic("claude exited with status \(result.exitCode)"))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

// MARK: - System prompt

extension ClaudeClient {
    /// Context appended to Claude Code's system prompt: the permission rules, the workspace's
    /// CLAUDE.md, and the Cadova skill (kept in the workspace, refreshed from the Cadova checkout).
    static func systemPrompt(forWorkspaceAt url: URL) -> String {
        func read(_ path: String) -> String? {
            try? String(contentsOf: url.appending(path: path), encoding: .utf8)
        }
        var sections = [permissionsSection]
        if let instructions = read("CLAUDE.md") {
            sections.append(instructions)
        }
        if let skill = read(".claude/skills/cadova/SKILL.md") {
            sections.append("# Cadova reference (from the Cadova skill)\n\n" + stripFrontMatter(skill))
        }
        return sections.joined(separator: "\n\n---\n\n")
    }

    static var permissionsSection: String {
        let commands = allowedCommands.map { "- `\($0) …`" }.joined(separator: "\n")
        return """
        # Tool permissions in this session

        You can use Read, Edit and Write on files in this workspace. Bash commands are restricted:
        only commands starting with one of these prefixes are allowed, and anything else is denied
        automatically (the user can't approve it):

        \(commands)

        Run one command per Bash call. Don't chain with `&&`, `;` or `|`: each part of a chained
        command must be allowed on its own, so one disallowed part blocks the whole call. If a
        command is denied, use an allowed alternative rather than concluding that commands can't run.
        `swift run` (to build the model) is always allowed.
        """
    }

    static func stripFrontMatter(_ text: String) -> String {
        guard text.hasPrefix("---\n"),
              let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex)
        else { return text }
        return String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
