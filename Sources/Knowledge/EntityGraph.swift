import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// The knowledge graph, as something a person can look at (ARCHITECTURE §11.4,
// P2.7 · the oldest outstanding item in the plan, U4 in the driving log).
//
// The relations have been extracted, stored and deleted-with-their-document
// since P2.7. What was missing is the half that makes a graph worth having:
// seeing it. The list that stands in for it today answers "what relations are
// there" and not "what is this thing connected to", which is the question
// somebody opens a graph to ask.
//
// Four decisions, and the first is the one that decides whether this is useful
// or decoration:
//
// **1. It is a neighbourhood, not the whole graph.** Five hundred nodes drawn
// at once is a hairball; it looks like a lot of knowledge and answers nothing.
// So there is always a focus, always a hop limit, and always a count of what
// was left out — a picture that silently shows a third of the graph is worse
// than a list.
//
// **2. A node sits at its shortest distance from the focus.** Breadth-first,
// not first-edge-wins. Otherwise the same graph draws differently depending on
// the order rows came back from the database, and two people looking at "the
// same" picture are not.
//
// **3. The layout is deterministic.** Same data, same picture, every time. A
// force-directed graph that settles somewhere new on each redraw is one nobody
// can point at and discuss. Radial rings cost nothing and can be described in
// a sentence: the focus in the middle, one ring per hop.
//
// **4. Every edge keeps the chunk that says so.** `Relation.chunkID` exists
// because an unfalsifiable graph is not knowledge, and a picture is exactly
// where that gets lost — an arrow between two words looks like a fact. The
// edge carries its source so the view can show the passage.
// ─────────────────────────────────────────────────────────────

public struct EntityGraph: Sendable, Equatable {

    /// What this needs from a relation, and nothing more.
    ///
    /// Its own type rather than `StoredRelation`, which lives in Persistence —
    /// and Persistence depends on Knowledge, not the other way round. A view of
    /// the graph should not care where the graph is kept, and the module graph
    /// is where this project enforces that kind of thing.
    public struct Relation: Sendable, Equatable, Hashable {
        public let subject: String
        public let predicate: String
        public let object: String
        public let chunkID: String
        public let documentID: String

        public init(subject: String, predicate: String, object: String,
                    chunkID: String, documentID: String) {
            self.subject = subject
            self.predicate = predicate
            self.object = object
            self.chunkID = chunkID
            self.documentID = documentID
        }
    }

    public struct Node: Sendable, Equatable, Identifiable {
        public let entity: String
        /// Distance from the focus, by the shortest path.
        public let hop: Int
        /// Unit-circle position: the focus is at the origin, hop *k* sits on a
        /// ring of radius *k*. The view scales it.
        public let x: Double
        public let y: Double
        /// How many edges touch this entity within the graph shown.
        public let degree: Int

        public var id: String { entity }
    }

    public struct Edge: Sendable, Equatable, Identifiable {
        public let subject: String
        public let predicate: String
        public let object: String
        /// The chunk that says so — decision 4.
        public let chunkID: String
        public let documentID: String

        public var id: String { "\(subject)|\(predicate)|\(object)|\(chunkID)" }
    }

    public let focus: String
    public let nodes: [Node]
    public let edges: [Edge]
    /// Entities connected to the focus but further away than the hop limit.
    /// Reported rather than dropped — decision 1.
    public let beyondHorizon: Int

    public var isEmpty: Bool { edges.isEmpty }

    /// What the screen says under the picture, including what it is not showing.
    public var summary: String {
        guard !isEmpty else {
            return localised("nothing has been extracted around “\(focus)” in this scope yet", "The entity graph is empty. Placeholder: the entity in focus.")
        }
        let base = localised("\(nodes.count) things · \(edges.count) relationships around “\(focus)”", "Summary of the entity graph. Placeholders: node count, edge count and the entity in focus.")
        guard beyondHorizon > 0 else { return base }
        return base + localised(" · \(beyondHorizon) more lie beyond what is shown — widen the range to see them", "Says how much of the graph is cut off. Placeholder: the number of hidden nodes.")
    }

    // ─────────────────────────────────────────────────────────

    /// Builds the neighbourhood around `focus`.
    ///
    /// - Parameter hops: how far to walk. 1 is "what touches this"; 2 is the
    ///   first distance at which a graph tells you something a list does not.
    public static func around(_ focus: String, in relations: [Relation],
                              hops: Int = 2) -> EntityGraph {
        let focusKey = normalise(focus)
        // Deduplicated and ordered, so the same rows always give the same
        // picture whatever order the database returned them in.
        let unique = Array(Set(relations.map(Key.init))).sorted()

        var adjacency: [String: Set<String>] = [:]
        for key in unique where key.subjectKey != key.objectKey {
            adjacency[key.subjectKey, default: []].insert(key.objectKey)
            adjacency[key.objectKey, default: []].insert(key.subjectKey)
        }

        // Breadth-first: a node's hop is its *shortest* distance — decision 2.
        var distance: [String: Int] = [focusKey: 0]
        var frontier = [focusKey]
        var beyond = 0
        var depth = 0
        while !frontier.isEmpty {
            depth += 1
            var next: [String] = []
            for node in frontier {
                for neighbour in (adjacency[node] ?? []).sorted()
                where distance[neighbour] == nil {
                    if depth <= hops {
                        distance[neighbour] = depth
                        next.append(neighbour)
                    } else {
                        // Counted, not silently dropped.
                        distance[neighbour] = Int.max
                        beyond += 1
                    }
                }
            }
            frontier = next
        }

        let visible = distance.filter { $0.value <= hops }
        guard visible.count > 1 || adjacency[focusKey] != nil else {
            return EntityGraph(focus: focus, nodes: [], edges: [], beyondHorizon: 0)
        }

        let edges = unique
            .filter { visible[$0.subjectKey] != nil && visible[$0.objectKey] != nil }
            .filter { $0.subjectKey != $0.objectKey }
            .map { Edge(subject: $0.subject, predicate: $0.predicate, object: $0.object,
                        chunkID: $0.chunkID, documentID: $0.documentID) }

        var degree: [String: Int] = [:]
        for edge in edges {
            degree[normalise(edge.subject), default: 0] += 1
            degree[normalise(edge.object), default: 0] += 1
        }

        // Display names: whichever spelling the relations used, chosen
        // deterministically rather than by whichever row arrived first.
        var display: [String: String] = [focusKey: focus]
        for key in unique {
            display[key.subjectKey] = min(display[key.subjectKey] ?? key.subject, key.subject)
            display[key.objectKey] = min(display[key.objectKey] ?? key.object, key.object)
        }

        var nodes: [Node] = []
        for hop in 0...max(0, hops) {
            let ring = visible.filter { $0.value == hop }.keys.sorted()
            for (index, key) in ring.enumerated() {
                let angle = ring.count == 1 && hop == 0
                    ? 0
                    : 2 * Double.pi * Double(index) / Double(max(1, ring.count))
                nodes.append(Node(entity: display[key] ?? key, hop: hop,
                                  x: Double(hop) * cos(angle),
                                  y: Double(hop) * sin(angle),
                                  degree: degree[key] ?? 0))
            }
        }
        return EntityGraph(focus: focus, nodes: nodes, edges: edges, beyondHorizon: beyond)
    }

    /// Entities worth offering as a starting point: the ones with the most
    /// connections, because a graph opened on a leaf shows one line.
    public static func busiestEntities(in relations: [Relation],
                                       limit: Int = 20) -> [String] {
        var degree: [String: (name: String, count: Int)] = [:]
        for relation in relations {
            for name in [relation.subject, relation.object] {
                let key = normalise(name)
                var entry = degree[key] ?? (name, 0)
                entry.count += 1
                entry.name = min(entry.name, name)
                degree[key] = entry
            }
        }
        return degree.values
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
            .prefix(limit)
            .map(\.name)
    }

    /// Case and surrounding space are not different entities. Deliberately not
    /// more than this: stemming Thai here would merge things a reader can see
    /// are different, and the extractor already refuses relations whose ends do
    /// not appear in the text.
    public static func normalise(_ entity: String) -> String {
        entity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// A relation reduced to what identifies it, so duplicates from two chunks
    /// saying the same thing collapse into one edge.
    private struct Key: Hashable, Comparable {
        let subject: String, predicate: String, object: String
        let chunkID: String, documentID: String
        var subjectKey: String { EntityGraph.normalise(subject) }
        var objectKey: String { EntityGraph.normalise(object) }

        init(_ relation: Relation) {
            subject = relation.subject
            predicate = relation.predicate
            object = relation.object
            chunkID = relation.chunkID
            documentID = relation.documentID
        }

        static func < (a: Key, b: Key) -> Bool {
            (a.subjectKey, a.predicate, a.objectKey, a.chunkID)
                < (b.subjectKey, b.predicate, b.objectKey, b.chunkID)
        }
    }
}
