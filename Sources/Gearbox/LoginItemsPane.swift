import SwiftUI

/// The apps config/login-items.txt tracks, against the login items of this
/// Mac, with sync-login-items' own decisions.
struct LoginItemsPane: View {
    @Bindable var model: AppModel
    private var items: LoginItemsModel { model.loginItems }

    var body: some View {
        VStack(spacing: 0) {
            PaneNote(text: "The apps mrk starts at login, against this Mac's login items, from sync-login-items --check. "
                     + "Add and Remove change config/login-items.txt and the manual; Ignore adds the app to "
                     + "~/.mrk/login-items-ignore. None of them changes this Mac's login items, and none commits.")
            Divider()
            if let error = items.decisionError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
            }
            PhaseView(phase: items.phase, retry: items.load) {
                List {
                    Section("Tracked in config/login-items.txt") {
                        ForEach(items.rows.filter { $0.state != .untracked }) { row in
                            rowView(row)
                        }
                    }
                    let untracked = items.rows.filter { $0.state == .untracked }
                    Section("Login items mrk does not track") {
                        if untracked.isEmpty {
                            Text("None. Every login item on this Mac is tracked or ignored.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(untracked) { row in rowView(row) }
                    }
                }
            }
        }
        .navigationTitle("Login Items")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                RefreshButton(action: items.load, busy: items.phase.isLoading || items.busy != nil)
            }
        }
        .task { if items.phase == .idle { await items.load() } }
    }

    private var subtitle: String {
        guard items.phase == .loaded else { return "" }
        let offers = items.rows.filter { $0.state != .tracked }.count
        return offers == 0 ? "In step" : "\(offers) to decide"
    }

    @ViewBuilder
    private func rowView(_ row: LoginItemRow) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: row.path))
                .resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                Text(row.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if items.busy == row.name {
                ProgressView().controlSize(.small)
            }
            switch row.state {
            case .tracked:
                Badge(text: "login item", color: .green)
            case .stale:
                Badge(text: "not a login item", color: .orange)
                decisionButton("Remove", .remove, row, help: "Stop tracking it: sync-login-items --remove")
            case .ignoredButTracked:
                Badge(text: "ignored, still tracked", color: .orange)
                decisionButton("Remove", .remove, row, help: "Stop tracking it: sync-login-items --remove")
            case .untracked:
                decisionButton("Ignore", .ignore, row, help: "Never offer it again: sync-login-items --ignore")
                decisionButton("Add", .add, row, help: "Track it: sync-login-items --add")
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 2)
    }

    private func decisionButton(_ title: String, _ decision: LoginItemsModel.Decision,
                                _ row: LoginItemRow, help: String) -> some View {
        Button(title) { Task { await items.decide(decision, row) } }
            .disabled(items.busy != nil)
            .help(help)
    }
}
