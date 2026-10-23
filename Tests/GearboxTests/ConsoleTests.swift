import AppKit
import XCTest
@testable import Gearbox

final class TerminalScreenTests: XCTestCase {
    private func screen(_ bytes: String) -> TerminalScreen {
        var screen = TerminalScreen()
        screen.feed(bytes)
        return screen
    }

    func testLinesEndAtANewlineAndTheCursorLineIsLast() {
        let s = screen("one\r\ntwo\r\nthr")
        XCTAssertEqual(s.lines.map { $0.map(\.text).joined() }, ["one", "two"])
        XCTAssertEqual(s.text, "one\ntwo\nthr")
        XCTAssertEqual(s.cursorOffset, 3)
        XCTAssertFalse(s.atLineStart)
        XCTAssertTrue(screen("done\r\n").atLineStart)
    }

    /// git's progress: each count writes over the last.
    func testACarriageReturnWritesOverTheLine() {
        XCTAssertEqual(screen("Counting:  10%\rCounting: 100%, done.\r\n").text, "Counting: 100%, done.\n")
        XCTAssertEqual(screen("abcdef\rXY").text, "XYcdef")
        XCTAssertEqual(screen("abcdef\rXY").cursorOffset, 2)
    }

    /// The terminal echoes Delete as "\b \b".
    func testTheEchoOfDeleteTakesTheCharacterOff() {
        let s = screen("Push/commit anyway? yx\u{8} \u{8}")
        XCTAssertEqual(s.text, "Push/commit anyway? y ")
        XCTAssertEqual(s.cursorOffset, "Push/commit anyway? y".utf16.count)
    }

    func testEraseInLine() {
        XCTAssertEqual(screen("abcdef\r\u{1B}[K").text, "")
        XCTAssertEqual(screen("abcdef\u{1B}[3D\u{1B}[0K").text, "abc")
        XCTAssertEqual(screen("abcdef\u{1B}[3D\u{1B}[1K").text, "    ef")
        XCTAssertEqual(screen("abcdef\u{1B}[2Kxy").text, "      xy")
    }

    func testMrksColoursAreStylesAndNotText() {
        // lib.sh's ok and warn, and section's bold blue.
        let s = screen("\u{1B}[32m  ✓\u{1B}[0m Saved\r\n\u{1B}[1m\u{1B}[34m══ Dock setup\u{1B}[0m\r\n")
        XCTAssertEqual(s.text, "  ✓ Saved\n══ Dock setup\n")
        XCTAssertEqual(s.lines[0], [
            TerminalScreen.Run(text: "  ✓", style: .init(color: 2)),
            TerminalScreen.Run(text: " Saved", style: .init()),
        ])
        XCTAssertEqual(s.lines[1], [TerminalScreen.Run(text: "══ Dock setup", style: .init(bold: true, color: 4))])
    }

    func testSGRCodes() {
        let s = screen("\u{1B}[2md\u{1B}[22;4mu\u{1B}[24;7mi\u{1B}[0;91mb\u{1B}[39mn\u{1B}[mx")
        XCTAssertEqual(s.cursorLine, [
            TerminalScreen.Run(text: "d", style: .init(dim: true)),
            TerminalScreen.Run(text: "u", style: .init(underline: true)),
            TerminalScreen.Run(text: "i", style: .init(inverse: true)),
            TerminalScreen.Run(text: "b", style: .init(color: 9)),
            TerminalScreen.Run(text: "nx", style: .init()),
        ])
    }

    /// An extended colour's arguments are not codes of their own: 38;5;1 is
    /// colour 1, not bold.
    func testAnExtendedColoursArgumentsAreSkipped() {
        XCTAssertEqual(screen("\u{1B}[38;5;1mx").cursorLine.first?.style, .init(color: 1))
        XCTAssertEqual(screen("\u{1B}[38;2;1;2;4mx").cursorLine.first?.style, .init())
        XCTAssertEqual(screen("\u{1B}[38;5;200mx").cursorLine.first?.style, .init())
    }

    func testOtherSequencesAreTakenOutWhole() {
        // A window title, the cursor hidden and shown, a character set, a move up.
        let s = screen("\u{1B}]0;title\u{7}a\u{1B}[?25lb\u{1B}[?25h\u{1B}(Bc\u{1B}[2Ad\u{1B}]8;;http://x\u{1B}\\e")
        XCTAssertEqual(s.text, "abcde")
    }

    func testATabGoesToTheNextStop() {
        let s = screen("ab\tc")
        XCTAssertEqual(s.text, "ab      c")
        let t = screen("ab\t")
        XCTAssertEqual(t.cursorOffset, 8)
        XCTAssertEqual(t.text, "ab      ")
    }

    /// A character can arrive split across two reads.
    func testACharacterSplitAcrossFeeds() {
        var s = TerminalScreen()
        let bytes = Array("✓ ok".utf8)
        s.feed(Array(bytes[0..<2]))
        s.feed(Array(bytes[2...]))
        XCTAssertEqual(s.text, "✓ ok")
        XCTAssertEqual(s.cursorOffset, 4)
    }

    func testBrokenUTF8IsAReplacement() {
        var s = TerminalScreen()
        s.feed([0x61, 0xE2, 0x9C, 0x62, 0xFF, 0x63])
        XCTAssertEqual(s.text, "a\u{FFFD}b\u{FFFD}c")
    }

    func testEachFeedIsANewRevision() {
        var s = TerminalScreen()
        let first = s.revision
        s.feed("x")
        XCTAssertNotEqual(s.revision, first)
    }
}

final class ConsoleKeysTests: XCTestCase {
    private func bytes(_ characters: String?, keyCode: UInt16 = 0, _ modifiers: NSEvent.ModifierFlags = []) -> [UInt8]? {
        ConsoleKeys.bytes(characters: characters, keyCode: keyCode, modifiers: modifiers)
    }

    func testTypingAndTheEditingKeys() {
        XCTAssertEqual(bytes("y"), [0x79])
        XCTAssertEqual(bytes("é"), Array("é".utf8))
        XCTAssertEqual(bytes("\r", keyCode: 36), [0x0D])
        XCTAssertEqual(bytes("\u{7F}", keyCode: 51), [0x7F])
        XCTAssertEqual(bytes("\t", keyCode: 48), [0x09])
    }

    /// The keypad's Enter is Return, not the ⌃C AppKit types for it.
    func testKeypadEnterIsReturn() {
        XCTAssertEqual(bytes("\u{3}", keyCode: 76), [0x0D])
    }

    func testControlKeysOnlyWithControlHeld() {
        XCTAssertEqual(bytes("\u{3}", keyCode: 8, .control), [0x03])
        XCTAssertEqual(bytes("\u{4}", keyCode: 2, .control), [0x04])
        XCTAssertNil(bytes("\u{1B}", keyCode: 53))
    }

    /// ⌃Z and ⌃Y would suspend the command with nothing to start it again.
    func testNothingSuspends() {
        XCTAssertNil(bytes("\u{1A}", keyCode: 6, .control))
        XCTAssertNil(bytes("\u{19}", keyCode: 16, .control))
        XCTAssertNil(bytes("\u{19}", keyCode: 48, .shift))
    }

    func testTheAppKeepsCommandAndTheArrows() {
        XCTAssertNil(bytes("c", keyCode: 8, .command))
        XCTAssertNil(bytes("\u{F700}", keyCode: 126))
        XCTAssertNil(bytes("\u{F72C}", keyCode: 116))
        XCTAssertNil(bytes(""))
        XCTAssertNil(bytes(nil))
    }
}

final class PseudoTerminalTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("GearboxTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("my 'checkout'", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch.deletingLastPathComponent())
    }

    private func zsh(_ script: String, grace: Duration = .seconds(2),
                     typing: [UInt8]? = nil, after: Duration = .milliseconds(300),
                     signal: Int32? = nil) async throws -> (output: String, status: Int32?) {
        let (terminal, events) = try PseudoTerminal.start(
            "/bin/zsh", arguments: ["-f", "-c", script],
            environment: ["PATH": "/usr/bin:/bin", "TERM": "dumb", "GEARBOX_PROBE": "it's set"],
            directory: scratch.path, drainGrace: grace)
        if typing != nil || signal != nil {
            Task {
                try? await Task.sleep(for: after)
                if let typing { terminal.write(typing) }
                if let signal { terminal.send(signal: signal) }
            }
        }
        var output = Data()
        var status: Int32?
        for await event in events {
            switch event {
            case .output(let data): output.append(data)
            case .exit(let code): status = code
            }
        }
        return (String(decoding: output, as: UTF8.self), status)
    }

    /// What snapshot-prefs's secret scan needs: stdin is a terminal, and
    /// /dev/tty is the program's own, so `read </dev/tty` takes what is typed.
    func testTheProgramHasATerminalAndCanAskThroughIt() async throws {
        let (output, status) = try await zsh(
            #"[[ -t 0 && -t 2 ]] && print isatty; print -rn -- "Push/commit anyway? "; read -r ans </dev/tty; print -r -- "got [$ans]"; exit 3"#,
            typing: Array("yes\r".utf8))
        XCTAssertTrue(output.contains("isatty"), output)
        // The terminal echoes what was typed, and the program reads the line.
        XCTAssertTrue(output.contains("Push/commit anyway? yes\r\n"), output)
        XCTAssertTrue(output.contains("got [yes]"), output)
        XCTAssertEqual(status, 3)
    }

    func testItRunsInTheDirectoryWithTheEnvironment() async throws {
        let (output, status) = try await zsh(#"pwd -P; print -r -- "$GEARBOX_PROBE $TERM"; stty size"#)
        XCTAssertTrue(output.contains(scratch.resolvingSymlinksInPath().path), output)
        XCTAssertTrue(output.contains("it's set dumb"), output)
        XCTAssertTrue(output.contains("24 80"), output)
        XCTAssertEqual(status, 0)
    }

    /// macOS drops what nobody has read when the program closes the terminal,
    /// so the last of a lot of output is the test.
    func testOutputUpToTheExitArrives() async throws {
        let (output, status) = try await zsh("for i in {1..20000}; do print line $i; done; exit 4")
        XCTAssertTrue(output.hasSuffix("line 20000\r\n"), String(output.suffix(80)))
        XCTAssertEqual(status, 4)
    }

    func testInterruptStopsItAsCtrlCDoes() async throws {
        let start = Date()
        let (_, status) = try await zsh("sleep 30", signal: SIGINT)
        XCTAssertEqual(status, 128 + SIGINT)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    /// ⌃C typed at the terminal reaches the program through the terminal.
    func testCtrlCTypedStopsIt() async throws {
        let (_, status) = try await zsh("sleep 30", typing: [0x03])
        XCTAssertEqual(status, 128 + SIGINT)
    }

    /// Something the program left in the background holds the terminal open;
    /// the run still ends, after the grace.
    func testABackgroundChildDoesNotHoldTheEndUp() async throws {
        let start = Date()
        let (output, status) = try await zsh("(sleep 20 &); print -r -- left", grace: .milliseconds(300))
        XCTAssertTrue(output.contains("left"), output)
        XCTAssertEqual(status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testAMissingDirectoryIsSaid() async throws {
        let (terminal, events) = try PseudoTerminal.start(
            "/bin/zsh", arguments: ["-c", "true"], environment: [:],
            directory: scratch.appendingPathComponent("gone").path)
        _ = terminal
        var output = ""
        var status: Int32?
        for await event in events {
            switch event {
            case .output(let data): output += String(decoding: data, as: UTF8.self)
            case .exit(let code): status = code
            }
        }
        // Named as the process is, which here is the test runner, not Gearbox.
        let name = ProcessInfo.processInfo.processName.lowercased()
        XCTAssertTrue(output.contains("\(name): cannot enter \(scratch.path)/gone"), output)
        XCTAssertEqual(status, 126)
    }

    func testShellStatus() {
        XCTAssertEqual(PseudoTerminal.shellStatus(3 << 8), 3)
        XCTAssertEqual(PseudoTerminal.shellStatus(SIGINT), 130)
        XCTAssertEqual(PseudoTerminal.shellStatus(SIGKILL), 137)
    }
}

@MainActor
final class ConsoleModelTests: XCTestCase {
    /// make dock in the console runs in the checkout with the login shell's
    /// environment and MRK_ROOT, as the .command file did, then reads the
    /// Dock pane again.
    func testTheConsoleRunsTheCommandThenReadsThePaneAgain() async throws {
        let stub = try StubMrk()
        try stub.write("Makefile", "dock:\n\t@printf 'docked term=%s root=%s\\n' \"$$TERM\" \"$$MRK_ROOT\"\n")
        try stub.write("config/dock.txt", "/Applications/Safari.app\n")
        let app = AppModel(checkout: stub.checkout, runner: stub.runner(), store: stub.store(), home: "/Users/x")

        await app.runInConsole(.applyDock)

        let session = try XCTUnwrap(app.console)
        XCTAssertEqual(session.state, .exited(0))
        let text = session.screen.text
        XCTAssertTrue(text.hasPrefix("$ make dock\n"), text)
        XCTAssertTrue(text.contains("docked term=dumb root=\(stub.root.path)"), text)
        XCTAssertTrue(text.hasSuffix("[exited 0]"), text)
        XCTAssertTrue(stub.calls.contains { $0.hasPrefix("scripts/dock-setup [--check]") }, "\(stub.calls)")

        app.closeConsole()
        XCTAssertNil(app.console)
    }

    func testAFailureIsItsStatusAndThePaneStillReads() async throws {
        let stub = try StubMrk()
        try stub.write("Makefile", "snapshot-prefs:\n\t@echo refused >&2; exit 1\n")
        let app = AppModel(checkout: stub.checkout, runner: stub.runner(), store: stub.store(), home: "/Users/x")

        await app.runInConsole(.snapshotPrefs)

        let session = try XCTUnwrap(app.console)
        XCTAssertEqual(session.state, .exited(2))  // make's own status for a failed recipe
        XCTAssertTrue(session.screen.text.contains("refused"), session.screen.text)
        XCTAssertTrue(stub.calls.contains { $0.hasPrefix("scripts/snapshot-prefs [--check]") }, "\(stub.calls)")
    }

    /// The console takes one command at a time, and closes only once it has
    /// exited.
    func testOneCommandAtATime() async throws {
        let stub = try StubMrk()
        try stub.write("Makefile", "dock:\n\t@sleep 30\n")
        let app = AppModel(checkout: stub.checkout, runner: stub.runner(), store: stub.store(), home: "/Users/x")

        let first = Task { await app.runInConsole(.applyDock) }
        while app.console?.state != .running { try await Task.sleep(for: .milliseconds(20)) }
        let session = try XCTUnwrap(app.console)

        await app.runInConsole(.snapshotPrefs)
        XCTAssertTrue(app.console === session)
        app.closeConsole()
        XCTAssertTrue(app.console === session)

        session.stop()
        await first.value
        // make deletes what it was making, then dies of the SIGINT itself.
        XCTAssertEqual(session.state, .exited(128 + SIGINT))
        XCTAssertEqual(session.stops, 1)
        app.closeConsole()
        XCTAssertNil(app.console)
    }

    func testTheConsoleEnvironment() {
        let env = AppModel.consoleEnvironment(
            ["PATH": "/opt/homebrew/bin:/usr/bin", "TERM": "xterm-256color", "COLUMNS": "200", "HOME": "/Users/x"],
            checkout: MrkCheckout(root: URL(fileURLWithPath: "/Users/x/mrk")))
        XCTAssertEqual(env["PATH"], "/opt/homebrew/bin:/usr/bin")
        XCTAssertEqual(env["HOME"], "/Users/x")
        XCTAssertEqual(env["MRK_ROOT"], "/Users/x/mrk")
        XCTAssertEqual(env["TERM"], "dumb")
        XCTAssertEqual(env["PAGER"], "cat")
        XCTAssertEqual(env["GIT_PAGER"], "cat")
        XCTAssertNil(env["COLUMNS"])
    }
}
