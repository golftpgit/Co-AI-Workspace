import Foundation

// ─────────────────────────────────────────────────────────────
// Not losing a file we could not read (P9.2, ARCHITECTURE §15).
//
// Four things in this system keep a list in a JSON file next to the database —
// channel accounts, DB connectors, MCP servers, document templates — and all
// four had the same shape of bug, inherited from the same reasonable-looking
// line: a file that will not decode logs an error and returns an empty list, so
// the app keeps working.
//
// The part that is not fine is what happens next. The screen now shows an empty
// list, the person adds one entry, and the store *saves* — writing that one
// entry over a file that had five in it. The decode failure was recoverable
// right up to the moment the app helpfully carried on.
//
// So: before a list that failed to load can be replaced, the file goes to one
// side. It costs a copy and it is the difference between "re-add your bot" and
// "which chat ids were allowed?".
// ─────────────────────────────────────────────────────────────

public enum FileStoreSafety {

    /// Where the copy of an unreadable `foo.json` goes.
    public static func backupLocation(for file: URL) -> URL {
        file.deletingPathExtension()
            .appendingPathExtension("unreadable.backup")
            .appendingPathExtension(file.pathExtension)
    }

    /// Copies a file aside, once, before something overwrites it.
    ///
    /// **Only if there is no copy already.** A second failed load must not
    /// overwrite the backup taken on the first one — by then the live file may
    /// already be the shortened version, and the copy worth keeping is the
    /// oldest, not the newest.
    @discardableResult
    public static func preserveUnreadable(_ file: URL,
                                         fileManager: FileManager = .default) -> URL? {
        let backup = backupLocation(for: file)
        guard fileManager.fileExists(atPath: file.path(percentEncoded: false)) else { return nil }
        guard !fileManager.fileExists(atPath: backup.path(percentEncoded: false)) else {
            return backup
        }
        do {
            try fileManager.copyItem(at: file, to: backup)
            return backup
        } catch {
            return nil
        }
    }

    /// Takes the copy *and* leaves a record a person can be shown (P9.4).
    ///
    /// P9.2 made a corrupt list safe: the data is preserved and the app keeps
    /// running. What it did not do is tell anybody. The only trace was a line
    /// in the unified log, so what the user actually experienced was their bot
    /// list being empty one morning for no stated reason — no crash, and no
    /// readable error either, which is only half of P9.4's Done-when.
    @discardableResult
    public static func reportUnreadable(_ file: URL, describedAs kind: String,
                                        fileManager: FileManager = .default) -> ReadableFailure {
        let backup = preserveUnreadable(file, fileManager: fileManager)
        let failure = ReadableFailure.unreadableFile(
            doing: kind,
            backup: backup?.lastPathComponent,
            detail: file.lastPathComponent)
        FileStoreIncidents.shared.record(failure)
        return failure
    }
}

/// The unreadable-file reports from this run, so a screen can show them.
///
/// Process-wide because the four stores that can hit this are constructed in
/// four different places, load themselves lazily, and have no error channel
/// back to the caller — `load()` returns `[ChannelAccount]`, not a result. The
/// alternative was threading a reporter through four initialisers to carry
/// something that happens approximately never; this keeps the change at the
/// two ends that matter.
public final class FileStoreIncidents: @unchecked Sendable {
    public static let shared = FileStoreIncidents()

    private let lock = NSLock()
    private var incidents: [ReadableFailure] = []

    public init() {}

    public func record(_ failure: ReadableFailure) {
        lock.withLock {
            // One per file. A store that is read on every screen change would
            // otherwise fill the list with the same sentence.
            guard !incidents.contains(where: { $0.detail == failure.detail }) else { return }
            incidents.append(failure)
        }
    }

    public var all: [ReadableFailure] { lock.withLock { incidents } }

    public func clear() { lock.withLock { incidents.removeAll() } }
}
