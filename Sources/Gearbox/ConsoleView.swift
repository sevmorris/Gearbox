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
