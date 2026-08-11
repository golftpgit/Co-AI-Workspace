import Foundation
import Observation
import UniformTypeIdentifiers
import AgentKit
import Knowledge
import EmbeddingRuntime
import Observability
import Persistence
import CoreEngine

// ─────────────────────────────────────────────────────────────
// The knowledge base screen's state (ARCHITECTURE §14.2, P2.7).
//
// Held by the app, not rebuilt per body pass — the same mistake that made
// approvals disappear in P1.10 (a view model recreated on every render sent
// its answers to an instance nobody was showing).
//
// The index is in memory for now. Persisting it to SurrealDB is the next
// piece of P2 work and the screen is written so that swap changes this file
// only.
// ─────────────────────────────────────────────────────────────

@MainActor
@Observable
public final class KnowledgeViewModel {
    public struct Status: Equatable {
        public var message: String
        public var isError: Bool
    }

    public private(set) var documents: [DocumentSummary] = []
    public private(set) var results: [SearchResult] = []
    public private(set) var status: Status?
    public private(set) var isWorking = false
    public var query = ""
    public var scope: Scope = .central

    private var index: KnowledgeIndex
    private let embedder: MLXEmbedder
    private let pipeline = IngestionPipeline()
    private let log = AppLog.logger("knowledge")
    /// Nil until the database is up. The screen still works without it — in
    /// memory only — and says so, rather than pretending an ingest was saved.
    private var store: KnowledgeStore?
    private var relationStore: RelationStore?
    private var relationExtractor: RelationExtractor?
    public private(set) var relations: [StoredRelation] = []

    public init(embedder: MLXEmbedder = MLXEmbedder()) {
        self.embedder = embedder
        self.index = KnowledgeIndex(profile: embedder.profile)
    }

    /// Loads the scope from the database into the searchable index. Vectors
    /// built by a different model are dropped rather than mixed in: they would
    /// be accepted by nothing downstream and would rank nonsense if they were
    /// (P2.8). Their text stays, so a re-embed can restore them.
    public func attach(store: KnowledgeStore) async {
        self.store = store
        await reload()
    }

    /// Relation extraction is optional: it needs a model, and a machine with
    /// none should still be able to keep a knowledge base — it just has no
    /// graph until one is available.
    public func attach(relations: RelationStore, extractor: RelationExtractor) async {
        self.relationStore = relations
        self.relationExtractor = extractor
        await reloadRelations()
    }

    public func reloadRelations() async {
        guard let relationStore else { return }
        relations = (try? await relationStore.load(scope: scope)) ?? []
    }

    public func reload() async {
        guard let store else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            let stored = try await store.load(scope: scope)
            var rebuilt = KnowledgeIndex(profile: embedder.profile)
            var foreign = 0
            for chunk in stored {
                if chunk.embedding != nil, chunk.embeddingProfileID != embedder.profile.id {
                    foreign += 1
                    try rebuilt.insert(chunk.withoutEmbedding())
                } else {
                    try rebuilt.insert(chunk)
                }
            }
            index = rebuilt
            refresh()
            if foreign > 0 {
                status = Status(message: "\(foreign) ส่วนถูกสร้าง vector ด้วยโมเดลอื่น "
                                + "— ค้นได้เฉพาะแบบข้อความจนกว่าจะ re-embed",
                                isError: true)
            }
        } catch {
            log.error("loading knowledge: \(error)")
            status = Status(message: "โหลดคลังจากฐานข้อมูลไม่สำเร็จ: \(error)", isError: true)
        }
    }

    public var documentCount: Int { documents.count }
    public var chunkCount: Int { index.count }

    // MARK: - ingestion

    public func ingest(_ urls: [URL], tier: SourceTier) async {
        guard !urls.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }

        var added = 0, skipped = 0, failed: [String] = []
        for url in urls {
            // A sandboxed app reaches a chosen file only inside this scope.
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            do {
                // The index is main-actor state and `ingest` is async, so it
                // cannot be passed inout directly. Working on a copy and
                // assigning back is the same thing here: nothing else can
                // touch it between the two, because everything on this model
                // runs on the main actor.
                var working = index
                let report = try await pipeline.ingest(url, into: &working, scope: scope,
                                                       tier: tier, embedder: embedder)
                index = working
                added += report.chunksAdded
                skipped += report.duplicatesSkipped

                // Written through immediately: an ingest that is only in
                // memory is one the user loses without ever being told.
                let newChunks = index.allChunks.filter {
                    $0.provenance.documentID == report.documentID
                }
                if let store { try await store.save(newChunks) }
                await extractRelations(from: newChunks)
            } catch {
                log.error("ingest \(url.lastPathComponent, privacy: .public): \(error)")
                failed.append("\(url.lastPathComponent): \(error)")
            }
        }

        refresh()
        if failed.isEmpty {
            status = Status(message: "เพิ่ม \(added) ส่วน · ข้ามที่ซ้ำ \(skipped) ส่วน",
                            isError: false)
        } else {
            status = Status(message: failed.joined(separator: "\n"), isError: true)
        }
    }

    // MARK: - search

    public func search() async {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []
            return
        }
        isWorking = true
        defer { isWorking = false }

        do {
            results = try await index.search(query, scope: scope, embedder: embedder, limit: 20)
        } catch {
            // Falling back to the lexical half is better than an empty screen,
            // and the user is told which one answered.
            log.error("hybrid search: \(error)")
            results = index.search(query, scope: scope, limit: 20)
            status = Status(message: "ค้นแบบข้อความอย่างเดียว (โมเดลใช้ไม่ได้): \(error)",
                            isError: true)
        }
    }

    // MARK: - editing

    /// The Done-when: correcting an entity has to change what the document
    /// answers, so the current search is re-run rather than left stale.
    public func updateEntities(chunkID: String, to entities: [String]) async {
        let cleaned = entities
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard index.updateEntities(of: chunkID, to: cleaned) else {
            status = Status(message: "ส่วนนี้ไม่อยู่ในคลังแล้ว", isError: true)
            return
        }
        do {
            try await store?.updateEntities(chunkID: chunkID, to: cleaned)
        } catch {
            log.error("persisting entities: \(error)")
            status = Status(message: "แก้ในหน้าจอแล้วแต่บันทึกไม่สำเร็จ: \(error)", isError: true)
            return
        }
        refresh()
        await search()
        status = Status(message: "แก้ entity แล้ว — ผลค้นหาอัปเดตตาม", isError: false)
    }

    public func delete(documentID: String) async {
        let removed = index.removeDocument(documentID)
        do {
            try await store?.deleteDocument(documentID)
            // Edges go with the document. One that outlives its evidence is
            // still queried, with nothing behind it.
            try await relationStore?.deleteDocument(documentID)
        } catch {
            log.error("deleting document: \(error)")
            status = Status(message: "ลบจากหน้าจอแล้วแต่ลบในฐานข้อมูลไม่สำเร็จ: \(error)",
                            isError: true)
            return
        }
        refresh()
        await search()
        status = Status(message: "ลบเอกสารแล้ว (\(removed) ส่วน)", isError: false)
    }

    /// Reads the graph edges out of freshly ingested text. Failures here are
    /// reported but never fatal: a document with no graph is still a document
    /// that can be searched and cited.
    private func extractRelations(from chunks: [IndexedChunk]) async {
        guard let relationExtractor, let relationStore, !chunks.isEmpty else { return }

        let found = await relationExtractor.relations(in: chunks)
        guard !found.isEmpty else { return }

        let documentOf = Dictionary(uniqueKeysWithValues:
            chunks.map { ($0.id, $0.provenance.documentID) })
        let stored = found.map { relation in
            StoredRelation(subject: relation.subject, predicate: relation.predicate,
                           object: relation.object, chunkID: relation.chunkID,
                           documentID: documentOf[relation.chunkID] ?? "")
        }
        do {
            try await relationStore.save(stored, scope: scope)
            await reloadRelations()
        } catch {
            log.error("saving relations: \(error)")
        }
    }

    // MARK: - export / import

    public func export(to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(index.export()).write(to: url)
            status = Status(message: "ส่งออกแล้ว: \(url.lastPathComponent)", isError: false)
        } catch {
            status = Status(message: "ส่งออกไม่สำเร็จ: \(error)", isError: true)
        }
    }

    public func importArchive(from url: URL) async {
        isWorking = true
        defer { isWorking = false }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        do {
            let archive = try JSONDecoder().decode(KnowledgeArchive.self,
                                                   from: Data(contentsOf: url))
            var working = index
            let added = try await working.importArchive(archive, embedder: embedder)
            index = working
            try await store?.save(working.allChunks)
            refresh()
            status = Status(message: "นำเข้า \(added) ส่วน "
                            + "(ที่ซ้ำถูกข้าม, vector สร้างใหม่ด้วยโมเดลปัจจุบัน)",
                            isError: false)
        } catch {
            status = Status(message: "นำเข้าไม่สำเร็จ: \(error)", isError: true)
        }
    }

    // MARK: -

    public func refresh() {
        documents = index.documents(in: scope)
    }

    public func changeScope(to scope: Scope) async {
        self.scope = scope
        // Each scope is its own body of knowledge, so switching means loading
        // a different one rather than filtering the same index.
        await reload()
        await search()
    }
}
