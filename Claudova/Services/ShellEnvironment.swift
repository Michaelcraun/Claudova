import Foundation

/// The user's login-shell environment, for launching command-line tools from a GUI app.
///
/// Apps launched from Finder/Dock get a minimal `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`), which
/// misses `~/.local/bin` (where Claude Code installs `claude`), Homebrew, etc. We ask the login
/// shell for its environment once and cache it.
actor ShellEnvironment {
    static let shared = ShellEnvironment()

    private var cached: [String: String]?

    func environment() async -> [String: String] {
        if let cached { return cached }
        let base = ProcessInfo.processInfo.environment
        var result = await Self.loginShellEnvironment() ?? base
        result["PATH"] = Self.augmentedPath(result["PATH"] ?? base["PATH"] ?? "", home: result["HOME"] ?? NSHomeDirectory())
        cached = result
        return result
    }

    /// Finds an executable by name on the environment's PATH.
    func which(_ name: String) async -> URL? {
        let path = await environment()["PATH"] ?? ""
        return Self.find(name, inPath: path)
    }

    // MARK: - Helpers

    static func find(_ name: String, inPath path: String) -> URL? {
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = URL(filePath: String(directory)).appending(path: name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Appends common tool locations that may be missing (deduplicated, order preserved).
    static func augmentedPath(_ path: String, home: String) -> String {
        var entries = path.split(separator: ":").map(String.init)
        let extras = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        for extra in extras where !entries.contains(extra) {
            entries.append(extra)
        }
        return entries.joined(separator: ":")
    }

    /// Runs `$SHELL -l -c 'env -0'` (bounded by a timeout) and parses the result.
    private static func loginShellEnvironment() async -> [String: String]? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let marker = "__CLAUDOVA_ENV__"
        let task = Task {
            try await ProcessRunner.run(
                URL(filePath: shell),
                arguments: ["-l", "-c", "printf '\(marker)'; /usr/bin/env -0"]
            )
        }
        let timeout = Task {
            try await Task.sleep(for: .seconds(5))
            task.cancel()
        }
        defer { timeout.cancel() }
        guard let result = try? await task.value, result.succeeded,
              let range = result.output.range(of: marker, options: .backwards) else { return nil }
        return parseNullSeparated(String(result.output[range.upperBound...]))
    }

    static func parseNullSeparated(_ output: String) -> [String: String] {
        var environment: [String: String] = [:]
        for entry in output.split(separator: "\0") {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<equals]).trimmingCharacters(in: .newlines)
            guard !key.isEmpty else { continue }
            environment[key] = String(entry[entry.index(after: equals)...])
        }
        return environment
    }
}
