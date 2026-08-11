import Testing
import Foundation
import AgentKit
import Knowledge
import LLMProviders
@testable import CoreEngine

// ─────────────────────────────────────────────────────────────
// P3.6's missing half: seeing that two passages disagree.
//
// Driven by a scripted model, because what is under test is what the detector
// does with an answer — including a hedged one — not whether a particular
// model is good at the judgement. The live check is opt-in below.
// ─────────────────────────────────────────────────────────────

private struct ScriptedExecutor: LLMExecutor {
    let identifier = "scripted"
    let tier: ModelTier = .selfHosted
    let capabilities = LLMCapabilities(contextWindow: 32_000, supportsTools: false,
                                       supportsStructuredOutput: true,
                                       supportsStreaming: true, supportsVision: false)
    let json: String

    func isAvailable() async -> Bool { true }

    func respond(to request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(json))
            continuation.yield(.finished(reason: "stop"))
            continuation.finish()
        }
    }
}

/// A reasoning model as LM Studio actually serves one: the schema-constrained
/// answer arrives in `reasoning_content` and `content` comes back empty, with
/// nothing reported as an error.
private struct ReasoningExecutor: LLMExecutor {
    let identifier = "reasoning"
    let tier: ModelTier = .selfHosted
    let capabilities = LLMCapabilities(contextWindow: 32_000, supportsTools: false,
                                       supportsStructuredOutput: true,
                                       supportsStreaming: true, supportsVision: false)
    let json: String

    func isAvailable() async -> Bool { true }

    func respond(to request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.reasoningDelta(json))
            continuation.yield(.finished(reason: "stop"))
            continuation.finish()
        }
    }
}

private struct DeadExecutor: LLMExecutor {
    let identifier = "dead"
    let tier: ModelTier = .selfHosted
    let capabilities = LLMCapabilities(contextWindow: 32_000, supportsTools: false,
                                       supportsStructuredOutput: true,
                                       supportsStreaming: true, supportsVision: false)
    func isAvailable() async -> Bool { false }
    func respond(to request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: LLMError.unavailable("offline")) }
    }
}

private func detector(saying json: String) -> ConflictDetector {
    ConflictDetector(router: ModelRouter(executors: [ScriptedExecutor(json: json)]))
}

@Suite("Conflict detection")
struct ConflictDetectorTests {
    @Test("a real contradiction is found")
    func contradictionIsDetected() async {
        let finding = await detector(saying: #"""
        {"contradicts":true,"question":"ขนาดยาที่แนะนำ","confidence":0.9,
         "explanation":"ตัวเลขขนาดยาต่างกันสำหรับผู้ป่วยกลุ่มเดียวกัน"}
        """#).detect("แนะนำ 500 มก. ต่อวัน", "แนะนำ 1000 มก. ต่อวัน")

        #expect(finding?.contradicts == true)
        #expect(finding?.question == "ขนาดยาที่แนะนำ")
    }

    // Found by driving the app against LM Studio: a real contradiction went
    // unreported on every ingest because qwen3.5 returned the JSON in
    // `reasoning_content` with `content` empty and `finish_reason: stop`.
    // Nothing errored, so "the model put its answer elsewhere" was
    // indistinguishable from "the model found no conflict" — and the same
    // silence emptied relation extraction.
    @Test("a reasoning model's answer is read, not mistaken for silence")
    func reasoningModelAnswerIsRead() async {
        let router = ModelRouter(executors: [ReasoningExecutor(json: #"""
        {"contradicts":true,"question":"ให้ยาต่อนานแค่ไหน","confidence":0.9,
         "explanation":"ฝั่งหนึ่งให้ต่อ 24 ชั่วโมง อีกฝั่งให้หยุดทันที"}
        """#)])
        let finding = await ConflictDetector(router: router)
            .detect("ให้ยาต่ออีก 24 ชั่วโมง", "หยุดยาทันทีที่ปิดแผล")

        #expect(finding?.contradicts == true)
        #expect(finding?.question == "ให้ยาต่อนานแค่ไหน")
    }

    @Test("passages that merely differ are not a conflict")
    func agreementIsNotAConflict() async {
        let finding = await detector(saying: #"""
        {"contradicts":false,"question":"","confidence":0.95,
         "explanation":"พูดคนละเรื่อง"}
        """#).detect("อินซูลินช่วยคุมน้ำตาล", "ควรออกกำลังกายสม่ำเสมอ")
        #expect(finding == nil)
    }

    @Test("an unsure answer is treated as no conflict")
    func lowConfidenceIsNotAConflict() async {
        // A card raised over two passages that agree teaches the user to
        // dismiss cards, and the next one dismissed is a real one.
        let finding = await detector(saying: #"""
        {"contradicts":true,"question":"อาจจะต่างกัน","confidence":0.4,
         "explanation":"ไม่แน่ใจ"}
        """#).detect("A", "B")
        #expect(finding == nil)
    }

    @Test("an unparseable answer is not read as a conflict")
    func garbageIsNotAConflict() async {
        let finding = await detector(saying: "ไม่แน่ใจครับ ลองดูอีกที")
            .detect("A", "B")
        #expect(finding == nil)
    }

    @Test("a model that cannot be reached does not mean the sources agree")
    func modelUnavailableIsNotAgreement() async {
        // Nothing is filed and nothing is claimed — the alternative is a
        // knowledge base that looks consistent because nobody could check.
        let detector = ConflictDetector(router: ModelRouter(executors: [DeadExecutor()]))
        #expect(await detector.detect("แนะนำ 500 มก.", "แนะนำ 1000 มก.") == nil)
    }

    @Test("only chunks from different documents are compared")
    func sameDocumentIsSkipped() async {
        var ledger = ConflictLedger()
        let detector = detector(saying: #"""
        {"contradicts":true,"question":"x","confidence":0.9,"explanation":"y"}
        """#)

        // Two passages of one paper restating each other are not a conflict,
        // and checking them is where most of the cost would go.
        let results = [result("c1", "ห้าใช่", document: "doc_1"),
                       result("c2", "สิบใช่", document: "doc_1")]
        let filed = await detector.review(results, question: "ค่าที่ถูกต้อง",
                                          scope: .central, into: &ledger)
        #expect(filed.isEmpty)
        #expect(ledger.all.isEmpty)
    }

    @Test("a reviewed pair from two documents reaches the ledger")
    func reviewFilesTheConflict() async {
        var ledger = ConflictLedger()
        let detector = detector(saying: #"""
        {"contradicts":true,"question":"ค่ามาตรฐาน","confidence":0.9,
         "explanation":"ตัวเลขต่างกัน"}
        """#)

        let filed = await detector.review(
            [result("c1", "ค่ามาตรฐานคือ 5", document: "doc_1", tier: .t2),
             result("c2", "ค่ามาตรฐานคือ 7", document: "doc_2", tier: .t2)],
            question: "ค่ามาตรฐาน", scope: .central, into: &ledger)

        #expect(filed.count == 1)
        #expect(ledger.all.count == 1)
        // Both sides verbatim, which is what the card shows (§11.6).
        #expect(filed.first?.a.text == "ค่ามาตรฐานคือ 5")
        #expect(filed.first?.b.text == "ค่ามาตรฐานคือ 7")
        // Two equally-credible sources is exactly the case a human decides.
        #expect(filed.first?.needsHuman == true)
    }
}

private func result(_ id: String, _ text: String, document: String,
                    tier: SourceTier = .t3) -> SearchResult {
    SearchResult(
        chunk: IndexedChunk(id: id, text: text, scope: .central,
                            provenance: Provenance(documentID: document, title: document,
                                                   origin: .upload(filename: "\(document).pdf"),
                                                   tier: tier, year: 2025)),
        score: 1, lexicalRank: 1, semanticRank: nil)
}
