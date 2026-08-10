import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// The three operating switches (ARCHITECTURE §5.5). They are independent on
// purpose: v1 conflated "don't execute" with "don't ask", which meant turning
// off approvals also turned off plan-only, and neither state was visible.
// ─────────────────────────────────────────────────────────────

public struct OperatingModes: Sendable, Equatable, Codable {
    /// Where the approval threshold sits. A slider, not a boolean, because
    /// "ask me about everything" and "ask me about nothing" are both wrong
    /// for day-to-day work.
    public enum Autonomy: Int, Sendable, Equatable, Codable, CaseIterable {
        /// Anything that is not read-only stops for a human.
        case approvalRequired = 0
        /// Only genuinely destructive work stops.
        case balanced = 1
        /// Nothing stops for approval — a policy hard stop still stops (§11.2).
        case fullAutonomous = 2

        public func requiresApproval(for risk: RiskLevel) -> Bool {
            switch self {
            case .approvalRequired: return risk >= .medium
            case .balanced: return risk >= .high
            case .fullAutonomous: return false
            }
        }

        public var label: String {
            switch self {
            case .approvalRequired: return "ขออนุมัติทุกขั้น"
            case .balanced: return "ขออนุมัติเฉพาะงานเสี่ยงสูง"
            case .fullAutonomous: return "ทำงานเองทั้งหมด"
            }
        }
    }

    public var autonomy: Autonomy
    /// Think and propose, never execute. Enforced in the gateway, so no agent
    /// can execute a tool while it is on regardless of its own risk opinion.
    public var planOnly: Bool
    /// Chain tasks without waiting for the user to type again. Explicit toggle
    /// only — v1 tried to infer it and got it wrong (§5.5).
    public var runUntilDone: Bool

    public init(autonomy: Autonomy = .balanced,
                planOnly: Bool = false,
                runUntilDone: Bool = false) {
        self.autonomy = autonomy
        self.planOnly = planOnly
        self.runUntilDone = runUntilDone
    }

    public static let `default` = OperatingModes()
}
