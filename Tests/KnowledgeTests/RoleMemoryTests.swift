import Testing
import Foundation
import AgentKit
@testable import Knowledge

// ─────────────────────────────────────────────────────────────
// P12.7 — what a role already learned, arriving rather than being findable.
//
// `LessonPublisher` already puts a closed project's lessons into `central`, so
// they can be searched for. The gap this closes is that a lesson somebody has
// to think to search for reaches the people who already knew it.
//
// The two rules worth testing are the ones that fail quietly. An unlabelled
// lesson excluded from everybody teaches nobody — which is the failure
// `LessonPublisher`'s own header names, moved one step later. And a lesson
// addressed to somebody else, shown to everybody, buries the ones that matter.
// ─────────────────────────────────────────────────────────────

private func lesson(_ title: String, appliesTo: String, project: String = "โครงการ ก",
                    at: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> IndexedChunk {
    let text = """
        บทเรียนจากโปรเจกต์ “\(project)”: \(title)
        สาเหตุ: อะไรสักอย่าง
        ครั้งหน้าจะทำต่างไป: ทำอีกแบบ
        ใช้กับ: \(appliesTo)
        """
    return IndexedChunk(
        id: "les_\(UUID().uuidString)", text: text, scope: .central,
        provenance: .authored(documentID: "lessons/\(project)",
                              title: "บทเรียน — \(project)",
                              runID: "r_\(UUID().uuidString)", accessedAt: at),
        embedding: nil, embeddingProfileID: nil, contentHash: UUID().uuidString)
}

private func ordinaryDocument(_ text: String) -> IndexedChunk {
    IndexedChunk(id: "doc_\(UUID().uuidString)", text: text, scope: .central,
                 provenance: Provenance(documentID: "doc_1", title: "เอกสารทั่วไป",
                                        origin: .upload(filename: "a.pdf"), tier: .t3),
                 embedding: nil, embeddingProfileID: nil, contentHash: UUID().uuidString)
}

@Suite("Role memory — P12.7")
struct RoleMemoryTests {

    // The rule that decides whether most lessons reach anybody at all.
    @Test("a lesson that names no role reaches every role")
    func unlabelledReachesEveryone() {
        let chunks = [lesson("อย่าเริ่มเก็บข้อมูลก่อนได้จริยธรรม", appliesTo: "ทุกโครงการ")]
        for role in Role.allCases {
            #expect(RoleMemory.lessons(for: role, in: chunks).count == 1,
                    "\(role) never saw an unlabelled lesson")
        }
    }

    // Without this, every role starts every assignment reading everybody
    // else's lessons.
    @Test("a lesson addressed to another role is not shown")
    func addressedElsewhereIsExcluded() {
        let chunks = [lesson("ตรวจ assumption ก่อนรัน", appliesTo: "นักวิเคราะห์")]
        #expect(RoleMemory.lessons(for: .analyst, in: chunks).count == 1)
        #expect(RoleMemory.lessons(for: .writer, in: chunks).isEmpty)
    }

    @Test("a lesson addressed to this role is marked as such, and comes first")
    func addressedToThisRoleRanksFirst() {
        let chunks = [
            lesson("บทเรียนทั่วไปที่ใหม่กว่า", appliesTo: "ทุกคน",
                   at: Date(timeIntervalSince1970: 1_800_000_000)),
            lesson("บทเรียนของคนเขียนที่เก่ากว่า", appliesTo: "ผู้เขียน",
                   at: Date(timeIntervalSince1970: 1_600_000_000)),
        ]
        let found = RoleMemory.lessons(for: .writer, in: chunks)
        #expect(found.count == 2)
        #expect(found[0].namesThisRole, "a lesson written for this role was ranked below a general one")
        #expect(found[0].text.contains("ของคนเขียน"))
    }

    @Test("among equals, the most recent comes first")
    func recencyBreaksTies() {
        let chunks = [
            lesson("เก่ากว่า", appliesTo: "ทุกคน", at: Date(timeIntervalSince1970: 1_600_000_000)),
            lesson("ใหม่กว่า", appliesTo: "ทุกคน", at: Date(timeIntervalSince1970: 1_800_000_000)),
        ]
        #expect(RoleMemory.lessons(for: .engineer, in: chunks)[0].text.contains("ใหม่กว่า"))
    }

    // Matching on provenance, not on the word "บทเรียน": an uploaded document
    // that happens to discuss lessons is not a lesson this system published.
    @Test("an ordinary document is not mistaken for a lesson")
    func onlyPublishedLessonsCount() {
        let chunks = [ordinaryDocument("บทเรียนจากงานวิจัยที่ผ่านมา ใช้กับ: นักวิจัย")]
        #expect(RoleMemory.lessons(for: .researcher, in: chunks).isEmpty)
    }

    // Only the "ใช้กับ:" line addresses anybody. A lesson whose *cause*
    // mentions the analyst is not addressed to the analyst.
    @Test("a role mentioned in the cause does not make the lesson theirs")
    func onlyTheAppliesLineAddresses() {
        let chunk = IndexedChunk(
            id: "les_1",
            text: """
                บทเรียนจากโปรเจกต์ “ก”: ตัวเลขไม่ตรง
                สาเหตุ: นักวิเคราะห์ใช้นิยามตัวแปรคนละรุ่น
                ครั้งหน้าจะทำต่างไป: ล็อก codebook ก่อน
                ใช้กับ: ผู้เขียน
                """,
            scope: .central,
            provenance: .authored(documentID: "lessons/ก", title: "บทเรียน — ก", runID: "r"),
            embedding: nil, embeddingProfileID: nil, contentHash: "h")
        #expect(RoleMemory.lessons(for: .writer, in: [chunk]).count == 1)
        #expect(RoleMemory.lessons(for: .analyst, in: [chunk]).isEmpty)
    }

    // A brief that shows five of twelve without saying so reads as "there were
    // five" — the silent-truncation rule this project applies everywhere else.
    @Test("a brief that had to cut some says how many it cut")
    func truncationIsSaidOutLoud() {
        let chunks = (1...8).map { lesson("บทเรียนที่ \($0)", appliesTo: "ทุกคน") }
        let brief = RoleMemory.brief(for: .engineer, in: chunks, limit: 3)
        #expect(brief.count == 4)
        #expect(brief.last?.contains("5 more relevant lessons") == true)
    }

    @Test("no lessons means no lines, not a line saying there are none")
    func silentWhenEmpty() {
        #expect(RoleMemory.brief(for: .writer, in: []).isEmpty)
    }

    // Nobody types `teamLead` into a lessons-learned field.
    @Test("the vocabulary is what a person would actually write")
    func vocabularyIsHumanWords() {
        let chunks = [lesson("อย่ารับงานที่ยังไม่มีเกณฑ์ตรวจ", appliesTo: "หัวหน้าทีม")]
        #expect(RoleMemory.lessons(for: .teamLead, in: chunks).count == 1)
        #expect(RoleMemory.lessons(for: .engineer, in: chunks).isEmpty)
    }
}
