import AppKit
import SwiftUI

/// The console: a sheet over the window that runs one TerminalCommand on a
/// terminal of Gearbox's own, and shows it on a phosphor screen.
struct ConsoleSheet: View {
    let session: ConsoleSession
    let close: () -> Void

    /// The colour of the tube, chosen from the sheet while you watch it.
    @AppStorage("consoleStyle", store: .app) private var styleRaw = PhosphorStyle.green.rawValue

    private var style: PhosphorStyle { PhosphorStyle(rawValue: styleRaw) ?? .green }

    var body: some View {
        VStack(spacing: 0) {
            header
            PhosphorScreen(style: style) {
                ConsoleScreenView(screen: session.screen, style: style,
                                  accepting: session.state == .running) { session.type($0) }
            }
            .padding(.horizontal, 16)
            footer
        }
        // Wide enough for the 80 columns the terminal says it has, with the
        // tube's bezel and a scroller that always shows: 80 × 9 pt of SF Mono
        // 15, and about 100 pt around it.
        .frame(minWidth: 860, idealWidth: 860, maxWidth: .infinity,
               minHeight: 460, idealHeight: 560, maxHeight: .infinity)
        .interactiveDismissDisabled(session.isRunning)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            Text(session.command.command)
                .font(.headline.monospaced())
            badge
            Spacer()
            Menu {
                Picker("Screen", selection: $styleRaw) {
                    ForEach(PhosphorStyle.allCases) { style in
                        Text(style.label).tag(style.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Image(systemName: "display")
            }
            .menuIndicator(.hidden)
            .frame(width: 34)
            .help("Screen colour")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    @ViewBuilder private var badge: some View {
        switch session.state {
        case .starting, .running: Badge(text: "running", color: .blue)
        case .exited(0): Badge(text: "done", color: .green)
        case .exited(let status) where status > 128: Badge(text: "stopped", color: .orange)
        case .exited(let status): Badge(text: "exited \(status)", color: .red)
        case .failed: Badge(text: "did not start", color: .red)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if session.isRunning {
                stopButton
            } else {
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var stopButton: some View {
        let (title, help): (String, String) = switch session.stops {
        case 0: ("Stop", "Send ⌃C, as a terminal does")
        case 1: ("Stop Again", "Send SIGTERM")
        default: ("Kill", "Send SIGKILL, which nothing can catch")
        }
        return Button(title) { session.stop() }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(session.state != .running)
            .help(help)
    }

    private var note: String {
        let pane = session.command.pane.title
        switch session.state {
        case .starting:
            return "Starting…"
        case .running:
            return "Type here to answer what it asks. ⌃C or ⌘. stops it."
        case .exited(0):
            return "It finished. Gearbox reads the \(pane) pane again."
        case .exited(let status) where status > 128:
            return "Signal \(status - 128) stopped it. Gearbox reads the \(pane) pane again."
        case .exited(let status):
            return "It exited \(status). Gearbox reads the \(pane) pane again."
        case .failed(let message):
            return message
        }
    }
}

/// The console's screen: the text the terminal holds, in a text view inside
/// the tube's clip, as MBM's log sits in its own.
struct ConsoleScreenView: NSViewRepresentable {
    let screen: TerminalScreen
    let style: PhosphorStyle
    /// The command is running, so keys go to it and the cursor shows.
    let accepting: Bool
    let onType: ([UInt8]) -> Void

    func makeNSView(context: Context) -> TubeClipView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        // The stock scroller is a bright grey strip, and on a dark tube that
        // is the first thing your eye finds. Someone who has asked macOS to
        // always show scrollbars means it, so the scroller is drawn to match
        // the phosphor instead.
        scrollView.verticalScroller = PhosphorScroller()

        let textView = ConsoleTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = PhosphorType.bodyFont
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 10, height: 8)
        scrollView.documentView = textView

        let clip = TubeClipView()
        clip.addSubview(scrollView)
        // The frame is set in TubeClipView.layout(); autoresizing would fight it.
        scrollView.autoresizingMask = []
        return clip
    }

    /// What the text view holds, so an update can replace only the cursor's
    /// line and the lines ended since the last.
    final class Coordinator {
        var revision = -1
        var style: PhosphorStyle?
        /// How many of the screen's ended lines the text view holds.
        var lineCount = 0
        /// Their length, in UTF-16 units: where the cursor's line begins.
        var linesLength = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateNSView(_ clip: TubeClipView, context: Context) {
        guard let scrollView = clip.subviews.first as? NSScrollView,
              let textView = scrollView.documentView as? ConsoleTextView,
              let storage = textView.textStorage else { return }
        let drawn = context.coordinator
        let styleChanged = drawn.style != style

        if styleChanged || drawn.revision != screen.revision {
            let wasAtBottom = Self.isNearBottom(scrollView)
            let painter = ConsolePainter(style: style)
            // A new style redraws everything; otherwise only the lines ended
            // since the last update, and the cursor's line, which a carriage
            // return can have rewritten.
            let from = styleChanged || screen.lines.count < drawn.lineCount ? 0 : drawn.lineCount
            let start = from == 0 ? 0 : drawn.linesLength
            let tail = NSMutableAttributedString()
            for line in screen.lines[from...] {
                tail.append(painter.text(line))
                tail.append(painter.newline)
            }
            let linesLength = start + tail.length
            tail.append(painter.text(screen.cursorLine))

            storage.beginEditing()
            storage.replaceCharacters(in: NSRange(location: start, length: storage.length - start), with: tail)
            storage.endEditing()
            drawn.lineCount = screen.lines.count
            drawn.linesLength = linesLength
            drawn.revision = screen.revision

            if styleChanged {
                textView.selectedTextAttributes = painter.selection
                textView.cursorColor = painter.cursor
                if let scroller = scrollView.verticalScroller as? PhosphorScroller {
                    scroller.tint = style == .plain ? nil : NSColor(style.tint)
                    scroller.needsDisplay = true
                }
                drawn.style = style
            }
            textView.sizeToFit()
            if wasAtBottom { textView.scrollToEndOfDocument(nil) }
            clip.refreshEdgeFade()
        }

        textView.onType = accepting ? onType : nil
        textView.cursorLocation = accepting ? drawn.linesLength + screen.cursorOffset : nil
    }

    private static func isNearBottom(_ scrollView: NSScrollView) -> Bool {
        let contentHeight = scrollView.documentView?.frame.height ?? 0
        return contentHeight - scrollView.contentView.bounds.maxY < 40
    }
}

/// The text attributes for each style a program sets, on one screen.
final class ConsolePainter {
    let style: PhosphorStyle
    private var cache: [TerminalScreen.Style: [NSAttributedString.Key: Any]] = [:]
    private var symbolFonts: [Unicode.Scalar: (regular: NSFont, bold: NSFont)?] = [:]

    init(style: PhosphorStyle) {
        self.style = style
    }

    var newline: NSAttributedString {
        NSAttributedString(string: "\n", attributes: attributes(TerminalScreen.Style()))
    }

    var selection: [NSAttributedString.Key: Any] {
        style == .plain ? [.backgroundColor: NSColor.selectedTextBackgroundColor]
            : [.backgroundColor: NSColor(style.tint).withAlphaComponent(0.28)]
    }

    var cursor: NSColor {
        style == .plain ? .textColor : NSColor(style.tint)
    }

    func text(_ runs: [TerminalScreen.Run]) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for run in runs {
            let attributes = attributes(run.style)
            var plain = ""
            for scalar in run.text.unicodeScalars {
                guard let symbol = symbolFont(for: scalar, bold: run.style.bold) else {
                    plain.unicodeScalars.append(scalar)
                    continue
                }
                text.append(NSAttributedString(string: plain, attributes: attributes))
                plain = ""
                var marked = attributes
                marked[.font] = symbol
                text.append(NSAttributedString(string: String(scalar), attributes: marked))
            }
            text.append(NSAttributedString(string: plain, attributes: attributes))
        }
        return text
    }

    /// Menlo, for a mark SF Mono lacks and Menlo has: mrk's ⚠, and ✔.
    /// TextKit's own fallback finds those in Apple Color Emoji, a picture no
    /// tint reaches, and a cascade list on the font does not change its mind
    /// (tried on 2026-10-22).
    private func symbolFont(for scalar: Unicode.Scalar, bold: Bool) -> NSFont? {
        guard scalar.value > 0x7F, scalar.value <= 0xFFFF else { return nil }
        if let known = symbolFonts[scalar] { return known.map { bold ? $0.bold : $0.regular } }
        var unit = UniChar(scalar.value)
        var glyph: CGGlyph = 0
        let lacking = !CTFontGetGlyphsForCharacters(PhosphorType.bodyFont, &unit, &glyph, 1)
        var fonts: (regular: NSFont, bold: NSFont)?
        if lacking, let regular = NSFont(name: "Menlo-Regular", size: PhosphorType.bodySize),
           CTFontGetGlyphsForCharacters(regular, &unit, &glyph, 1) {
            fonts = (regular, NSFont(name: "Menlo-Bold", size: PhosphorType.bodySize) ?? regular)
        }
        symbolFonts[scalar] = fonts
        return fonts.map { bold ? $0.bold : $0.regular }
    }


    func attributes(_ s: TerminalScreen.Style) -> [NSAttributedString.Key: Any] {
        if let cached = cache[s] { return cached }
        let made = make(s)
        cache[s] = made
        return made
    }

    private func make(_ s: TerminalScreen.Style) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.font: s.bold ? PhosphorType.boldFont : PhosphorType.bodyFont]
        if s.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }

        guard style != .plain else {
            var color = s.color.map(Self.ansi) ?? .textColor
            if s.dim { color = color.withAlphaComponent(0.55) }
            if s.inverse {
                attributes[.foregroundColor] = NSColor.textBackgroundColor
                attributes[.backgroundColor] = color
            } else {
                attributes[.foregroundColor] = color
            }
            return attributes
        }

        // A tube has one colour, so what a program prints in red or green
        // shows in the phosphor's own, and mrk's ✓, ⚠ and ✗ carry the
        // difference. What a tube can vary is brightness: bold glows harder
        // and dim glows less.
        let tint = NSColor(style.tint)
        if s.inverse {
            attributes[.foregroundColor] = NSColor(style.ground)
            attributes[.backgroundColor] = tint.withAlphaComponent(0.85)
            return attributes
        }
        attributes[.foregroundColor] = tint.withAlphaComponent(s.dim ? 0.5 : 1)
        // Set as a text attribute, not as a shadow on the view: that would
        // halo the whole rectangle instead of the glyphs. Zero offset, because
        // a phosphor dot blooms evenly.
        let glow = NSShadow()
        glow.shadowColor = tint.withAlphaComponent(s.bold ? 0.9 : s.dim ? 0.35 : 0.75)
        glow.shadowBlurRadius = s.bold ? 6 : 4
        glow.shadowOffset = .zero
        attributes[.shadow] = glow
        return attributes
    }

    /// The eight ANSI colours, as the Plain screen shows them.
    static func ansi(_ color: UInt8) -> NSColor {
        switch color % 8 {
        case 0: return .secondaryLabelColor
        case 1: return .systemRed
        case 2: return .systemGreen
        case 3: return .systemYellow
        case 4: return .systemBlue
        case 5: return .systemPurple
        case 6: return .systemCyan
        default: return .textColor
        }
    }
}

/// The console's text: what the command printed, selectable as any text is,
/// and the keyboard of the terminal it runs on.
final class ConsoleTextView: NSTextView {
    /// Where typing goes while the command runs; nil once it has exited.
    var onType: (([UInt8]) -> Void)?

    /// Where the terminal's cursor is, as an offset into the text; nil hides
    /// it.
    var cursorLocation: Int? {
        didSet {
            guard cursorLocation != oldValue else { return }
            cursorLit = true
            needsDisplay = true
            blink()
        }
    }

    var cursorColor = NSColor.textColor {
        didSet { needsDisplay = true }
    }

    private var cursorLit = true
    private var blinkTimer: Timer?
    /// About the rate a terminal's cursor blinked at.
    private static let blinkPeriod: TimeInterval = 0.53

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            blinkTimer?.invalidate()
            blinkTimer = nil
        } else {
            // So the first key pressed goes to the command.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
            blink()
        }
    }

    override func keyDown(with event: NSEvent) {
        if let onType, let bytes = ConsoleKeys.bytes(characters: event.characters, keyCode: event.keyCode,
                                                     modifiers: event.modifierFlags) {
            onType(bytes)
            scrollToEndOfDocument(nil)
            return
        }
        // Return and Escape belong to the sheet's buttons once the command
        // has exited.
        if onType == nil, [36, 53, 76].contains(event.keyCode) {
            nextResponder?.keyDown(with: event)
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        guard let onType, let text = NSPasteboard.general.string(forType: .string) else {
            return super.paste(sender)
        }
        onType(Array(text.utf8))
        scrollToEndOfDocument(nil)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) {
            return onType != nil && NSPasteboard.general.string(forType: .string) != nil
        }
        return super.validateUserInterfaceItem(item)
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let rect = cursorRect(), rect.insetBy(dx: -8, dy: -8).intersects(dirtyRect) else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        // A block where typing goes, blinking; an outline when typing goes
        // elsewhere, as Terminal draws an inactive window's cursor.
        if window?.isKeyWindow == true && window?.firstResponder === self {
            guard cursorLit else { return }
            let glow = NSShadow()
            glow.shadowColor = cursorColor.withAlphaComponent(0.7)
            glow.shadowBlurRadius = 4
            glow.set()
            cursorColor.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 1), xRadius: 1, yRadius: 1).fill()
        } else {
            cursorColor.withAlphaComponent(0.6).setStroke()
            let outline = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1.5))
            outline.lineWidth = 1
            outline.stroke()
        }
    }

    /// The cell the cursor sits on: the character at its location, or the
    /// place after the last one.
    private func cursorRect() -> NSRect? {
        guard let location = cursorLocation, let layoutManager, let textContainer else { return nil }
        let text = string as NSString
        let font = PhosphorType.bodyFont
        let width = ("M" as NSString).size(withAttributes: [.font: font]).width
        let height = layoutManager.defaultLineHeight(for: font)
        let origin: NSPoint
        if location < text.length {
            let glyph = layoutManager.glyphIndexForCharacter(at: location)
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let box = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
            origin = NSPoint(x: box.minX, y: line.minY)
        } else if text.length == 0 || text.character(at: text.length - 1) == 0x0A {
            layoutManager.ensureLayout(for: textContainer)
            let extra = layoutManager.extraLineFragmentRect
            origin = NSPoint(x: extra.minX + textContainer.lineFragmentPadding, y: extra.minY)
        } else {
            let glyph = layoutManager.glyphIndexForCharacter(at: text.length - 1)
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let box = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
            origin = NSPoint(x: box.maxX, y: line.minY)
        }
        return NSRect(x: origin.x + textContainerOrigin.x, y: origin.y + textContainerOrigin.y,
                      width: width, height: height)
    }

    /// Blinks while the cursor shows, unless Reduce Motion is on.
    private func blink() {
        let wanted = cursorLocation != nil && window != nil
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !wanted {
            blinkTimer?.invalidate()
            blinkTimer = nil
            return
        }
        // Typing restarts the blink lit, so the cursor never hides what was
        // just typed.
        blinkTimer?.invalidate()
        let timer = Timer(timeInterval: Self.blinkPeriod, repeats: true) { [weak self] _ in
            guard let self, let rect = self.cursorRect() else { return }
            self.cursorLit.toggle()
            self.setNeedsDisplay(rect.insetBy(dx: -8, dy: -8))
        }
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }
}
