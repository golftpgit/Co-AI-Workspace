import Testing
import Foundation
import AgentKit
@testable import ProjectKit

// The gates a project type declares (§20.2), which were data until now. What is
// pinned here is the three-way answer — enforced, honestly unchecked, or refused
// as unknown — because collapsing any two of them is how the `gate:` line goes
// back to being decorative.

private let instrumentGate = ProjectTypeGate(
    id: "G-instrument", after: "instrument.draft",
    requires: ["content_validity_passed", "consent_approved", "ethics_recorded"])

/// A project sitting at the execution boundary with everything else in order,
/// so the only thing that can fail is the type's own gate.
private func readyToClose() -> (Project, WorkBreakdown) {
    var project = Project(name: "การคงอยู่ของพยาบาล", kind: .research,
                          typeName: "research.quantitative",
                          brief: "ทำไมพยาบาลลาออก",
                          statement: ScopeStatement(inScope: ["สำรวจ"],
                                                    outOfScope: ["สัมภาษณ์เชิงลึก"],
                                                    acceptanceCriteria: ["ได้ผลสำรวจ"]))
    project.stage = .execution
    return (project, WorkBreakdown())
}

@Suite("gates a project type declares")
struct TypeGateTests {

    @Test("a condition the system can answer blocks the stage while it is false")
    func answerableBlocks() throws {
        let (project, wbs) = readyToClose()
        let unmet = try #require(ProjectLifecycle.evaluate(
            project, wbs: wbs,
            typeGates: [instrumentGate],
            typeFacts: TypeGateFacts(known: ["content_validity_passed": false,
                                             "consent_approved": true,
                                             "ethics_recorded": true])))
        #expect(!unmet.passed)
        #expect(unmet.unmet.count == 1)
        #expect(unmet.unmet[0].contains("content_validity_passed"))
        // The gate says which gate and which milestone, so the sentence points
        // at the thing to go and do.
        #expect(unmet.unmet[0].contains("G-instrument"))
        #expect(unmet.unmet[0].contains("instrument.draft"))
    }

    @Test("and lets it through once the answer is yes")
    func answerablePasses() throws {
        let (project, wbs) = readyToClose()
        let met = try #require(ProjectLifecycle.evaluate(
            project, wbs: wbs,
            typeGates: [instrumentGate],
            typeFacts: TypeGateFacts(known: ["content_validity_passed": true,
                                             "consent_approved": true,
                                             "ethics_recorded": true])))
        #expect(met.passed)
    }

    @Test("a project type with no declared gates behaves exactly as before")
    func noGatesNoChange() throws {
        let (project, wbs) = readyToClose()
        let plain = try #require(ProjectLifecycle.evaluate(project, wbs: wbs))
        let withEmpty = try #require(ProjectLifecycle.evaluate(
            project, wbs: wbs, typeGates: [], typeFacts: TypeGateFacts()))
        #expect(plain.conditions == withEmpty.conditions)
        #expect(plain.passed)
    }

    @Test("a condition no build can answer yet is unchecked, not passed, and does not wall the project in")
    func namedGapIsVacuous() throws {
        var project = readyToClose().0
        project.typeName = "research.qualitative"
        // `saturation_reached` is the standing example: P11.8 computes the curve,
        // but declaring saturation is the researcher's conclusion, so no build
        // will ever answer it.
        let saturation = ProjectTypeGate(id: "G-saturation", after: "coding.round",
                                         requires: ["saturation_reached"])
        let evaluation = try #require(ProjectLifecycle.evaluate(
            project, wbs: WorkBreakdown(), typeGates: [saturation]))

        // It passes — four of the six shipped types would otherwise be unable to
        // leave execution at all, which is a bug wearing rigour's clothes.
        #expect(evaluation.passed)
        // And it is marked as unchecked, so nothing reads as confirmed.
        let theirs = evaluation.conditions.filter { $0.text.contains("G-saturation") }
        #expect(theirs.count == 1)
        #expect(theirs.count { $0.vacuous } == 1)
        #expect(theirs[0].text.contains("this cannot be checked automatically"))
        // It names the phase rather than saying "later".
        #expect(theirs[0].text.contains("P11.8"))
    }

    @Test("a condition the build can check but nobody ran blocks, and says which of the two it is")
    func answerableButUnaskedBlocks() throws {
        let (project, wbs) = readyToClose()
        let coding = ProjectTypeGate(id: "G-coding", after: "coding.round",
                                     requires: ["intercoder_agreement"])
        // No facts supplied — the reader is not wired, or could not reach its
        // store. That is not the same as an unrecognised word, and it must not
        // read as one: the two send somebody to different places.
        let evaluation = try #require(ProjectLifecycle.evaluate(
            project, wbs: wbs, typeGates: [coding]))
        #expect(!evaluation.passed)
        #expect(evaluation.unmet[0].contains("this can be checked but has not been"))
        #expect(!evaluation.unmet[0].contains("ไม่รู้จักเงื่อนไข"))
    }

    @Test("a condition nobody has heard of blocks, and says it does not know the word")
    func unknownConditionBlocks() throws {
        let (project, wbs) = readyToClose()
        let typo = ProjectTypeGate(id: "G-typo", after: "somewhere",
                                   requires: ["content_validty_passed"])
        let evaluation = try #require(ProjectLifecycle.evaluate(
            project, wbs: wbs, typeGates: [typo]))
        #expect(!evaluation.passed)
        #expect(evaluation.unmet[0].contains("this condition name is unknown"))
        #expect(evaluation.unmet[0].contains("content_validty_passed"))
    }

    @Test("one condition per requirement, not one per gate")
    func oneConditionPerRequirement() {
        let conditions = TypeGateConditions.conditions(
            for: [instrumentGate],
            facts: TypeGateFacts(known: ["content_validity_passed": true,
                                         "consent_approved": false,
                                         "ethics_recorded": false]))
        // Three rows, so a screen shows which two of the three are missing
        // instead of "G-instrument ยังไม่ผ่าน".
        #expect(conditions.count == 3)
        #expect(conditions.count { !$0.satisfied } == 2)
    }

    @Test("the gates only apply at the boundary out of execution")
    func onlyAtExecution() throws {
        var project = readyToClose().0
        project.stage = .initiation
        let evaluation = try #require(ProjectLifecycle.evaluate(
            project, typeGates: [instrumentGate],
            typeFacts: TypeGateFacts(known: ["content_validity_passed": false])))
        // G1 asks about a scope statement, not about instruments — a project
        // cannot be asked for content validity before it has planned to collect
        // anything.
        #expect(!evaluation.conditions.contains { $0.text.contains("G-instrument") })
    }

    @Test("every condition a shipped type file names is either answerable or a named gap")
    func shippedFilesAreAccountedFor() throws {
        // The file is the source of truth, so this reads it rather than a list.
        let root = #filePath.replacingOccurrences(
            of: "Tests/ProjectKitTests/TypeGateTests.swift", with: "")
        let directory = URL(fileURLWithPath: root + "Resources/project-types")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".md") }
        #expect(!files.isEmpty)

        var unaccounted: [String] = []
        for file in files {
            let text = try String(contentsOf: directory.appending(path: file), encoding: .utf8)
            for line in text.split(separator: "\n") where line.hasPrefix("gate:") {
                guard let requires = line.range(of: "requires=") else { continue }
                for name in line[requires.upperBound...].split(separator: ",") {
                    let condition = name.trimmingCharacters(in: .whitespaces)
                    if !TypeGateConditions.answerable.contains(condition),
                       TypeGateConditions.notAnswerableYet[condition] == nil {
                        unaccounted.append("\(file): \(condition)")
                    }
                }
            }
        }
        #expect(unaccounted.isEmpty, "\(unaccounted)")
    }
}
