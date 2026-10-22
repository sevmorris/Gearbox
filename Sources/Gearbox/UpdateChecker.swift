import AppKit
import Foundation

/// A release newer than this build, which this Mac can run.
struct AvailableUpdate: Equatable, Sendable {
    let version: String
    let downloadURL: URL
    let releaseURL: URL
}

/// Asks GitHub for Gearbox's latest release, as each sibling app asks for its
/// own: sevmorris/Gearbox's /releases/latest, and the minimum-macos marker
/// release.sh ends every release's notes with. Dipstick's, with the name
/// changed.
actor UpdateChecker {
    static let shared = UpdateChecker()

    enum Result: Equatable, Sendable {
        case upToDate(version: String)
        case available(AvailableUpdate)
        /// Newer than this build, but it needs a newer macOS than this Mac has.
        case needsNewerMacOS(version: String, minimum: String, installed: String)
        case error(String)
    }

    /// The fields of GitHub's release JSON that the check reads.
    struct Release: Decodable {
        let tagName: String
        let htmlUrl: String
        let assets: [Asset]
        /// The release notes, which carry the minimum-macos marker.
        let body: String?

        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: String
            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadUrl = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlUrl = "html_url"
            case assets
            case body
        }
    }

    static let apiURL = URL(string: "https://api.github.com/repos/sevmorris/Gearbox/releases/latest")!
    static let releasesURL = URL(string: "https://github.com/sevmorris/Gearbox/releases")!

    /// The version this copy is: the bundle's, or appVersion under `swift run`,
    /// which has no bundle.
    nonisolated static var installedVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? appVersion
    }

    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        return URLSession(configuration: config)
    }()

    /// The macOS a release says it needs. release.sh ends every release's notes
    /// with `<!-- minimum-macos: 15.0 -->`, read from the built app's
    /// LSMinimumSystemVersion; GitHub does not render the comment. nil when there
    /// is no marker: a release from before it existed, which runs on every macOS
    /// this build does.
    nonisolated static func minimumMacOS(inReleaseNotes notes: String?) -> OperatingSystemVersion? {
        guard let notes,
              let start = notes.range(of: "<!-- minimum-macos:"),
              let end = notes[start.upperBound...].range(of: "-->") else { return nil }
        return macOSVersion(String(notes[start.upperBound..<end.lowerBound]))
    }

    /// "15", "15.0" or "15.2.1" as a version; nil for anything else.
    nonisolated static func macOSVersion(_ string: String) -> OperatingSystemVersion? {
        let fields = string.trimmingCharacters(in: .whitespaces)
            .split(separator: ".", omittingEmptySubsequences: false)
        let numbers = fields.compactMap { Int($0) }
        guard (1...3).contains(fields.count), numbers.count == fields.count else { return nil }
        return OperatingSystemVersion(majorVersion: numbers[0],
                                      minorVersion: numbers.count > 1 ? numbers[1] : 0,
                                      patchVersion: numbers.count > 2 ? numbers[2] : 0)
    }

    /// True when a Mac running `os` meets `minimum`.
    nonisolated static func runs(on os: OperatingSystemVersion, given minimum: OperatingSystemVersion) -> Bool {
        (os.majorVersion, os.minorVersion, os.patchVersion)
            >= (minimum.majorVersion, minimum.minorVersion, minimum.patchVersion)
    }

    /// "15.0", or "15.2.1" when there is a patch number.
    nonisolated static func describe(_ version: OperatingSystemVersion) -> String {
        let base = "\(version.majorVersion).\(version.minorVersion)"
        return version.patchVersion > 0 ? "\(base).\(version.patchVersion)" : base
    }

    /// What `release` means for a copy at `installed` on a Mac running `os`.
    /// Apart from the request, so the tests can ask it.
    nonisolated static func result(for release: Release, installed: String,
                                   os: OperatingSystemVersion) -> Result {
        let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        guard latest.compare(installed, options: .numeric) == .orderedDescending else {
            return .upToDate(version: installed)
        }
        // A release this Mac cannot run is not an update for it: its DMG would
        // replace a working app with one that will not open.
        if let minimum = minimumMacOS(inReleaseNotes: release.body), !runs(on: os, given: minimum) {
            return .needsNewerMacOS(version: latest, minimum: describe(minimum), installed: installed)
        }
        let releaseURL = URL(string: release.htmlUrl) ?? releasesURL
        let downloadURL = release.assets.first(where: { $0.name.hasSuffix(".dmg") })
            .flatMap { URL(string: $0.browserDownloadUrl) }
            ?? releaseURL
        return .available(AvailableUpdate(version: latest, downloadURL: downloadURL, releaseURL: releaseURL))
    }

    func check() async -> Result {
        do {
            var request = URLRequest(url: Self.apiURL, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

            let (data, response) = try await urlSession.data(for: request)

            switch (response as? HTTPURLResponse)?.statusCode {
            case 200:
                break
            case 404:
                // What /releases/latest answers while a repo has no release.
                return .error("Gearbox has no published release yet.")
            default:
                return .error("Could not reach GitHub. Check your internet connection.")
            }

            let release = try JSONDecoder().decode(Release.self, from: data)
            return Self.result(for: release, installed: Self.installedVersion,
                               os: ProcessInfo.processInfo.operatingSystemVersion)
        } catch {
            return .error(error.localizedDescription)
        }
    }
}

/// When the quiet check may ask GitHub, and which update you already said
/// Not Now to. Both live in the store Gearbox keeps its settings in, which is
/// `UserDefaults.app`: Gearbox's own domain, and a scratch suite under tests
/// and in a --snapshot run, so neither ever writes a throttle date into the
/// real domain.
struct UpdateSchedule {
    static let lastCheckKey = "lastUpdateCheck"
    static let dismissedVersionKey = "dismissedUpdateVersion"
    /// Magic Backup Machine's figure. It had six hours, and a release cut the
    /// same afternoon was never offered: every launch fell inside the window
    /// the one before had opened. An hour still costs GitHub one of the sixty
    /// requests an hour it allows a caller without a token.
    static let cooldown: TimeInterval = 60 * 60

    let store: UserDefaults

    /// True when no check has concluded in the last hour. A date ahead of
    /// `now` counts as due, so a clock set back cannot stop the check.
    func isDue(at now: Date) -> Bool {
        guard let last = store.object(forKey: Self.lastCheckKey) as? Date else { return true }
        let elapsed = now.timeIntervalSince(last)
        return elapsed >= Self.cooldown || elapsed < 0
    }

    /// Records a check that concluded. A failed one records nothing: stamping
    /// it would let one request made offline hide a release for the hour.
    func record(_ result: UpdateChecker.Result, at now: Date) {
        if case .error = result { return }
        store.set(now, forKey: Self.lastCheckKey)
    }

    func isDismissed(_ version: String) -> Bool {
        store.string(forKey: Self.dismissedVersionKey) == version
    }

    func dismiss(_ version: String) {
        store.set(version, forKey: Self.dismissedVersionKey)
    }
}

/// What a check found, said in an alert. Not Now on an update records that
/// version as dismissed, so the quiet check does not offer it again; the
/// sidebar still names it.
@MainActor
enum UpdateAlert {
    static func show(_ result: UpdateChecker.Result, schedule: UpdateSchedule) {
        NSApp.activate()
        let alert = NSAlert()
        switch result {
        case .upToDate(let version):
            alert.messageText = "You're up to date"
            alert.informativeText = "Gearbox \(version) is the latest version."
            alert.addButton(withTitle: "OK")
            alert.runModal()

        case .available(let update):
            alert.messageText = "Update Available"
            alert.informativeText = "Gearbox \(update.version) is available. You have \(UpdateChecker.installedVersion)."
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Release Notes")
            alert.addButton(withTitle: "Not Now")
            switch alert.runModal() {
            case .alertFirstButtonReturn: NSWorkspace.shared.open(update.downloadURL)
            case .alertSecondButtonReturn: NSWorkspace.shared.open(update.releaseURL)
            default: schedule.dismiss(update.version)
            }

        case .needsNewerMacOS(let version, let minimum, let installed):
            alert.messageText = "Gearbox \(version) needs macOS \(minimum)"
            alert.informativeText = "This Mac has macOS \(UpdateChecker.describe(ProcessInfo.processInfo.operatingSystemVersion)), "
                + "so Gearbox \(installed) is the newest version it can run."
            alert.addButton(withTitle: "OK")
            alert.runModal()

        case .error(let message):
            alert.messageText = "Update Check Failed"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

extension AppModel {
    /// Checks, and says what the check found when there is something to say.
    func checkForUpdatesAndTell(quietly: Bool) async {
        guard let result = await checkForUpdates(quietly: quietly) else { return }
        UpdateAlert.show(result, schedule: updateSchedule)
    }
}
