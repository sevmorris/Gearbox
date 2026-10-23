import XCTest
@testable import Gearbox

final class TSVTests: XCTestCase {
    func testEscapesAreUndone() {
        XCTAssertEqual(MrkText.unescape(#"a\tb\nc\\d"#), "a\tb\nc\\d")
        XCTAssertEqual(MrkText.unescape("plain"), "plain")
    }

    func testABackslashBeforeAnythingElseIsRefused() {
        XCTAssertNil(MrkText.unescape(#"C:\qtemp"#))
        XCTAssertNil(MrkText.unescape(#"ends\"#))
    }

    func testTwoTabsAreAnEmptyField() {
        XCTAssertEqual(MrkText.fields("a\t\tc"), ["a", "", "c"])
        XCTAssertEqual(MrkText.fields("a\t"), ["a", ""])
    }

    /// As Characters, "\r\n" is one, which a split at "\n" would not find.
    func testACarriageReturnDoesNotJoinTwoLines() {
        XCTAssertEqual(MrkText.lines("a\tb\r\nc\td\n"), ["a\tb\r", "c\td"])
        XCTAssertEqual(MrkText.lines("one\n\ntwo"), ["one", "", "two"])
        XCTAssertEqual(MrkText.lines(""), [])
    }

    func testHasLinesIsTextOnSomeLine() {
        XCTAssertFalse(MrkText.hasLines(""))
        XCTAssertFalse(MrkText.hasLines("\n\n"))
        XCTAssertTrue(MrkText.hasLines("\nx\n"))
    }

    func testEntriesFollowMrkConfigEntries() {
        XCTAssertFalse(MrkText.isEntry("# comment"))
        XCTAssertFalse(MrkText.isEntry(""))
        XCTAssertFalse(MrkText.isEntry("   \t"))
        XCTAssertTrue(MrkText.isEntry(" /Applications/x.app"))
        XCTAssertTrue(MrkText.isEntry("/Applications/#1.app"))
    }
}

final class PrefsDiffTests: XCTestCase {
    /// snapshot-prefs --check on this Mac, 2026-10-21, cut down.
    let output = """
    AudioHijack.plist\trecentFolderPaths\tadded
    Keka.plist\tBookmarks\tchanged
    Keka.plist\tVersion\tchanged
    sevmorris-apps/io.github.sevmorris.ClipHack.plist\tClipHackSettings\tchanged
    repos.tsv\t\tchanged
    app-support/Loopback/Devices.plist\t\tdeleted
    garbage line
    Keka.plist\tX\tmodified

    """

    let table = AppPrefsTable.parse("""
    # domain\tfile\tapp\tname
    com.aone.keka\tKeka.plist\t/Applications/Keka.app\tKeka
    com.rogueamoeba.AudioHijack\tAudioHijack.plist\t/Applications/Audio Hijack.app\tAudio Hijack
    bad line
    """)

    func testThreeFieldsAndAKnownChange() {
        let changes = PrefChange.parse(output)
        XCTAssertEqual(changes.count, 6)
        XCTAssertEqual(changes[0], PrefChange(file: "AudioHijack.plist", key: "recentFolderPaths", kind: .added))
        XCTAssertEqual(changes[4], PrefChange(file: "repos.tsv", key: "", kind: .changed))
    }

    /// The --check line contract: escaped fields, and fields a later mrk
    /// adds at the end.
    func testEscapedKeysAndExtraFields() {
        let changes = PrefChange.parse("""
        Keka.plist\tTab\\tKey\tchanged
        Keka.plist\tTwo\\nLines\tadded\tsomething later
        Keka.plist\tC:\\\\temp\tdeleted
        Keka.plist\tBad\\qEscape\tchanged

        """)
        XCTAssertEqual(changes, [
            PrefChange(file: "Keka.plist", key: "Tab\tKey", kind: .changed),
            PrefChange(file: "Keka.plist", key: "Two\nLines", kind: .added),
            PrefChange(file: "Keka.plist", key: "C:\\temp", kind: .deleted),
        ])
    }

    func testTheRealCheck() throws {
        XCTAssertEqual(PrefChange.parse(try Fixture.text("mrk-122/snapshot-prefs--check.out")), [
            PrefChange(file: "sevmorris-apps/io.github.sevmorris.ClipHack.plist", key: "ClipHackSettings", kind: .changed),
        ])
        let table = AppPrefsTable.parse(try Fixture.text("mrk-122/app-prefs.tsv"))
        XCTAssertFalse(table.names.isEmpty)
    }

    func testGroupsByTheTablesNameThenByDirectory() {
        let groups = PrefGroup.group(PrefChange.parse(output), table: table)
        XCTAssertEqual(groups.map(\.name),
                       ["Audio Hijack", "Keka", "sevmorris-apps", "repos.tsv", "app-support/Loopback"])
        XCTAssertEqual(groups[1].changes.map(\.key), ["Bookmarks", "Version"])
    }

    func testLabels() {
        let groups = PrefGroup.group(PrefChange.parse(output), table: table)
        XCTAssertEqual(PrefGroup.label(of: groups[1].changes[0], in: groups[1]), "Bookmarks")
        XCTAssertEqual(PrefGroup.label(of: groups[2].changes[0], in: groups[2]),
                       "io.github.sevmorris.ClipHack.plist — ClipHackSettings")
        XCTAssertEqual(PrefGroup.label(of: groups[3].changes[0], in: groups[3]), "The whole file")
        XCTAssertEqual(PrefGroup.label(of: groups[4].changes[0], in: groups[4]), "Devices.plist")
    }
}

final class DefaultsParserTests: XCTestCase {
    let table = """
    # header
    NSGlobalDomain\tAppleShowAllExtensions\tbool\ttrue\talways\tFinder
    com.apple.screencapture\tlocation\tstring\t~/Desktop\talways\tScreenshots
    com.apple.AppleMultitouchTrackpad\tClicking\tbool\ttrue\ttrackpad\tTrackpad
    com.apple.driver.AppleBluetoothMultitouch.trackpad\tClicking\tbool\ttrue\ttrackpad\tTrackpad
    com.apple.TextEdit\tRichText\tbool\tfalse\texisting\tTextEdit
    com.example\tTab\tstring\tone\\ttwo\talways\tOdd
    bad\tline
    """

    let descriptions = """
    # domain key title category default preference description why background
    NSGlobalDomain\tAppleShowAllExtensions\tShow All File Extensions\tSecurity\t\tfalse\tShows every extension.\tSo a .app named .pdf shows.\t
    com.apple.AppleMultitouchTrackpad\tClicking\tTap to Click\tInput\tfalse\ttrue\tA tap is a click.\t\tSince 10.x.\\nTwo lines.
    eight\tfields\tonly\tSecurity\t\tfalse\ttext\t
    """

    func testTheTable() {
        let rows = DefaultsRow.parse(table)
        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(rows[1].value, "~/Desktop")
        XCTAssertEqual(rows[2].when, "trackpad")
        XCTAssertEqual(rows[5].value, "one\ttwo")
        XCTAssertEqual(rows[2].setting, rows[3].setting)
    }

    func testTheDescriptions() {
        let d = DefaultDescription.parse(descriptions)
        XCTAssertEqual(d.count, 2)
        let tap = d["com.apple.AppleMultitouchTrackpad\tClicking"]
        XCTAssertEqual(tap?.title, "Tap to Click")
        XCTAssertEqual(tap?.preference, true)
        XCTAssertEqual(tap?.systemDefault, "false")
        XCTAssertEqual(tap?.background, "Since 10.x.\nTwo lines.")
        XCTAssertEqual(d["NSGlobalDomain\tAppleShowAllExtensions"]?.why, "So a .app named .pdf shows.")
    }

    /// defaults.sh --check: five fields, escaped, absent with an empty value.
    func testTheCheck() {
        let checks = DefaultCheck.parse("""
        NSGlobalDomain\tAppleShowAllExtensions\ttrue\ttrue\tset
        com.apple.screencapture\tlocation\t/Users/x/Desktop\t/Users/x/Pictures\tdiffers
        com.apple.TextEdit\tRichText\tfalse\t\tabsent
        com.example\tTab\tone\\ttwo\tone\\\\two\tdiffers
        com.example\tWrong\ta\tb\tmaybe
        """)
        XCTAssertEqual(checks.count, 4)
        XCTAssertEqual(checks[2].state, .absent)
        XCTAssertEqual(checks[2].current, "")
        XCTAssertEqual(checks[3].mrkValue, "one\ttwo")
        XCTAssertEqual(checks[3].current, "one\\two")
    }

    /// sevmorris/mrk#122: nodomain for a when=existing key whose app has not
    /// made its preferences, and fields a later mrk adds at the end.
    func testNodomainAndExtraFields() {
        let checks = DefaultCheck.parse("""
        com.apple.mail\tAddressesIncludeNameOnPasteboard\tfalse\t\tnodomain
        NSGlobalDomain\tA\ttrue\ttrue\tset\tsomething later
        NSGlobalDomain\tB\ttrue\t\tabsent\t\t
        NSGlobalDomain\tC\ttrue\tfalse\tdiffers
        four\tfields\tonly\tset

        """)
        XCTAssertEqual(checks.map(\.state), [.nodomain, .set, .absent, .differs])
        XCTAssertEqual(checks[0].current, "")
        XCTAssertEqual(checks.map(\.state.isDrift), [false, false, true, true])
        let counts = DefaultsSection(name: "x", entries: DefaultsEntry.join(checks: checks, rows: [], descriptions: [:])).counts
        XCTAssertEqual(counts, DefaultsCounts(set: 1, differs: 1, absent: 1, waiting: 1))
    }

    func testTheRealCheck() throws {
        let checks = DefaultCheck.parse(try Fixture.text("mrk-122/defaults.sh--check--with-trackpad.out"))
        XCTAssertEqual(checks.count, 150)
        let rows = DefaultsRow.parse(try Fixture.text("mrk-122/defaults.tsv"))
        let sections = DefaultsSection.group(DefaultsEntry.join(checks: checks, rows: rows, descriptions: [:]))
        XCTAssertEqual(sections.reduce(DefaultsCounts()) { $0 + $1.counts },
                       DefaultsCounts(set: 148, differs: 0, absent: 2, waiting: 0))
        XCTAssertFalse(sections.contains { $0.name == "Not in config/defaults.tsv" },
                       "every key --check names is a line of the table")
    }

    func testTheSecondDomainOfASettingTakesTheFirstsDescription() {
        let checks = DefaultCheck.parse("""
        com.apple.AppleMultitouchTrackpad\tClicking\ttrue\ttrue\tset
        com.apple.driver.AppleBluetoothMultitouch.trackpad\tClicking\ttrue\tfalse\tdiffers
        NSGlobalDomain\tAppleShowAllExtensions\ttrue\ttrue\tset
        com.apple.TextEdit\tRichText\tfalse\t\tabsent
        """)
        let entries = DefaultsEntry.join(checks: checks, rows: DefaultsRow.parse(table),
                                         descriptions: DefaultDescription.parse(descriptions))
        XCTAssertEqual(entries.map(\.title),
                       ["Tap to Click", "Tap to Click", "Show All File Extensions", "RichText"])
        XCTAssertEqual(entries[0].alsoDomains, ["com.apple.driver.AppleBluetoothMultitouch.trackpad"])
        XCTAssertEqual(entries[1].check.state, .differs)
        // The switch of either domain turns the setting in both.
        let both = [DefaultsKey(domain: "com.apple.AppleMultitouchTrackpad", key: "Clicking"),
                    DefaultsKey(domain: "com.apple.driver.AppleBluetoothMultitouch.trackpad", key: "Clicking")]
        XCTAssertEqual(entries[0].keys, both)
        XCTAssertEqual(entries[1].keys, both)
        XCTAssertEqual(entries[2].keys, [DefaultsKey(domain: "NSGlobalDomain", key: "AppleShowAllExtensions")])
        XCTAssertNil(entries[3].description)
        XCTAssertEqual(entries[3].row?.when, "existing")

        let sections = DefaultsSection.group(entries)
        XCTAssertEqual(sections.map(\.name), ["Trackpad", "Finder", "TextEdit"])
        XCTAssertEqual(sections[0].counts.set, 1)
        XCTAssertEqual(sections[0].counts.differs, 1)
    }

    func testACheckLineTheTableLacksStillShows() {
        let entries = DefaultsEntry.join(
            checks: DefaultCheck.parse("com.new\tKey\t1\t\tabsent\n"), rows: [], descriptions: [:])
        XCTAssertEqual(entries.first?.section, "Not in config/defaults.tsv")
        XCTAssertEqual(entries.first?.title, "Key")
        XCTAssertEqual(entries.first?.keys, [DefaultsKey(domain: "com.new", key: "Key")])
    }

    /// sevmorris/mrk#131: noaccess, for a key whose app keeps its settings in
    /// a container Gearbox may not read. Its value is empty and not known.
    func testNoaccessIsNotDriftAndHasNoValue() {
        let checks = DefaultCheck.parse("""
        com.apple.mail\tAddressesIncludeNameOnPasteboard\tfalse\t\tnoaccess
        com.apple.Passwords\tshowMenuBarExtra\tfalse\t\tnoaccess\ta later field
        NSGlobalDomain\tA\ttrue\ttrue\tset

        """)
        XCTAssertEqual(checks.map(\.state), [.noaccess, .noaccess, .set])
        XCTAssertEqual(checks.map(\.state.isDrift), [false, false, false])
        XCTAssertEqual(checks[0].current, "")
        let entries = DefaultsEntry.join(checks: checks, rows: [], descriptions: [:])
        XCTAssertEqual(entries.map(\.isOn), [true, true, true], "no access says nothing of the skip list")
        XCTAssertEqual(DefaultsSection(name: "x", entries: entries).counts,
                       DefaultsCounts(set: 1, differs: 0, absent: 0, waiting: 0, skipped: 0, noAccess: 2))
    }

    /// sevmorris/mrk#130: skipped, for a key config/defaults-skip.tsv lists.
    /// It is off, and not drift, whatever its value.
    func testSkippedIsOffAndNotDrift() {
        let checks = DefaultCheck.parse("""
        NSGlobalDomain\tA\ttrue\tfalse\tskipped
        NSGlobalDomain\tB\ttrue\t\tskipped\ta later field
        NSGlobalDomain\tC\ttrue\ttrue\tset

        """)
        XCTAssertEqual(checks.map(\.state), [.skipped, .skipped, .set])
        XCTAssertEqual(checks.map(\.state.isDrift), [false, false, false])
        let entries = DefaultsEntry.join(checks: checks, rows: [], descriptions: [:])
        XCTAssertEqual(entries.map(\.isOn), [false, false, true])
        XCTAssertEqual(DefaultsSection(name: "x", entries: entries).counts,
                       DefaultsCounts(set: 1, differs: 0, absent: 0, waiting: 0, skipped: 2))
    }
}

final class LoginItemsTests: XCTestCase {
    let tracked = LoginItemRow.tracked(in: """
    # header
    /Applications/AlDente.app
    /Applications/Chrono Plus.app

    /Applications/Dropbox.app
    /Applications/Old.app
    """)

    func testTheTrackedAppsAreTheFilesEntries() {
        XCTAssertEqual(tracked, ["/Applications/AlDente.app", "/Applications/Chrono Plus.app",
                                 "/Applications/Dropbox.app", "/Applications/Old.app"])
    }

    func testOffersAreFourFields() {
        let offers = LoginItemOffer.parse("""
        add\tRaycast\t/Applications/Raycast.app\tnew
        remove\tOld\t/Applications/Old.app\tstale
        remove\tDropbox\t/Applications/Dropbox.app\tignored
        add\tBad\t/x\tother
        three\tfields\tonly

        """)
        XCTAssertEqual(offers.map(\.name), ["Raycast", "Old", "Dropbox"])
        XCTAssertEqual(offers[1].reason, .stale)
    }

    /// The --check line contract: a name goes back to --add as
    /// sync-login-items wrote it, and a field a later mrk adds is passed by.
    func testEscapedNamesAndExtraFields() {
        let offers = LoginItemOffer.parse("""
        add\tA\\\\B\t/Applications/A\\\\B.app\tnew
        add\tTab\\there\t/Applications/Tab\\there.app\tnew\tsomething later
        add\tBad\\q\t/x\tnew

        """)
        XCTAssertEqual(offers.map(\.name), ["A\\B", "Tab\there"])
        XCTAssertEqual(offers[0].path, "/Applications/A\\B.app")
    }

    func testTheRealCheckOffersNothing() throws {
        let tracked = LoginItemRow.tracked(in: try Fixture.text("mrk-122/login-items.txt"))
        let offers = LoginItemOffer.parse(try Fixture.text("mrk-122/sync-login-items--check.out"))
        XCTAssertEqual(offers, [])
        XCTAssertFalse(tracked.isEmpty)
        XCTAssertTrue(LoginItemRow.rows(tracked: tracked, offers: offers).allSatisfy { $0.state == .tracked })
    }

    func testRowsJoinTheFileAndTheCheck() {
        let offers = LoginItemOffer.parse("""
        add\tRaycast\t/Applications/Raycast.app\tnew
        remove\tOld\t/Applications/Old.app\tstale
        remove\tDropbox\t/Applications/Dropbox.app\tignored
        """)
        let rows = LoginItemRow.rows(tracked: tracked, offers: offers)
        XCTAssertEqual(rows.map(\.name), ["AlDente", "Chrono Plus", "Dropbox", "Old", "Raycast"])
        XCTAssertEqual(rows.map(\.state), [.tracked, .tracked, .ignoredButTracked, .stale, .untracked])
    }

    func testARemoveTakesTheNameCheckGives() {
        // sync-login-items compares names in NFC; the decision takes its form.
        let rows = LoginItemRow.rows(tracked: ["/Applications/Cafe\u{301}.app"],
                                     offers: LoginItemOffer.parse("remove\tCaf\u{E9}\t/Applications/Cafe\u{301}.app\tstale\n"))
        XCTAssertEqual(rows.first?.name.unicodeScalars.count, 4)
        XCTAssertEqual(rows.first?.state, .stale)
    }
}

final class DockListTests: XCTestCase {
    let file = """
    # mrk Dock layout
    #
    /Applications/Helium.app
    /Applications/Safari.app
    # the next one is mine
    /Applications/Claude.app
    ~/Work Apps
    # trailing note

    """

    func testParseKeepsEveryLine() {
        let list = DockList.parse(file)
        XCTAssertEqual(list.header, ["# mrk Dock layout", "#"])
        XCTAssertEqual(list.items.map(\.line),
                       ["/Applications/Helium.app", "/Applications/Safari.app", "/Applications/Claude.app", "~/Work Apps"])
        XCTAssertEqual(list.items[2].leading, ["# the next one is mine"])
        XCTAssertEqual(list.trailer, ["# trailing note"])
        XCTAssertEqual(list.text, file)
    }

    func testAMovedAppTakesItsCommentAndFoldersStayPut() {
        var list = DockList.parse(file)
        list.moveApps(fromOffsets: [2], toOffset: 0)
        XCTAssertEqual(list.text, """
        # mrk Dock layout
        #
        # the next one is mine
        /Applications/Claude.app
        /Applications/Helium.app
        /Applications/Safari.app
        ~/Work Apps
        # trailing note

        """)
    }

    func testAppOffsetsSkipAFolderBetweenApps() {
        var list = DockList.parse("/A.app\n/Folder\n/B.app\n/C.app\n")
        list.moveApps(fromOffsets: [0], toOffset: 3)
        XCTAssertEqual(list.items.map(\.line), ["/B.app", "/Folder", "/C.app", "/A.app"])
    }

    func testAddPutsAnAppAfterTheAppsAndAFolderLast() throws {
        var list = DockList.parse(file)
        try list.add("/Applications/Notes.app")
        try list.add("~/Downloads")
        XCTAssertEqual(list.items.map(\.line).suffix(3),
                       ["/Applications/Notes.app", "~/Work Apps", "~/Downloads"])
        XCTAssertThrowsError(try list.add("/Applications/Safari.app")) {
            XCTAssertEqual($0 as? DockList.EditError, .alreadyListed("/Applications/Safari.app"))
        }
        XCTAssertThrowsError(try list.add("Applications/X.app"))
    }

    func testRemoveKeepsTheComment() {
        var list = DockList.parse(file)
        list.remove("/Applications/Claude.app")
        XCTAssertEqual(list.items.map(\.line), ["/Applications/Helium.app", "/Applications/Safari.app", "~/Work Apps"])
        XCTAssertEqual(list.items[2].leading, ["# the next one is mine"])
    }

    func testAPathInTheHomeDirectoryIsWrittenWithATilde() {
        XCTAssertEqual(DockList.line(for: URL(fileURLWithPath: "/Users/x/Work Apps"), home: "/Users/x"), "~/Work Apps")
        XCTAssertEqual(DockList.line(for: URL(fileURLWithPath: "/Users/xy/A"), home: "/Users/x"), "/Users/xy/A")
        XCTAssertEqual(DockList.line(for: URL(fileURLWithPath: "/Applications/Safari.app"), home: "/Users/x"),
                       "/Applications/Safari.app")
    }

    func testWriteReplacesTheFileWhole() throws {
        let stub = try StubMrk()
        try stub.write("config/dock.txt", "old\n")
        var list = DockList.parse(file)
        list.remove("/Applications/Helium.app")
        try list.write(to: stub.checkout.dockList)
        XCTAssertEqual(try stub.read("config/dock.txt"), list.text)
        let mode = try FileManager.default.attributesOfItem(atPath: stub.checkout.dockList.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o644)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: stub.root.appendingPathComponent("config").path)
            .filter { $0.contains("gearbox") }
        XCTAssertEqual(leftovers, [])
    }

    /// dock-setup --check before sevmorris/mrk#122: four fields, escaped.
    func testTheCheck() {
        let checks = DockCheck.parse("""
        app\t/Applications/Helium.app\t/Applications/Helium.app\tpresent
        app\t/Applications/Gone.app\t/Applications/Gone.app\tmissing
        folder\t~/Odd\\\\name\\there\t/Users/x/Odd\\\\name\\there\tpresent
        file\t/x\t/x\tpresent
        """)
        XCTAssertEqual(checks.count, 3)
        XCTAssertEqual(checks[1].state, .missing)
        XCTAssertEqual(checks[2].line, "~/Odd\\name\there")
        XCTAssertEqual(checks[2].kind, .folder)
        XCTAssertEqual(checks.map(\.docked), [nil, nil, nil])
    }

    /// sevmorris/mrk#122: a fifth field, unlisted lines, and whatever a
    /// later mrk adds at the end.
    func testTheCheckWithTheDock() {
        let output = """
        app\t/Applications/A.app\t/Applications/A.app\tpresent\tdocked
        app\t/Applications/B.app\t/Applications/B.app\tpresent\tundocked\tsomething later
        app\t/Applications/C.app\t/Applications/C.app\tmissing\tunknown
        app\t/Applications/D.app\t/Applications/D.app\tpresent\tsomeday
        unlisted\t\t/Applications/Signal.app\tpresent\tdocked
        unlisted\t\t/Users/x/Odd\\\\name\\there\tmissing\tdocked\tsomething later
        unlisted\t\t\tpresent\tdocked
        weblink\t\thttps://example.com\tpresent\tdocked

        """
        let checks = DockCheck.parse(output)
        XCTAssertEqual(checks.map(\.line), ["/Applications/A.app", "/Applications/B.app",
                                            "/Applications/C.app", "/Applications/D.app"])
        XCTAssertEqual(checks.map(\.docked), [.docked, .undocked, .unknown, nil],
                       "a word Gearbox does not know reads as not saying")
        let unlisted = UnlistedDockItem.parse(output)
        XCTAssertEqual(unlisted, [
            UnlistedDockItem(path: "/Applications/Signal.app", state: .present),
            UnlistedDockItem(path: "/Users/x/Odd\\name\there", state: .missing),
        ])
        XCTAssertEqual(unlisted[0].name, "Signal")
        XCTAssertTrue(unlisted[0].isApp)
        XCTAssertEqual(DockList.line(for: URL(fileURLWithPath: unlisted[1].path), home: "/Users/x"), "~/Odd\\name\there")
    }

    /// The same config/dock.txt, checked by mrk before and after #122: each
    /// item has its check either way.
    func testTheRealChecksBeforeAndAfterTheContract() throws {
        let list = DockList.parse(try Fixture.text("mrk-122/dock.txt"))
        for (fixture, docked) in [("mrk-before-122/dock-setup--check.out", nil as Docked?),
                                  ("mrk-122/dock-setup--check.out", .docked)] {
            let output = try Fixture.text(fixture)
            let checks = DockCheck.parse(output)
            XCTAssertEqual(checks.map(\.line), list.items.map(\.line), fixture)
            XCTAssertTrue(checks.allSatisfy { $0.state == .present && $0.docked == docked }, fixture)
        }
        XCTAssertEqual(UnlistedDockItem.parse(try Fixture.text("mrk-before-122/dock-setup--check.out")), [])
        XCTAssertEqual(UnlistedDockItem.parse(try Fixture.text("mrk-122/dock-setup--check.out")),
                       [UnlistedDockItem(path: "/Applications/Signal.app", state: .present)])
    }
}
