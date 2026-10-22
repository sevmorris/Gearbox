import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $model.selection) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.checkout.root.path)
                        .font(.caption.monospaced())
                        .lineLimit(1).truncationMode(.middle)
                    Text("Gearbox \(appVersion) never commits. mrk-push does.")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
        } detail: {
            if let problem = model.checkoutProblem {
                ContentUnavailableView("No mrk checkout", systemImage: "folder.badge.questionmark",
                                       description: Text(problem))
            } else {
                switch model.selection ?? .preferences {
                case .preferences: PrefsPane(model: model)
                case .defaults: DefaultsPane(model: model)
                case .loginItems: LoginItemsPane(model: model)
                case .dock: DockPane(model: model)
                }
            }
        }
        .alert("Could not open a terminal",
               isPresented: Binding(get: { model.terminalError != nil }, set: { if !$0 { model.terminalError = nil } })) {
            Button("OK") { model.terminalError = nil }
        } message: {
            Text(model.terminalError ?? "")
        }
    }
}

// MARK: - Shared pieces

/// The pane's loading and failure states over its content.
struct PhaseView<Content: View>: View {
    let phase: LoadPhase
    let retry: () async -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            states
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var states: some View {
        switch phase {
        case .idle, .loading:
            ProgressView().controlSize(.large)
        case .failed(let message):
            ContentUnavailableView {
                Label("mrk refused", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message).textSelection(.enabled)
            } actions: {
                Button("Try Again") { Task { await retry() } }
            }
        case .loaded:
            content()
        }
    }
}

/// A small coloured capsule.
struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }
}

/// A line under the pane's title that says what the pane shows and where it
/// comes from.
struct PaneNote: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

struct RefreshButton: View {
    let action: () async -> Void
    let busy: Bool
    var body: some View {
        Button { Task { await action() } } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(busy)
        .help("Run the check again")
    }
}

extension LoadPhase {
    var isLoading: Bool { self == .loading }
}
