import Testing
import Foundation
import AgentKit
@testable import ScreenDriver

// ─────────────────────────────────────────────────────────────
// P17.1/P17.4 — finding a control by the name a screen reader says, and
// proving the screen changed.
//
// These run against snapshots rather than a live window, which is the point of
// the snapshot being a value: the finding rules and the evidence rules are
// decidable without accessibility permission, a running app or a display.
// Everything that genuinely needs those is in `AXNavigator` and is driven by
// hand — and the plan says so rather than pretending otherwise.
// ─────────────────────────────────────────────────────────────

private func window(_ children: [ScreenElement], title: String = "Co-AI Workspace")
    -> ScreenSnapshot {
    ScreenSnapshot(takenAt: Date(timeIntervalSince1970: 1_770_000_000),
                   windowTitle: title,
                   root: ScreenElement(role: "AXWindow", label: title, children: children))
}

private let planScreen = window([
    ScreenElement(role: "AXButton", label: "สร้างโปรเจกต์",
                  centre: .init(x: 100, y: 200)),
    ScreenElement(role: "AXStaticText", label: "สร้างโปรเจกต์แล้วจะเข้าขั้นเริ่มต้น"),
    ScreenElement(role: "AXTextField", label: "ชื่อโปรเจกต์", value: ""),
    ScreenElement(role: "AXButton", label: "บันทึก", enabled: false),
])

@Suite("Finding a control the way a screen reader does")
struct ElementFinderTests {

    @Test("a button is found by the words its label contains")
    func findsByLabel() throws {
        let found = try ElementFinder.find(.button("สร้างโปรเจกต์"), in: planScreen)
        #expect(found.role == "AXButton")
        // The static text says the same words. Without the role, "find the
        // thing that says สร้างโปรเจกต์" is two things.
        #expect(found.centre?.x == 100)
    }

    @Test("a label shared by a button and a caption is ambiguous, not first-wins")
    func ambiguityIsRefused() {
        // A driver that silently takes the first of two matches writes a test
        // that passes while pressing the wrong control, which is worse than no
        // test at all.
        #expect(throws: ScreenDriverError.self) {
            _ = try ElementFinder.find(ElementQuery(label: .contains("สร้างโปรเจกต์")),
                                       in: planScreen)
        }
    }

    @Test("a control that is not there says what was there instead")
    func missingControlNamesWhatItSaw() {
        do {
            _ = try ElementFinder.find(.button("ส่งออก"), in: planScreen)
            Issue.record("a missing button was not reported")
        } catch let error as ScreenDriverError {
            #expect("\(error)".contains("หาไม่เจอ") || "\(error)".contains("หา"))
            // The list of what *is* on screen is the difference between a
            // failure somebody can act on and "element not found".
            #expect("\(error)".contains("สร้างโปรเจกต์"))
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    /// A disabled Save button and a missing Save button send a person to two
    /// completely different places: one is the app saying "not yet", the other
    /// is the driver looking in the wrong window.
    @Test("a disabled control is reported as disabled, not as missing")
    func disabledIsNotMissing() {
        do {
            _ = try ElementFinder.find(.button("บันทึก"), in: planScreen)
            Issue.record("a disabled button was treated as pressable")
        } catch let error as ScreenDriverError {
            #expect(error == .disabled(label: "บันทึก"))
            #expect("\(error)".contains("หน้าจอกำลังบอกว่ายังทำสิ่งนี้ไม่ได้"))
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("a field is found by its label and can be told apart from its value")
    func findsFields() throws {
        let field = try ElementFinder.find(.field("ชื่อโปรเจกต์"), in: planScreen)
        #expect(field.value == "")
    }
}

@Suite("Evidence that the screen changed")
struct ScreenEvidenceTests {

    @Test("a screen that did not change is not evidence that something happened")
    func nothingHappenedIsNotSuccess() {
        let action = ScreenAction(description: "กด สร้างโปรเจกต์",
                                  before: planScreen, after: planScreen,
                                  usedFallbackClick: false)
        #expect(action.changed == false)
        // §2.5's rule, applied to the driver: the claim is "I pressed it", and
        // the evidence has to be able to say no.
        #expect(action.evidence.passed == false)
        #expect(action.evidence.kind == .screenObservation)
        #expect(action.evidence.summary.contains("หน้าจอไม่เปลี่ยนเลย"))
    }

    @Test("what changed is named, not just that something did")
    func changesAreNamed() {
        let after = window([
            ScreenElement(role: "AXButton", label: "สร้างโปรเจกต์"),
            ScreenElement(role: "AXTextField", label: "ชื่อโปรเจกต์", value: "งานวิจัยพยาบาล"),
            ScreenElement(role: "AXButton", label: "บันทึก"),
        ])
        let action = ScreenAction(description: "พิมพ์ชื่อโปรเจกต์",
                                  before: planScreen, after: after,
                                  usedFallbackClick: false)
        #expect(action.changed)
        #expect(action.evidence.passed)
        #expect(action.evidence.summary.contains("งานวิจัยพยาบาล"))
    }

    @Test("a window that only moved has not changed")
    func movingIsNotChanging() {
        // Positions are deliberately not part of the comparison: a window
        // dragged two pixels would otherwise count as evidence that a button
        // worked.
        let moved = window([
            ScreenElement(role: "AXButton", label: "สร้างโปรเจกต์",
                          centre: .init(x: 900, y: 640)),
            ScreenElement(role: "AXStaticText", label: "สร้างโปรเจกต์แล้วจะเข้าขั้นเริ่มต้น"),
            ScreenElement(role: "AXTextField", label: "ชื่อโปรเจกต์", value: ""),
            ScreenElement(role: "AXButton", label: "บันทึก", enabled: false),
        ])
        #expect(moved.differs(from: planScreen) == false)
    }

    /// A control AX cannot press is a control VoiceOver cannot press. The
    /// driver still gets its job done through a synthetic click, and the
    /// evidence says so — otherwise the accessibility defect is invisible
    /// precisely because the workaround worked.
    @Test("falling back to a synthetic click is reported as an accessibility finding")
    func fallbackIsReported() {
        let after = window([ScreenElement(role: "AXButton", label: "สร้างโปรเจกต์"),
                            ScreenElement(role: "AXStaticText", label: "สร้างแล้ว")])
        let action = ScreenAction(description: "กด สร้างโปรเจกต์",
                                  before: planScreen, after: after,
                                  usedFallbackClick: true)
        #expect(action.evidence.passed)
        #expect(action.evidence.summary.contains("VoiceOver ก็กดไม่ได้"))
    }
}
