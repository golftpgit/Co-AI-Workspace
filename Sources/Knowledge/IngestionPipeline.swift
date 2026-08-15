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
    /// How many chunks of an earlier version of this document were removed to
    /// make room. Non-zero only when the same document was ingested before —
    /// a corrected transcript (§20.9) — and worth reporting, because "เพิ่ม 12
    /// ส่วน" hides that 11 older ones just stopped being citable.
    public let chunksReplaced: Int

    public var duplicatesSkipped: Int { exactDuplicatesSkipped + nearDuplicatesSkipped }

    /// Public because ingestion has more than one front door: a file from
    /// disk and a page from the web both report what they did the same way.
    public init(documentID: String, chunksAdded: Int,
                exactDuplicatesSkipped: Int, nearDuplicatesSkipped: Int,
                usedOCR: Bool, pages: Int, chunksReplaced: Int = 0) {
        self.chunksReplaced = chunksReplaced
        self.documentID = documentID
        self.chunksAdded = chunksAdded
        self.exactDuplicatesSkipped = exactDuplicatesSkipped
        self.nearDuplicatesSkipped = nearDuplicatesSkipped
        self.usedOCR = usedOCR
        self.pages = pages
    }
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

    // ─────────────────────────────────────────────────────────
    // Text that is already in the system
    // ─────────────────────────────────────────────────────────

    /// Ingests passages that came from inside the app rather than from a file
    /// — an interview transcript (§20.9, P11.8).
    ///
    /// Chunking is done by the caller because `TranscriptIngest` has to record
    /// *where in the transcript* each chunk came from, and a chunk that cannot
    /// be cited back to a passage turns a two-hour interview into a citation
    /// nobody can check. Everything after that — dedup, embedding,
    /// near-duplicate rejection — is the same path an uploaded document takes,
    /// because a transcript that were indexed differently would retrieve
    /// differently from everything else in the project.
    ///
    /// **Re-ingesting replaces.** A transcript keeps its id when it is
    /// corrected, so a second ingest is the *same document* said better. Adding
    /// the corrected passages beside the old ones would leave the knowledge
    /// base holding both versions of an interview with no way to tell which
    /// answer came from the retracted one — the exact failure §20.9 corrects
    /// transcripts to avoid. An uploaded file is content-addressed and so is a
    /// genuinely different document when it changes; this is not.
    public func ingest(chunks: [(chunk: Chunk, provenance: Provenance)],
                       into index: inout KnowledgeIndex,
                       scope: Scope,
                       documentID: String,
                       embedder: (any Embedder)? = nil) async throws -> IngestionReport {
        if let embedder {
            let diagnosis: EmbedderDiagnosis
            do { diagnosis = try await diagnose(embedder) }
            catch let error as EmbeddingError { throw IngestionError.embedding(error) }
            guard diagnosis.isUsable else { throw IngestionError.embedderUnusable(diagnosis) }
        }

        // Before anything is inserted, and only once the embedder is known to
        // work: a replace that threw halfway would otherwise leave the
        // knowledge base with neither version.
        let replaced = index.removeDocument(documentID)

        var added = 0, exact = 0, near = 0
        for (position, entry) in chunks.enumerated() {
            let hash = Self.contentHash(entry.chunk.text)
            guard !index.contains(contentHash: hash) else { exact += 1; continue }

            var embedding: [Float]?
            if let embedder {
                do { embedding = try await embedder.embed(entry.chunk.text) }
                catch let error as EmbeddingError { throw IngestionError.embedding(error) }
            }
            if let embedding, index.containsNearDuplicate(of: embedding, scope: scope,
                                                          threshold: nearDuplicateThreshold) {
                near += 1
                continue
            }

            try index.insert(IndexedChunk(
                id: "\(documentID)#c\(position)",
                text: entry.chunk.text,
                scope: scope,
                provenance: entry.provenance,
                embedding: embedding,
                embeddingProfileID: embedding == nil ? nil : embedder?.profile.id,
                contentHash: hash,
                entities: EntityExtractor().entities(in: entry.chunk.text)))
            added += 1
        }

        return IngestionReport(documentID: documentID, chunksAdded: added,
                               exactDuplicatesSkipped: exact, nearDuplicatesSkipped: near,
                               usedOCR: false, pages: 1, chunksReplaced: replaced)
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

    /// Whether the tagger can name entities in this text at all.
    ///
    /// `NLTagger` publishes no `.nameType` scheme for Thai, so on a Thai
    /// document `entities(in:)` returns an empty list that is indistinguishable
    /// from "there are no people or places in here" — which is how a Thai
    /// library ends up with no graph and nobody notices. Callers that have a
    /// model available should ask it instead when this is false.
    public func canTag(_ text: String) -> Bool {
        guard let language = NLLanguageRecognizer.dominantLanguage(for: text) else { return false }
        return NLTagger.availableTagSchemes(for: .word, language: language).contains(.nameType)
    }

    public func entities(in text: String) -> [String] {
        guard canTag(text) else { return [] }

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
