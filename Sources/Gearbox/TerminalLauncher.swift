import AppKit

/// Runs a command in a terminal window: `cd <checkout> && <command>`, with the
/// terminal attached. Copied from Dipstick.
///
/// What Gearbox runs this way changes the Mac or the repository, and asks
/// questions or shows what it does: snapshot-prefs stops to ask when its secret
/// scan finds a match, and make defaults and make dock restart parts of the
/// system. So none of it runs hidden inside the app. Gearbox writes the command
/// into a `.command` file and opens it, which starts it in whichever terminal
/// opens `.command` files — Terminal unless another app has claimed them. That
/// needs no Automation permission, as scripting Terminal would.
enum TerminalLauncher {
    /// `s` in single quotes, for zsh.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// The `.command` file's text. It deletes itself first, since it is used
    /// once; the shell already has it open. `rc`, because `status` is read-only
    /// in zsh.
    ///
    /// `exports` carries what the terminal's own shell would not set for a
    /// script: PATH and MRK_ROOT come from .zshrc, which a script never reads.
    static func script(command: String, directory: String, exports: [String: String] = [:]) -> String {
        var lines = [
            "#!/bin/zsh",
            "# Written by Gearbox to run one command in a terminal. It deletes itself.",
            "rm -f -- \"$0\"",
        ]
        for name in exports.keys.sorted() {
            lines.append("export \(name)=\(shellQuote(exports[name]!))")
        }
        lines += [
            "cd -- \(shellQuote(directory)) || exit 1",
            "print -r -- \(shellQuote("$ " + command))",
            command,
            "rc=$?",
            "print",
            "print -r -- \"Gearbox: exited $rc. Refresh Gearbox to see the result.\"",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    static func run(command: String, directory: String, exports: [String: String] = [:]) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Gearbox", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent("run-\(UUID().uuidString).command")
        try script(command: command, directory: directory, exports: exports)
            .write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        guard NSWorkspace.shared.open(file) else {
            try? FileManager.default.removeItem(at: file)
            throw CocoaError(.fileReadUnknown, userInfo: [
                NSLocalizedDescriptionKey: "No app opened \(file.lastPathComponent).",
            ])
        }
    }
}
