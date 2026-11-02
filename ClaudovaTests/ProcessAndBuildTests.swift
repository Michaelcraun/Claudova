import Foundation
import Synchronization
import Testing
@testable import Claudova

struct ProcessRunnerTests {
    @Test func capturesCombinedOutputAndExitCode() async throws {
        let lines = Mutex<[String]>([])
        let result = try await ProcessRunner.run(
            URL(filePath: "/bin/sh"),
            arguments: ["-c", "echo one; echo two 1>&2; exit 3"],
            onLine: { line in lines.withLock { $0.append(line) } }
        )
        #expect(result.exitCode == 3)
        #expect(!result.succeeded)
        #expect(result.output == "one\ntwo")
        #expect(lines.withLock { $0 } == ["one", "two"])
    }

    @Test func runsInGivenDirectory() async throws {
        let dir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let result = try await ProcessRunner.run(URL(filePath: "/bin/pwd"), currentDirectory: dir)
        #expect(result.succeeded)
        #expect(URL(filePath: result.output).standardizedFileURL.path == dir.standardizedFileURL.path)
    }
}

struct ModelBuilderParsingTests {
    @Test func parsesWrittenModelPath() {
        let output = """
        Build of product 'Model' complete! (13.44s)
        2026-11-02T21:05:05.141 [INFO] [model] Generating...
        2026-11-02T21:05:05.151 [INFO] [model] Wrote model to /tmp/x/Models/model.3mf
        """
        #expect(ModelBuilder.writtenModelURLs(in: output) == [URL(filePath: "/tmp/x/Models/model.3mf")])
    }

    @Test func errorSummaryPrefersCompilerErrors() {
        let output = """
        Building for debugging...
        /w/Sources/Model/main.swift:4:5: error: cannot find 'Boxx' in scope
        [3/5] Compiling
        error: fatalError
        """
        #expect(ModelBuilder.errorSummary(from: output) == """
        /w/Sources/Model/main.swift:4:5: error: cannot find 'Boxx' in scope
        error: fatalError
        """)
    }
}
