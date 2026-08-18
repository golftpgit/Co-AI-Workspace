import Foundation
import Config
import Observability

// ─────────────────────────────────────────────────────────────
// SidecarManager (ARCHITECTURE §11.5) — owns the lifecycle of the helper
// processes the app bundles (surreal, searxng). The user must never have to
// start or install these by hand, and quitting the app must never leave one
// running. Crash-orphans are reaped at next launch via pid files.
// ─────────────────────────────────────────────────────────────

public struct SidecarSpec: Sendable, Identifiable {
    public let id: String
    public let executableURL: URL
    public let arguments: [String]
    /// Probed until it answers before the sidecar is considered ready.
    public let healthURL: URL?
    public let workingDirectory: URL?
    public let environment: [String: String]
    public let readinessTimeout: Duration
    /// Restart attempts allowed inside `restartWindow` before giving up.
    public let maxRestarts: Int
    public let restartWindow: Duration

    public init(id: String,
                executableURL: URL,
                arguments: [String] = [],
                healthURL: URL? = nil,
                workingDirectory: URL? = nil,
                environment: [String: String] = [:],
                readinessTimeout: Duration = .seconds(15),
                maxRestarts: Int = 5,
                restartWindow: Duration = .seconds(60)) {
        self.id = id
        self.executableURL = executableURL
        self.arguments = arguments
        self.healthURL = healthURL
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.readinessTimeout = readinessTimeout
        self.maxRestarts = maxRestarts
        self.restartWindow = restartWindow
    }
}

public enum SidecarStatus: Sendable, Equatable {
    case stopped
    case starting
    case running(pid: Int32)
    case restarting(attempt: Int)
    /// Gave up after `maxRestarts` — surfaced in the UI, not swallowed.
    case failed(reason: String)

    public var isHealthy: Bool { if case .running = self { return true }; return false }

    /// What this means for the person using the app (P9.4).
    ///
    /// The status itself is a diagnostic — "exited 1; 3 restarts in 60s" is
    /// the right thing to keep and the wrong thing to show alone. When
    /// SurrealDB gives up, everything durable in the app stops working, and a
    /// screen that reports only the exit code leaves the user to infer that.
    /// The raw reason stays, after the sentence, because whoever is debugging
    /// still needs it.
    public func explanation(id: String) -> String {
        switch self {
        case .stopped: "หยุดอยู่"
        case .starting: "กำลังเริ่ม…"
        case .running(let pid): "ทำงานอยู่ (pid \(pid))"
        case .restarting(let attempt):
            "หยุดไปเอง กำลังเริ่มใหม่ให้อัตโนมัติ (ครั้งที่ \(attempt)) — "
                + "ระหว่างนี้สิ่งที่ต้องใช้ \(id) จะยังไม่ทำงาน"
        case .failed(let reason):
            "\(id) หยุดทำงานและเริ่มใหม่ไม่สำเร็จ — สิ่งที่ต้องใช้บริการนี้จะใช้ไม่ได้จนกว่าจะแก้ · "
                + "ลองปิดแล้วเปิดแอปใหม่ ถ้ายังเป็นเหมือนเดิมให้ดู log ของ \(id) · "
                + "รายละเอียด: \(reason)"
        }
    }
}

public enum SidecarError: Error, CustomStringConvertible, Equatable {
    case executableMissing(String)
    case launchFailed(String)
    case notReady(id: String, after: String)
    case unknownSidecar(String)

    public var description: String {
        switch self {
        case .executableMissing(let p): return "sidecar executable not found: \(p)"
        case .launchFailed(let m): return "sidecar failed to launch: \(m)"
        case .notReady(let id, let t): return "sidecar '\(id)' did not become ready within \(t)"
        case .unknownSidecar(let id): return "unknown sidecar '\(id)'"
        }
    }
}

public actor SidecarManager {
    private struct Managed {
        let spec: SidecarSpec
        var process: Process?
        var status: SidecarStatus
        var intentionalStop: Bool
        var restartTimestamps: [Date]
    }

    private var managed: [String: Managed] = [:]
    private let paths: AppPaths
    private let log = AppLog.logger("sidecar")
    private let probe: @Sendable (URL) async -> Bool

    public init(paths: AppPaths,
                probe: (@Sendable (URL) async -> Bool)? = nil) {
        self.paths = paths
        self.probe = probe ?? SidecarManager.httpProbe
        // Every entry point that can start a sidecar installs this, not just the
        // app: `swift test` and the check executables start them too, and those
        // are the runs that actually get killed part-way (U17).
        SidecarReaper.install()
    }

    // MARK: - lifecycle

    /// Starts the sidecar and waits until its health probe answers.
    /// Reaps a stale process from a previous crashed run first.
    public func start(_ spec: SidecarSpec) async throws {
        guard FileManager.default.isExecutableFile(atPath: spec.executableURL.path(percentEncoded: false)) else {
            throw SidecarError.executableMissing(spec.executableURL.path(percentEncoded: false))
        }
        reapOrphan(for: spec)

        managed[spec.id] = Managed(spec: spec, process: nil, status: .starting,
                                   intentionalStop: false, restartTimestamps: [])
        try launch(spec.id)
        try await waitUntilReady(spec.id)
    }

    public func stop(_ id: String) {
        guard var entry = managed[id] else { return }
        entry.intentionalStop = true
        entry.status = .stopped
        managed[id] = entry
        terminate(entry.process)
        removePIDFile(id: id)
        SidecarReaper.forget(id: id)
        log.info("sidecar '\(id, privacy: .public)' stopped")
    }

    /// Called on app termination — must leave nothing behind.
    public func stopAll() {
        for id in managed.keys { stop(id) }
    }

    public func status(of id: String) -> SidecarStatus {
        managed[id]?.status ?? .stopped
    }

    public func allStatuses() -> [String: SidecarStatus] {
        managed.mapValues(\.status)
    }

    // MARK: - internals

    private func launch(_ id: String) throws {
        guard var entry = managed[id] else { throw SidecarError.unknownSidecar(id) }
        let spec = entry.spec

        let process = Process()
        process.executableURL = spec.executableURL
        process.arguments = spec.arguments
        if let cwd = spec.workingDirectory { process.currentDirectoryURL = cwd }
        if !spec.environment.isEmpty {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in spec.environment { env[k] = v }
            process.environment = env
        }
        // Sidecar output goes to a log file, never to the app's stdout.
        if let handle = logHandle(for: id) {
            process.standardOutput = handle
            process.standardError = handle
        }

        process.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { await self?.processDidTerminate(id: id, exitCode: code) }
        }

        do { try process.run() } catch {
            entry.status = .failed(reason: "\(error)")
            managed[id] = entry
            throw SidecarError.launchFailed("\(error)")
        }

        entry.process = process
        entry.status = .starting
        managed[id] = entry
        writePIDFile(id: id, pid: process.processIdentifier)
        // So it dies with us even when nobody asks politely (U17). The pid file
        // stays too: it is what covers SIGKILL and a crash, which no handler can.
        SidecarReaper.register(id: id, pid: process.processIdentifier)
        log.info("sidecar '\(id, privacy: .public)' launched pid \(process.processIdentifier)")
    }

    private func waitUntilReady(_ id: String) async throws {
        guard let entry = managed[id] else { throw SidecarError.unknownSidecar(id) }
        let spec = entry.spec
        guard let healthURL = spec.healthURL else {
            // No probe configured: running process is the only signal we have.
            if let pid = managed[id]?.process?.processIdentifier {
                managed[id]?.status = .running(pid: pid)
            }
            return
        }

        let deadline = ContinuousClock.now.advanced(by: spec.readinessTimeout)
        while ContinuousClock.now < deadline {
            if await probe(healthURL) {
                if let pid = managed[id]?.process?.processIdentifier {
                    managed[id]?.status = .running(pid: pid)
                }
                log.info("sidecar '\(id, privacy: .public)' ready")
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        managed[id]?.status = .failed(reason: "readiness timeout")
        throw SidecarError.notReady(id: id, after: "\(spec.readinessTimeout)")
    }

    /// Restart on unexpected exit, with a bounded attempt budget so a sidecar
    /// that cannot start never becomes an infinite spawn loop.
    private func processDidTerminate(id: String, exitCode: Int32) async {
        guard var entry = managed[id], !entry.intentionalStop else { return }

        let now = Date()
        let window = TimeInterval(entry.spec.restartWindow.components.seconds)
        entry.restartTimestamps = entry.restartTimestamps.filter { now.timeIntervalSince($0) < window }
        entry.restartTimestamps.append(now)
        let attempt = entry.restartTimestamps.count

        guard attempt <= entry.spec.maxRestarts else {
            entry.status = .failed(reason: "exited \(exitCode); \(attempt - 1) restarts in \(Int(window))s")
            managed[id] = entry
            removePIDFile(id: id)
            log.error("sidecar '\(id, privacy: .public)' gave up after \(attempt - 1) restarts")
            return
        }

        entry.status = .restarting(attempt: attempt)
        managed[id] = entry
        log.warning("sidecar '\(id, privacy: .public)' exited \(exitCode), restart \(attempt)")

        // Backoff, but keep the first retry fast so the Done-when target
        // (recovered within ~5s of an external kill) holds.
        let backoffMs = min(2_000, 250 * (1 << min(attempt - 1, 3)))
        try? await Task.sleep(for: .milliseconds(backoffMs))

        guard managed[id]?.intentionalStop == false else { return }
        do {
            try launch(id)
            try await waitUntilReady(id)
        } catch {
            managed[id]?.status = .failed(reason: "\(error)")
        }
    }

    private func terminate(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()                       // SIGTERM
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)   // last resort
        }
    }

    // MARK: - crash-orphan reaping

    private func pidFile(id: String) -> URL {
        paths.logsDirectory.appending(path: "\(id).pid")
    }

    private func writePIDFile(id: String, pid: Int32) {
        try? paths.createDirectories()
        try? "\(pid)".write(to: pidFile(id: id), atomically: true, encoding: .utf8)
    }

    private func removePIDFile(id: String) {
        try? FileManager.default.removeItem(at: pidFile(id: id))
    }

    /// If the app crashed last run, its sidecar may still be alive and holding
    /// the port. Kill it before starting a new one.
    private func reapOrphan(for spec: SidecarSpec) {
        let file = pidFile(id: spec.id)
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else { return }
        if kill(pid, 0) == 0 {                     // still alive
            log.warning("reaping orphaned sidecar '\(spec.id, privacy: .public)' pid \(pid)")
            kill(pid, SIGTERM)
            usleep(300_000)
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
        removePIDFile(id: spec.id)
    }

    private func logHandle(for id: String) -> FileHandle? {
        try? paths.createDirectories()
        let url = paths.logsDirectory.appending(path: "\(id).log")
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        try? handle?.seekToEnd()
        return handle
    }

    private static let httpProbe: @Sendable (URL) async -> Bool = { url in
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        request.httpMethod = "GET"
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<500).contains(http.statusCode)   // answering at all is enough
    }
}
