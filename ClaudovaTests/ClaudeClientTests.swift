import Foundation
import Testing
@testable import Claudova

struct ClaudeEventParserTests {
    private func events(fromFixture name: String) throws -> [ClaudeEvent] {
        let bundle = try #require(Bundle(identifier: "com.mietech.ClaudovaTests"))
        let url = try #require(bundle.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .flatMap { ClaudeEventParser.parse(line: String($0)) }
    }

    @Test func parsesTextTurn() throws {
        let events = try events(fromFixture: "claude-turn-text")
        #expect(events.first == .sessionStarted(sessionID: "a6e1be86-07e0-4b8f-b50a-1dd7030ab9f0", model: "claude-haiku-5-5"))
        let text = events.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined()
        #expect(text == "pong\nno")
        #expect(events.contains(.thinking))
        guard case .finished(let result) = events.last else { Issue.record("no result"); return }
        #expect(!result.isError)
        #expect(result.resultText == "pong\nno")
    }

    @Test func parsesToolCallsResultsAndDenials() throws {
        let events = try events(fromFixture: "claude-turn-tools")
        let tools = events.compactMap { if case .tool(let call) = $0 { call } else { nil } }
        // Each call is announced when it starts streaming, then again with its full input.
        #expect(tools.map(\.name) == ["Bash", "Bash", "Bash", "Bash"])
        #expect(tools.filter { $0.detail != nil }.map(\.detail) == ["List files in Sources/Model", "Fetch HTTP headers from example.com"])

        let results = events.compactMap { if case .toolResult(_, let isError, let output) = $0 { (isError, output) } else { nil } }
        #expect(results.count == 2)
        #expect(results[0] == (false, "main.swift"))
        #expect(results[1].0 == true)
        #expect(results[1].1.contains("denied"))

        guard case .finished(let result) = events.last else { Issue.record("no result"); return }
        #expect(result.permissionDenials == 1)
    }

    @Test func nonJSONLinesBecomeDiagnostics() {
        #expect(ClaudeEventParser.parse(line: "No conversation found with session ID: x")
                == [.diagnostic("No conversation found with session ID: x")])
        #expect(ClaudeEventParser.parse(line: "   ").isEmpty)
    }

    @Test func ignoresSubagentMessages() {
        let line = #"{"type":"stream_event","parent_tool_use_id":"toolu_1","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"x"}}}"#
        #expect(ClaudeEventParser.parse(line: line).isEmpty)
    }

    @Test func toolDetails() {
        #expect(ClaudeEventParser.toolDetail(name: "Edit", input: ["file_path": "/w/Sources/Model/main.swift"]) == "main.swift")
        #expect(ClaudeEventParser.toolDetail(name: "Bash", input: ["command": "swift run\necho hi"]) == "swift run")
        #expect(ClaudeEventParser.toolDetail(name: "Bash", input: ["command": "swift run", "description": "Build"]) == "Build")
        #expect(ClaudeEventParser.toolDetail(name: "Skill", input: ["skill": "cadova"]) == "cadova")
        #expect(ClaudeEventParser.toolDetail(name: "Mystery", input: [:]) == nil)
    }
}

struct ClaudeClientTests {
    @Test func argumentsForNewAndResumedSessions() {
        let new = ClaudeClient.arguments(session: .new("abc"))
        #expect(new.starts(with: ["-p", "--output-format", "stream-json"]))
        #expect(new.suffix(2) == ["--session-id", "abc"])
        #expect(new.contains("--strict-mcp-config"))
        #expect(new.contains("dontAsk"))
        #expect(new.contains("Bash(swift run:*)"))
        #expect(!new.contains("--model"))

        #expect(new.contains("--safe-mode"))   // keeps the user's global CLAUDE.md etc. out
        #expect(!new.contains("Skill"))

        let resumed = ClaudeClient.arguments(session: .resume("abc"), model: "haiku", systemPrompt: "ctx")
        #expect(resumed.suffix(6) == ["--resume", "abc", "--model", "haiku", "--append-system-prompt", "ctx"])
    }

    @Test func allowedToolsMirrorPromptedCommands() {
        #expect(ClaudeClient.allowedTools.contains("Bash(swift run:*)"))
        for command in ClaudeClient.allowedCommands {
            #expect(ClaudeClient.permissionsSection.contains("`\(command) …`"))
        }
    }

    @Test func systemPromptIncludesInstructionsAndSkillWithoutFrontMatter() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "prompt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appending(path: ".claude/skills/cadova"), withIntermediateDirectories: true)
        try "# Workspace rules".write(to: dir.appending(path: "CLAUDE.md"), atomically: true, encoding: .utf8)
        try "---\nname: cadova\ndescription: x\n---\n\n# Cadova\nBody".write(
            to: dir.appending(path: ".claude/skills/cadova/SKILL.md"), atomically: true, encoding: .utf8
        )

        let prompt = ClaudeClient.systemPrompt(forWorkspaceAt: dir)
        #expect(prompt.hasPrefix("# Tool permissions in this session"))
        #expect(prompt.contains("# Workspace rules"))
        #expect(prompt.contains("# Cadova\nBody"))
        #expect(!prompt.contains("name: cadova"))
    }

    @Test func stripFrontMatterLeavesPlainTextAlone() {
        #expect(ClaudeClient.stripFrontMatter("no front matter") == "no front matter")
    }
}

struct ShellEnvironmentTests {
    @Test func parsesNullSeparatedEnvironment() {
        let parsed = ShellEnvironment.parseNullSeparated("PATH=/a:/b\0MULTI=line1\nline2\0EMPTY=\0junk\0")
        #expect(parsed == ["PATH": "/a:/b", "MULTI": "line1\nline2", "EMPTY": ""])
    }

    @Test func augmentsPathWithoutDuplicates() {
        let path = ShellEnvironment.augmentedPath("/usr/bin:/custom", home: "/Users/me")
        let entries = path.split(separator: ":").map(String.init)
        #expect(entries.prefix(2) == ["/usr/bin", "/custom"])
        #expect(entries.contains("/Users/me/.local/bin"))
        #expect(entries.filter { $0 == "/usr/bin" }.count == 1)
    }

    @Test func findsExecutablesOnPath() {
        #expect(ShellEnvironment.find("sh", inPath: "/nonexistent:/bin")?.path == "/bin/sh")
        #expect(ShellEnvironment.find("definitely-not-a-tool", inPath: "/bin") == nil)
    }
}
