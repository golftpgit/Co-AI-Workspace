import Foundation
import Darwin
import AgentKit
import Observability

// ─────────────────────────────────────────────────────────────
// ProcessRegistry (ARCHITECTURE §13) — one place that knows about every
// running child, so pause/stop is a property of the system rather than of
// whichever agent happens to hold a handle.
//
// Two rules the design exists to guarantee:
//   • Stop actually stops. Signals go to the child's process group, so a
//     command that spawned children takes them with it.
//   • Nothing is left behind. Every child is reaped by a waitpid that runs
//     whether it exited, was killed or timed out — no zombies, and no
//     "finished" row for a process that is still alive.
// ─────────────────────────────────────────────────────────────

public actor ProcessRegistry {
    public struct Entry: Sendable, Identifiable, Equatable {
        public let id: String
        public let label: String
        public let command: String
        public let pid: pid_t
        public let conversationID: String?
        public let startedAt: Date
        public var state: ProcessState
    }

    private struct Live {
        var entry: Entry
        let control: ProcessControl
    }

    private var processes: [String: Live] = [:]
    private let sink: (any SpanSink)?
    private let log = AppLog.logger("execution")

    public init(spanSink: (any SpanSink)? = nil) {
        self.sink = spanSink
    }

    // MARK: - running

    /// Launches and waits. The process appears in `list()` for its whole life,
    /// including while this call is suspended, which is what makes pause/stop
    /// from another task possible.
    public func run(_ spec: ProcessSpec,
                    label: String,
                    conversationID: String? = nil,
                    parentSpan: SpanID? = nil,
                    onOutput: (@Sendable (OutputChunk) -> Void)? = nil) async throws -> ProcessOutcome {
        let (executable, arguments, sandboxApplied) = Self.resolve(spec)
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ExecutionError.executableMissing(executable)
        }

        var environment = ProcessInfo.processInfo.environment
        for (key, value) in spec.environmentOverrides { environment[key] = value }

        let child: SpawnedChild
        do {
            child = try Spawn.launch(
                executable: executable,
                arguments: arguments,
                workingDirectory: spec.workingDirectory?.path(percentEncoded: false),
                environment: environment)
        } catch {
            throw ExecutionError.launchFailed("\(error)")
        }

        let id = OpaqueID.make("px")
        let command = ([spec.executable] + spec.arguments).joined(separator: " ")
        let startedAt = Date()
        let control = ProcessControl(child: child, limit: spec.outputLimit, onOutput: onOutput)
        processes[id] = Live(entry: Entry(id: id, label: label, command: command,
                                          pid: child.pid, conversationID: conversationID,
                                          startedAt: startedAt, state: .running),
                             control: control)

        var span = Span(parent: parentSpan, name: "process:\(label)")
        await sink?.record(span)

        control.write(stdin: spec.stdin)
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: spec.timeout)
            guard !Task.isCancelled else { return }
            await self?.stop(id, reason: .timedOut)
        }

        let status = await control.waitForCompletion()
        timeoutTask.cancel()

        let requested = processes[id]?.control.requestedReason
        let reason = Self.reason(from: status, requested: requested)
        let exitCode = Self.exitCode(from: status, reason: reason)
        processes[id]?.entry.state = .finished(reason, exitCode: exitCode)

        let outcome = ProcessOutcome(exitCode: exitCode,
                                     stdout: control.stdoutText,
                                     stderr: control.stderrText,
                                     reason: reason,
                                     duration: Date().timeIntervalSince(startedAt),
                                     sandboxApplied: sandboxApplied,
                                     outputTruncated: control.truncated)

        span.status = outcome.succeeded ? .succeeded : (reason == .stoppedByUser ? .cancelled : .failed)
        span.endedAt = Date()
        span.detail = "exit \(exitCode) · \(reason.label) · \(String(format: "%.1fs", outcome.duration))"
            + (sandboxApplied ? " · sandboxed" : "")
        await sink?.record(span)
        log.info("\(label, privacy: .public) exit \(exitCode) (\(reason.label, privacy: .public))")

        // The registry tracks what is alive. History lives in the span stream,
        // which is the single source §16 asks for — not a second list here.
        processes.removeValue(forKey: id)
        return outcome
    }

    // MARK: - control

    /// SIGSTOP the group. The timeout is intentionally left running: a paused
    /// process the user forgets about should still not hold a turn open forever.
    public func pause(_ id: String) throws {
        guard let live = processes[id] else { throw ExecutionError.unknownProcess(id) }
        guard live.entry.state == .running else { throw ExecutionError.notLive(id) }
        Spawn.signalGroup(live.entry.pid, SIGSTOP)
        processes[id]?.entry.state = .paused
    }

    public func resume(_ id: String) throws {
        guard let live = processes[id] else { throw ExecutionError.unknownProcess(id) }
        guard live.entry.state == .paused else { throw ExecutionError.notLive(id) }
        Spawn.signalGroup(live.entry.pid, SIGCONT)
        processes[id]?.entry.state = .running
    }

    public func stop(_ id: String) { stop(id, reason: .stoppedByUser) }

    /// SIGTERM the group, then SIGKILL what is still there. A stopped process
    /// is continued first — SIGTERM to a SIGSTOPped process is queued, not
    /// delivered, which is how a "killed" process stays alive forever.
    private func stop(_ id: String, reason: TerminationReason) {
        guard let live = processes[id], live.entry.state.isLive else { return }
        live.control.requestedReason = reason
        let pid = live.entry.pid
        Spawn.signalGroup(pid, SIGCONT)
        Spawn.signalGroup(pid, SIGTERM)
        Task.detached {
            try? await Task.sleep(for: .seconds(3))
            // Harmless if the group is already gone: kill(2) just returns ESRCH.
            Spawn.signalGroup(pid, SIGKILL)
        }
    }

    public func stopAll() {
        for id in processes.keys { stop(id) }
    }

    // MARK: - inspection

    /// Everything alive right now, across every conversation — the Processes
    /// page (§14.2) is a filter over this, not a second source of truth.
    public func list() -> [Entry] {
        processes.values.map(\.entry).sorted { $0.startedAt < $1.startedAt }
    }

    public func live() -> [Entry] {
        list().filter { $0.state.isLive }
    }

    // MARK: - helpers

    /// Wraps the command in `sandbox-exec` when a profile is set and the OS
    /// will honour it, and reports which of the two happened.
    private static func resolve(_ spec: ProcessSpec) -> (String, [String], Bool) {
        guard let sandbox = spec.sandbox, SandboxProfile.isApplicable else {
            return (spec.executable, spec.arguments, false)
        }
        return (SandboxProfile.executable,
                ["-p", sandbox.profileText, spec.executable] + spec.arguments,
                true)
    }

    private static func reason(from status: Int32, requested: TerminationReason?) -> TerminationReason {
        if Self.wasSignalled(status) {
            // A signal we sent is reported as what we meant by it, so the UI
            // says "หมดเวลา" instead of "ถูกสัญญาณ 15".
            if let requested { return requested }
            return .signal(status & 0x7f)
        }
        return .exited
    }

    private static func wasSignalled(_ status: Int32) -> Bool { (status & 0x7f) != 0 }

    private static func exitCode(from status: Int32, reason: TerminationReason) -> Int32 {
        guard !wasSignalled(status) else { return 128 + (status & 0x7f) }
        return (status >> 8) & 0xff
    }
}

// ─────────────────────────────────────────────────────────────
// The per-process plumbing: pipe readers, stdin, and the waitpid that reaps.
// Deliberately not an actor — the reads and the wait are blocking calls that
// belong on Dispatch threads, not on the cooperative pool.
// ─────────────────────────────────────────────────────────────

final class ProcessControl: @unchecked Sendable {
    private let child: SpawnedChild
    private let limit: Int
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var didTruncate = false
    private var status: Int32 = 0
    private var reason: TerminationReason?
    private let group = DispatchGroup()

    init(child: SpawnedChild, limit: Int, onOutput: (@Sendable (OutputChunk) -> Void)?) {
        self.child = child
        self.limit = limit
        startReader(fd: child.stdoutFD, stream: .stdout, onOutput: onOutput)
        startReader(fd: child.stderrFD, stream: .stderr, onOutput: onOutput)
        startWait()
    }

    var stdoutText: String { lock.withLock { String(decoding: stdout, as: UTF8.self) } }
    var stderrText: String { lock.withLock { String(decoding: stderr, as: UTF8.self) } }
    var truncated: Bool { lock.withLock { didTruncate } }

    /// What we asked for when we signalled, so an exit-by-signal can be
    /// reported as a timeout or a user stop rather than a raw signal number.
    var requestedReason: TerminationReason? {
        get { lock.withLock { reason } }
        set { lock.withLock { reason = newValue } }
    }

    func write(stdin text: String?) {
        defer { close(child.stdinFD) }
        guard let text, !text.isEmpty else { return }
        _ = text.withCString { pointer in
            Darwin.write(child.stdinFD, pointer, strlen(pointer))
        }
    }

    /// Returns once the child has been reaped *and* both pipes have hit EOF —
    /// waiting on the exit alone loses the tail of the output.
    func waitForCompletion() async -> Int32 {
        await withCheckedContinuation { continuation in
            group.notify(queue: .global(qos: .utility)) { [self] in
                continuation.resume(returning: lock.withLock { status })
            }
        }
    }

    private func startReader(fd: Int32, stream: OutputChunk.Stream,
                             onOutput: (@Sendable (OutputChunk) -> Void)?) {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { close(fd); group.leave() }
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    let data = Data(buffer[0..<count])
                    append(data, to: stream)
                    onOutput?(OutputChunk(stream: stream, text: String(decoding: data, as: UTF8.self)))
                } else if count == 0 {
                    return                                  // EOF
                } else if errno != EINTR {
                    return
                }
            }
        }
    }

    private func startWait() {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { group.leave() }
            var raw: Int32 = 0
            // Loop past EINTR: a signal arriving here would otherwise leave
            // the child unreaped — the zombie the Done-when asks about.
            while waitpid(child.pid, &raw, 0) < 0 && errno == EINTR {}
            lock.withLock { status = raw }
        }
    }

    private func append(_ data: Data, to stream: OutputChunk.Stream) {
        lock.withLock {
            switch stream {
            case .stdout:
                guard stdout.count < limit else { didTruncate = true; return }
                stdout.append(data.prefix(limit - stdout.count))
                if stdout.count >= limit { didTruncate = true }
            case .stderr:
                guard stderr.count < limit else { didTruncate = true; return }
                stderr.append(data.prefix(limit - stderr.count))
                if stderr.count >= limit { didTruncate = true }
            }
        }
    }
}
