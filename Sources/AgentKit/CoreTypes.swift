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
public enum CredibilityTier: String, Sendable, Codable, Comparable, CaseIterable {
    case t1   // authoritative: standards bodies, official guidance, law
    case t2   // peer-reviewed
    case t3   // preprint / semi-official
    case t4   // curated community
    case t5   // general web

    /// The number people say out loud, and what rows written before the tiers
    /// were one type are stored as.
    public var number: Int { (CredibilityTier.allCases.firstIndex(of: self) ?? 0) + 1 }

    /// Lower tier number == more credible, so ordering is inverted on purpose:
    /// `t5 < t1` reads as "general web is worth less than a standards body".
    ///
    /// **This is the one meaning now.** `Knowledge.SourceTier` was a second
    /// enum of the same five tiers whose `<` meant the opposite — `t1 < t2`
    /// was true there — so the same comparison read one way in one module and
    /// the other way next door. That is the kind of duplication §0.2 rule 3
    /// forbids, and the kind that fails silently: nothing crashes, some
    /// filter just keeps the wrong sources.
    public static func < (lhs: CredibilityTier, rhs: CredibilityTier) -> Bool {
        lhs.number > rhs.number
    }

    public var label: String { "T\(number)" }

    /// Accepts both shapes on the way in. Provenance rows have been written
    /// as `"t3"` since P2 and evidence rows as `3` since P1; a decoder that
    /// took only one would make half the stored knowledge base unreadable,
    /// which is a migration nobody asked for (the same rule P9.2 settled).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self),
           let tier = CredibilityTier(rawValue: text) {
            self = tier
            return
        }
        let number = try container.decode(Int.self)
        guard let tier = CredibilityTier.allCases.first(where: { $0.number == number }) else {
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "ไม่รู้จัก tier \(number)")
        }
        self = tier
    }

    /// Written as the string form from here on, which is what the larger of
    /// the two populations already uses.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
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
