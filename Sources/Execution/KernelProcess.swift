import Foundation
import Darwin

// ─────────────────────────────────────────────────────────────
// A child that stays (ARCHITECTURE §13, "stdin piping สำหรับ notebook kernel").
//
// `ProcessRegistry.run` is built for commands: it writes stdin, closes it, and
// waits. A notebook kernel is the opposite shape — it outlives every cell, and
// closing its stdin is how it is told to quit. So this is a second, smaller
// thing next to the registry rather than a flag on it: one request in, one
// framed response out, for as long as the kernel lives.
//
// The three details that are easy to get wrong and expensive to debug:
//
//  • **SIGPIPE.** Writing to a kernel that has just died raises SIGPIPE, whose
//    default action kills *us*. Ignored once, process-wide, so a dead kernel is
//    an error value instead of the app disappearing.
//  • **Framing is by line, and the reader never blocks a cooperative thread.**
//    A dedicated thread reads the pipe; waiters are continuations resumed under
//    a lock, with the timeout resolved by the same lock so a late line and an
//    expiring wait cannot both resume.
//  • **Its own process group**, inherited from `Spawn` — an interrupt or a kill
//    reaches whatever the kernel itself started.
// ─────────────────────────────────────────────────────────────

public final class KernelProcess: @unchecked Sendable {
    private let child: SpawnedChild
    private let lock = NSLock()
    private var pending: [String] = []
    private var buffer = Data()
    private var stderrText = ""
    private var waiter: (id: UUID, continuation: CheckedContinuation<String?, Never>)?
    private var closed = false
    private var exited = false
    private var stdinOpen = true

    /// Ignoring SIGPIPE is process-wide and idempotent; doing it here means
    /// nobody has to remember to do it before writing to a kernel.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    public var pid: pid_t { child.pid }

    /// False once the child has exited or been terminated. A kernel that died
    /// on its own — a segfaulting native extension, an `os._exit()` in a cell —
    /// has to be visible as dead rather than as a call that never answers.
    public var isRunning: Bool { lock.withLock { !exited && !closed } }

    public init(executable: String,
                arguments: [String] = [],
                workingDirectory: URL? = nil,
                environmentOverrides: [String: String] = [:]) throws {
        _ = Self.ignoreSIGPIPE
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ExecutionError.executableMissing(executable)
        }
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in environmentOverrides { environment[key] = value }
        do {
            child = try Spawn.launch(executable: executable,
                                     arguments: arguments,
                                     workingDirectory: workingDirectory?
                                        .path(percentEncoded: false),
                                     environment: environment)
        } catch {
            throw ExecutionError.launchFailed("\(error)")
        }
        startReader()
        startErrorReader()
        startWait()
    }

    // MARK: - talking to it

    /// Sends one request line. Appends the newline itself, because the framing
    /// is this class's promise, not the caller's.
    public func send(_ line: String) throws {
        var data = Data(line.utf8)
        data.append(0x0a)
        let alive = lock.withLock { !exited && stdinOpen }
        guard alive else { throw ExecutionError.notLive("kernel") }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(child.stdinFD,
                                           raw.baseAddress!.advanced(by: offset),
                                           raw.count - offset)
                if written > 0 { offset += written; continue }
                if written < 0 && errno == EINTR { continue }
                // EPIPE: the kernel is gone. Reported, not signalled.
                throw ExecutionError.notLive("kernel")
            }
        }
    }

    /// The next complete line of stdout, or nil if the wait ran out or the
    /// kernel closed its output.
    ///
    /// Nil is deliberately not an error: "the cell is still running" and "the
    /// kernel died" are different situations for the caller, and it can tell
    /// them apart with `isRunning`.
    public func nextLine(timeout: Duration) async -> String? {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            lock.lock()
            if !pending.isEmpty {
                let line = pending.removeFirst()
                lock.unlock()
                continuation.resume(returning: line)
                return
            }
            if closed || exited {
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            waiter = (id, continuation)
            lock.unlock()

            let milliseconds = Int(timeout.components.seconds * 1_000
                + timeout.components.attoseconds / 1_000_000_000_000_000)
            DispatchQueue.global(qos: .utility)
                .asyncAfter(deadline: .now() + .milliseconds(max(1, milliseconds))) { [self] in
                    lock.lock()
                    guard let waiting = waiter, waiting.id == id else { lock.unlock(); return }
                    waiter = nil
                    lock.unlock()
                    waiting.continuation.resume(returning: nil)
                }
        }
    }

    /// Everything the kernel has written to stderr so far. Kept because a
    /// kernel that fails to start says why there and nowhere else.
    public func errorOutput() -> String { lock.withLock { stderrText } }

    // MARK: - control

    /// SIGINT to the group — the signal a Python kernel turns into
    /// `KeyboardInterrupt`, so a runaway cell can be stopped without losing the
    /// variables the previous twenty cells built up.
    public func interrupt() {
        Spawn.signalGroup(child.pid, SIGINT)
    }

    /// Closes stdin, then SIGTERMs and SIGKILLs the group. Safe to call twice.
    public func terminate() {
        let shouldClose: Bool = lock.withLock {
            guard !closed else { return false }
            closed = true
            if stdinOpen { stdinOpen = false; return true }
            return false
        }
        if shouldClose { close(child.stdinFD) }
        Spawn.signalGroup(child.pid, SIGCONT)
        Spawn.signalGroup(child.pid, SIGTERM)
        let pid = child.pid
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            Spawn.signalGroup(pid, SIGKILL)
        }
        // Anyone waiting on a line is told now rather than at their timeout.
        resumeWaiter(with: nil)
    }

    /// A kernel nobody holds any more is a kernel nobody can stop — §13's rule
    /// that nothing we start outlives us applies to the ones we simply forget.
    deinit { terminate() }

    // MARK: - plumbing

    private func startReader() {
        Thread.detachNewThread { [self] in
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = read(child.stdoutFD, &chunk, chunk.count)
                if count > 0 {
                    deliver(Data(chunk[0..<count]))
                } else if count == 0 || errno != EINTR {
                    close(child.stdoutFD)
                    lock.withLock { closed = true }
                    resumeWaiter(with: nil)
                    return
                }
            }
        }
    }

    private func startErrorReader() {
        Thread.detachNewThread { [self] in
            var chunk = [UInt8](repeating: 0, count: 8 * 1024)
            while true {
                let count = read(child.stderrFD, &chunk, chunk.count)
                if count > 0 {
                    let text = String(decoding: chunk[0..<count], as: UTF8.self)
                    lock.withLock { stderrText += text }
                } else if count == 0 || errno != EINTR {
                    close(child.stderrFD)
                    return
                }
            }
        }
    }

    private func startWait() {
        Thread.detachNewThread { [self] in
            var status: Int32 = 0
            while waitpid(child.pid, &status, 0) < 0 && errno == EINTR {}
            lock.withLock { exited = true }
            resumeWaiter(with: nil)
        }
    }

    private func deliver(_ data: Data) {
        var ready: [String] = []
        lock.lock()
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            ready.append(String(decoding: line, as: UTF8.self))
        }
        pending.append(contentsOf: ready)
        let waiting = pending.isEmpty ? nil : waiter
        if waiting != nil { waiter = nil }
        let next = waiting != nil ? pending.removeFirst() : nil
        lock.unlock()
        waiting?.continuation.resume(returning: next)
    }

    private func resumeWaiter(with line: String?) {
        lock.lock()
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.continuation.resume(returning: line)
    }
}
