import Foundation
import Observation
import UniformTypeIdentifiers
import AgentKit
import Knowledge
import EmbeddingRuntime
import Observability

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

    public init(embedder: MLXEmbedder = MLXEmbedder()) {
        self.embedder = embedder
        self.index = KnowledgeIndex(profile: embedder.profile)
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
        refresh()
        await search()
        status = Status(message: "แก้ entity แล้ว — ผลค้นหาอัปเดตตาม", isError: false)
    }

    public func delete(documentID: String) async {
        let removed = index.removeDocument(documentID)
        refresh()
        await search()
        status = Status(message: "ลบเอกสารแล้ว (\(removed) ส่วน)", isError: false)
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
        refresh()
        await search()
    }
}
