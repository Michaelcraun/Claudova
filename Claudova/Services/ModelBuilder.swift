import Foundation

struct BuildOutcome: Sendable {
    let result: ProcessResult
    /// The model file reported by Cadova's "Wrote model to …" log line, if any.
    let modelURL: URL?
    let duration: Duration

    var succeeded: Bool { result.succeeded && modelURL != nil }
}

/// Abstraction over `ModelBuilder` so the build loop can be tested without compiling anything.
protocol ModelBuilding: Sendable {
    func build(_ workspace: Workspace, onLine: (@Sendable (String) -> Void)?) async throws -> BuildOutcome
}

extension ModelBuilder: ModelBuilding {}

/// Builds and runs a workspace's Cadova package with `swift run`.
struct ModelBuilder: Sendable {
    /// The `swift` shim; it resolves the active toolchain via `xcode-select`.
    var swiftExecutable = URL(filePath: "/usr/bin/swift")

    func build(_ workspace: Workspace, onLine: (@Sendable (String) -> Void)? = nil) async throws -> BuildOutcome {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await ProcessRunner.run(
            swiftExecutable,
            arguments: ["run", "Model"],
            currentDirectory: workspace.url,
            onLine: onLine
        )
        let written = Self.writtenModelURLs(in: result.output)
        let modelURL = written.last ?? (result.succeeded && FileManager.default.fileExists(atPath: workspace.modelOutputURL.path)
            ? workspace.modelOutputURL : nil)
        return BuildOutcome(result: result, modelURL: modelURL, duration: clock.now - start)
    }

    /// Paths from Cadova log lines like `[INFO] [model] Wrote model to /path/Models/model.3mf`.
    static func writtenModelURLs(in output: String) -> [URL] {
        let marker = "Wrote model to "
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            guard let range = line.range(of: marker) else { return nil }
            let path = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return path.isEmpty ? nil : URL(filePath: path)
        }
    }

    /// True if the model file exists and is at least as new as every input to the build
    /// (`Sources/**`, `Package.swift`, `Package.resolved`), i.e. the last `swift run` (usually
    /// Claude's own) already produced it from the current code.
    static func isOutputUpToDate(_ workspace: Workspace) -> Bool {
        guard let output = modificationDate(of: workspace.modelOutputURL) else { return false }
        guard let newestInput = newestInputDate(in: workspace) else { return true }
        return output >= newestInput
    }

    static func newestInputDate(in workspace: Workspace) -> Date? {
        var dates = ["Package.swift", "Package.resolved"].compactMap {
            modificationDate(of: workspace.url.appending(path: $0))
        }
        let sources = workspace.url.appending(path: "Sources", directoryHint: .isDirectory)
        if let enumerator = FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        ) {
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                if values?.isRegularFile == true, let date = values?.contentModificationDate {
                    dates.append(date)
                }
            }
        }
        return dates.max()
    }

    private static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Lines worth showing the user when a build fails: compiler errors, falling back to the tail.
    static func errorSummary(from output: String, maxLines: Int = 20) -> String {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        let errors = lines.filter { $0.contains("error:") }
        return (errors.isEmpty ? Array(lines.suffix(maxLines)) : Array(errors.prefix(maxLines)))
            .joined(separator: "\n")
    }
}
