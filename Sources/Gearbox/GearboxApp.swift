import AppKit
import SwiftUI

let appVersion = "0.5"

/// Decides, before anything else runs, whether this launch is the app or only
/// a host for tests, as the sibling apps' AppLauncher does.
///
/// `swift test` links this module into the test runner and never calls
/// main(), so today nothing launches the app under a test. The guard is here
/// from the start all the same: Gearbox stores settings of its own (the pane
/// it shows, the defaults filter, the update check's dates), SwiftUI records
/// its window frames, and a test run must never touch the developer's real
/// ones.
#if !TESTING
@main
#endif
enum AppLauncher {
    static func main() {
        if isHostingTests {
            TestHostApp.main()
        } else {
            GearboxApp.main()
        }
    }

    /// XCTest is already loaded when main() runs in a test host, and is never
    /// linked into the app itself.
    static let isHostingTests =
        NSClassFromString("XCTestCase") != nil
        || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
}

/// A scene with no window: while the app hosts tests, nothing of the real app
/// is built.
private struct TestHostApp: App {
    var body: some Scene {
        Settings { EmptyView() }
    }
}

extension UserDefaults {
    /// Where Gearbox keeps what it stores in defaults: its own domain, except
    /// under tests and in a --snapshot run, where it is a scratch suite named
    /// by a path in the temporary folder. A path keeps the file out of
    /// ~/Library/Preferences, where snapshot-prefs exports every
    /// io.github.sevmorris.* domain. Nothing in the app names `.standard`; it
    /// goes through here.
    static let app: UserDefaults = {
        let scratch: String?
        if AppLauncher.isHostingTests {
            scratch = "io.github.sevmorris.Gearbox.tests"
        } else if Snapshot.directory(in: CommandLine.arguments) != nil {
            scratch = "io.github.sevmorris.Gearbox.snapshot"
        } else {
            scratch = nil
        }
        guard let scratch else { return .standard }
        return UserDefaults(suiteName: FileManager.default.temporaryDirectory
            .appendingPathComponent(scratch).path)!
    }()
}

struct GearboxApp: App {
    @State private var model = AppModel.live()

    init() {
        // Before any window opens, so the snapshot can put the domain back.
        if Snapshot.directory(in: CommandLine.arguments) != nil { Snapshot.saveDomain() }
    }

    var body: some Scene {
        Window("Gearbox", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 900, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
                .task {
                    if let dir = Snapshot.directory(in: CommandLine.arguments) {
                        let written = await Snapshot.write(model: model, to: dir)
                        exit(written ? 0 : 1)
                    }
                    // The quiet update check: now, and each time Gearbox comes
                    // to the front, which the schedule holds to one request an
                    // hour. A check at launch alone misses the case Magic
                    // Backup Machine found: the window stays open, a release
                    // is cut, and the app never looks again.
                    await model.checkForUpdatesAndTell(quietly: true)
                    let activations = NotificationCenter.default.notifications(
                        named: NSApplication.didBecomeActiveNotification
                    ).map { _ in () }
                    for await _ in activations {
                        await model.checkForUpdatesAndTell(quietly: true)
                    }
                }
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await model.checkForUpdatesAndTell(quietly: false) }
                }
            }
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("Refresh") {
                    if let pane = model.selection { Task { await model.load(pane) } }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
