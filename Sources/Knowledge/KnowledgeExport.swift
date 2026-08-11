import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// Getting the knowledge base out and back in (ARCHITECTURE §11.4, P2.7).
//
// Text, provenance and the entities a user corrected are exported; vectors are
// not. They are derived from the text by a named model, they are the bulk of
// the bytes, and an export carrying them would be silently wrong the moment
// the importing machine ran a different one. The import re-embeds instead,
// which is the same path a model change takes (P2.8).
// ─────────────────────────────────────────────────────────────

public struct KnowledgeArchive: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public let id: String
        public let text: String
        public let scope: Scope
        public let provenance: Provenance
        public let entities: [String]
    }

    public let formatVersion: Int
    /// What produced the vectors that were dropped, so an import can say
    /// whether it is re-embedding into the same space or a different one.
    public let exportedProfile: EmbeddingProfile?
    public let entries: [Entry]

    public static let currentFormatVersion = 1
}

public enum ArchiveError: Error, CustomStringConvertible {
    case unsupportedFormat(Int)

    public var description: String {
        switch self {
        case .unsupportedFormat(let version):
            return "knowledge archive format \(version) is newer than this app understands"
        }
    }
}

extension KnowledgeIndex {
    public func export(scope: Scope? = nil) -> KnowledgeArchive {
        let visible = scope.map { s in allChunks.filter { $0.scope == s } } ?? allChunks
        return KnowledgeArchive(
            formatVersion: KnowledgeArchive.currentFormatVersion,
            exportedProfile: profile,
            entries: visible.map {
                .init(id: $0.id, text: $0.text, scope: $0.scope,
                      provenance: $0.provenance, entities: $0.entities)
            })
    }

    /// Imports text and provenance, re-embedding when an embedder is given.
    /// Entries whose content is already present are skipped, so importing an
    /// archive twice is a no-op for the same reason ingesting a file twice is.
    @discardableResult
    public mutating func importArchive(_ archive: KnowledgeArchive,
                                       embedder: (some Embedder)?) async throws -> Int {
        guard archive.formatVersion <= KnowledgeArchive.currentFormatVersion else {
            throw ArchiveError.unsupportedFormat(archive.formatVersion)
        }

        var added = 0
        for entry in archive.entries {
            let hash = IngestionPipeline.contentHash(entry.text)
            guard !contains(contentHash: hash) else { continue }

            var embedding: [Float]?
            if let embedder { embedding = try await embedder.embed(entry.text) }

            try insert(IndexedChunk(
                id: entry.id, text: entry.text, scope: entry.scope,
                provenance: entry.provenance,
                embedding: embedding,
                embeddingProfileID: embedding == nil ? nil : embedder?.profile.id,
                contentHash: hash, entities: entry.entities))
            added += 1
        }
        return added
    }
}
