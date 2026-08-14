import Testing
import Foundation
import AgentKit
import Instruments
@testable import Persistence

// ─────────────────────────────────────────────────────────────
// Instruments against a real SurrealDB (ARCHITECTURE §20.3 · §20.6).
//
// The delete path is here rather than only in M15 because the rule and the row
// are two different things: `InstrumentDisposal` decides, and this checks that
// deciding actually removes what it said it would — including the expert ratings,
// which are scores for questions that are about to stop existing.
// ─────────────────────────────────────────────────────────────

private func draft(_ title: String) -> Instrument {
    var instrument = Instrument(projectID: ProjectID("pj_disposal"), title: Bilingual(title))
    instrument.items = [Item(prompt: Bilingual("ข้อหนึ่ง"),
                             kind: .likert(levels: [Bilingual("1"), Bilingual("2")]),
                             isDemographic: true, order: 1)]
    return instrument
}

@Suite("Instrument store", .serialized)
struct InstrumentStoreTests {

    @Test("a draft and its expert ratings both go", .timeLimit(.minutes(2)))
    func discardRemovesRatingsToo() async throws {
        guard let server = try await makeServer(port: 18_651) else { return }
        defer { Task { await server.shutdown() } }
        let store = InstrumentStore(client: await server.client)

        let keep = draft("ที่เก็บไว้")
        let going = draft("ที่จะลบ")
        try await store.save(keep)
        try await store.save(going)
        for expert in ["ก", "ข", "ค"] {
            try await store.save(ExpertRating(itemID: going.items[0].id, expert: expert,
                                              congruence: 1, relevance: 4),
                                 instrument: going.id)
            try await store.save(ExpertRating(itemID: keep.items[0].id, expert: expert,
                                              congruence: 1, relevance: 4),
                                 instrument: keep.id)
        }
        #expect(try await store.ratings(instrument: going.id).count == 3)

        let discardable = try InstrumentDisposal.check(going, footprint: .untouched)
        try await store.delete(discardable)

        let remaining = try await store.all(project: ProjectID("pj_disposal"))
        #expect(remaining.map(\.id) == [keep.id])
        #expect(try await store.ratings(instrument: going.id).isEmpty)
        // And the neighbour's scores are untouched — the delete is scoped by
        // instrument id, not by "the ratings that were loaded a moment ago".
        #expect(try await store.ratings(instrument: keep.id).count == 3)
    }

    @Test("an approved version cannot be handed to delete at all", .timeLimit(.minutes(2)))
    func approvedCannotBeDeleted() async throws {
        // No server needed: the point is that the argument cannot be produced,
        // so the store is never reached.
        #expect(throws: DisposalRefusal.approved) {
            try InstrumentDisposal.check(
                draft("ผ่านประตูแล้ว"),
                footprint: InstrumentFootprint(isApproved: true, responses: 0, rounds: 0))
        }
    }
}
