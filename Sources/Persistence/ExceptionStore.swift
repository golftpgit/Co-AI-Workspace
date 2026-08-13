import Foundation
import AgentKit
import ProjectKit

// ─────────────────────────────────────────────────────────────
// Exception reports, made durable (ARCHITECTURE §19.10, P10.6).
//
// Durable specifically because of what an open one does: it stops the project.
// A stop that is forgotten when the app closes is not a stop, it is a pause
// that happens to coincide with somebody being at their desk.
//
// The report is stored as JSON with `open` denormalised, because "is this
// project stopped" is asked on every tool call and must not require decoding
// every report ever written.
// ─────────────────────────────────────────────────────────────

public actor ExceptionStore: ExceptionPersisting {
    private let client: SurrealClient

    public init(client: SurrealClient) {
        self.client = client
    }

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

    public func save(_ report: ExceptionReport) async throws {
        let json = String(decoding: try Self.encoder.encode(report), as: UTF8.self)
        var content = ContentBuilder()
        content.setString("uid", report.id)
        content.setString("project_id", report.projectID.rawValue)
        content.setString("dimension", report.dimension.rawValue)
        content.set("open", report.isOpen)
        content.setString("report", json)
        content.raw("updated_at", "time::now()")

        try await client.exec(
            "UPSERT exception CONTENT \(content.content) WHERE uid = type::string($uid)",
            vars: content.vars)
    }

    public func all(project: ProjectID) async throws -> [ExceptionReport] {
        try await client.query(
            "SELECT * FROM exception WHERE project_id = type::string($pid) ORDER BY updated_at DESC",
            vars: ["pid": project.rawValue])
            .first?.rows.compactMap { row in
                guard let json = row["report"]?.stringValue else { return nil }
                return try? Self.decoder.decode(ExceptionReport.self, from: Data(json.utf8))
            } ?? []
    }
}
