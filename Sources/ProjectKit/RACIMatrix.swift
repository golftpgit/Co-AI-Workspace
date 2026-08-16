import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// The RACI table, as a table (ARCHITECTURE §19.9, P10.9).
//
// Per-package editing has existed since P10.5: each leaf can be given its
// accountable, its responsible, its consulted and its informed. What has been
// missing is the view the standard is actually for — **everybody down one
// axis, every piece of work down the other** — because the questions a RACI is
// built to answer are questions across rows:
//
//  • who is accountable for nothing, and is on this project why?
//  • who is responsible for everything, and is therefore the plan's real
//    bottleneck?
//  • which package has an A and no R — accountable to somebody, assigned to
//    nobody?
//
// None of those can be seen one package at a time, which is why a per-package
// editor is not a RACI and this exists.
//
// The one rule with teeth: **a cell holds every letter that applies, and
// disagreement is shown rather than resolved.** Somebody who is both
// accountable and consulted on a package is a real state and usually a
// mistake — flattening it to one letter hides exactly the thing a reader of
// this table is looking for.
// ─────────────────────────────────────────────────────────────

public enum RACILetterKind: String, Sendable, CaseIterable, Comparable {
    case responsible = "R"
    case accountable = "A"
    case consulted = "C"
    case informed = "I"

    public static func < (lhs: Self, rhs: Self) -> Bool {
        let order: [Self] = [.responsible, .accountable, .consulted, .informed]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

public struct RACIMatrix: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public let packageID: String
        public let title: String
        /// Letters per actor, in the column order of the matrix.
        public let cells: [[RACILetterKind]]

        public var id: String { packageID }

        /// Accountable to somebody, assigned to nobody — the state a RACI is
        /// read to find.
        public var isUnassigned: Bool {
            cells.contains { $0.contains(.accountable) }
                && !cells.contains { $0.contains(.responsible) }
        }
    }

    /// Everyone who appears anywhere, once. The column order is stable —
    /// people first, then agents by role — so the table does not reshuffle
    /// when somebody is added.
    public let actors: [RACIActor]
    public let rows: [Row]

    /// Actors on the project who carry no letter at all. Listed rather than
    /// hidden: somebody in the column headers with an empty column is the
    /// question the table exists to raise.
    public var uninvolved: [RACIActor] {
        actors.enumerated()
            .filter { index, _ in rows.allSatisfy { $0.cells[index].isEmpty } }
            .map(\.element)
    }

    /// How many packages each actor is responsible for — the bottleneck
    /// question, answered by counting rather than by reading down a column.
    public func responsibleCount(for actor: RACIActor) -> Int {
        guard let index = actors.firstIndex(of: actor) else { return 0 }
        return rows.count { $0.cells[index].contains(.responsible) }
    }

    public static func build(_ wbs: WorkBreakdown) -> RACIMatrix {
        let leaves = Schedule.order(wbs)
        var seen: [RACIActor] = []

        func note(_ actor: RACIActor) {
            if !seen.contains(actor) { seen.append(actor) }
        }
        for leaf in leaves {
            guard let raci = leaf.raci else { continue }
            note(raci.accountable.asActor)
            raci.responsible.forEach(note)
            raci.consulted.forEach(note)
            raci.informed.forEach(note)
        }
        // People before agents: a table read by a person starts with the people
        // in it. Stable within each group so the columns do not move about.
        let actors = seen.filter(\.isHuman) + seen.filter { !$0.isHuman }

        let rows = leaves.map { leaf -> Row in
            let raci = leaf.raci
            let cells = actors.map { actor -> [RACILetterKind] in
                guard let raci else { return [] }
                var letters: [RACILetterKind] = []
                if raci.accountable.asActor == actor { letters.append(.accountable) }
                if raci.responsible.contains(actor) { letters.append(.responsible) }
                if raci.consulted.contains(actor) { letters.append(.consulted) }
                if raci.informed.contains(actor) { letters.append(.informed) }
                return letters.sorted()
            }
            return Row(packageID: leaf.id, title: leaf.title, cells: cells)
        }
        return RACIMatrix(actors: actors, rows: rows)
    }
}
