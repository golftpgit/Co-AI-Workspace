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
public enum Scope: Hashable, Sendable {
    case central
    case project(ProjectID)
    case policy
    /// One organisation-wide run's Situation Board (§22.5, P16.4).
    ///
    /// A scope rather than a new subsystem, so the board is searched by the
    /// `kb_search` every agent already has and written by the one path that
    /// may write it. Keyed by run so it disappears with the run: a board that
    /// outlived its incident would be a second library nobody curates.
    case board(String)

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
        case .board(let runID): return "board/\(runID)"
        }
    }

    public init?(storageKey: String) {
        switch storageKey {
        case "central": self = .central
        case "policy": self = .policy
        default:
            if storageKey.hasPrefix("board/") {
                let runID = String(storageKey.dropFirst("board/".count))
                guard !runID.isEmpty else { return nil }
                self = .board(runID)
                return
            }
            guard storageKey.hasPrefix("project/") else { return nil }
            let id = String(storageKey.dropFirst("project/".count))
            guard !id.isEmpty else { return nil }
            self = .project(ProjectID(id))
        }
    }
}

// ─────────────────────────────────────────────────────────────

extension Scope: Codable {
    /// Encoded as its `storageKey`, not as a synthesized enum object.
    ///
    /// **Written by hand for two reasons, and the second one is a crash.**
    ///
    ///  1. `storageKey` is already the documented stable string form for this
    ///     type — config files and columns use it — so a second, differently
    ///     shaped JSON representation was one representation too many. A
    ///     `connectors.json` a person opens now says `"project/diabetes"`
    ///     rather than `{"project":{"_0":{"rawValue":"diabetes"}}}`.
    ///  2. The synthesized conformance took `JSONEncoder` into
    ///     `EXC_BAD_ACCESS` inside `serializeString` on this toolchain once the
    ///     enum grew a fourth case — a use-after-free in Foundation's encoder,
    ///     not in anything callable from here. A single-value string has no
    ///     nested containers for it to lose track of.
    ///
    /// The decoder still reads the old object form, because files written by
    /// earlier builds exist and a settings file that stops loading is a
    /// migration nobody asked for.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageKey)
    }

    private enum LegacyKey: String, CodingKey {
        case central, project, policy, board
    }

    private enum PayloadKey: String, CodingKey {
        case _0
    }

    public init(from decoder: any Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let text = try? container.decode(String.self),
           let scope = Scope(storageKey: text) {
            self = scope
            return
        }
        // The shape Swift synthesized before this extension existed.
        let container = try decoder.container(keyedBy: LegacyKey.self)
        guard let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "ไม่รู้ว่าเป็น scope ไหน"))
        }
        switch key {
        case .central: self = .central
        case .policy: self = .policy
        case .project:
            let nested = try container.nestedContainer(keyedBy: PayloadKey.self, forKey: .project)
            self = .project(try nested.decode(ProjectID.self, forKey: ._0))
        case .board:
            let nested = try container.nestedContainer(keyedBy: PayloadKey.self, forKey: .board)
            self = .board(try nested.decode(String.self, forKey: ._0))
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

    /// Good enough to stand behind a claim on its own (§14.1). T4–T5 are not:
    /// a curated wiki and a blog post can *point* at the truth, but the rule is
    /// that something at T1–T3 has to be there too.
    public var canCarryAClaim: Bool { self <= .t3 }
}

/// §14.1's rule for how confidently something may be written, as arithmetic.
///
/// It lives here, in the module both callers already depend on, because it is one
/// rule with two jobs: the Limitations section of a document explains it to a
/// reader, and QA *refuses work* over it. Two copies would have drifted the first
/// time one of them was tuned — and the copy that mattered would have been the
/// one that let work through (§0.2 rule 3).
public enum Corroboration: Sendable, Equatable {
    /// Two or more sources at T1–T2.
    case strong
    /// Enough to state, with the qualification that goes with it.
    case adequate
    /// Only weak sources, or only one of anything.
    case weak(reason: String)

    public var mayStatePlainly: Bool { self == .strong }
    public var isEnoughForQA: Bool {
        if case .weak = self { return false }
        return true
    }

    public var note: String? {
        switch self {
        case .strong: nil
        case .adequate: "มีแหล่งรองรับพอสมควร แต่ยังไม่ถึงเกณฑ์ 'แหล่งชั้นต้นสองแหล่งขึ้นไป'"
        case .weak(let reason): reason
        }
    }

    /// One tier per *work*, in any order. `nil` is a source with no tier at all,
    /// which counts as a source and never as a strong one.
    ///
    /// Counting works rather than sentences is the point: quoting one paper three
    /// times is one source, and a rule that counted otherwise would let a single
    /// blog post look like a consensus.
    public static func assess(tiers: [CredibilityTier?]) -> Corroboration {
        guard !tiers.isEmpty else { return .weak(reason: "ไม่มีแหล่งอ้างอิงเลย") }
        let strong = tiers.filter { $0 == .t1 || $0 == .t2 }.count
        let mid = tiers.filter { $0 == .t3 }.count
        if strong >= 2 { return .strong }
        if tiers.count == 1 {
            return .weak(reason: "มีแหล่งเดียว — ยังยืนยันข้ามแหล่งไม่ได้")
        }
        if strong + mid >= 1 { return .adequate }
        // Ten weak sources are not two strong ones; §14.1 is explicit that T5s
        // need at least one T1–T3 standing behind them.
        return .weak(reason: "มีแต่แหล่งชั้นรอง (T4–T5) \(tiers.count) แหล่ง — "
                     + "ต้องมีแหล่ง T1–T3 ยืนยันอย่างน้อยหนึ่งแหล่ง")
    }
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
