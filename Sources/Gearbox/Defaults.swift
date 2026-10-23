import Foundation

/// One line of config/defaults.tsv: domain, key, type, value, when, section.
struct DefaultsRow: Hashable, Sendable {
    let domain: String
    let key: String
    let type: String
    let value: String
    /// always, trackpad or existing.
    let when: String
    let section: String

    /// The lines of the file, in its order. A line that is not six fields
    /// with good escapes is passed over: defaults.sh refuses the whole file
    /// for it, and --check says so.
    static func parse(_ text: String) -> [DefaultsRow] {
        MrkText.lines(text).compactMap { line in
            guard MrkText.isEntry(line), let f = MrkText.fields(line), f.count == 6 else { return nil }
            return DefaultsRow(domain: f[0], key: f[1], type: f[2], value: f[3], when: f[4], section: f[5])
        }
    }

    /// The same key, type and value in one section is one setting, which
    /// MRK-1 shows once and describes once, for its first domain.
    var setting: String { [section, key, type, value].joined(separator: "\t") }
}

/// One line of docs/defaults/descriptions.tsv.
struct DefaultDescription: Hashable, Sendable {
    let domain: String
    let key: String
    let title: String
    let category: String
    /// The value macOS has when nothing sets the key, or empty.
    let systemDefault: String
    /// A personal choice that may not suit everyone.
    let preference: Bool
    let description: String
    /// Why mrk sets it, or empty.
    let why: String
    /// History and notes that are not Simplified Technical English, or empty.
    let background: String

    /// domain<TAB>key → description. A line in any other shape than nine
    /// fields is passed over; check-defaults-desc refuses it.
    static func parse(_ text: String) -> [String: DefaultDescription] {
        var out: [String: DefaultDescription] = [:]
        for line in MrkText.lines(text) where MrkText.isEntry(line) {
            guard let f = MrkText.fields(line), f.count == 9 else { continue }
            out["\(f[0])\t\(f[1])"] = DefaultDescription(
                domain: f[0], key: f[1], title: f[2], category: f[3], systemDefault: f[4],
                preference: f[5] == "true", description: f[6], why: f[7], background: f[8])
        }
        return out
    }
}

/// One line of `defaults.sh --check`.
struct DefaultCheck: Hashable, Sendable {
    enum State: String, Sendable {
        case set, differs, absent
        /// A when=existing key whose app has not made its preferences yet.
        /// make defaults passes it over until the app has, so it is not
        /// drift. An mrk before sevmorris/mrk#122 calls it absent.
        case nodomain
        /// A key that config/defaults-skip.tsv lists: make defaults does not
        /// write it, whatever its value. Gearbox shows it as off. An mrk
        /// before sevmorris/mrk#130 has no such key.
        case skipped

        /// What a run of make defaults would write.
        var isDrift: Bool { self == .differs || self == .absent }
    }

    let domain: String
    let key: String
    /// The value mrk sets, with ~/ shown expanded.
    let mrkValue: String
    /// The value the key has now; empty when it is absent or its domain is.
    let current: String
    let state: State

    /// Five fields or more, by mrk's --check line contract, in the order of
    /// the file. A line in any other shape, or with a state Gearbox does not
    /// know, is passed over.
    static func parse(_ output: String) -> [DefaultCheck] {
        MrkText.lines(output).compactMap { line in
            guard let f = MrkText.fields(line), f.count >= 5, let state = State(rawValue: f[4]) else { return nil }
            return DefaultCheck(domain: f[0], key: f[1], mrkValue: f[2], current: f[3], state: state)
        }
    }
}

/// A domain and a key of config/defaults.tsv: what defaults.sh's options of
/// one key take.
struct DefaultsKey: Hashable, Sendable {
    let domain: String
    let key: String
}

/// A key as the defaults pane shows it: what defaults.sh --check found, with
/// its line of config/defaults.tsv and its description.
struct DefaultsEntry: Identifiable, Hashable, Sendable {
    let check: DefaultCheck
    let row: DefaultsRow?
    let description: DefaultDescription?
    /// The other domains of the same setting, when this is its first.
    var alsoDomains: [String] = []
    /// Every domain of the same setting, this one among them, in the order
    /// of the file. The switch turns them off or on together, as MRK-1
    /// shows them as one setting.
    var settingDomains: [String] = []

    var id: String { "\(check.domain)\t\(check.key)" }
    var section: String { row?.section ?? "Not in config/defaults.tsv" }
    var title: String { description?.title ?? check.key }
    var isOn: Bool { check.state != .skipped }

    /// The keys the switch and Apply change: this key in each domain of its
    /// setting.
    var keys: [DefaultsKey] {
        (settingDomains.isEmpty ? [check.domain] : settingDomains).map { DefaultsKey(domain: $0, key: check.key) }
    }

    /// Every --check line, in its order, joined to the table and the
    /// descriptions. A line whose section, key, type and value repeat an
    /// earlier line's takes that line's description, as MRK-1 shows it.
    static func join(checks: [DefaultCheck], rows: [DefaultsRow],
                     descriptions: [String: DefaultDescription]) -> [DefaultsEntry] {
        var rowByID: [String: DefaultsRow] = [:]
        var firstOfSetting: [String: DefaultsRow] = [:]
        var mirrors: [String: [String]] = [:]
        var domainsOfSetting: [String: [String]] = [:]
        for row in rows {
            rowByID["\(row.domain)\t\(row.key)"] = row
            domainsOfSetting[row.setting, default: []].append(row.domain)
            if let first = firstOfSetting[row.setting] {
                mirrors["\(first.domain)\t\(first.key)", default: []].append(row.domain)
            } else {
                firstOfSetting[row.setting] = row
            }
        }
        return checks.map { check in
            let id = "\(check.domain)\t\(check.key)"
            let row = rowByID[id]
            var description = descriptions[id]
            if description == nil, let row, let first = firstOfSetting[row.setting] {
                description = descriptions["\(first.domain)\t\(first.key)"]
            }
            return DefaultsEntry(check: check, row: row, description: description,
                                 alsoDomains: mirrors[id] ?? [],
                                 settingDomains: row.flatMap { domainsOfSetting[$0.setting] } ?? [check.domain])
        }
    }
}

/// The entries of one section of config/defaults.tsv, in the order the
/// sections first appear.
struct DefaultsSection: Identifiable, Hashable, Sendable {
    let name: String
    let entries: [DefaultsEntry]
    var id: String { name }

    var counts: DefaultsCounts {
        entries.reduce(into: DefaultsCounts()) { c, e in
            switch e.check.state {
            case .set: c.set += 1
            case .differs: c.differs += 1
            case .absent: c.absent += 1
            case .nodomain: c.waiting += 1
            case .skipped: c.skipped += 1
            }
        }
    }

    static func group(_ entries: [DefaultsEntry]) -> [DefaultsSection] {
        var order: [String] = []
        var bySection: [String: [DefaultsEntry]] = [:]
        for entry in entries {
            if bySection[entry.section] == nil { order.append(entry.section) }
            bySection[entry.section, default: []].append(entry)
        }
        return order.map { DefaultsSection(name: $0, entries: bySection[$0]!) }
    }
}

/// How many keys are in each state.
struct DefaultsCounts: Equatable, Sendable {
    var set = 0
    var differs = 0
    var absent = 0
    /// nodomain: keys that wait for their app to make its preferences.
    var waiting = 0
    /// Keys that config/defaults-skip.tsv lists: off.
    var skipped = 0

    static func + (a: DefaultsCounts, b: DefaultsCounts) -> DefaultsCounts {
        DefaultsCounts(set: a.set + b.set, differs: a.differs + b.differs,
                       absent: a.absent + b.absent, waiting: a.waiting + b.waiting,
                       skipped: a.skipped + b.skipped)
    }
}
