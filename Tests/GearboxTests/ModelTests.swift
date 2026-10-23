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

    /// The switch turns every domain of a setting, in one run of defaults.sh,
    /// then reads the keys again with the list still up, on the key it
    /// turned. Apply writes the keys of one setting.
    func testTheSwitchTurnsEachDomainOfASettingThenChecksAgain() async throws {
        let stub = try StubMrk()
        try stub.write("config/defaults-skip.tsv", "# the keys to skip\n")
        try stub.write("config/defaults.tsv", """
        NSGlobalDomain\tA\tbool\ttrue\talways\tOne
        com.apple.AppleMultitouchTrackpad\tClicking\tbool\ttrue\ttrackpad\tTrackpad
        com.apple.driver.AppleBluetoothMultitouch.trackpad\tClicking\tbool\ttrue\ttrackpad\tTrackpad

        """)
        try stub.answer("defaults.sh", ["--check"], out: """
        NSGlobalDomain\tA\ttrue\tfalse\tdiffers
        com.apple.AppleMultitouchTrackpad\tClicking\ttrue\ttrue\tset
        com.apple.driver.AppleBluetoothMultitouch.trackpad\tClicking\ttrue\ttrue\tset

        """)
        let model = DefaultsModel(checkout: stub.checkout, runner: stub.runner(), store: stub.store())
        await model.load()
        XCTAssertFalse(model.skipListMissing)
        let a = try XCTUnwrap(model.entries.first)
        let tap = model.entries[2]

        await model.setOn(false, for: tap)
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.selectedID, tap.id)
        await model.setOn(true, for: tap)
        await model.apply(a)
        let trackpad = "com.apple.AppleMultitouchTrackpad", bluetooth = "com.apple.driver.AppleBluetoothMultitouch.trackpad"
        XCTAssertEqual(stub.calls.map { $0.components(separatedBy: " cwd=")[0] }, [
            "scripts/defaults.sh [--check]",
            "scripts/defaults.sh [--skip] [\(trackpad)] [Clicking] [--revert] [\(trackpad)] [Clicking] "
                + "[--skip] [\(bluetooth)] [Clicking] [--revert] [\(bluetooth)] [Clicking]",
            "scripts/defaults.sh [--check]",
            "scripts/defaults.sh [--unskip] [\(trackpad)] [Clicking] [--key] [\(trackpad)] [Clicking] "
                + "[--unskip] [\(bluetooth)] [Clicking] [--key] [\(bluetooth)] [Clicking]",
            "scripts/defaults.sh [--check]",
            "scripts/defaults.sh [--key] [NSGlobalDomain] [A]",
            "scripts/defaults.sh [--check]",
        ])
        XCTAssertNil(model.decisionError)
        XCTAssertNil(model.busy)
    }

    /// An mrk from before sevmorris/mrk#130 exits 2 for --skip. Gearbox says
    /// to run make pull, and the list stays as it was.
    func testARefusedSwitchIsShownAndTheListStays() async throws {
        let stub = try StubMrk()
        try stub.answer("defaults.sh", ["--check"], out: "NSGlobalDomain\tA\ttrue\ttrue\tset\n")
        try stub.answer("defaults.sh", ["--skip", "NSGlobalDomain", "A", "--revert", "NSGlobalDomain", "A"],
                        err: "unknown argument: --skip\n", status: 2)
        let model = DefaultsModel(checkout: stub.checkout, runner: stub.runner(), store: stub.store())
        await model.load()
        XCTAssertTrue(model.skipListMissing, "the stub checkout has no config/defaults-skip.tsv")
        await model.setOn(false, for: try XCTUnwrap(model.entries.first))
        let error = try XCTUnwrap(model.decisionError)
        XCTAssertTrue(error.contains("this mrk is older than Gearbox. Run make pull"), error)
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.entries.map(\.isOn), [true])
    }

    /// A key Gearbox may not read is not set as far as it can tell, so Not set
    /// shows it; the pane's message names how many, and the settings link is
    /// the Full Disk Access pane.
    func testKeysWithNoAccess() async throws {
        let stub = try StubMrk()
        try stub.answer("defaults.sh", ["--check"], out: """
        NSGlobalDomain\tA\ttrue\ttrue\tset
        com.apple.mail\tAddressesIncludeNameOnPasteboard\tfalse\t\tnoaccess
        com.apple.TextEdit\tRichText\t0\t\tnoaccess

        """)
        let model = DefaultsModel(checkout: stub.checkout, runner: stub.runner(), store: stub.store())
        await model.load()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.counts.noAccess, 2)
        XCTAssertEqual(model.selected?.check.state, .noaccess, "with nothing to fix, the first key to see is one Gearbox cannot read")
        model.filter = .unset
        XCTAssertEqual(model.shown.flatMap(\.entries).map(\.check.key), ["AddressesIncludeNameOnPasteboard", "RichText"])
        model.filter = .off
        XCTAssertTrue(model.shown.isEmpty)

        XCTAssertEqual(FullDiskAccess.settings.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        XCTAssertTrue(FullDiskAccess.message(2).hasPrefix("Gearbox cannot read 2 keys without Full Disk Access."))
        XCTAssertTrue(FullDiskAccess.message(1).hasPrefix("Gearbox cannot read 1 key without Full Disk Access."))
    }

    /// Off shows the skipped keys; Not set leaves them out, since make
    /// defaults leaves them as they are on purpose.
    func testTheOffFilter() async throws {
        let stub = try StubMrk()
        try stub.answer("defaults.sh", ["--check"], out: """
        NSGlobalDomain\tA\ttrue\ttrue\tset
        NSGlobalDomain\tB\ttrue\t\tabsent
        NSGlobalDomain\tC\ttrue\tfalse\tskipped
        com.apple.mail\tD\tfalse\t\tnodomain

        """)
        let model = DefaultsModel(checkout: stub.checkout, runner: stub.runner(), store: stub.store())
        await model.load()
        XCTAssertEqual(model.counts, DefaultsCounts(set: 1, differs: 0, absent: 1, waiting: 1, skipped: 1))
        model.filter = .unset
        XCTAssertEqual(model.shown.flatMap(\.entries).map(\.check.key), ["B", "D"])
        model.filter = .off
        XCTAssertEqual(model.shown.flatMap(\.entries).map(\.check.key), ["C"])
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

    /// What the Dock has and the list lacks shows on its own, out of the
    /// checks keyed by line, and Add lists it as DockList.line writes it.
    func testAnUnlistedDockItemShowsAndCanBeAdded() async throws {
        let stub = try StubMrk()
        try stub.write("config/dock.txt", "/Applications/A.app\n~/Work Apps\n")
        try stub.answer("dock-setup", ["--check"], out: """
        app\t/Applications/A.app\t/Applications/A.app\tpresent\tdocked
        folder\t~/Work Apps\t/Users/x/Work Apps\tpresent\tundocked
        unlisted\t\t/Applications/Signal.app\tpresent\tdocked
        unlisted\t\t/Users/x/Downloads\tpresent\tdocked

        """)
        let model = DockModel(checkout: stub.checkout, runner: stub.runner(), home: "/Users/x")
        await model.load()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(Set(model.checks.keys), ["/Applications/A.app", "~/Work Apps"])
        XCTAssertEqual(model.checks["~/Work Apps"]?.docked, .undocked)
        XCTAssertEqual(model.unlisted.map(\.path), ["/Applications/Signal.app", "/Users/x/Downloads"])

        await model.add(model.unlisted[0])
        await model.add(model.unlisted[1])
        XCTAssertEqual(try stub.read("config/dock.txt"),
                       "/Applications/A.app\n/Applications/Signal.app\n~/Work Apps\n~/Downloads\n")
        XCTAssertNil(model.editError)
        XCTAssertEqual(stub.calls.count, 3, "a check after the load and after each add")
    }

    /// Each pane against the real output of sevmorris/mrk#122's scripts.
    func testEachPaneReadsTheRealChecks() async throws {
        let stub = try StubMrk()
        for file in ["dock.txt", "defaults.tsv", "login-items.txt", "app-prefs.tsv"] {
            try stub.write("config/\(file)", try Fixture.text("mrk-122/\(file)"))
        }
        try stub.answer("dock-setup", ["--check"], out: try Fixture.text("mrk-122/dock-setup--check.out"))
        try stub.answer("defaults.sh", ["--check", "--with-trackpad"],
                        out: try Fixture.text("mrk-122/defaults.sh--check--with-trackpad.out"))
        try stub.answer("sync-login-items", ["--check"], out: try Fixture.text("mrk-122/sync-login-items--check.out"))
        try stub.answer("snapshot-prefs", ["--check"], out: try Fixture.text("mrk-122/snapshot-prefs--check.out"))

        let dock = DockModel(checkout: stub.checkout, runner: stub.runner(), home: "/Users/sev")
        await dock.load()
        XCTAssertEqual(dock.phase, .loaded)
        XCTAssertEqual(dock.checks.count, dock.list.items.count)
        XCTAssertEqual(dock.unlisted.map(\.name), ["Signal"])

        let store = stub.store()
        store.set(true, forKey: "defaultsWithTrackpad")
        let defaults = DefaultsModel(checkout: stub.checkout, runner: stub.runner(), store: store)
        await defaults.load()
        XCTAssertEqual(defaults.phase, .loaded)
        XCTAssertEqual(defaults.counts, DefaultsCounts(set: 148, differs: 0, absent: 2, waiting: 0))
        XCTAssertEqual(defaults.selected?.check.state, .absent)

        let login = LoginItemsModel(checkout: stub.checkout, runner: stub.runner())
        await login.load()
        XCTAssertEqual(login.phase, .loaded, "no line is nothing to offer, not an error")
        XCTAssertFalse(login.rows.isEmpty)

        let prefs = PrefsModel(checkout: stub.checkout, runner: stub.runner())
        await prefs.load()
        XCTAssertEqual(prefs.phase, .loaded)
        XCTAssertEqual(prefs.groups.map(\.name), ["sevmorris-apps"])
    }

    /// A Mac where Mail was never opened: its keys wait, and are not what
    /// the pane selects first.
    func testDefaultsKeysThatWaitForTheirApp() async throws {
        let stub = try StubMrk()
        try stub.answer("defaults.sh", ["--check"], out: """
        com.apple.mail\tAddressesIncludeNameOnPasteboard\tfalse\t\tnodomain
        NSGlobalDomain\tA\ttrue\ttrue\tset
        NSGlobalDomain\tB\ttrue\t\tabsent

        """)
        let model = DefaultsModel(checkout: stub.checkout, runner: stub.runner(), store: stub.store())
        await model.load()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.counts, DefaultsCounts(set: 1, differs: 0, absent: 1, waiting: 1))
        XCTAssertEqual(model.selected?.check.key, "B")
    }

    /// Lines, and not one Gearbox can read: an mrk newer than this Gearbox,
    /// which each pane says, rather than show an empty list as nothing to do.
    func testEachPaneSaysWhenItCanReadNoLine() async throws {
        let stub = try StubMrk()
        try stub.write("config/dock.txt", "/Applications/A.app\n")
        try stub.answer("dock-setup", ["--check"], out: "tile\t/Applications/A.app\tpresent\n")
        try stub.answer("defaults.sh", ["--check"], out: "NSGlobalDomain\tA\ttrue\ttrue\tperhaps\n")
        try stub.answer("sync-login-items", ["--check"], out: "offer\tRaycast\t/Applications/Raycast.app\tnew\n")
        try stub.answer("snapshot-prefs", ["--check"], out: "Keka.plist\tVersion\n")

        let dock = DockModel(checkout: stub.checkout, runner: stub.runner(), home: "/Users/x")
        await dock.load()
        let defaults = DefaultsModel(checkout: stub.checkout, runner: stub.runner(), store: stub.store())
        await defaults.load()
        let login = LoginItemsModel(checkout: stub.checkout, runner: stub.runner())
        await login.load()
        let prefs = PrefsModel(checkout: stub.checkout, runner: stub.runner())
        await prefs.load()

        for (phase, script) in [(dock.phase, "scripts/dock-setup --check"),
                                (defaults.phase, "scripts/defaults.sh --check"),
                                (login.phase, "scripts/sync-login-items --check"),
                                (prefs.phase, "scripts/snapshot-prefs --check")] {
            guard case .failed(let message) = phase else { XCTFail("\(script): got \(phase)"); continue }
            XCTAssertTrue(message.contains(script), message)
            XCTAssertTrue(message.contains("this Gearbox is older than mrk's output"), message)
        }
    }

    /// No line at all is an empty list, as before.
    func testNoLineIsNothingToDo() async throws {
        let stub = try StubMrk()
        try stub.answer("snapshot-prefs", ["--check"], out: "\n")
        let prefs = PrefsModel(checkout: stub.checkout, runner: stub.runner())
        await prefs.load()
        XCTAssertEqual(prefs.phase, .loaded)
        XCTAssertEqual(prefs.changeCount, 0)
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
