import Foundation
import AgentKit
import Instruments

// ─────────────────────────────────────────────────────────────
// The qualitative half on disk (ARCHITECTURE §20.3, P11.8).
//
// Same arrangement as `InstrumentStore`: the columns a query needs as
// primitives, the value as a blob. Three tables rather than one blob per
// codebook, for the reason expert ratings are their own table — codings arrive
// one coder at a time, often weeks apart, and rewriting a whole codebook to
// record one decision is how two coders working the same evening lose one of
// the two sets.
//
// A coding is keyed by unit *and* coder, so a coder revisiting a passage
// replaces their own decision and never anybody else's. That is an upsert on
// purpose: a coder who changes their mind has changed their mind, and keeping
// both would put a person into a κ twice.
// ─────────────────────────────────────────────────────────────

public actor CodebookStore {
    private let client: SurrealClient

    public init(client: SurrealClient) {
        self.client = client
    }

    // MARK: - the book

    public func save(_ codebook: Codebook) async throws {
        var updated = codebook
        updated.updatedAt = Date()
        let json = String(decoding: try Coding.encoder.encode(updated), as: UTF8.self)
        var content = ContentBuilder()
        content.setString("uid", updated.id)
        content.setString("project_id", updated.projectID.rawValue)
        content.setString("codebook", json)
        content.raw("updated_at", "time::now()")

        try await client.exec(
            "UPSERT codebook CONTENT \(content.content) WHERE uid = type::string($uid)",
            vars: content.vars)
    }

    public func all(project: ProjectID) async throws -> [Codebook] {
        try await client.query("""
            SELECT * FROM codebook WHERE project_id = type::string($pid)
            ORDER BY updated_at DESC
            """, vars: ["pid": project.rawValue])
            .first?.rows.compactMap { row in
                guard let json = row["codebook"]?.stringValue else { return nil }
                return try? Coding.decoder.decode(Codebook.self, from: Data(json.utf8))
            } ?? []
    }

    // MARK: - the passages

    public func save(_ unit: CodingUnit, codebook: String) async throws {
        let json = String(decoding: try Coding.encoder.encode(unit), as: UTF8.self)
        var content = ContentBuilder()
        content.setString("uid", unit.id)
        content.setString("codebook_id", codebook)
        content.setString("document_id", unit.documentID)
        content.setString("unit", json)

        try await client.exec(
            "UPSERT coding_unit CONTENT \(content.content) WHERE uid = type::string($uid)",
            vars: content.vars)
    }

    public func units(codebook: String) async throws -> [CodingUnit] {
        try await client.query("""
            SELECT * FROM coding_unit WHERE codebook_id = type::string($cid)
            """, vars: ["cid": codebook])
            .first?.rows.compactMap { row in
                guard let json = row["unit"]?.stringValue else { return nil }
                return try? Coding.decoder.decode(CodingUnit.self, from: Data(json.utf8))
            }
            // Sorted here rather than by the database: the id carries the
            // document and the offset, and a stable order is what keeps two
            // runs of the same κ identical.
            .sorted { ($0.documentID, $0.range.lowerBound) < ($1.documentID, $1.range.lowerBound) }
            ?? []
    }

    // MARK: - the codings

    public func save(_ assignment: CodeAssignment, codebook: String) async throws {
        let json = String(decoding: try Coding.encoder.encode(assignment), as: UTF8.self)
        var content = ContentBuilder()
        // Unit and coder together: a coder revising a passage replaces their own
        // decision, never somebody else's.
        content.setString("uid", "\(codebook)|\(assignment.unitID)|\(assignment.coder)")
        content.setString("codebook_id", codebook)
        content.setString("coder", assignment.coder)
        content.setString("assignment", json)
        content.raw("updated_at", "time::now()")

        try await client.exec(
            "UPSERT code_assignment CONTENT \(content.content) WHERE uid = type::string($uid)",
            vars: content.vars)
    }

    public func assignments(codebook: String) async throws -> [CodeAssignment] {
        try await client.query("""
            SELECT * FROM code_assignment WHERE codebook_id = type::string($cid)
            """, vars: ["cid": codebook])
            .first?.rows.compactMap { row in
                guard let json = row["assignment"]?.stringValue else { return nil }
                return try? Coding.decoder.decode(CodeAssignment.self, from: Data(json.utf8))
            } ?? []
    }
}
