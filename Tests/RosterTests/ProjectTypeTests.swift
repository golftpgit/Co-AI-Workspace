import Testing
import Foundation
import AgentKit
import ProjectKit
@testable import Roster

// ─────────────────────────────────────────────────────────────
// Project types as files (ARCHITECTURE §20.2, P11.1).
//
// The Done-when has two halves and the second is the one that lasts: creating a
// `research.quantitative` project gives the WBS, roster and gates the file says,
// **and there is no second parser**. The first half is checked by reading a real
// shipped file rather than a fixture, because a type file that parses in a test
// and not in the app is the failure this is meant to prevent.
// ─────────────────────────────────────────────────────────────

private let shippedTypes: URL = {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // RosterTests
        .deletingLastPathComponent()      // Tests
        .deletingLastPathComponent()      // repo root
        .appending(path: "Resources/project-types")
}()

private func parser() -> ManifestParser {
    ManifestParser(knownTools: [])
}

@Suite("Project type manifests")
struct ProjectTypeTests {

    @Test("a research project starts with the WBS, roster and gate its file names")
    func quantitativeResearchTypeLoads() throws {
        let url = shippedTypes.appending(path: "research-quantitative.md")
        let manifest = try parser().parseProjectType(
            try String(contentsOf: url, encoding: .utf8), source: url)

        #expect(manifest.type == "research.quantitative")
        // The head of the dotted name is what a `Project` actually stores.
        #expect(manifest.kind == .research)
        #expect(manifest.roles == [.teamLead, .researcher, .analyst, .writer, .reviewer])
        #expect(manifest.stages == [.initiation, .planning, .execution, .closing])

        // The gate §20.1 calls the strongest one in a research project.
        let gate = try #require(manifest.gates.first { $0.id == "G-instrument" })
        #expect(gate.after == "instrument.draft")
        #expect(gate.requires == ["content_validity_passed", "consent_approved", "ethics_recorded"])

        // And the plan it starts with is a real plan, not an empty list.
        let packages = WBSTemplate.packages(manifest.wbsTemplate,
                                            project: ProjectID("pj_test"))
        #expect(packages.count > 10)
        #expect(packages.contains { $0.title.contains("ตรวจความตรงเชิงเนื้อหา") })
        #expect(packages.contains { $0.title.contains("บทที่ 4") })
    }

    @Test("every shipped type loads, and each names a template that exists")
    func allShippedTypesLoad() throws {
        let (types, errors) = parser().loadProjectTypes(directory: shippedTypes)
        #expect(errors.isEmpty, "\(errors.map { String(describing: $0) })")
        // The six §20.2 lists.
        #expect(Set(types.map(\.type)) == ["research.quantitative", "research.qualitative",
                                           "research.mixed", "software", "analysis", "blank"])
        for type in types {
            // A template name with no template behind it would give a project an
            // empty plan and no complaint, which reads as a bug in the app.
            #expect(WBSTemplate.isKnown(type.wbsTemplate),
                    "\(type.type) asks for a template that does not exist: \(type.wbsTemplate ?? "")")
            #expect(!type.label.isEmpty)
            #expect(!type.roles.isEmpty)
        }
    }

    @Test("a starting plan is a draft, and the gate still refuses it")
    func startingPlansDoNotPassTheGateOnTheirOwn() throws {
        let project = ProjectID("pj_test")
        let packages = WBSTemplate.packages("research-5-chapter", project: project)
        let breakdown = WorkBreakdown(packages)
        // Nothing is tied to a line of the scope statement and nobody is
        // accountable yet, both of which G2 checks. A template that could pass
        // the planning gate by itself would be a plan nobody wrote.
        let problems = breakdown.problems(inScope: ["ตอบคำถามวิจัย"])
        #expect(problems.contains { $0.kind == .noScopeRef })
        #expect(problems.contains { $0.kind == .noAccountable })
    }

    @Test("a name that does not exist is a rejected file, not a smaller project")
    func unknownNamesAreRejected() {
        let base = """
        ---
        type: research.quantitative
        description: ทดสอบ
        """

        #expect(throws: ProjectTypeError.self) {
            try parser().parseProjectType(base + "\nroles: researcher, wizard\n---\n")
        }
        #expect(throws: ProjectTypeError.self) {
            try parser().parseProjectType(base + "\nstages: initiation, someday\n---\n")
        }
        #expect(throws: ProjectTypeError.self) {
            try parser().parseProjectType(
                base + "\nsuggest_tailoring_out: astrology | ไม่เกี่ยว\n---\n")
        }
        #expect(throws: ProjectTypeError.self) {
            try parser().parseProjectType("---\ntype: sorcery\ndescription: x\n---\n")
        }
        // A gate line the format cannot read is a rejected file too: a gate that
        // silently does not exist is the worst of the three outcomes.
        #expect(throws: ProjectTypeError.self) {
            try parser().parseProjectType(base + "\ngate: G-1 | after=x\n---\n")
        }
    }

    @Test("a project type cannot grade its own risk either")
    func riskIsStillNotDeclarable() {
        #expect(throws: ManifestError.self) {
            try parser().parseProjectType("""
            ---
            type: software
            description: ทดสอบ
            risk: low
            ---
            """)
        }
    }

    @Test("a manifest suggests tailoring; it cannot decide it")
    func tailoringIsSuggestedNotDecided() throws {
        let url = shippedTypes.appending(path: "research-quantitative.md")
        let manifest = try parser().parseProjectType(
            try String(contentsOf: url, encoding: .utf8), source: url)

        let suggestion = try #require(manifest.suggestedTailoring.first { $0.practice == .procurement })
        #expect(!suggestion.reason.isEmpty)

        // §19.15: dropping an assurance practice is a governance decision with a
        // person's name on it. The suggestion carries the reason; the record
        // still refuses to exist without somebody signing for it — which is what
        // stops a file from quietly removing a practice.
        #expect(throws: TailoringError.emptyDecider) {
            _ = try TailoringRecord.decided(projectID: ProjectID("pj_test"),
                                            practice: suggestion.practice,
                                            reason: suggestion.reason,
                                            by: "  ")
        }
        let record = try TailoringRecord.decided(projectID: ProjectID("pj_test"),
                                                 practice: suggestion.practice,
                                                 reason: suggestion.reason,
                                                 by: "ผู้วิจัย")
        #expect(record.decidedBy == "ผู้วิจัย")
    }

    @Test("repeating a key is how this format writes a list, and it reads them all")
    func repeatedKeysAreKept() throws {
        let manifest = try parser().parseProjectType("""
        ---
        type: research.mixed
        description: ทดสอบ
        gate: G-a | after=one | requires=x
        gate: G-b | after=two | requires=y, z
        ---
        """)
        // The flat format §7.2 chose keeps every value for a repeated key, which
        // is what let project types have gates without a second parser.
        #expect(manifest.gates.map(\.id) == ["G-a", "G-b"])
        #expect(manifest.gates[1].requires == ["y", "z"])
    }

    @Test("agent and skill manifests still read the last value for a repeated key")
    func flatManifestsAreUnchanged() throws {
        // The shared reader now collects every value. Agents and skills take the
        // last one, exactly as before — this pins that the change did not alter
        // the format they have always used.
        let manifest = try ManifestParser(knownTools: ["kb_search"]).parse("""
        ---
        name: tester
        description: first
        description: second
        tools: kb_search
        ---
        body
        """, kind: .agent)
        #expect(manifest.description == "second")
    }
}
