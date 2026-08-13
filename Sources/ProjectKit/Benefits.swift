import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// Benefits (ARCHITECTURE §19.12, P10.10).
//
// A deliverable is what gets handed over; a benefit is what somebody wanted from
// it. They are not the same fact, and the second one is the one that goes
// missing: a project can deliver every work package on the plan and still have
// been pointless, and nothing in the WBS can tell you that.
//
// ISO 21502 puts benefit realization at the centre for exactly that reason, so a
// benefit here is a *measurement waiting to happen*, not a sentence of intent:
// a measure, a value it starts at, a value it should reach, and a date somebody
// looks. That shape is what makes `result` fillable — and what makes the
// business-case tolerance (§19.10) able to read a number instead of a mood.
//
// The review date may fall after the project closes, and that is the normal
// case for anything worth measuring. So a measurement can be recorded against a
// closed project (§19.12's post-project review) — the one write this system
// allows after closing, because forbidding it would mean the benefit is never
// checked at all, which is the failure the register exists to prevent.
// ─────────────────────────────────────────────────────────────

/// One measurement of one benefit. Separate from the benefit so the fact that
/// nobody has measured it yet is representable — `result == nil` is the state
/// most benefits are in for most of their life, and a zero would read as "we
/// looked and got nothing".
public struct BenefitMeasurement: Sendable, Codable, Equatable {
    public var value: Double
    public var measuredAt: Date
    /// Who looked. A name, not a role: a benefit measured by "the system" is a
    /// benefit nobody will defend at the review.
    public var measuredBy: String
    public var note: String

    public init(value: Double, measuredAt: Date = Date(),
                measuredBy: String, note: String = "") {
        self.value = value
        self.measuredAt = measuredAt
        self.measuredBy = measuredBy
        self.note = note
    }
}

public struct Benefit: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let projectID: ProjectID
    /// What is supposed to get better — "เวลาที่ใช้ทำรายงานประจำเดือน".
    public var title: String
    /// How it is counted — "ชั่วโมงต่อเดือน", "จำนวนข้อผิดพลาดต่อ 100 ระเบียน".
    /// Prose, but prose that names a unit: a measure with no unit cannot be
    /// compared against a target.
    public var measure: String
    /// Where it stands before the project. Required, because "better" with no
    /// starting point is not a claim anyone can check afterwards.
    public var baselineValue: Double
    public var target: Double
    /// When somebody looks. Often after `closedAt`, which is why measuring is
    /// allowed on a closed project.
    public var reviewAt: Date
    /// Whose job the looking is (§19.12's "ใครวัด").
    public var owner: RACIActor
    public var result: BenefitMeasurement?
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: String = OpaqueID.make(OpaqueID.benefit),
                projectID: ProjectID,
                title: String,
                measure: String,
                baselineValue: Double,
                target: Double,
                reviewAt: Date,
                owner: RACIActor,
                result: BenefitMeasurement? = nil,
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.measure = measure
        self.baselineValue = baselineValue
        self.target = target
        self.reviewAt = reviewAt
        self.owner = owner
        self.result = result
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isMeasured: Bool { result != nil }

    /// How far it got, as a fraction of the distance it was supposed to travel.
    /// `nil` until measured — the distinction the whole type exists for.
    ///
    /// Subtraction rather than division on purpose: half of all real benefits
    /// are improvements *downwards* (fewer errors, less time), and a ratio of
    /// `value / target` calls those a success the moment they get worse.
    public var achievement: Double? {
        guard let result else { return nil }
        let distance = target - baselineValue
        guard distance != 0 else { return result.value == target ? 1 : 0 }
        return (result.value - baselineValue) / distance
    }

    /// Whether somebody was supposed to have looked by now.
    public func isDue(at now: Date = Date()) -> Bool {
        result == nil && reviewAt <= now
    }
}

/// The project's benefits, and the two questions asked of them: what does the
/// business case look like now, and is anything owed a measurement.
public struct BenefitLedger: Sendable, Equatable {
    public let benefits: [Benefit]

    public init(_ benefits: [Benefit] = []) {
        self.benefits = benefits.sorted { $0.reviewAt < $1.reviewAt }
    }

    public var isEmpty: Bool { benefits.isEmpty }
    public var measured: [Benefit] { benefits.filter(\.isMeasured) }
    public var unmeasured: [Benefit] { benefits.filter { !$0.isMeasured } }

    public func due(at now: Date = Date()) -> [Benefit] {
        benefits.filter { $0.isDue(at: now) }
    }

    /// The worst measured benefit, as a fraction of its target. `nil` when
    /// nothing has been measured — which the tolerance strip renders as "ยังไม่
    /// ได้วัด" rather than as a full bar. A business case that looks healthy
    /// because nobody checked is the exact failure §19.12 is about.
    public var lowestAchievement: Double? {
        measured.compactMap(\.achievement).min()
    }
}

public enum BenefitError: Error, CustomStringConvertible, Equatable {
    case emptyMeasurer

    public var description: String {
        switch self {
        case .emptyMeasurer: "ต้องระบุชื่อคนที่วัด — ตัวเลขที่ไม่มีใครรับรองไม่ใช่ผลการวัด"
        }
    }
}

/// Where benefits are kept. Same split as the registers: the rule lives in
/// ProjectKit, the row lives in Persistence, and neither imports the other.
public protocol BenefitPersisting: Sendable {
    func save(_ benefit: Benefit) async throws
    func all(project: ProjectID) async throws -> [Benefit]
    func delete(_ id: String, project: ProjectID) async throws
}
