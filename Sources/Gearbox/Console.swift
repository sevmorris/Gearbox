import AppKit
import Foundation
import Observation

/// One run of a TerminalCommand in Gearbox's console, from its start to its
/// exit: the screen it prints to, and the keys typed at it.
@Observable @MainActor
final class ConsoleSession: Identifiable {
    enum State: Equatable {
        case starting
        case running
        /// The exit status as a shell gives it.
        case exited(Int32)
        /// The command never started.
        case failed(String)
    }

    let id = UUID()
    let command: TerminalCommand
    private(set) var screen = TerminalScreen()
    private(set) var state = State.starting
    /// How many times Stop was pressed. Each press sends a harder signal.
    private(set) var stops = 0
    @ObservationIgnored private var terminal: PseudoTerminal?

    init(command: TerminalCommand) {
        self.command = command
    }

    var isRunning: Bool { state == .starting || state == .running }

    /// Runs the command with zsh in `directory`, as the terminal window's
    /// shell ran it, and returns when it has exited.
    func run(environment: [String: String], directory: String) async {
        guard state == .starting else { return }
        screen.feed("\u{1B}[1m$ \(command.command)\u{1B}[0m\r\n")
        let events: AsyncStream<PseudoTerminal.Event>
        do {
            let started = try PseudoTerminal.start(
                "/bin/zsh", arguments: ["-c", command.command],
                environment: environment, directory: directory)
            terminal = started.0
            events = started.1
        } catch {
            state = .failed("\(command.command) could not start: \(error.localizedDescription)")
            return
        }
        state = .running
        for await event in events {
            switch event {
            case .output(let data):
                screen.feed(data)
            case .exit(let status):
                if !screen.atLineStart { screen.feed("\r\n") }
                screen.feed("\u{1B}[2m[exited \(status)]\u{1B}[0m")
                state = .exited(status)
            }
        }
        terminal = nil
    }

    /// Types at the command's terminal.
    func type(_ bytes: [UInt8]) {
        guard state == .running, let terminal else { return }
        if !terminal.write(bytes) { NSSound.beep() }
    }

    /// SIGINT, as ⌃C sends; then SIGTERM; then SIGKILL. A script that traps
    /// ⌃C to tidy up, as mrk's do, gets its chance first, and one that
    /// ignores it still stops.
    func stop() {
        guard state == .running, let terminal else { return }
        let signals = [SIGINT, SIGTERM, SIGKILL]
        terminal.send(signal: signals[min(stops, signals.count - 1)])
        stops += 1
    }
}

/// What a key pressed in the console types at the terminal.
enum ConsoleKeys {
    /// The bytes for a key, or nil for a key the console leaves to the text
    /// view and the menus.
    static func bytes(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> [UInt8]? {
        // ⌘ belongs to the app: Copy, Select All, Stop.
        if modifiers.contains(.command) { return nil }
        // The keypad's Enter types U+0003, which a terminal reads as ⌃C.
        if keyCode == 76 { return [0x0D] }
        guard let characters, !characters.isEmpty else { return nil }
        let scalars = characters.unicodeScalars
        // The arrows, Page Up and Down and the function keys arrive as
        // AppKit's private-use characters. A dumb terminal has none of them,
        // and the text view scrolls with the page keys.
        if scalars.contains(where: { (0xF700...0xF8FF).contains($0.value) }) { return nil }
        if scalars.count == 1, let c = scalars.first, c.value < 0x20 || c.value == 0x7F {
            switch c.value {
            case 0x0D, 0x09, 0x7F:
                // Return, Tab and Delete.
                return [UInt8(c.value)]
            case 0x19, 0x1A:
                // ⌃Y and ⌃Z suspend the program, and with no shell's job
                // control nothing could start it again. ⇧Tab arrives as
                // U+0019 too.
                return nil
            default:
                // ⌃C, ⌃D, ⌃U and the rest when ⌃ is held. Escape types
                // nothing.
                return modifiers.contains(.control) ? [UInt8(c.value)] : nil
            }
        }
        return Array(characters.utf8)
    }
}
