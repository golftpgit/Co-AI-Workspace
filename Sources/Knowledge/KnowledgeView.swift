import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// One graph, several views of it (ARCHITECTURE §21.2, P12.1–P12.5).
//
// **What this deliberately is not.** It does not cut the knowledge base into
// pieces and give each agent one. That is state to keep in sync, and the day it
// drifts nobody finds out from the system — they find out from an answer that
// was missing something.
//
// Every agent searches the same chunks. What differs is a *declared filter*,
// written in the same manifest as its tool grant, so "why did the Writer not
// see that" is answerable by reading a file rather than by reasoning about a
// prompt.
//
// Three of the rules here exist because getting them wrong is invisible:
//
//  • **`policy` is in every view and cannot be taken out.** It is not a default
//    that a manifest may override — there is no representation of a view
//    without it. A role that could not see the rules it is bound by would break
//    them and be right to, and the manifest that did it would look like a
//    typo. `scopes` is therefore private and `visibleScopes` always unions it.
//  • **The Writer sees only chunks whose provenance is complete.** Filtering at
//    retrieval rather than checking at the end is the whole point: a citation
//    that cannot be completed is one the Writer never had, instead of one it
//    has to be told to drop after writing a paragraph around it.
//  • **Reviewer sees evidence and rules, not the maker's working.** A review
//    that reads what the maker read is a review that reaches the maker's
//    conclusion; §19 asks the reviewer to judge the deliverable against the
//    definition of done, and this is that asked for at retrieval.
//
// `minTier` reads "at least this credible". Tiers sort with T1 most credible,
// so "min T3" admits T1, T2 and T3 — the arithmetic is the wrong way round
// from the name and is therefore done in one place.
// ─────────────────────────────────────────────────────────────

public struct KnowledgeView: Sendable, Equatable {

    /// Which scopes this role reads. Private: `policy` is added on the way out
    /// and there is no way to ask for a view without it.
    private let declaredScopes: Set<ScopeKind>
    /// Entity types this role cares about. Empty means "no restriction" —
    /// which is different from "none", and is the honest reading of a manifest
    /// that does not mention them.
    public let entityTypes: Set<String>
    /// The least credible source this role will accept. `nil` admits anything,
    /// including primary data, which is on no tier at all.
    public let minTier: SourceTier?
    /// How far to walk the graph from an entity that matched.
    public let hops: Int
    /// Terms that push a chunk up the ranking without excluding anything else.
    public let boost: Set<String>
    /// Prefer sources from this year onwards. A preference, not a filter: an
    /// API note from 2019 is stale, and a 2019 randomised trial is not.
    public let preferAfter: Int?
    /// P12.4 — the Writer's rule.
    public let requiresCompleteProvenance: Bool
    /// P12.5 — the Reviewer's rule.
    public let evidenceOnly: Bool

    public enum ScopeKind: String, Sendable, Codable, CaseIterable {
        case project, central, policy
    }

    public init(scopes: Set<ScopeKind> = [.project, .central],
                entityTypes: Set<String> = [],
                minTier: SourceTier? = nil,
                hops: Int = 1,
                boost: Set<String> = [],
                preferAfter: Int? = nil,
                requiresCompleteProvenance: Bool = false,
                evidenceOnly: Bool = false) {
        self.declaredScopes = scopes
        self.entityTypes = entityTypes
        self.minTier = minTier
        self.hops = max(0, hops)
        self.boost = boost
        self.preferAfter = preferAfter
        self.requiresCompleteProvenance = requiresCompleteProvenance
        self.evidenceOnly = evidenceOnly
    }

    /// The scopes actually searched. `policy` is always among them (P12.3).
    public var visibleScopes: Set<ScopeKind> { declaredScopes.union([.policy]) }

    /// Whether a manifest tried to exclude `policy`. Not an error — the view is
    /// corrected either way — but worth showing next to the role, because a
    /// manifest that asked for something it did not get should say so somewhere
    /// rather than appear to have been obeyed.
    public var policyWasAddedBack: Bool { !declaredScopes.contains(.policy) }

    // ─────────────────────────────────────────────────────────
    // Applying it
    // ─────────────────────────────────────────────────────────

    /// Whether this view admits a chunk at all.
    public func admits(_ chunk: IndexedChunk) -> Bool {
        guard visibleScopes.contains(Self.kind(of: chunk.scope)) else { return false }

        // `policy` is exempt from the rest. A rule is not less binding because
        // it has no author, no tier and no year — and a view that filtered its
        // own governing rules out on a technicality would be the bug this whole
        // type exists to make impossible.
        if Self.kind(of: chunk.scope) == .policy { return true }

        if let minTier {
            // A chunk with no tier is primary data (§11.3): not weak evidence,
            // not on the scale. A role that asked for "at least T3 published
            // sources" is not asking to be shown an interview transcript.
            guard let tier = chunk.provenance.tier, tier <= minTier else { return false }
        }
        if requiresCompleteProvenance, !Self.hasCompleteProvenance(chunk) { return false }
        if evidenceOnly, !Self.isEvidence(chunk) { return false }
        if !entityTypes.isEmpty {
            guard chunk.entities.contains(where: { entityTypes.contains($0.lowercased()) })
                    || entityTypes.contains(where: { chunk.text.lowercased().contains($0) })
            else { return false }
        }
        return true
    }

    /// The score adjustment for a chunk this view admits. Multiplicative and
    /// never zero: boosting must not be able to remove something the filter
    /// admitted, or two mechanisms would be deciding visibility and only one of
    /// them would be declared.
    public func weight(for chunk: IndexedChunk) -> Double {
        var weight = 1.0
        let text = chunk.text.lowercased()
        if boost.contains(where: { text.contains($0.lowercased()) }) { weight *= 1.5 }
        if let preferAfter, let year = chunk.provenance.year {
            weight *= year >= preferAfter ? 1.25 : 0.8
        }
        return weight
    }

    /// Complete enough to cite: who said it, when, and where it came from.
    static func hasCompleteProvenance(_ chunk: IndexedChunk) -> Bool {
        !chunk.provenance.authors.isEmpty
            && chunk.provenance.year != nil
            && chunk.provenance.isExternallySourced
    }

    /// What a reviewer may see: things produced as evidence, and the rules.
    /// Deliberately narrow — the point is that a review reaching the maker's
    /// conclusion by reading the maker's sources is not a review.
    static func isEvidence(_ chunk: IndexedChunk) -> Bool {
        switch chunk.provenance.origin {
        case .userAuthored: return true
        default: return false
        }
    }

    static func kind(of scope: Scope) -> ScopeKind {
        switch scope {
        case .project: .project
        case .central: .central
        case .policy: .policy
        }
    }
}

// ─────────────────────────────────────────────────────────────
// Decoding — where a manifest's `knowledge_view:` becomes one of these.
// ─────────────────────────────────────────────────────────────

extension KnowledgeView: Codable {
    private enum CodingKeys: String, CodingKey {
        case scopes, entityTypes = "entity_types", minTier = "min_tier"
        case hops, boost, preferAfter = "prefer_after"
        case requiresCompleteProvenance = "requires_complete_provenance"
        case evidenceOnly = "evidence_only"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Every field optional: a manifest that mentions only `min_tier` is an
        // ordinary manifest, not a broken one. Codable's synthesised decoder
        // makes every field required, which is how P8.4 ended up rejecting
        // files for being plain.
        let scopes = try container.decodeIfPresent(Set<ScopeKind>.self, forKey: .scopes)
        self.init(
            scopes: scopes ?? [.project, .central],
            entityTypes: Set((try container.decodeIfPresent([String].self, forKey: .entityTypes)
                              ?? []).map { $0.lowercased() }),
            minTier: try container.decodeIfPresent(SourceTier.self, forKey: .minTier),
            hops: try container.decodeIfPresent(Int.self, forKey: .hops) ?? 1,
            boost: Set(try container.decodeIfPresent([String].self, forKey: .boost) ?? []),
            preferAfter: try container.decodeIfPresent(Int.self, forKey: .preferAfter),
            requiresCompleteProvenance:
                try container.decodeIfPresent(Bool.self, forKey: .requiresCompleteProvenance) ?? false,
            evidenceOnly: try container.decodeIfPresent(Bool.self, forKey: .evidenceOnly) ?? false)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // `visibleScopes`, not the declared set: what is written back out is
        // what will actually be searched.
        try container.encode(visibleScopes.map(\.rawValue).sorted(), forKey: .scopes)
        try container.encode(entityTypes.sorted(), forKey: .entityTypes)
        try container.encodeIfPresent(minTier, forKey: .minTier)
        try container.encode(hops, forKey: .hops)
        try container.encode(boost.sorted(), forKey: .boost)
        try container.encodeIfPresent(preferAfter, forKey: .preferAfter)
        try container.encode(requiresCompleteProvenance, forKey: .requiresCompleteProvenance)
        try container.encode(evidenceOnly, forKey: .evidenceOnly)
    }
}

// ─────────────────────────────────────────────────────────────
// The six defaults (ARCHITECTURE §21.2's table)
// ─────────────────────────────────────────────────────────────

public extension KnowledgeView {
    /// What a role sees when its manifest does not say otherwise.
    ///
    /// A `switch` with no `default:`, for the reason `Conformance` gives about
    /// the seventeen practices: a seventh role must be a compiler error here,
    /// not a role that silently inherits somebody else's filter. `check.sh`
    /// keeps the arm out.
    static func standard(for role: Role) -> KnowledgeView {
        switch role {
        case .researcher:
            // A conclusion that cites research has to stand on sources good
            // enough to cite, so the floor is real rather than advisory.
            KnowledgeView(scopes: [.project, .central],
                          entityTypes: ["study", "construct", "measure", "population", "finding"],
                          minTier: .t3, hops: 2,
                          boost: ["systematic review", "randomised", "randomized", "rct"],
                          preferAfter: 2020)
        case .analyst:
            // Statistics go wrong at the variable definition, not at the test,
            // and data-governance rules are part of the definition.
            KnowledgeView(scopes: [.project, .central],
                          entityTypes: ["variable", "dataset", "codebook",
                                        "analysis_plan", "statistical_test"],
                          hops: 2)
        case .engineer:
            // Last year's API documentation is *wrong*, not merely weak — so
            // freshness outranks credibility here, and nowhere else.
            KnowledgeView(scopes: [.project, .central],
                          entityTypes: ["file", "module", "api", "error", "decision"],
                          hops: 1, preferAfter: 2024)
        case .writer:
            // P12.4. Filtered at retrieval so the Writer's definition of done
            // is true while it writes, not checked after it has built a
            // paragraph around a citation it cannot complete.
            KnowledgeView(scopes: [.project, .central], hops: 1,
                          requiresCompleteProvenance: true)
        case .teamLead:
            // §5.1's rule at the retrieval layer: the lead does not do the
            // work, so it does not get the raw material for doing it.
            KnowledgeView(scopes: [.project, .central], hops: 0)
        case .reviewer:
            // P12.5. A review that reads what the maker read reaches the
            // maker's conclusion.
            KnowledgeView(scopes: [.project, .central], hops: 0, evidenceOnly: true)
        }
    }
}
