import AppKit
import SwiftUI

/// `Gearbox --snapshot <directory>`: each pane in turn, loaded as the window
/// loads it, drawn into a PNG in the directory, and quit.
///
/// It draws the app's own window, not the pane hosted apart: Dipstick's
/// v0.1 snapshots hosted its view on its own and showed a layout the real
/// window never had. Each pane runs its real check against the checkout, so
/// this is also how to see Gearbox against a real mrk without clicking.
enum Snapshot {
    static func directory(in arguments: [String]) -> String? {
        guard let flag = arguments.firstIndex(of: "--snapshot"),
              flag + 1 < arguments.count else { return nil }
        return arguments[flag + 1]
    }

    /// The app's real domain as it was before the snapshot's window opened:
    /// nil when there was none. SwiftUI writes the window's frame and the
    /// split view's widths into it as the window opens, before the snapshot
    /// can stop it, and snapshot-prefs exports every io.github.sevmorris.*
    /// domain. So the snapshot puts the domain back as it found it.
    nonisolated(unsafe) private static var savedDomain: [String: Any]?
    nonisolated(unsafe) private static var savedDomainTaken = false

    static func saveDomain() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        savedDomain = UserDefaults.standard.persistentDomain(forName: id)
        savedDomainTaken = true
    }

    /// Key by key, through the app's own defaults: a key the run added goes,
    /// and one it changed gets its old value back. setPersistentDomain and
    /// removePersistentDomain left the window's keys in place on this Mac.
    static func restoreDomain() {
        guard savedDomainTaken, let id = Bundle.main.bundleIdentifier else { return }
        let before = savedDomain ?? [:]
        let now = UserDefaults.standard.persistentDomain(forName: id) ?? [:]
        for key in now.keys where before[key] == nil {
            UserDefaults.standard.removeObject(forKey: key)
        }
        for (key, value) in before where !(now[key].map { ($0 as AnyObject).isEqual(value) } ?? false) {
            UserDefaults.standard.set(value, forKey: key)
        }
        UserDefaults.standard.synchronize()
    }

    static func fileName(_ pane: Pane, index: Int) -> String {
        "\(index + 1)-\(pane.rawValue).png"
    }

    @MainActor
    static func write(model: AppModel, to directory: String) async -> Bool {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        guard let window = await mainWindow() else {
            say("the window did not open")
            return false
        }
        // The size below is the snapshot's, not one to remember: SwiftUI would
        // save it, and the split view's widths, in the app's real domain.
        window.setFrameAutosaveName("")
        clearAutosave(in: window.contentView)
        // Now, as well as at the end, so snapshot-prefs --check in the first
        // pane does not find the keys the window just wrote.
        restoreDomain()
        window.setContentSize(NSSize(width: 1120, height: 720))

        var ok = true
        defer { restoreDomain() }
        for (i, pane) in Pane.allCases.enumerated() {
            model.selection = pane
            await model.load(pane)
            await settle(window)
            let url = dir.appendingPathComponent(fileName(pane, index: i))
            if capture(window, to: url) {
                say("wrote \(url.path), \(Int(window.frame.width))×\(Int(window.frame.height)) pt")
            } else {
                say("could not draw \(pane.title)")
                ok = false
            }
        }
        return await writeConsole(model: model, over: window, to: dir) && ok
    }

    static var consoleFileName: String { "\(Pane.allCases.count + 1)-console.png" }

    /// The console, last, running make dock's dry run, which reads
    /// config/dock.txt and changes nothing. The sheet is a window of its own,
    /// so it is drawn on its own.
    @MainActor
    private static func writeConsole(model: AppModel, over window: NSWindow, to dir: URL) async -> Bool {
        Task { await model.runInConsole(.dockDryRun) }
        var sheet: NSWindow?
        for _ in 0..<300 {
            if let attached = window.attachedSheet, model.console?.isRunning == false {
                sheet = attached
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let sheet else {
            say("the console did not finish make dock ARGS=-n in 30 s")
            return false
        }
        await settle(sheet)
        let url = dir.appendingPathComponent(consoleFileName)
        let drawn = capture(sheet, to: url)
        say(drawn ? "wrote \(url.path), \(Int(sheet.frame.width))×\(Int(sheet.frame.height)) pt"
                  : "could not draw the console")
        model.closeConsole()
        return drawn
    }

    @MainActor
    private static func clearAutosave(in view: NSView?) {
        guard let view else { return }
        if let split = view as? NSSplitView { split.autosaveName = nil }
        view.subviews.forEach(clearAutosave)
    }

    /// The app's window, once it is on screen.
    @MainActor
    private static func mainWindow() async -> NSWindow? {
        for _ in 0..<50 {
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.canBecomeMain }) {
                return window
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// SwiftUI lays a list out over more than one pass, so wait until the
    /// window has drawn the new pane and kept still for 0.5 s.
    @MainActor
    private static func settle(_ window: NSWindow) async {
        try? await Task.sleep(for: .milliseconds(600))
        var last = render(window)?.tiffRepresentation
        var steady = 0
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(250))
            let now = render(window)?.tiffRepresentation
            steady = now == last ? steady + 1 : 0
            last = now
            if steady == 2 { return }
        }
    }

    /// The whole window, title bar and toolbar included: the view that holds
    /// the content view and the title bar.
    @MainActor
    private static func render(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    @MainActor
    private static func capture(_ window: NSWindow, to url: URL) -> Bool {
        guard let rep = render(window), let png = rep.representation(using: .png, properties: [:]) else {
            return false
        }
        return (try? png.write(to: url)) != nil
    }

    private static func say(_ text: String) {
        FileHandle.standardError.write(Data("gearbox: \(text)\n".utf8))
    }
}
