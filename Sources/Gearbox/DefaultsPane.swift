import SwiftUI

/// Every key of config/defaults.tsv against this Mac, with its description.
struct DefaultsPane: View {
    @Bindable var model: AppModel
    @State private var confirmApply = false

    private var defaults: DefaultsModel { model.defaults }

    var body: some View {
        @Bindable var defaults = model.defaults
        VStack(spacing: 0) {
            PaneNote(text: "Each key mrk sets, from defaults.sh --check, with its description from MRK-1. "
                     + "Set means a run of make defaults skips it. Waiting means it waits for its app, "
                     + "whose preferences do not exist yet.")
            Divider()
            if defaults.descriptionsMissing {
                Label("This mrk has no docs/defaults/descriptions.tsv, so the keys have no descriptions. Run make pull.",
                      systemImage: "info.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
            }
            PhaseView(phase: defaults.phase, retry: defaults.load) {
                HSplitView {
                    ScrollViewReader { proxy in
                        List(selection: $defaults.selectedID) {
                            ForEach(defaults.shown) { section in
                                Section(section.name) {
                                    ForEach(section.entries) { entry in
                                        DefaultsRowView(entry: entry).tag(entry.id).id(entry.id)
                                    }
                                }
                            }
                        }
                        .onAppear {
                            if let id = defaults.selectedID { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                    .frame(minWidth: 340, idealWidth: 420)
                    Group {
                        if let entry = defaults.selected {
                            DefaultDetail(entry: entry)
                        } else {
                            ContentUnavailableView("Select a key", systemImage: "gearshape.2")
                        }
                    }
                    .frame(minWidth: 300, idealWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .searchable(text: $defaults.search, placement: .toolbar, prompt: "Search keys")
        .navigationTitle("macOS Defaults")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                Picker("Show", selection: $defaults.filter) {
                    ForEach(DefaultsModel.Filter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Show every key, or only those not set")
                Toggle("Trackpad", isOn: $defaults.withTrackpad)
                    .toggleStyle(.checkbox)
                    .help("Compare the trackpad keys too, which make trackpad writes")
                    .onChange(of: defaults.withTrackpad) { Task { await defaults.load() } }
                RefreshButton(action: defaults.load, busy: defaults.phase.isLoading)
                Button { confirmApply = true } label: {
                    Label("Apply All…", systemImage: "checkmark.seal")
                }
                .help("Run \(TerminalCommand.applyDefaults(withTrackpad: defaults.withTrackpad).command) in a terminal")
            }
        }
        .confirmationDialog("Apply all the defaults?", isPresented: $confirmApply) {
            Button("Open in Terminal") {
                Task { await model.runInTerminal(.applyDefaults(withTrackpad: defaults.withTrackpad)) }
            }
        } message: {
            Text("\(TerminalCommand.applyDefaults(withTrackpad: defaults.withTrackpad).command) writes each key "
                 + "that is not set, and records its old value in ~/.mrk/defaults-rollback.sh. "
                 + "Then it restarts Finder, the Dock and SystemUIServer, so their windows and the menu bar "
                 + "close and open again. It runs in a terminal.")
        }
        .task { if defaults.phase == .idle { await defaults.load() } }
    }

    private var subtitle: String {
        guard defaults.phase == .loaded else { return "" }
        let c = defaults.counts
        let text = "\(c.set) set · \(c.differs) differ · \(c.absent) absent"
        return c.waiting == 0 ? text : text + " · \(c.waiting) waiting"
    }
}

struct StateMark: View {
    let state: DefaultCheck.State
    var body: some View {
        switch state {
        case .set: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .differs: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .absent: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        case .nodomain: Image(systemName: "hourglass").foregroundStyle(.secondary)
        }
    }
}

struct DefaultsRowView: View {
    let entry: DefaultsEntry
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StateMark(state: entry.check.state)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).lineLimit(1)
                Text("\(entry.check.domain) \(entry.check.key)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }
}

struct DefaultDetail: View {
    let entry: DefaultsEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.title).font(.title2.weight(.semibold))
                    Spacer()
                    stateBadge
                }
                Text("\(entry.check.domain) \(entry.check.key)")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    row("mrk sets", value(entry.check.mrkValue, type: entry.row?.type))
                    row("Now", nowText)
                    if let d = entry.description, !d.systemDefault.isEmpty { row("macOS default", d.systemDefault) }
                    if let r = entry.row {
                        row("Written", whenText(r.when))
                        row("Section", r.section)
                    }
                    if !entry.alsoDomains.isEmpty { row("Also in", entry.alsoDomains.joined(separator: ", ")) }
                }
                .font(.callout)

                if entry.check.state == .nodomain {
                    block("Waits for the app",
                          "Its preferences do not exist yet, so make defaults passes this key over. "
                            + "Open the app once; the next make defaults writes the key.",
                          color: .secondary)
                }
                if let d = entry.description {
                    Text(d.description).fixedSize(horizontal: false, vertical: true)
                    if !d.why.isEmpty { block("Why this setting", d.why, color: .accentColor) }
                    if d.preference {
                        block("Personal preference",
                              "This reflects a specific workflow and may not suit everyone. Review it before you apply it.",
                              color: .purple)
                    }
                    if !d.background.isEmpty { block("Background", d.background, color: .secondary) }
                } else {
                    Text("docs/defaults/descriptions.tsv has no description of this key.")
                        .foregroundStyle(.secondary)
                }
                Text("Gearbox applies all the keys at once. Applying one key needs a new defaults.sh option.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    private var stateBadge: Badge {
        switch entry.check.state {
        case .set: return Badge(text: "set", color: .green)
        case .differs: return Badge(text: "differs", color: .orange)
        case .absent: return Badge(text: "absent", color: .secondary)
        case .nodomain: return Badge(text: "waiting", color: .secondary)
        }
    }

    private var nowText: String {
        switch entry.check.state {
        case .absent: return "absent"
        case .nodomain: return "no preferences yet"
        case .set, .differs: return value(entry.check.current, type: nil)
        }
    }

    private func value(_ text: String, type: String?) -> String {
        let shown = text.isEmpty ? "\"\"" : text
        return type.map { "\(shown)  (\($0))" } ?? shown
    }

    private func whenText(_ when: String) -> String {
        switch when {
        case "trackpad": return "only by make trackpad"
        case "existing": return "only once the app has made its preferences"
        default: return "on every run"
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).font(.callout.monospaced())
        }
    }

    private func block(_ title: String, _ text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(color)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
