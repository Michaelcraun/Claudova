import Foundation

struct ProcessResult: Sendable, Equatable {
    let exitCode: Int32
    /// Combined stdout and stderr, in the order it was produced.
    let output: String

    var succeeded: Bool { exitCode == 0 }
}

/// Runs a subprocess to completion, streaming its combined output line by line.
enum ProcessRunner {
    static func run(
        _ executable: URL,
        arguments: [String] = [],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        input: Data? = nil,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        if let environment { process.environment = environment }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let inputPipe = input.map { _ in Pipe() }
        process.standardInput = inputPipe ?? FileHandle.nullDevice

        // Buffered, so the exit status isn't lost if the process ends before we start awaiting it.
        let (exitStream, exitContinuation) = AsyncStream<Int32>.makeStream(bufferingPolicy: .bufferingNewest(1))
        process.terminationHandler = { process in
            exitContinuation.yield(process.terminationStatus)
            exitContinuation.finish()
        }

        try process.run()
        let handle = ProcessHandle(process)
        if let input, let inputPipe {
            // Small payloads (prompts) fit in the pipe buffer; close so the child sees EOF.
            try? inputPipe.fileHandleForWriting.write(contentsOf: input)
            try? inputPipe.fileHandleForWriting.close()
        }

        return try await withTaskCancellationHandler {
            var lines: [String] = []
            // Ends at EOF, i.e. once the process and any children holding the pipe have exited.
            for try await line in pipe.fileHandleForReading.bytes.lines {
                lines.append(line)
                onLine?(line)
            }
            var status: Int32 = -1
            for await code in exitStream { status = code }
            try Task.checkCancellation()
            return ProcessResult(exitCode: status, output: lines.joined(separator: "\n"))
        } onCancel: {
            handle.terminate()
        }
    }
}

/// Lets the cancellation handler terminate the process from another context.
private final class ProcessHandle: @unchecked Sendable {
    private let process: Process
    init(_ process: Process) { self.process = process }
    func terminate() {
        if process.isRunning { process.terminate() }
    }
}
