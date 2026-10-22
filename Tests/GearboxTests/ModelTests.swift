import XCTest
@testable import Gearbox

@MainActor
final class ModelTests: XCTestCase {
    func testPrefsGroupsTheCheckByTheTable() async throws {
        let stub = try StubMrk()
        try stub.write("config/app-prefs.tsv", "com.aone.keka\tKeka.plist\t/Applications/Keka.app\tKeka\n")
        try stub.answer("snapshot-prefs", ["--check"],
                        out: "Keka.plist\tBookmarks\tchanged\nKeka.plist\tVersion\tchanged\n",
                        err: "  ✓ Dry run: nothing was committed or pushed.\n")
        let model = PrefsModel(checkout: stub.checkout, runner: stub.runner())
        await model.load()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.groups.map(\.name), ["Keka"])
        XCTAssertEqual(model.changeCount, 2)
        XCTAssertTrue(model.log.contains("Dry run"))
    }

    func testDefaultsAsksWithTheTrackpadWhenAsked() async throws {
        let stub = try StubMrk()
        try stub.write("config/defaults.tsv", "NSGlobalDomain\tAppleShowAllExtensions\tbool\ttrue\talways\tFinder\n")
        try stub.write("docs/defaults/descriptions.tsv",
                       "NSGlobalDomain\tAppleShowAllExtensions\tShow All File Extensions\tSecurity\t\tfalse\tShows them.\t\t\n")
        try stub.answer("defaults.sh", ["--check"], out: "NSGlobalDomain\tAppleShowAllExtensions\ttrue\tfalse\tdiffers\n")
        let model = DefaultsModel(checkout: stub.checkout, runner: stub.runner(), store: stub.store())
        await model.load()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertFalse(model.descriptionsMissing)
        XCTAssertEqual(model.selected?.title, "Show All File Extensions")
        XCTAssertEqual(model.counts.differs, 1)

        model.withTrackpad = true
        await model.load()
        XCTAssertEqual(stub.calls.map { $0.components(separatedBy: " cwd=")[0] },
                       ["scripts/defaults.sh [--check]", "scripts/defaults.sh [--check] [--with-trackpad]"])
    }

    func testDefaultsFilterAndSearch() async throws {
        let stub = try StubMrk()
        try stub.write("config/defaults.tsv", """
        NSGlobalDomain\tA\tbool\ttrue\talways\tOne
        NSGlobalDomain\tB\tbool\ttrue\talways\tOne
        com.apple.dock\tC\tbool\ttrue\talways\tTwo

        """)
        try stub.answer("defaults.sh", ["--check"], out: """
        NSGlobalDomain\tA\ttrue\ttrue\tset
        NSGlobalDomain\tB\ttrue\t\tabsent
        com.apple.dock\tC\ttrue\ttrue\tset

        """)
        let model = DefaultsModel(checkout: stub.checkout, runner: stub.runner(), store: stub.store())
        await model.load()
        XCTAssertTrue(model.descriptionsMissing == false)
        XCTAssertEqual(model.shown.flatMap(\.entries).count, 3)
        model.filter = .unset
        XCTAssertEqual(model.shown.map(\.name), ["One"])
        XCTAssertEqual(model.shown.first?.entries.map(\.check.key), ["B"])
        model.filter = .all
        model.search = "dock"
        XCTAssertEqual(model.shown.map(\.name), ["Two"])
    }

    func testAnMrkWithoutDescriptionsStillShowsTheKeys() async throws {
        let stub = try StubMrk()
        try FileManager.default.removeItem(at: stub.checkout.defaultsDescriptions)
        try stub.write("config/defaults.tsv", "NSGlobalDomain\tA\tbool\ttrue\talways\tOne\n")
        try stub.answer("defaults.sh", ["--check"], out: "NSGlobalDomain\tA\ttrue\ttrue\tset\n")
        let model = DefaultsModel(checkout: stub.checkout, runner: stub.runner(), store: stub.store())
        await model.load()
        XCTAssertTrue(model.descriptionsMissing)
        XCTAssertEqual(model.entries.map(\.title), ["A"])
    }

    func testDefaultsKeepsItsSettingsInItsStore() throws {
        let stub = try StubMrk()
        let store = stub.store()
        let model = DefaultsModel(checkout: stub.checkout, runner: stub.runner(), store: store)
        model.withTrackpad = true
        model.filter = .unset
        let again = DefaultsModel(checkout: stub.checkout, runner: stub.runner(), store: store)
        XCTAssertTrue(again.withTrackpad)
        XCTAssertEqual(again.filter, .unset)
    }

    /// sync-login-items --check exits 1 with no line when System Events
    /// fails: the pane says so, and names Automation, and lists nothing.
    func testLoginItemsShowTheRefusal() async throws {
        let stub = try StubMrk()
        try stub.write("config/login-items.txt", "/Applications/AlDente.app\n")
        try stub.answer("sync-login-items", ["--check"],
                        err: "  ✗ System Events returned no login items. Check Automation access.\n", status: 1)
        let model = LoginItemsModel(checkout: stub.checkout, runner: stub.runner())
        await model.load()
        guard case .failed(let message) = model.phase else { return XCTFail("expected the refusal, got \(model.phase)") }
        XCTAssertTrue(message.contains("System Events returned no login items"), message)
        XCTAssertTrue(message.contains("Privacy & Security → Automation"), message)
        XCTAssertEqual(model.rows, [])
    }

    func testALoginItemDecisionRunsItsFlagThenChecksAgain() async throws {
        let stub = try StubMrk()
        try stub.write("config/login-items.txt", "/Applications/AlDente.app\n")
        try stub.answer("sync-login-items", ["--check"], out: "add\tChrono Plus\t/Applications/Chrono Plus.app\tnew\n")
        let model = LoginItemsModel(checkout: stub.checkout, runner: stub.runner())
        await model.load()
        XCTAssertEqual(model.rows.map(\.state), [.tracked, .untracked])

        await model.decide(.add, model.rows[1])
        await model.decide(.ignore, model.rows[1])
        await model.decide(.remove, model.rows[0])
        XCTAssertEqual(stub.calls.map { $0.components(separatedBy: " cwd=")[0] }, [
            "scripts/sync-login-items [--check]",
            "scripts/sync-login-items [--add] [Chrono Plus]",
            "scripts/sync-login-items [--check]",
            "scripts/sync-login-items [--ignore] [Chrono Plus]",
            "scripts/sync-login-items [--check]",
            "scripts/sync-login-items [--remove] [AlDente]",
            "scripts/sync-login-items [--check]",
        ])
        XCTAssertNil(model.decisionError)
    }

    func testARefusedDecisionIsShown() async throws {
        let stub = try StubMrk()
        try stub.answer("sync-login-items", ["--add", "X"], err: "✗ X is not a login item\n", status: 1)
        let model = LoginItemsModel(checkout: stub.checkout, runner: stub.runner())
        await model.decide(.add, LoginItemRow(name: "X", path: "/X.app", state: .untracked))
        XCTAssertEqual(model.decisionError, "X is not a login item")
    }

    func testTheDockWritesTheFileThenChecksIt() async throws {
        let stub = try StubMrk()
        try stub.write("config/dock.txt", "# header\n/Applications/A.app\n/Applications/B.app\n~/Work Apps\n")
        try stub.answer("dock-setup", ["--check"], out: """
        app\t/Applications/A.app\t/Applications/A.app\tpresent
        app\t/Applications/B.app\t/Applications/B.app\tmissing
        folder\t~/Work Apps\t/Users/x/Work Apps\tpresent

        """)
        let model = DockModel(checkout: stub.checkout, runner: stub.runner(), home: "/Users/x")
        await model.load()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.checks["/Applications/B.app"]?.state, .missing)

        await model.moveApps(fromOffsets: [1], toOffset: 0)
        XCTAssertEqual(try stub.read("config/dock.txt"),
                       "# header\n/Applications/B.app\n/Applications/A.app\n~/Work Apps\n")
        await model.add(URL(fileURLWithPath: "/Users/x/Downloads"))
        await model.remove("/Applications/A.app")
        XCTAssertEqual(try stub.read("config/dock.txt"), "# header\n/Applications/B.app\n~/Work Apps\n~/Downloads\n")
        XCTAssertEqual(stub.calls.count, 4, "one check after the load and after each edit")
        XCTAssertNil(model.editError)
    }

    func testTheDockDoesNotWriteOverAChangeItHasNotShown() async throws {
        let stub = try StubMrk()
        try stub.write("config/dock.txt", "/Applications/A.app\n/Applications/B.app\n")
        let model = DockModel(checkout: stub.checkout, runner: stub.runner(), home: "/Users/x")
        await model.load()
        try stub.write("config/dock.txt", "/Applications/A.app\n/Applications/B.app\n/Applications/C.app\n")
        await model.remove("/Applications/A.app")
        XCTAssertEqual(try stub.read("config/dock.txt"), "/Applications/A.app\n/Applications/B.app\n/Applications/C.app\n")
        XCTAssertNotNil(model.editError)
        XCTAssertEqual(model.list.items.count, 3, "it read the file again")
    }

    func testARefusedDockListIsShown() async throws {
        let stub = try StubMrk()
        try stub.write("config/dock.txt", "Applications/A.app\n")
        try stub.answer("dock-setup", ["--check"], err: "✗ Not a path, in config/dock.txt: Applications/A.app — the Dock is unchanged.\n", status: 1)
        let model = DockModel(checkout: stub.checkout, runner: stub.runner(), home: "/Users/x")
        await model.load()
        guard case .failed(let message) = model.phase else { return XCTFail("expected a failure") }
        XCTAssertTrue(message.contains("Not a path"), message)
    }

    func testAnMrkWithoutDockCheckSaysToPull() async throws {
        let stub = try StubMrk()
        try stub.write("config/dock.txt", "/Applications/A.app\n")
        try stub.answer("dock-setup", ["--check"], err: "unknown argument: --check\n", status: 2)
        let model = DockModel(checkout: stub.checkout, runner: stub.runner(), home: "/Users/x")
        await model.load()
        guard case .failed(let message) = model.phase else { return XCTFail("expected a failure") }
        XCTAssertFalse(message.contains("refuses config/dock.txt"), message)
        XCTAssertTrue(message.contains("older than Gearbox"), message)
    }

    func testTheAppRemembersThePaneInItsStore() throws {
        let stub = try StubMrk()
        let store = stub.store()
        let app = AppModel(checkout: stub.checkout, runner: stub.runner(), store: store, home: "/Users/x")
        XCTAssertEqual(app.selection, .preferences)
        app.selection = .dock
        XCTAssertEqual(AppModel(checkout: stub.checkout, runner: stub.runner(), store: store, home: "/Users/x").selection, .dock)
        XCTAssertNil(app.checkoutProblem)
    }
}

final class IsolationTests: XCTestCase {
    /// Under tests the app's store is a scratch suite named by a path in the
    /// temporary folder, never the real domain.
    func testTheAppStoreIsNotTheRealDomain() {
        XCTAssertTrue(AppLauncher.isHostingTests)
        XCTAssertFalse(UserDefaults.app === UserDefaults.standard)
        UserDefaults.app.set("x", forKey: "gearboxIsolationProbe")
        XCTAssertNil(UserDefaults.standard.string(forKey: "gearboxIsolationProbe"))
        UserDefaults.app.removeObject(forKey: "gearboxIsolationProbe")
    }
}
