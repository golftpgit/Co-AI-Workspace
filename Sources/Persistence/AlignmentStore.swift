import Foundation
import AgentKit
import Knowledge

// ─────────────────────────────────────────────────────────────
// Which names a person said are the same concept (ARCHITECTURE §11.8, P18.3).
//
// The rule has been complete since P18.3 and had nowhere to be answered:
// `EntityAligner` proposes merges between names in different scripts, and
// `canonicalKey` counts only the confirmed ones — so with nothing storing a
// confirmation, every suggestion stayed a suggestion forever.
//
// **Both answers are kept.** A rejected pair that comes back every time the
// screen opens is a screen somebody stops reading, and "we looked at this and
// said no" is the more useful of the two records: E.26 measured the highest-
// scoring suggestion in the fixture as a wrong one, so rejections are the
// common case rather than the exception.
// ─────────────────────────────────────────────────────────────

public actor AlignmentStore {
    private let client: SurrealClient

    public init(client: SurrealClient) {
        self.client = client
    }

    /// The id of a pair, independent of which side was named first: the
    /// decision is about the pair, not about the order somebody happened to
    /// see it in.
    public static func key(_ alignment: EntityAlignment) -> String {
        alignment.labels.map { EntityGraph.normalise($0.text) }.sorted().joined(separator: "\u{1}")
    }

    public func record(_ alignment: EntityAlignment, confirmed: Bool) async throws {
        var content = ContentBuilder()
        content.setString("uid", Self.key(alignment))
        content.set("labels", alignment.labels.map(\.text))
        content.set("similarity", alignment.similarity)
        content.set("confirmed", confirmed)
        content.raw("decided_at", "time::now()")
        try await client.exec(
            "UPSERT entity_alignment CONTENT \(content.content) WHERE uid = type::string($uid)",
            vars: content.vars)
    }

    /// Everything decided, confirmed and rejected alike. The caller needs both:
    /// the confirmed ones key the graph, and the rejected ones are what keeps
    /// them off the suggestion list.
    public func decided() async throws -> [EntityAlignment] {
        let rows = try await client.query("SELECT * FROM entity_alignment").first?.rows ?? []
        return rows.compactMap { row in
            guard let labels = row["labels"]?.arrayValue?.compactMap({ $0.stringValue }),
                  labels.count >= 2 else { return nil }
            return EntityAlignment(labels: labels.map(EntityLabel.init(text:)),
                                   similarity: row["similarity"]?.doubleValue ?? 0,
                                   confirmedByHuman: row["confirmed"]?.boolValue ?? false)
        }
    }

    /// Suggestions minus everything already answered — in either direction.
    public func unanswered(from proposals: [EntityAlignment]) async throws -> [EntityAlignment] {
        let answered = Set(try await decided().map(Self.key))
        return proposals.filter { !answered.contains(Self.key($0)) }
    }
}
