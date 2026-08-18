import Foundation

// ─────────────────────────────────────────────────────────────
// The vector half of hybrid search (ARCHITECTURE §11, E.10).
//
// P2.1 locked `bge-m3` at 1024 dimensions before any indexing began, because
// changing it later means re-embedding the whole knowledge base. The protocol
// declares its dimension and every implementation checks what it got back
// against it: a silently different dimension corrupts an index in a way that
// only shows up as bad answers.
// ─────────────────────────────────────────────────────────────

public protocol Embedder: Sendable {
    var identifier: String { get }
    /// Which vector space this produces. Required, not derived: an embedder
    /// that cannot say what it is cannot be checked against an index.
    var profile: EmbeddingProfile { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}

extension Embedder {
    public var dimensions: Int { profile.dimensions }
}

extension Embedder {
    public func embed(_ text: String) async throws -> [Float] {
        guard let vector = try await embed([text]).first else {
            throw EmbeddingError.empty
        }
        return vector
    }
}

public enum EmbeddingError: Error, CustomStringConvertible, Equatable {
    case empty
    case dimensionMismatch(expected: Int, got: Int)
    case transport(String)
    case http(status: Int, body: String)

    public var description: String {
        switch self {
        case .empty: return "the embedder returned nothing"
        case .dimensionMismatch(let e, let g):
            return "embedding dimension \(g) does not match the indexed \(e) — re-indexing required"
        case .transport(let m): return "transport: \(m.prefix(120))"
        case .http(let s, let b): return "http(\(s)): \(b.prefix(120))"
        }
    }
}

/// What a health check found out about a model before it is trusted with an
/// index. Verified on hardware: `text-embedding-nomic-embed-text-v1.5` served
/// by LM Studio returns the *same* vector for every Thai input while handling
/// English normally (ARCHITECTURE E.11). Indexing with it would fill the
/// vector half of hybrid search with identical rows and degrade silently —
/// the search still returns something, it is just meaningless.
public enum EmbedderDiagnosis: Sendable, Equatable {
    case healthy
    /// Different texts in this script come back as the same vector.
    case blind(to: String)

    public var isUsable: Bool { self == .healthy }
}

/// Embeds two obviously different sentences per script and checks the model
/// can tell them apart. Cheap, and the only thing standing between a
/// script-blind model and a knowledge base full of identical vectors.
public func diagnose(_ embedder: some Embedder) async throws -> EmbedderDiagnosis {
    /// LOCALISATION: matching data — see RULES.md U24.
    let probes: [(script: String, texts: [String])] = [
        ("Thai", ["การให้อินซูลินในผู้ป่วยเบาหวาน", "การปนเปื้อนโลหะหนักในแหล่งน้ำดิบ"]),
        ("Latin", ["insulin therapy in diabetic patients", "heavy metal contamination in water"]),
    ]
    for probe in probes {
        let vectors = try await embedder.embed(probe.texts)
        guard vectors.count == 2 else { throw EmbeddingError.empty }
        // Not a threshold: identical is identical. A model that merely finds
        // two sentences similar is doing its job.
        if vectors[0] == vectors[1] { return .blind(to: probe.script) }
    }
    return .healthy
}

public func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot = 0.0, normA = 0.0, normB = 0.0
    for i in a.indices {
        dot += Double(a[i]) * Double(b[i])
        normA += Double(a[i]) * Double(a[i])
        normB += Double(b[i]) * Double(b[i])
    }
    guard normA > 0, normB > 0 else { return 0 }
    return dot / (sqrt(normA) * sqrt(normB))
}

/// Any OpenAI-compatible `/v1/embeddings` endpoint — LM Studio locally, vLLM
/// on the GX10, or a hosted API. Same shape as `VLLMExecutor` for the same
/// reason: one protocol, several places it can run.
public struct RemoteEmbedder: Embedder {
    public let identifier: String
    public let profile: EmbeddingProfile
    private let baseURL: URL
    private let model: String
    private let apiKey: String?

    public init(baseURL: URL, model: String, profile: EmbeddingProfile, apiKey: String? = nil) {
        self.identifier = model
        self.baseURL = baseURL
        self.model = model
        self.profile = profile
        self.apiKey = apiKey
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        do {
            return try await send(texts)
        } catch let error as EmbeddingError where Self.isTransient(error) {
            // LM Studio evicts idle models and then rejects whatever was in
            // flight; the next request loads it again. Ingesting a document is
            // thousands of calls, so failing the whole run on an eviction that
            // fixes itself is not acceptable. One retry, and only for this.
            return try await send(texts)
        }
    }

    private static func isTransient(_ error: EmbeddingError) -> Bool {
        guard case .http(let status, let body) = error else { return false }
        return status == 503 || body.contains("Model was unloaded")
    }

    private func send(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }

        var request = URLRequest(url: baseURL.appendingPathComponent("embeddings"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["model": model, "input": texts],
            options: [.withoutEscapingSlashes])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw EmbeddingError.transport("\(error)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw EmbeddingError.transport("no HTTPURLResponse")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw EmbeddingError.http(status: http.statusCode,
                                      body: String(decoding: data.prefix(400), as: UTF8.self))
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]] else {
            throw EmbeddingError.empty
        }
        // The endpoint may return rows out of order; `index` is authoritative.
        let vectors = rows
            .sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }
            .compactMap { $0["embedding"] as? [Double] }
            .map { $0.map(Float.init) }

        guard vectors.count == texts.count else { throw EmbeddingError.empty }
        for vector in vectors where vector.count != dimensions {
            throw EmbeddingError.dimensionMismatch(expected: dimensions, got: vector.count)
        }
        return vectors
    }
}
