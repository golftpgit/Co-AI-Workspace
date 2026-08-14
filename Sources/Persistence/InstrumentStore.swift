import Foundation
import AgentKit
import Instruments

// ─────────────────────────────────────────────────────────────
// Instruments on disk (ARCHITECTURE §20.3, P11.2).
//
// Same arrangement as the other stores: the columns a query needs as primitives,
// the value as a blob. `version` is a column beside the id because §20.6's first
// invariant is about versions — "which versions of this instrument exist" has to
// be answerable without decoding every row.
//
// Expert ratings live in their own table rather than inside the instrument:
// they arrive one expert at a time, often after the instrument is otherwise
// finished, and rewriting the whole blob to add one rating is how two experts
// scoring at once lose one of the two.
// ─────────────────────────────────────────────────────────────

public actor InstrumentStore: InstrumentPersisting {
    private let client: SurrealClient

    public init(client: SurrealClient) {
        self.client = client
    }

    public func save(_ instrument: Instrument) async throws {
        let json = String(decoding: try Coding.encoder.encode(instrument), as: UTF8.self)
        var content = ContentBuilder()
        content.setString("uid", instrument.id)
        content.setString("project_id", instrument.projectID.rawValue)
        content.set("version", instrument.version)
        content.setString("instrument", json)
        content.raw("updated_at", "time::now()")

        try await client.exec(
            "UPSERT instrument CONTENT \(content.content) WHERE uid = type::string($uid)",
            vars: content.vars)
    }

    public func all(project: ProjectID) async throws -> [Instrument] {
        try await client.query("""
            SELECT * FROM instrument WHERE project_id = type::string($pid)
            ORDER BY updated_at DESC
            """, vars: ["pid": project.rawValue])
            .first?.rows.compactMap { row in
                guard let json = row["instrument"]?.stringValue else { return nil }
                return try? Coding.decoder.decode(Instrument.self, from: Data(json.utf8))
            } ?? []
    }

    // MARK: - expert ratings (§20.4)

    public func save(_ rating: ExpertRating, instrument: String) async throws {
        let json = String(decoding: try Coding.encoder.encode(rating), as: UTF8.self)
        var content = ContentBuilder()
        // One rating per expert per item: a second submission is the same expert
        // changing their mind, not a second opinion.
        content.setString("uid", "\(instrument)|\(rating.itemID)|\(rating.expert)")
        content.setString("instrument_id", instrument)
        content.setString("item_id", rating.itemID)
        content.setString("rating", json)
        content.raw("updated_at", "time::now()")

        try await client.exec(
            "UPSERT expert_rating CONTENT \(content.content) WHERE uid = type::string($uid)",
            vars: content.vars)
    }

    public func ratings(instrument: String) async throws -> [ExpertRating] {
        try await client.query("""
            SELECT * FROM expert_rating WHERE instrument_id = type::string($iid)
            """, vars: ["iid": instrument])
            .first?.rows.compactMap { row in
                guard let json = row["rating"]?.stringValue else { return nil }
                return try? Coding.decoder.decode(ExpertRating.self, from: Data(json.utf8))
            } ?? []
    }

    // MARK: - approvals (§20.5)

    /// Records that a version passed the gate. One row per version, and the id is
    /// the version itself: approving twice is the same approval, not a second one,
    /// and a version can never be un-approved by writing over it — editing it is
    /// what `nextVersion` is for.
    public func save(_ approval: InstrumentApproval) async throws {
        let json = String(decoding: try Coding.encoder.encode(approval), as: UTF8.self)
        var content = ContentBuilder()
        content.setString("uid", approval.id)
        content.setString("instrument_id", approval.instrumentID)
        content.set("version", approval.version)
        content.setString("approval", json)
        content.raw("approved_at", "time::now()")

        try await client.exec(
            "UPSERT instrument_approval CONTENT \(content.content) WHERE uid = type::string($uid)",
            vars: content.vars)
    }

    public func approval(instrument: String) async throws -> InstrumentApproval? {
        let rows = try await client.query("""
            SELECT * FROM instrument_approval WHERE instrument_id = type::string($iid)
            """, vars: ["iid": instrument])
            .first?.rows ?? []
        return rows.compactMap { row -> InstrumentApproval? in
            guard let json = row["approval"]?.stringValue else { return nil }
            return try? Coding.decoder.decode(InstrumentApproval.self, from: Data(json.utf8))
        }.first
    }
}
