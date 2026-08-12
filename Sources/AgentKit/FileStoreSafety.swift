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
}
