import Foundation
import Observation

/// Where a pane's last load stands.
enum LoadPhase: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)

    /// A check printed lines and Gearbox read none of them. By mrk's --check
    /// line contract a later mrk only adds fields and words, so that is an
    /// mrk newer than this Gearbox, not a list with nothing in it.
    static func unreadable(_ command: MrkCommand) -> LoadPhase {
        .failed("Could not read \(command.script) \(command.arguments.joined(separator: " ")): "
                + "this Gearbox is older than mrk's output. Choose Gearbox → Check for Updates….")
    }
}

enum Pane: String, CaseIterable, Identifiable, Sendable {
    case preferences, defaults, loginItems, dock
    var id: String { rawValue }

    var title: String {
        switch self {
        case .preferences: return "App Preferences"
        case .defaults: return "macOS Defaults"
        case .loginItems: return "Login Items"
        case .dock: return "Dock"
        }
    }

    var symbol: String {
        switch self {
        case .preferences: return "slider.horizontal.3"
        case .defaults: return "gearshape.2"
        case .loginItems: return "power"
        case .dock: return "dock.rectangle"
        }
    }
}

/// The whole app: the checkout, the runner, and one model for each pane.
@Observable @MainActor
final class AppModel {
    let checkout: MrkCheckout
    let runner: MrkRunner
    let store: UserDefaults
    let prefs: PrefsModel
    let defaults: DefaultsModel
    let loginItems: LoginItemsModel
    let dock: DockModel

    var selection: Pane? {
        didSet { store.set(selection?.rawValue, forKey: "selectedPane") }
    }
    /// Set when a terminal command could not start.
    var terminalError: String?
    /// A newer Gearbox, found by the last check that reached GitHub. The
    /// sidebar names it.
    private(set) var availableUpdate: AvailableUpdate?
    /// Asks GitHub for the latest release. The tests pass their own.
    private let latestRelease: @Sendable () async -> UpdateChecker.Result
    private var isCheckingForUpdates = false

    init(checkout: MrkCheckout, runner: MrkRunner, store: UserDefaults = .app,
         home: String = NSHomeDirectory(),
         latestRelease: @escaping @Sendable () async -> UpdateChecker.Result = { await UpdateChecker.shared.check() }) {
        self.checkout = checkout
        self.runner = runner
        self.store = store
        self.latestRelease = latestRelease
        prefs = PrefsModel(checkout: checkout, runner: runner)
        defaults = DefaultsModel(checkout: checkout, runner: runner, store: store)
        loginItems = LoginItemsModel(checkout: checkout, runner: runner)
        dock = DockModel(checkout: checkout, runner: runner, home: home)
        selection = store.string(forKey: "selectedPane").flatMap(Pane.init(rawValue:)) ?? .preferences
    }

    /// The real app: ~/mrk, or MRK_ROOT, with the login shell's environment.
    static func live() -> AppModel {
        let env = ProcessInfo.processInfo.environment
        return AppModel(checkout: .resolve(environment: env, home: NSHomeDirectory()), runner: MrkRunner())
    }

    var checkoutProblem: String? {
        checkout.missing().map {
            "Gearbox needs mrk at \(checkout.root.path), with \($0). Set MRK_ROOT for a checkout elsewhere, or run make pull there."
        }
    }

    func load(_ pane: Pane) async {
        switch pane {
        case .preferences: await prefs.load()
        case .defaults: await defaults.load()
        case .loginItems: await loginItems.load()
        case .dock: await dock.load()
        }
    }

    var updateSchedule: UpdateSchedule { UpdateSchedule(store: store) }

    /// Asks GitHub for a newer Gearbox, and returns what to tell you, or nil
    /// for nothing. Check for Updates… always asks and always answers. The
    /// quiet check, at launch and each time Gearbox comes to the front, asks
    /// at most once an hour, and answers only with an update you have not
    /// said Not Now to. Up to date, a release this Mac cannot run, and a
    /// failure, it keeps to itself.
    func checkForUpdates(quietly: Bool, now: Date = Date()) async -> UpdateChecker.Result? {
        let schedule = updateSchedule
        // Launching makes Gearbox active as well, so two quiet checks can
        // start together; the second stops here rather than ask GitHub twice.
        if quietly && (isCheckingForUpdates || !schedule.isDue(at: now)) { return nil }
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }

        let result = await latestRelease()
        schedule.record(result, at: now)
        switch result {
        case .available(let update):
            availableUpdate = update
        case .upToDate, .needsNewerMacOS:
            availableUpdate = nil
        case .error:
            // A failed check says nothing about what was found before.
            break
        }
        guard quietly else { return result }
        if case .available(let update) = result, !schedule.isDismissed(update.version) {
            return result
        }
        return nil
    }

    /// Runs a command in a terminal, in the checkout, with the login shell's
    /// PATH, as the terminal's own shell would have it.
    func runInTerminal(_ command: TerminalCommand) async {
        let env = await runner.resolvedEnvironment()
        var exports = ["MRK_ROOT": checkout.root.path]
        if let path = env["PATH"], !path.isEmpty { exports["PATH"] = path }
        do {
            try TerminalLauncher.run(command: command.command, directory: checkout.root.path, exports: exports)
            terminalError = nil
        } catch {
            terminalError = "Could not open a terminal for \(command.command): \(error.localizedDescription)"
        }
    }
}

// MARK: - App preferences

@Observable @MainActor
final class PrefsModel {
    let checkout: MrkCheckout
    let runner: MrkRunner
    var phase: LoadPhase = .idle
    var groups: [PrefGroup] = []
    /// What snapshot-prefs --check wrote to stderr: its progress, what it
    /// left out, and an unpushed commit when there is one.
    var log = ""

    init(checkout: MrkCheckout, runner: MrkRunner) {
        self.checkout = checkout
        self.runner = runner
    }

    var changeCount: Int { groups.reduce(0) { $0 + $1.changes.count } }

    func load() async {
        phase = .loading
        do {
            let result = try await runner.run(.prefsCheck, in: checkout)
            let table = AppPrefsTable.parse((try? String(contentsOf: checkout.appPrefs, encoding: .utf8)) ?? "")
            let changes = PrefChange.parse(result.stdoutText)
            groups = PrefGroup.group(changes, table: table)
            log = result.stderrText
            phase = changes.isEmpty && MrkText.hasLines(result.stdoutText) ? .unreadable(.prefsCheck) : .loaded
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

// MARK: - macOS defaults

@Observable @MainActor
final class DefaultsModel {
    enum Filter: String, CaseIterable, Identifiable, Sendable {
        case all, unset
        var id: String { rawValue }
        var title: String { self == .all ? "All keys" : "Not set" }
    }

    let checkout: MrkCheckout
    let runner: MrkRunner
    let store: UserDefaults
    var phase: LoadPhase = .idle
    var sections: [DefaultsSection] = []
    var selectedID: String?
    /// The checkout has no docs/defaults/descriptions.tsv: an mrk from before it.
    var descriptionsMissing = false

    var withTrackpad: Bool {
        didSet { store.set(withTrackpad, forKey: "defaultsWithTrackpad") }
    }
    var filter: Filter {
        didSet { store.set(filter.rawValue, forKey: "defaultsFilter") }
    }
    var search = ""

    init(checkout: MrkCheckout, runner: MrkRunner, store: UserDefaults) {
        self.checkout = checkout
        self.runner = runner
        self.store = store
        withTrackpad = store.bool(forKey: "defaultsWithTrackpad")
        filter = store.string(forKey: "defaultsFilter").flatMap(Filter.init(rawValue:)) ?? .all
    }

    var entries: [DefaultsEntry] { sections.flatMap(\.entries) }

    var selected: DefaultsEntry? {
        guard let selectedID else { return nil }
        return entries.first { $0.id == selectedID }
    }

    var counts: DefaultsCounts {
        sections.reduce(DefaultsCounts()) { $0 + $1.counts }
    }

    /// The sections, with the filter and the search applied.
    var shown: [DefaultsSection] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return sections.compactMap { section in
            let entries = section.entries.filter { e in
                (filter == .all || e.check.state != .set)
                    && (needle.isEmpty || [e.title, e.check.domain, e.check.key, e.description?.category ?? ""]
                        .contains { $0.lowercased().contains(needle) })
            }
            return entries.isEmpty ? nil : DefaultsSection(name: section.name, entries: entries)
        }
    }

    func load() async {
        phase = .loading
        do {
            let command = MrkCommand.defaultsCheck(withTrackpad: withTrackpad)
            let result = try await runner.run(command, in: checkout)
            let rows = DefaultsRow.parse((try? String(contentsOf: checkout.defaultsTable, encoding: .utf8)) ?? "")
            let descriptionsText = try? String(contentsOf: checkout.defaultsDescriptions, encoding: .utf8)
            descriptionsMissing = descriptionsText == nil
            let descriptions = DefaultDescription.parse(descriptionsText ?? "")
            let checks = DefaultCheck.parse(result.stdoutText)
            let joined = DefaultsEntry.join(checks: checks, rows: rows, descriptions: descriptions)
            sections = DefaultsSection.group(joined)
            if checks.isEmpty && MrkText.hasLines(result.stdoutText) {
                phase = .unreadable(command)
                return
            }
            if selected == nil {
                selectedID = (joined.first { $0.check.state.isDrift } ?? joined.first { $0.check.state != .set }
                              ?? joined.first)?.id
            }
            phase = .loaded
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Login items

@Observable @MainActor
final class LoginItemsModel {
    enum Decision: Sendable { case add, ignore, remove }

    let checkout: MrkCheckout
    let runner: MrkRunner
    var phase: LoadPhase = .idle
    var rows: [LoginItemRow] = []
    /// The name a decision is running for.
    var busy: String?
    var decisionError: String?

    init(checkout: MrkCheckout, runner: MrkRunner) {
        self.checkout = checkout
        self.runner = runner
    }

    /// sync-login-items --check exits 1 with no line when System Events
    /// fails or returns no login items. It refuses rather than show every
    /// tracked app as stale, and Gearbox says why, since the usual cause is
    /// Automation access that Gearbox does not have.
    static func refusalMessage(_ detail: String) -> String {
        var text = "sync-login-items could not read the login items from System Events, so it compared nothing."
        if !detail.isEmpty { text += " It said: \(detail)" }
        text += " Allow Gearbox to control System Events in System Settings → Privacy & Security → Automation,"
            + " then refresh. If this Mac really has no login items, edit config/login-items.txt by hand."
        return text
    }

    func load() async {
        phase = .loading
        do {
            let result = try await runner.run(.loginItemsCheck, in: checkout)
            let tracked = LoginItemRow.tracked(
                in: (try? String(contentsOf: checkout.loginItems, encoding: .utf8)) ?? "")
            let offers = LoginItemOffer.parse(result.stdoutText)
            rows = LoginItemRow.rows(tracked: tracked, offers: offers)
            phase = offers.isEmpty && MrkText.hasLines(result.stdoutText) ? .unreadable(.loginItemsCheck) : .loaded
        } catch let error as MrkError where error.status == 1 {
            rows = []
            if case .failed(_, _, let message) = error {
                phase = .failed(Self.refusalMessage(message))
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func decide(_ decision: Decision, _ row: LoginItemRow) async {
        let command: MrkCommand
        switch decision {
        case .add: command = .loginItemsAdd(row.name)
        case .ignore: command = .loginItemsIgnore(row.name)
        case .remove: command = .loginItemsRemove(row.name)
        }
        busy = row.name
        defer { busy = nil }
        do {
            _ = try await runner.run(command, in: checkout)
            decisionError = nil
        } catch {
            decisionError = error.localizedDescription
        }
        await load()
    }
}

// MARK: - Dock

@Observable @MainActor
final class DockModel {
    let checkout: MrkCheckout
    let runner: MrkRunner
    let home: String
    var phase: LoadPhase = .idle
    var list = DockList(header: [], items: [], trailer: [])
    /// line → what dock-setup --check says of it.
    var checks: [String: DockCheck] = [:]
    /// What the Dock has and the list does not, in the Dock's order: make
    /// dock deletes these.
    var unlisted: [UnlistedDockItem] = []
    var editError: String?
    /// The file as Gearbox last read or wrote it.
    private var loadedText: String?

    init(checkout: MrkCheckout, runner: MrkRunner, home: String) {
        self.checkout = checkout
        self.runner = runner
        self.home = home
    }

    func load() async {
        phase = .loading
        do {
            let text = try String(contentsOf: checkout.dockList, encoding: .utf8)
            list = DockList.parse(text)
            loadedText = text
        } catch {
            phase = .failed("Could not read config/dock.txt: \(error.localizedDescription)")
            return
        }
        await check()
    }

    /// What dock-setup says of each item, and whether it takes the list.
    func check() async {
        do {
            let result = try await runner.run(.dockCheck, in: checkout)
            // Unlisted lines have no line in the file, so they stay out of
            // the dictionary, which is keyed by it.
            let listed = DockCheck.parse(result.stdoutText)
            checks = Dictionary(listed.map { ($0.line, $0) }, uniquingKeysWith: { first, _ in first })
            unlisted = UnlistedDockItem.parse(result.stdoutText)
            phase = listed.isEmpty && unlisted.isEmpty && MrkText.hasLines(result.stdoutText)
                ? .unreadable(.dockCheck) : .loaded
        } catch let error as MrkError where error.status == 1 {
            checks = [:]
            unlisted = []
            phase = .failed("dock-setup refuses config/dock.txt: \(error.localizedDescription)")
        } catch {
            checks = [:]
            unlisted = []
            phase = .failed(error.localizedDescription)
        }
    }

    func moveApps(fromOffsets source: IndexSet, toOffset destination: Int) async {
        await edit { $0.moveApps(fromOffsets: source, toOffset: destination) }
    }

    func add(_ url: URL) async {
        let line = DockList.line(for: url, home: home)
        await edit { try $0.add(line) }
    }

    /// Lists an item the Dock has, so make dock keeps it.
    func add(_ item: UnlistedDockItem) async {
        await add(URL(fileURLWithPath: item.path))
    }

    func remove(_ line: String) async {
        await edit { $0.remove(line) }
    }

    /// Applies one edit and writes the file. When the file changed on disk
    /// since Gearbox read it, Gearbox reads it again and makes no edit, so it
    /// never writes over a change it has not shown.
    private func edit(_ change: (inout DockList) throws -> Void) async {
        let onDisk = try? String(contentsOf: checkout.dockList, encoding: .utf8)
        guard onDisk == loadedText else {
            editError = "config/dock.txt changed on disk. Gearbox read it again; make the change again."
            await load()
            return
        }
        var next = list
        do {
            try change(&next)
            guard next != list else { return }
            try next.write(to: checkout.dockList)
            list = next
            loadedText = next.text
            editError = nil
        } catch {
            editError = error.localizedDescription
            return
        }
        await check()
    }
}
