// Shared verbatim across the sibling app repos (Gearbox, Dipstick). Keep the
// copies byte-identical: scripts/check-shared.sh compares them and a release
// preflight fails when they drift. Anything one app needs on its own belongs
// in that app's files, not here.

import Foundation

/// What a dumb terminal shows of a program's output: the lines a newline has
/// ended, and the line the cursor is on.
///
/// The console runs its commands with TERM=dumb and draws what that promises
/// and a little more. A carriage return goes back to the start of the line,
/// so a progress count writes over itself, as git's does. A backspace steps
/// back, which is how the terminal echoes Delete ("\b \b"). Colour and weight
/// come from SGR, as mrk's lib.sh writes them. Erasing in the line, and
/// moving along it, are read too. Every other escape sequence is taken out
/// whole, so none of it shows as text: a program that moves the cursor up
/// gets its lines one after another instead.
struct TerminalScreen: Sendable {
    struct Style: Hashable, Sendable {
        var bold = false
        var dim = false
        var underline = false
        var inverse = false
        /// An ANSI colour, 0 to 7, or 8 to 15 for the bright ones; nil for
        /// the terminal's own.
        var color: UInt8?
    }

    /// Text in one style.
    struct Run: Equatable, Sendable {
        var text: String
        var style: Style
    }

    private struct Cell: Equatable, Sendable {
        var scalar: Unicode.Scalar
        var style: Style
    }

    private enum State: Sendable {
        case ground, escape, csi, string, stringEscape, charset
    }

    /// The lines a newline has ended, in runs of one style.
    private(set) var lines: [[Run]] = []
    /// The line the cursor is on, which the program can still write over.
    private var line: [Cell] = []
    /// Where the next character goes on `line`, in characters. It can run
    /// past the end, after a tab.
    private var column = 0
    /// Bumped by every feed, so a view can tell whether it has drawn this.
    private(set) var revision = 0

    private var style = Style()
    private var state = State.ground
    private var parameters: [UInt8] = []
    private var pending: [UInt8] = []
    private var pendingNeeds = 0

    /// The cursor's line, with spaces up to the cursor where it is past the
    /// end.
    var cursorLine: [Run] {
        Self.runs(line + Array(repeating: Cell(scalar: " ", style: Style()), count: max(0, column - line.count)))
    }

    /// Where the cursor is in `cursorLine`'s text, in UTF-16 units, as a text
    /// view counts.
    var cursorOffset: Int {
        line.prefix(column).reduce(0) { $0 + $1.scalar.utf16.count } + max(0, column - line.count)
    }

    /// The cursor is at the start of an empty line.
    var atLineStart: Bool { line.isEmpty && column == 0 }

    /// Everything on the screen, without its styles.
    var text: String {
        (lines.map { $0.map(\.text).joined() } + [cursorLine.map(\.text).joined()]).joined(separator: "\n")
    }

    mutating func feed(_ text: String) { feed(Array(text.utf8)) }

    mutating func feed(_ data: Data) { feed(Array(data)) }

    mutating func feed(_ bytes: [UInt8]) {
        for byte in bytes {
            switch state {
            case .ground: ground(byte)
            case .escape: escape(byte)
            case .csi: csi(byte)
            case .string:
                // An OSC (a window title, a link) or a DCS, up to BEL or ST.
                if byte == 0x07 { state = .ground } else if byte == 0x1B { state = .stringEscape }
            case .stringEscape:
                state = byte == 0x5C ? .ground : .string
            case .charset:
                // ESC ( B and its kind choose a character set: one byte more.
                state = .ground
            }
        }
        revision &+= 1
    }

    private mutating func ground(_ byte: UInt8) {
        if pendingNeeds > 0 {
            if byte & 0xC0 == 0x80 {
                pending.append(byte)
                pendingNeeds -= 1
                if pendingNeeds == 0 {
                    put(String(decoding: pending, as: UTF8.self).unicodeScalars.first ?? "\u{FFFD}")
                    pending = []
                }
                return
            }
            // A character cut short: the replacement, then this byte afresh.
            put("\u{FFFD}")
            pending = []
            pendingNeeds = 0
        }
        switch byte {
        case 0x1B: state = .escape
        case 0x00..<0x20: control(byte)
        case 0x7F: break
        case 0x80..<0xC0, 0xF8...: put("\u{FFFD}")
        case 0xC0..<0xE0: begin(byte, needs: 1)
        case 0xE0..<0xF0: begin(byte, needs: 2)
        case 0xF0..<0xF8: begin(byte, needs: 3)
        default: put(Unicode.Scalar(byte))
        }
    }

    private mutating func begin(_ byte: UInt8, needs: Int) {
        pending = [byte]
        pendingNeeds = needs
    }

    private mutating func control(_ byte: UInt8) {
        switch byte {
        case 0x0A, 0x0B, 0x0C:
            // The terminal turns a program's "\n" into "\r\n", so a line feed
            // starts the next line at its start.
            lines.append(Self.runs(line))
            line = []
            column = 0
        case 0x0D: column = 0
        case 0x08: column = max(0, column - 1)
        case 0x09: column = (column / 8 + 1) * 8
        default: break  // the bell, and the rest
        }
    }

    private mutating func escape(_ byte: UInt8) {
        switch byte {
        case 0x5B:  // [
            parameters = []
            state = .csi
        case 0x5D, 0x50, 0x58, 0x5E, 0x5F:  // ] P X ^ _
            state = .string
        case 0x28...0x2B:  // ( ) * +
            state = .charset
        default:
            state = .ground
        }
    }

    private mutating func csi(_ byte: UInt8) {
        switch byte {
        case 0x20...0x3F:
            parameters.append(byte)
        case 0x40...0x7E:
            perform(byte)
            state = .ground
        case 0x1B:
            state = .escape
        default:
            // A control character inside a sequence still does what it does.
            control(byte)
        }
    }

    private mutating func perform(_ final: UInt8) {
        // ?25l and its kind belong to a terminal that draws a screen.
        if let first = parameters.first, (0x3C...0x3F).contains(first) { return }
        let numbers = String(decoding: parameters, as: UTF8.self)
            .split(separator: ";", omittingEmptySubsequences: false).map { Int($0) }
        let n = max(1, (numbers.first ?? nil) ?? 1)
        switch final {
        case 0x6D: sgr(numbers)  // m
        case 0x4B: erase((numbers.first ?? nil) ?? 0)  // K
        case 0x47: column = n - 1  // G
        case 0x43: column += n  // C
        case 0x44: column = max(0, column - n)  // D
        default: break
        }
    }

    private mutating func sgr(_ numbers: [Int?]) {
        guard !numbers.isEmpty else {
            style = Style()
            return
        }
        var i = 0
        while i < numbers.count {
            let code = numbers[i] ?? 0
            switch code {
            case 0: style = Style()
            case 1: style.bold = true
            case 2: style.dim = true
            case 22:
                style.bold = false
                style.dim = false
            case 4: style.underline = true
            case 24: style.underline = false
            case 7: style.inverse = true
            case 27: style.inverse = false
            case 30...37: style.color = UInt8(code - 30)
            case 39: style.color = nil
            case 90...97: style.color = UInt8(code - 90 + 8)
            case 38, 48:
                // 38;5;N and 38;2;R;G;B: a colour beyond the sixteen. Its
                // arguments are skipped, never read as codes of their own.
                let kind = i + 1 < numbers.count ? numbers[i + 1] : nil
                if code == 38, kind == 5, i + 2 < numbers.count, let n = numbers[i + 2], (0..<16).contains(n) {
                    style.color = UInt8(n)
                }
                i += kind == 5 ? 2 : kind == 2 ? 4 : 0
            default:
                break  // backgrounds, italics, blinking
            }
            i += 1
        }
    }

    private mutating func erase(_ mode: Int) {
        switch mode {
        case 0:
            if column < line.count { line.removeSubrange(column...) }
        case 1:
            for i in 0..<min(column + 1, line.count) { line[i] = Cell(scalar: " ", style: Style()) }
        case 2:
            line = []
        default:
            break
        }
    }

    private mutating func put(_ scalar: Unicode.Scalar) {
        while line.count < column { line.append(Cell(scalar: " ", style: Style())) }
        let cell = Cell(scalar: scalar, style: style)
        if column < line.count { line[column] = cell } else { line.append(cell) }
        column += 1
    }

    private static func runs(_ cells: [Cell]) -> [Run] {
        var runs: [Run] = []
        for cell in cells {
            if runs.last?.style == cell.style {
                runs[runs.count - 1].text.unicodeScalars.append(cell.scalar)
            } else {
                runs.append(Run(text: String(cell.scalar), style: cell.style))
            }
        }
        return runs
    }
}
