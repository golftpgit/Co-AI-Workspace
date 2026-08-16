import Foundation

// ─────────────────────────────────────────────────────────────
// What is on screen, as a value (ARCHITECTURE §23.1, §23.3 · P17.1/P17.4).
//
// The accessibility tree is the driver's primary surface, and it is worth being
// a plain value for two reasons that turn out to be the same reason: it can be
// compared — which is what makes "the screen changed" evidence rather than a
// claim (§23.3) — and it can be searched without a live app, which is what
// makes the finding rules testable at all.
//
// **This is the same tree VoiceOver reads.** A driver that can find a control
// is a driver that proves the control is reachable; a control it cannot find is
// a control somebody using VoiceOver cannot find either. The accessibility
// audit and the driver are the same work approached from two ends.
// ─────────────────────────────────────────────────────────────

public struct ScreenElement: Sendable, Equatable, Codable {
    /// AX role — `AXButton`, `AXTextField`, `AXStaticText`.
    public let role: String
    /// What a screen reader would say. This is what the driver searches by:
    /// a coordinate is a command that breaks silently when a layout moves one
    /// pixel, and a label is a command that breaks with a message (§23.1).
    public let label: String
    /// The control's current value, where it has one.
    public let value: String?
    /// AppKit's finer answer — `AXCloseButton`, `AXMinimizeButton`. Carried
    /// because it is what separates the window's own furniture from a control
    /// this app drew, and a driver that cannot tell them apart reports the
    /// traffic lights as unlabelled buttons forever (measured, E.30).
    public let subrole: String?
    /// Centre of the element in screen coordinates, for the cases where a click
    /// has to be synthesised. Optional because an element found in a stored
    /// snapshot has no position on today's screen.
    public let centre: Point?
    public let enabled: Bool
    public let children: [ScreenElement]

    public struct Point: Sendable, Equatable, Codable {
        public let x: Double
        public let y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    public init(role: String, label: String, value: String? = nil,
                subrole: String? = nil,
                centre: Point? = nil, enabled: Bool = true,
                children: [ScreenElement] = []) {
        self.subrole = subrole
        self.role = role
        self.label = label
        self.value = value
        self.centre = centre
        self.enabled = enabled
        self.children = children
    }

    /// Depth-first, self included — the order a person reads a window in, and
    /// the order that makes "the first Save button" mean the topmost one.
    public var flattened: [ScreenElement] {
        [self] + children.flatMap(\.flattened)
    }
}

/// One window's tree at one moment.
public struct ScreenSnapshot: Sendable, Equatable, Codable {
    public let takenAt: Date
    public let windowTitle: String
    public let root: ScreenElement

    public init(takenAt: Date, windowTitle: String, root: ScreenElement) {
        self.takenAt = takenAt
        self.windowTitle = windowTitle
        self.root = root
    }

    /// Everything on screen that a screen reader would announce, in order. The
    /// comparison unit for "did anything happen": labels and values, not
    /// coordinates, because a window that merely moved has not changed.
    public var spokenLines: [String] {
        root.flattened.compactMap { element in
            let text = [element.label, element.value].compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: ": ")
            return text.isEmpty ? nil : "\(element.role) \(text)"
        }
    }

    /// Whether anything a person could notice is different.
    ///
    /// **This is what turns a driver's report into evidence** (§23.3): a model
    /// saying it pressed a button is a claim, and two snapshots either differ
    /// or they do not. Timestamps are deliberately not part of it — otherwise
    /// every pair would "differ" and the check would pass on nothing.
    public func differs(from other: ScreenSnapshot) -> Bool {
        spokenLines != other.spokenLines || windowTitle != other.windowTitle
    }

    /// The lines that appeared and the lines that went away, for a QA reviewer
    /// who has to say *what* changed rather than that something did.
    public func changes(from before: ScreenSnapshot) -> (added: [String], removed: [String]) {
        let old = Set(before.spokenLines), new = Set(spokenLines)
        return (added: spokenLines.filter { !old.contains($0) },
                removed: before.spokenLines.filter { !new.contains($0) })
    }
}

// ─────────────────────────────────────────────────────────────

/// How to say which control is meant.
///
/// By label and role, never by index into a list of everything: "the third
/// button" is a description that survives no layout change at all, and a test
/// written that way fails the day somebody adds a toolbar item.
public struct ElementQuery: Sendable, Equatable {
    public enum Match: Sendable, Equatable {
        case exact(String)
        /// For labels that carry state — "ปิดแท็บ โครงการ ก — ปิดแค่หน้าต่าง…".
        /// The spoken label is written for a person, and pinning the whole
        /// sentence in a test makes the test fail on a wording improvement.
        case contains(String)
    }

    public let label: Match
    /// `nil` matches any role. Given, it is the difference between the button
    /// called "บันทึก" and the static text next to it that says the same word.
    public let role: String?
    public let mustBeEnabled: Bool

    public init(label: Match, role: String? = nil, mustBeEnabled: Bool = true) {
        self.label = label
        self.role = role
        self.mustBeEnabled = mustBeEnabled
    }

    public static func button(_ label: String) -> ElementQuery {
        ElementQuery(label: .contains(label), role: "AXButton")
    }

    public static func field(_ label: String) -> ElementQuery {
        ElementQuery(label: .contains(label), role: "AXTextField")
    }

    func matches(_ element: ScreenElement) -> Bool {
        if let role, element.role != role { return false }
        if mustBeEnabled, !element.enabled { return false }
        switch label {
        case .exact(let text): return element.label == text
        case .contains(let text):
            return element.label.localizedCaseInsensitiveContains(text)
                || (element.value?.localizedCaseInsensitiveContains(text) ?? false)
        }
    }
}

/// Why a control could not be acted on. Every case says what to do next,
/// because §23.1's whole argument for driving by label is that a failure comes
/// with a message instead of a click into empty space.
public enum ScreenDriverError: Error, CustomStringConvertible, Equatable {
    case notFound(query: String, sawInstead: [String])
    case ambiguous(query: String, count: Int)
    case disabled(label: String)
    case notPermitted(String)
    /// The screen did not change after an action that should have changed it.
    case nothingHappened(action: String)

    public var description: String {
        switch self {
        case .notFound(let query, let saw):
            "หา \(query) บนหน้าจอไม่เจอ — ที่เห็นคือ: "
                + (saw.isEmpty ? "(ไม่มีอะไรเลย)" : saw.prefix(8).joined(separator: " · "))
        case .ambiguous(let query, let count):
            "เจอ \(query) \(count) อัน — ต้องระบุให้เจาะจงกว่านี้ "
                + "(ใส่ role หรือใช้ข้อความที่ยาวขึ้น) ก่อนจะกดอันไหนก็ได้แล้วหวังว่าถูก"
        case .disabled(let label):
            "ปุ่ม “\(label)” ยังกดไม่ได้ — หน้าจอกำลังบอกว่ายังทำสิ่งนี้ไม่ได้ ไม่ใช่ตัวขับหาไม่เจอ"
        case .notPermitted(let detail): detail
        case .nothingHappened(let action):
            "ทำ “\(action)” แล้วหน้าจอไม่เปลี่ยนเลย — ถือว่ายังไม่ได้เกิดอะไรขึ้น "
                + "จนกว่าจะมีหลักฐานว่าเปลี่ยน (§23.3)"
        }
    }
}

public enum ElementFinder {
    /// The one control a query names, or a refusal that says why.
    ///
    /// Ambiguity is an error rather than "take the first": a driver that
    /// silently picks one of three Save buttons produces a test that passes
    /// while pressing the wrong thing, which is worse than no test.
    public static func find(_ query: ElementQuery,
                            in snapshot: ScreenSnapshot) throws -> ScreenElement {
        let all = snapshot.root.flattened
        let matches = all.filter { query.matches($0) }
        switch matches.count {
        case 1: return matches[0]
        case 0:
            // A disabled control that would otherwise match is reported as
            // disabled, not missing: they send a person to two different places.
            let ignoringEnabled = ElementQuery(label: query.label, role: query.role,
                                               mustBeEnabled: false)
            if let found = all.first(where: { ignoringEnabled.matches($0) }) {
                throw ScreenDriverError.disabled(label: found.label)
            }
            throw ScreenDriverError.notFound(query: describe(query),
                                             sawInstead: all.filter { !$0.label.isEmpty }
                                                 .map(\.label))
        default:
            throw ScreenDriverError.ambiguous(query: describe(query), count: matches.count)
        }
    }

    static func describe(_ query: ElementQuery) -> String {
        let text: String
        switch query.label {
        case .exact(let value): text = "“\(value)”"
        case .contains(let value): text = "ที่มีคำว่า “\(value)”"
        }
        return [query.role, text].compactMap { $0 }.joined(separator: " ")
    }
}
