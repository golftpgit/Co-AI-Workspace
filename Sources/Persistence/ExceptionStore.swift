import Foundation
import AgentKit

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

public actor ExceptionStore {
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

    public func save(_ report: ExceptionReportRecord) async throws {
        var content = ContentBuilder()
        content.setString("uid", report.id)
        content.setString("project_id", report.projectID)
        content.setString("dimension", report.dimension)
        content.set("open", report.isOpen)
        content.setString("report", report.json)
        content.raw("updated_at", "time::now()")

        try await client.exec(
            "UPSERT exception CONTENT \(content.content) WHERE uid = type::string($uid)",
            vars: content.vars)
    }

    public func all(project: String) async throws -> [ExceptionReportRecord] {
        try await client.query(
            "SELECT * FROM exception WHERE project_id = type::string($pid) ORDER BY updated_at DESC",
            vars: ["pid": project])
            .first?.rows.compactMap { row in
                guard let id = row["uid"]?.stringValue,
                      let json = row["report"]?.stringValue else { return nil }
                return ExceptionReportRecord(
                    id: id,
                    projectID: row["project_id"]?.stringValue ?? project,
                    dimension: row["dimension"]?.stringValue ?? "",
                    isOpen: row["open"]?.boolValue ?? true,
                    json: json)
            } ?? []
    }
}

/// The stored shape, kept deliberately dumb.
///
/// `Persistence` does not import `ProjectKit` — the row is columns plus a blob,
/// and the module that owns the type is the one that decodes it. That keeps the
/// dependency pointing one way, the same as `ProjectPersisting`.
public struct ExceptionReportRecord: Sendable, Equatable {
    public let id: String
    public let projectID: String
    public let dimension: String
    public let isOpen: Bool
    public let json: String

    public init(id: String, projectID: String, dimension: String,
                isOpen: Bool, json: String) {
        self.id = id
        self.projectID = projectID
        self.dimension = dimension
        self.isOpen = isOpen
        self.json = json
    }
}
