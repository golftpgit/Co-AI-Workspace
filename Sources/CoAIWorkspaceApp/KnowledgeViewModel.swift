import Foundation
import Observation
import UniformTypeIdentifiers
import AgentKit
import Knowledge
import Instruments
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
    /// Which project the app is in, so the scope picker's "โปรเจกต์" option
    /// means a real one (§19.1). `nil` in General, where that option is
    /// disabled rather than filled in with a made-up id.
    public var currentProject: ProjectID?

    private var index: KnowledgeIndex
    private let embedder: MLXEmbedder
    private let pipeline = IngestionPipeline()
    private let log = AppLog.logger("knowledge")
    /// Nil until the database is up. The screen still works without it — in
    /// memory only — and says so, rather than pretending an ingest was saved.
    private var store: KnowledgeStore?
    private var policySource: PolicyLibrarySource?
    private var relationStore: RelationStore?
    private var relationExtractor: RelationExtractor?
    public private(set) var relations: [StoredRelation] = []
    private var conflictStore: ConflictStore?
    private var conflictDetector: ConflictDetector?

    /// How much of a newly ingested document is checked against the rest of the
    /// library, and how wide each check looks. Both are small on purpose: every
    /// pair is a high-impact model call (§9.2), and the chunks most likely to
    /// contradict something are the ones stating the document's claims, which
    /// is where a document starts.
    private static let chunksReviewedPerIngest = 5
    private static let neighboursPerChunk = 3

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

    /// The hook chain's rulebook, so ingesting a policy document takes effect
    /// on the next tool call rather than at the next launch (R14).
    public func attach(policySource: PolicyLibrarySource) {
        self.policySource = policySource
    }

    /// Relation extraction is optional: it needs a model, and a machine with
    /// none should still be able to keep a knowledge base — it just has no
    /// graph until one is available.
    public func attach(relations: RelationStore, extractor: RelationExtractor) async {
        self.relationStore = relations
        self.relationExtractor = extractor
        await reloadRelations()
    }

    /// Conflict detection is optional in the same way relation extraction is:
    /// it needs a model. Without one the library still works — it just never
    /// raises a card.
    public func attach(conflicts: ConflictStore, detector: ConflictDetector) {
        self.conflictStore = conflicts
        self.conflictDetector = detector
    }

    /// One chunk by id, for the graph's "where did this arrow come from".
    ///
    /// Read from the live index rather than kept as a second copy: the graph
    /// is looked at long after ingest, and a stale copy would show the passage
    /// that used to be there.
    public func chunk(id: String) -> IndexedChunk? {
        index.allChunks.first { $0.id == id }
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

        // Whatever else this ingest does, if it lands in `policy` the gate has
        // to stop using the rulebook it parsed before (R14).
        defer { if scope == .policy { let source = policySource
                                      Task { await source?.invalidate() } } }
        var added = 0, skipped = 0, conflicts = 0, failed: [String] = []
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
                conflicts += await reviewForConflicts(newChunks)
            } catch {
                log.error("ingest \(url.lastPathComponent, privacy: .public): \(error)")
                failed.append("\(url.lastPathComponent): \(error)")
            }
        }

        refresh()
        if failed.isEmpty {
            // A contradiction the user is not told about is one they find out
            // from the answer instead of the library (§11.6).
            let raised = conflicts > 0
                ? " · พบความรู้ที่ขัดกัน \(conflicts) จุด ดูได้ที่แท็บข้อขัดแย้ง"
                : ""
            status = Status(message: "เพิ่ม \(added) ส่วน · ข้ามที่ซ้ำ \(skipped) ส่วน" + raised,
                            isError: false)
        } else {
            status = Status(message: failed.joined(separator: "\n"), isError: true)
        }
    }

    /// Puts an interview transcript into the knowledge base (§20.9, P11.8).
    ///
    /// Not `ingest(_ urls:)` with a temporary file, which was the tempting
    /// shortcut: writing the transcript out and reading it back would lose the
    /// character offsets, and those offsets are what let a retrieved chunk cite
    /// *the passage* instead of the whole two-hour interview. `TranscriptIngest`
    /// chunks it and keeps the spans; this puts the result through the same
    /// dedup and embedding path an uploaded document takes.
    ///
    /// **Refused outside a project.** An interview belongs to the study that
    /// collected it. Landing one in `central` would put a participant's words
    /// in the library every other project searches, and in `policy` it would
    /// become a rule the hook chain enforces — neither is a mistake worth
    /// leaving available, and neither is undoable by the person who notices.
    public func ingest(transcript: Transcript) async {
        guard case .project = scope else {
            status = Status(message: "บทถอดเทปเข้าคลังของโครงการเท่านั้น — "
                            + "คลังกลางถูกค้นจากทุกโครงการ คำพูดของผู้เข้าร่วมจึงไม่ควรไปอยู่ตรงนั้น "
                            + "(§20.7) · เปลี่ยนไปที่โครงการที่เก็บบทสัมภาษณ์นี้ก่อน",
                            isError: true)
            return
        }
        isWorking = true
        defer { isWorking = false }

        let chunks = TranscriptIngest.chunks(of: transcript)
            .map { (chunk: $0.0, provenance: $0.1) }
        guard !chunks.isEmpty else {
            status = Status(message: "บทถอดเทปนี้ยังไม่มีเนื้อความให้เข้าคลัง", isError: true)
            return
        }

        do {
            var working = index
            let report = try await pipeline.ingest(chunks: chunks, into: &working,
                                                   scope: scope,
                                                   documentID: transcript.id,
                                                   embedder: embedder)
            index = working

            let newChunks = index.allChunks.filter {
                $0.provenance.documentID == report.documentID
            }
            if let store {
                // The old version's rows go too, or the database keeps passages
                // the index has already stopped citing — a retracted sentence
                // that comes back on the next launch.
                if report.chunksReplaced > 0 { try await store.deleteDocument(transcript.id) }
                try await store.save(newChunks)
            }
            await extractRelations(from: newChunks)
            let conflicts = await reviewForConflicts(newChunks)

            refresh()
            var message = "เข้าคลังแล้ว \(report.chunksAdded) ส่วน จาก “\(transcript.title)” — "
                + "แต่ละส่วนอ้างกลับไปที่ช่วงข้อความในบทถอดเทปได้"
            if report.chunksReplaced > 0 {
                // Said out loud: "เพิ่ม 12 ส่วน" on its own hides that eleven
                // older passages just stopped being citable.
                message += " · แทนที่ของเดิม \(report.chunksReplaced) ส่วน "
                    + "เพราะบทถอดเทปนี้เคยเข้าคลังไปแล้ว"
            }
            if report.duplicatesSkipped > 0 {
                message += " · ข้ามที่ซ้ำ \(report.duplicatesSkipped) ส่วน"
            }
            if conflicts > 0 {
                message += " · พบความรู้ที่ขัดกัน \(conflicts) จุด ดูได้ที่แท็บข้อขัดแย้ง"
            }
            status = Status(message: message, isError: false)
        } catch {
            log.error("ingest transcript: \(error)")
            status = Status(message: ReadableFailure.message(
                for: error, doing: "นำบทถอดเทปเข้าคลังความรู้"), isError: true)
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

        await fillEntitiesWhereTaggerCannot(found, in: chunks)
    }

    /// Names the entities in documents `NLTagger` has no tagger for.
    ///
    /// It publishes no `.nameType` scheme for Thai, so a Thai document is
    /// indexed with an empty entity list — the same result as a document with
    /// no people or places in it. The model reading the same text for relations
    /// has already named its subjects and objects, and those are entities
    /// (§11.4), so they fill the gap without a second call.
    ///
    /// Only where the tagger abstained: where it works, its output is the one
    /// the entity list was built around, and quietly widening it would change
    /// what every existing document matches.
    private func fillEntitiesWhereTaggerCannot(_ found: [Relation],
                                               in chunks: [IndexedChunk]) async {
        let tagger = EntityExtractor()
        let namesByChunk = Dictionary(grouping: found, by: \.chunkID)

        for chunk in chunks where !tagger.canTag(chunk.text) {
            guard let relations = namesByChunk[chunk.id] else { continue }
            var entities = chunk.entities
            for name in relations.flatMap({ [$0.subject, $0.object] }) {
                let cleaned = name.trimmingCharacters(in: .whitespaces)
                if !cleaned.isEmpty, !entities.contains(cleaned) { entities.append(cleaned) }
            }
            guard entities != chunk.entities else { continue }

            _ = index.updateEntities(of: chunk.id, to: entities)
            do {
                try await store?.updateEntities(chunkID: chunk.id, to: entities)
            } catch {
                log.error("persisting entities from relations: \(error)")
            }
        }
    }

    /// Checks what just arrived against what was already in the library, and
    /// files the disagreements (§11.6, P3.6).
    ///
    /// Runs on ingest rather than on search: §11.6's promise is that the user
    /// is *told* two sources disagree, and a check that only fires when someone
    /// happens to search the right words is a check that a contradiction can
    /// sit behind indefinitely.
    ///
    /// The detector is still only shown pairs a real retrieval put side by
    /// side — each new chunk is searched for, and what came back with it is
    /// what gets compared — so nothing here trawls the library for
    /// disagreement nobody asked about.
    private func reviewForConflicts(_ newChunks: [IndexedChunk]) async -> Int {
        guard let conflictDetector, let conflictStore, !newChunks.isEmpty else { return 0 }

        // Anything already filed is left alone. Re-filing would overwrite the
        // weights on a card the user may have decided on, and re-open a
        // question §11.6 says is answered once.
        let alreadyFiled = Set(((try? await conflictStore.load(scope: scope)) ?? []).map(\.id))
        var ledger = ConflictLedger()
        var filed = 0

        for chunk in newChunks.prefix(Self.chunksReviewedPerIngest) {
            // The chunk itself ranks first; the rest are its neighbours, and
            // `review` skips pairs from the same document.
            guard let retrieved = try? await index.search(chunk.text, scope: scope,
                                                          embedder: embedder,
                                                          limit: Self.neighboursPerChunk + 1),
                  retrieved.contains(where: {
                      $0.provenance.documentID != chunk.provenance.documentID
                  })
            else { continue }

            let found = await conflictDetector.review(
                retrieved,
                question: chunk.provenance.title,
                scope: scope,
                into: &ledger,
                limit: Self.neighboursPerChunk + 1)

            for conflict in found where !alreadyFiled.contains(conflict.id) {
                do {
                    try await conflictStore.save(conflict, scope: scope)
                    filed += 1
                } catch {
                    log.error("filing conflict: \(error)")
                }
            }
        }

        return filed
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
        // The relations too. They were loaded once at attach and never again,
        // which nobody could see while nothing rendered them — the graph tab
        // (P2.7) showed central's relations with "โปรเจกต์" selected, and the
        // picker was telling the truth about a screen that was not.
        await reloadRelations()
        await search()
    }
}
