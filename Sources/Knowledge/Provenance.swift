import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// Where a piece of knowledge came from and how much it is worth
// (ARCHITECTURE §11.3, P2.5).
//
// The rule this file exists to enforce: nothing reaches the index without
// provenance, and nothing from outside the system reaches it without a
// credibility tier. Both are enforced by the type — `IndexedChunk` cannot be
// built any other way — because a convention that says "always attach the
// source" is a convention someone forgets on the one path that matters.
// ─────────────────────────────────────────────────────────────

/// Shared vocabulary with web search (§1.4): a document ingested from the web
/// keeps the tier its source had, so the two halves of the system rank
/// evidence the same way.
public enum SourceTier: String, Sendable, Codable, CaseIterable, Comparable {
    case t1, t2, t3, t4, t5

    public static func < (a: SourceTier, b: SourceTier) -> Bool {
        a.rawValue < b.rawValue   // t1 is the most credible
    }

    public var isMoreCredibleThan: (SourceTier) -> Bool { { self < $0 } }
}
extension SourceTier {
    /// The same five tiers as `AgentKit.CredibilityTier`, which is the vocabulary
    /// the rest of the system shares (§14.1's rule, the QA gate, conflict
    /// weighting). Two enums for one idea is a duplication this project's own
    /// §0.2 rule 3 forbids — the mapping is exhaustive and `TierParityTests`
    /// fails if either side grows a case the other does not have, so the
    /// duplication cannot drift while it waits to be collapsed.
    public var credibility: CredibilityTier {
        switch self {
        case .t1: .t1
        case .t2: .t2
        case .t3: .t3
        case .t4: .t4
        case .t5: .t5
        }
    }
}


public enum Origin: Sendable, Codable, Equatable {
    case upload(filename: String)
    case web(url: URL)
    case database(name: String)
    /// Produced by the system itself — an analysis run, a written summary.
    /// Carries no external tier, which is why `Provenance.tier` is optional.
    case userAuthored(runID: String)
}

public struct Provenance: Sendable, Equatable, Codable {
    public let documentID: String
    public let title: String
    public let origin: Origin
    /// `nil` only for `.userAuthored`. The initialisers are the enforcement:
    /// there is no way to build an external source without one.
    public let tier: SourceTier?
    public let authors: [String]
    public let year: Int?
    public let page: Int?
    public let section: String?
    /// Matters for the web, where the same URL says something else next month.
    public let accessedAt: Date
    /// The earlier revision of the same document, if this replaces one.
    public let supersedes: String?

    /// `optionalTier`, not `tier`: with the same label this would be the same
    /// call site as the public initialiser below, because `SourceTier`
    /// converts implicitly to `SourceTier?` — and that initialiser's
    /// `self.init` would resolve straight back to itself.
    private init(documentID: String, title: String, origin: Origin, optionalTier: SourceTier?,
                 authors: [String], year: Int?, page: Int?, section: String?,
                 accessedAt: Date, supersedes: String?) {
        self.documentID = documentID
        self.title = title
        self.origin = origin
        self.tier = optionalTier
        self.authors = authors
        self.year = year
        self.page = page
        self.section = section
        self.accessedAt = accessedAt
        self.supersedes = supersedes
    }

    /// Anything that came from outside the system. `tier` is not optional here
    /// on purpose: an upload defaults to T3 in the UI (§11.3) and the user can
    /// change it, but nothing gets to skip the question.
    public init(documentID: String, title: String, origin: Origin, tier: SourceTier,
                authors: [String] = [], year: Int? = nil, page: Int? = nil,
                section: String? = nil, accessedAt: Date = Date(),
                supersedes: String? = nil) {
        self.init(documentID: documentID, title: title, origin: origin, optionalTier: tier,
                  authors: authors, year: year, page: page, section: section,
                  accessedAt: accessedAt, supersedes: supersedes)
    }

    /// Written by the system: an analysis result, a generated summary. Has no
    /// external credibility to claim, but still has to say which run made it.
    public static func authored(documentID: String, title: String, runID: String,
                                page: Int? = nil, section: String? = nil,
                                accessedAt: Date = Date(),
                                supersedes: String? = nil) -> Provenance {
        Provenance(documentID: documentID, title: title,
                   origin: .userAuthored(runID: runID), optionalTier: nil,
                   authors: [], year: nil, page: page, section: section,
                   accessedAt: accessedAt, supersedes: supersedes)
    }

    /// True when this row can be cited with a credibility claim attached.
    public var isExternallySourced: Bool { tier != nil }
}
