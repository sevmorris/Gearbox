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
                     + "Waiting means it waits for its app's preferences. Off means config/defaults-skip.tsv "
                     + "lists it, so make defaults leaves it. A switch restarts Finder, the Dock and the menu bar when it changes a key.")
            Divider()
            if defaults.descriptionsMissing {
                Label("This mrk has no docs/defaults/descriptions.tsv, so the keys have no descriptions. Run make pull.",
                      systemImage: "info.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
            }
            if defaults.skipListMissing && defaults.phase == .loaded {
                Label("This mrk has no config/defaults-skip.tsv, so a key cannot be turned off. Run make pull.",
                      systemImage: "info.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
            }
            if let error = defaults.decisionError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
            }
            PhaseView(phase: defaults.phase, retry: { await defaults.load() }) {
                HSplitView {
                    ScrollViewReader { proxy in
                        List(selection: $defaults.selectedID) {
                            ForEach(defaults.shown) { section in
                                Section(section.name) {
                                    ForEach(section.entries) { entry in
                                        DefaultsRowView(entry: entry, defaults: defaults).tag(entry.id).id(entry.id)
                                    }
                                }
                            }
                        }
                        .onAppear {
                            if let id = defaults.selectedID { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                    .frame(minWidth: 380, idealWidth: 460)
                    Group {
                        if let entry = defaults.selected {
                            DefaultDetail(entry: entry, defaults: defaults)
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
                .help("Show every key, only those not set, or only those that are off")
                Toggle("Trackpad", isOn: $defaults.withTrackpad)
                    .toggleStyle(.checkbox)
                    .help("Compare the trackpad keys too, which make trackpad writes")
                    .onChange(of: defaults.withTrackpad) { Task { await defaults.load() } }
                RefreshButton(action: { await defaults.load() }, busy: defaults.phase.isLoading || defaults.busy != nil)
                Button { confirmApply = true } label: {
                    Label("Apply All…", systemImage: "checkmark.seal")
                }
                .disabled(defaults.busy != nil)
                .help("Run \(TerminalCommand.applyDefaults(withTrackpad: defaults.withTrackpad).command) in Gearbox's console")
            }
        }
        .confirmationDialog("Apply all the defaults?", isPresented: $confirmApply) {
            Button("Apply All") {
                Task { await model.runInConsole(.applyDefaults(withTrackpad: defaults.withTrackpad)) }
            }
        } message: {
            Text("\(TerminalCommand.applyDefaults(withTrackpad: defaults.withTrackpad).command) writes each key "
                 + "that is on and not set, and records its old value in ~/.mrk/defaults-rollback.sh. "
                 + "Then it restarts Finder, the Dock and SystemUIServer, so their windows and the menu bar "
                 + "close and open again. It runs in Gearbox's console.")
        }
        .task { if defaults.phase == .idle { await defaults.load() } }
    }

    private var subtitle: String {
        guard defaults.phase == .loaded else { return "" }
        let c = defaults.counts
        var text = "\(c.set) set · \(c.differs) differ · \(c.absent) absent"
        if c.waiting > 0 { text += " · \(c.waiting) waiting" }
        if c.skipped > 0 { text += " · \(c.skipped) off" }
        return text
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
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }
}

/// The switch of a key: on means mrk writes the key, off means
/// config/defaults-skip.tsv lists it. It turns every domain of the setting
/// together, and shows a spinner while defaults.sh runs.
struct DefaultSwitch: View {
    let entry: DefaultsEntry
    let defaults: DefaultsModel

    var body: some View {
        if defaults.busy == entry.id {
            ProgressView().controlSize(.small).frame(width: 38)
        } else {
            Toggle("On", isOn: Binding(
                get: { entry.isOn },
                set: { on in Task { await defaults.setOn(on, for: entry) } }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(defaults.busy != nil || defaults.skipListMissing)
                .help(help)
        }
    }

    private var help: String {
        if defaults.skipListMissing { return "This mrk cannot turn a key off. Run make pull." }
        let keys = entry.keys.map { "\($0.domain) \($0.key)" }.joined(separator: ", ")
        return entry.isOn
            ? "Turn off: make defaults leaves \(keys), and it goes back to its value from before mrk"
            : "Turn on: make defaults writes \(keys), and Gearbox writes it now"
    }
}

struct DefaultsRowView: View {
    let entry: DefaultsEntry
    let defaults: DefaultsModel

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            StateMark(state: entry.check.state)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).lineLimit(1)
                    .foregroundStyle(entry.isOn ? .primary : .secondary)
                Text("\(entry.check.domain) \(entry.check.key)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            DefaultSwitch(entry: entry, defaults: defaults)
        }
    }
}

struct DefaultDetail: View {
    let entry: DefaultsEntry
    let defaults: DefaultsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.title).font(.title2.weight(.semibold))
                    Spacer()
                    stateBadge
                    DefaultSwitch(entry: entry, defaults: defaults)
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

                if entry.check.state == .skipped {
                    block("Off",
                          "config/defaults-skip.tsv lists this key, so make defaults leaves it as it is. "
                            + "Turn it on to write mrk's value again.",
                          color: .secondary)
                }
                if entry.check.state == .nodomain {
                    block("Waits for the app",
                          "Its preferences do not exist yet, so make defaults passes this key over. "
                            + "Open the app once; the next make defaults writes the key.",
                          color: .secondary)
                }
                if entry.check.state.isDrift {
                    HStack(spacing: 10) {
                        Button("Apply This Key") { Task { await defaults.apply(entry) } }
                            .disabled(defaults.busy != nil || defaults.skipListMissing)
                            .help(defaults.skipListMissing
                                  ? "This mrk cannot write one key. Run make pull."
                                  : "Run defaults.sh --key for this key")
                        Text("Writes mrk's value now, and restarts Finder, the Dock and the menu bar.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
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
                Text("The switch runs defaults.sh --skip and --revert to turn the key off, and --unskip and --key "
                     + "to turn it on. It changes config/defaults-skip.tsv, which mrk-push or pushall commits.")
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
        case .skipped: return Badge(text: "off", color: .secondary)
        }
    }

    private var nowText: String {
        switch entry.check.state {
        case .absent: return "absent"
        case .nodomain: return "no preferences yet"
        case .set, .differs: return value(entry.check.current, type: nil)
        // A skipped key's current value is empty when the key is absent.
        case .skipped: return entry.check.current.isEmpty ? "absent" : value(entry.check.current, type: nil)
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
