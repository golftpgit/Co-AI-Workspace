import Testing
import Foundation
import AgentKit
@testable import Knowledge

// ─────────────────────────────────────────────────────────────
// P21.4 — what a closed project leaves to the next one, and what it must not.
//
// The interesting tests here are the refusals. Moving a paper up is a
// convenience; keeping a transcript down is a promise made to the people in it,
// and the difference between the two is not visible in the data — both are text
// in the same index with the same shape. `Origin` is what makes it decidable,
// which is why it has no `other` case and why this rule has no default arm.
// ─────────────────────────────────────────────────────────────

private let projectScope = Scope.project(ProjectID("p-nurse-burnout"))

private func chunk(_ id: String, _ text: String, provenance: Provenance) -> IndexedChunk {
    IndexedChunk(id: id, text: text, scope: projectScope, provenance: provenance)
}

private let paper = chunk(
    "c1", "Sleep deprivation among shift nurses is associated with medication error",
    provenance: Provenance(documentID: "doc-1", title: "Shift work and error rates",
                           origin: .web(url: URL(string: "https://example.org/paper")!),
                           tier: .t2))

private let uploadedGuideline = chunk(
    "c2", "แนวทางเวชปฏิบัติสำหรับการจัดตารางเวรพยาบาล",
    provenance: Provenance(documentID: "doc-2", title: "แนวทางกระทรวง",
                           origin: .upload(filename: "guideline.pdf"), tier: .t1))

private let transcript = chunk(
    "c3", "พยาบาล ก เล่าว่าเวรดึกติดกันสามคืนทำให้จำคำสั่งแพทย์ผิด",
    provenance: .fieldwork(documentID: "int-07", title: "บทสัมภาษณ์ 07",
                           participantCode: "P07",
                           collectedAt: Date(timeIntervalSince1970: 1_770_000_000)))

private let draft = chunk(
    "c4", "สมมติฐานที่ยังไม่ได้ทดสอบ: ภาระงานสัมพันธ์กับความผิดพลาด",
    provenance: .authored(documentID: "note-3", title: "บันทึกระหว่างทาง", runID: "run-9"))

private let pulledTable = chunk(
    "c5", "ตารางเวรและรหัสพนักงาน 1,204 แถว",
    provenance: Provenance(documentID: "tbl-1", title: "ตารางเวร",
                           origin: .database(name: "hr"), tier: .t3))

@Suite("What a closed project hands over")
struct ClosingHandoverTests {

    /// The ethical rule, and the reason this task is not about storage: the
    /// people in a transcript agreed to one study.
    @Test("participants' words never leave the project they were given to")
    func fieldworkNeverMovesUp() {
        let verdict = ClosingHandoverPolicy.verdict(for: transcript)
        #expect(verdict.isMovingUp == false)
        if case .stays(let reason) = verdict {
            #expect(reason.contains("participant data"))
        }
        // …and it is not in the promoted set either, which is the version of
        // this fact that a caller can get wrong.
        let promoted = ClosingHandoverPolicy.promoted(
            [paper, uploadedGuideline, transcript, draft, pulledTable])
        #expect(promoted.contains { $0.id == transcript.id } == false,
                "a participant's interview followed the project into the shared library")
    }

    @Test("a pulled database table stays, because nothing here can tell what is in it")
    func databaseExtractsStay() {
        // Refusing is the answer that is wrong in the recoverable direction: a
        // table nobody can read centrally is an inconvenience, a patient
        // extract published to every future project is not.
        #expect(ClosingHandoverPolicy.verdict(for: pulledTable).isMovingUp == false)
    }

    @Test("working notes stay; a lesson is a decision somebody made, not a kind of text")
    func draftsStay() {
        #expect(ClosingHandoverPolicy.verdict(for: draft).isMovingUp == false)
    }

    @Test("external references move up, and keep the tier they were ranked by")
    func referencesMoveUp() {
        let promoted = ClosingHandoverPolicy.promoted([paper, uploadedGuideline, transcript, draft])
        #expect(promoted.map(\.id).sorted() == ["c1", "c2"])
        #expect(promoted.allSatisfy { $0.scope == .central })
        // The tier travels with the document: arriving centrally without it
        // would mean being re-ranked as if nobody had ever assessed it.
        #expect(promoted.first { $0.id == "c1" }?.provenance.tier == .t2)
        #expect(promoted.first { $0.id == "c2" }?.provenance.tier == .t1)
    }

    /// Unbuildable through the initialisers — `Provenance` refuses an external
    /// source with no tier — but reachable by decoding a row written before
    /// that rule existed, which is the only way it can turn up in a real
    /// library. Kept because the guard in the policy is otherwise a claim
    /// nobody has checked.
    @Test("a stored row whose tier is missing stays rather than arriving unranked")
    func untieredReferenceStays() throws {
        let json = #"""
        {"documentID":"doc-9","title":"บล็อกเก่า",
         "origin":{"web":{"url":"https://x.example"}},
         "authors":[],"accessedAt":760000000}
        """#
        guard let provenance = try? JSONDecoder().decode(Provenance.self,
                                                         from: Data(json.utf8)) else {
            // The decoder refusing is also an acceptable answer to this
            // question: it means the row cannot exist at all.
            return
        }
        #expect(provenance.tier == nil)
        #expect(ClosingHandoverPolicy.verdict(for: chunk("c6", "หน้าเว็บ", provenance: provenance))
                    .isMovingUp == false)
    }

    @Test("closing twice hands over the same rows, not two copies of them")
    func handoverIsIdempotent() {
        // The ids are the project's own, so the store upserts. A library that
        // grows a copy of every paper each time a project closes is a library
        // whose search results are duplicates.
        let once = ClosingHandoverPolicy.promoted([paper, uploadedGuideline])
        let twice = ClosingHandoverPolicy.promoted([paper, uploadedGuideline])
        #expect(once.map(\.id) == twice.map(\.id))
        #expect(Set(once.map(\.id)).count == once.count)
    }

    // ─────────────────────────────────────────────────────────

    @Test("a decision declared central becomes a precedent; one kept local does not")
    func onlyDeclaredPrecedentsTravel() {
        let central = ConflictDecision(resolution: .preferA(reason: "หลักฐานระดับสูงกว่า"),
                                       scope: .central, decidedByHuman: true)
        let local = ConflictDecision(resolution: .preferA(reason: "ตามนิยามผลลัพธ์ของงานนี้"),
                                     scope: projectScope, decidedByHuman: true)
        #expect(ClosingHandoverPolicy.isCentralPrecedent(central))
        // "For this study, given how we defined the outcome" is not a rule for
        // the next study, and promoting it would put words in somebody's mouth.
        #expect(ClosingHandoverPolicy.isCentralPrecedent(local) == false)
    }

    @Test("a decision the system made for itself is not a precedent for everybody")
    func machineDecisionsAreNotPrecedent() {
        let automatic = ConflictDecision(resolution: .preferA(reason: "คะแนนน้ำหนักต่างกันมาก"),
                                         scope: .central, decidedByHuman: false)
        #expect(ClosingHandoverPolicy.isCentralPrecedent(automatic) == false)
    }
}
