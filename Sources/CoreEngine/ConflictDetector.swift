import Foundation
import AgentKit
import Knowledge
import LLMProviders
import Observability

// ─────────────────────────────────────────────────────────────
// Noticing that two passages disagree (ARCHITECTURE §11.6, P3.6).
//
// The ledger can weigh a conflict and route it; what it cannot do is see one.
// Two chunks that answer the same question differently look, to BM25 and to
// cosine similarity, exactly like two chunks that agree — similarity is what
// retrieved them both in the first place.
//
// So this asks a model, and constrains the answer to a schema. Three things
// keep that honest:
//
//  • it is asked *only* about pairs retrieval already put side by side, so a
//    model is never trawling for disagreement that nobody asked about;
//  • the answer is structured, not prose, so "maybe, it depends" cannot be
//    read as a yes by whatever parses it;
//  • an uncertain answer means no conflict. A false positive puts a Conflict
//    Card in front of the user for two passages that agree, and a system that
//    cries wolf gets its cards dismissed unread — including the real ones.
// ─────────────────────────────────────────────────────────────

public struct ConflictFinding: Sendable, Equatable {
    public let contradicts: Bool
    /// What the two disagree about, in one line, for the card's heading.
    public let question: String
    public let confidence: Double
    public let explanation: String
}

public struct ConflictDetector: Sendable {
    private let router: ModelRouter
    /// Below this the pair is treated as agreeing. High on purpose — see the
    /// file comment: the cost of a false card is that real ones stop being
    /// read.
    private let minimumConfidence: Double
    private let log = AppLog.logger("conflict")

    public init(router: ModelRouter, minimumConfidence: Double = 0.7) {
        self.router = router
        self.minimumConfidence = minimumConfidence
    }

    private static let schema = #"""
    {"type":"object",
     "properties":{
       "contradicts":{"type":"boolean"},
       "question":{"type":"string"},
       "confidence":{"type":"number"},
       "explanation":{"type":"string"}},
     "required":["contradicts","question","confidence","explanation"]}
    """#

    /// Returns a finding only when the model says the two disagree and is sure
    /// enough to say so; `nil` means "treat these as compatible".
    public func detect(_ a: String, _ b: String,
                       about topic: String? = nil) async -> ConflictFinding? {
        var request = LLMRequest(messages: [
            .init(.system, """
            เปรียบเทียบข้อความสองชิ้นว่า **ขัดแย้งกันจริงหรือไม่**
            ขัดแย้ง = ตอบคำถามเดียวกันแต่ให้คำตอบที่เป็นจริงพร้อมกันไม่ได้ (ตัวเลขต่างกัน คำแนะนำตรงข้าม นิยามที่ใช้แทนกันไม่ได้)
            ไม่ขัดแย้ง = พูดคนละเรื่อง, เสริมกัน, รายละเอียดต่างระดับ, หรือเป็นเงื่อนไขคนละบริบท
            ถ้าไม่แน่ใจ ให้ตอบว่าไม่ขัดแย้ง และตั้ง confidence ต่ำ
            """),
            .init(.user, """
            \(topic.map { "หัวข้อ: \($0)\n" } ?? "")
            ข้อความ A:
            \(a)

            ข้อความ B:
            \(b)
            """),
        ])
        request.responseSchema = (name: "ConflictCheck", schemaJSON: Self.schema)
        request.maxTokens = 2_048
        request.temperature = 0

        do {
            // High impact: a wrong answer here either hides a contradiction or
            // manufactures one, so the router keeps this off the smallest tier
            // (§9.2).
            let completion = try await router.complete(request, policy: .init(impact: .high))
            guard let data = completion.text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let contradicts = object["contradicts"] as? Bool else {
                log.error("conflict check returned unparseable output")
                return nil
            }
            let confidence = (object["confidence"] as? Double)
                ?? (object["confidence"] as? Int).map(Double.init) ?? 0

            guard contradicts, confidence >= minimumConfidence else { return nil }
            return ConflictFinding(
                contradicts: true,
                question: object["question"] as? String ?? topic ?? "",
                confidence: confidence,
                explanation: object["explanation"] as? String ?? "")
        } catch {
            // A model that is unavailable must not turn into "these agree".
            // Nothing is filed, and the caller is told nothing was checked.
            log.error("conflict check unavailable: \(error)")
            return nil
        }
    }

    /// Checks the pairs a single retrieval returned and files what it finds.
    /// Only chunks from *different documents* are compared: two passages of one
    /// paper restating each other are not a conflict, and comparing them is
    /// where most of the cost would go.
    @discardableResult
    public func review(_ results: [SearchResult],
                       question: String,
                       scope: Scope,
                       into ledger: inout ConflictLedger,
                       limit: Int = 4) async -> [Conflict] {
        let candidates = Array(results.prefix(limit))
        var filed: [Conflict] = []

        for i in candidates.indices {
            for j in candidates.indices where j > i {
                let a = candidates[i], b = candidates[j]
                guard a.provenance.documentID != b.provenance.documentID else { continue }
                guard let finding = await detect(a.chunk.text, b.chunk.text, about: question)
                else { continue }

                filed.append(ledger.record(
                    question: finding.question.isEmpty ? question : finding.question,
                    a: ConflictSide(text: a.chunk.text, provenance: a.provenance),
                    b: ConflictSide(text: b.chunk.text, provenance: b.provenance),
                    scope: scope))
            }
        }
        return filed
    }
}
