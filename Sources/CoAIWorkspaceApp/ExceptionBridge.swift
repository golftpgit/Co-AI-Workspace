import Foundation
import AgentKit
import ProjectKit
import Persistence
import Knowledge

// ─────────────────────────────────────────────────────────────
// The join between the rule and the row (ARCHITECTURE §19.10, P10.6).
//
// `ProjectKit` owns `ExceptionReport` and never imports a database;
// `Persistence` owns the table and never imports the rules. Something has to
// know both, and it is the app — the same place that already knows every other
// pairing on the wiring diagram.
//
// Encoding lives here rather than in either module for the same reason: the
// blob's shape is a fact about this pairing, not about the report or the row.
// ─────────────────────────────────────────────────────────────

struct ExceptionBridge: ExceptionPersisting {
    let store: ExceptionStore

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func save(_ report: ExceptionReport) async throws {
        let json = String(decoding: try Self.encoder.encode(report), as: UTF8.self)
        try await store.save(ExceptionReportRecord(
            id: report.id,
            projectID: report.projectID.rawValue,
            dimension: report.dimension.rawValue,
            isOpen: report.isOpen,
            json: json))
    }

    func all(project: ProjectID) async throws -> [ExceptionReport] {
        try await store.all(project: project.rawValue).compactMap { record in
            guard let data = record.json.data(using: .utf8) else { return nil }
            return try? Self.decoder.decode(ExceptionReport.self, from: data)
        }
    }
}

struct RegisterBridge: RegisterPersisting {
    let store: RegisterStore

    func save(_ entry: RegisterEntry) async throws {
        let json = String(decoding: try Coding.encoder.encode(entry), as: UTF8.self)
        try await store.save(RegisterRecord(id: entry.id,
                                            projectID: entry.projectID.rawValue,
                                            kind: entry.kind.rawValue,
                                            isOpen: entry.status.isOpen,
                                            json: json))
    }

    func all(project: ProjectID) async throws -> [RegisterEntry] {
        try await store.all(project: project.rawValue).compactMap {
            try? Coding.decoder.decode(RegisterEntry.self, from: Data($0.json.utf8))
        }
    }
}

struct BaselineBridge: BaselinePersisting {
    let store: BaselineStore

    func save(_ baseline: Baseline) async throws {
        let json = String(decoding: try Coding.encoder.encode(baseline), as: UTF8.self)
        try await store.save(BaselineRecord(id: baseline.id,
                                            projectID: baseline.projectID.rawValue,
                                            version: baseline.version,
                                            json: json))
    }

    func all(project: ProjectID) async throws -> [Baseline] {
        try await store.all(project: project.rawValue).compactMap {
            try? Coding.decoder.decode(Baseline.self, from: Data($0.json.utf8))
        }
    }
}

/// Lessons into the central knowledge base (§19.11, §19.12 condition 7).
///
/// Written as ordinary chunks, in `central`, with system-authored provenance —
/// so the next project finds them through the same search as everything else
/// rather than through a special case. `Provenance.authored` is the right shape
/// precisely because a lesson has no external credibility to claim: it says
/// which project produced it, and that is the whole of its standing.
struct LessonBridge: LessonPublishing {
    let knowledge: KnowledgeStore

    func publish(_ lessons: [RegisterEntry], from project: Project) async throws {
        let chunks = lessons.compactMap { entry -> IndexedChunk? in
            guard case .lesson(let cause, let doDifferently, let appliesTo) = entry.detail else {
                return nil
            }
            let text = """
            บทเรียนจากโปรเจกต์ “\(project.name)”: \(entry.title)
            สาเหตุ: \(cause)
            ครั้งหน้าจะทำต่างไป: \(doDifferently)
            ใช้กับ: \(appliesTo)
            """
            return IndexedChunk(
                id: entry.id,
                text: text,
                // Central, not the project's own scope — a lesson filed where
                // only the finished project can see it has taught nobody.
                scope: .central,
                provenance: .authored(documentID: "lessons/\(project.id.rawValue)",
                                      title: "บทเรียน — \(project.name)",
                                      runID: entry.id))
        }
        guard !chunks.isEmpty else { return }
        try await knowledge.save(chunks)
    }
}

/// One encoder and one decoder for every bridge in this file. Dates as ISO-8601
/// on both sides, because a blob written by one and read by the other is the
/// classic way a round-trip stops round-tripping.
private enum Coding {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
