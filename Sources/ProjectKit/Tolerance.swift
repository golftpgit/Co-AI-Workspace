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
        case .time: t("Time", "Status bar cell: time spent on this project.")
        case .cost: t("Cost", "Name of an ISO 21502 practice.")
        case .scope: t("Scope", "Name of an ISO 21502 practice.")
        case .quality: t("Quality", "Name of an ISO 21502 practice.")
        case .risk: t("Risk", "Name of an ISO 21502 practice.")
        case .benefit: t("Benefit", "Name of a tolerance dimension.")
        }
    }

    /// What the number in `Tolerances` means, in the words the screen uses.
    /// The autonomy slider is these six sentences with numbers in them, which
    /// is the whole of §19.10's claim that the slider stops being a mood.
    public var unit: String {
        switch self {
        case .time: t("multiples of the p90 that work of this kind has taken",
                      "Unit of the time tolerance.")
        case .cost: t("per stage, in the endpoint's currency", "Unit of the cost tolerance.")
        case .scope: t("work packages that may be added beyond the baseline",
                       "Unit of the scope tolerance.")
        case .quality: t("rounds of rework per work package", "Unit of the quality tolerance.")
        case .risk: t("highest risk level the team may take on its own (0 low · 1 medium · 2 high)",
                      "Unit of the risk tolerance.")
        case .benefit: t("lowest acceptable value of the measure", "Unit of the benefit tolerance.")
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

    // ── the slider and these numbers, connected (§5.5, P10.6) ──
    //
    // They have described the same thing since both were written and nothing
    // joined them, so moving the slider left the frame where it was and the two
    // halves of the screen disagreed about how much rope the team has.
    //
    // The hazard is the only reason this is a rule and not an assignment: a
    // project may have hand-tuned limits, and a slider that overwrote them
    // would discard numbers somebody chose — silently, because the slider is
    // not where they are looking.

    /// The slider's three positions, named for them. Spelled out here rather
    /// than taken from `OperatingModes.Autonomy` because neither module can see
    /// the other; the app converts, and the conversion is one `switch` over
    /// cases that will not compile if either side gains a position.
    public enum Preset: String, Sendable, Equatable, CaseIterable {
        case approvalRequired, balanced, fullAutonomous
    }

    public static func preset(_ preset: Preset) -> Tolerances {
        switch preset {
        case .approvalRequired: approvalRequired
        case .balanced: balanced
        case .fullAutonomous: fullAutonomous
        }
    }

    /// Which preset these limits *are*, or nil when somebody has tuned them.
    ///
    /// Exact equality on all six axes, not a stored "which preset was picked":
    /// a stored answer goes stale the moment one number is edited, and would
    /// then authorise overwriting the other five.
    public var matchingPreset: Preset? {
        Preset.allCases.first { Self.preset($0).limits == limits }
    }

    /// The frame after the slider moves to `preset`.
    ///
    /// A frame that is still a preset follows — nothing is lost, there was
    /// nothing there but a preset. A frame somebody has edited is returned
    /// unchanged, and `matchingPreset` going nil is how the screen says the
    /// slider and the numbers no longer agree. Applying a preset over tuned
    /// numbers stays possible and stays a deliberate act, which is different
    /// from dragging a slider and worth being different.
    public func following(_ preset: Preset) -> Tolerances {
        matchingPreset == nil ? self : Self.preset(preset)
    }
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
            t("⚠️ The \(dimension.label) tolerance was breached — the project is waiting on your decision",
              "First line of an exception report. Placeholder is which tolerance."),
            "",
            t("Cause: \(cause)", "Exception report line. Placeholder is the cause."),
            t("Effect: \(impact)", "Exception report line. Placeholder is the effect."),
        ]
        if !options.isEmpty {
            lines.append("")
            lines.append(t("Options:", "Exception report heading before the list of options."))
            lines.append(contentsOf: options.enumerated().map { "  \($0.offset + 1). \($0.element)" })
        }
        lines.append("")
        lines.append(t("The team lead suggests: \(recommendation)",
                       "Exception report line. Placeholder is the suggestion."))
        lines.append(t("What we need from you: \(needsFromHuman)",
                       "Exception report line. Placeholder is what is needed."))
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
            cause: t("The \(dimension.label) tolerance was exceeded — now \(format(status.current)) against a limit of \(format(status.limit)) (\(dimension.unit))",
                     "Cause of an exception. Placeholders: which tolerance, its current value, its limit and its unit."),
            impact: t("The team takes on no new work in this stage until it is decided",
                      "Effect of an exception."),
            options: [t("Widen the \(dimension.label) tolerance and carry on",
                        "Option offered in an exception report. Placeholder is which tolerance."),
                      t("Cut scope back to fit the existing tolerance",
                        "Option offered in an exception report."),
                      t("End the project early", "Option offered in an exception report.")],
            recommendation: t("No suggestion from the team lead yet — this report was assembled from measured numbers",
                              "Default recommendation on a system-generated exception."),
            needsFromHuman: t("Choose one of the options, or change the tolerance and close this exception",
                              "What an exception needs from a person."),
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
