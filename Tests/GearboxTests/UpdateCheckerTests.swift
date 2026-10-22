import XCTest
@testable import Gearbox

/// `minimumMacOS(inReleaseNotes:)` and its helpers decide whether the update
/// check offers a release, from the marker release.sh writes into its notes.
/// A missing or malformed marker sets no minimum, so the release is offered.
/// The same tests as the sibling apps', for the same code.
final class UpdateCheckerMinimumMacOSTests: XCTestCase {

    private func version(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
    }

    private func fields(_ version: OperatingSystemVersion?) -> [Int]? {
        version.map { [$0.majorVersion, $0.minorVersion, $0.patchVersion] }
    }

    /// The footer release.sh appends after the curated notes.
    func testReadsTheMarkerReleaseShWrites() {
        XCTAssertEqual(fields(UpdateChecker.minimumMacOS(inReleaseNotes: "**Fixed**\n- Something.\n\n---\nRequires macOS 15.0 or later.\n<!-- minimum-macos: 15.0 -->")), [15, 0, 0])
        XCTAssertEqual(fields(UpdateChecker.minimumMacOS(inReleaseNotes: "<!-- minimum-macos: 15.2.1 -->")), [15, 2, 1])
        XCTAssertEqual(fields(UpdateChecker.minimumMacOS(inReleaseNotes: "<!-- minimum-macos: 26 -->")), [26, 0, 0])
    }

    /// The visible "Requires macOS" line is prose, not the marker.
    func testNotesWithoutAMarkerSetNoMinimum() {
        XCTAssertNil(UpdateChecker.minimumMacOS(inReleaseNotes: nil))
        XCTAssertNil(UpdateChecker.minimumMacOS(inReleaseNotes: "**Fixed**\n- Something."))
        XCTAssertNil(UpdateChecker.minimumMacOS(inReleaseNotes: "Requires macOS 15.0 or later."))
    }

    func testAMalformedMarkerSetsNoMinimum() {
        XCTAssertNil(UpdateChecker.minimumMacOS(inReleaseNotes: "<!-- minimum-macos: fifteen -->"))
        XCTAssertNil(UpdateChecker.minimumMacOS(inReleaseNotes: "<!-- minimum-macos: 15.0"))
        XCTAssertNil(UpdateChecker.minimumMacOS(inReleaseNotes: "<!-- minimum-macos: 15..0 -->"))
        XCTAssertNil(UpdateChecker.minimumMacOS(inReleaseNotes: "<!-- minimum-macos: 1.2.3.4 -->"))
    }

    func testComparesMajorThenMinorThenPatch() {
        XCTAssertFalse(UpdateChecker.runs(on: version(14, 6), given: version(15)))
        XCTAssertTrue(UpdateChecker.runs(on: version(15), given: version(15)))
        XCTAssertTrue(UpdateChecker.runs(on: version(26, 7, 1), given: version(15)))
        XCTAssertFalse(UpdateChecker.runs(on: version(15), given: version(15, 1)))
        XCTAssertTrue(UpdateChecker.runs(on: version(15, 1), given: version(15, 0, 1)))
    }

    func testDescribesAVersionTheWayMacOSDoes() {
        XCTAssertEqual(UpdateChecker.describe(version(15)), "15.0")
        XCTAssertEqual(UpdateChecker.describe(version(15, 2, 1)), "15.2.1")
    }
}

/// `result(for:installed:os:)`: what a release from GitHub means for this copy,
/// from the JSON GitHub sends. No request is made.
final class UpdateCheckerResultTests: XCTestCase {

    private let sequoia = OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 0)
    private let tahoe = OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)

    /// A /releases/latest answer, cut down to the fields the check reads plus a
    /// few it ignores, as release.sh publishes one: the DMG as the only asset,
    /// and the notes ending in the marker.
    private func release(tag: String, minimum: String? = "15.0",
                         assets: [String] = ["Gearbox-TAG.dmg"]) throws -> UpdateChecker.Release {
        let assetJSON = assets.map { name in
            let file = name.replacingOccurrences(of: "TAG", with: tag)
            return """
                {"name": "\(file)", "size": 1234567,
                 "browser_download_url": "https://github.com/sevmorris/Gearbox/releases/download/\(tag)/\(file)"}
                """
        }.joined(separator: ", ")
        let notes = "**Added**\\n- Something.\\n\\n---\\nRequires macOS 15.0 or later."
            + (minimum.map { "\\n<!-- minimum-macos: \($0) -->" } ?? "")
        let json = """
            {"tag_name": "\(tag)", "name": "Gearbox \(tag)", "draft": false, "prerelease": false,
             "html_url": "https://github.com/sevmorris/Gearbox/releases/tag/\(tag)",
             "body": "\(notes)", "assets": [\(assetJSON)]}
            """
        return try JSONDecoder().decode(UpdateChecker.Release.self, from: Data(json.utf8))
    }

    func testANewerReleaseIsOfferedWithItsDMG() throws {
        let result = UpdateChecker.result(for: try release(tag: "v0.2"), installed: "0.1", os: sequoia)
        XCTAssertEqual(result, .available(AvailableUpdate(
            version: "0.2",
            downloadURL: URL(string: "https://github.com/sevmorris/Gearbox/releases/download/v0.2/Gearbox-v0.2.dmg")!,
            releaseURL: URL(string: "https://github.com/sevmorris/Gearbox/releases/tag/v0.2")!)))
    }

    /// Numeric, not textual: 0.10 is after 0.9.
    func testVersionsCompareAsNumbers() throws {
        guard case .available(let update) = UpdateChecker.result(
            for: try release(tag: "v0.10"), installed: "0.9", os: sequoia) else {
            return XCTFail("0.10 should be offered over 0.9")
        }
        XCTAssertEqual(update.version, "0.10")
    }

    func testTheSameOrAnOlderReleaseIsUpToDate() throws {
        XCTAssertEqual(UpdateChecker.result(for: try release(tag: "v0.2"), installed: "0.2", os: sequoia),
                       .upToDate(version: "0.2"))
        XCTAssertEqual(UpdateChecker.result(for: try release(tag: "v0.1"), installed: "0.2", os: sequoia),
                       .upToDate(version: "0.2"))
    }

    func testAReleaseThisMacCannotRunIsNotOffered() throws {
        let result = UpdateChecker.result(for: try release(tag: "v0.3", minimum: "26.0"),
                                          installed: "0.2", os: sequoia)
        XCTAssertEqual(result, .needsNewerMacOS(version: "0.3", minimum: "26.0", installed: "0.2"))
        guard case .available = UpdateChecker.result(for: try release(tag: "v0.3", minimum: "26.0"),
                                                     installed: "0.2", os: tahoe) else {
            return XCTFail("a Mac on 26.1 runs a release that needs 26.0")
        }
    }

    /// Notes with no marker set no minimum, so the release is offered.
    func testAReleaseWithoutTheMarkerIsOffered() throws {
        guard case .available = UpdateChecker.result(for: try release(tag: "v0.2", minimum: nil),
                                                     installed: "0.1", os: sequoia) else {
            return XCTFail("a release without the marker should be offered")
        }
    }

    /// With no DMG among the assets, Download opens the release page.
    func testAReleaseWithoutADMGDownloadsFromItsPage() throws {
        guard case .available(let update) = UpdateChecker.result(
            for: try release(tag: "v0.2", assets: ["Gearbox-TAG-app.zip"]), installed: "0.1", os: sequoia) else {
            return XCTFail("expected an update")
        }
        XCTAssertEqual(update.downloadURL, update.releaseURL)
    }
}

/// GitHub as the tests have it: answers in turn from a list, and counts the
/// requests.
private final class FakeGitHub: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [UpdateChecker.Result]
    private(set) var requests = 0

    init(_ answers: [UpdateChecker.Result]) { self.answers = answers }

    func latest() -> UpdateChecker.Result {
        lock.lock(); defer { lock.unlock() }
        requests += 1
        return answers.count > 1 ? answers.removeFirst() : answers[0]
    }
}

/// When the quiet check asks, what it says, and where it keeps its dates:
/// the store the model was given, never the real domain.
@MainActor
final class UpdateScheduleTests: XCTestCase {
    private let update = AvailableUpdate(
        version: "0.2",
        downloadURL: URL(string: "https://github.com/sevmorris/Gearbox/releases/download/v0.2/Gearbox-v0.2.dmg")!,
        releaseURL: URL(string: "https://github.com/sevmorris/Gearbox/releases/tag/v0.2")!)
    private let noon = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func model(_ stub: StubMrk, _ github: FakeGitHub, store: UserDefaults? = nil) -> AppModel {
        AppModel(checkout: stub.checkout, runner: stub.runner(), store: store ?? stub.store(),
                 home: "/Users/x", latestRelease: { github.latest() })
    }

    func testTheScheduleIsDueAfterAnHourAndWhenTheClockWentBack() throws {
        let stub = try StubMrk()
        let schedule = UpdateSchedule(store: stub.store())
        XCTAssertTrue(schedule.isDue(at: noon))
        schedule.record(.upToDate(version: "0.1"), at: noon)
        XCTAssertFalse(schedule.isDue(at: noon.addingTimeInterval(59 * 60)))
        XCTAssertTrue(schedule.isDue(at: noon.addingTimeInterval(60 * 60)))
        XCTAssertTrue(schedule.isDue(at: noon.addingTimeInterval(-60)))
    }

    func testAFailedCheckRecordsNoDate() throws {
        let stub = try StubMrk()
        let schedule = UpdateSchedule(store: stub.store())
        schedule.record(.error("offline"), at: noon)
        XCTAssertNil(stub.store().object(forKey: UpdateSchedule.lastCheckKey))
        XCTAssertTrue(schedule.isDue(at: noon.addingTimeInterval(60)))
    }

    func testTheQuietCheckAsksOnceAnHour() async throws {
        let stub = try StubMrk()
        let github = FakeGitHub([.upToDate(version: "0.1")])
        let app = model(stub, github)
        let first = await app.checkForUpdates(quietly: true, now: noon)
        XCTAssertNil(first, "up to date is not worth an alert")
        let soon = await app.checkForUpdates(quietly: true, now: noon.addingTimeInterval(10 * 60))
        XCTAssertNil(soon)
        XCTAssertEqual(github.requests, 1)
        _ = await app.checkForUpdates(quietly: true, now: noon.addingTimeInterval(61 * 60))
        XCTAssertEqual(github.requests, 2)
    }

    /// Check for Updates… asks inside the hour too, and says what it found.
    func testCheckForUpdatesAlwaysAsksAndAnswers() async throws {
        let stub = try StubMrk()
        let github = FakeGitHub([.upToDate(version: "0.1")])
        let app = model(stub, github)
        _ = await app.checkForUpdates(quietly: true, now: noon)
        let asked = await app.checkForUpdates(quietly: false, now: noon.addingTimeInterval(60))
        XCTAssertEqual(asked, .upToDate(version: "0.1"))
        XCTAssertEqual(github.requests, 2)
    }

    func testAnUpdateIsOfferedUntilItIsDismissed() async throws {
        let stub = try StubMrk()
        let github = FakeGitHub([.available(update)])
        let app = model(stub, github)
        let found = await app.checkForUpdates(quietly: true, now: noon)
        XCTAssertEqual(found, .available(update))
        XCTAssertEqual(app.availableUpdate, update)

        app.updateSchedule.dismiss("0.2")
        let later = await app.checkForUpdates(quietly: true, now: noon.addingTimeInterval(2 * 60 * 60))
        XCTAssertNil(later, "Not Now on 0.2 keeps the quiet check from offering it again")
        XCTAssertEqual(app.availableUpdate, update, "the sidebar still names it")
        XCTAssertEqual(github.requests, 2)
    }

    /// A failure keeps what the last check found, and leaves the next quiet
    /// check free to ask at once.
    func testAFailedQuietCheckSaysNothingAndKeepsWhatWasFound() async throws {
        let stub = try StubMrk()
        let github = FakeGitHub([.available(update), .error("offline"), .upToDate(version: "0.2")])
        let app = model(stub, github)
        _ = await app.checkForUpdates(quietly: false, now: noon)
        let failed = await app.checkForUpdates(quietly: true, now: noon.addingTimeInterval(2 * 60 * 60))
        XCTAssertNil(failed)
        XCTAssertEqual(app.availableUpdate, update)
        let next = await app.checkForUpdates(quietly: true, now: noon.addingTimeInterval(2 * 60 * 60 + 60))
        XCTAssertNil(next)
        XCTAssertNil(app.availableUpdate, "up to date clears it")
        XCTAssertEqual(github.requests, 3)
    }

    /// A release this Mac cannot run is no update: nothing in the sidebar,
    /// and nothing said at launch.
    func testAReleaseThisMacCannotRunIsKeptQuiet() async throws {
        let stub = try StubMrk()
        let github = FakeGitHub([.needsNewerMacOS(version: "0.3", minimum: "26.0", installed: "0.2")])
        let app = model(stub, github)
        let quiet = await app.checkForUpdates(quietly: true, now: noon)
        XCTAssertNil(quiet)
        XCTAssertNil(app.availableUpdate)
    }

    /// The dates go to the store the model was given: under tests a suite in
    /// a temporary folder, in the app UserDefaults.app.
    func testTheScheduleLivesInTheModelsStore() async throws {
        let stub = try StubMrk()
        let store = stub.store()
        let app = model(stub, FakeGitHub([.upToDate(version: "0.1")]), store: store)
        _ = await app.checkForUpdates(quietly: true, now: noon)
        XCTAssertEqual(store.object(forKey: UpdateSchedule.lastCheckKey) as? Date, noon)
        XCTAssertNil(UserDefaults.app.object(forKey: UpdateSchedule.lastCheckKey))
    }
}
