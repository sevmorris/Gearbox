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

    /// dock-setup --check: four fields, escaped.
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
    }
}
