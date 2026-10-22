import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// config/dock.txt, the Dock make dock builds, with dock-setup's view of each
/// item.
struct DockPane: View {
    @Bindable var model: AppModel
    @State private var confirmApply = false
    @State private var selection: String?

    private var dock: DockModel { model.dock }

    var body: some View {
        VStack(spacing: 0) {
            PaneNote(text: "The Dock that make dock builds, left to right, from config/dock.txt. Finder is always "
                     + "first and needs no line. Drag to reorder; each change writes the file, and "
                     + "dock-setup --check reads it again. The Dock itself changes only when you apply.")
            Divider()
            if let error = dock.editError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
            }
            PhaseView(phase: dock.phase, retry: dock.load) {
                List(selection: $selection) {
                    Section("Apps") {
                        ForEach(dock.list.items.filter(\.isApp)) { item in
                            row(item).tag(item.line)
                        }
                        .onMove { source, destination in
                            Task { await dock.moveApps(fromOffsets: source, toOffset: destination) }
                        }
                    }
                    let folders = dock.list.items.filter { !$0.isApp }
                    if !folders.isEmpty {
                        Section("Beside the Trash") {
                            ForEach(folders) { item in row(item).tag(item.line) }
                        }
                    }
                }
                .onDeleteCommand { if let selection { Task { await dock.remove(selection) } } }
            }
        }
        .navigationTitle("Dock")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                Button { choose(apps: true) } label: { Label("Add App…", systemImage: "plus.app") }
                    .help("Add an app to config/dock.txt")
                Button { choose(apps: false) } label: { Label("Add Folder…", systemImage: "folder.badge.plus") }
                    .help("Add a folder, which the Dock shows beside the Trash")
                Button { if let selection { Task { await dock.remove(selection) } } } label: {
                    Label("Remove", systemImage: "minus")
                }
                .disabled(selection == nil)
                .help("Delete the selected item from config/dock.txt")
                RefreshButton(action: dock.load, busy: dock.phase.isLoading)
                Button { confirmApply = true } label: { Label("Apply…", systemImage: "dock.arrow.down.rectangle") }
                    .help("Run make dock in a terminal")
            }
        }
        .confirmationDialog("Rebuild the Dock from config/dock.txt?", isPresented: $confirmApply) {
            Button("Open in Terminal") { Task { await model.runInTerminal(.applyDock) } }
        } message: {
            Text("make dock deletes every item from the Dock, adds the items of this list, and restarts the Dock. "
                 + "It saved the Dock once, the first time it ran, to ~/.mrk/plist-backups/com.apple.dock.plist, "
                 + "and does not save it again, so a layout you made by hand since then is lost. "
                 + "It runs in a terminal.")
        }
        .task { if dock.phase == .idle { await dock.load() } }
    }

    private var subtitle: String {
        guard dock.phase == .loaded else { return "" }
        let missing = dock.checks.values.filter { $0.state == .missing }.count
        let n = dock.list.items.count
        return missing == 0 ? "\(n) items" : "\(n) items · \(missing) missing on this Mac"
    }

    private func row(_ item: DockList.Item) -> some View {
        let check = dock.checks[item.line]
        return HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: check?.path ?? item.line))
                .resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                Text(item.line).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if check?.state == .missing {
                Badge(text: item.isApp ? "not installed" : "no such folder", color: .orange)
                    .help("make dock skips it on this Mac")
            }
        }
        .contextMenu {
            Button("Remove from the Dock List") { Task { await dock.remove(item.line) } }
            Button("Show in Finder") {
                if let path = check?.path { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
            }
        }
    }

    private func choose(apps: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = apps
        panel.canChooseDirectories = !apps
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        if apps {
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
        }
        panel.prompt = "Add to Dock List"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await dock.add(url) }
    }
}
