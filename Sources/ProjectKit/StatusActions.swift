import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// What the status bar can do, and the trail it leaves (ARCHITECTURE §19.2.3,
// P10.15 second half).
//
// The status bar's whole claim is that it is a dashboard rather than a row of
// labels: every cell opens with *where the number came from* and *a button that
// does something*. The second half is what makes it dangerous — a widget that
// widens a budget or closes an exception in one click, from any screen, is a
// place where decisions get made and forgotten.
//
// So the Done-when includes "ทุกการกระทำใน popover เขียน decision record", and
// the way to make that true is not to remember it at three call sites in a view.
// It is this: every action is a case here, and `ProjectService.perform` is the
// only thing that runs one. A new action that forgets to record is a new case
// that fails `StatusActionTests`.
// ─────────────────────────────────────────────────────────────

public enum StatusAction: Sendable, Equatable {
    /// Loosening the agreed frame from the tolerance popover (§19.10). Goes
    /// through change control as well: after G2 the frame is part of the
    /// agreement, so this can also open a change request.
    case widenTolerance(ToleranceDimension, to: Double, reason: String)
    /// Deciding an exception without leaving the screen — the Done-when's first
    /// clause. The decision text is the answer to the report's
    /// "ต้องการจากคุณ" field.
    case decideException(ExceptionReport, decision: String)
    /// Turning visible drift into a request somebody has to decide (§19.11).
    case requestChange(title: String, scopeImpact: String, timeImpact: String,
                       costImpact: String)

    public var title: String {
        switch self {
        case .widenTolerance(let dimension, let limit, _):
            "ขยายกรอบ\(dimension.label) เป็น \(ChangeControl.number(limit))"
        case .decideException(let report, _):
            "ตัดสินข้อยกเว้น: ทะลุกรอบ\(report.dimension.label)"
        case .requestChange(let title, _, _, _):
            title
        }
    }

    /// The alternatives that were on the table. Kept because a decision record
    /// without them says what happened but not what was being chosen between,
    /// and the second half is what makes it worth reading a month later.
    var options: [String] {
        switch self {
        case .widenTolerance(let dimension, _, _):
            ["ขยายกรอบ\(dimension.label)", "ลดขอบเขตให้พอดีกรอบเดิม", "ยุติโครงการ"]
        case .decideException(let report, _):
            report.options
        case .requestChange:
            ["เปิดคำขอเปลี่ยนแปลง", "ไม่แก้แผน"]
        }
    }

    var reason: String {
        switch self {
        case .widenTolerance(_, _, let reason): reason
        case .decideException(_, let decision): decision
        case .requestChange(_, let scope, let time, let cost):
            "กระทบ: ขอบเขต \(scope) · เวลา \(time) · เงิน \(cost)"
        }
    }

    /// Whether undoing it is a matter of setting the value back. Widening a
    /// frame is; work done under the wider frame is not, which is why the record
    /// says so rather than leaving the reader to assume.
    var isReversible: Bool {
        switch self {
        case .widenTolerance: true
        case .decideException: false
        case .requestChange: true
        }
    }
}

extension ProjectService {

    /// Runs one status-bar action and records it.
    ///
    /// Recording happens **after** the effect and only if it succeeded: a
    /// decision record for something that did not happen is worse than no
    /// record, because it is the version a later reader will believe.
    public func perform(_ action: StatusAction, in id: ProjectID,
                        by person: String = "ผู้ใช้") async throws {
        guard let project = await project(id) else { throw LifecycleError.alreadyClosed }

        switch action {
        case .widenTolerance(let dimension, let limit, _):
            var limits = project.tolerances
            limits.limits[dimension] = limit
            // Through `apply`, so a frame widened after G2 opens its own change
            // request instead of quietly editing the agreement (§19.11).
            try await apply(.tolerances(limits), in: id, by: person)
            // A frame that was breached and has just been widened is no longer
            // breached; the exception it raised has to be closed with it, or the
            // project stays stopped for a limit that no longer exists.
            for report in try await openExceptions(id) where report.dimension == dimension {
                try await resolve(report, decision: "ขยายกรอบ\(dimension.label) เป็น \(ChangeControl.number(limit))")
            }

        case .decideException(let report, let decision):
            let text = decision.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw StatusActionError.emptyDecision }
            try await resolve(report, decision: text)

        case .requestChange(let title, let scope, let time, let cost):
            try await record(RegisterEntry(
                projectID: id, title: title,
                detail: .change(scopeImpact: scope, timeImpact: time, costImpact: cost),
                origin: .human(person)))
            // A change request *is* the record for this one — it names who
            // raised it, what it would do, and it cannot be closed without
            // somebody deciding. A second decision entry beside it would say
            // that a decision was made, which is exactly what has not happened.
            return
        }

        try await record(RegisterEntry(
            projectID: id, title: action.title,
            detail: .decision(options: action.options, reversible: action.isReversible),
            origin: .human(person),
            note: action.reason))
    }
}

public enum StatusActionError: Error, CustomStringConvertible, Equatable {
    case emptyDecision

    public var description: String {
        switch self {
        case .emptyDecision:
            "ต้องเขียนคำตัดสิน — ปิดข้อยกเว้นโดยไม่บอกว่าตัดสินอะไร คือการลบมันทิ้ง"
        }
    }
}
