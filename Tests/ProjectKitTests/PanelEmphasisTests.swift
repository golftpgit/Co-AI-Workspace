import Testing
import Foundation
import AgentKit
@testable import ProjectKit

// ─────────────────────────────────────────────────────────────
// P20.6 — the screen leans on what the person declared, and on nothing else.
//
// Half of these tests are about what emphasis *does*; the other half are about
// what it must never learn to do. The second half is the part that would rot
// quietly: usage-based adaptation is one plausible commit away at any time,
// and it reads like an improvement in the diff.
// ─────────────────────────────────────────────────────────────

@Suite("Emphasis follows the declared project type (P20.6)")
struct PanelEmphasisTests {

    /// The Done-when: switch the type, and a different set of panels is in
    /// front.
    @Test("each kind emphasises a different set")
    func kindsDiffer() {
        let research = Set(PanelEmphasis.panels(for: .research))
        let software = Set(PanelEmphasis.panels(for: .software))
        let analysis = Set(PanelEmphasis.panels(for: .analysis))

        #expect(research != software)
        #expect(software != analysis)
        #expect(research != analysis)
        #expect(research.contains(.documents))
        #expect(software.contains(.coding))
        #expect(analysis.contains(.internalDB))
        // Writing code is not what a research project is doing, and a panel
        // emphasised everywhere is emphasis that says nothing.
        #expect(research.contains(.coding) == false)
    }

    /// A project nobody classified gets no opinion — including no opinion
    /// inferred from its name, which would be the same guessing in a hat.
    @Test("an unclassified project is not guessed at")
    func blankGetsNoOpinion() {
        #expect(PanelEmphasis.panels(for: .blank).isEmpty)
        #expect(PanelEmphasis.opening(for: .blank) == nil)
        #expect(PanelEmphasis.reason(for: .blank) == nil)
    }

    @Test("the panel that opens is one of the panels that were marked")
    func openingIsEmphasised() {
        for kind in ProjectKind.allCases {
            guard let opening = PanelEmphasis.opening(for: kind) else { continue }
            #expect(PanelEmphasis.isEmphasised(opening, in: kind),
                    "\(kind) opens on a panel it did not mark")
        }
    }

    /// The refusal, as a property rather than a promise in a comment: the only
    /// thing that can change the answer is the kind. Same kind called a hundred
    /// times, at any point in a session, gives the same list — there is no
    /// counter inside to warm up.
    @Test("emphasis depends on the declared kind and nothing else")
    func emphasisIsAFunctionOfTheKindAlone() {
        for kind in ProjectKind.allCases {
            let first = PanelEmphasis.panels(for: kind)
            for _ in 0..<100 {
                #expect(PanelEmphasis.panels(for: kind) == first)
            }
        }
    }

    /// A person has to be able to account for what they are seeing. "Why is
    /// this one highlighted" with no answer is indistinguishable from a bug.
    @Test("the emphasis says where it came from, in words")
    func reasonNamesTheSource() {
        let reason = PanelEmphasis.reason(for: .research)
        #expect(reason?.contains("research") == true)
        #expect(reason?.contains("not adjusted by how you use it") == true)
    }

    /// Emphasis marks panels; it does not invent them. A name here that the
    /// app no longer draws would be a highlight on nothing — `check.sh` holds
    /// the other end of this, against the app's own tab identifiers.
    @Test("every emphasised panel is a panel that exists")
    func panelsAreRealPanels() {
        let known = Set(WorkspacePanel.allCases)
        for kind in ProjectKind.allCases {
            #expect(Set(PanelEmphasis.panels(for: kind)).isSubset(of: known))
        }
    }
}
