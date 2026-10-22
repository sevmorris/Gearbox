import SwiftUI

/// What the next `snapshot-prefs` would commit to mrk-prefs, by app.
struct PrefsPane: View {
    @Bindable var model: AppModel
    @State private var confirmSnapshot = false
    @State private var showLog = false

    private var prefs: PrefsModel { model.prefs }

    var body: some View {
        VStack(spacing: 0) {
            PaneNote(text: "The changes the next snapshot would commit to mrk-prefs, from snapshot-prefs --check. "
                     + "It exports into a scratch copy and changes nothing. Keys that change on their own are left out.")
            Divider()
            PhaseView(phase: prefs.phase, retry: prefs.load) {
                if prefs.groups.isEmpty {
                    ContentUnavailableView("Nothing to snapshot", systemImage: "checkmark.circle",
                                           description: Text("The app preferences match the last snapshot in mrk-prefs."))
                } else {
                    List {
                        ForEach(prefs.groups) { group in
                            Section {
                                ForEach(group.changes) { change in
                                    HStack {
                                        Text(PrefGroup.label(of: change, in: group))
                                            .font(.body.monospaced())
                                            .lineLimit(1).truncationMode(.middle)
                                        Spacer()
                                        Self.badge(change.kind)
                                    }
                                }
                            } header: {
                                HStack {
                                    Text(group.name)
                                    Spacer()
                                    Text("\(group.changes.count)").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            if prefs.phase == .loaded, !prefs.log.isEmpty {
                Divider()
                DisclosureGroup("snapshot-prefs output", isExpanded: $showLog) {
                    ScrollView {
                        Text(prefs.log)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
        .navigationTitle("App Preferences")
        .navigationSubtitle(prefs.phase == .loaded ? "\(prefs.changeCount) change(s) in \(prefs.groups.count) app(s)" : "")
        .toolbar {
            ToolbarItemGroup {
                RefreshButton(action: prefs.load, busy: prefs.phase.isLoading)
                Button { confirmSnapshot = true } label: {
                    Label("Snapshot…", systemImage: "square.and.arrow.up.on.square")
                }
                .help("Run make snapshot-prefs in Gearbox's console")
            }
        }
        .confirmationDialog("Snapshot the app preferences?", isPresented: $confirmSnapshot) {
            Button("Snapshot") { Task { await model.runInConsole(.snapshotPrefs) } }
        } message: {
            Text("make snapshot-prefs exports the app preferences, commits them to mrk-prefs and pushes. "
                 + "It runs in Gearbox's console, where its secret scan can stop and ask you before it commits.")
        }
        .task { if prefs.phase == .idle { await prefs.load() } }
    }

    static func badge(_ kind: PrefChange.Kind) -> Badge {
        switch kind {
        case .added: return Badge(text: "added", color: .green)
        case .deleted: return Badge(text: "deleted", color: .red)
        case .changed: return Badge(text: "changed", color: .orange)
        }
    }
}
