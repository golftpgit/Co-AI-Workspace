import Foundation
import Darwin

// ─────────────────────────────────────────────────────────────
// A child whose pipes somebody else reads (ARCHITECTURE §13, P8.3).
//
// `ProcessRegistry.run` owns a command from start to exit, and `KernelProcess`
// owns a long-lived child *and* its framing. An MCP server is the third shape:
// it lives as long as the app does, but the framing belongs to the MCP SDK's
// transport, which wants file descriptors. So this type does the part §13 says
// only this module may do — spawn into its own process group, with the sandbox
// rules and signal dispositions `Spawn` sets — and then hands the descriptors
// out and stays out of the way.
//
// **Ownership of the descriptors is split, and the order matters.** The reader
// (the transport) must be stopped *before* `terminate()`, or it can be sitting
// in a `read` on a descriptor this closes. `MCPConnection.disconnect` does it
// in that order, and it is the only caller.
//
// stderr is the exception: nobody else wants it, and an MCP server that fails
// to start says why there and nowhere else — so it is drained here and kept.
// ─────────────────────────────────────────────────────────────

public final class PipedChild: @unchecked Sendable {
    private let child: SpawnedChild
    private let lock = NSLock()
    private var stderrText = ""
    private var exited = false
    private var stdinOpen = true
    private var readClosed = false

    /// Process-wide and idempotent, for the same reason `KernelProcess` does
    /// it: writing to a server that has just died must be an error value, not
    /// a signal that kills the app.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    public var pid: pid_t { child.pid }

    /// Where the child's replies come out. The caller reads this and must not
    /// close it — `terminate()` does, once the child has been reaped.
    public var outputDescriptor: Int32 { child.stdoutFD }

    /// Where requests go in.
    public var inputDescriptor: Int32 { child.stdinFD }

    public var isRunning: Bool { lock.withLock { !exited } }

    /// Returns once the child is gone.
    ///
    /// Polled rather than pushed: the `waitpid` that knows this runs on its
    /// own thread, and handing a continuation across it would be a second
    /// piece of concurrency in a file whose whole job is to keep the first one
    /// simple. 50ms is far below any human-visible delay and this is only ever
    /// awaited while something is being waited for anyway.
    public func waitForExit() async {
        while isRunning {
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return }
        }
    }

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
        startErrorReader()
        startWait()
    }

    /// Everything the child has written to stderr. A server that exits during
    /// the handshake leaves its reason here, and a timeout that reports only
    /// "no response" throws that reason away.
    public func standardErrorText() -> String { lock.withLock { stderrText } }

    /// Closes stdin — which is how the stdio transport tells a server to quit —
    /// then signals the group. Safe to call twice.
    ///
    /// Call this *after* whoever is reading `outputDescriptor` has stopped.
    public func terminate() {
        let (closeInput, closeOutput): (Bool, Bool) = lock.withLock {
            let input = stdinOpen
            let output = !readClosed
            stdinOpen = false
            readClosed = true
            return (input, output)
        }
        guard closeInput || closeOutput else { return }
        // Both descriptors go back here rather than on a delay: the contract
        // above is that the reader has already stopped, and a descriptor freed
        // "in two seconds" is a descriptor number another thread can be handed
        // in the meantime.
        if closeInput { close(child.stdinFD) }
        if closeOutput { close(child.stdoutFD) }

        Spawn.signalGroup(child.pid, SIGCONT)
        Spawn.signalGroup(child.pid, SIGTERM)
        let pid = child.pid
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            Spawn.signalGroup(pid, SIGKILL)
        }
    }

    /// §13's rule — nothing we start outlives us — applied to the ones nobody
    /// holds any more.
    deinit { terminate() }

    // MARK: - plumbing

    private func startErrorReader() {
        Thread.detachNewThread { [self] in
            var chunk = [UInt8](repeating: 0, count: 8 * 1024)
            while true {
                let count = read(child.stderrFD, &chunk, chunk.count)
                if count > 0 {
                    let text = String(decoding: chunk[0..<count], as: UTF8.self)
                    // Bounded: a server that logs a line per request must not
                    // turn a diagnostic into a memory leak.
                    lock.withLock {
                        stderrText += text
                        if stderrText.count > 64 * 1024 {
                            stderrText = String(stderrText.suffix(32 * 1024))
                        }
                    }
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
        }
    }
}
