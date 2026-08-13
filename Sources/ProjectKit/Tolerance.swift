import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// Manage by exception (ARCHITECTURE §19.10, P10.6).
//
// The piece of PRINCE2 worth the most here. The team runs on its own inside an
// agreed frame; the moment it leaves the frame it stops and hands the decision
// to a person. Not "asks nicely" — stops.
//
// Escalation already existed with one trigger (rework past the cap). This makes
// it six, and every one of them reads a number the system was already
// recording: spans for time, the budget governor for cost, the baseline diff
// for scope, `retry_count` for quality, the risk scorer for risk, and the
// benefit target for benefit. Nothing new is measured — the measurements are
// simply given a limit and a consequence.
//
// The evaluation is a pure function of (limits, readings). The app supplies the
// readings; this file decides nothing about where they come from, which is what
// makes the rule testable without a running project.
// ─────────────────────────────────────────────────────────────

public enum ToleranceDimension: String, Sendable, Codable, CaseIterable {
    case time, cost, scope, quality, risk, benefit

    public var label: String {
        switch self {
        case .time: "เวลา"
        case .cost: "ค่าใช้จ่าย"
        case .scope: "ขอบเขต"
        case .quality: "คุณภาพ"
        case .risk: "ความเสี่ยง"
        case .benefit: "ประโยชน์"
        }
    }

    /// What the number in `Tolerances` means, in the words the screen uses.
    /// The autonomy slider is these six sentences with numbers in them, which
    /// is the whole of §19.10's claim that the slider stops being a mood.
    public var unit: String {
        switch self {
        case .time: "เท่าของ p90 ที่งานแบบเดียวกันเคยใช้"
        case .cost: "บาทต่อขั้น"
        case .scope: "ใบงานที่เพิ่มได้จาก baseline"
        case .quality: "รอบ rework ต่อใบงาน"
        case .risk: "ระดับความเสี่ยงสูงสุดที่ทำเองได้ (0 ต่ำ · 1 กลาง · 2 สูง)"
        case .benefit: "ค่าต่ำสุดของตัววัดที่ยอมรับได้"
        }
    }
}

/// The agreed frame. One number per dimension, because a limit somebody has to
/// interpret is a limit that gets argued with at exactly the wrong moment.
public struct Tolerances: Sendable, Codable, Equatable {
    public var limits: [ToleranceDimension: Double]

    public init(limits: [ToleranceDimension: Double] = Tolerances.balanced.limits) {
        self.limits = limits
    }

    public func limit(_ dimension: ToleranceDimension) -> Double {
        limits[dimension] ?? Self.balanced.limits[dimension] ?? 0
    }

    /// The three presets the autonomy slider maps onto (§5.5). Named the same
    /// way, so moving the slider and reading the numbers describe one thing.
    public static let approvalRequired = Tolerances(limits: [
        .time: 1.0, .cost: 100, .scope: 0, .quality: 1, .risk: 0, .benefit: 0,
    ])
    public static let balanced = Tolerances(limits: [
        .time: 1.5, .cost: 500, .scope: 0, .quality: 3, .risk: 1, .benefit: 0,
    ])
    public static let fullAutonomous = Tolerances(limits: [
        .time: 3.0, .cost: 2_000, .scope: 3, .quality: 5, .risk: 2, .benefit: 0,
    ])
}

/// What is actually happening, as the app measures it. Every field names where
/// it comes from, because a number with no source is a number nobody can argue
/// with when it decides to stop the work.
public struct ToleranceReadings: Sendable, Equatable {
    /// Elapsed time over the p90 of comparable spans. 1.0 means "as long as
    /// this kind of work usually takes".
    public var timeRatio: Double
    /// Spent this stage, from the budget governor's ledger.
    public var spent: Double
    /// Work packages added since the baseline was frozen.
    public var addedPackages: Double
    /// The highest `retry_count` on any open package.
    public var maxRework: Double
    /// The highest risk class waiting to be executed (0 low, 1 medium, 2 high).
    public var highestRisk: Double
    /// The lowest measured benefit against its target, as a fraction. 1.0 means
    /// the target is met; below the limit means the business case is in doubt.
    public var benefitRatio: Double

    public init(timeRatio: Double = 0, spent: Double = 0, addedPackages: Double = 0,
                maxRework: Double = 0, highestRisk: Double = 0, benefitRatio: Double = 1) {
        self.timeRatio = timeRatio
        self.spent = spent
        self.addedPackages = addedPackages
        self.maxRework = maxRework
        self.highestRisk = highestRisk
        self.benefitRatio = benefitRatio
    }

    public func value(for dimension: ToleranceDimension) -> Double {
        switch dimension {
        case .time: timeRatio
        case .cost: spent
        case .scope: addedPackages
        case .quality: maxRework
        case .risk: highestRisk
        case .benefit: benefitRatio
        }
    }
}

public struct ToleranceStatus: Sendable, Equatable, Identifiable {
    public let dimension: ToleranceDimension
    public let limit: Double
    public let current: Double
    public let breached: Bool

    public var id: String { dimension.rawValue }

    /// How close to the edge, for the strip that has to show "nearly" as well
    /// as "over" — the point of a frame is being able to see it coming.
    public var fraction: Double {
        guard limit > 0 else { return breached ? 1 : 0 }
        return min(current / limit, 1.5)
    }
}

public enum ToleranceCheck {
    /// Benefit is the one dimension where *less* is the breach: everything
    /// else counts up towards its limit, a benefit counts down away from it.
    public static func isBreach(_ dimension: ToleranceDimension,
                                current: Double, limit: Double) -> Bool {
        switch dimension {
        case .benefit: limit > 0 && current < limit
        default: current > limit
        }
    }

    public static func evaluate(_ tolerances: Tolerances,
                                readings: ToleranceReadings) -> [ToleranceStatus] {
        ToleranceDimension.allCases.map { dimension in
            let limit = tolerances.limit(dimension)
            let current = readings.value(for: dimension)
            return ToleranceStatus(dimension: dimension, limit: limit, current: current,
                                   breached: isBreach(dimension, current: current, limit: limit))
        }
    }

    public static func breaches(_ tolerances: Tolerances,
                                readings: ToleranceReadings) -> [ToleranceStatus] {
        evaluate(tolerances, readings: readings).filter(\.breached)
    }
}

/// The report a person is handed when the frame is left (§19.10).
///
/// The shape is the standard's, and every field is there because a report
/// missing it makes the reader do the work: what happened, what it costs, what
/// could be done, what the lead thinks, and — the field that turns a status
/// update into a decision — what is being asked for.
public struct ExceptionReport: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let projectID: ProjectID
    public let dimension: ToleranceDimension
    public let cause: String
    public let impact: String
    public let options: [String]
    public let recommendation: String
    public let needsFromHuman: String
    public let raisedAt: Date
    public var resolvedAt: Date?
    public var resolution: String?

    public var isOpen: Bool { resolvedAt == nil }

    public init(id: String = OpaqueID.make(OpaqueID.exception),
                projectID: ProjectID,
                dimension: ToleranceDimension,
                cause: String,
                impact: String,
                options: [String],
                recommendation: String,
                needsFromHuman: String,
                raisedAt: Date = Date(),
                resolvedAt: Date? = nil,
                resolution: String? = nil) {
        self.id = id
        self.projectID = projectID
        self.dimension = dimension
        self.cause = cause
        self.impact = impact
        self.options = options
        self.recommendation = recommendation
        self.needsFromHuman = needsFromHuman
        self.raisedAt = raisedAt
        self.resolvedAt = resolvedAt
        self.resolution = resolution
    }

    /// One text for every channel (§19.10). Rendered here rather than per
    /// channel so the version that reaches a phone is the version on screen.
    public var message: String {
        var lines = [
            "⚠️ ทะลุกรอบ\(dimension.label) — โครงการหยุดรอคุณตัดสิน",
            "",
            "สาเหตุ: \(cause)",
            "ผลกระทบ: \(impact)",
        ]
        if !options.isEmpty {
            lines.append("")
            lines.append("ทางเลือก:")
            lines.append(contentsOf: options.enumerated().map { "  \($0.offset + 1). \($0.element)" })
        }
        lines.append("")
        lines.append("ข้อเสนอของหัวหน้าทีม: \(recommendation)")
        lines.append("ต้องการจากคุณ: \(needsFromHuman)")
        return lines.joined(separator: "\n")
    }

    /// The report a breach produces on its own, when nobody has written a
    /// better one. Bare, and honest about being bare: a breach that raised no
    /// report at all would stop the work with no explanation, which is the one
    /// outcome worse than a thin explanation.
    public static func automatic(projectID: ProjectID,
                                 status: ToleranceStatus,
                                 raisedAt: Date = Date()) -> ExceptionReport {
        let dimension = status.dimension
        return ExceptionReport(
            projectID: projectID,
            dimension: dimension,
            cause: "\(dimension.label)ทะลุกรอบที่ตั้งไว้ — ตอนนี้ \(format(status.current)) จากกรอบ \(format(status.limit)) (\(dimension.unit))",
            impact: "ทีมหยุดรับงานใหม่ในขั้นนี้จนกว่าจะมีคำตัดสิน",
            options: ["ขยายกรอบ\(dimension.label) แล้วทำต่อ",
                      "ลดขอบเขตให้พอดีกับกรอบเดิม",
                      "ยุติโครงการก่อนกำหนด"],
            recommendation: "ยังไม่มีข้อเสนอจากหัวหน้าทีม — รายงานนี้ระบบสร้างจากตัวเลขที่วัดได้",
            needsFromHuman: "เลือกทางใดทางหนึ่ง หรือแก้กรอบแล้วปิดข้อยกเว้นนี้",
            raisedAt: raisedAt)
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}

extension Project {
    /// The frame as a value. Stored as a plain dictionary on the project so the
    /// row stays decodable without ProjectKit, and read through this so nobody
    /// has to remember the string keys.
    public var tolerances: Tolerances {
        get {
            var limits: [ToleranceDimension: Double] = [:]
            for (key, value) in toleranceLimits {
                if let dimension = ToleranceDimension(rawValue: key) { limits[dimension] = value }
            }
            return limits.isEmpty ? .balanced : Tolerances(limits: limits)
        }
        set {
            toleranceLimits = Dictionary(uniqueKeysWithValues:
                newValue.limits.map { ($0.key.rawValue, $0.value) })
        }
    }
}

/// Where exception reports are kept. Same split as the other two: the rule
/// lives here, the row lives in Persistence.
public protocol ExceptionPersisting: Sendable {
    func save(_ report: ExceptionReport) async throws
    func all(project: ProjectID) async throws -> [ExceptionReport]
}
