import Foundation

/// The two rules mrk's lists share, as BIN-1 documents them.
enum MrkText {
    /// A field of config/defaults.tsv, docs/defaults/descriptions.tsv or a
    /// --check line of defaults.sh or dock-setup, with its escapes undone: \t
    /// is a tab, \n a newline and \\ a backslash. nil for a backslash before
    /// anything else, which mrk refuses.
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
    static func lines(_ text: String) -> [Substring] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}
