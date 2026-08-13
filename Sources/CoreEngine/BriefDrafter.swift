import Foundation
import AgentKit
import LLMProviders
import Observability

// ─────────────────────────────────────────────────────────────
// Promotion: General → Project (ARCHITECTURE §19.1, P10.3).
//
// This is the flow that actually happens. Nobody opens a fresh app and fills in
// a project charter; they ask a question, the answer turns into three more
// questions, and somewhere in there it became work. So the way into a project
// is *from a conversation*, and the brief starts as a draft of what was already
// said rather than an empty form.
//
// The division of labour is the same one `GapDetector` uses, and for the same
// reason: the model reads prose, and nothing else is the model's.
//
//  • **What the transcript says** — the model's job, and only that.
//  • **What the transcript does not say is an open question, not a guess.**
//    A drafted scope statement that invents an out-of-scope list would sail
//    through G1 while meaning nothing, which is worse than an empty one that
//    stops there and asks.
//  • **Assembling the draft is deterministic**, so it can be tested exactly and
//    still produces something usable when the model cannot be reached.
// ─────────────────────────────────────────────────────────────

/// One turn, as the drafter needs it. Deliberately not `StoredMessage`:
/// CoreEngine does not link the database to read two strings.
public struct TranscriptTurn: Sendable, Equatable {
    public let fromUser: Bool
    public let text: String

    public init(fromUser: Bool, text: String) {
        self.fromUser = fromUser
        self.text = text
    }
}

/// What the model found in the transcript. Empty fields mean "not said" — they
/// never mean "none".
public struct BriefReading: Sendable, Equatable {
    public let name: String
    public let purpose: String
    public let inScope: [String]
    public let outOfScope: [String]

    public init(name: String = "", purpose: String = "",
                inScope: [String] = [], outOfScope: [String] = []) {
        self.name = name
        self.purpose = purpose
        self.inScope = inScope
        self.outOfScope = outOfScope
    }
}

/// What the user is shown before the project exists. Editable in full — every
/// field here is a proposal, including the ones the model was confident about.
public struct DraftedBrief: Sendable, Equatable, Identifiable {
    public let name: String
    public let brief: String
    public let statement: ScopeStatement
    /// What the conversation never settled, in the words the screen shows.
    /// Present rather than filled in: this is the list that keeps a draft from
    /// looking more decided than the conversation was.
    public let openQuestions: [String]

    /// A draft is identified by what it says, because that is all it is — a
    /// value shown in a sheet, replaced whole whenever it is redrafted.
    public var id: String { name + "|" + brief }

    public init(name: String, brief: String,
                statement: ScopeStatement, openQuestions: [String]) {
        self.name = name
        self.brief = brief
        self.statement = statement
        self.openQuestions = openQuestions
    }

    public var isReadyForG1: Bool {
        !name.isEmpty && !brief.isEmpty
            && !statement.inScope.isEmpty && !statement.outOfScope.isEmpty
    }
}

public enum BriefDraft {
    static let couldNotRead = "ร่างจากบทสนทนาไม่ได้ — โมเดลไม่ตอบ กรอกเองได้เลย"

    /// Pure: same transcript and same reading give the same draft, and a nil
    /// reading still gives something the user can work with.
    public static func assemble(reading: BriefReading?,
                                transcript: [TranscriptTurn]) -> DraftedBrief {
        let firstAsk = transcript.first(where: \.fromUser)?.text
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let name = pick(reading?.name, fallback: summarise(firstAsk))
        let purpose = clean(reading?.purpose ?? "")
        let inScope = list(reading?.inScope)
        let outOfScope = list(reading?.outOfScope)

        var questions: [String] = []
        if reading == nil { questions.append(couldNotRead) }
        if purpose.isEmpty { questions.append("ยังไม่ได้บอกว่าทำโครงการนี้ไปเพื่ออะไร") }
        if inScope.isEmpty { questions.append("ยังไม่ได้บอกว่าจะทำอะไรบ้าง") }
        // The one G1 refuses without, and the one a conversation almost never
        // produces on its own — people say what they want, not what they are
        // leaving out (§19.6).
        if outOfScope.isEmpty {
            questions.append("ยังไม่ได้บอกว่าจะ**ไม่**ทำอะไร — G1 ต้องการอย่างน้อย 1 ข้อ")
        }

        return DraftedBrief(
            name: name.isEmpty ? "โปรเจกต์ใหม่" : name,
            brief: purpose,
            statement: ScopeStatement(inScope: inScope, outOfScope: outOfScope),
            openQuestions: questions)
    }

    private static func pick(_ value: String?, fallback: String) -> String {
        let cleaned = clean(value ?? "")
        return cleaned.isEmpty ? fallback : cleaned
    }

    private static func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func list(_ values: [String]?) -> [String] {
        (values ?? []).map(clean).filter { !$0.isEmpty }
    }

    /// A name from the first thing the user asked. Cut at a sentence boundary
    /// where there is one, so the fallback reads like a title rather than the
    /// first 40 characters of a paragraph.
    ///
    /// Public because the conversation list names itself the same way (§19.2.1):
    /// a title cut mid-word is the same defect wherever it shows up, and it was
    /// already solved once here.
    public static func summarise(_ ask: String) -> String {
        guard !ask.isEmpty else { return "" }
        let firstLine = ask.split(separator: "\n").first.map(String.init) ?? ask
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 48 else { return trimmed }
        let cut = trimmed.prefix(48)
        // Prefer the last word boundary, so a Thai sentence is not cut in the
        // middle of a word by a character count that means nothing.
        if let space = cut.lastIndex(of: " "), space > cut.startIndex {
            return String(cut[cut.startIndex..<space])
        }
        return String(cut)
    }
}

public struct BriefDrafter: Sendable {
    private let router: ModelRouter
    private let log = AppLog.logger("brief")

    public init(router: ModelRouter) {
        self.router = router
    }

    private static let schema = #"""
    {"type":"object",
     "properties":{
       "name":{"type":"string"},
       "purpose":{"type":"string"},
       "in_scope":{"type":"array","items":{"type":"string"}},
       "out_of_scope":{"type":"array","items":{"type":"string"}}},
     "required":["name","purpose","in_scope","out_of_scope"]}
    """#

    /// Reads a conversation into a draft brief. Never returns nil: a model that
    /// cannot be reached produces a draft whose open questions say so, because
    /// the alternative is a promotion button that silently does nothing.
    public func draft(from transcript: [TranscriptTurn]) async -> DraftedBrief {
        BriefDraft.assemble(reading: await read(transcript), transcript: transcript)
    }

    private func read(_ transcript: [TranscriptTurn]) async -> BriefReading? {
        let text = transcript
            .map { "\($0.fromUser ? "ผู้ใช้" : "ผู้ช่วย"): \($0.text)" }
            .joined(separator: "\n\n")
        guard text.count > 40 else { return nil }

        var request = LLMRequest(messages: [
            .init(.system, """
            อ่านบทสนทนาแล้วร่างหัวข้อโครงการจาก **สิ่งที่คุยกันไว้จริง** เท่านั้น
            - name: ชื่อสั้น ๆ ที่บอกว่างานนี้คืออะไร
            - purpose: ทำไปเพื่ออะไร ตามที่บทสนทนาบอก
            - in_scope: สิ่งที่ตกลงกันว่าจะทำ
            - out_of_scope: สิ่งที่พูดไว้ชัดว่า **จะไม่ทำ** หรือ **อยู่นอกเรื่อง**
            ถ้าบทสนทนาไม่ได้บอกช่องไหน ให้เว้นว่างหรือส่งลิสต์ว่าง **ห้ามเดาแทน**
            โดยเฉพาะ out_of_scope — การเดาขอบเขตที่ไม่ทำ ทำให้ประตูตรวจผ่านไปโดยไม่มีความหมาย
            ตอบเป็นภาษาเดียวกับบทสนทนา
            """),
            .init(.user, String(text.suffix(12_000))),
        ])
        request.responseSchema = (name: "Brief", schemaJSON: Self.schema)
        request.maxTokens = 1_024
        request.temperature = 0

        do {
            let completion = try await router.complete(request)
            guard let data = completion.structuredText.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                log.error("brief draft returned unparseable output")
                return nil
            }
            return BriefReading(
                name: (root["name"] as? String) ?? "",
                purpose: (root["purpose"] as? String) ?? "",
                inScope: (root["in_scope"] as? [String]) ?? [],
                outOfScope: (root["out_of_scope"] as? [String]) ?? [])
        } catch {
            log.error("brief draft unavailable: \(error)")
            return nil
        }
    }
}
