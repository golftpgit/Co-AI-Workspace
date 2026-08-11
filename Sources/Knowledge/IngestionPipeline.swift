import Foundation
import CryptoKit
import NaturalLanguage
import AgentKit

// ─────────────────────────────────────────────────────────────
// One document in, indexed chunks out (ARCHITECTURE §11, P2.3):
// read → OCR when the page is a picture → chunk → dedup → embed → index.
//
// Two things this refuses to do, both of them silent failures otherwise:
//  • index through an embedder that cannot read the document's script — the
//    vectors would all be identical and search would rank noise (E.11);
//  • add the same content twice, whether it arrives byte-identical or as the
//    same passage re-scanned with different OCR noise.
// ─────────────────────────────────────────────────────────────

public struct IngestionReport: Sendable, Equatable {
    public let documentID: String
    public let chunksAdded: Int
    public let exactDuplicatesSkipped: Int
    public let nearDuplicatesSkipped: Int
    public let usedOCR: Bool
    public let pages: Int

    public var duplicatesSkipped: Int { exactDuplicatesSkipped + nearDuplicatesSkipped }
}

public enum IngestionError: Error, CustomStringConvertible {
    case read(DocumentReadError)
    case embedderUnusable(EmbedderDiagnosis)
    case embedding(EmbeddingError)

    public var description: String {
        switch self {
        case .read(let e): return e.description
        case .embedderUnusable(let d):
            return "the embedding model cannot read this content (\(d)) — indexing would produce identical vectors"
        case .embedding(let e): return e.description
        }
    }
}

public struct IngestionPipeline: Sendable {
    private let reader: DocumentReader
    private let chunker: Chunker
    /// Cosine at or above which two chunks are the same passage. 0.97 is high
    /// on purpose: two paragraphs about one subject sit well below it, and the
    /// cost of a wrong merge (knowledge silently missing) is worse than the
    /// cost of a duplicate.
    private let nearDuplicateThreshold: Double

    public init(reader: DocumentReader = DocumentReader(),
                chunker: Chunker = Chunker(),
                nearDuplicateThreshold: Double = 0.97) {
        self.reader = reader
        self.chunker = chunker
        self.nearDuplicateThreshold = nearDuplicateThreshold
    }

    /// `embedder` is optional so a machine with no embedding endpoint can still
    /// build the lexical half of the index rather than refusing to ingest at
    /// all — hybrid search already tolerates chunks without vectors.
    public func ingest(_ url: URL,
                       into index: inout KnowledgeIndex,
                       scope: Scope,
                       tier: SourceTier,
                       title: String? = nil,
                       documentID: String? = nil,
                       embedder: (any Embedder)? = nil) async throws -> IngestionReport {
        let document: ReadDocument
        do {
            document = try reader.read(url)
        } catch let error as DocumentReadError {
            throw IngestionError.read(error)
        }

        if let embedder {
            let diagnosis: EmbedderDiagnosis
            do { diagnosis = try await diagnose(embedder) }
            catch let error as EmbeddingError { throw IngestionError.embedding(error) }
            guard diagnosis.isUsable else { throw IngestionError.embedderUnusable(diagnosis) }
        }

        // Stable across re-ingestion of the same file, which is what makes
        // "ingest twice, index once" work even after a restart.
        let id = documentID ?? Self.documentID(for: url)
        let name = title ?? url.deletingPathExtension().lastPathComponent

        var added = 0, exact = 0, near = 0

        for (pageNumber, page) in document.pages.enumerated() {
            for chunk in chunker.chunks(of: page) {
                let hash = Self.contentHash(chunk.text)
                guard !index.contains(contentHash: hash) else { exact += 1; continue }

                var embedding: [Float]?
                if let embedder {
                    do { embedding = try await embedder.embed(chunk.text) }
                    catch let error as EmbeddingError { throw IngestionError.embedding(error) }
                }
                if let embedding, index.containsNearDuplicate(of: embedding, scope: scope,
                                                              threshold: nearDuplicateThreshold) {
                    near += 1
                    continue
                }

                let provenance = Provenance(
                    documentID: id,
                    title: name,
                    origin: .upload(filename: url.lastPathComponent),
                    tier: tier,
                    page: document.pages.count > 1 ? pageNumber + 1 : nil,
                    section: document.usedOCR ? "OCR" : nil)

                try index.insert(IndexedChunk(
                    id: "\(id)#p\(pageNumber + 1)c\(chunk.index)",
                    text: chunk.text,
                    scope: scope,
                    provenance: provenance,
                    embedding: embedding,
                    embeddingProfileID: embedding == nil ? nil : embedder?.profile.id,
                    contentHash: hash,
                    entities: EntityExtractor().entities(in: chunk.text)))
                added += 1
            }
        }

        return IngestionReport(documentID: id, chunksAdded: added,
                               exactDuplicatesSkipped: exact, nearDuplicatesSkipped: near,
                               usedOCR: document.usedOCR, pages: document.pages.count)
    }

    /// Content-addressed, not path-addressed: the same file copied to a second
    /// folder is the same document, and a re-scan that changes one pixel is
    /// not (the near-duplicate check catches that case instead).
    public static func documentID(for url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else {
            return "doc_" + Self.contentHash(url.path).prefix(16)
        }
        return "doc_" + SHA256.hash(data: data).map { String(format: "%02x", $0) }
            .joined().prefix(16)
    }

    /// Whitespace is normalised first so a reflowed paragraph is recognised as
    /// the same text rather than indexed twice. Public because anything that
    /// creates content for the index — a fetched page, an imported archive —
    /// has to hash it the same way or dedup silently stops working.
    public static func contentHash(_ text: String) -> String {
        let normalised = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return SHA256.hash(data: Data(normalised.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

/// People, places and organisations, for the knowledge graph (§11.4). Relations
/// between them need a model to read the sentence and land with the graph view;
/// this is the half that a tagger can do honestly on its own.
public struct EntityExtractor: Sendable {
    public init() {}

    public func entities(in text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text

        var found: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word,
                             scheme: .nameType,
                             options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            if let tag, [.personalName, .placeName, .organizationName].contains(tag) {
                let entity = String(text[range])
                if !found.contains(entity) { found.append(entity) }
            }
            return true
        }
        return found
    }
}
