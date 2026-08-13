import Foundation
import AgentKit
import ProjectKit
import Persistence

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
