import Foundation

struct ProcessResult: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: Data
    /// True when the watchdog stopped the process.
    var timedOut: Bool

    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// Runs a program to completion, with stdin from /dev/null, and returns what
/// it wrote.
///
/// Dipstick's Subprocess, with the pipe readers of Barkeep's ScriptProcess.
/// stdin is /dev/null: mrk's scripts ask through gum and `read </dev/tty` when
/// they think a person is there, and a program that waits on a terminal
/// Gearbox does not have would never finish. Each pipe is read to its end on a
/// thread of its own while the program runs, so output larger than a pipe
/// buffer cannot stall it. After `timeout` the program gets SIGTERM, which
/// mrk's scripts trap to delete their temp files.
enum Subprocess {
    static func run(
        _ executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: Duration,
        drainGrace: Duration = .seconds(2)
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let (exits, exitContinuation) = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = { finished in
            exitContinuation.yield(finished.terminationStatus)
            exitContinuation.finish()
        }

        try process.run()
        let pid = process.processIdentifier

        // The readers start on threads of their own at once, not as tasks: on
        // a busy machine a task can wait for a thread, and output the program
        // wrote would then be missed by the grace below. Barkeep's CI found
        // that on 2026-10-18.
        let out = Collector()
        let err = Collector()
        let readers = DispatchGroup()
        read(outPipe.fileHandleForReading, into: out, group: readers)
        read(errPipe.fileHandleForReading, into: err, group: readers)

        let watchdog = Task.detached { () -> Bool in
            do { try await Task.sleep(for: timeout) } catch { return false }
            kill(pid, SIGTERM)
            return true
        }

        var status: Int32 = -1
        for await code in exits { status = code }
        watchdog.cancel()
        // A child the program started, such as osascript under a stopped
        // sync-login-items, can keep the pipes open after the program is gone.
        // Wait a little for the rest of the output, never for that child.
        await wait(for: readers, atMost: drainGrace)

        return ProcessResult(status: status, stdout: out.data, stderr: err.data,
                             timedOut: await watchdog.value)
    }

    /// Returns when every reader in `group` is done, or after `limit`,
    /// whichever is first. A reader still blocked then goes on by itself.
    private static func wait(for group: DispatchGroup, atMost limit: Duration) async {
        let (seconds, attoseconds) = limit.components
        let deadline = DispatchTime.now() + Double(seconds) + Double(attoseconds) / 1e18
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let once = Once()
            group.notify(queue: .global(qos: .userInitiated)) {
                if once.claim() { done.resume() }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: deadline) {
                if once.claim() { done.resume() }
            }
        }
    }

    /// Reads a pipe to its end on a thread of its own: `availableData` blocks,
    /// and a blocked thread must not be one of Swift's cooperative pool.
    private static func read(_ handle: FileHandle, into collector: Collector, group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                collector.append(chunk)
            }
            group.leave()
        }
    }
}

/// True for the first caller only.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Every byte of one stream, appended from a reader thread.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var all = Data()

    var data: Data {
        lock.lock(); defer { lock.unlock() }
        return all
    }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        all.append(chunk)
    }
}
