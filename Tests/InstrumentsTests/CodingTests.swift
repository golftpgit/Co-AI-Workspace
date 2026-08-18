import Testing
import Foundation
import AgentKit
@testable import Instruments

// P11.8's Done-when is "κ computed from two sets of codings whose answer is
// known", so the fixtures here are small enough to work out on paper — the same
// standard the ICC round set, one level up: `Agreement` was already checked
// against published examples, and what is checked here is the step that feeds it.

private let burden = Code(id: "cd_burden", name: Bilingual("ภาระงาน"),
                          definition: "ข้อความที่พูดถึงปริมาณงานต่อเวร")
private let team = Code(id: "cd_team", name: Bilingual("ความสัมพันธ์ในทีม"),
                        definition: "ข้อความที่พูดถึงการช่วยเหลือกัน")
private let pay = Code(id: "cd_pay", name: Bilingual("ค่าตอบแทน"),
                       definition: "ข้อความที่พูดถึงเงินเดือนหรือค่าเวร")

private func book(_ codes: [Code] = [burden, team, pay],
                  order: [String] = []) -> Codebook {
    Codebook(projectID: ProjectID("pj_q"), title: Bilingual("สมุดรหัส"),
             codes: codes, documentOrder: order)
}

private func units(_ count: Int, document: String = "doc1") -> [CodingUnit] {
    (0..<count).map {
        CodingUnit(id: "cu_\(document)_\($0)", documentID: document,
                   range: ($0 * 10)..<($0 * 10 + 10), text: "ช่วงที่ \($0)")
    }
}

private func coded(_ units: [CodingUnit], _ coder: String,
                   _ codes: [String?]) -> [CodeAssignment] {
    zip(units, codes).map { CodeAssignment(unitID: $0.id, coder: coder, codeID: $1) }
}

@Suite("intercoder agreement over codings")
struct CodingReliabilityTests {

    @Test("two coders who agree on everything score κ 1")
    func perfectAgreement() throws {
        let passages = units(6)
        let labels: [String?] = ["cd_burden", "cd_burden", "cd_team",
                                 "cd_team", "cd_pay", nil]
        let report = try #require(CodingAnalysis.reliability(
            units: passages,
            assignments: coded(passages, "ก", labels) + coded(passages, "ข", labels),
            codebook: book()))
        #expect(abs(report.overall.kappa - 1) < 1e-12)
        #expect(report.overall.observedAgreement == 1)
        #expect(report.comparableUnits == 6)
        #expect(report.incompleteUnits == 0)
        #expect(report.isSubstantial)
    }

    @Test("the worked 2×2 comes out at the figure it comes out at on paper")
    func knownKappa() throws {
        // Ten units, two categories. Both coders say A on 4, both say B on 3,
        // and they differ on the other 3 → Po = .70. Marginals: coder ก has
        // A 6 / B 4, coder ข has A 5 / B 5 → Pe = .6×.5 + .4×.5 = .50.
        // κ = (.70 − .50) / (1 − .50) = .40 — the same worked example
        // `Agreement` itself is pinned to, reached this time through the coding
        // layer rather than through two arrays of strings.
        let passages = units(10)
        let first: [String?] = ["cd_burden", "cd_burden", "cd_burden", "cd_burden",
                                "cd_burden", "cd_burden", "cd_team", "cd_team",
                                "cd_team", "cd_team"]
        let second: [String?] = ["cd_burden", "cd_burden", "cd_burden", "cd_burden",
                                 "cd_team", "cd_team", "cd_burden", "cd_team",
                                 "cd_team", "cd_team"]
        let report = try #require(CodingAnalysis.reliability(
            units: passages,
            assignments: coded(passages, "ก", first) + coded(passages, "ข", second),
            codebook: book()))
        #expect(abs(report.overall.observedAgreement - 0.70) < 1e-12)
        #expect(abs(report.overall.expectedAgreement - 0.50) < 1e-12)
        #expect(abs(report.overall.kappa - 0.40) < 1e-12)
    }

    @Test("a unit one coder never reached is left out and counted, not guessed at")
    func incompleteUnitsAreExcluded() throws {
        let passages = units(5)
        let full: [String?] = ["cd_burden", "cd_burden", "cd_team", "cd_team", "cd_pay"]
        var partial = coded(passages, "ข", full)
        partial.removeLast(2)          // coder ข stopped after three

        let report = try #require(CodingAnalysis.reliability(
            units: passages, assignments: coded(passages, "ก", full) + partial,
            codebook: book()))
        #expect(report.comparableUnits == 3)
        #expect(report.incompleteUnits == 2)
        #expect(report.summary.contains("2 units are left out"))
    }

    @Test("“none of these codes” is a decision two people can agree on")
    func noneIsACategory() throws {
        let passages = units(4)
        let labels: [String?] = [nil, nil, "cd_burden", "cd_burden"]
        let report = try #require(CodingAnalysis.reliability(
            units: passages,
            assignments: coded(passages, "ก", labels) + coded(passages, "ข", labels),
            codebook: book()))
        // Four units, perfect agreement — two of them on "this passage carries
        // none of the codes", which is a judgement, not a gap.
        #expect(report.comparableUnits == 4)
        #expect(report.incompleteUnits == 0)
        #expect(abs(report.overall.kappa - 1) < 1e-12)
    }

    @Test("the code they disagree about is named, not left to be hunted for")
    func perCodeKappaFindsTheWeakOne() throws {
        let passages = units(8)
        // They agree on burden and team, and disagree wherever pay appears.
        let first: [String?] = ["cd_burden", "cd_burden", "cd_team", "cd_team",
                                "cd_pay", "cd_pay", "cd_pay", "cd_pay"]
        let second: [String?] = ["cd_burden", "cd_burden", "cd_team", "cd_team",
                                 "cd_team", "cd_burden", "cd_team", "cd_burden"]
        let report = try #require(CodingAnalysis.reliability(
            units: passages,
            assignments: coded(passages, "ก", first) + coded(passages, "ข", second),
            codebook: book()))
        let weakest = try #require(report.perCode.min { $0.kappa < $1.kappa })
        #expect(weakest.codeID == "cd_pay")
        #expect(report.summary.contains("ค่าตอบแทน"))
        // And burden, which they never disagreed about, is not the one blamed.
        let burdenRow = try #require(report.perCode.first { $0.codeID == "cd_burden" })
        #expect(burdenRow.kappa > weakest.kappa)
    }

    @Test("a code that was defined and never used keeps its row")
    func unusedCodeIsStillReported() throws {
        let passages = units(4)
        let labels: [String?] = ["cd_burden", "cd_burden", "cd_team", "cd_team"]
        let report = try #require(CodingAnalysis.reliability(
            units: passages,
            assignments: coded(passages, "ก", labels) + coded(passages, "ข", labels),
            codebook: book()))
        let unused = try #require(report.perCode.first { $0.codeID == "cd_pay" })
        #expect(unused.applications == 0)
    }

    @Test("one coder is not a reliability study")
    func oneCoderRefused() {
        let passages = units(4)
        #expect(CodingAnalysis.reliability(
            units: passages,
            assignments: coded(passages, "ก", ["cd_burden", nil, nil, nil]),
            codebook: book()) == nil)
    }

    @Test("three coders get Fleiss rather than a pair picked out of the three")
    func threeCoders() throws {
        let passages = units(5)
        let labels: [String?] = ["cd_burden", "cd_team", "cd_team", "cd_pay", nil]
        let report = try #require(CodingAnalysis.reliability(
            units: passages,
            assignments: coded(passages, "ก", labels) + coded(passages, "ข", labels)
                + coded(passages, "ค", labels),
            codebook: book()))
        #expect(report.coders == ["ก", "ข", "ค"])
        #expect(report.overall.raters == 3)
        #expect(abs(report.overall.kappa - 1) < 1e-12)
    }
}

@Suite("saturation as a curve")
struct SaturationTests {

    private func interview(_ document: String, codes: [String?]) -> ([CodingUnit], [CodeAssignment]) {
        let passages = units(codes.count, document: document)
        return (passages, coded(passages, "ก", codes))
    }

    @Test("new codes stop appearing, and that is reported as an observation")
    func curveFlattens() {
        var allUnits: [CodingUnit] = []
        var allAssignments: [CodeAssignment] = []
        // Two new codes, then one, then nothing new three times over.
        let script: [(String, [String?])] = [
            ("doc1", ["cd_burden", "cd_team"]),
            ("doc2", ["cd_pay", "cd_burden"]),
            ("doc3", ["cd_burden", "cd_team"]),
            ("doc4", ["cd_pay", "cd_team"]),
            ("doc5", ["cd_burden", "cd_pay"]),
        ]
        for (document, codes) in script {
            let (units, assignments) = interview(document, codes: codes)
            allUnits += units
            allAssignments += assignments
        }

        let curve = CodingAnalysis.saturation(units: allUnits, assignments: allAssignments,
                                              order: script.map(\.0))
        #expect(curve.points.count == 5)
        #expect(curve.points[0].newCodes == 2)
        #expect(curve.points[1].newCodes == 1)
        #expect(curve.points[2].newCodes == 0)
        #expect(curve.points.last?.cumulative == 3)
        #expect(curve.flattenedAfter(consecutive: 3) == 2)
        // The wording refuses to call it saturation, which is the researcher's
        // claim to make and defend.
        #expect(curve.summary.contains("an observation, not a finding of saturation"))
    }

    @Test("a curve still climbing says so rather than reporting nothing")
    func curveStillClimbing() {
        let (units1, assignments1) = interview("doc1", codes: ["cd_burden"])
        let (units2, assignments2) = interview("doc2", codes: ["cd_team"])
        let (units3, assignments3) = interview("doc3", codes: ["cd_pay"])
        let curve = CodingAnalysis.saturation(units: units1 + units2 + units3,
                                              assignments: assignments1 + assignments2 + assignments3,
                                              order: ["doc1", "doc2", "doc3"])
        #expect(curve.flattenedAfter() == nil)
        #expect(curve.summary.contains("new codes are still appearing"))
    }

    @Test("documents the codebook never ordered still appear, in the order they were coded")
    func unorderedDocumentsStillCounted() {
        let (units1, assignments1) = interview("doc1", codes: ["cd_burden"])
        let (units2, assignments2) = interview("doc2", codes: ["cd_team"])
        let curve = CodingAnalysis.saturation(units: units1 + units2,
                                              assignments: assignments1 + assignments2,
                                              order: [])
        #expect(curve.points.map(\.documentID) == ["doc1", "doc2"])
        #expect(curve.points.last?.cumulative == 2)
    }
}

@Suite("the codebook itself")
struct CodebookTests {

    @Test("a code with no definition is reported, and saving is still allowed")
    func undefinedCodeReported() {
        let vague = Code(id: "cd_x", name: Bilingual("ความรู้สึก"))
        let codebook = book([burden, vague])
        #expect(codebook.problems.count == 1)
        #expect(codebook.problems[0].text.contains("has no definition"))
        // Reported, not refused: half-finished work has to be saveable.
        #expect(codebook.codes.count == 2)
    }

    @Test("an axial code pointing at a parent that is not there is reported")
    func danglingParent() {
        let orphan = Code(id: "cd_y", name: Bilingual("เวรดึก"),
                          definition: "ข้อความเรื่องเวรกลางคืน", parentID: "cd_missing")
        #expect(book([orphan]).problems.contains { $0.text.contains("points at a parent code that is not in the codebook") })
    }

    @Test("a well-formed codebook has nothing to report")
    func clean() {
        let child = Code(id: "cd_night", name: Bilingual("เวรดึก"),
                         definition: "ข้อความเรื่องเวรกลางคืน", parentID: burden.id)
        #expect(book([burden, team, pay, child]).problems.isEmpty)
    }
}
