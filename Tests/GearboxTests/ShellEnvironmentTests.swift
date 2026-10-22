import XCTest
@testable import Gearbox

final class ShellEnvironmentTests: XCTestCase {
    private func dump(_ entries: [String], noise: String = "", trailer: String = "") -> Data {
        var data = Data(noise.utf8)
        data.append(Data(ShellEnvironment.startMarker.utf8))
        for entry in entries {
            data.append(Data(entry.utf8))
            data.append(0)
        }
        data.append(Data(ShellEnvironment.endMarker.utf8))
        data.append(Data(trailer.utf8))
        return data
    }

    func testReadsBetweenTheMarkersOnly() {
        let env = ShellEnvironment.parse(dump(
            ["HOME=/Users/x", "PATH=/Users/x/bin:/usr/bin"],
            noise: "oh-my-zsh says hello\nPATH=/wrong\n",
            trailer: "\nlate output"))
        XCTAssertEqual(env, ["HOME": "/Users/x", "PATH": "/Users/x/bin:/usr/bin"])
    }

    func testKeepsNewlinesAndEqualsSignsInValues() {
        let env = ShellEnvironment.parse(dump(["MULTI=one\ntwo", "EQ=a=b=c"]))
        XCTAssertEqual(env?["MULTI"], "one\ntwo")
        XCTAssertEqual(env?["EQ"], "a=b=c")
    }

    func testNoMarkersIsNoEnvironment() {
        XCTAssertNil(ShellEnvironment.parse(Data("PATH=/usr/bin\0".utf8)))
        var startOnly = Data(ShellEnvironment.startMarker.utf8)
        startOnly.append(Data("PATH=/usr/bin\0".utf8))
        XCTAssertNil(ShellEnvironment.parse(startOnly))
    }

    func testTheFallbackPutsBinAndHomebrewFirst() {
        let env = ShellEnvironment.fallback(base: ["HOME": "/Users/x", "PATH": "/usr/bin:/bin"],
                                            home: "/Users/x")
        XCTAssertEqual(env["HOME"], "/Users/x")
        XCTAssertTrue(env["PATH"]!.hasPrefix("/Users/x/bin:/opt/homebrew/bin:"))
    }

    /// The real thing, with a shell that reads no dotfiles: the markers and
    /// `env -0` round-trip through Subprocess.
    func testCaptureRunsTheScript() async throws {
        let result = try await Subprocess.run(
            URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-f", "-c", ShellEnvironment.script],
            environment: ["GEARBOX_TEST": "yes\nreally", "PATH": "/usr/bin:/bin"],
            timeout: .seconds(10))
        let env = try XCTUnwrap(ShellEnvironment.parse(result.stdout))
        XCTAssertEqual(env["GEARBOX_TEST"], "yes\nreally")
    }
}
