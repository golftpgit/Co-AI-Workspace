import Foundation

// ─────────────────────────────────────────────────────────────
// Which sources exist, how much each is worth, and what they cover
// (ARCHITECTURE §1.4, P3.2).
//
// The rule that shapes this file: **adding a source is adding a row, not
// editing agent code**. v1 hardcoded WHO/CDC/PubMed into the researcher, which
// made it a medical-research tool wearing a general-purpose label — a coding
// question had nowhere credible to go.
//
// So tier is a property of the *source*, and which sources a task uses is
// decided by the task's subject. Nothing here knows about roles.
// ─────────────────────────────────────────────────────────────

/// Broad subject areas, used to pick sources by what a task is about rather
/// than by who is asking. Deliberately coarse: a finer taxonomy would need
/// maintenance nobody would do, and the tier already carries credibility.
public enum Discipline: String, Sendable, Codable, CaseIterable {
    case medicine, science, engineering, computing, socialScience
    case statistics, law, policy, general

    public var label: String {
        switch self {
        case .medicine: "การแพทย์"
        case .science: "วิทยาศาสตร์"
        case .engineering: "วิศวกรรม"
        case .computing: "คอมพิวเตอร์"
        case .socialScience: "สังคมศาสตร์"
        case .statistics: "สถิติ"
        case .law: "กฎหมาย"
        case .policy: "นโยบาย"
        case .general: "ทั่วไป"
        }
    }
}

/// How a source is reached. The registry describes sources; the clients that
/// speak these protocols are P3.3 and P3.4.
public enum AccessMethod: Sendable, Codable, Equatable {
    /// An official API with its own client.
    case api(name: String)
    /// A search engine query restricted to this domain.
    case siteQuery
    /// Whatever the meta-search returns, read afterwards with `fetch_page`.
    case metaSearch
}

public struct Source: Sendable, Codable, Equatable, Identifiable {
    /// Matched against a URL's host, longest pattern first, so
    /// `who.int` and `apps.who.int` can carry different tiers if they need to.
    public let domain: String
    public let name: String
    public let tier: SourceTier
    public let disciplines: [Discipline]
    public let access: AccessMethod
    /// Off means "do not use", without losing the row — a user disabling a
    /// source should not have to retype it later.
    public var isEnabled: Bool

    public var id: String { domain }

    public init(domain: String, name: String, tier: SourceTier,
                disciplines: [Discipline], access: AccessMethod = .siteQuery,
                isEnabled: Bool = true) {
        self.domain = domain.lowercased()
        self.name = name
        self.tier = tier
        self.disciplines = disciplines
        self.access = access
        self.isEnabled = isEnabled
    }

    /// True when `host` is this domain or a subdomain of it. String suffix
    /// matching would make `notwho.int` a match for `who.int`.
    public func matches(host: String) -> Bool {
        let host = host.lowercased()
        return host == domain || host.hasSuffix("." + domain)
    }
}

public struct SourceRegistry: Sendable, Codable {
    public private(set) var sources: [Source]

    public init(sources: [Source] = SourceRegistry.builtIn) {
        self.sources = sources
    }

    // MARK: - lookup

    /// The tier of whatever published this URL. Unknown domains are T5, not
    /// "unknown": a page nobody vouched for is general web, and treating it as
    /// unrated would let it slip past filters that check for a tier.
    public func tier(for url: URL) -> SourceTier {
        source(for: url)?.tier ?? .t5
    }

    public func source(for url: URL) -> Source? {
        guard let host = url.host()?.lowercased() else { return nil }
        // Longest domain wins, so a specific subdomain rule beats its parent.
        return sources
            .filter { $0.isEnabled && $0.matches(host: host) }
            .max { $0.domain.count < $1.domain.count }
    }

    /// Sources to search for a task on this subject, most credible first.
    /// `general` is always included: a question about anything can still be
    /// answered by an encyclopedia, it is just worth less.
    public func sources(for discipline: Discipline,
                        upTo lowestTier: SourceTier = .t5) -> [Source] {
        sources
            .filter { $0.isEnabled }
            .filter { $0.disciplines.contains(discipline) || $0.disciplines.contains(.general) }
            .filter { $0.tier <= lowestTier }
            .sorted { a, b in
                a.tier == b.tier ? a.name < b.name : a.tier < b.tier
            }
    }

    // MARK: - editing

    /// Adding a source is adding a row. Replacing by domain rather than
    /// appending, so editing one in the UI does not silently create a second
    /// rule for the same host.
    public mutating func upsert(_ source: Source) {
        if let position = sources.firstIndex(where: { $0.domain == source.domain }) {
            sources[position] = source
        } else {
            sources.append(source)
        }
    }

    public mutating func remove(domain: String) {
        sources.removeAll { $0.domain == domain.lowercased() }
    }

    public mutating func setEnabled(_ enabled: Bool, domain: String) {
        guard let position = sources.firstIndex(where: { $0.domain == domain.lowercased() })
        else { return }
        sources[position].isEnabled = enabled
    }
}

// MARK: - the shipped rows

extension SourceRegistry {
    /// Starting rows, one per §1.4's table. Not exhaustive and not meant to be
    /// — it is a floor a user extends, which is the whole point of the row
    /// being data rather than code.
    public static let builtIn: [Source] = [
        // T1 — authoritative
        .init(domain: "who.int", name: "World Health Organization", tier: .t1,
              disciplines: [.medicine, .policy]),
        .init(domain: "cdc.gov", name: "US CDC", tier: .t1, disciplines: [.medicine]),
        .init(domain: "moph.go.th", name: "กระทรวงสาธารณสุข", tier: .t1,
              disciplines: [.medicine, .policy]),
        .init(domain: "nist.gov", name: "NIST", tier: .t1,
              disciplines: [.science, .engineering, .computing]),
        .init(domain: "iso.org", name: "ISO", tier: .t1, disciplines: [.engineering]),
        .init(domain: "ietf.org", name: "IETF RFC", tier: .t1, disciplines: [.computing]),
        .init(domain: "worldbank.org", name: "World Bank", tier: .t1,
              disciplines: [.statistics, .policy]),
        .init(domain: "oecd.org", name: "OECD", tier: .t1,
              disciplines: [.statistics, .policy]),
        .init(domain: "un.org", name: "United Nations", tier: .t1, disciplines: [.policy]),
        .init(domain: "nso.go.th", name: "สำนักงานสถิติแห่งชาติ", tier: .t1,
              disciplines: [.statistics, .policy]),
        .init(domain: "ratchakitcha.soc.go.th", name: "ราชกิจจานุเบกษา", tier: .t1,
              disciplines: [.law]),

        // T2 — peer reviewed
        .init(domain: "pubmed.ncbi.nlm.nih.gov", name: "PubMed", tier: .t2,
              disciplines: [.medicine], access: .api(name: "eutils")),
        .init(domain: "openalex.org", name: "OpenAlex", tier: .t2,
              disciplines: [.general], access: .api(name: "openalex")),
        .init(domain: "crossref.org", name: "Crossref", tier: .t2,
              disciplines: [.general], access: .api(name: "crossref")),
        .init(domain: "semanticscholar.org", name: "Semantic Scholar", tier: .t2,
              disciplines: [.general], access: .api(name: "semanticscholar")),
        .init(domain: "doaj.org", name: "DOAJ", tier: .t2, disciplines: [.general]),
        .init(domain: "eric.ed.gov", name: "ERIC", tier: .t2, disciplines: [.socialScience]),

        // T3 — preprint and semi-official
        .init(domain: "medrxiv.org", name: "medRxiv", tier: .t3,
              disciplines: [.medicine], access: .api(name: "medrxiv")),
        .init(domain: "biorxiv.org", name: "bioRxiv", tier: .t3,
              disciplines: [.science], access: .api(name: "biorxiv")),
        .init(domain: "arxiv.org", name: "arXiv", tier: .t3,
              disciplines: [.science, .computing, .statistics], access: .api(name: "arxiv")),
        .init(domain: "ssrn.com", name: "SSRN", tier: .t3, disciplines: [.socialScience]),

        // T4 — curated community
        .init(domain: "wikipedia.org", name: "Wikipedia", tier: .t4, disciplines: [.general]),
        .init(domain: "stackoverflow.com", name: "Stack Overflow", tier: .t4,
              disciplines: [.computing]),
        .init(domain: "github.com", name: "GitHub", tier: .t4, disciplines: [.computing]),
        .init(domain: "developer.apple.com", name: "Apple Developer", tier: .t1,
              disciplines: [.computing]),
        .init(domain: "swift.org", name: "Swift", tier: .t1, disciplines: [.computing]),
    ]
}
