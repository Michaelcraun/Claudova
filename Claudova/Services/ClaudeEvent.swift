import Foundation

/// What the chat UI needs from Claude Code's `--output-format stream-json` output.
enum ClaudeEvent: Equatable, Sendable {
    /// `system/init`: the session is up.
    case sessionStarted(sessionID: String, model: String?)
    /// Claude began extended thinking.
    case thinking
    /// A new text content block began.
    case textStarted
    /// Streamed text for the current text block.
    case textDelta(String)
    /// A tool call began streaming (input not known yet) or its full input arrived.
    case tool(ToolCall)
    /// A tool call finished.
    case toolResult(id: String, isError: Bool, output: String)
    /// The turn ended.
    case finished(TurnResult)
    /// A line that isn't stream-json (stderr warnings, crash output).
    case diagnostic(String)

    struct ToolCall: Equatable, Sendable {
        let id: String
        let name: String
        /// Short human-readable detail (file name, command description), once the input is known.
        let detail: String?
    }

    struct TurnResult: Equatable, Sendable {
        let isError: Bool
        let subtype: String
        let resultText: String?
        let sessionID: String?
        let durationMS: Int?
        let costUSD: Double?
        let permissionDenials: Int
    }
}

/// Stateless line-by-line parser for Claude Code stream-json output.
enum ClaudeEventParser {
    static func parse(line: String) -> [ClaudeEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String
        else { return [.diagnostic(trimmed)] }

        // Ignore anything a subagent does; only the main conversation is shown.
        if object["parent_tool_use_id"] is String { return [] }

        switch type {
        case "system":
            guard object["subtype"] as? String == "init", let sessionID = object["session_id"] as? String else { return [] }
            return [.sessionStarted(sessionID: sessionID, model: object["model"] as? String)]

        case "stream_event":
            return parseStreamEvent(object["event"] as? [String: Any] ?? [:])

        case "assistant":
            // Text arrives via stream deltas; only take the completed tool inputs from here.
            return contentBlocks(of: object).compactMap { block in
                guard block["type"] as? String == "tool_use",
                      let id = block["id"] as? String, let name = block["name"] as? String else { return nil }
                let input = block["input"] as? [String: Any] ?? [:]
                return .tool(.init(id: id, name: name, detail: toolDetail(name: name, input: input)))
            }

        case "user":
            return contentBlocks(of: object).compactMap { block in
                guard block["type"] as? String == "tool_result",
                      let id = block["tool_use_id"] as? String else { return nil }
                return .toolResult(
                    id: id,
                    isError: block["is_error"] as? Bool ?? false,
                    output: resultText(block["content"])
                )
            }

        case "result":
            return [.finished(.init(
                isError: object["is_error"] as? Bool ?? (object["subtype"] as? String != "success"),
                subtype: object["subtype"] as? String ?? "unknown",
                resultText: object["result"] as? String,
                sessionID: object["session_id"] as? String,
                durationMS: object["duration_ms"] as? Int,
                costUSD: object["total_cost_usd"] as? Double,
                permissionDenials: (object["permission_denials"] as? [Any])?.count ?? 0
            ))]

        default:
            return []
        }
    }

    private static func parseStreamEvent(_ event: [String: Any]) -> [ClaudeEvent] {
        switch event["type"] as? String {
        case "content_block_start":
            let block = event["content_block"] as? [String: Any] ?? [:]
            switch block["type"] as? String {
            case "text": return [.textStarted]
            case "thinking", "redacted_thinking": return [.thinking]
            case "tool_use":
                guard let id = block["id"] as? String, let name = block["name"] as? String else { return [] }
                return [.tool(.init(id: id, name: name, detail: nil))]
            default: return []
            }
        case "content_block_delta":
            let delta = event["delta"] as? [String: Any] ?? [:]
            guard delta["type"] as? String == "text_delta", let text = delta["text"] as? String, !text.isEmpty else { return [] }
            return [.textDelta(text)]
        default:
            return []
        }
    }

    private static func contentBlocks(of object: [String: Any]) -> [[String: Any]] {
        let message = object["message"] as? [String: Any]
        return message?["content"] as? [[String: Any]] ?? []
    }

    private static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    /// A short description of a tool call for the chat transcript.
    static func toolDetail(name: String, input: [String: Any]) -> String? {
        func fileName(_ key: String) -> String? {
            (input[key] as? String).map { URL(filePath: $0).lastPathComponent }
        }
        switch name {
        case "Bash":
            if let description = input["description"] as? String, !description.isEmpty { return description }
            return (input["command"] as? String)?.split(separator: "\n").first.map(String.init)
        case "Read", "Edit", "Write", "MultiEdit", "NotebookEdit":
            return fileName("file_path") ?? fileName("notebook_path")
        case "Skill":
            return input["skill"] as? String ?? input["command"] as? String
        case "Glob", "Grep":
            return input["pattern"] as? String
        default:
            return nil
        }
    }
}
