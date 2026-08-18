import Foundation
import Observability

// ─────────────────────────────────────────────────────────────
// Sidecars that die when this process does, even when nobody asked politely
// (U17, AUDIT F-3).
//
// `applicationShouldTerminate` covers ⌘Q and nothing else. A run killed with
// SIGTERM — `pkill`, a stopped `swift test`, Xcode's stop button, a crash
// during MLX work — left `surreal` alive, ~200 MB each. Eleven of them were
// found alive hours later on a 16 GB machine, and the symptom was not "orphans":
// it was P5.3 reporting that there was no memory for the model, which reads as a
// code problem and is not one.
//
// macOS has no `PR_SET_PDEATHSIG`, so the child cannot be told to follow its
// parent. What it does have is dispatch signal sources, which run on a queue
// rather than in a signal handler and may therefore do real work. That covers
// every terminating signal a person or a tool sends. It cannot cover SIGKILL —
// nothing can — and that case stays with the pid-file reaping at next launch.
// ─────────────────────────────────────────────────────────────

/// Process-wide record of the children to take down, and the signal sources
/// that take them down.
///
/// Deliberately not on `SidecarManager`: this has to work while that actor is
/// busy waiting on a health probe, which is exactly when a person gives up and
/// presses Ctrl-C.
public enum SidecarReaper {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var children: [String: Int32] = [:]
    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []
    nonisolated(unsafe) private static var installed = false
    private static let log = AppLog.logger("sidecar-reaper")

    /// The signals a person or a tool actually sends. SIGKILL is absent because
    /// it cannot be caught, not because it was forgotten.
    private static let handled: [Int32] = [SIGTERM, SIGINT, SIGHUP, SIGQUIT]

    public static func register(id: String, pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        children[id] = pid
    }

    public static func forget(id: String) {
        lock.lock(); defer { lock.unlock() }
        children.removeValue(forKey: id)
    }

    /// Installs the handlers once. Safe to call from every entry point — the
    /// app, and any test or check executable that starts a sidecar.
    public static func install() {
        lock.lock()
        guard !installed else { lock.unlock(); return }
        installed = true
        lock.unlock()

        for number in handled {
            // The default disposition has to go first, or the process dies
            // before the source ever runs.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number,
                                                         queue: .global(qos: .userInitiated))
            source.setEventHandler {
                terminateChildren(because: number)
                // Then die the way the sender asked. Restoring the default and
                // re-raising keeps the exit status honest: a process that
                // swallows SIGTERM to be tidy is a process that hangs in every
                // script that expects it to stop.
                signal(number, SIG_DFL)
                raise(number)
            }
            source.resume()
            sources.append(source)
        }
    }

    /// Sends every registered child SIGTERM, then SIGKILL to whatever is left.
    ///
    /// Synchronous on purpose: it runs while the process is on its way out, and
    /// anything asynchronous here is a promise that will not be kept.
    public static func terminateChildren(because signalNumber: Int32? = nil) {
        lock.lock()
        let pids = children
        children.removeAll()
        lock.unlock()
        guard !pids.isEmpty else { return }

        if let signalNumber {
            log.warning("signal \(signalNumber, privacy: .public) — เก็บ sidecar \(pids.count, privacy: .public) ตัว")
        }
        for (_, pid) in pids where pid > 0 {
            kill(pid, SIGTERM)
        }
        // A short grace period, then no more asking. 300 ms is what
        // `reapOrphan` already waits for the same binary.
        usleep(300_000)
        for (_, pid) in pids where pid > 0 {
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    /// For tests: what is currently registered.
    public static var registered: [String: Int32] {
        lock.lock(); defer { lock.unlock() }
        return children
    }
}
