import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// Conformance and tailoring (ARCHITECTURE §19.15–§19.16, P10.13).
//
// ISO 21502 clause 7 lists seventeen management practices. The honest thing to
// do with that list is not to claim all seventeen — most projects genuinely do
// not procure anything — but to be unable to *skip one silently*. So each
// practice has exactly two acceptable states:
//
//   • there is a real thing in this project that does it, or
//   • somebody wrote down that it was left out, and why.
//
// A third state — nothing there and nobody said — is what a conformance claim
// usually means in practice, and it is the state this file makes impossible to
// carry through the closing gate (§19.12 condition 6).
//
// The mapping from practice to evidence is one exhaustive `switch`. That is the
// point of `Practice` being an enum rather than a list of strings: adding an
// eighteenth practice does not compile until somebody says what would count as
// doing it. `check.sh` guards the other half — that every case is named here,
// so a case cannot be answered by a `default:` that quietly passes.
// ─────────────────────────────────────────────────────────────

/// The seventeen practices of ISO 21502:2020 clause 7, in the standard's order.
public enum Practice: String, Sendable, Codable, CaseIterable {
    case planning
    case benefits
    case scope
    case resource
    case schedule
    case cost
    case risk
    case issue
    case changeControl
    case quality
    case stakeholder
    case communication
    case orgChange
    case reporting
    case information
    case procurement
    case lessons

    public var label: String {
        switch self {
        case .planning: "การวางแผน"
        case .benefits: "ประโยชน์ที่จะได้"
        case .scope: "ขอบเขต"
        case .resource: "ทรัพยากรและคน"
        case .schedule: "กำหนดเวลา"
        case .cost: "ค่าใช้จ่าย"
        case .risk: "ความเสี่ยง"
        case .issue: "ปัญหา"
        case .changeControl: "การควบคุมการเปลี่ยนแปลง"
        case .quality: "คุณภาพ"
        case .stakeholder: "ผู้มีส่วนได้เสีย"
        case .communication: "การสื่อสาร"
        case .orgChange: "การเปลี่ยนแปลงองค์กร"
        case .reporting: "การรายงาน"
        case .information: "ข้อมูลและเอกสาร"
        case .procurement: "การจัดซื้อจัดหา"
        case .lessons: "บทเรียน"
        }
    }
}

/// Somebody deciding a practice does not apply, on the record (§19.15).
///
/// `decidedBy` is a person's name and there is no argument here that a `Role`
/// fits — the same shape as `RegisterEntry.decided(approve:by:)` and the
/// Executive seat, for the same reason: tailoring away a practice is a
/// governance decision, and a system that lets an agent make it has removed the
/// only thing that made the record worth anything.
public struct TailoringRecord: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let projectID: ProjectID
    public let practice: Practice
    public var reason: String
    public let decidedBy: String
    public let decidedAt: Date

    private init(id: String, projectID: ProjectID, practice: Practice,
                 reason: String, decidedBy: String, decidedAt: Date) {
        self.id = id
        self.projectID = projectID
        self.practice = practice
        self.reason = reason
        self.decidedBy = decidedBy
        self.decidedAt = decidedAt
    }

    /// The only way one is made. Refuses an empty reason as well as an empty
    /// name: "ไม่เกี่ยว" with nobody attached is the box-ticking the record was
    /// supposed to replace.
    public static func decided(projectID: ProjectID,
                               practice: Practice,
                               reason: String,
                               by person: String,
                               id: String = OpaqueID.make(OpaqueID.tailoring),
                               at date: Date = Date()) throws -> TailoringRecord {
        let name = person.trimmingCharacters(in: .whitespacesAndNewlines)
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw TailoringError.emptyDecider }
        guard !why.isEmpty else { throw TailoringError.emptyReason }
        return TailoringRecord(id: id, projectID: projectID, practice: practice,
                               reason: why, decidedBy: name, decidedAt: date)
    }
}

public enum TailoringError: Error, CustomStringConvertible, Equatable {
    case emptyDecider
    case emptyReason

    public var description: String {
        switch self {
        case .emptyDecider: "ต้องระบุชื่อคนที่ตัดสินว่าจะไม่ทำ practice นี้"
        case .emptyReason: "ต้องบอกเหตุผลที่ไม่ทำ — 'ไม่เกี่ยว' เฉย ๆ ไม่ใช่บันทึก"
        }
    }
}

/// What the project actually has, counted from the stores that already hold it.
///
/// Every field is a count or a flag rather than an object, because the switch
/// below has no business knowing what a risk register row looks like — and
/// because that makes the whole conformance answer testable without a database.
///
/// The defaults are all "nothing", which is the honest starting point: a fact
/// that was not gathered must not arrive here as evidence.
public struct ConformanceFacts: Sendable, Equatable {
    public var leafCount: Int
    public var benefitCount: Int
    public var inScopeCount: Int
    public var outOfScopeCount: Int
    /// Leaves that somebody or something is down to do — a role, or an R in the
    /// RACI. Resource management, at the only granularity this system has.
    public var staffedLeaves: Int
    public var dependencyCount: Int
    /// Seconds actually recorded against this project's leaves (§19.7). Time
    /// management is dependencies *or* actuals — a one-package project has
    /// nothing to sequence but is still being timed.
    public var measuredSeconds: TimeInterval
    public var spent: Double
    public var riskCount: Int
    public var issueCount: Int
    public var changeCount: Int
    public var decisionCount: Int
    public var lessonCount: Int
    public var baselineVersions: Int
    /// Accepted evidence across the plan — what QA actually looked at.
    public var evidenceCount: Int
    public var boardSeats: Int
    /// Things that were genuinely sent to a person: exception reports go out on
    /// every channel, and each one is a communication that happened.
    public var messagesSent: Int
    public var reportsIssued: Int
    public var dataDispositionDecided: Bool
    /// The two practices this system cannot observe on its own. Flags rather
    /// than guesses: a project that bought something says so, and one that did
    /// not writes a tailoring record — which is exactly what ISO tailoring is.
    public var procurementRecorded: Bool
    public var orgChangeRecorded: Bool

    public init(leafCount: Int = 0,
                benefitCount: Int = 0,
                inScopeCount: Int = 0,
                outOfScopeCount: Int = 0,
                staffedLeaves: Int = 0,
                dependencyCount: Int = 0,
                measuredSeconds: TimeInterval = 0,
                spent: Double = 0,
                riskCount: Int = 0,
                issueCount: Int = 0,
                changeCount: Int = 0,
                decisionCount: Int = 0,
                lessonCount: Int = 0,
                baselineVersions: Int = 0,
                evidenceCount: Int = 0,
                boardSeats: Int = 0,
                messagesSent: Int = 0,
                reportsIssued: Int = 0,
                dataDispositionDecided: Bool = false,
                procurementRecorded: Bool = false,
                orgChangeRecorded: Bool = false) {
        self.leafCount = leafCount
        self.benefitCount = benefitCount
        self.inScopeCount = inScopeCount
        self.outOfScopeCount = outOfScopeCount
        self.staffedLeaves = staffedLeaves
        self.dependencyCount = dependencyCount
        self.measuredSeconds = measuredSeconds
        self.spent = spent
        self.riskCount = riskCount
        self.issueCount = issueCount
        self.changeCount = changeCount
        self.decisionCount = decisionCount
        self.lessonCount = lessonCount
        self.baselineVersions = baselineVersions
        self.evidenceCount = evidenceCount
        self.boardSeats = boardSeats
        self.messagesSent = messagesSent
        self.reportsIssued = reportsIssued
        self.dataDispositionDecided = dataDispositionDecided
        self.procurementRecorded = procurementRecorded
        self.orgChangeRecorded = orgChangeRecorded
    }
}

/// The parts of the conformance answer only the running app can see.
///
/// `ProjectService` owns the plan, the registers and the baselines, so it counts
/// those itself. Money, elapsed time and messages sent live in the spend ledger,
/// the span store and the channels — the app reads those anyway for the status
/// strip (§19.2.3), and hands them over rather than making ProjectKit import
/// three more modules.
public struct ObservedFacts: Sendable, Equatable {
    /// The tolerance readings as the status strip computed them (§19.10), passed
    /// whole rather than field by field so a report and the strip cannot show
    /// two different numbers for the same day.
    public var readings: ToleranceReadings
    /// Which of the six are real measurements. Everything outside this set
    /// prints as "ยังไม่ได้วัด" in a report, which matters more there than on
    /// screen — a report gets quoted.
    public var measured: Set<ToleranceDimension>
    public var measuredSeconds: TimeInterval
    public var messagesSent: Int

    public init(readings: ToleranceReadings = ToleranceReadings(),
                measured: Set<ToleranceDimension> = [],
                measuredSeconds: TimeInterval = 0,
                messagesSent: Int = 0) {
        self.readings = readings
        self.measured = measured
        self.measuredSeconds = measuredSeconds
        self.messagesSent = messagesSent
    }

    /// What the cost practice counts, and what a report prints as spend.
    public var spent: Double { measured.contains(.cost) ? readings.spent : 0 }
}

/// One practice, and which of the two acceptable states it is in.
public struct PracticeStatus: Sendable, Equatable, Identifiable {
    public let practice: Practice
    /// What the project has that does this practice, in words a reader can
    /// check. `nil` means nothing was found — not "probably fine".
    public let evidence: String?
    public let tailoring: TailoringRecord?

    public var id: String { practice.rawValue }
    public var satisfied: Bool { evidence != nil || tailoring != nil }
    /// Satisfied by a decision not to do it, rather than by doing it. Worth
    /// distinguishing on screen: seventeen green ticks where sixteen are
    /// tailoring records is a conformance claim nobody should read as strong.
    public var isTailored: Bool { evidence == nil && tailoring != nil }
}

public enum Conformance {

    /// What in this project does this practice — or `nil` if nothing does.
    ///
    /// Exhaustive by construction. There is no `default:` here and there must
    /// never be one: the whole value of the enum is that a new practice fails
    /// to compile until this function has an answer for it.
    public static func evidence(for practice: Practice,
                                in facts: ConformanceFacts) -> String? {
        switch practice {
        case .planning:
            facts.leafCount > 0 ? "แผนงานมี \(facts.leafCount) ใบงาน" : nil
        case .benefits:
            facts.benefitCount > 0 ? "ทะเบียนประโยชน์ \(facts.benefitCount) รายการ" : nil
        case .scope:
            facts.inScopeCount > 0 && facts.outOfScopeCount > 0
                ? "ขอบเขต: ทำ \(facts.inScopeCount) ข้อ · ไม่ทำ \(facts.outOfScopeCount) ข้อ"
                : nil
        case .resource:
            facts.staffedLeaves > 0 ? "ใบงานที่มีคนหรือ agent รับไป \(facts.staffedLeaves) ใบ" : nil
        case .schedule:
            if facts.dependencyCount > 0 {
                "เส้นพึ่งพา \(facts.dependencyCount) เส้น"
            } else if facts.measuredSeconds > 0 {
                "เวลาที่วัดได้ \(Int(facts.measuredSeconds / 60)) นาที"
            } else {
                nil
            }
        case .cost:
            facts.spent > 0 ? String(format: "ค่าใช้จ่ายที่บันทึกไว้ ฿%.2f", facts.spent) : nil
        case .risk:
            facts.riskCount > 0 ? "ทะเบียนความเสี่ยง \(facts.riskCount) รายการ" : nil
        case .issue:
            facts.issueCount > 0 ? "ทะเบียนปัญหา \(facts.issueCount) รายการ" : nil
        case .changeControl:
            // A baseline is what makes change control exist: without a frozen
            // agreement there is nothing for a change request to change.
            facts.baselineVersions > 0
                ? "baseline \(facts.baselineVersions) เวอร์ชัน · คำขอเปลี่ยนแปลง \(facts.changeCount) รายการ"
                : nil
        case .quality:
            facts.evidenceCount > 0 ? "หลักฐานที่ QA รับแล้ว \(facts.evidenceCount) ชิ้น" : nil
        case .stakeholder:
            facts.boardSeats > 0 ? "ที่นั่งกำกับที่มีชื่อคน \(facts.boardSeats) ที่" : nil
        case .communication:
            facts.messagesSent > 0 ? "ข้อความที่ส่งถึงคนแล้ว \(facts.messagesSent) ครั้ง" : nil
        case .orgChange:
            facts.orgChangeRecorded ? "บันทึกผลกระทบต่อวิธีทำงานไว้แล้ว" : nil
        case .reporting:
            facts.reportsIssued > 0 ? "รายงานที่ออกแล้ว \(facts.reportsIssued) ฉบับ" : nil
        case .information:
            facts.dataDispositionDecided ? "ตัดสินแล้วว่าข้อมูลและไฟล์ที่เหลือจะไปทางไหน" : nil
        case .procurement:
            facts.procurementRecorded ? "บันทึกการจัดซื้อจัดหาไว้แล้ว" : nil
        case .lessons:
            facts.lessonCount > 0 ? "บทเรียน \(facts.lessonCount) ข้อ" : nil
        }
    }

    /// All seventeen, in the standard's order, each answered.
    public static func evaluate(_ facts: ConformanceFacts,
                                tailoring: [TailoringRecord] = []) -> [PracticeStatus] {
        // Last decision wins when a practice was tailored twice: the record is
        // append-only, so the newest is the one in force.
        var byPractice: [Practice: TailoringRecord] = [:]
        for record in tailoring.sorted(by: { $0.decidedAt < $1.decidedAt }) {
            byPractice[record.practice] = record
        }
        return Practice.allCases.map { practice in
            PracticeStatus(practice: practice,
                           evidence: evidence(for: practice, in: facts),
                           tailoring: byPractice[practice])
        }
    }

    /// The practices with neither. This is what §19.12 condition 6 refuses to
    /// close over.
    public static func gaps(_ facts: ConformanceFacts,
                            tailoring: [TailoringRecord] = []) -> [Practice] {
        evaluate(facts, tailoring: tailoring).filter { !$0.satisfied }.map(\.practice)
    }
}

/// Where tailoring records are kept. Append-only in spirit — nothing here
/// updates or deletes, because a governance decision that can be edited away is
/// not a record of anything.
public protocol TailoringPersisting: Sendable {
    func save(_ record: TailoringRecord) async throws
    func all(project: ProjectID) async throws -> [TailoringRecord]
}
