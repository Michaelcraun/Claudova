import Foundation

/// One row in the chat transcript.
struct ChatItem: Identifiable, Equatable, Codable, Sendable {
    enum Kind: Equatable, Codable, Sendable {
        case user(String)
        case assistant(String)
        case tool(ToolActivity)
        /// App-generated status line (errors, "stopped", hints).
        case notice(String, isError: Bool)
    }

    let id: UUID
    var kind: Kind

    init(id: UUID = UUID(), _ kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

struct ToolActivity: Equatable, Codable, Sendable {
    enum Status: Equatable, Codable, Sendable {
        case running
        case succeeded
        case failed(String)
    }

    let toolUseID: String
    let name: String
    var detail: String?
    var status: Status

    /// e.g. "Edit · main.swift", "Bash · Build the model".
    var title: String {
        guard let detail, !detail.isEmpty else { return name }
        return "\(name) · \(detail)"
    }
}
