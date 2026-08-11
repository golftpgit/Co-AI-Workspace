import Foundation
import Knowledge

// ─────────────────────────────────────────────────────────────
// T5, the general web, through a meta-search engine we run ourselves
// (ARCHITECTURE §1.4, P3.1).
//
// Why a sidecar rather than an API: every commercial search API has closed or
// throttled its free tier, and v1's answer — scraping DuckDuckGo's HTML — broke
// every time the markup changed. SearXNG has maintainers keeping ~70 engine
// parsers working, and we already run one sidecar, so the second is a process
// rather than an architecture.
//
// What comes back is a list of places to look, not evidence: §1.4 requires
// `fetch_page` before anything here is cited, and the snippet is deliberately
// not usable as a quote.
// ─────────────────────────────────────────────────────────────

public struct WebResult: Sendable, Equatable {
    public let title: String
    public let url: URL
    /// The engine's own summary. For deciding what to open — never for
    /// citing, which is what `fetch_page` is for.
    public let snippet: String
    public let engine: String
    public let tier: SourceTier
    public let accessedAt: Date
}

public enum WebSearchError: Error, CustomStringConvertible, Equatable {
    case unavailable(String)
    case http(status: Int)
    case decoding(String)
    /// SearXNG serves HTML by default; the JSON API has to be enabled in
    /// settings.yml. Worth its own case because the fix is one line of config
    /// and the symptom otherwise looks like a parse failure.
    case jsonFormatDisabled

    public var description: String {
        switch self {
        case .unavailable(let message): "SearXNG ใช้ไม่ได้: \(message.prefix(120))"
        case .http(let status): "SearXNG: http \(status)"
        case .decoding(let message): "อ่านผลจาก SearXNG ไม่ได้: \(message.prefix(120))"
        case .jsonFormatDisabled:
            "SearXNG ปิด JSON API อยู่ — ต้องเปิด `search.formats: [html, json]` ใน settings.yml"
        }
    }
}

public struct SearXNGSource: Sendable {
    public let name = "SearXNG"
    private let baseURL: URL
    private let registry: SourceRegistry
    private let timeout: TimeInterval

    public init(baseURL: URL = URL(string: "http://127.0.0.1:18080")!,
                registry: SourceRegistry = SourceRegistry(),
                timeout: TimeInterval = 30) {
        self.baseURL = baseURL
        self.registry = registry
        self.timeout = timeout
    }

    public func isAvailable() async -> Bool {
        var request = URLRequest(url: baseURL)
        request.timeoutInterval = 3
        guard let (_, response) = try? await URLSession.shared.data(for: request) else {
            return false
        }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    public func search(_ query: String, limit: Int = 10,
                       language: String = "auto") async throws -> [WebResult] {
        var components = URLComponents(url: baseURL.appendingPathComponent("search"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "language", value: language),
        ]

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw WebSearchError.unavailable("\(error)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw WebSearchError.unavailable("no HTTPURLResponse")
        }
        // 403 on the JSON endpoint while the instance itself answers is what
        // "formats: [html]" looks like from out here.
        if http.statusCode == 403, await isAvailable() { throw WebSearchError.jsonFormatDisabled }
        guard (200..<300).contains(http.statusCode) else {
            throw WebSearchError.http(status: http.statusCode)
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else {
            throw WebSearchError.decoding("no results array")
        }

        let now = Date()
        return results.prefix(limit).compactMap { result in
            guard let title = result["title"] as? String,
                  let link = (result["url"] as? String).flatMap(URL.init(string:))
            else { return nil }
            return WebResult(
                title: title, url: link,
                snippet: (result["content"] as? String) ?? "",
                // SearXNG reports which engine found it; useful when one
                // engine starts returning junk.
                engine: (result["engine"] as? String) ?? "unknown",
                // A meta-search result is rated by whoever published it, not
                // by the search engine — a WHO page found through SearXNG is
                // still T1.
                tier: registry.tier(for: link),
                accessedAt: now)
        }
    }
}
