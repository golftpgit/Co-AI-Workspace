import Foundation
import AgentKit
import LLMProviders
import Observability

// ─────────────────────────────────────────────────────────────
// Gap Detection (ARCHITECTURE §12.4, P6.7).
//
// When the work is attached to a proposal, the Clarify stage stops being a
// conversation and becomes an audit: read what the proposal actually commits
// to, compare it against the columns that actually exist, and put every
// difference in front of a person before any query runs.
//
// The division of labour here is deliberate:
//
//  • **The model reads prose.** Pulling "population", "exposure", "outcome"
//    out of a paragraph of Thai academic writing is what a model is for.
//  • **Nothing else is the model's.** Which fields exist, whether a name is
//    ambiguous, what blocks approval — all of that is comparison and counting,
//    done here, deterministically, and testable without a model at all.
//  • **A value the proposal does not contain is the agent's, not the
//    proposal's.** Same rule as `RelationExtractor` (§11.4): if the words are
//    not in the text, the claim is not from the text. That is what keeps the
//    `proposal_stated` tag from becoming a rubber stamp.
// ─────────────────────────────────────────────────────────────

/// The columns that actually exist, as a plain value.
///
/// Not `Analysis`'s schema type: CoreEngine must not link a database engine to
/// compare two lists of names, and the caller already has the schema in hand.
public struct SchemaSnapshot: Sendable, Equatable {
    public struct Field: Sendable, Equatable, Hashable {
        public let table: String
        public let name: String
        public let type: String

        public init(table: String, name: String, type: String = "") {
            self.table = table
            self.name = name
            self.type = type
        }

        public var qualified: String { "\(table).\(name)" }
    }

    public let fields: [Field]

    public init(fields: [Field]) { self.fields = fields }

    public var isEmpty: Bool { fields.isEmpty }

    /// Columns whose name is the requested one, ignoring case, spaces and
    /// underscores — `HbA1c`, `hba1c` and `hb_a1c` are the same column with
    /// three spellings, and treating them as three fields would report a gap
    /// that is not there.
    public func exactMatches(_ requested: String) -> [Field] {
        let wanted = Self.normalise(requested)
        return fields.filter { Self.normalise($0.name) == wanted
            || Self.normalise($0.qualified) == wanted }
    }

    /// Columns that merely look related. A single one of these is still a
    /// guess, which is why it produces an ambiguous gap rather than a match.
    public func looseMatches(_ requested: String) -> [Field] {
        let wanted = Self.normalise(requested)
        guard wanted.count >= 3 else { return [] }
        return fields.filter {
            let name = Self.normalise($0.name)
            return name.contains(wanted) || wanted.contains(name)
        }
    }

    static func normalise(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
    }
}

/// What §12.4 step 1 asks to be pulled out of the proposal.
public struct ProposalReading: Sendable, Codable, Equatable {
    public var researchQuestion = ""
    public var hypothesis = ""
    public var population = ""
    public var exposure = ""
    public var outcome = ""
    public var plannedMethod = ""
    public var timeframe = ""
    /// The variables the proposal says it needs, as it names them.
    public var requiredFields: [String] = []

    public init() {}

    public init(researchQuestion: String = "", hypothesis: String = "", population: String = "",
                exposure: String = "", outcome: String = "", plannedMethod: String = "",
                timeframe: String = "", requiredFields: [String] = []) {
        self.researchQuestion = researchQuestion
        self.hypothesis = hypothesis
        self.population = population
        self.exposure = exposure
        self.outcome = outcome
        self.plannedMethod = plannedMethod
        self.timeframe = timeframe
        self.requiredFields = requiredFields
    }
}

public struct GapDetector: Sendable {
    private let router: ModelRouter
    private let log = AppLog.logger("gaps")

    public init(router: ModelRouter) {
        self.router = router
    }

    private static let schema = #"""
    {"type":"object",
     "properties":{
       "research_question":{"type":"string"},
       "hypothesis":{"type":"string"},
       "population":{"type":"string"},
       "exposure":{"type":"string"},
       "outcome":{"type":"string"},
       "planned_method":{"type":"string"},
       "timeframe":{"type":"string"},
       "required_fields":{"type":"array","items":{"type":"string"}}},
     "required":["research_question","population","outcome","required_fields"]}
    """#

    /// Reads a proposal.
    ///
    /// Returns nil when the model could not be reached — not an empty reading.
    /// An empty reading would be indistinguishable from a proposal that says
    /// nothing, and this project has paid for that confusion once already
    /// (a model that could not answer read as "the two sources agree", U13).
    public func read(proposal text: String) async -> ProposalReading? {
        guard text.count > 40 else { return nil }

        var request = LLMRequest(messages: [
            .init(.system, """
            อ่านโครงร่างวิจัยแล้วสกัดสิ่งที่ **เอกสารระบุไว้จริง** เท่านั้น
            - ถ้าเอกสารไม่ได้ระบุช่องไหน ให้เว้นเป็นสตริงว่าง ห้ามเดาแทน
            - required_fields คือชื่อตัวแปร/ข้อมูลที่ต้องใช้ ตามที่เอกสารเรียก
            - ตอบเป็นภาษาเดียวกับเอกสาร
            """),
            .init(.user, String(text.prefix(12_000))),
        ])
        request.responseSchema = (name: "Proposal", schemaJSON: Self.schema)
        request.maxTokens = 2_048
        request.temperature = 0

        do {
            let completion = try await router.complete(request)
            guard let data = completion.structuredText.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                log.error("proposal parse returned unparseable output")
                return nil
            }
            func value(_ key: String) -> String {
                (root[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            return ProposalReading(
                researchQuestion: value("research_question"),
                hypothesis: value("hypothesis"),
                population: value("population"),
                exposure: value("exposure"),
                outcome: value("outcome"),
                plannedMethod: value("planned_method"),
                timeframe: value("timeframe"),
                requiredFields: (root["required_fields"] as? [String] ?? [])
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty })
        } catch {
            log.error("proposal parse unavailable: \(error)")
            return nil
        }
    }

    // MARK: - the deterministic half

    /// The narrative slots §12.4 step 1 lists, paired with the question each
    /// one answers in the plan.
    private static func slots(of reading: ProposalReading) -> [(question: String, value: String)] {
        [("คำถามวิจัย", reading.researchQuestion),
         ("สมมติฐาน", reading.hypothesis),
         ("ประชากรที่ศึกษา", reading.population),
         ("ปัจจัยที่ศึกษา (exposure)", reading.exposure),
         ("ผลลัพธ์ที่วัด (outcome)", reading.outcome),
         ("วิธีทางสถิติ", reading.plannedMethod),
         ("ช่วงเวลาที่ศึกษา", reading.timeframe)]
    }

    /// Builds the plan and its Gap Report.
    ///
    /// Pure: same reading, same schema, same plan. The model's output is an
    /// input here, not an authority — everything about what blocks approval is
    /// decided by the comparison below.
    public static func plan(title: String,
                            scope: Scope = .central,
                            reading: ProposalReading,
                            proposalText: String,
                            proposalDocumentID: String? = nil,
                            schema: SchemaSnapshot) -> AnalysisPlan {
        var plan = AnalysisPlan(title: title, scope: scope,
                                proposalDocumentID: proposalDocumentID)
        let haystack = proposalText.lowercased()

        for slot in slots(of: reading) {
            let value = slot.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                // §12.4 level 3: the proposal does not make this choice, so
                // somebody has to. The placeholder decision is what makes the
                // gap block approval — an unanswered method is not a detail.
                plan.add(AnalysisGap(severity: .assumptionNeeded,
                                     subject: slot.question,
                                     detail: "โครงร่างไม่ได้ระบุ \(slot.question) — ต้องเลือกก่อนเริ่ม"))
                plan.add(AnalysisDecision(question: slot.question,
                                          value: "ยังไม่ได้เลือก",
                                          origin: .agentSuggested,
                                          note: "โครงร่างไม่ได้ระบุไว้"))
            } else if haystack.contains(value.lowercased()) {
                plan.add(AnalysisDecision(question: slot.question, value: value,
                                          origin: .proposalStated))
            } else {
                // The model produced words the proposal does not contain. It
                // may well be a good paraphrase; it is still the agent's, and
                // it is tagged as such until a person says otherwise.
                plan.add(AnalysisDecision(question: slot.question, value: value,
                                          origin: .agentSuggested,
                                          note: "สรุปโดย agent — ไม่ใช่ข้อความที่ปรากฏในโครงร่าง"))
            }
        }

        for field in reading.requiredFields {
            let exact = schema.exactMatches(field)
            if exact.count == 1 {
                plan.add(AnalysisDecision(question: "ตัวแปร “\(field)”",
                                          value: exact[0].qualified,
                                          origin: .proposalStated,
                                          note: "ตรงกับคอลัมน์ \(exact[0].qualified) ชนิด \(exact[0].type)"))
            } else if exact.count > 1 {
                plan.add(AnalysisGap(
                    severity: .ambiguous,
                    subject: "ตัวแปร “\(field)”",
                    detail: "มีคอลัมน์ชื่อนี้อยู่ \(exact.count) ที่ ต้องเลือกว่าจะใช้อันไหน",
                    options: exact.map(\.qualified)))
            } else {
                let loose = schema.looseMatches(field)
                if loose.isEmpty {
                    // §12.4 level 1: a hard block. No column, no analysis.
                    plan.add(AnalysisGap(
                        severity: .critical,
                        subject: "ตัวแปร “\(field)”",
                        detail: schema.isEmpty
                            ? "ยังไม่ได้ต่อฐานข้อมูล จึงยังตรวจไม่ได้ว่ามีตัวแปรนี้หรือไม่"
                            : "ไม่พบคอลัมน์ที่ตรงกับ “\(field)” ในสคีมาที่ต่ออยู่"))
                } else {
                    plan.add(AnalysisGap(
                        severity: .ambiguous,
                        subject: "ตัวแปร “\(field)”",
                        detail: "ไม่มีคอลัมน์ชื่อตรงกัน มีแต่ชื่อใกล้เคียง — ต้องยืนยันว่าหมายถึงอันไหน",
                        options: loose.map(\.qualified)))
                }
            }
        }
        return plan
    }
}
