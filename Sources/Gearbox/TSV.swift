import Foundation

/// The rules mrk's lists share, as BIN-1 documents them.
///
/// The five --check modes (defaults.sh, dock-setup, sync, sync-login-items
/// and snapshot-prefs) print their lines by one contract, mrk's
/// mrk_check_line: one tab between two fields, and each field escaped. A
/// later mrk may add fields at the end of a line, and new words to a field
/// that has a fixed set of them; it never removes or reorders a field. So a
/// reader takes a line with at least the fields it knows, and passes over a
/// line whose word it does not know.
enum MrkText {
    /// A field of config/defaults.tsv, docs/defaults/descriptions.tsv or a
    /// line of any of the five --check modes, with its escapes undone: \t is
    /// a tab, \n a newline and \\ a backslash. nil for a backslash before
    /// anything else, which mrk never writes.
    static func unescape(_ field: Substring) -> String? {
        guard field.contains("\\") else { return String(field) }
        var out = ""
        var it = field.makeIterator()
        while let c = it.next() {
            guard c == "\\" else { out.append(c); continue }
            switch it.next() {
            case "t": out.append("\t")
            case "n": out.append("\n")
            case "\\": out.append("\\")
            default: return nil
            }
        }
        return out
    }

    /// The fields of one line, split at every tab, each with its escapes
    /// undone. Two tabs in a row are an empty field. nil when a field has a
    /// bad escape.
    static func fields(_ line: Substring) -> [String]? {
        var fields: [String] = []
        for field in line.split(separator: "\t", omittingEmptySubsequences: false) {
            guard let text = unescape(field) else { return nil }
            fields.append(text)
        }
        return fields
    }

    /// Whether a line of a list in config/ is an entry, by mrk_config_entries'
    /// rule: every line but one that starts with # and one that is empty or
    /// only white space. The line is taken as it stands, with nothing trimmed.
    static func isEntry(_ line: Substring) -> Bool {
        !line.hasPrefix("#") && !line.allSatisfy(\.isWhitespace)
    }

    /// The lines of a file's text, without the newline that ends the last.
    /// It splits at every newline scalar: as Characters, a carriage return
    /// and the newline after it are one, and mrk does not escape a carriage
    /// return, so a field that ends in one would join two lines.
    static func lines(_ text: String) -> [Substring] {
        var lines = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map(Substring.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// Whether a check printed anything: a line with text in it. A check
    /// that did, and of which Gearbox read no line, printed what this
    /// Gearbox does not know.
    static func hasLines(_ text: String) -> Bool {
        lines(text).contains { !$0.isEmpty }
    }
}
