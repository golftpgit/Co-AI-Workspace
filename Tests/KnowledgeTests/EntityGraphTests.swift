import Testing
import Foundation
@testable import Knowledge

// ─────────────────────────────────────────────────────────────
// P2.7's outstanding half — the oldest item in the plan (U4).
//
// The tests worth writing are not "does it build a graph". They are the four
// ways a graph view lies: showing part of the data as though it were all of it,
// placing a node by whichever edge arrived first, drawing differently on each
// redraw, and turning a sentence somebody wrote into an arrow with no source.
// ─────────────────────────────────────────────────────────────

private func relation(_ subject: String, _ predicate: String, _ object: String,
                      chunk: String = "c1", document: String = "d1") -> EntityGraph.Relation {
    EntityGraph.Relation(subject: subject, predicate: predicate, object: object,
                         chunkID: chunk, documentID: document)
}

@Suite("Entity graph — P2.7")
struct EntityGraphTests {

    private let chain = [
        relation("ภาวะหมดไฟ", "พบใน", "พยาบาลไอซียู"),
        relation("พยาบาลไอซียู", "ทำงานที่", "โรงพยาบาล"),
        relation("โรงพยาบาล", "อยู่ใน", "จังหวัดเชียงใหม่"),
        relation("จังหวัดเชียงใหม่", "อยู่ใน", "ภาคเหนือ"),
    ]

    @Test("the focus is at the centre and its neighbours are one ring out")
    func radialLayout() {
        let graph = EntityGraph.around("ภาวะหมดไฟ", in: chain, hops: 2)
        let focus = graph.nodes.first { $0.entity == "ภาวะหมดไฟ" }
        #expect(focus?.hop == 0)
        #expect(focus?.x == 0 && focus?.y == 0)
        #expect(graph.nodes.first { $0.entity == "พยาบาลไอซียู" }?.hop == 1)
        #expect(graph.nodes.first { $0.entity == "โรงพยาบาล" }?.hop == 2)
    }

    // Decision 1. A picture that quietly shows part of the graph is worse than
    // a list, because it looks complete.
    @Test("what is beyond the horizon is counted and said, not dropped")
    func horizonIsReported() {
        let graph = EntityGraph.around("ภาวะหมดไฟ", in: chain, hops: 2)
        #expect(graph.nodes.contains { $0.entity == "จังหวัดเชียงใหม่" } == false)
        #expect(graph.beyondHorizon == 1)
        #expect(graph.summary.contains("1 more lie beyond what is shown"))
    }

    @Test("raising the hop limit brings the far ones in")
    func moreHopsShowsMore() {
        let wider = EntityGraph.around("ภาวะหมดไฟ", in: chain, hops: 4)
        #expect(wider.beyondHorizon == 0)
        #expect(wider.nodes.contains { $0.entity == "ภาคเหนือ" })
    }

    // Decision 2. First-edge-wins would place this at 2 when a shorter path
    // exists, and the answer would depend on database row order.
    @Test("a node sits at its shortest distance, not at the first path found")
    func shortestPathWins() {
        let relations = [
            relation("ก", "→", "ข"),
            relation("ข", "→", "ค"),
            // A direct edge, listed last on purpose.
            relation("ก", "→", "ค"),
        ]
        #expect(EntityGraph.around("ก", in: relations, hops: 3)
            .nodes.first { $0.entity == "ค" }?.hop == 1)
    }

    // Decision 3. Two people looking at "the same" picture should be.
    @Test("the same relations in a different order give an identical graph")
    func layoutIsDeterministic() {
        let forwards = EntityGraph.around("ภาวะหมดไฟ", in: chain, hops: 3)
        let backwards = EntityGraph.around("ภาวะหมดไฟ", in: chain.reversed(), hops: 3)
        #expect(forwards == backwards)
    }

    // Decision 4. An arrow between two words looks like a fact; the source is
    // what makes it checkable.
    @Test("every edge carries the chunk that says so")
    func edgesKeepTheirSource() {
        let graph = EntityGraph.around("ภาวะหมดไฟ", in: chain, hops: 1)
        #expect(graph.edges.isEmpty == false)
        for edge in graph.edges {
            #expect(edge.chunkID.isEmpty == false)
            #expect(edge.documentID.isEmpty == false)
        }
    }

    // Two chunks saying the same thing is one edge in the picture and two
    // sources behind it — not one line drawn twice.
    @Test("the same statement from two chunks stays two edges, not one drawn twice")
    func duplicatesFromTwoSourcesAreKept() {
        let graph = EntityGraph.around("ก", in: [
            relation("ก", "→", "ข", chunk: "c1"),
            relation("ก", "→", "ข", chunk: "c2"),
        ], hops: 1)
        #expect(graph.edges.count == 2)
        #expect(graph.nodes.count == 2, "the same pair of things became four nodes")
    }

    @Test("an identical row twice is one edge")
    func identicalRowsCollapse() {
        let graph = EntityGraph.around("ก", in: [
            relation("ก", "→", "ข", chunk: "c1"),
            relation("ก", "→", "ข", chunk: "c1"),
        ], hops: 1)
        #expect(graph.edges.count == 1)
    }

    @Test("case and stray spaces are not different things")
    func normalisesLightly() {
        let graph = EntityGraph.around("Burnout", in: [
            relation("burnout", "found in", "ICU nurses"),
            relation(" Burnout ", "studied by", "Maslach"),
        ], hops: 1)
        #expect(graph.nodes.count == 3, "one entity was drawn as several")
    }

    @Test("a self-referential row does not draw a loop or a phantom node")
    func selfEdgesAreDropped() {
        let graph = EntityGraph.around("ก", in: [relation("ก", "คือ", "ก")], hops: 2)
        #expect(graph.edges.isEmpty)
        #expect(graph.isEmpty)
    }

    @Test("an entity nothing connects to says so rather than drawing an empty box")
    func isolatedFocusIsHonest() {
        let graph = EntityGraph.around("ไม่มีใครรู้จัก", in: chain, hops: 2)
        #expect(graph.isEmpty)
        #expect(graph.summary.contains("nothing has been extracted around"))
    }

    // A graph opened on a leaf shows one line and teaches nothing, so the
    // screen offers the busiest entities first.
    @Test("the busiest entities are offered first, by connection count")
    func busiestFirst() {
        let busiest = EntityGraph.busiestEntities(in: chain, limit: 2)
        #expect(busiest.contains("พยาบาลไอซียู"))
    }

    @Test("degree counts the edges actually shown, not the whole store")
    func degreeIsWithinTheView() {
        let graph = EntityGraph.around("ภาวะหมดไฟ", in: chain, hops: 1)
        #expect(graph.nodes.first { $0.entity == "ภาวะหมดไฟ" }?.degree == 1)
    }
}
