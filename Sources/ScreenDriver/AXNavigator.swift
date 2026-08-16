import Foundation
import ApplicationServices
import CoreGraphics
import AppKit
import AgentKit
import Observability

// ─────────────────────────────────────────────────────────────
// Driving the screen through the accessibility tree
// (ARCHITECTURE §23.1, P17.1/P17.2/P17.3).
//
// **AX first, always.** Finding a button by the name a screen reader announces
// and then pressing it is an instruction that fails with a message. Clicking at
// (412, 288) is an instruction that fails silently the moment a layout moves,
// and worse, sometimes succeeds on the wrong control. `CGEvent` appears here
// only where AX genuinely cannot write — typing into `TextField`, `TextEditor`
// and `SecureField`, which is the exact wall the previous AppleScript driver
// hit and the whole reason this module exists.
//
// **Scoped to this app by default** (§23.2 rule 3). The APIs below can drive
// every window on the machine; the driver is constructed around one pid and
// refuses anything else unless a caller opens that door deliberately.
// ─────────────────────────────────────────────────────────────

public actor AXNavigator {
    private let pid: pid_t
    private let permissions: ScreenPermissionReader
    private let spans: (any SpanSink)?
    private let log = AppLog.logger("screen-driver")

    /// - Parameter pid: whose windows may be touched. Defaults to this process,
    ///   which is the only thing a self-test needs and the safe default for a
    ///   capability that can otherwise reach anybody's password manager.
    public init(pid: pid_t = ProcessInfo.processInfo.processIdentifier,
                permissions: ScreenPermissionReader = ScreenPermissionReader(),
                spans: (any SpanSink)? = nil) {
        self.pid = pid
        self.permissions = permissions
        self.spans = spans
    }

    /// The frontmost window of the target app, as a value.
    public func snapshot() throws -> ScreenSnapshot {
        try requirePermission()
        let application = AXUIElementCreateApplication(pid)
        guard let window = Self.copy(application, kAXFocusedWindowAttribute)
                ?? Self.copyFirst(application, kAXWindowsAttribute) else {
            throw ScreenDriverError.notFound(query: "หน้าต่างของแอป", sawInstead: [])
        }
        let root = Self.read(window, depth: 0)
        return ScreenSnapshot(takenAt: Date(),
                              windowTitle: Self.string(window, kAXTitleAttribute) ?? "",
                              root: root)
    }

    /// What has keyboard focus right now, as a value.
    ///
    /// The other half of §14.4: a tree where everything has a name says
    /// nothing about the order somebody reaches those names in, and focus
    /// order is only answerable by moving focus and looking (P8.7).
    public func focused() throws -> ScreenElement? {
        try requirePermission()
        let application = AXUIElementCreateApplication(pid)
        guard let element = Self.copy(application, kAXFocusedUIElementAttribute) else {
            return nil
        }
        return Self.describe(element)
    }

    /// Presses the control a query names, and reports what changed.
    ///
    /// The before/after pair is not a nicety — it is the evidence (§23.3). A
    /// press that changes nothing on screen is reported as `nothingHappened`
    /// rather than as success, because "I clicked it" is exactly the claim this
    /// module exists to replace.
    @discardableResult
    public func press(_ query: ElementQuery) async throws -> ScreenAction {
        let before = try snapshot()
        let element = try ElementFinder.find(query, in: before)
        let live = try locate(query)

        // AXPress is what a screen reader does. It reaches controls a synthetic
        // click cannot — a menu item inside a closed menu, a button off the
        // visible area — and it cannot land on the wrong thing.
        let pressed = AXUIElementPerformAction(live, kAXPressAction as CFString)
        if pressed != .success {
            guard let centre = element.centre else {
                throw ScreenDriverError.notFound(query: ElementFinder.describe(query),
                                                 sawInstead: before.spokenLines)
            }
            Self.click(at: CGPoint(x: centre.x, y: centre.y))
        }

        let after = try await settled(after: before)
        return try await record(ScreenAction(
            description: "กด \(element.label)",
            before: before, after: after,
            usedFallbackClick: pressed != .success))
    }

    /// Types text into a field — the thing AX cannot do (§23.1).
    ///
    /// `CGEventKeyboardSetUnicodeString` rather than key codes, because key
    /// codes are a US keyboard layout and this app's users type Thai. The
    /// field is focused through AX first so the characters land somewhere
    /// deliberate rather than wherever focus happened to be.
    @discardableResult
    public func type(_ text: String, into query: ElementQuery) async throws -> ScreenAction {
        let before = try snapshot()
        let element = try ElementFinder.find(query, in: before)
        let live = try locate(query)

        AXUIElementSetAttributeValue(live, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        // Some fields do accept a written value, and where they do it is both
        // faster and less disruptive than synthesising keystrokes. Tried first,
        // and the keyboard is the fallback rather than the other way round.
        let written = AXUIElementSetAttributeValue(live, kAXValueAttribute as CFString,
                                                   text as CFTypeRef)
        if written != .success { Self.typeUnicode(text) }

        let after = try await settled(after: before)
        return try await record(ScreenAction(
            description: "พิมพ์ “\(text)” ลง \(element.label)",
            before: before, after: after,
            usedFallbackClick: written != .success))
    }

    // MARK: - the parts that talk to the system

    private func requirePermission() throws {
        let state = permissions.read()
        guard state.canDrive else {
            throw ScreenDriverError.notPermitted(
                (["ตัวขับหน้าจอทำงานไม่ได้เพราะยังไม่มีสิทธิ์:"] + state.instructions)
                    .joined(separator: "\n"))
        }
    }

    /// Finds the live element again by walking the same tree the snapshot came
    /// from. Re-walked rather than cached: an `AXUIElement` held across a
    /// redraw refers to something that may no longer exist, and SwiftUI redraws
    /// constantly.
    private func locate(_ query: ElementQuery) throws -> AXUIElement {
        let application = AXUIElementCreateApplication(pid)
        guard let window = Self.copy(application, kAXFocusedWindowAttribute)
                ?? Self.copyFirst(application, kAXWindowsAttribute) else {
            throw ScreenDriverError.notFound(query: "หน้าต่างของแอป", sawInstead: [])
        }
        var found: [AXUIElement] = []
        Self.walk(window, depth: 0) { element in
            if query.matches(Self.describe(element)) { found.append(element) }
        }
        switch found.count {
        case 1: return found[0]
        case 0: throw ScreenDriverError.notFound(query: ElementFinder.describe(query),
                                                 sawInstead: [])
        default: throw ScreenDriverError.ambiguous(query: ElementFinder.describe(query),
                                                   count: found.count)
        }
    }

    /// Waits for the screen to stop moving, up to a bound.
    ///
    /// Not a fixed sleep: an animation takes as long as it takes, and a fixed
    /// wait is either slower than it needs to be or shorter than the animation
    /// on the machine that matters. Bounded, because a screen that never
    /// settles has to be reported rather than waited on forever.
    private func settled(after before: ScreenSnapshot,
                         within limit: Duration = .seconds(3)) async throws -> ScreenSnapshot {
        var last = before
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(120))
            let now = try snapshot()
            if now.differs(from: before), !now.differs(from: last) { return now }
            last = now
        }
        return last
    }

    private func record(_ action: ScreenAction) async throws -> ScreenAction {
        var span = Span(name: "screen.\(action.changed ? "acted" : "no-change")",
                        status: action.changed ? .succeeded : .failed,
                        endedAt: Date())
        span.detail = action.description
        await spans?.record(span)
        log.info("\(action.description, privacy: .public) — \(action.changed ? "เปลี่ยน" : "ไม่เปลี่ยน", privacy: .public)")
        guard action.changed else {
            throw ScreenDriverError.nothingHappened(action: action.description)
        }
        return action
    }

    // MARK: - AX plumbing

    private static func read(_ element: AXUIElement, depth: Int) -> ScreenElement {
        // Bounded: a deeply nested SwiftUI hierarchy is a tree with thousands
        // of nodes, and a snapshot nobody can read is not evidence.
        let children: [ScreenElement] = depth >= 24 ? [] :
            (copyChildren(element).map { read($0, depth: depth + 1) })
        return describe(element, children: children)
    }

    private static func describe(_ element: AXUIElement,
                                 children: [ScreenElement] = []) -> ScreenElement {
        ScreenElement(role: string(element, kAXRoleAttribute) ?? "AXUnknown",
                      label: label(of: element),
                      value: string(element, kAXValueAttribute),
                      subrole: string(element, kAXSubroleAttribute),
                      centre: centre(of: element),
                      enabled: boolean(element, kAXEnabledAttribute) ?? true,
                      children: children)
    }

    /// What a screen reader would say, in the order it prefers: the description
    /// an author wrote, then the title, then the value.
    private static func label(of element: AXUIElement) -> String {
        string(element, kAXDescriptionAttribute)
            ?? string(element, kAXTitleAttribute)
            ?? string(element, kAXHelpAttribute)
            ?? ""
    }

    private static func walk(_ element: AXUIElement, depth: Int,
                             visit: (AXUIElement) -> Void) {
        visit(element)
        guard depth < 24 else { return }
        for child in copyChildren(element) { walk(child, depth: depth + 1, visit: visit) }
    }

    private static func copyChildren(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString,
                                            &value) == .success,
              let children = value as? [AXUIElement] else { return [] }
        return children
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func copyFirst(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return nil }
        return list.first
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func boolean(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private static func centre(of element: AXUIElement) -> ScreenElement.Point? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString,
                                            &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString,
                                            &sizeValue) == .success else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID(),
              AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return ScreenElement.Point(x: position.x + size.width / 2,
                                   y: position.y + size.height / 2)
    }

    // MARK: - CGEvent, only where AX cannot write

    private static func click(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    /// Types a string as characters rather than as key codes.
    ///
    /// Key codes are positions on a US keyboard; `ก` has none. Every character
    /// is posted as a unicode payload on an otherwise empty key event, which is
    /// how Thai text reaches a field at all — and it is why this driver can do
    /// what the AppleScript one could not.
    private static func typeUnicode(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        for character in text {
            var utf16 = Array(String(character).utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }
}

/// One thing the driver did, with the screen before and after it.
public struct ScreenAction: Sendable, Equatable {
    public let description: String
    public let before: ScreenSnapshot
    public let after: ScreenSnapshot
    /// Whether AX refused and a synthetic click or keystroke was used instead.
    /// Recorded because it is a signal about the *app*: a control that AX
    /// cannot press is a control somebody using VoiceOver cannot press either.
    public let usedFallbackClick: Bool

    public var changed: Bool { after.differs(from: before) }

    public init(description: String, before: ScreenSnapshot, after: ScreenSnapshot,
                usedFallbackClick: Bool) {
        self.description = description
        self.before = before
        self.after = after
        self.usedFallbackClick = usedFallbackClick
    }

    /// The evidence a QA reviewer reads (§23.3, P17.4).
    public var evidence: Evidence {
        let (added, removed) = after.changes(from: before)
        var parts = [description]
        if !added.isEmpty { parts.append("ขึ้นใหม่: " + added.prefix(3).joined(separator: " · ")) }
        if !removed.isEmpty { parts.append("หายไป: " + removed.prefix(3).joined(separator: " · ")) }
        if !changed { parts.append("หน้าจอไม่เปลี่ยนเลย") }
        if usedFallbackClick {
            parts.append("AX กดไม่ได้ ต้องใช้คลิก/คีย์บอร์ดแทน — ตัวควบคุมนี้คนใช้ VoiceOver ก็กดไม่ได้")
        }
        return Evidence(kind: .screenObservation,
                        summary: parts.joined(separator: " | "),
                        passed: changed)
    }
}
