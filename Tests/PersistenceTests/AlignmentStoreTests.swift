import Testing
import Foundation
import AgentKit
import Knowledge
@testable import Persistence

// ─────────────────────────────────────────────────────────────
// P18.3's outstanding item — the merge rule had nowhere to be answered.
//
// `EntityAligner` proposes and `canonicalKey` counts only confirmed merges, so
// with nothing storing a confirmation every suggestion stayed a suggestion
// forever. E.26 is the reason both answers are worth keeping: the highest
// scoring suggestion in that fixture was a wrong one, which makes rejection
// the common case.
// ─────────────────────────────────────────────────────────────

private func pair(_ a: String, _ b: String, similarity: Double = 0.93) -> EntityAlignment {
    EntityAlignment(labels: [EntityLabel(text: a), EntityLabel(text: b)],
                    similarity: similarity)
}

@Suite("Deciding a merge", .serialized)
struct AlignmentStoreTests {

    @Test("a confirmed merge comes back confirmed, and keys the graph",
          .timeLimit(.minutes(2)))
    func confirmedSurvives() async throws {
        guard let server = try await makeServer(port: 18_720) else { return }
        defer { Task { await server.shutdown() } }
        let store = AlignmentStore(client: await server.client)

        try await store.record(pair("ภาวะหมดไฟ", "burnout"), confirmed: true)
        let decided = try await store.decided()
        #expect(decided.count == 1)
        #expect(decided.first?.confirmedByHuman == true)

        // What the confirmation is *for*: the graph keys both names as one.
        let key = EntityAligner.canonicalKey(for: "burnout", alignments: decided)
        #expect(key == EntityAligner.canonicalKey(for: "ภาวะหมดไฟ", alignments: decided))
    }

    /// The measured case (E.26): `ความดัน` ↔ `pressure` scored 0.919, higher
    /// than every correct merge in the fixture, and it is wrong.
    @Test("a rejected merge stays rejected and does not key anything",
          .timeLimit(.minutes(2)))
    func rejectedStaysRejected() async throws {
        guard let server = try await makeServer(port: 18_721) else { return }
        defer { Task { await server.shutdown() } }
        let store = AlignmentStore(client: await server.client)

        try await store.record(pair("ความดัน", "pressure", similarity: 0.919), confirmed: false)
        let decided = try await store.decided()
        #expect(decided.first?.confirmedByHuman == false)
        // Not confirmed, so it keys nothing — each name stays itself.
        #expect(EntityAligner.canonicalKey(for: "pressure", alignments: decided) == "pressure")
    }

    /// A suggestion list that keeps offering what somebody already said no to
    /// is a list they stop reading.
    @Test("an answered pair is not proposed again, whichever way round",
          .timeLimit(.minutes(2)))
    func answeredPairsDropOut() async throws {
        guard let server = try await makeServer(port: 18_722) else { return }
        defer { Task { await server.shutdown() } }
        let store = AlignmentStore(client: await server.client)

        try await store.record(pair("ความดัน", "pressure"), confirmed: false)
        let proposals = [pair("pressure", "ความดัน"), pair("ภาวะหมดไฟ", "burnout")]
        let left = try await store.unanswered(from: proposals)

        #expect(left.count == 1)
        #expect(left.first?.labels.contains { $0.text == "burnout" } == true)
    }

    @Test("changing your mind overwrites rather than adding a second row",
          .timeLimit(.minutes(2)))
    func decisionsAreOnePerPair() async throws {
        guard let server = try await makeServer(port: 18_723) else { return }
        defer { Task { await server.shutdown() } }
        let store = AlignmentStore(client: await server.client)

        try await store.record(pair("ภาวะหมดไฟ", "burnout"), confirmed: false)
        try await store.record(pair("burnout", "ภาวะหมดไฟ"), confirmed: true)

        let decided = try await store.decided()
        #expect(decided.count == 1, "the pair was answered twice and stored twice")
        #expect(decided.first?.confirmedByHuman == true)
    }
}
