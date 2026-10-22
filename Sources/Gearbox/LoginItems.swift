import Foundation

/// One line of `sync-login-items --check`: an item an interactive run would
/// offer.
struct LoginItemOffer: Hashable, Sendable, Identifiable {
    enum Action: String, Sendable { case add, remove }
    enum Reason: String, Sendable {
        /// A login item config/login-items.txt does not track.
        case new
        /// A tracked app that is not a login item.
        case stale
        /// A tracked app that ~/.mrk/login-items-ignore names.
        case ignored
    }

    let action: Action
    /// The app name without .app, as the decisions take it.
    let name: String
    /// For an add, the login item's path; for a remove, the line in the file.
    let path: String
    let reason: Reason

    var id: String { "\(action.rawValue)\t\(name)" }

    /// Four fields or more, by mrk's --check line contract, each with its
    /// escapes undone, so a name with a backslash goes back to --add as
    /// sync-login-items wrote it. A line in any other shape is passed over.
    static func parse(_ output: String) -> [LoginItemOffer] {
        MrkText.lines(output).compactMap { line in
            guard let f = MrkText.fields(line), f.count >= 4, let action = Action(rawValue: f[0]), !f[1].isEmpty,
                  let reason = Reason(rawValue: f[3]) else { return nil }
            return LoginItemOffer(action: action, name: f[1], path: f[2], reason: reason)
        }
    }
}

/// A row of the login items pane.
struct LoginItemRow: Hashable, Sendable, Identifiable {
    enum State: Hashable, Sendable {
        /// Tracked, and a login item on this Mac.
        case tracked
        /// Tracked, and not a login item: --remove takes it.
        case stale
        /// Tracked, and on the ignore list: --remove takes it.
        case ignoredButTracked
        /// A login item the file does not track: --add or --ignore takes it.
        case untracked
    }

    let name: String
    let path: String
    let state: State
    var id: String { name }

    /// The apps config/login-items.txt tracks, in its order, each with what
    /// --check says of it, then the login items it offers to add. A tracked
    /// app --check names nowhere is a login item, as the file says.
    static func rows(tracked: [String], offers: [LoginItemOffer]) -> [LoginItemRow] {
        var removes: [String: LoginItemOffer] = [:]
        for offer in offers where offer.action == .remove { removes[offer.path] = offer }
        // A decision takes the name as --check gives it, which sync-login-items
        // has normalised; a row --check does not name shows the file's.
        var rows = tracked.map { path -> LoginItemRow in
            guard let offer = removes[path] else {
                return LoginItemRow(name: Self.name(of: path), path: path, state: .tracked)
            }
            return LoginItemRow(name: offer.name, path: path,
                                state: offer.reason == .ignored ? .ignoredButTracked : .stale)
        }
        for offer in offers where offer.action == .add {
            rows.append(LoginItemRow(name: offer.name, path: offer.path, state: .untracked))
        }
        return rows
    }

    /// The tracked paths: every entry of config/login-items.txt.
    static func tracked(in text: String) -> [String] {
        MrkText.lines(text).filter(MrkText.isEntry).map(String.init)
    }

    static func name(of path: String) -> String {
        var name = (path as NSString).lastPathComponent
        if name.hasSuffix(".app") { name.removeLast(4) }
        return name
    }
}
