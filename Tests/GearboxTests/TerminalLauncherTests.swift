import XCTest
@testable import Gearbox

final class TerminalLauncherTests: XCTestCase {
    func testQuotingSurvivesSingleQuotesAndSpaces() {
        XCTAssertEqual(TerminalLauncher.shellQuote("it's here"), #"'it'"'"'s here'"#)
        XCTAssertEqual(TerminalLauncher.shellQuote("/Users/x/my mrk"), "'/Users/x/my mrk'")
    }

    func testTheScriptRunsTheFixInTheCheckout() {
        let script = TerminalLauncher.script(
            command: #"make setup ARGS="--only shell""#,
            directory: "/Users/x/mrk",
            exports: ["PATH": "/Users/x/bin:/usr/bin", "MRK_ROOT": "/Users/x/mrk"])
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        XCTAssertEqual(lines.first, "#!/bin/zsh")
        XCTAssertTrue(lines.contains(#"rm -f -- "$0""#))
        // Sorted, so the file is the same for the same inputs.
        XCTAssertEqual(lines.filter { $0.hasPrefix("export ") },
                       ["export MRK_ROOT='/Users/x/mrk'", "export PATH='/Users/x/bin:/usr/bin'"])
        XCTAssertTrue(lines.contains("cd -- '/Users/x/mrk' || exit 1"))
        // The fix itself goes in as written: it is shell, as the TUI runs it.
        XCTAssertTrue(lines.contains(#"make setup ARGS="--only shell""#))
        // `status` is read-only in zsh; assigning it would end the script.
        XCTAssertTrue(lines.contains("rc=$?"))
        XCTAssertFalse(script.contains("status=$?"))
    }

    /// The script, run by zsh with `cd` pointed at a scratch folder: it runs
    /// the command there, reports the exit, and deletes itself.
    func testTheScriptRunsAndDeletesItself() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GearboxTests-\(UUID().uuidString)", isDirectory: true)
        let work = dir.appendingPathComponent("my 'checkout'", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("run.command")
        try TerminalLauncher.script(command: "pwd -P; exit_code_is() { return 3 }; exit_code_is",
                                    directory: work.path,
                                    exports: ["PATH": "/usr/bin:/bin"])
            .write(to: file, atomically: true, encoding: .utf8)

        let result = try await Subprocess.run(
            URL(fileURLWithPath: "/bin/zsh"), arguments: ["-f", file.path], timeout: .seconds(10))
        let out = String(decoding: result.stdout, as: UTF8.self)

        XCTAssertTrue(out.contains(work.resolvingSymlinksInPath().path), out)
        XCTAssertTrue(out.contains("Gearbox: exited 3."), out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
