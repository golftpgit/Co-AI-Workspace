import Foundation
import CryptoKit

// ─────────────────────────────────────────────────────────────
// What an index was built with (ARCHITECTURE §11, E.10).
//
// An embedding model is not a tier. Swapping the chat model costs nothing —
// that is what the Model Router is for. Swapping the embedding model puts every
// stored vector in a different space, and search keeps working while ranking
// nothing: the failure has no error to catch (E.11 is the same failure from a
// different direction).
//
// So the model is pinned to the *index*, not to the call, and it is recorded
// with everything that changes what a vector means:
//
//  • the model and its build — two quantisations of one model are two spaces;
//  • pooling and normalisation — the same weights read two ways;
//  • the tokenizer version — merge-layer changes alter the terms BM25 sees;
//  • the chunker version — different boundaries mean different chunk ids, and
//    the entity/relation graph and every citation anchor hang off those ids.
//
// The last one is the dangerous one. A new embedding model costs a re-embed
// from text we already hold. A new chunker costs the graph.
// ─────────────────────────────────────────────────────────────

public struct EmbeddingProfile: Sendable, Equatable, Codable {
    public enum Pooling: String, Sendable, Codable { case cls, mean, lastToken }

    public let modelID: String
    /// Quantisation, revision, or build tag. `q8_0` and `f16` of one model do
    /// not produce interchangeable vectors.
    public let revision: String
    public let dimensions: Int
    public let pooling: Pooling
    public let normalised: Bool
    public let tokenizerVersion: Int
    public let chunkerVersion: Int

    public init(modelID: String, revision: String, dimensions: Int,
                pooling: Pooling = .cls, normalised: Bool = true,
                tokenizerVersion: Int = Tokenizer.version,
                chunkerVersion: Int = Chunker.version) {
        self.modelID = modelID
        self.revision = revision
        self.dimensions = dimensions
        self.pooling = pooling
        self.normalised = normalised
        self.tokenizerVersion = tokenizerVersion
        self.chunkerVersion = chunkerVersion
    }

    /// Derived, not stored: two configurations that are the same in every way
    /// that matters get the same id, and any difference produces a new one.
    /// That is what makes "does this vector belong in this index" a comparison
    /// rather than a judgement call.
    public var id: String {
        let fingerprint = [
            modelID, revision, String(dimensions), pooling.rawValue,
            normalised ? "norm" : "raw",
            "tok\(tokenizerVersion)", "chunk\(chunkerVersion)",
        ].joined(separator: "|")
        return "emb_" + SHA256.hash(data: Data(fingerprint.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(16)
    }

    /// What P2.1 locked after measuring four candidates (ARCHITECTURE E.10).
    /// The dimension is part of the decision, not a detail of the deployment.
    public static let bgeM3 = EmbeddingProfile(modelID: "bge-m3", revision: "q8_0",
                                               dimensions: 1_024)
}

public enum IndexProfileError: Error, CustomStringConvertible, Equatable {
    case foreignVector(indexProfile: String, chunkProfile: String)
    case vectorWithoutProfile
    case lexicalIndexCannotHoldVectors
    case queriedWithAnotherModel(indexProfile: String, queryProfile: String)

    public var description: String {
        switch self {
        case .foreignVector(let index, let chunk):
            return "vector was built with \(chunk) but this index is \(index) — re-embed before inserting"
        case .vectorWithoutProfile:
            return "a vector arrived without saying which model produced it"
        case .lexicalIndexCannotHoldVectors:
            return "this index has no embedding profile, so it cannot store vectors"
        case .queriedWithAnotherModel(let index, let query):
            return "searching \(index) with \(query): the two models do not share a vector space"
        }
    }
}
