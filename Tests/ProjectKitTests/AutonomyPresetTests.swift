import Testing
@testable import ProjectKit

// ─────────────────────────────────────────────────────────────
// Moving the autonomy slider and the six numbers under it (§5.5, P10.6).
//
// The slider and the tolerance frame have described the same thing since both
// were written — the presets are even named after the slider's positions — and
// nothing connected them, so moving the slider left the numbers where they
// were and the two halves of the screen disagreed about how much rope the team
// has.
//
// Connecting them has one hazard, and it is the reason this is a rule rather
// than an assignment: **a project may have hand-tuned limits**, and a slider
// that overwrote them would throw away numbers somebody chose deliberately —
// silently, because the slider is not where they are looking. So:
//
//  • **A frame that still matches a preset follows the slider.** Nothing is
//    lost, because there was nothing there but a preset.
//  • **A frame somebody has edited is left alone**, and the mismatch is
//    reported so the screen can say the two no longer agree. A person can then
//    apply the preset on purpose, which is a different act from moving a
//    slider and is worth being a different act.
//
// `matchingPreset` is what makes the distinction possible, and it is exact
// equality on all six axes rather than a flag: a stored "which preset was
// chosen" would go stale the moment somebody edited one number, and would then
// authorise overwriting the other five.
// ─────────────────────────────────────────────────────────────

@Suite("The autonomy slider and the tolerance frame")
struct AutonomyPresetTests {

    @Test("each preset recognises itself, and only itself")
    func presetsAreRecognisable() {
        for preset in Tolerances.Preset.allCases {
            #expect(Tolerances.preset(preset).matchingPreset == preset)
        }
        #expect(Tolerances.balanced.matchingPreset != .fullAutonomous)
    }

    @Test("a hand-tuned frame matches no preset")
    func editedFramesAreNotPresets() {
        var tuned = Tolerances.balanced
        // One axis, and only one: the point is that a single deliberate edit is
        // enough to stop the slider rewriting the other five.
        tuned.limits[.cost] = 750
        #expect(tuned.matchingPreset == nil)
    }

    @Test("moving the slider carries an untouched frame with it")
    func untouchedFrameFollows() {
        let moved = Tolerances.balanced.following(.fullAutonomous)
        #expect(moved == .fullAutonomous)
        #expect(moved.limit(.cost) == 2_000)
    }

    @Test("moving the slider does not silently rewrite numbers somebody chose")
    func editedFrameIsLeftAlone() {
        var tuned = Tolerances.balanced
        tuned.limits[.cost] = 750
        let after = tuned.following(.fullAutonomous)
        #expect(after == tuned, "กรอบที่คนตั้งเองต้องไม่ถูกสไลเดอร์เขียนทับเงียบ ๆ")
        #expect(after.limit(.cost) == 750)
    }

    @Test("the screen can tell that the slider and the numbers disagree")
    func disagreementIsReportable() {
        var tuned = Tolerances.balanced
        tuned.limits[.risk] = 2
        // Nil means "these numbers are nobody's preset", which is exactly what
        // has to reach the screen — a slider sitting at a position its own
        // numbers do not describe is the kind of quiet lie §2.5 is about.
        #expect(tuned.matchingPreset == nil)
        #expect(Tolerances.balanced.matchingPreset == .balanced)
    }
}
