import Testing
import Foundation
import AgentKit
@testable import CoreEngine

// ─────────────────────────────────────────────────────────────
// Promotion from a conversation (ARCHITECTURE §19.1, P10.3).
//
// Everything here runs without a model, for the same reason `GapDetector`'s
// tests do: the model's only job is turning prose into a `BriefReading`, and
// every rule about what the draft says — and what it refuses to invent — is
// deterministic.
// ─────────────────────────────────────────────────────────────

private let conversation: [TranscriptTurn] = [
    .init(fromUser: true, text: "แบบวัด burnout ที่ใช้กับพยาบาลไทย มีตัวไหนที่แปลและตรวจความตรงแล้วบ้าง"),
    .init(fromUser: false, text: "พบ 3 ฉบับ — MBI-HSS ฉบับแปลไทย, CBI ฉบับแปลไทย และ OLBI"),
    .init(fromUser: true, text: "เอา แล้วน่าจะทำเป็นงานวิจัยจริงเลย"),
]

@Suite("Drafting a brief from a conversation")
struct BriefDrafterTests {

    @Test("what the conversation said comes through")
    func carriesWhatWasSaid() {
        let reading = BriefReading(
            name: "ภาวะหมดไฟในพยาบาลวิชาชีพ",
            purpose: "หาความชุกและความตรงของมาตรวัดฉบับไทย",
            inScope: ["ความชุกใน รพ. ตติยภูมิ 2 แห่ง"],
            outOfScope: ["การเปรียบเทียบข้ามวิชาชีพ"])

        let draft = BriefDraft.assemble(reading: reading, transcript: conversation)
        #expect(draft.name == "ภาวะหมดไฟในพยาบาลวิชาชีพ")
        #expect(draft.brief == "หาความชุกและความตรงของมาตรวัดฉบับไทย")
        #expect(draft.statement.inScope == ["ความชุกใน รพ. ตติยภูมิ 2 แห่ง"])
        #expect(draft.openQuestions.isEmpty)
        #expect(draft.isReadyForG1)
    }

    @Test("what it never said becomes a question, not a guess")
    func silenceIsNotInvented() {
        // The realistic case: people say what they want, never what they are
        // leaving out. A draft that filled this in would pass G1 while meaning
        // nothing, which is worse than one that stops and asks (§19.6).
        let reading = BriefReading(name: "ภาวะหมดไฟในพยาบาล",
                                   purpose: "หาความชุก",
                                   inScope: ["ความชุก"],
                                   outOfScope: [])

        let draft = BriefDraft.assemble(reading: reading, transcript: conversation)
        #expect(draft.statement.outOfScope.isEmpty)
        #expect(!draft.isReadyForG1)
        #expect(draft.openQuestions.contains { $0.contains("G1") })
    }

    @Test("a model that could not answer says so, and still hands back a usable form")
    func modelFailureIsVisible() {
        let draft = BriefDraft.assemble(reading: nil, transcript: conversation)

        // Not an empty form pretending to be a draft: the first line says the
        // draft did not happen. A promotion button that silently produces
        // nothing is indistinguishable from one that is broken.
        #expect(draft.openQuestions.first == BriefDraft.couldNotRead)
        // And the name still comes from the conversation, because the fallback
        // is deterministic rather than model-dependent.
        #expect(draft.name.contains("แบบวัด burnout"))
        #expect(!draft.isReadyForG1)
    }

    @Test("the fallback name is a title, not the first 48 characters of a paragraph")
    func fallbackNameCutsAtAWordBoundary() {
        let long = "ช่วยดูหน่อยว่าข้อมูลชุดนี้ควรใช้สถิติแบบไหน และต้องตรวจ assumption อะไรก่อนบ้าง"
        let name = BriefDraft.summarise(long)

        #expect(name.count <= 48)
        #expect(!name.hasSuffix(" "))
        #expect(long.hasPrefix(name))
    }

    @Test("blank fields from the model are dropped rather than kept as empty bullets")
    func blankBulletsAreDropped() {
        let reading = BriefReading(name: "  ", purpose: "  ",
                                   inScope: ["ทำ ก", "   ", ""],
                                   outOfScope: [" ไม่ทำ ข "])

        let draft = BriefDraft.assemble(reading: reading, transcript: conversation)
        #expect(draft.statement.inScope == ["ทำ ก"])
        #expect(draft.statement.outOfScope == ["ไม่ทำ ข"])
        // A blank name falls back to the conversation rather than becoming an
        // untitled project.
        #expect(draft.name.contains("แบบวัด burnout"))
        #expect(draft.brief.isEmpty)
        #expect(draft.openQuestions.contains("ยังไม่ได้บอกว่าทำโครงการนี้ไปเพื่ออะไร"))
    }

    @Test("an empty conversation still produces something nameable")
    func emptyTranscript() {
        let draft = BriefDraft.assemble(reading: nil, transcript: [])
        #expect(draft.name == "โปรเจกต์ใหม่")
        #expect(!draft.isReadyForG1)
    }
}
