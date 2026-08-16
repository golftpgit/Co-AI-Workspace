import Testing
import Foundation
import AgentKit
import ToolBelt
@testable import CoreEngine
@testable import Roster

// ─────────────────────────────────────────────────────────────
// The roster (ARCHITECTURE §7, P8.1/P8.2).
//
// Two Done-whens, and both are about refusal: a tool name that does not exist
// stops the manifest loading, and a manifest cannot talk its way past the gate
// by describing itself as safe.
// ─────────────────────────────────────────────────────────────

/// The tools a real gateway advertises. `base:` resolves against this, so it
/// has to contain everything `RoleTools` inherits — a fixture that lags the
/// role table makes every `base:` test fail for a reason that has nothing to do
/// with what it is testing. (It did, the day the four missing tools landed,
/// which is the invariant working.)
private let known: Set<String> = ["kb_search", "web_search", "fetch_page",
                                  "run_shell", "run_stat_test", "ingest_url",
                                  "analysis_query", "analysis_execute",
                                  "pull_db_table", "save_document", "raise_risk"]

private let risks: [String: RiskLevel] = [
    "kb_search": .low, "web_search": .low, "fetch_page": .low,
    "run_stat_test": .low, "analysis_query": .low, "run_shell": .high,
    "ingest_url": .medium, "analysis_execute": .medium,
    "pull_db_table": .medium, "save_document": .medium, "raise_risk": .medium,
]

private func parser() -> ManifestParser {
    ManifestParser(knownTools: known, toolRisks: risks)
}

private let legalReview = """
---
name: legal-review
description: Contract review persona — KB search + web search เท่านั้น ไม่มี shell
tools: kb_search, web_search
base: researcher
model_tier: 1
definition_of_done: ทุกข้อสรุปมี ≥2 source, tier 1-2 อย่างน้อย 1 แหล่ง
---

You are a contract-review assistant specializing in Thai commercial contracts...
"""

@Suite("Manifests")
struct ManifestTests {

    /// §7.2's own example, parsed field for field.
    @Test("the format from the spec parses, body and all")
    func parsesTheSpecExample() throws {
        let manifest = try parser().parse(legalReview, kind: .agent)
        #expect(manifest.name == "legal-review")
        #expect(manifest.description.contains("Contract review"))
        #expect(manifest.base == .researcher)
        #expect(manifest.modelTier == 1)
        #expect(manifest.definitionOfDone?.contains("≥2 source") == true)
        #expect(manifest.body.hasPrefix("You are a contract-review assistant"))
    }

    /// `base:` inherits the role's tools and the manifest adds to them, without
    /// listing anything twice.
    @Test("base inherits a tool set and the manifest's own list is added on top")
    func baseInheritance() throws {
        let manifest = try parser().parse(legalReview, kind: .agent)
        // `ingest_url` comes from the role, not from the file: a researcher may
        // put a page into the knowledge base so it can be cited later. So does
        // `raise_risk` (P10.8) — whoever notices a risk is who files it, and
        // that is a property of the role rather than of any one persona.
        #expect(manifest.tools.sorted()
                == ["fetch_page", "ingest_url", "kb_search", "raise_risk", "web_search"])
        #expect(manifest.tools.count == Set(manifest.tools).count)
        // And what the persona is *not* allowed to touch stays out.
        #expect(!manifest.tools.contains("run_shell"))
    }

    /// P8.1's Done-when. The unknown name has to be in the message: "invalid
    /// manifest" tells nobody which line to fix.
    @Test("a tool name that does not exist rejects the manifest, and names it")
    func unknownToolIsRejected() {
        let typo = """
        ---
        name: broken
        description: ทดสอบชื่อทูลผิด
        tools: kb_search, kb_serach
        ---
        body
        """
        do {
            _ = try parser().parse(typo, kind: .agent, source: URL(fileURLWithPath: "/a/broken.md"))
            Issue.record("a manifest naming a tool that does not exist must not load")
        } catch let error as ManifestError {
            #expect("\(error)".contains("kb_serach"))
            #expect("\(error)".contains("broken.md"))
            // And it says what does exist, so the fix is visible from the error.
            #expect("\(error)".contains("kb_search"))
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    /// P8.2's Done-when: the manifest that tries to grade itself.
    @Test("a manifest cannot declare its own risk or talk its way past the gate")
    func riskCannotBeDeclared() {
        for field in ["risk: low", "requires_approval: false", "bypass_gate: true",
                      "autonomy: full", "trusted: yes"] {
            let sneaky = """
            ---
            name: sneaky
            description: พยายามข้าม gate
            tools: run_shell
            \(field)
            ---
            body
            """
            do {
                _ = try parser().parse(sneaky, kind: .agent)
                Issue.record("'\(field)' should have been refused")
            } catch let error as ManifestError {
                #expect("\(error)".contains("คำนวณจากรายการทูล"))
            } catch {
                Issue.record("wrong error: \(error)")
            }
        }
    }

    /// And the positive half: the risk is what the tools make it, whatever the
    /// file would have preferred.
    @Test("risk is computed from the tools, so a shell agent is always gated")
    func riskFollowsTheTools() throws {
        // Tools listed rather than inherited, because the point here is the
        // arithmetic — read-only tools give a low ceiling and a capability that
        // never reaches the gate.
        let reader = try parser().parse("""
        ---
        name: reader
        description: อ่านอย่างเดียว
        tools: kb_search, web_search, fetch_page
        ---
        อ่านแล้วสรุป
        """, kind: .agent)
        let readerEntry = parser().entry(for: reader)
        #expect(readerEntry.riskCeiling == .low)
        #expect(!readerEntry.isRiskSensitive)

        // And `base: researcher` is *not* read-only any more, which is the
        // truthful consequence of giving that role `ingest_url`: writing into
        // the shared knowledge base is a write, and what goes in there is what
        // gets cited later (§5.3 grades it medium).
        let researcher = parser().entry(for: try parser().parse(legalReview, kind: .agent))
        #expect(researcher.riskCeiling == .medium)
        #expect(researcher.isRiskSensitive)

        let shell = try parser().parse("""
        ---
        name: builder
        description: รันคำสั่งได้
        tools: kb_search, run_shell
        ---
        body
        """, kind: .agent)
        let shellEntry = parser().entry(for: shell)
        #expect(shellEntry.riskCeiling == .high)
        #expect(shellEntry.isRiskSensitive)
    }

    /// §5.3's rule for an unrecognised tool, applied here too.
    @Test("a tool with no declared risk counts as High")
    func unknownRiskIsHigh() {
        let parser = ManifestParser(knownTools: ["mystery"], toolRisks: [:])
        #expect(parser.riskCeiling(for: ["mystery"]) == .high)
    }

    @Test("a file with no frontmatter, or with no name, is refused")
    func malformedManifests() {
        #expect(throws: ManifestError.self) {
            try parser().parse("just a body", kind: .skill)
        }
        #expect(throws: ManifestError.self) {
            try parser().parse("---\ndescription: ไม่มีชื่อ\n---\nbody", kind: .skill)
        }
        // A description is what the router and the UI pick from; without one a
        // capability is invisible even when it loads.
        #expect(throws: ManifestError.self) {
            try parser().parse("---\nname: nameless\n---\nbody", kind: .skill)
        }
    }

    @Test("an unknown base role is refused with the roles that exist")
    func unknownBase() {
        do {
            _ = try parser().parse("""
            ---
            name: x
            description: y
            base: wizard
            ---
            body
            """, kind: .agent)
            Issue.record("base: wizard should not load")
        } catch let error as ManifestError {
            #expect("\(error)".contains("researcher"))
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    // MARK: - loading a directory

    @Test("one broken file does not take the others down with it")
    func directoryLoadIsResilient() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "coai-roster-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try legalReview.write(to: directory.appending(path: "legal.md"),
                              atomically: true, encoding: .utf8)
        try "---\nname: broken\ndescription: d\ntools: nope\n---\nbody"
            .write(to: directory.appending(path: "broken.md"), atomically: true, encoding: .utf8)

        let (manifests, errors) = parser().load(directory: directory, kind: .agent)
        #expect(manifests.map(\.name) == ["legal-review"])
        #expect(errors.count == 1)
        #expect("\(errors[0])".contains("nope"))
    }

    /// Whichever of two same-named files wins would depend on directory order,
    /// which is not a decision anybody made.
    @Test("two files claiming the same name are both withdrawn, loudly")
    func duplicateNamesAreRefused() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "coai-roster-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let body = "---\nname: twin\ndescription: d\ntools: kb_search\n---\nbody"
        try body.write(to: directory.appending(path: "a.md"), atomically: true, encoding: .utf8)
        try body.write(to: directory.appending(path: "b.md"), atomically: true, encoding: .utf8)

        let (manifests, errors) = parser().load(directory: directory, kind: .agent)
        #expect(manifests.isEmpty)
        #expect(errors.count == 1)
        #expect("\(errors[0])".contains("twin"))
    }
}

@Suite("The roster's view of the system matches the system")
struct RosterFidelityTests {

    /// `base:` is only meaningful if the tool sets it inherits are the ones the
    /// specialists actually have. Roster cannot import CoreEngine — it must not
    /// be able to reach a tool — so the mirror is checked here, where both are
    /// visible, rather than trusted.
    @Test("the role→tool table matches the specialists it mirrors")
    func roleToolsMatchTheSpecialists() {
        for (role, expected) in SpecialistTools.byRole {
            #expect(Set(RoleTools.tools(for: role)) == expected,
                    "roster's tools for \(role.rawValue) have drifted from the specialist's")
        }
    }

    /// And the tool names the roster validates against are the ones the gateway
    /// really advertises.
    @Test("the built-in tool names are the ones a manifest is checked against")
    func toolNamesAreReal() async {
        let gateway = ToolGateway(modes: OperatingModes(autonomy: .fullAutonomous))
        await gateway.register([RunShellTool(registry: .init()), WebSearchTool(),
                                FetchPageTool(), StatTestTool()])
        let advertised = Set(await gateway.adverts.map(\.name))
        let unaccounted = advertised.subtracting(known)
        #expect(unaccounted.isEmpty, "a tool exists that these tests do not know about")
    }
}
