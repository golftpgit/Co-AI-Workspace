import Foundation
import Knowledge

// ─────────────────────────────────────────────────────────────
// The T2–T3 half of search: official APIs, no keys, no rate limits worth
// worrying about (ARCHITECTURE §1.4, P3.3).
//
// Every record comes back with the three things a citation needs — where it
// is, how much it is worth, and when we looked — because a result that cannot
// be cited is a result the Researcher is not allowed to use (§2.5).
//
// Tier is not asked for. It comes from the source registry, keyed on the URL
// the record actually resolves to, for the same reason `ingest_url` does not
// take one: a tier a caller can choose means nothing.
// ─────────────────────────────────────────────────────────────

public struct ScholarlyRecord: Sendable, Equatable {
    public let title: String
    public let authors: [String]
    public let year: Int?
    public let doi: String?
    public let url: URL
    public let abstract: String?
    /// Which API produced this, for the trail — not the same as the tier,
    /// which belongs to whoever published the work.
    public let foundVia: String
    public let tier: SourceTier
    public let accessedAt: Date

    /// Ready to hand to `ingest_url` or to cite directly.
    public var provenance: Provenance {
        Provenance(documentID: "sch_" + IngestionPipeline.contentHash(url.absoluteString).prefix(16),
                   title: title, origin: .web(url: url), tier: tier,
                   authors: authors, year: year, accessedAt: accessedAt)
    }
}

public enum ScholarlyError: Error, CustomStringConvertible, Equatable {
    case http(status: Int, api: String)
    case transport(String)
    case decoding(String)
    /// Rate limited. Named separately because the answer is "wait or get a
    /// key", not "the query was wrong".
    case rateLimited(api: String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .http(let status, let api): "\(api): http \(status)"
        case .transport(let message): "ต่อไม่ได้: \(message.prefix(120))"
        case .decoding(let message): "อ่านผลลัพธ์ไม่ได้: \(message.prefix(120))"
        case .rateLimited(let api): "\(api) จำกัดอัตราการเรียก — ต้องรอหรือใช้ API key"
        case .unsupported(let message): message
        }
    }
}

public protocol ScholarlySource: Sendable {
    var name: String { get }
    func search(_ query: String, limit: Int) async throws -> [ScholarlyRecord]
}

// MARK: - shared plumbing

struct APIClient: Sendable {
    let name: String
    let registry: SourceRegistry
    let timeout: TimeInterval

    /// A contact address is what puts a caller in OpenAlex's and Crossref's
    /// "polite pool" — anonymous callers are throttled harder, so this is
    /// courtesy that pays for itself.
    static let contact = "coai-workspace"

    func json(_ url: URL) async throws -> Any {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CoAIWorkspace/1.0 (mailto:\(Self.contact)@localhost)",
                         forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ScholarlyError.transport("\(error)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw ScholarlyError.transport("no HTTPURLResponse")
        }
        if http.statusCode == 429 { throw ScholarlyError.rateLimited(api: name) }
        guard (200..<300).contains(http.statusCode) else {
            throw ScholarlyError.http(status: http.statusCode, api: name)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw ScholarlyError.decoding("\(name): not JSON")
        }
        return object
    }

    func url(_ base: String, _ items: [String: String]) -> URL {
        var components = URLComponents(string: base)!
        components.queryItems = items.sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    /// A DOI link has no editorial identity of its own — `doi.org` is a
    /// redirector — so a peer-reviewed paper found through Crossref or
    /// OpenAlex would otherwise be rated T5, the same as a blog. In that one
    /// case the tier of the index that found it stands in, which is what §1.4
    /// already says those indexes are worth. Once the DOI is followed,
    /// `fetch_page` re-rates the page against the publisher it lands on.
    func tier(for url: URL, foundIn: SourceTier) -> SourceTier {
        let host = url.host()?.lowercased() ?? ""
        if host == "doi.org" || host == "dx.doi.org" { return foundIn }
        let published = registry.tier(for: url)
        // A known publisher's own rating wins; an unknown one falls back to
        // the index, since being indexed there is itself evidence.
        return published == .t5 ? foundIn : published
    }
}

// MARK: - OpenAlex

/// Every discipline, no key, and it resolves to a DOI — the best default.
public struct OpenAlexSource: ScholarlySource {
    public let name = "OpenAlex"
    private let client: APIClient

    public init(registry: SourceRegistry = SourceRegistry(), timeout: TimeInterval = 30) {
        client = APIClient(name: "OpenAlex", registry: registry, timeout: timeout)
    }

    public func search(_ query: String, limit: Int = 10) async throws -> [ScholarlyRecord] {
        let url = client.url("https://api.openalex.org/works",
                             ["search": query, "per-page": String(limit),
                              "mailto": APIClient.contact])
        guard let root = try await client.json(url) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else {
            throw ScholarlyError.decoding("OpenAlex: no results array")
        }
        let now = Date()
        return results.compactMap { work in
            guard let title = work["title"] as? String ?? work["display_name"] as? String
            else { return nil }
            // `doi` is already a full https://doi.org/… URL here, and the DOI
            // is what a citation should point at rather than the API record.
            let doiURL = (work["doi"] as? String).flatMap(URL.init(string:))
            let landing = ((work["primary_location"] as? [String: Any])?["landing_page_url"]
                           as? String).flatMap(URL.init(string:))
            guard let url = doiURL ?? landing else { return nil }

            let authors = (work["authorships"] as? [[String: Any]] ?? []).compactMap {
                (($0["author"] as? [String: Any])?["display_name"]) as? String
            }
            return ScholarlyRecord(
                title: title, authors: authors,
                year: work["publication_year"] as? Int,
                doi: (work["doi"] as? String)?
                    .replacingOccurrences(of: "https://doi.org/", with: ""),
                url: url, abstract: nil, foundVia: name,
                tier: client.tier(for: url, foundIn: .t2), accessedAt: now)
        }
    }
}

// MARK: - Crossref

public struct CrossrefSource: ScholarlySource {
    public let name = "Crossref"
    private let client: APIClient

    public init(registry: SourceRegistry = SourceRegistry(), timeout: TimeInterval = 30) {
        client = APIClient(name: "Crossref", registry: registry, timeout: timeout)
    }

    public func search(_ query: String, limit: Int = 10) async throws -> [ScholarlyRecord] {
        let url = client.url("https://api.crossref.org/works",
                             ["query": query, "rows": String(limit),
                              "mailto": APIClient.contact])
        guard let root = try await client.json(url) as? [String: Any],
              let message = root["message"] as? [String: Any],
              let items = message["items"] as? [[String: Any]] else {
            throw ScholarlyError.decoding("Crossref: no items")
        }
        let now = Date()
        return items.compactMap { item in
            // Crossref's `title` is an array; an item with none is metadata
            // for something that is not a document.
            guard let title = (item["title"] as? [String])?.first,
                  let link = (item["URL"] as? String).flatMap(URL.init(string:))
            else { return nil }

            let authors = (item["author"] as? [[String: Any]] ?? []).compactMap { author -> String? in
                let given = author["given"] as? String
                let family = author["family"] as? String
                return [given, family].compactMap { $0 }.joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces).nilIfEmpty
            }
            let year = ((item["issued"] as? [String: Any])?["date-parts"] as? [[Int]])?
                .first?.first

            return ScholarlyRecord(
                title: title, authors: authors, year: year,
                doi: item["DOI"] as? String, url: link,
                abstract: (item["abstract"] as? String).map(Readability.stripTags),
                foundVia: name, tier: client.tier(for: link, foundIn: .t2), accessedAt: now)
        }
    }
}

// MARK: - PubMed

/// Two calls, because E-utilities separates "which ids match" from "what are
/// they" — esearch then esummary.
public struct PubMedSource: ScholarlySource {
    public let name = "PubMed"
    private let client: APIClient

    public init(registry: SourceRegistry = SourceRegistry(), timeout: TimeInterval = 30) {
        client = APIClient(name: "PubMed", registry: registry, timeout: timeout)
    }

    public func search(_ query: String, limit: Int = 10) async throws -> [ScholarlyRecord] {
        let searchURL = client.url("https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi",
                                   ["db": "pubmed", "term": query, "retmax": String(limit),
                                    "retmode": "json", "tool": "CoAIWorkspace"])
        guard let searchRoot = try await client.json(searchURL) as? [String: Any],
              let result = searchRoot["esearchresult"] as? [String: Any],
              let ids = result["idlist"] as? [String], !ids.isEmpty else { return [] }

        let summaryURL = client.url("https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi",
                                    ["db": "pubmed", "id": ids.joined(separator: ","),
                                     "retmode": "json", "tool": "CoAIWorkspace"])
        guard let summaryRoot = try await client.json(summaryURL) as? [String: Any],
              let records = summaryRoot["result"] as? [String: Any] else {
            throw ScholarlyError.decoding("PubMed: no result object")
        }

        let now = Date()
        return ids.compactMap { id in
            guard let record = records[id] as? [String: Any],
                  let title = record["title"] as? String,
                  let url = URL(string: "https://pubmed.ncbi.nlm.nih.gov/\(id)/")
            else { return nil }

            let authors = (record["authors"] as? [[String: Any]] ?? [])
                .compactMap { $0["name"] as? String }
            // "2026 Jul 29" — the year is the part that matters for weighing.
            let year = (record["pubdate"] as? String).flatMap { Int($0.prefix(4)) }
            let doi = (record["articleids"] as? [[String: Any]] ?? [])
                .first { $0["idtype"] as? String == "doi" }?["value"] as? String

            return ScholarlyRecord(
                title: title, authors: authors, year: year, doi: doi, url: url,
                abstract: nil, foundVia: name,
                tier: client.tier(for: url, foundIn: .t2), accessedAt: now)
        }
    }
}

// MARK: - Semantic Scholar

/// Documented as free, and it is — but an anonymous caller shares one pool and
/// is rate limited hard in practice (429 on the first request from this
/// machine while P3.3 was being written). Kept because a key makes it usable,
/// and the failure is reported as rate limiting rather than as no results.
public struct SemanticScholarSource: ScholarlySource {
    public let name = "Semantic Scholar"
    private let client: APIClient
    private let apiKey: String?

    public init(registry: SourceRegistry = SourceRegistry(), apiKey: String? = nil,
                timeout: TimeInterval = 30) {
        client = APIClient(name: "Semantic Scholar", registry: registry, timeout: timeout)
        self.apiKey = apiKey
    }

    public func search(_ query: String, limit: Int = 10) async throws -> [ScholarlyRecord] {
        let url = client.url("https://api.semanticscholar.org/graph/v1/paper/search",
                             ["query": query, "limit": String(limit),
                              "fields": "title,year,authors,externalIds,url,abstract"])
        guard let root = try await client.json(url) as? [String: Any] else {
            throw ScholarlyError.decoding("Semantic Scholar: not an object")
        }
        if (root["code"] as? String) == "429" {
            throw ScholarlyError.rateLimited(api: name)
        }
        guard let data = root["data"] as? [[String: Any]] else { return [] }

        let now = Date()
        return data.compactMap { paper in
            guard let title = paper["title"] as? String,
                  let link = (paper["url"] as? String).flatMap(URL.init(string:))
            else { return nil }
            let authors = (paper["authors"] as? [[String: Any]] ?? [])
                .compactMap { $0["name"] as? String }
            return ScholarlyRecord(
                title: title, authors: authors, year: paper["year"] as? Int,
                doi: (paper["externalIds"] as? [String: Any])?["DOI"] as? String,
                url: link, abstract: paper["abstract"] as? String, foundVia: name,
                tier: client.tier(for: link, foundIn: .t2), accessedAt: now)
        }
    }
}

// MARK: - medRxiv

/// **No keyword search exists.** The bioRxiv/medRxiv API answers by DOI or by
/// date range only — checked against the live service while writing P3.3.
/// `search` therefore refuses rather than quietly returning the most recent
/// preprints regardless of the question, which would look like a search and be
/// noise. Recent-by-date is offered under its own name.
public struct MedRxivSource: ScholarlySource {
    public let name = "medRxiv"
    private let client: APIClient
    private let server: String

    public init(registry: SourceRegistry = SourceRegistry(), server: String = "medrxiv",
                timeout: TimeInterval = 30) {
        client = APIClient(name: "medRxiv", registry: registry, timeout: timeout)
        self.server = server
    }

    public func search(_ query: String, limit: Int = 10) async throws -> [ScholarlyRecord] {
        throw ScholarlyError.unsupported(
            "medRxiv ไม่มี API ค้นด้วยคำค้น — ใช้ OpenAlex/Crossref ค้นแล้วค่อยดึงรายละเอียดด้วย DOI")
    }

    /// Details for a known preprint. This is what the API is actually for.
    public func record(doi: String) async throws -> ScholarlyRecord? {
        let url = URL(string: "https://api.biorxiv.org/details/\(server)/\(doi)")!
        guard let root = try await client.json(url) as? [String: Any],
              let collection = root["collection"] as? [[String: Any]],
              let entry = collection.last,
              let title = entry["title"] as? String else { return nil }

        let link = URL(string: "https://www.medrxiv.org/content/\(doi)")!
        let authors = (entry["authors"] as? String ?? "")
            .components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let year = (entry["date"] as? String).flatMap { Int($0.prefix(4)) }

        return ScholarlyRecord(
            title: title, authors: authors, year: year, doi: doi, url: link,
            abstract: entry["abstract"] as? String, foundVia: name,
            // A preprint is T3 wherever it was found — it has not been
            // reviewed, and the index that lists it does not change that.
            tier: client.tier(for: link, foundIn: .t3), accessedAt: Date())
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
