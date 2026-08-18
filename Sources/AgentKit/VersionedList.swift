import Foundation

// ─────────────────────────────────────────────────────────────
// A list file that knows what shape it is (ARCHITECTURE §15, P9.2's remaining
// half).
//
// P9.2 gave the config file a `schema_version` and a migration path, and left
// the four list files — channels, connectors, MCP servers, templates — as bare
// JSON arrays. They were made *safe* (a file that will not decode is copied
// aside rather than overwritten), which stops data being lost today and does
// nothing about the version that adds a field.
//
// The three rules are P9.2's, and each one is a way somebody's settings go
// missing:
//
//  • **No version is version 0, not a broken file.** Every file written before
//    this existed is a bare array, and they are the majority.
//  • **A file from a newer build is never written over.** Falling back to the
//    defaults for one session is recoverable; overwriting is not, and the
//    version they would go back to is the one that lost them.
//  • **Nothing is overwritten without a copy first**, which `FileStoreSafety`
//    already does and this keeps.
// ─────────────────────────────────────────────────────────────

public enum VersionedList {

    /// What this build writes. Raised when the shape of an item changes, and
    /// the migration that comes with it belongs beside the store that owns it.
    public static let currentVersion = 1

    private struct Envelope<Item: Codable>: Codable {
        let schemaVersion: Int
        let items: [Item]
    }

    public enum Outcome<Item> {
        /// Read, with the version it was written by.
        case list([Item], version: Int)
        /// A file this build is too old to read. It is not touched, and the
        /// caller runs on defaults until somebody opens the newer build again.
        case fromNewerBuild(version: Int)
        /// Neither shape decoded.
        case unreadable
    }

    /// Reads either shape.
    public static func decode<Item: Codable>(_ data: Data, as: Item.Type) -> Outcome<Item> {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(Envelope<Item>.self, from: data) {
            guard envelope.schemaVersion <= currentVersion else {
                return .fromNewerBuild(version: envelope.schemaVersion)
            }
            return .list(envelope.items, version: envelope.schemaVersion)
        }
        // A bare array is version 0 — every file written before this existed.
        if let items = try? decoder.decode([Item].self, from: data) {
            return .list(items, version: 0)
        }
        return .unreadable
    }

    /// Writes the envelope. Always the current version: a file this build
    /// wrote is a file this build can read.
    public static func encode<Item: Codable>(_ items: [Item],
                                             formatting: JSONEncoder.OutputFormatting =
                                                [.prettyPrinted, .sortedKeys]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = formatting
        return try encoder.encode(Envelope(schemaVersion: currentVersion, items: items))
    }

    /// Whether this build may write over what is on disk.
    ///
    /// Reading is what tells us: a file from a newer build has to be left
    /// exactly as it is, and the caller has to be able to say so rather than
    /// quietly saving and taking somebody's settings with it.
    public static func mayOverwrite<Item: Codable>(_ file: URL, of: Item.Type,
                                                   fileManager: FileManager = .default) -> Bool {
        guard let data = try? Data(contentsOf: file) else { return true }
        if case .fromNewerBuild = decode(data, as: Item.self) { return false }
        return true
    }
}

/// What a list store refuses to do.
public enum FileStoreError: Error, CustomStringConvertible, Equatable {
    /// The file on disk was written by a newer build. Saving would replace it
    /// with something that build cannot read, and the settings would be gone
    /// from the version somebody was going back to.
    case fileFromNewerBuild

    public var description: String {
        localised("this file was written by a newer version of the app, and has not been written over ", "Why a save was refused.")
            + localised("because overwriting it would lose those settings for the version you would go back to", "Ends the reason a save was refused.")
    }
}
