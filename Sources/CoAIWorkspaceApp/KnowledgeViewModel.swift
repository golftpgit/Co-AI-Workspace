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
    private var alignmentStore: AlignmentStore?
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
    public func attach(relations: RelationStore, extractor: RelationExtractor,
                       alignments: AlignmentStore? = nil) async {
        self.relationStore = relations
        self.alignmentStore = alignments
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

    /// `kind` is what the person said this document is (§12.4, P6.7). It is
    /// asked once, beside the tier, and it is never guessed: `doc_type:
    /// proposal` is what turns a document into an analysis plan, and a system
    /// that inferred it would start writing plans out of literature reviews.
    public func ingest(_ urls: [URL], tier: SourceTier,
                       kind: DocumentKind? = nil) async {
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
                                                       tier: tier, kind: kind,
                                                       embedder: embedder)
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

    /// Throws out one edge (§11.4, P12).
    ///
    /// The arrow goes; the passage does not. And the rejection is recorded, so
    /// re-reading the document does not quietly put it back — a correction
    /// that an ingest can undo is a correction nobody will trust twice.
    public func rejectRelation(_ relation: StoredRelation) async {
        guard let relationStore else { return }
        do {
            try await relationStore.reject(relation)
            await reloadRelations()
            status = Status(message: "ลบความสัมพันธ์นี้แล้ว — ข้อความต้นทางยังอยู่ "
                            + "และการอ่านเอกสารนี้อีกครั้งจะไม่สร้างมันขึ้นมาใหม่",
                            isError: false)
        } catch {
            log.error("rejecting relation: \(error)")
            status = Status(message: "ลบความสัมพันธ์ไม่สำเร็จ: \(error)", isError: true)
        }
    }

    /// The stored edge behind a drawn one, or `nil` if it has gone.
    public func relation(matching edge: EntityGraph.Edge) -> StoredRelation? {
        relations.first { $0.chunkID == edge.chunkID
            && $0.subject == edge.subject && $0.object == edge.object
            && $0.predicate == edge.predicate }
    }

    // MARK: - merging names across languages (§11.8, P18.3)

    /// Suggested merges nobody has answered yet.
    public private(set) var mergeSuggestions: [EntityAlignment] = []
    /// The merges a person confirmed, which is what keys the graph.
    public private(set) var confirmedMerges: [EntityAlignment] = []

    /// Proposes merges between entity names written in different scripts.
    ///
    /// Every suggestion is a suggestion: E.26 measured the highest-scoring pair
    /// in the fixture as a *wrong* merge (`ความดัน` ↔ `pressure`, 0.919), higher
    /// than every correct one — so nothing here changes a graph, and the list
    /// exists to be answered rather than applied.
    public func proposeMerges() async {
        guard let alignments = alignmentStore else { return }
        let names = Array(Set(index.allChunks.flatMap(\.entities))).sorted()
        guard names.count > 1 else { mergeSuggestions = []; return }

        var vectors: [String: [Float]] = [:]
        for name in names.prefix(200) {
            guard let vector = try? await embedder.embed(name) else { continue }
            vectors[name] = vector
        }
        let proposals = EntityAligner.propose(names: names, vectors: vectors)
        mergeSuggestions = (try? await alignments.unanswered(from: proposals)) ?? proposals
        confirmedMerges = ((try? await alignments.decided()) ?? []).filter(\.confirmedByHuman)
    }

    /// Records what a person said about one suggestion, either way. A
    /// rejection is kept for the same reason as a confirmation: a list that
    /// keeps offering what somebody already refused is a list they stop
    /// reading.
    public func decideMerge(_ alignment: EntityAlignment, confirmed: Bool) async {
        guard let alignmentStore else { return }
        do {
            try await alignmentStore.record(alignment, confirmed: confirmed)
            mergeSuggestions.removeAll { AlignmentStore.key($0) == AlignmentStore.key(alignment) }
            confirmedMerges = ((try? await alignmentStore.decided()) ?? []).filter(\.confirmedByHuman)
            status = Status(message: confirmed
                            ? "รวมเป็นชื่อเดียวกันแล้ว — กราฟจะใช้ชื่อเดียวสำหรับทั้งสองคำ"
                            : "บันทึกว่าไม่ใช่คำเดียวกัน — จะไม่เสนออีก",
                            isError: false)
        } catch {
            log.error("recording alignment: \(error)")
            status = Status(message: "บันทึกคำตัดสินเรื่องชื่อไม่สำเร็จ: \(error)", isError: true)
        }
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

    /// P9.5 — encoding and writing happen off the main actor. Measured on a
    /// 24 MB archive: doing this here stalls the main actor for 81.6 ms, which
    /// is five dropped frames and reads as the app having hung; off it, 2.6 ms
    /// (E.29). Nothing bounds the size of somebody's knowledge base, so this
    /// only gets worse with use.
    public func export(to url: URL) async {
        let archive = index.export()
        do {
            try await Task.detached(priority: .userInitiated) {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                try encoder.encode(archive).write(to: url)
            }.value
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
            // Read and decode off the main actor, for the reason in `export`.
            let archive = try await Task.detached(priority: .userInitiated) {
                try JSONDecoder().decode(KnowledgeArchive.self, from: Data(contentsOf: url))
            }.value
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

    // MARK: - the shelf (§11.9, P18.4)

    /// How each document is classified. Keyed by document id, and held here
    /// rather than on `DocumentSummary` because a person's correction has to
    /// outlive a reload of the index.
    public private(set) var classifications: [String: Classification] = [:]

    /// Which class the list is filtered to, or nil for the whole shelf.
    /// `unclassifiedFilter` is its own state rather than a magic code, because
    /// "show me what nothing could be filed under" is exactly the question the
    /// shelf exists to make askable.
    public var shelfFilter: String?
    public static let unclassifiedFilter = "—"

    /// The proportions the shelf screen draws, unclassified documents included.
    public var shelf: (byCode: [(code: String, label: String, count: Int)], unclassified: Int) {
        Classifier.breakdown(documents.map { classification(of: $0) })
    }

    public func classification(of document: DocumentSummary) -> Classification {
        classifications[document.documentID] ?? .unclassified
    }

    /// The documents the list should show, given the filter.
    public var shelvedDocuments: [DocumentSummary] {
        guard let shelfFilter else { return documents }
        if shelfFilter == Self.unclassifiedFilter {
            return documents.filter { !classification(of: $0).isClassified }
        }
        return documents.filter {
            classification(of: $0).subjects.contains { $0.code == shelfFilter }
        }
    }

    /// A person putting a document where it belongs. Marked as theirs, and the
    /// classifier never overwrites it afterwards (§11.9).
    public func reclassify(_ document: DocumentSummary, to codes: [String]) {
        let subjects = codes.compactMap(LCSubject.init(code:))
        classifications[document.documentID] = subjects.isEmpty
            ? Classification(subjects: [], assignedBy: .user, reason: "")
            : Classifier.assign(subjects)
    }

    /// Which LC classes each entity appears under (§11.9, P18.5).
    ///
    /// An entity belongs to the classes of the documents it is named in — there
    /// is no other place a class could come from, and asking a model would be
    /// inventing one. Built from what is already loaded, so it costs a pass
    /// over the chunks rather than anything remote.
    public var classesByEntity: [String: Set<LCClass>] {
        var byEntity: [String: Set<LCClass>] = [:]
        for document in documents {
            let classes = Set(classification(of: document).subjects.map(\.class))
            guard !classes.isEmpty else { continue }
            for entity in document.entities {
                byEntity[EntityGraph.normalise(entity), default: []].formUnion(classes)
            }
        }
        return byEntity
    }

    /// Whether an edge joins two different classes — the line §11.9 says is
    /// the interesting one in interdisciplinary work.
    ///
    /// **An end with no class is not a crossing.** Guessing otherwise would
    /// highlight exactly the entities nobody has classified, which is the
    /// opposite of the intent.
    public func crossesClasses(_ edge: EntityGraph.Edge,
                               using classes: [String: Set<LCClass>]) -> Bool {
        guard let subject = classes[EntityGraph.normalise(edge.subject)],
              let object = classes[EntityGraph.normalise(edge.object)],
              !subject.isEmpty, !object.isEmpty else { return false }
        return subject.isDisjoint(with: object)
    }

    // MARK: -

    public func refresh() {
        documents = index.documents(in: scope)
        classify()
    }

    /// Classifies anything that has no classification yet.
    ///
    /// Only what is missing: a document a person filed by hand keeps their
    /// answer, because the whole point of recording *who* assigned a class is
    /// that the machine's guess loses to a person's decision.
    private func classify() {
        for document in documents where classifications[document.documentID] == nil {
            let text = (index.chunks(of: document.documentID).map(\.text).prefix(6))
                .joined(separator: " ")
            classifications[document.documentID] = Classifier.classify(text,
                                                                       title: document.title)
        }
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
