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
        await sidecars?.stopAll()
        log.info("shutdown complete")
    }
}
