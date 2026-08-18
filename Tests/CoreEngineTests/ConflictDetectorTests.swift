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
        {"sameQuestion":true,"mutuallyExclusive":true,"sameContext":true,"isTranslation":false,
         "question":"ขนาดยาที่แนะนำ","confidence":0.9,
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
        {"sameQuestion":true,"mutuallyExclusive":true,"sameContext":true,"isTranslation":false,
         "question":"ให้ยาต่อนานแค่ไหน","confidence":0.9,
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
        {"sameQuestion":false,"mutuallyExclusive":false,"sameContext":true,"isTranslation":false,
         "question":"","confidence":0.95,"explanation":"พูดคนละเรื่อง"}
        """#).detect("อินซูลินช่วยคุมน้ำตาล", "ควรออกกำลังกายสม่ำเสมอ")
        #expect(finding == nil)
    }

    @Test("an unsure answer is treated as no conflict")
    func lowConfidenceIsNotAConflict() async {
        // A card raised over two passages that agree teaches the user to
        // dismiss cards, and the next one dismissed is a real one.
        let finding = await detector(saying: #"""
        {"sameQuestion":true,"mutuallyExclusive":true,"sameContext":true,"isTranslation":false,
         "question":"อาจจะต่างกัน","confidence":0.4,"explanation":"ไม่แน่ใจ"}
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

    // ─────────────────────────────────────────────────────────
    // P18.1 — §11.7's three conditions, each one refused on its own terms.
    //
    // They used to live in the prompt as prose and come back as one boolean.
    // A model that answers "yes they contradict" while also saying the two
    // passages are about different populations has told us both things; the
    // old shape kept only the answer it was asked for.
    // ─────────────────────────────────────────────────────────

    @Test("two answers to different questions are not a contradiction")
    func differentQuestionsIsNotAConflict() async {
        // NLI's *reference indeterminacy*: the largest single source of
        // mislabelling is two sentences that look opposed and are about
        // different populations, periods or units.
        let outcome = await detector(saying: #"""
        {"sameQuestion":false,"mutuallyExclusive":true,"sameContext":true,"isTranslation":false,
         "question":"อัตราการติดเชื้อ","confidence":0.95,"explanation":"คนละประชากร"}
        """#).examine("อัตราในโรงพยาบาล 5%", "อัตราในชุมชน 12%")

        #expect(outcome == .failure(.differentQuestion))
    }

    @Test("advice for adults against advice for children is context, not conflict")
    func differentContextIsNotAConflict() async {
        // The ledger has had `bothInContext` as a decision since §11.6; this is
        // the same fact, reached before a card is raised rather than after
        // somebody spends attention on one.
        let outcome = await detector(saying: #"""
        {"sameQuestion":true,"mutuallyExclusive":true,"sameContext":false,"isTranslation":false,
         "question":"ขนาดยา","confidence":0.95,"explanation":"ผู้ใหญ่กับเด็ก"}
        """#).examine("ผู้ใหญ่ใช้ 500 มก.", "เด็กใช้ 250 มก.")

        #expect(outcome == .failure(.differentContext))
    }

    @Test("numbers that differ inside overlapping intervals are not a contradiction")
    func overlappingIntervalsAreNotAConflict() async {
        // §11.7 condition 2 in the form it actually turns up in papers: two
        // effect sizes that are not the same number and are not incompatible.
        let outcome = await detector(saying: #"""
        {"sameQuestion":true,"mutuallyExclusive":false,"sameContext":true,"isTranslation":false,
         "question":"ผลของการรักษา","confidence":0.9,"explanation":"ช่วงความเชื่อมั่นทับกัน"}
        """#).examine("OR 1.8 (95% CI 1.2–2.6)", "OR 2.1 (95% CI 1.5–2.9)")

        #expect(outcome == .failure(.notMutuallyExclusive))
    }

    // The symptom that started §11.7: the cards raised were one sentence in
    // two languages.
    @Test("the same sentence in two languages never becomes a card")
    func translationIsNotAConflict() async {
        let thai = "การนอนหลับที่เพียงพอช่วยลดความเสี่ยงของโรคหัวใจในผู้ใหญ่"
        let english = "Adequate sleep reduces the risk of heart disease in adults"
        // A model that cannot read one side answers exactly like this: sure of
        // itself, and wrong.
        let outcome = await detector(saying: #"""
        {"sameQuestion":true,"mutuallyExclusive":true,"sameContext":true,"isTranslation":true,
         "question":"การนอนกับโรคหัวใจ","confidence":0.98,"explanation":"ข้อความไม่ตรงกัน"}
        """#).examine(thai, english)

        #expect(outcome == .failure(.notMutuallyExclusive),
                "a translated pair was filed as a conflict — the §11.7 symptom")
    }

    @Test("a cross-language pair is held to a higher bar than a same-language one")
    func crossLanguageNeedsMoreConfidence() async {
        // 0.75 clears the ordinary bar (0.7) and not the cross-language one
        // (0.8), because the model is reading a language it may not have.
        //
        // The value used to be 0.8, which stopped discriminating when the
        // cross-language bar came down from 0.9 — measured, that bar was
        // discarding correct answers at 0.85, and translation is already
        // refused by name through `isTranslation` (E.45). **The property this
        // test guards is unchanged**: cross-language is still held higher than
        // same-language. Only the number that demonstrates it moved.
        let json = #"""
        {"sameQuestion":true,"mutuallyExclusive":true,"sameContext":true,"isTranslation":false,
         "question":"ผลของวัคซีน","confidence":0.75,"explanation":"ตรงข้ามกัน"}
        """#
        let thai = "วัคซีนไข้หวัดใหญ่ลดอัตราการเข้ารักษาในโรงพยาบาลของผู้สูงอายุ"
        let english = "Influenza vaccination has no effect on hospital admissions in older adults"

        #expect(await detector(saying: json).examine(thai, english)
                == .failure(.notConfidentEnough(0.75)))
        // The same answer about two Thai passages is filed: nothing here says
        // the model is bad at Thai, only that it may not read both languages.
        let bothThai = await detector(saying: json)
            .examine(thai, "วัคซีนไข้หวัดใหญ่ไม่มีผลต่อการเข้ารักษาในโรงพยาบาลของผู้สูงอายุ")
        #expect((try? bothThai.get())?.contradicts == true)
    }

    @Test("a cross-language pair that is sure enough is still filed")
    func crossLanguageCanStillBeAConflict() async {
        // The gate must not become "cross-language conflicts do not exist" —
        // a Thai guideline against an English trial is a real card.
        let outcome = await detector(saying: #"""
        {"sameQuestion":true,"mutuallyExclusive":true,"sameContext":true,"isTranslation":false,
         "question":"ผลของวัคซีน","confidence":0.95,"explanation":"ผลตรงข้ามกันชัดเจน"}
        """#).examine("วัคซีนไข้หวัดใหญ่ลดอัตราการเข้ารักษาในโรงพยาบาลของผู้สูงอายุ",
                      "Influenza vaccination has no effect on hospital admissions in older adults")

        #expect((try? outcome.get())?.contradicts == true)
    }

    @Test("only chunks from different documents are compared")
    func sameDocumentIsSkipped() async {
        var ledger = ConflictLedger()
        let detector = detector(saying: #"""
        {"sameQuestion":true,"mutuallyExclusive":true,"sameContext":true,"isTranslation":false,
         "question":"x","confidence":0.9,"explanation":"y"}
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
        {"sameQuestion":true,"mutuallyExclusive":true,"sameContext":true,"isTranslation":false,
         "question":"ค่ามาตรฐาน","confidence":0.9,"explanation":"ตัวเลขต่างกัน"}
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
