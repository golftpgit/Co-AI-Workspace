import Foundation

// ─────────────────────────────────────────────────────────────
// What the coding says about itself (ARCHITECTURE §20.3, P11.8).
//
// `Agreement` has had Cohen's and Fleiss' κ since the ICC round, checked against
// published examples and reachable from nothing. This is the part that turns a
// pile of `CodeAssignment` rows into the two arrays it wants, and it is almost
// entirely decisions about what to leave out.
//
//  • **Only units every coder labelled** go into κ. `Agreement` refuses `nil`
//    labels on purpose — a unit one coder never reached is not a disagreement,
//    and treating "not coded" as a category of its own inflates agreement — so
//    the incomplete ones are counted and reported rather than filled in.
//  • **"No code here" is a category.** A coder who read the passage and decided
//    none of the codes apply has made a decision, and two coders agreeing on
//    that are agreeing. It is a different state from not having looked, which is
//    why `CodeAssignment.codeID` is optional and absence of the row is not.
//  • **Per-code κ as well as overall.** One low figure sends somebody through
//    the whole scheme; the useful question is which code the disagreement is
//    in, and that is the standard one-against-the-rest calculation.
//
// Saturation is a curve, not a verdict — see `SaturationCurve`.
// ─────────────────────────────────────────────────────────────

public struct CodingReliability: Sendable, Equatable {
    /// Overall agreement across the units everybody coded.
    public let overall: CategoryAgreement
    /// κ for each code taken against everything else, so the scheme's weak
    /// category can be named instead of hunted for.
    public let perCode: [CodeAgreement]
    public let coders: [String]
    /// Units every coder labelled — the denominator κ was computed on.
    public let comparableUnits: Int
    /// Units at least one coder did not reach. Reported because a κ computed on
    /// eleven of forty passages is a different claim from one computed on forty.
    public let incompleteUnits: Int

    public struct CodeAgreement: Sendable, Equatable, Identifiable {
        public let codeID: String
        public let name: String
        public let kappa: Double
        /// How often this code was applied at all, across coders and units. A κ
        /// for a code used twice is arithmetic about two passages.
        public let applications: Int
        public var id: String { codeID }
    }

    /// Landis & Koch again, and the threshold most qualitative methods sections
    /// quote — .61 is where "substantial" starts. Not enforced anywhere: this is
    /// a number the researcher defends, and a gate on it would be a gate on work
    /// that has already been done.
    public var isSubstantial: Bool { overall.kappa >= 0.61 }

    public var summary: String {
        var parts = [overall.summary]
        if incompleteUnits > 0 {
            parts.append(localised("\(incompleteUnits) units are left out because not everyone has coded them yet", "Says what the agreement figure excludes. Placeholder: the number of units."))
        }
        if let weakest = perCode.min(by: { $0.kappa < $1.kappa }), weakest.kappa < 0.61 {
            parts.append(String(format: localised("least agreed-on code: “%@” κ %.2f", "Names the worst-agreed code. Placeholders: the code and its kappa."),
                                weakest.name, weakest.kappa))
        }
        return parts.joined(separator: " · ")
    }
}

/// How many codes had appeared by the time each transcript was finished.
///
/// The shape a methods section shows to argue saturation, and nothing more: the
/// point at which it flattens is a judgement, and a number produced here would
/// be quoted as though the software had made it.
public struct SaturationCurve: Sendable, Equatable {
    public struct Point: Sendable, Equatable, Identifiable {
        public let documentID: String
        /// Position in the coding order, from 1.
        public let position: Int
        /// Codes seen for the first time in this document.
        public let newCodes: Int
        /// Distinct codes used up to and including this document.
        public let cumulative: Int
        public var id: String { documentID }
    }

    public let points: [Point]

    /// The first position after which no document introduced a new code, when
    /// there is one.
    ///
    /// Reported as an observation with the run length beside it, never as
    /// "saturation reached at 9" — a study that stopped at nine has no evidence
    /// about the tenth.
    public func flattenedAfter(consecutive: Int = 3) -> Int? {
        guard points.count > consecutive else { return nil }
        var run = 0
        for point in points {
            if point.newCodes == 0 {
                run += 1
                if run == consecutive { return point.position - consecutive }
            } else {
                run = 0
            }
        }
        return nil
    }

    public var summary: String {
        guard let last = points.last else { return localised("nothing has been coded yet", "Shown when no coding has happened.") }
        var parts = [localised("\(points.count) documents coded · \(last.cumulative) codes used", "Coding progress. Placeholders: documents coded and codes used.")]
        if let flat = flattenedAfter() {
            parts.append(localised("no new code has appeared since document \(flat) — an observation, not a finding of saturation ", "Comment on the saturation curve. Placeholder: the document number.")
                         + localised("a study that stopped at document \(points.count) has no evidence about the next one", "Ends the saturation comment. Placeholder: the document count."))
        } else {
            parts.append(localised("new codes are still appearing in the most recent documents", "Comment on the saturation curve."))
        }
        return parts.joined(separator: " · ")
    }
}

public enum CodingAnalysis {

    /// Below this there is nothing to compare.
    public static let minimumCoders = 2

    /// κ over the units every coder labelled.
    ///
    /// `nil` when the design cannot support a figure: fewer than two coders, or
    /// no unit that all of them reached. Same rule as everywhere else in this
    /// module — the alternative is a number that would be quoted.
    public static func reliability(units: [CodingUnit], assignments: [CodeAssignment],
                                   codebook: Codebook) -> CodingReliability? {
        let coders = Array(Set(assignments.map(\.coder))).sorted()
        guard coders.count >= minimumCoders else { return nil }

        let byUnit = Dictionary(grouping: assignments, by: \.unitID)
        /// The label a coder gave, with "none of these" as its own category —
        /// see the note at the top about why that is a decision and not a gap.
        let none = "\u{0}none"
        var rows: [[String]] = []
        var incomplete = 0
        for unit in units {
            let given = byUnit[unit.id] ?? []
            let labels = coders.map { coder in
                given.first { $0.coder == coder }.map { $0.codeID ?? none }
            }
            if labels.contains(where: { $0 == nil }) {
                incomplete += 1
                continue
            }
            rows.append(labels.compactMap { $0 })
        }
        guard !rows.isEmpty else { return nil }

        let overall: CategoryAgreement
        do {
            overall = coders.count == 2
                ? try Agreement.cohensKappa(rows.map { $0[0] }, rows.map { $0[1] })
                : try Agreement.fleissKappa(rows)
        } catch {
            return nil
        }

        // One code against all the others, which is how a scheme's weak category
        // gets a name. Codes nobody applied are included with κ 0 rather than
        // dropped: "defined and never used" is a fact about the scheme.
        var perCode: [CodingReliability.CodeAgreement] = []
        for code in codebook.codes {
            let binary = rows.map { row in row.map { $0 == code.id ? "yes" : "no" } }
            let applications = binary.reduce(0) { running, row in
                running + row.count { $0 == "yes" }
            }
            let agreement = (try? (coders.count == 2
                ? Agreement.cohensKappa(binary.map { $0[0] }, binary.map { $0[1] })
                : Agreement.fleissKappa(binary)))
            perCode.append(CodingReliability.CodeAgreement(
                codeID: code.id, name: code.name.thai,
                kappa: agreement?.kappa ?? 0, applications: applications))
        }

        return CodingReliability(overall: overall, perCode: perCode, coders: coders,
                                 comparableUnits: rows.count, incompleteUnits: incomplete)
    }

    /// The saturation curve, in the order the codebook records.
    ///
    /// Documents the codebook does not list are appended in the order their
    /// units appear, so a curve is still drawn for a study that never set an
    /// order — with the order it actually used, which is the honest fallback.
    public static func saturation(units: [CodingUnit], assignments: [CodeAssignment],
                                  order: [String]) -> SaturationCurve {
        let unitDocument = Dictionary(units.map { ($0.id, $0.documentID) },
                                      uniquingKeysWith: { first, _ in first })
        var sequence = order
        for unit in units where !sequence.contains(unit.documentID) {
            sequence.append(unit.documentID)
        }

        var seen: Set<String> = []
        var points: [SaturationCurve.Point] = []
        for (index, document) in sequence.enumerated() {
            let used = Set(assignments.compactMap { assignment -> String? in
                guard unitDocument[assignment.unitID] == document else { return nil }
                return assignment.codeID
            })
            let fresh = used.subtracting(seen)
            seen.formUnion(used)
            points.append(SaturationCurve.Point(documentID: document, position: index + 1,
                                                newCodes: fresh.count,
                                                cumulative: seen.count))
        }
        return SaturationCurve(points: points)
    }
}
