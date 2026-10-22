import Foundation

/// config/dock.txt, the Dock dock-setup builds, left to right.
///
/// Writing the plain list is the interface, as Barkeep writes the picker
/// descriptions: one path on each line, a full path or one that starts with
/// ~/, and a path that ends in .app is an app. Gearbox keeps every comment.
/// The comments above the first item are the file's header and stay at the
/// top; a comment or an empty line among the items belongs to the item after
/// it and moves with it; those after the last item stay at the end.
struct DockList: Equatable, Sendable {
    struct Item: Equatable, Hashable, Sendable, Identifiable {
        /// The line as the file has it.
        let line: String
        /// The comment and empty lines just above it, after the header.
        var leading: [String] = []
        var id: String { line }
        var isApp: Bool { line.hasSuffix(".app") }
        var name: String {
            var name = (line as NSString).lastPathComponent
            if name.hasSuffix(".app") { name.removeLast(4) }
            return name
        }
    }

    var header: [String]
    var items: [Item]
    var trailer: [String]

    static func parse(_ text: String) -> DockList {
        var header: [String] = []
        var items: [Item] = []
        var pending: [String] = []
        for line in MrkText.lines(text).map(String.init) {
            if MrkText.isEntry(line[...]) {
                if items.isEmpty {
                    header += pending
                    pending = []
                }
                items.append(Item(line: line, leading: pending))
                pending = []
            } else {
                pending.append(line)
            }
        }
        if items.isEmpty { return DockList(header: pending, items: [], trailer: []) }
        return DockList(header: header, items: items, trailer: pending)
    }

    var text: String {
        var lines = header
        for item in items { lines += item.leading + [item.line] }
        lines += trailer
        return lines.map { $0 + "\n" }.joined()
    }

    /// The line for a path: ~/ for one in the home directory, as the file
    /// writes ~/Work Apps, so the list suits another Mac.
    static func line(for url: URL, home: String) -> String {
        let path = url.standardizedFileURL.path
        let prefix = home.hasSuffix("/") ? home : home + "/"
        return path.hasPrefix(prefix) ? "~/" + path.dropFirst(prefix.count) : path
    }

    enum EditError: LocalizedError, Equatable {
        case alreadyListed(String)
        case notAPath(String)

        var errorDescription: String? {
            switch self {
            case .alreadyListed(let line): return "\(line) is already in the Dock list."
            case .notAPath(let line): return "\(line) is not a full path, or a path that starts with ~/."
            }
        }
    }

    /// Adds an item at the end of the apps, or of the list for a folder,
    /// which the Dock keeps beside the Trash.
    mutating func add(_ line: String) throws {
        guard line.hasPrefix("/") || line.hasPrefix("~/"), !line.contains("\n") else {
            throw EditError.notAPath(line)
        }
        guard !items.contains(where: { $0.line == line }) else { throw EditError.alreadyListed(line) }
        let item = Item(line: line)
        if item.isApp, let lastApp = items.lastIndex(where: \.isApp) {
            items.insert(item, at: lastApp + 1)
        } else {
            items.append(item)
        }
    }

    mutating func remove(_ line: String) {
        guard let i = items.firstIndex(where: { $0.line == line }) else { return }
        let removed = items.remove(at: i)
        // Its comments stay, with the item that now follows them.
        if !removed.leading.isEmpty {
            if i < items.count { items[i].leading = removed.leading + items[i].leading }
            else { trailer = removed.leading + trailer }
        }
    }

    /// Reorders the apps, as the Apps list shows them: the offsets count
    /// apps alone. The apps go back into the places apps had, so a folder
    /// keeps its line.
    mutating func moveApps(fromOffsets source: IndexSet, toOffset destination: Int) {
        let slots = items.indices.filter { items[$0].isApp }
        var apps = slots.map { items[$0] }
        apps.move(fromOffsets: source, toOffset: destination)
        for (slot, app) in zip(slots, apps) { items[slot] = app }
    }

    /// Writes the list through a temporary file in the same directory,
    /// renamed over it, with mode 0644: a reader never sees half a file.
    func write(to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).gearbox-\(UUID().uuidString)")
        try Data(text.utf8).write(to: tmp)
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tmp.path)
            guard rename(tmp.path, url.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [
                    NSLocalizedDescriptionKey: "Could not replace \(url.path): \(String(cString: strerror(errno)))",
                ])
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
}

/// One line of `dock-setup --check`.
struct DockCheck: Hashable, Sendable {
    enum Kind: String, Sendable { case app, folder }
    enum State: String, Sendable { case present, missing }

    let kind: Kind
    /// The line as config/dock.txt has it.
    let line: String
    /// The path it names, with ~/ expanded.
    let path: String
    let state: State

    /// Four fields, escaped as config/defaults.tsv escapes them. A line in
    /// any other shape is passed over.
    static func parse(_ output: String) -> [DockCheck] {
        MrkText.lines(output).compactMap { line in
            guard let f = MrkText.fields(line), f.count == 4, let kind = Kind(rawValue: f[0]),
                  let state = State(rawValue: f[3]) else { return nil }
            return DockCheck(kind: kind, line: f[1], path: f[2], state: state)
        }
    }
}
