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
    /// Primary data this study collected: an interview transcript, a field note
    /// (§20.3, P11.8). Carries a participant *code* and never a name — §20.7
    /// keeps identities in a different file behind a different key, and a
    /// transcript that named somebody would carry that identity into every
    /// index, export and quotation downstream.
    case fieldwork(participantCode: String?)
}

/// Where in a document something is, when the document has no pages.
///
/// A transcript has no page 7. What it has is a passage, and "the citation
/// points back to the real passage" (P11.8's Done-when) needs somewhere to put
/// the offsets — which is here rather than squeezed into `section`, because a
/// string a reader has to parse back into two numbers is a string that will be
/// formatted differently by the second caller.
///
/// **The offsets count `Character`s — grapheme clusters — and that choice is
/// load-bearing for Thai.** Driving the screen with a Thai transcript made it
/// visible: a line that shows 43 marks is 32 characters, because vowels and
/// tone marks combine onto the consonant they sit on. UTF-16 offsets would give
/// a third number again. What matters is not which unit is chosen but that one
/// unit is used to *produce* a span and to *resolve* it, which is why both
/// happen here rather than wherever a caller found convenient.
public struct TextSpan: Sendable, Equatable, Codable {
    public let start: Int
    public let end: Int

    public init(start: Int, end: Int) {
        self.start = min(start, end)
        self.end = max(start, end)
    }

    public init(_ range: Range<Int>) {
        self.init(start: range.lowerBound, end: range.upperBound)
    }

    public var range: Range<Int> { start..<end }
    public var length: Int { end - start }

    /// The characters this span names, or `nil` when it does not fit the text —
    /// which is the answer that matters: a citation whose span has drifted past
    /// the end of its source must not quietly return a shorter quotation.
    public func slice(of text: String) -> String? {
        let characters = Array(text)
        guard start >= 0, end <= characters.count, start < end else { return nil }
        return String(characters[start..<end])
    }
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
    /// Where in the document, for documents that have no pages (§20.3). Optional
    /// on purpose and optional in the decoder: rows written before P11.8 have no
    /// such key, and a stored index that stopped loading would be a migration
    /// nobody asked for.
    public let passage: TextSpan?
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
                 passage: TextSpan?, accessedAt: Date, supersedes: String?) {
        self.documentID = documentID
        self.title = title
        self.origin = origin
        self.tier = optionalTier
        self.authors = authors
        self.year = year
        self.page = page
        self.section = section
        self.passage = passage
        self.accessedAt = accessedAt
        self.supersedes = supersedes
    }

    /// Anything that came from outside the system. `tier` is not optional here
    /// on purpose: an upload defaults to T3 in the UI (§11.3) and the user can
    /// change it, but nothing gets to skip the question.
    public init(documentID: String, title: String, origin: Origin, tier: SourceTier,
                authors: [String] = [], year: Int? = nil, page: Int? = nil,
                section: String? = nil, passage: TextSpan? = nil,
                accessedAt: Date = Date(), supersedes: String? = nil) {
        self.init(documentID: documentID, title: title, origin: origin, optionalTier: tier,
                  authors: authors, year: year, page: page, section: section,
                  passage: passage, accessedAt: accessedAt, supersedes: supersedes)
    }

    /// Written by the system: an analysis result, a generated summary. Has no
    /// external credibility to claim, but still has to say which run made it.
    public static func authored(documentID: String, title: String, runID: String,
                                page: Int? = nil, section: String? = nil,
                                passage: TextSpan? = nil,
                                accessedAt: Date = Date(),
                                supersedes: String? = nil) -> Provenance {
        Provenance(documentID: documentID, title: title,
                   origin: .userAuthored(runID: runID), optionalTier: nil,
                   authors: [], year: nil, page: page, section: section,
                   passage: passage, accessedAt: accessedAt, supersedes: supersedes)
    }

    /// Primary data this study collected (§20.3, P11.8).
    ///
    /// No tier, and that is a claim rather than an omission. The five tiers rank
    /// *published* sources by how much weight somebody else's review earned them;
    /// an interview you conducted has no such review to point at, and its
    /// trustworthiness comes from the study's design — the ethics record, the
    /// sampling, the instrument that passed its gate. Giving it a tier would put
    /// primary data on a scale built for secondary, and the corroboration rule
    /// (§14.1) would then read a transcript as though it were a journal.
    public static func fieldwork(documentID: String, title: String,
                                 participantCode: String? = nil,
                                 collectedAt: Date,
                                 passage: TextSpan? = nil,
                                 section: String? = nil) -> Provenance {
        Provenance(documentID: documentID, title: title,
                   origin: .fieldwork(participantCode: participantCode),
                   optionalTier: nil, authors: [], year: nil, page: nil,
                   section: section, passage: passage,
                   accessedAt: collectedAt, supersedes: nil)
    }

    /// The same provenance pointing at one passage of the same document.
    public func citing(_ passage: TextSpan) -> Provenance {
        Provenance(documentID: documentID, title: title, origin: origin,
                   optionalTier: tier, authors: authors, year: year, page: page,
                   section: section, passage: passage, accessedAt: accessedAt,
                   supersedes: supersedes)
    }

    /// True when this row can be cited with a credibility claim attached.
    public var isExternallySourced: Bool { tier != nil }
}
