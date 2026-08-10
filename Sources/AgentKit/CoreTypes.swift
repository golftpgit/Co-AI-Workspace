import Foundation

// ─────────────────────────────────────────────────────────────
// AgentKit — shared vocabulary for every module (ARCHITECTURE §6).
// Rule: types and protocols only, never logic. Declared ONCE here so we
// never repeat v1's mistake of three separately-declared `Scope` enums.
// ─────────────────────────────────────────────────────────────

public struct ProjectID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// Where a piece of state belongs. Used by KB, DB connectors, workflows,
/// notebooks and agent manifests alike — one declaration for all of them.
public enum Scope: Hashable, Sendable, Codable {
    case central
    case project(ProjectID)
    case policy

    public var isPolicy: Bool { self == .policy }

    /// Stable string form for database columns and config files.
    ///
    /// Used for config files and UI state. Never `:` as a separator —
    /// SurrealDB v3 reads a *bound* string shaped like `table:id` as a record
    /// link (ARCHITECTURE App. C.0). Database rows do not store this composite
    /// form at all; they use primitive columns (see Persistence.ScopeColumns).
    public var storageKey: String {
        switch self {
        case .central: return "central"
        case .policy: return "policy"
        case .project(let id): return "project/\(id.rawValue)"
        }
    }

    public init?(storageKey: String) {
        switch storageKey {
        case "central": self = .central
        case "policy": self = .policy
        default:
            guard storageKey.hasPrefix("project/") else { return nil }
            let id = String(storageKey.dropFirst("project/".count))
            guard !id.isEmpty else { return nil }
            self = .project(ProjectID(id))
        }
    }
}

/// Risk classification for a tool call. Drives the hook chain (§5.3) and,
/// combined with the autonomy setting, whether a human must approve.
public enum RiskLevel: Int, Sendable, Codable, Comparable, CaseIterable, CustomStringConvertible {
    case low = 0
    case medium = 1
    case high = 2

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String {
        switch self {
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        }
    }
}

/// Source credibility, shared by WebSearch (§1.4) and Knowledge (§11.3)
/// so conflict resolution can compare a web page against an uploaded file.
public enum CredibilityTier: Int, Sendable, Codable, Comparable, CaseIterable {
    case t1 = 1   // authoritative: standards bodies, official guidance, law
    case t2 = 2   // peer-reviewed
    case t3 = 3   // preprint / semi-official
    case t4 = 4   // curated community
    case t5 = 5   // general web

    /// Lower tier number == more credible, so ordering is inverted on purpose.
    public static func < (lhs: CredibilityTier, rhs: CredibilityTier) -> Bool {
        lhs.rawValue > rhs.rawValue
    }

    public var label: String { "T\(rawValue)" }
}

/// Which specialist on the AI team owns a piece of work (§2).
/// A closed enum by design: the supervisor cannot invent worker names.
public enum Role: String, Sendable, Codable, CaseIterable {
    case teamLead
    case researcher
    case analyst
    case engineer
    case writer
    case reviewer
}
