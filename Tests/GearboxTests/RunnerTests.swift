import XCTest
@testable import Gearbox

final class CommandTests: XCTestCase {
    /// The exact command lines, as BIN-1 documents each flag.
    func testEachCommandsScriptAndArguments() {
        let cases: [(MrkCommand, String, [String])] = [
            (.prefsCheck, "scripts/snapshot-prefs", ["--check"]),
            (.defaultsCheck(withTrackpad: false), "scripts/defaults.sh", ["--check"]),
            (.defaultsCheck(withTrackpad: true), "scripts/defaults.sh", ["--check", "--with-trackpad"]),
            (.loginItemsCheck, "scripts/sync-login-items", ["--check"]),
            (.loginItemsAdd("Chrono Plus"), "scripts/sync-login-items", ["--add", "Chrono Plus"]),
            (.loginItemsIgnore("Raycast"), "scripts/sync-login-items", ["--ignore", "Raycast"]),
            (.loginItemsRemove("Old"), "scripts/sync-login-items", ["--remove", "Old"]),
            (.dockCheck, "scripts/dock-setup", ["--check"]),
        ]
        for (command, script, arguments) in cases {
            XCTAssertEqual(command.script, script, "\(command)")
            XCTAssertEqual(command.arguments, arguments, "\(command)")
        }
        XCTAssertEqual(MrkCommand.loginItemsAdd("Chrono Plus").displayLine,
                       #"$ scripts/sync-login-items --add "Chrono Plus""#)
    }

    /// No command Gearbox runs by itself commits: none passes -c.
    func testNothingCommits() {
        let all: [MrkCommand] = [.prefsCheck, .defaultsCheck(withTrackpad: true), .loginItemsCheck,
                                 .loginItemsAdd("a"), .loginItemsIgnore("a"), .loginItemsRemove("a"), .dockCheck]
        for command in all {
            XCTAssertFalse(command.arguments.contains { $0 == "-c" || $0 == "--commit" }, "\(command)")
        }
    }

    func testTheTerminalCommands() {
        XCTAssertEqual(TerminalCommand.snapshotPrefs.command, "make snapshot-prefs")
        XCTAssertEqual(TerminalCommand.applyDefaults(withTrackpad: false).command, "make defaults")
        XCTAssertEqual(TerminalCommand.applyDefaults(withTrackpad: true).command, "make trackpad")
        XCTAssertEqual(TerminalCommand.applyDock.command, "make dock")
    }

    func testTheCheckoutIsMrkRootOrHomeMrk() {
        XCTAssertEqual(MrkCheckout.resolve(environment: ["MRK_ROOT": "/w/mrk"], home: "/Users/x").root.path, "/w/mrk")
        XCTAssertEqual(MrkCheckout.resolve(environment: ["MRK_ROOT": ""], home: "/Users/x").root.path, "/Users/x/mrk")
        XCTAssertEqual(MrkCheckout.resolve(environment: [:], home: "/Users/x").root.path, "/Users/x/mrk")
    }

    func testACheckoutWithoutTheScriptsIsNamed() throws {
        let stub = try StubMrk()
        XCTAssertNil(stub.checkout.missing())
        try FileManager.default.removeItem(at: stub.checkout.file("scripts/dock-setup"))
        XCTAssertEqual(stub.checkout.missing(), "scripts/dock-setup")
    }

    func testTheLastLineLosesItsMarkAndColour() {
        XCTAssertEqual(MrkRunner.lastLine(of: "  ▸ working\n\u{1B}[31m  ✗ Not tracked: X\u{1B}[0m\n\n"), "Not tracked: X")
        XCTAssertEqual(MrkRunner.lastLine(of: ""), "")
    }
}

final class RunnerTests: XCTestCase {
    func testRunsTheScriptInTheCheckoutWithStdinClosed() async throws {
        let stub = try StubMrk()
        try stub.answer("dock-setup", ["--check"], out: "app\t/A.app\t/A.app\tpresent\n")
        let result = try await stub.runner().run(.dockCheck, in: stub.checkout)
        XCTAssertEqual(result.stdoutText, "app\t/A.app\t/A.app\tpresent\n")
        let cwd = stub.root.resolvingSymlinksInPath().path
        XCTAssertEqual(stub.calls.map { $0.replacingOccurrences(of: "/private/var/", with: "/var/") },
                       ["scripts/dock-setup [--check] cwd=\(cwd.replacingOccurrences(of: "/private/var/", with: "/var/")) stdin=eof"])
    }

    func testANameWithSpacesIsOneArgument() async throws {
        let stub = try StubMrk()
        _ = try await stub.runner().run(.loginItemsAdd("Chrono Plus"), in: stub.checkout)
        XCTAssertEqual(stub.calls.first?.components(separatedBy: " cwd=").first,
                       "scripts/sync-login-items [--add] [Chrono Plus]")
    }

    func testARefusalCarriesTheLastLineOfStderr() async throws {
        let stub = try StubMrk()
        try stub.answer("sync-login-items", ["--remove", "Raycast"],
                        err: "  ▸ Reading login items\n  ✗ Raycast is still a login item, and the ignore list does not name it\n",
                        status: 1)
        do {
            _ = try await stub.runner().run(.loginItemsRemove("Raycast"), in: stub.checkout)
            XCTFail("expected a refusal")
        } catch let error as MrkError {
            XCTAssertEqual(error.status, 1)
            XCTAssertEqual(error.errorDescription,
                           "Raycast is still a login item, and the ignore list does not name it")
        }
    }

    func testExitTwoIsAnOlderMrk() async throws {
        let stub = try StubMrk()
        try stub.answer("dock-setup", ["--check"], err: "unknown argument: --check\n", status: 2)
        do {
            _ = try await stub.runner().run(.dockCheck, in: stub.checkout)
            XCTFail("expected a refusal")
        } catch let error as MrkError {
            XCTAssertTrue(error.errorDescription!.contains("older than Gearbox"), error.errorDescription!)
            XCTAssertTrue(error.errorDescription!.contains("make pull"))
        }
    }

    func testTheEnvironmentIsAskedForOnce() async throws {
        let stub = try StubMrk()
        let counter = Counter()
        let runner = MrkRunner(environment: { await counter.bump(); return ["PATH": "/usr/bin:/bin"] })
        _ = try await runner.run(.dockCheck, in: stub.checkout)
        _ = try await runner.run(.prefsCheck, in: stub.checkout)
        let n = await counter.value
        XCTAssertEqual(n, 1)
    }
}

actor Counter {
    var value = 0
    func bump() { value += 1 }
}

final class SubprocessTests: XCTestCase {
    /// A child that outlives the program and holds its pipes open must not
    /// hold up the result: the output the program wrote comes back within
    /// the grace. Barkeep's CI found this on 2026-10-18.
    func testAChildLeftHoldingThePipes() async throws {
        let start = ContinuousClock.now
        let result = try await Subprocess.run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo hi; sleep 30 & exit 0"],
            timeout: .seconds(20), drainGrace: .milliseconds(500))
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdoutText, "hi\n")
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(10))
    }

    func testMoreThanAPipeBufferOfOutput() async throws {
        let result = try await Subprocess.run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "head -c 300000 /dev/zero | tr '\\0' x"],
            timeout: .seconds(20))
        XCTAssertEqual(result.stdout.count, 300_000)
    }

    func testTheWatchdogStopsAHang() async throws {
        let result = try await Subprocess.run(
            URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: .milliseconds(300))
        XCTAssertTrue(result.timedOut)
    }
}
