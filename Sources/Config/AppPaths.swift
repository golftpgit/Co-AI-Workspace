import Foundation

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
    public var logsDirectory: URL { root.appending(path: "logs") }

    /// All directories that must exist before the app is usable.
    public var managedDirectories: [URL] {
        [root, databaseDirectory, modelsDirectory, agentsDirectory,
         skillsDirectory, pluginsDirectory, documentsDirectory, logsDirectory]
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
