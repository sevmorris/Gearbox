import Foundation

// Gearbox is a window over mrk's own scripts. It reads the lists in config/
// and asks the scripts' check modes what they find, and every decision goes
// back through a script's own flag: sync-login-items --add, --remove and
// --ignore, and defaults.sh --skip, --unskip, --key and --revert. The one
// file it writes itself is config/dock.txt, the plain list
// dock-setup reads, as Barkeep writes tools/picker/descriptions.tsv. What
// changes the Mac (make defaults, make dock) or commits and pushes (make
// snapshot-prefs) runs in Gearbox's console, on a terminal of its own, with
// its own prompts and output in view. Gearbox never commits: mrk-push and
// pushall do that, with their secret scan and gates, and Dipstick's
// Unrecorded panel shows what is waiting.

/// An mrk checkout: ~/mrk, or the one MRK_ROOT names, as mrk-status and
/// Dipstick read it.
struct MrkCheckout: Equatable, Sendable {
    let root: URL

    static func resolve(environment: [String: String], home: String) -> MrkCheckout {
        if let root = environment["MRK_ROOT"], !root.isEmpty {
            return MrkCheckout(root: URL(fileURLWithPath: root, isDirectory: true))
        }
        return MrkCheckout(root: URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("mrk", isDirectory: true))
    }

    func file(_ path: String) -> URL { root.appendingPathComponent(path) }

    var defaultsTable: URL        { file("config/defaults.tsv") }
    var defaultsDescriptions: URL { file("docs/defaults/descriptions.tsv") }
    var defaultsSkip: URL         { file("config/defaults-skip.tsv") }
    var appPrefs: URL             { file("config/app-prefs.tsv") }
    var loginItems: URL           { file("config/login-items.txt") }
    var dockList: URL             { file("config/dock.txt") }

    /// The scripts Gearbox runs. A checkout without them is too old for
    /// Gearbox, or no checkout at all.
    static let scripts = ["scripts/snapshot-prefs", "scripts/defaults.sh",
                          "scripts/sync-login-items", "scripts/dock-setup"]

    /// The first script Gearbox runs and cannot find, or nil. A file a pane
    /// reads is that pane's concern: an mrk older than Gearbox lacks some, and
    /// the other panes still work.
    func missing(fileManager: FileManager = .default) -> String? {
        Self.scripts.first { !fileManager.isExecutableFile(atPath: file($0).path) }
    }
}

/// One run of one of mrk's scripts, in the checkout, that changes nothing but
/// what its flag asks for. Each is a check mode or a decision documented in
/// BIN-1 (docs/bin/mrk-usage.html).
enum MrkCommand: Equatable, Sendable {
    /// The commit a snapshot would make: FILE, KEY, added|deleted|changed.
    case prefsCheck
    /// Each key of config/defaults.tsv against this Mac.
    case defaultsCheck(withTrackpad: Bool)
    /// Turn keys off: list them in config/defaults-skip.tsv, so make defaults
    /// passes them over, and put back the value each had before mrk wrote it.
    case defaultsOff([DefaultsKey])
    /// Turn keys on: take them out of config/defaults-skip.tsv, and write
    /// mrk's value.
    case defaultsOn([DefaultsKey])
    /// Write mrk's value of keys that are on.
    case defaultsApply([DefaultsKey])
    /// The login items an interactive run would offer.
    case loginItemsCheck
    /// Track a login item in config/login-items.txt and the manual.
    case loginItemsAdd(String)
    /// Add a login item to ~/.mrk/login-items-ignore.
    case loginItemsIgnore(String)
    /// Stop tracking an app in config/login-items.txt and the manual.
    case loginItemsRemove(String)
    /// Each item of config/dock.txt: app or folder, line, path, state, and
    /// whether it is docked; then each unlisted item the Dock has.
    case dockCheck

    var script: String {
        switch self {
        case .prefsCheck: return "scripts/snapshot-prefs"
        case .defaultsCheck, .defaultsOff, .defaultsOn, .defaultsApply: return "scripts/defaults.sh"
        case .loginItemsCheck, .loginItemsAdd, .loginItemsIgnore, .loginItemsRemove:
            return "scripts/sync-login-items"
        case .dockCheck: return "scripts/dock-setup"
        }
    }

    var arguments: [String] {
        switch self {
        case .prefsCheck: return ["--check"]
        case .defaultsCheck(let trackpad): return trackpad ? ["--check", "--with-trackpad"] : ["--check"]
        case .defaultsOff(let keys): return keys.flatMap { ["--skip", $0.domain, $0.key, "--revert", $0.domain, $0.key] }
        case .defaultsOn(let keys): return keys.flatMap { ["--unskip", $0.domain, $0.key, "--key", $0.domain, $0.key] }
        case .defaultsApply(let keys): return keys.flatMap { ["--key", $0.domain, $0.key] }
        case .loginItemsCheck: return ["--check"]
        case .loginItemsAdd(let name): return ["--add", name]
        case .loginItemsIgnore(let name): return ["--ignore", name]
        case .loginItemsRemove(let name): return ["--remove", name]
        case .dockCheck: return ["--check"]
        }
    }

    /// The command as Gearbox shows it.
    var displayLine: String {
        "$ " + ([script] + arguments.map { $0.contains(" ") ? "\"\($0)\"" : $0 }).joined(separator: " ")
    }

    /// snapshot-prefs --check exports every app into a scratch clone, about
    /// 4 s on this Mac; the others answer in under a second.
    var timeout: Duration { self == .prefsCheck ? .seconds(180) : .seconds(60) }
}

/// What Gearbox runs in its console, on a terminal: the commands that change
/// the Mac, or that commit and push, so their prompts and their output stay
/// in view.
///
/// Gearbox 0.2 and earlier ran these in Terminal, through a self-deleting
/// .command file. The console runs them as that file did, `make <target>`
/// under zsh in the checkout, with the login shell's environment.
enum TerminalCommand: Equatable, Sendable {
    case snapshotPrefs
    case applyDefaults(withTrackpad: Bool)
    case applyDock
    /// make dock's dry run, which reads config/dock.txt and changes nothing:
    /// what `--snapshot` shows in the console.
    case dockDryRun

    var command: String {
        switch self {
        case .snapshotPrefs: return "make snapshot-prefs"
        case .applyDefaults(let trackpad): return trackpad ? "make trackpad" : "make defaults"
        case .applyDock: return "make dock"
        case .dockDryRun: return "make dock ARGS=-n"
        }
    }

    /// The pane that reads mrk again when the command has exited.
    var pane: Pane {
        switch self {
        case .snapshotPrefs: return .preferences
        case .applyDefaults: return .defaults
        case .applyDock, .dockDryRun: return .dock
        }
    }
}

enum MrkError: LocalizedError, Equatable {
    case failed(command: String, status: Int32, message: String)
    case timedOut(command: String)
    case notStarted(command: String, message: String)

    var errorDescription: String? {
        switch self {
        case .failed(let command, let status, let message):
            return message.isEmpty ? "\(command) exited with status \(status)." : message
        case .timedOut(let command):
            return "\(command) did not finish, and Gearbox stopped it."
        case .notStarted(let command, let message):
            return "\(command) could not start: \(message)"
        }
    }

    var status: Int32? {
        if case .failed(_, let status, _) = self { return status }
        return nil
    }
}

/// Runs mrk's scripts with the environment of an interactive login zsh, asked
/// for once and kept, in the checkout.
actor MrkRunner {
    typealias EnvironmentProvider = @Sendable () async -> [String: String]

    /// What a terminal window on this Mac has, or Gearbox's own environment
    /// with the usual PATH when the shell cannot be asked.
    static let loginShellEnvironment: EnvironmentProvider = {
        await ShellEnvironment.capture()
            ?? ShellEnvironment.fallback(base: ProcessInfo.processInfo.environment, home: NSHomeDirectory())
    }

    private let environmentProvider: EnvironmentProvider
    private var environment: [String: String]?

    init(environment: @escaping EnvironmentProvider = MrkRunner.loginShellEnvironment) {
        self.environmentProvider = environment
    }

    func resolvedEnvironment() async -> [String: String] {
        if let environment { return environment }
        let env = await environmentProvider()
        environment = env
        return env
    }

    /// Runs the command in the checkout and returns its stdout. Throws when
    /// it exits non-zero, with the last line it wrote to stderr — where mrk's
    /// scripts say why they refused.
    func run(_ command: MrkCommand, in checkout: MrkCheckout) async throws -> ProcessResult {
        let env = await resolvedEnvironment()
        let result: ProcessResult
        do {
            result = try await Subprocess.run(
                checkout.file(command.script),
                arguments: command.arguments,
                environment: env,
                currentDirectory: checkout.root,
                timeout: command.timeout)
        } catch {
            throw MrkError.notStarted(command: command.script, message: error.localizedDescription)
        }
        if result.timedOut { throw MrkError.timedOut(command: command.displayLine) }
        guard result.status == 0 else {
            // Each script exits 2 for an option it does not know, and Gearbox
            // passes only documented ones, so 2 means an mrk from before them.
            let message = result.status == 2
                ? "\(command.script) does not take \(command.arguments.joined(separator: " ")): this mrk is older than Gearbox. Run make pull in \(checkout.root.path)."
                : Self.lastLine(of: result.stderrText)
            throw MrkError.failed(command: command.displayLine, status: result.status, message: message)
        }
        return result
    }

    /// The last line with text in it, with mrk's ✗/⚠ marks and colour codes
    /// taken off.
    static func lastLine(of text: String) -> String {
        let plain = text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        let line = plain.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        for mark in ["✗ ", "⚠ ", "✓ ", "▸ ", "· "] where trimmed.hasPrefix(mark) {
            trimmed.removeFirst(mark.count)
        }
        return trimmed
    }
}
