import Foundation

/// One line of `snapshot-prefs --check`: a key of a file that the next
/// snapshot commits to mrk-prefs.
struct PrefChange: Hashable, Sendable, Identifiable {
    enum Kind: String, Sendable { case added, deleted, changed }

    /// A path in mrk-prefs, such as Raycast.plist or app-support/Loopback/x.
    let file: String
    /// A top-level key of a changed plist, or empty for a whole file.
    let key: String
    let kind: Kind

    var id: String { "\(file)\t\(key)" }

    /// Three fields or more, with no header, by mrk's --check line contract,
    /// each with its escapes undone: a plist key may hold a tab, a newline
    /// or a backslash. A line in any other shape is passed over.
    static func parse(_ output: String) -> [PrefChange] {
        MrkText.lines(output).compactMap { line in
            guard let fields = MrkText.fields(line), fields.count >= 3, !fields[0].isEmpty,
                  let kind = Kind(rawValue: fields[2]) else { return nil }
            return PrefChange(file: fields[0], key: fields[1], kind: kind)
        }
    }
}

/// The named apps of config/app-prefs.tsv: the plist in mrk-prefs, and the
/// name to show for it.
struct AppPrefsTable: Sendable {
    /// file → name
    let names: [String: String]

    /// Four fields, separated by tabs: domain, file, app and name. A line in
    /// any other shape is passed over; snapshot-prefs refuses it.
    static func parse(_ text: String) -> AppPrefsTable {
        var names: [String: String] = [:]
        for line in MrkText.lines(text) where MrkText.isEntry(line) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if f.count == 4, !f[1].isEmpty, !f[3].isEmpty { names[f[1]] = f[3] }
        }
        return AppPrefsTable(names: names)
    }
}

/// The changes of one app, or of one directory in mrk-prefs.
struct PrefGroup: Identifiable, Hashable, Sendable {
    /// The app's name from config/app-prefs.tsv, or the directory.
    let name: String
    let changes: [PrefChange]
    var id: String { name }

    /// A top-level plist the table names goes under the app's name. Any other
    /// top-level file is its own group, and a file in a directory goes under
    /// the directory, such as sevmorris-apps or app-support/Loopback.
    /// Groups keep the order in which snapshot-prefs first names them.
    static func group(_ changes: [PrefChange], table: AppPrefsTable) -> [PrefGroup] {
        var order: [String] = []
        var byName: [String: [PrefChange]] = [:]
        for change in changes {
            let name: String
            if let slash = change.file.lastIndex(of: "/") {
                name = String(change.file[..<slash])
            } else {
                name = table.names[change.file] ?? change.file
            }
            if byName[name] == nil { order.append(name) }
            byName[name, default: []].append(change)
        }
        return order.map { PrefGroup(name: $0, changes: byName[$0]!) }
    }

    /// What a row shows: the key, or for a file in a directory, the file and
    /// the key.
    static func label(of change: PrefChange, in group: PrefGroup) -> String {
        var file = change.file
        if file.hasPrefix(group.name + "/") { file.removeFirst(group.name.count + 1) }
        let inDirectory = change.file != file
        switch (inDirectory, change.key.isEmpty) {
        case (false, false): return change.key
        case (false, true):  return "The whole file"
        case (true, false):  return "\(file) — \(change.key)"
        case (true, true):   return file
        }
    }
}
