import Foundation
import AgentKit
import Knowledge
import LLMProviders
import Observability

// ─────────────────────────────────────────────────────────────
// The half of the knowledge graph a tagger cannot do (ARCHITECTURE §11.4,
// carried over from P2.3).
//
// `NLTagger` finds the names in a sentence. What connects them — who studied
// what, which drug treats which condition, which agency published which rule —
// is in the grammar, and reading grammar is what a model is for.
//
// The rule that keeps this from inventing a graph: **a relation must be
// supported by the chunk it came from**. Both endpoints have to be entities
// actually present in the text, and anything else is dropped. A knowledge
// graph that quietly contains things nobody wrote is worse than no graph,
// because it is queried as though it were evidence.
// ─────────────────────────────────────────────────────────────

public struct Relation: Sendable, Equatable, Codable {
    public let subject: String
    /// A short verb phrase in the document's own language — not a fixed
    /// ontology. A closed predicate list would need maintenance nobody will do
    /// and would silently drop everything it has no term for.
    public let predicate: String
    public let object: String
    /// Which chunk says so. A relation with no source cannot be checked, and
    /// an unfalsifiable graph is not knowledge.
    public let chunkID: String

    public init(subject: String, predicate: String, object: String, chunkID: String) {
        self.subject = subject
        self.predicate = predicate
        self.object = object
        self.chunkID = chunkID
    }
}

public struct RelationExtractor: Sendable {
    private let router: ModelRouter
    private let log = AppLog.logger("relations")

    public init(router: ModelRouter) {
        self.router = router
    }

    private static let schema = #"""
    {"type":"object",
     "properties":{
       "relations":{"type":"array","items":{
         "type":"object",
         "properties":{
           "subject":{"type":"string"},
           "predicate":{"type":"string"},
           "object":{"type":"string"}},
         "required":["subject","predicate","object"]}}},
     "required":["relations"]}
    """#

    /// Relations stated in this chunk. Never invented: an endpoint the text
    /// does not contain is dropped, so an empty result means the model found
    /// nothing rather than that extraction failed silently.
    public func relations(in chunk: IndexedChunk) async -> [Relation] {
        guard chunk.text.count > 20 else { return [] }

        var request = LLMRequest(messages: [
            .init(.system, """
            สกัดความสัมพันธ์ที่ **ข้อความระบุไว้ตรงๆ** เท่านั้น
            - subject และ object ต้องเป็นคำที่ปรากฏในข้อความจริง ห้ามเติมความรู้จากภายนอก
            - predicate เป็นวลีกริยาสั้นๆ ในภาษาเดียวกับข้อความ
            - ถ้าไม่มีความสัมพันธ์ที่ระบุชัด ให้คืน relations เป็น []
            """),
            .init(.user, chunk.text),
        ])
        request.responseSchema = (name: "Relations", schemaJSON: Self.schema)
        request.maxTokens = 2_048
        request.temperature = 0

        do {
            let completion = try await router.complete(request)
            guard let data = completion.structuredText.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = root["relations"] as? [[String: Any]] else {
                log.error("relation extraction returned unparseable output")
                return []
            }

            let haystack = chunk.text.lowercased()
            return rows.compactMap { row in
                guard let subject = (row["subject"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      let predicate = (row["predicate"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      let object = (row["object"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !subject.isEmpty, !predicate.isEmpty, !object.isEmpty
                else { return nil }

                // The check that makes the graph checkable: both ends have to
                // be in the text the relation claims to come from.
                guard haystack.contains(subject.lowercased()),
                      haystack.contains(object.lowercased()) else {
                    log.error("dropped a relation whose endpoints are not in the chunk")
                    return nil
                }
                guard subject.lowercased() != object.lowercased() else { return nil }

                return Relation(subject: subject, predicate: predicate,
                                object: object, chunkID: chunk.id)
            }
        } catch {
            // Unavailable is not "no relations": returning empty here would
            // look identical to a chunk that genuinely states none.
            log.error("relation extraction unavailable: \(error)")
            return []
        }
    }

    /// Extracts across chunks, keeping each relation attached to the chunk that
    /// supports it. Deliberately sequential: this runs over a whole document
    /// at ingest time and a fan-out would queue behind the same model anyway.
    public func relations(in chunks: [IndexedChunk]) async -> [Relation] {
        var found: [Relation] = []
        for chunk in chunks {
            found.append(contentsOf: await relations(in: chunk))
        }
        return found
    }
}
