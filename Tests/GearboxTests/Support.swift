import Foundation
import XCTest
@testable import Gearbox

/// Real output of mrk's scripts and the config/ files they read, from
/// Fixtures/, whose README says where each came from.
enum Fixture {
    static func text(_ path: String) throws -> String {
        let dir = try XCTUnwrap(Bundle.module.resourceURL).appendingPathComponent("Fixtures")
        return try String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8)
    }
}

/// A stand-in mrk checkout in a temporary folder. Its scripts are stubs: each
/// records how it was run in `calls.log`, then prints what its fixture files
/// hold and exits with the status they give. No test runs a real mrk script.
final class StubMrk {
    let dir: URL
    let root: URL
    var checkout: MrkCheckout { MrkCheckout(root: root) }
    var log: URL { dir.appendingPathComponent("calls.log") }

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GearboxTests-\(UUID().uuidString)", isDirectory: true)
        root = dir.appendingPathComponent("my mrk", isDirectory: true)
        for sub in ["scripts", "config", "docs/defaults", "fixtures"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(sub),
                                                    withIntermediateDirectories: true)
        }
        for script in MrkCheckout.scripts { try stub(script) }
        for file in ["config/defaults.tsv", "docs/defaults/descriptions.tsv", "config/app-prefs.tsv",
                     "config/login-items.txt", "config/dock.txt"] {
            try write(file, "")
        }
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    /// The stub for SCRIPT. It logs one line — the script, each argument in
    /// brackets, the directory it ran in and whether stdin reached EOF at
    /// once — then prints fixtures/<name>.out to stdout and .err to stderr,
    /// and exits with fixtures/<name>.status (0 when absent). <name> is the
    /// script's file name, then each argument, joined by "_".
    private func stub(_ script: String) throws {
        let text = """
        #!/bin/bash
        name="${0##*/}"; for a in "$@"; do name+="_$a"; done
        name=${name// /-}
        if IFS= read -r _; then stdin=data; else stdin=eof; fi
        { printf '%s' "\(script)"; printf ' [%s]' "$@"; printf ' cwd=%s stdin=%s\\n' "$PWD" "$stdin"; } >> "\(log.path)"
        f="\(root.path)/fixtures/$name"
        [[ -f "$f.out" ]] && cat "$f.out"
        [[ -f "$f.err" ]] && cat "$f.err" >&2
        [[ -f "$f.status" ]] && exit "$(cat "$f.status")"
        exit 0
        """
        let url = root.appendingPathComponent(script)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func write(_ path: String, _ text: String) throws {
        try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// What a run of SCRIPT with ARGS prints and exits with.
    func answer(_ script: String, _ args: [String], out: String = "", err: String = "", status: Int32 = 0) throws {
        let name = ([(script as NSString).lastPathComponent] + args).joined(separator: "_")
            .replacingOccurrences(of: " ", with: "-")
        try write("fixtures/\(name).out", out)
        try write("fixtures/\(name).err", err)
        try write("fixtures/\(name).status", "\(status)")
    }

    var calls: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    func runner() -> MrkRunner {
        MrkRunner(environment: { ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory()] })
    }

    /// A defaults suite of the test's own, named by a path in this folder,
    /// which goes when the folder does.
    func store() -> UserDefaults {
        UserDefaults(suiteName: dir.appendingPathComponent("defaults").path)!
    }
}
