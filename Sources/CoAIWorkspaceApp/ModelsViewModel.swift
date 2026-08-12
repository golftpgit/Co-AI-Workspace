import Foundation
import Observation
import MLXRuntime
import Observability

// ─────────────────────────────────────────────────────────────
// The model manager's state (ARCHITECTURE §9.4, P5.2).
//
// Tier 0.5 is inference inside this app, so the app has to be the place a
// model comes from: pick from a list, watch it download, use it without a
// restart, delete it when the disk fills up. Before this screen the only way
// to give the app a local model was a terminal, which on a sandboxed app meant
// there was no way at all (U16).
// ─────────────────────────────────────────────────────────────

@MainActor
@Observable
public final class ModelsViewModel {
    public struct Status: Equatable {
        public var message: String
        public var isError: Bool
    }

    public struct Download: Equatable {
        public var repository: String
        public var completedBytes: Int64
        public var totalBytes: Int64
        public var fraction: Double
    }

    public private(set) var installed: [LocalModel] = []
    public private(set) var storage: StorageReport?
    public private(set) var downloads: [String: Download] = [:]
    public private(set) var status: Status?
    /// Which model Tier 0.5 will load. Nil while nothing is installed.
    public private(set) var selectedName: String?
    /// What this machine can hold, and what §9.4 says a model of that size can
    /// be trusted with — shown so the size numbers below have a yardstick.
    public private(set) var memory = MachineMemory.current()
    public var sizeClass: MachineSizeClass {
        MachineSizeClass.forMachine(totalBytes: memory.totalBytes)
    }

    private var installer: ModelInstaller?
    private var catalog: LocalModelCatalog?
    private var tier: LocalTier?
    /// Writes the choice to bootstrap.plist so it survives a restart — the
    /// router is built before the database exists, so this cannot live there.
    private var persist: ((String?) -> Void)?
    private var tasks: [String: Task<Void, Never>] = [:]
    private let log = AppLog.logger("models-ui")

    public init() {}

    /// Everything in the recommended list that is not already here.
    public var recommended: [ModelCatalogEntry] {
        let have = Set(installed.map(\.name))
        return RecommendedModels.all.filter { !have.contains($0.repository) }
    }

    public func attach(installer: ModelInstaller,
                       catalog: LocalModelCatalog,
                       tier: LocalTier,
                       persist: @escaping (String?) -> Void) async {
        self.installer = installer
        self.catalog = catalog
        self.tier = tier
        self.persist = persist
        self.selectedName = tier.selected?.name
        await refresh()
    }

    /// Whether this model can be run here *now* — re-read on every refresh
    /// because the answer changes with whatever else the Mac is doing.
    public func admission(for model: LocalModel) -> Admission {
        AdmissionControl.admit(model, memory: memory)
    }

    public func admission(for entry: ModelCatalogEntry) -> Admission {
        AdmissionControl.admit(entry, memory: memory)
    }

    public func refresh() async {
        guard let catalog, let installer else { return }
        memory = MachineMemory.current()
        installed = await catalog.installed()
        storage = await installer.storage()
        if let selectedName, !installed.contains(where: { $0.name == selectedName }) {
            // The selected model was deleted from under us.
            select(installed.first)
        }
    }

    // MARK: - downloading

    public func isDownloading(_ entry: ModelCatalogEntry) -> Bool {
        tasks[entry.repository] != nil
    }

    public func download(_ entry: ModelCatalogEntry) {
        guard let installer, tasks[entry.repository] == nil else { return }
        status = nil
        downloads[entry.repository] = Download(repository: entry.repository,
                                               completedBytes: 0,
                                               totalBytes: entry.downloadBytes,
                                               fraction: 0)
        // Built here rather than inside the task: the installer calls it from
        // its own actor, so it has to be a plain @Sendable closure holding one
        // weak reference, not a capture nested inside another one.
        let onProgress: @Sendable (DownloadProgress) -> Void = { [weak self] progress in
            Task { @MainActor in self?.record(progress) }
        }
        tasks[entry.repository] = Task { [weak self] in
            do {
                let model = try await installer.install(entry, progress: onProgress)
                guard let self else { return }
                self.finish(entry)
                await self.refresh()
                // First model on the machine: use it, rather than making the
                // user find a second switch after a ten-minute download.
                if self.selectedName == nil { self.select(model) }
                self.status = Status(message: "โหลด \(entry.displayName) เสร็จแล้ว", isError: false)
            } catch is CancellationError {
                guard let self else { return }
                self.finish(entry)
                await self.refresh()
                self.status = Status(
                    message: "ยกเลิก \(entry.displayName) แล้ว — ไฟล์ที่โหลดเสร็จยังอยู่ เริ่มใหม่แล้วจะไปต่อจากเดิม",
                    isError: false)
            } catch {
                guard let self else { return }
                self.finish(entry)
                await self.refresh()
                self.log.error("download \(entry.repository): \(error)")
                self.status = Status(message: "\(error)", isError: true)
            }
        }
    }

    public func cancel(_ entry: ModelCatalogEntry) {
        tasks[entry.repository]?.cancel()
    }

    private func record(_ progress: DownloadProgress) {
        downloads[progress.repository] = Download(repository: progress.repository,
                                                  completedBytes: progress.completedBytes,
                                                  totalBytes: progress.totalBytes,
                                                  fraction: progress.fraction)
    }

    private func finish(_ entry: ModelCatalogEntry) {
        tasks[entry.repository] = nil
        downloads[entry.repository] = nil
    }

    // MARK: - choosing and removing

    /// Refuses a model that would not fit in what is free (§9.4, P5.3).
    ///
    /// Not a warning with a button next to it: a model too big for the machine
    /// does not answer slowly, it takes the Mac down with it, and by then the
    /// user cannot get to this screen to undo the choice.
    public func select(_ model: LocalModel?) {
        if let model {
            let admission = self.admission(for: model)
            guard !admission.isBlocking else {
                status = Status(message: admission.reason, isError: true)
                log.error("refused \(model.name) on memory: \(admission.reason)")
                return
            }
            if admission.verdict == .tight {
                status = Status(message: admission.reason, isError: false)
            }
        }
        tier?.select(model)
        selectedName = model?.name
        persist?(model?.name)
    }

    public func isSelected(_ model: LocalModel) -> Bool { model.name == selectedName }

    /// Only models this app downloaded can be removed; the installer refuses
    /// anything else, because the catalogue also finds LM Studio's library.
    public func isRemovable(_ model: LocalModel) async -> Bool {
        guard let installer else { return false }
        return await ModelInstaller.contains(installer.destination, model.directory)
    }

    public func delete(_ model: LocalModel) async {
        guard let installer else { return }
        do {
            // Free the weights first: deleting the files under a loaded model
            // leaves the runtime holding descriptors to files that are gone.
            if isSelected(model) {
                await tier?.unloadSelected()
                select(nil)
            }
            try await installer.delete(model)
            await refresh()
            if selectedName == nil { select(installed.first) }
            status = Status(message: "ลบ \(model.name) แล้ว", isError: false)
        } catch {
            log.error("delete \(model.name): \(error)")
            status = Status(message: "\(error)", isError: true)
        }
    }
}
