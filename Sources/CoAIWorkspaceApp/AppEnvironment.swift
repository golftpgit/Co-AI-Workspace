import Foundation
import Observation
import Config
import Observability
import Sidecar

/// Boot state the UI observes. Everything that can fail at startup fails
/// *visibly* here — v1's habit of swallowing startup errors left blank panels
/// with no explanation (bug B4).
@MainActor
@Observable
public final class AppEnvironment {
    public enum Phase: Equatable {
        case launching
        case ready
        case degraded(String)
    }

    public private(set) var phase: Phase = .launching
    public private(set) var paths: AppPaths?
    public private(set) var config: BootstrapConfig = .default
    public private(set) var bootstrapOutcome: BootstrapStore.LoadOutcome?
    public private(set) var createdDirectories: [String] = []
    public private(set) var sidecarStatuses: [String: SidecarStatus] = [:]
    public private(set) var notes: [String] = []
    /// Nil until the database answers. Chat is unavailable without it, and the
    /// UI says which of the two happened rather than showing an empty panel.
    private(set) var engine: Engine?
    private(set) var engineError: String?

    private var sidecars: SidecarManager?
    private var statusPoll: Task<Void, Never>?
    private let log = AppLog.logger("boot")

    public init() {}

    public func boot() async {
        do {
            let paths = try AppPaths.standard()
            let created = try paths.createDirectories()
            self.paths = paths
            self.createdDirectories = created.map(\.lastPathComponent)

            let store = BootstrapStore(paths: paths)
            let (config, outcome) = try store.load()
            self.config = config
            self.bootstrapOutcome = outcome
            if case .repairedInvalid(let reason) = outcome {
                notes.append("bootstrap.plist ใช้ไม่ได้ จึงสร้างใหม่จากค่าเริ่มต้น (\(reason))")
            }

            let manager = SidecarManager(paths: paths)
            self.sidecars = manager
            await startBundledSidecars(manager, config: config, paths: paths)
            startStatusPolling(manager)
            await buildEngine(config: config, paths: paths)

            phase = .ready
            log.info("boot complete at \(paths.root.path(percentEncoded: false), privacy: .public)")
        } catch {
            phase = .degraded("\(error)")
            log.error("boot failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// P0 wires the manager and reports what is missing; the actual surreal /
    /// searxng binaries are bundled in P1.2 and P3.1 respectively.
    private func startBundledSidecars(_ manager: SidecarManager,
                                      config: BootstrapConfig,
                                      paths: AppPaths) async {
        guard let helpers = Bundle.main.url(forResource: nil, withExtension: nil, subdirectory: "Helpers")
                ?? Bundle.main.resourceURL?.appending(path: "Helpers"),
              FileManager.default.fileExists(atPath: helpers.path(percentEncoded: false)) else {
            notes.append("ยังไม่มีโฟลเดอร์ Helpers ใน bundle — sidecar จะเริ่มทำงานเมื่อถึง P1.2/P3.1")
            return
        }

        let surreal = helpers.appending(path: "surreal")
        guard FileManager.default.isExecutableFile(atPath: surreal.path(percentEncoded: false)) else {
            notes.append("ไม่พบ binary 'surreal' ใน Helpers — ข้ามการเริ่ม sidecar")
            return
        }

        let spec = SidecarSpec(
            id: "surreal",
            executableURL: surreal,
            arguments: ["start",
                        "--user", "root", "--pass", "root",
                        "--bind", "127.0.0.1:\(config.surrealPort)",
                        "surrealkv://\(paths.databaseDirectory.path(percentEncoded: false))"],
            healthURL: URL(string: "http://127.0.0.1:\(config.surrealPort)/health"))
        do {
            try await manager.start(spec)
        } catch {
            notes.append("เริ่ม sidecar 'surreal' ไม่สำเร็จ: \(error)")
        }

        await startSearXNG(manager: manager, config: config)
    }

    /// Meta-search (§1.4, P3.1). Optional on purpose: everything except T5 web
    /// search works without it, so a machine that has not installed it gets a
    /// note rather than a failed boot.
    ///
    /// The interpreter is a configured path rather than something bundled,
    /// because a Python virtualenv cannot be relocated — its scripts hold
    /// absolute paths — so shipping one inside the .app is packaging work
    /// (P9.6), not a copy step.
    private func startSearXNG(manager: SidecarManager, config: BootstrapConfig) async {
        guard let interpreter = config.searxngPython, !interpreter.isEmpty else {
            notes.append("ยังไม่ได้ตั้ง searxngPython — ค้นเว็บทั่วไป (T5) จะใช้ไม่ได้ "
                         + "(ติดตั้งด้วย scripts/fetch-searxng.sh แล้วตั้งค่าใน bootstrap.plist)")
            return
        }
        guard FileManager.default.isExecutableFile(atPath: interpreter) else {
            notes.append("searxngPython ชี้ไปที่ไฟล์ที่รันไม่ได้: \(interpreter)")
            return
        }

        let settings = URL(fileURLWithPath: interpreter)
            .deletingLastPathComponent()      // bin
            .deletingLastPathComponent()      // venv
            .deletingLastPathComponent()      // searxng
            .appending(path: "config/settings.yml")

        let spec = SidecarSpec(
            id: "searxng",
            executableURL: URL(fileURLWithPath: interpreter),
            arguments: ["-m", "searx.webapp"],
            healthURL: URL(string: "http://127.0.0.1:\(config.searxngPort)/"),
            environment: ["SEARXNG_SETTINGS_PATH": settings.path(percentEncoded: false)],
            // It loads ~70 engine definitions before it answers; the default
            // 15 seconds is measured against a database, not this.
            readinessTimeout: .seconds(45))
        do {
            try await manager.start(spec)
        } catch {
            notes.append("เริ่ม sidecar 'searxng' ไม่สำเร็จ: \(error)")
        }
    }

    /// The database is a sidecar that has just been asked to start, so the
    /// first connection attempt can legitimately lose the race. Retrying for a
    /// few seconds is the difference between a working first launch and a
    /// window that says "ต่อฐานข้อมูลไม่ได้" until the user restarts.
    private func buildEngine(config: BootstrapConfig, paths: AppPaths) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            do {
                engine = try await Engine.build(config: config, paths: paths)
                engineError = nil
                log.info("engine ready")
                return
            } catch {
                engineError = "\(error)"
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        notes.append("เชื่อมต่อฐานข้อมูลไม่สำเร็จ จึงยังใช้หน้าแชทไม่ได้ — \(engineError ?? "ไม่ทราบสาเหตุ")")
        log.error("engine unavailable: \(self.engineError ?? "unknown", privacy: .public)")
    }

    private func startStatusPolling(_ manager: SidecarManager) {
        statusPoll?.cancel()
        statusPoll = Task { [weak self] in
            while !Task.isCancelled {
                let statuses = await manager.allStatuses()
                await MainActor.run { self?.sidecarStatuses = statuses }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Must run before the process exits so no sidecar is left behind.
    public func shutdown() async {
        statusPoll?.cancel()
        await engine?.shutdown()
        await sidecars?.stopAll()
        log.info("shutdown complete")
    }
}
