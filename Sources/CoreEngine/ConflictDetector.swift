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

/// Why a pair was not filed. Kept rather than folded into `nil`, because "the
/// model said they agree" and "the two answer different questions" call for
/// different things: the first is an answer, the second is the criteria doing
/// their job, and only one of them is worth showing anybody (§11.7, P18.1).
public enum ConflictRejection: Error, Sendable, Equatable {
    /// One of the three NLI conditions was not met (§11.7).
    case differentQuestion
    case notMutuallyExclusive
    /// Different populations, ages, settings — `bothInContext` in the ledger's
    /// own vocabulary, and a real answer rather than a near miss.
    case differentContext
    /// The model was not sure enough. Cross-language pairs are held to a
    /// higher bar, for the reason in the file comment.
    case notConfidentEnough(Double)
    case modelSaidNo
    case modelUnavailable
    case unparseable
}

public struct ConflictDetector: Sendable {
    private let router: ModelRouter
    /// Below this the pair is treated as agreeing. High on purpose — see the
    /// file comment: the cost of a false card is that real ones stop being
    /// read.
    private let minimumConfidence: Double
    /// The bar for a pair written in two languages (§11.7, P18.1).
    ///
    /// Higher, and not as a matter of taste: **a model that cannot read one of
    /// the two sides answers "contradiction" with high confidence**, because
    /// what it sees is two passages that do not match. That is how the cards
    /// that started §11.7 were raised. The planned fix — filter the pair out
    /// with an embedding before the model sees it — was measured and does not
    /// work (E.25), so what is left is to require more before believing the
    /// answer, and to say in the criteria that a translation is not a
    /// disagreement.
    private let crossLanguageConfidence: Double
    private let log = AppLog.logger("conflict")

    public init(router: ModelRouter,
                minimumConfidence: Double = 0.7,
                crossLanguageConfidence: Double = 0.9) {
        self.router = router
        self.minimumConfidence = minimumConfidence
        self.crossLanguageConfidence = max(minimumConfidence, crossLanguageConfidence)
    }

    /// §11.7's three conditions, asked one at a time.
    ///
    /// They used to be one `contradicts` boolean with the conditions described
    /// in the prompt, which asks the model to do the reasoning *and* the
    /// bookkeeping and gives nothing to check afterwards. Asked separately,
    /// each one can be refused on its own — and "these answer different
    /// questions" is a different card from "these disagree", which is exactly
    /// the distinction NLI research says is missed most often
    /// (*reference indeterminacy*).
    private static let schema = #"""
    {"type":"object",
     "properties":{
       "sameQuestion":{"type":"boolean"},
       "mutuallyExclusive":{"type":"boolean"},
       "sameContext":{"type":"boolean"},
       "isTranslation":{"type":"boolean"},
       "question":{"type":"string"},
       "confidence":{"type":"number"},
       "explanation":{"type":"string"}},
     "required":["sameQuestion","mutuallyExclusive","sameContext","isTranslation",
                 "question","confidence","explanation"]}
    """#

    /// Returns a finding only when the model says the two disagree and is sure
    /// enough to say so; `nil` means "treat these as compatible".
    public func detect(_ a: String, _ b: String,
                       about topic: String? = nil) async -> ConflictFinding? {
        try? await examine(a, b, about: topic).get()
    }

    /// The same judgement, with the reason it came out the way it did.
    ///
    /// `detect` throws that away because most callers only file cards; the
    /// screen and the checks want to know *which* condition failed, since
    /// "these answer different questions" and "the model was not sure" are
    /// different facts about the library.
    public func examine(_ a: String, _ b: String,
                        about topic: String? = nil)
        async -> Result<ConflictFinding, ConflictRejection> {
        let crossLanguage = TextScriptReader.differentLanguages(a, b)
        var request = LLMRequest(messages: [
            .init(.system, Self.criteria(crossLanguage: crossLanguage)),
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
            guard let data = completion.structuredText.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sameQuestion = object["sameQuestion"] as? Bool,
                  let mutuallyExclusive = object["mutuallyExclusive"] as? Bool,
                  let sameContext = object["sameContext"] as? Bool else {
                log.error("conflict check returned unparseable output")
                return .failure(.unparseable)
            }
            let confidence = (object["confidence"] as? Double)
                ?? (object["confidence"] as? Int).map(Double.init) ?? 0

            // §11.7's three conditions, each refused on its own terms. Order
            // matters for what gets reported: a pair that answers two different
            // questions was never a candidate, whatever else is true of it.
            guard sameQuestion else { return .failure(.differentQuestion) }
            guard sameContext else { return .failure(.differentContext) }
            // The language rule, and it is checked here rather than trusted to
            // the prompt: a model that says "these are translations" and
            // "these contradict" in the same answer has told us which of the
            // two to believe.
            if object["isTranslation"] as? Bool == true { return .failure(.notMutuallyExclusive) }
            guard mutuallyExclusive else { return .failure(.notMutuallyExclusive) }

            let bar = crossLanguage ? crossLanguageConfidence : minimumConfidence
            guard confidence >= bar else { return .failure(.notConfidentEnough(confidence)) }

            return .success(ConflictFinding(
                contradicts: true,
                question: object["question"] as? String ?? topic ?? "",
                confidence: confidence,
                explanation: object["explanation"] as? String ?? ""))
        } catch {
            // A model that is unavailable must not turn into "these agree".
            // Nothing is filed, and the caller is told nothing was checked.
            log.error("conflict check unavailable: \(error)")
            return .failure(.modelUnavailable)
        }
    }

    /// §11.7's criteria, in the words the model is asked to apply them in.
    ///
    /// The language paragraph is only added when the two sides really are in
    /// different scripts. A rule about translation in front of two Thai
    /// passages is a sentence the model has to reconcile with what it sees, and
    /// every unnecessary instruction is a chance to answer the wrong question.
    private static func criteria(crossLanguage: Bool) -> String {
        var text = """
        ตัดสินว่าข้อความสองชิ้น **ขัดแย้งกันจริงหรือไม่** ตามเกณฑ์ NLI สามข้อ ซึ่งต้องจริง**พร้อมกันทั้งสามข้อ**:

        1. sameQuestion — ตอบคำถามเดียวกันจริงไหม (ประชากรเดียวกัน ช่วงเวลาเดียวกัน หน่วยวัดเดียวกัน) \
        ถ้าพูดคนละประชากรหรือคนละหน่วย ให้ false
        2. mutuallyExclusive — จาก A อนุมานได้ว่า B เป็นเท็จจริงไหม \
        แค่ "ไม่เหมือนกัน" ไม่นับ · **ตัวเลขที่ต่างกันแต่ช่วงความเชื่อมั่นทับกัน ให้ false**
        3. sameContext — เงื่อนไขเดียวกันไหม \
        คำแนะนำสำหรับผู้ใหญ่กับสำหรับเด็ก คือคนละเงื่อนไข ให้ false

        ถ้าข้อใดข้อหนึ่งเป็น false = ไม่ขัดแย้ง (neutral) และ neutral ไม่ต้องยกการ์ด
        ไม่แน่ใจ = ตั้ง confidence ต่ำ
        """
        if crossLanguage {
            text += """


            **ข้อความสองชิ้นนี้เขียนคนละภาษา** — ถ้ามันคือ*ข้อความเดียวกันที่แปลกันไปมา* \
            ให้ isTranslation = true และ mutuallyExclusive = false \
            **คำแปลไม่ใช่ข้อขัดแย้ง** แม้จะเขียนไม่เหมือนกันคำต่อคำ \
            ถ้าอ่านฝั่งใดฝั่งหนึ่งไม่ออก ให้ตั้ง confidence ต่ำ อย่าเดาว่าขัดแย้ง
            """
        }
        return text
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
