import Foundation
import AgentKit

/// Every filesystem location the app owns, derived from one root.
/// Created on demand so a wiped Application Support directory self-heals.
public struct AppPaths: Sendable {
    public static let bundleIdentifier = "com.coaiworkspace.app"

    public let root: URL

    public var bootstrapFile: URL { root.appending(path: "bootstrap.plist") }
    public var databaseDirectory: URL { root.appending(path: "surrealdb") }
    public var modelsDirectory: URL { root.appending(path: "models") }
    public var agentsDirectory: URL { root.appending(path: "agents") }
    public var skillsDirectory: URL { root.appending(path: "skills") }
    public var pluginsDirectory: URL { root.appending(path: "plugins") }
    public var documentsDirectory: URL { root.appending(path: "documents") }
    /// The analysis store's own directory (§12.1). A directory rather than a
    /// bare file because DuckDB writes a `.wal` beside the database, and a
    /// stray write-ahead log in the middle of Application Support is the sort
    /// of thing that gets deleted by hand and takes the data with it.
    public var analysisDirectory: URL { root.appending(path: "analysis") }
    public var logsDirectory: URL { root.appending(path: "logs") }
    /// One folder per project (§19.1). Everything a project owns that is a
    /// *file* lives under here — its analysis database, its notebooks, its
    /// documents, and the working directory shell commands run in.
    ///
    /// The database rows were already partitioned by `Scope`; the disk was not,
    /// which meant two projects shared one `analysis.duckdb` and one notebook
    /// folder. Deleting a project could not be done without reading every file
    /// to see whose it was.
    public var projectsDirectory: URL { root.appending(path: "projects") }

    public func project(_ id: ProjectID) -> ProjectPaths {
        ProjectPaths(root: projectsDirectory.appending(path: id.rawValue))
    }

    /// All directories that must exist before the app is usable.
    public var managedDirectories: [URL] {
        [root, databaseDirectory, modelsDirectory, agentsDirectory,
         skillsDirectory, pluginsDirectory, documentsDirectory, analysisDirectory,
         logsDirectory, projectsDirectory]
    }

    public init(root: URL) { self.root = root }

    /// `~/Library/Application Support/CoAIWorkspace` (or the sandbox equivalent).
    public static func standard(
        fileManager: FileManager = .default
    ) throws -> AppPaths {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        return AppPaths(root: support.appending(path: "CoAIWorkspace"))
    }

    /// Idempotent: safe to call on every launch.
    @discardableResult
    public func createDirectories(fileManager: FileManager = .default) throws -> [URL] {
        var created: [URL] = []
        for dir in managedDirectories where !fileManager.fileExists(atPath: dir.path(percentEncoded: false)) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            created.append(dir)
        }
        return created
    }
}

/// Where one project's files live (§19.1).
///
/// A value, not a service: it computes paths and creates them on demand, and it
/// deliberately cannot delete anything. Removing a project's row is cheap and
/// reversible; removing its folder is neither, so that stays a decision a
/// person makes with the files in front of them.
public struct ProjectPaths: Sendable {
    public let root: URL

    /// DuckDB writes a `.wal` beside its database, so the store gets a
    /// directory of its own for the same reason the app-wide one does.
    public var analysisDirectory: URL { root.appending(path: "analysis") }
    public var notebooksDirectory: URL { root.appending(path: "notebooks") }
    public var documentsDirectory: URL { root.appending(path: "documents") }
    /// Where this project's shell commands run and its files are written.
    /// Inside the app container, so a sandboxed app reaches it without the
    /// user having to grant anything.
    public var filesDirectory: URL { root.appending(path: "files") }

    /// Where M16 writes what people answered (§19.17). Its own directory beside
    /// the analysis one, and for the same reason: SQLite in WAL mode keeps a
    /// `-wal` and a `-shm` beside the database, and those three files are one
    /// database — a stray write-ahead log loose in a folder is the sort of thing
    /// somebody deletes by hand and takes the data with it.
    public var fieldDirectory: URL { root.appending(path: "field") }

    public var analysisDatabase: URL { analysisDirectory.appending(path: "analysis.duckdb") }
    public var connectorsFile: URL { analysisDirectory.appending(path: "connectors.json") }
    /// The raw answers, in the one database shape that takes concurrent writers
    /// (§19.17). Separate from `analysisDatabase` on purpose: DuckDB is where
    /// answers are *read* from, through `ATTACH`, and never where they land.
    public var responsesDatabase: URL { fieldDirectory.appending(path: "responses.sqlite") }

    public var managedDirectories: [URL] {
        [root, analysisDirectory, notebooksDirectory, documentsDirectory, filesDirectory,
         fieldDirectory]
    }

    public init(root: URL) { self.root = root }

    @discardableResult
    public func createDirectories(fileManager: FileManager = .default) throws -> [URL] {
        var created: [URL] = []
        for dir in managedDirectories
        where !fileManager.fileExists(atPath: dir.path(percentEncoded: false)) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            created.append(dir)
        }
        return created
    }
}
