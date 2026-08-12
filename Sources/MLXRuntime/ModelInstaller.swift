import Foundation
import Hub

// ─────────────────────────────────────────────────────────────
// Getting a model onto this machine, from inside the app (P5.2, §9.4).
//
// The app is sandboxed, which decides the layout: weights go into the app's
// own models directory, because that is the one place it can read on the next
// launch without asking anyone for permission. A model sitting in
// `~/.lmstudio` is visible to the terminal and invisible here (U16), so
// "download it ourselves" is not a convenience — it is the only way Tier 0.5
// exists inside the app.
//
// Three things this refuses to do quietly:
//  • exceed the quota, or the free space actually on the disk
//  • delete anything outside its own directory
//  • report a download as finished when the files are not loadable
// ─────────────────────────────────────────────────────────────

public struct DownloadProgress: Sendable, Equatable {
    public let repository: String
    /// 0…1. The authoritative figure: the Hub's own progress counts *files*
    /// (one unit each, subdivided per file), so it is the fraction — not the
    /// unit counts — that means anything in bytes terms.
    public let fraction: Double
    /// The repository's recorded total. Together with the fraction this gives
    /// the "120 MB / 334 MB" a person can read; reading the Hub's unit counts
    /// as bytes instead showed "0 MB / 0 MB" beside a bar that was 40% along.
    public let totalBytes: Int64

    public var completedBytes: Int64 { Int64(Double(totalBytes) * fraction) }

    public init(repository: String, fraction: Double, totalBytes: Int64) {
        self.repository = repository
        self.fraction = min(1, max(0, fraction))
        self.totalBytes = totalBytes
    }
}

public enum ModelInstallError: Error, CustomStringConvertible, Equatable {
    case quotaExceeded(needs: Int64, remaining: Int64)
    case notEnoughDiskSpace(needs: Int64, free: Int64)
    case notOurs(URL)
    case incomplete(String)
    case unsupportedArchitecture(String)
    case failed(String)

    public var description: String {
        switch self {
        case .quotaExceeded(let needs, let remaining):
            return "เกินโควตา: ต้องการ \(Self.gb(needs)) เหลือ \(Self.gb(remaining))"
        case .notEnoughDiskSpace(let needs, let free):
            return "พื้นที่ดิสก์ไม่พอ: ต้องการ \(Self.gb(needs)) ว่าง \(Self.gb(free))"
        case .notOurs(let url):
            return "ลบได้เฉพาะโมเดลในโฟลเดอร์ของแอป: \(url.lastPathComponent)"
        case .incomplete(let detail):
            return "โหลดมาไม่ครบ: \(detail)"
        case .unsupportedArchitecture(let type):
            return "runtime นี้ยังรันสถาปัตยกรรม \(type) ไม่ได้ — โหลดมาแล้วก็ใช้ไม่ได้"
        case .failed(let detail):
            return "โหลดไม่สำเร็จ: \(detail)"
        }
    }

    private static func gb(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }
}

public struct StorageReport: Sendable, Equatable {
    public let usedBytes: Int64
    public let quotaBytes: Int64
    public let freeDiskBytes: Int64

    public var remainingBytes: Int64 { max(0, quotaBytes - usedBytes) }
    /// What a download of this size is actually limited by, whichever is less.
    public func headroom() -> Int64 { min(remainingBytes, freeDiskBytes) }
}

public actor ModelInstaller {
    /// The app's own models directory (`AppPaths.modelsDirectory`).
    public let destination: URL
    private let quotaBytes: Int64

    public init(destination: URL, quotaGigabytes: Int = 60) {
        self.destination = destination
        self.quotaBytes = Int64(max(1, quotaGigabytes)) * 1_073_741_824
    }

    // MARK: - space

    public func storage() -> StorageReport {
        ensureDestination()
        return StorageReport(usedBytes: Self.directorySize(destination),
                      quotaBytes: quotaBytes,
                      freeDiskBytes: Self.freeSpace(at: destination))
    }

    /// Checked before the first byte, because finding out at 90% costs the
    /// user everything they already waited for.
    public func admits(_ entry: ModelCatalogEntry) throws {
        let report = storage()
        guard entry.downloadBytes <= report.remainingBytes else {
            throw ModelInstallError.quotaExceeded(needs: entry.downloadBytes,
                                                  remaining: report.remainingBytes)
        }
        // A little slack: the Hub writes the file and its metadata, and a disk
        // with nothing left over is a disk that fails at the last shard.
        guard entry.downloadBytes + 1_073_741_824 <= report.freeDiskBytes else {
            throw ModelInstallError.notEnoughDiskSpace(needs: entry.downloadBytes,
                                                       free: report.freeDiskBytes)
        }
    }

    /// Free space is read from the directory itself, so it has to exist before
    /// the question can be answered — otherwise the honest-looking answer is
    /// "0 bytes free" and every download is refused on a disk with room.
    private func ensureDestination() {
        guard !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) else { return }
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    // MARK: - installing

    /// Downloads the repository and returns it as a model the runtime can load.
    ///
    /// Cancellation is the caller's Task: cancelling leaves the files that
    /// finished in place, so starting again continues from there. The file that
    /// was in flight starts over — the Hub client resumes per file, not per
    /// byte, which matters on a checkpoint kept in one 4 GB shard.
    public func install(_ entry: ModelCatalogEntry,
                        progress: @Sendable @escaping (DownloadProgress) -> Void) async throws -> LocalModel {
        try admits(entry)
        // `cache: nil` on purpose. HubApi keeps a shared content-addressed
        // cache *in addition to* the snapshot it materialises — the two are
        // independent by design — so the default costs 335 MB twice for a
        // 335 MB model, and the copy the quota cannot see is the one that
        // fills the disk. We own this directory; there is nothing to share
        // with.
        let hub = HubApi(downloadBase: destination, cache: nil)
        let repository = entry.repository

        do {
            let directory = try await hub.snapshot(
                from: repository,
                matching: Self.weightPatterns
            ) { received in
                progress(DownloadProgress(repository: repository,
                                          fraction: received.fractionCompleted,
                                          totalBytes: entry.downloadBytes))
            }
            try Task.checkCancellation()

            // The Hub reports success per file; what matters here is whether
            // the result is a model. A snapshot missing its tokenizer looks
            // downloaded and fails at first use, days later.
            let catalog = LocalModelCatalog(searchPaths: [destination])
            guard await catalog.isChatModel(directory) else {
                let type = LocalModelCatalog.modelType(in: directory)
                throw await LocalModelCatalog.runtimeCanBuild(type)
                    ? ModelInstallError.incomplete(
                        "\(repository) — ไม่พบ weights/tokenizer/chat template ครบใน \(directory.lastPathComponent)")
                    : ModelInstallError.unsupportedArchitecture(type ?? "ไม่ทราบชนิด")
            }
            guard let model = await catalog.installed().first(where: {
                $0.directory.standardizedFileURL == directory.standardizedFileURL
            }) else {
                throw ModelInstallError.incomplete("\(repository) — โหลดแล้วแต่ยังอ่านค่าไม่ได้")
            }
            progress(DownloadProgress(repository: repository, fraction: 1,
                                      totalBytes: model.sizeOnDisk))
            return model
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ModelInstallError {
            throw error
        } catch {
            // Cancelling a download does not arrive as `CancellationError`:
            // the task's cancellation reaches URLSession first and comes back
            // as NSURLError -999. Left untranslated, pressing "ยกเลิก" showed
            // the user a red failure with a Foundation error domain in it.
            if Task.isCancelled || (error as NSError).code == NSURLErrorCancelled {
                throw CancellationError()
            }
            throw ModelInstallError.failed(
                "\(repository): \((error as NSError).localizedDescription)")
        }
    }

    /// Everything a chat model needs and nothing else — an MLX repository also
    /// carries the original PyTorch weights often enough to double the
    /// download for files that are never read.
    static let weightPatterns = [
        "*.safetensors", "*.json", "*.jinja", "*.txt", "*.model",
    ]

    // MARK: - removing

    /// Deletes a model this installer owns. Refuses anything else: the
    /// catalogue also finds models in LM Studio's library and the Hugging Face
    /// cache, and this app has no business deleting those.
    public func delete(_ model: LocalModel) throws {
        let target = model.directory
        guard Self.contains(destination, target) else {
            throw ModelInstallError.notOurs(model.directory)
        }
        try FileManager.default.removeItem(at: target)
        Self.pruneEmptyDirectories(under: destination)
    }

    /// Symlinks resolved on both sides before comparing: `/var` is a link to
    /// `/private/var`, so the same directory has two spellings and a plain
    /// prefix check reads the app's own model as somebody else's.
    public static func contains(_ root: URL, _ candidate: URL) -> Bool {
        let base = root.resolvingSymlinksInPath().standardizedFileURL
            .path(percentEncoded: false)
        let path = candidate.resolvingSymlinksInPath().standardizedFileURL
            .path(percentEncoded: false)
        return path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    // MARK: - filesystem

    /// Leftover `mlx-community/` shells after a delete read as "still
    /// installed" to anyone looking in Finder.
    private static func pruneEmptyDirectories(under root: URL) {
        let manager = FileManager.default
        guard let entries = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])?
            .allObjects as? [URL] else { return }
        for directory in entries.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let contents = try? manager.contentsOfDirectory(atPath: directory.path(percentEncoded: false)),
                  contents.isEmpty else { continue }
            try? manager.removeItem(at: directory)
        }
    }

    static func directorySize(_ root: URL) -> Int64 {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    static func freeSpace(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}
