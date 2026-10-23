// Shared verbatim across the sibling app repos (Gearbox, Dipstick). Keep the
// copies byte-identical: scripts/check-shared.sh compares them and a release
// preflight fails when they drift. Anything one app needs on its own belongs
// in that app's files, not here.

import Darwin
import Foundation

/// Runs a program on a pseudo-terminal of its own, as a terminal window runs
/// it, and hands back what it prints as it prints it.
///
/// What the console runs asks questions: mrk-push's commit message, the
/// secret scan before a commit, lib.sh's confirm, which tests `[[ -t 0 ]]`
/// and then reads `</dev/tty`, and sudo's password. A pipe answers none of
/// them, so the program gets a terminal. forkpty makes the
/// pair, starts a session, and makes the terminal the session's controlling
/// terminal, which /dev/tty needs. posix_spawn cannot do the last part on
/// macOS: a child spawned with POSIX_SPAWN_SETSID that opens the terminal
/// still has no controlling terminal, and /dev/tty answers "device not
/// configured" (tried on 2026-10-22, opened in the file actions and by the
/// child itself).
///
/// The master is read the whole time the program runs. On macOS the last
/// close of the terminal waits a while for its output to be read and then
/// throws the rest away, so output read only after the program exits is
/// lost: a test that waited for the exit and then read got nothing at all.
final class PseudoTerminal: @unchecked Sendable {
    enum Event: Equatable, Sendable {
        case output(Data)
        /// The exit status as a shell gives it: the program's code, or 128
        /// and the number of the signal that ended it.
        case exit(Int32)
    }

    let pid: pid_t
    private let lock = NSLock()
    /// The master side, or -1 once it is closed.
    private var master: Int32
    /// Set when the program has exited, before it is reaped: from then on its
    /// pid can become another process's, so nothing is sent to it.
    private var exited = false

    private init(pid: pid_t, master: Int32) {
        self.pid = pid
        self.master = master
    }

    /// Starts `executable` with `arguments` in `directory`, on a terminal of
    /// `columns` × `rows`. The stream yields the output as it comes, then the
    /// exit, and ends. Once the program has exited, its output is read for
    /// `drainGrace` at most: a child it left in the background can hold the
    /// terminal open for ever.
    static func start(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String],
        directory: String,
        columns: UInt16 = 80,
        rows: UInt16 = 24,
        drainGrace: Duration = .seconds(2)
    ) throws -> (PseudoTerminal, AsyncStream<Event>) {
        // Between fork and exec the child of a threaded process may make only
        // async-signal-safe calls, and allocating is not one. So everything
        // it needs is made here, and it touches only raw pointers.
        let argv = CStringArray([executable] + arguments)
        let envp = CStringArray(environment.keys.sorted().map { "\($0)=\(environment[$0]!)" })
        // The child's errors name the app, as a shell's name the shell:
        // "gearbox: cannot enter …".
        let name = ProcessInfo.processInfo.processName.lowercased()
        let strings = CStringArray([directory, "\(name): cannot enter \(directory)\r\n",
                                    "\(name): cannot run \(executable)\r\n"])
        let (argvPointer, envpPointer) = (argv.pointer, envp.pointer)
        let (dir, noDir, noExec) = (strings.pointer[0]!, strings.pointer[1]!, strings.pointer[2]!)
        let (noDirLength, noExecLength) = (strlen(noDir), strlen(noExec))
        let openMax = getdtablesize()
        var defaultAction = sigaction()
        var noSignals = sigset_t()
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        var fd: Int32 = -1

        let pid = forkpty(&fd, nil, nil, &size)
        if pid == 0 {
            // The child. The terminal is its stdin, stdout and stderr, and its
            // controlling terminal. None of the app's other files goes with it.
            var other: Int32 = 3
            while other < openMax {
                close(other)
                other += 1
            }
            // And the signals are as a terminal's shell has them. The child
            // keeps the mask of the thread that forked, and a GCD thread
            // blocks SIGINT, so ⌃C would wait for ever; exec keeps whatever
            // the app ignores.
            var signal: Int32 = 1
            while signal < NSIG {
                _ = sigaction(signal, &defaultAction, nil)
                signal += 1
            }
            _ = sigprocmask(SIG_SETMASK, &noSignals, nil)
            if chdir(dir) != 0 {
                _ = Darwin.write(2, noDir, noDirLength)
                _exit(126)
            }
            execve(argvPointer[0], argvPointer, envpPointer)
            _ = Darwin.write(2, noExec, noExecLength)
            _exit(127)
        }
        withExtendedLifetime((argv, envp, strings)) {}
        guard pid > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        // Not for the programs the app starts later: a check mode or an
        // mrk-status that held the master would keep the terminal open.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let terminal = PseudoTerminal(pid: pid, master: fd)
        let (events, continuation) = AsyncStream.makeStream(of: Event.self)
        terminal.watch(fd, continuation, drainGrace: drainGrace)
        return (terminal, events)
    }

    /// Reads the master until nothing holds the terminal open, and waits for
    /// the exit. Both end on one queue, so the exit always comes after the
    /// last output.
    private func watch(_ fd: Int32, _ continuation: AsyncStream<Event>.Continuation, drainGrace: Duration) {
        let queue = DispatchQueue(label: "\(Bundle.main.bundleIdentifier ?? "app").PseudoTerminal")
        let ending = Ending(continuation)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n > 0 {
                    continuation.yield(.output(Data(buffer[0..<n])))
                } else if n < 0 && errno == EINTR {
                    continue
                } else if n < 0 && errno == EAGAIN {
                    return
                } else {
                    // 0 or EIO: the program and everything it started have
                    // closed the terminal.
                    source.cancel()
                    return
                }
            }
        }
        source.setCancelHandler { [self] in
            closeMaster()
            ending.readerDone = true
        }
        source.resume()

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            // Waits without reaping, so that the pid stays this program's
            // until `exited` says to leave it alone.
            var info = siginfo_t()
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0 && errno == EINTR {}
            lock.withLock { exited = true }
            var raw: Int32 = 0
            var reaped: pid_t
            repeat { reaped = waitpid(pid, &raw, 0) } while reaped < 0 && errno == EINTR
            let status = reaped == pid ? Self.shellStatus(raw) : -1
            queue.async {
                ending.status = status
                if !ending.readerDone {
                    queue.asyncAfter(deadline: .now() + drainGrace.timeInterval) { source.cancel() }
                }
            }
        }
    }

    /// Types `bytes` at the terminal, as keys pressed in it. False when the
    /// terminal is closed, or will not take them all.
    @discardableResult
    func write(_ bytes: [UInt8]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard master >= 0 else { return false }
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
            if n > 0 {
                offset += n
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    /// Sends `signal` to the program's process group, which is the program
    /// and what it started, make and the script under it: what ⌃C in a
    /// terminal reaches. Nothing once the program has exited.
    func send(signal: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard !exited else { return }
        kill(-pid, signal)
    }

    private func closeMaster() {
        lock.lock()
        defer { lock.unlock() }
        guard master >= 0 else { return }
        close(master)
        master = -1
    }

    /// A wait status as a shell reports it.
    static func shellStatus(_ raw: Int32) -> Int32 {
        let signal = raw & 0x7F
        return signal == 0 ? (raw >> 8) & 0xFF : 128 + signal
    }
}

/// The two halves of an ending, the last read and the exit, which come in
/// either order. Touched on the terminal's queue only.
private final class Ending: @unchecked Sendable {
    private let continuation: AsyncStream<PseudoTerminal.Event>.Continuation
    private var finished = false
    var readerDone = false { didSet { finish() } }
    var status: Int32? { didSet { finish() } }

    init(_ continuation: AsyncStream<PseudoTerminal.Event>.Continuation) {
        self.continuation = continuation
    }

    private func finish() {
        guard readerDone, let status, !finished else { return }
        finished = true
        continuation.yield(.exit(status))
        continuation.finish()
    }
}

/// NULL-terminated C strings, made before a fork and freed by the parent.
private final class CStringArray {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        pointer = .allocate(capacity: strings.count + 1)
        for (i, string) in strings.enumerated() { pointer[i] = strdup(string) }
        pointer[strings.count] = nil
    }

    deinit {
        for i in 0..<count { free(pointer[i]) }
        pointer.deallocate()
    }
}

private extension Duration {
    var timeInterval: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
