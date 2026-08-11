import Foundation
import AgentKit
import Knowledge

// ─────────────────────────────────────────────────────────────
// `ingest_url` (ARCHITECTURE §11.4, P3.5): a web page into the knowledge base,
// through the same path an uploaded file takes.
//
// One thing is deliberately not a parameter: the tier. An upload asks the user
// how much to trust it because nobody else can say; a web page already has an
// answer, from the source registry, and letting a caller pass one in would
// make "T1" mean "whoever ingested it said so".
// ─────────────────────────────────────────────────────────────

/// The seam that lets this be tested without the network — and lets a cached
/// or archived page be ingested later without changing anything here.
public protocol PageReading: Sendable {
    func fetch(_ url: URL) async throws -> FetchedPage
}

extension PageFetcher: PageReading {}

public struct URLIngestor: Sendable {
    private let reader: any PageReading
    private let chunker: Chunker
    private let nearDuplicateThreshold: Double

    public init(reader: any PageReading = PageFetcher(),
                chunker: Chunker = Chunker(),
                nearDuplicateThreshold: Double = 0.97) {
        self.reader = reader
        self.chunker = chunker
        self.nearDuplicateThreshold = nearDuplicateThreshold
    }

    @discardableResult
    public func ingest(_ address: String,
                       into index: inout KnowledgeIndex,
                       scope: Scope,
                       embedder: (any Embedder)? = nil) async throws -> IngestionReport {
        guard let url = URL(string: address) else { throw FetchError.invalidURL(address) }
        return try await ingest(url, into: &index, scope: scope, embedder: embedder)
    }

    @discardableResult
    public func ingest(_ url: URL,
                       into index: inout KnowledgeIndex,
                       scope: Scope,
                       embedder: (any Embedder)? = nil) async throws -> IngestionReport {
        let page = try await reader.fetch(url)

        if let embedder {
            let diagnosis = try await diagnose(embedder)
            guard diagnosis.isUsable else { throw IngestionError.embedderUnusable(diagnosis) }
        }

        var added = 0, exact = 0, near = 0

        for (position, paragraph) in page.paragraphs.enumerated() {
            // Paragraphs are chunked rather than taken whole: a page can put a
            // thousand words in one <p>, and the chunker is what keeps a chunk
            // within what the embedder can actually read.
            for piece in chunker.chunks(of: paragraph) {
                let hash = IngestionPipeline.contentHash(piece.text)
                guard !index.contains(contentHash: hash) else { exact += 1; continue }

                var embedding: [Float]?
                if let embedder { embedding = try await embedder.embed(piece.text) }
                if let embedding, index.containsNearDuplicate(of: embedding, scope: scope,
                                                              threshold: nearDuplicateThreshold) {
                    near += 1
                    continue
                }

                // Provenance is the page's, with the paragraph recorded so a
                // citation can point at the passage rather than at the URL.
                let provenance = Provenance(
                    documentID: page.provenance.documentID,
                    title: page.provenance.title,
                    origin: page.provenance.origin,
                    tier: page.provenance.tier ?? .t5,
                    page: position + 1,
                    section: "ย่อหน้า \(position + 1)",
                    accessedAt: page.provenance.accessedAt)

                try index.insert(IndexedChunk(
                    id: "\(page.provenance.documentID)#p\(position + 1)c\(piece.index)",
                    text: piece.text,
                    scope: scope,
                    provenance: provenance,
                    embedding: embedding,
                    embeddingProfileID: embedding == nil ? nil : embedder?.profile.id,
                    contentHash: hash,
                    entities: EntityExtractor().entities(in: piece.text)))
                added += 1
            }
        }

        return IngestionReport(documentID: page.provenance.documentID,
                               chunksAdded: added,
                               exactDuplicatesSkipped: exact,
                               nearDuplicatesSkipped: near,
                               usedOCR: false,
                               pages: page.paragraphs.count)
    }
}
