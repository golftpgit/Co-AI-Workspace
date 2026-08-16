import Testing
import Foundation
import AgentKit
@testable import CoreEngine
@testable import ToolBelt

// ─────────────────────────────────────────────────────────────
// The Statistical Verification Gate, reached the way the Analyst reaches it
// (ARCHITECTURE §12.3, P6.6).
//
// Through `ToolGateway`, not by calling `StatGate` directly: §12.3 describes a
// hook on the Analyst's work, and a gate that only its own unit tests can run
// is the D6 mistake again.
// ─────────────────────────────────────────────────────────────

private let skewed = "[1,1,1,2,2,2,3,3,4,5,8,14,27,61,140]"

private func run(_ arguments: String) async throws -> String {
    let gateway = ToolGateway(modes: OperatingModes(autonomy: .fullAutonomous))
    await gateway.register(StatTestTool())
    let outcome = try await gateway.call("run_stat_test",
                                         argumentsJSON: arguments,
                                         context: ToolContext(scope: .central))
    guard case .executed(let output, _, _) = outcome else {
        Issue.record("run_stat_test did not run: \(outcome)")
        return ""
    }
    return output.text
}

@Suite("The stat gate reaches the Analyst")
struct StatToolTests {

    // P19.1/P19.2 — the epidemiological measures, reached the same way. A
    // capability only its own unit tests can call is the D6 mistake, and these
    // are the measures a medical paper is actually written in.
    @Test("the trial's risk ratio comes back through the tool, interval attached")
    func riskRatioThroughTheTool() async throws {
        // Physicians' Health Study: 104/11,037 on aspirin, 189/11,034 on placebo.
        let text = try await run("""
        {"test": "risk_ratio", "table": [[104, 10933], [189, 10845]]}
        """)
        #expect(text.contains("0.5501"))
        #expect(text.contains("95% CI"), "a point estimate reached the caller with no interval")
        #expect(text.contains("Katz"))
    }

    @Test("an NNT whose interval crosses zero is refused through the tool too")
    func nntRefusedThroughTheTool() async {
        // The refusal has to survive the trip: this is the number that gets
        // quoted in an abstract.
        await #expect(throws: (any Error).self) {
            _ = try await run("""
            {"test": "nnt", "table": [[50, 450], [55, 445]]}
            """)
        }
    }

    @Test("diagnostic accuracy will not answer without a prevalence")
    func diagnosticNeedsPrevalence() async {
        await #expect(throws: (any Error).self) {
            _ = try await run("""
            {"test": "diagnostic_accuracy", "table": [[45, 5], [95, 855]]}
            """)
        }
    }

    /// P19.3 through the path the Analyst uses, censoring included: the tool
    /// asks for the censoring flags explicitly rather than inferring them,
    /// because inferring them is how a censored subject silently becomes an
    /// event.
    @Test("a survival comparison comes back with the PH assumption attached")
    func survivalThroughTheTool() async throws {
        let text = try await run("""
        {"test": "survival",
         "times":  [[6,6,6,6,7,9,10,10,11,13,16,17,19,20,22,23,25,32,32,34,35],
                    [1,1,2,2,3,4,4,5,5,8,8,8,8,11,11,12,12,15,17,22,23]],
         "events": [[1,1,1,0,1,0,1,0,0,1,1,0,0,0,1,1,0,0,0,0,0],
                    [1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1]]}
        """)
        // Freireich: χ² 16.79, HR about 4.5 the other way round — the tool is
        // given 6-MP first, so the ratio is its inverse.
        #expect(text.contains("16.79"))
        #expect(text.contains("HR ="))
        #expect(text.contains("proportional hazards"))
    }

    @Test("a survival call with mismatched censoring flags is refused")
    func survivalNeedsMatchingFlags() async {
        await #expect(throws: (any Error).self) {
            _ = try await run("""
            {"test": "survival", "times": [[1,2,3],[4,5,6]], "events": [[1,1],[1,1,1]]}
            """)
        }
    }

    /// P19.4 — the warning has to survive the trip to the Analyst, because the
    /// Poisson result on its own looks entirely reasonable.
    @Test("overdispersed counts come back with the warning and the alternative")
    func overdispersionReachesTheAnalyst() async throws {
        let text = try await run("""
        {"test": "count_regression",
         "y": [0,0,1,4,8,11,1,2,4,18,26,31,3,5,9,44,60,75],
         "predictors": [[0,0,0,0,0,0,1,1,1,1,1,1,2,2,2,2,2,2]],
         "names": ["กลุ่ม"]}
        """)
        #expect(text.contains("rate ratio"))
        #expect(text.contains("กระจายเกิน"))
        #expect(text.contains("negative binomial"))
        // And the standard "this result is not usable as it stands" line, which
        // is what stops a model quoting the number anyway.
        #expect(text.contains("ผลนี้ยังใช้สรุปไม่ได้ตามที่เป็นอยู่"))
    }

    /// P19.5 — clustered data through the Analyst's own path. The warning is
    /// the deliverable here: the estimate looks the same either way.
    @Test("clustered data comes back corrected, and says what the wrong interval was")
    func clusteringReachesTheAnalyst() async throws {
        let text = try await run("""
        {"test": "clustered", "groups": [[52,55,53,54,51],[68,71,69,70,72],[45,44,47,46,43],
                                          [61,63,60,62,64],[75,77,74,76,78],[57,58,56,59,55]]}
        """)
        #expect(text.contains("แก้ตามการจับกลุ่มแล้ว"))
        #expect(text.contains("ข้อมูลซ้อนชั้น"))
        #expect(text.contains("ผลนี้ยังใช้สรุปไม่ได้ตามที่เป็นอยู่"))
    }

    @Test("a predictive value arrives with the prevalence it depends on")
    func predictiveValuesCarryPrevalence() async throws {
        let text = try await run("""
        {"test": "diagnostic_accuracy", "table": [[45, 5], [95, 855]], "prevalence": 0.01}
        """)
        // 8%, from a test that is "90% accurate" both ways.
        #expect(text.contains("0.0833"))
        #expect(text.contains("0.0100"), "the prevalence the numbers depend on was not reported")
        #expect(text.contains("PPV/NPV เปลี่ยนตามความชุก"))
    }

    /// P6.6's Done-when, through the path the agent actually uses.
    @Test("a t-test on non-normal data comes back with the warning attached")
    func nonNormalTTest() async throws {
        let text = try await run("""
        {"test": "welch_t", "groups": [\(skewed), [2,2,3,3,4,4,5,6,9,15,28,62,141,200,400]]}
        """)
        #expect(text.contains("Shapiro–Wilk"))
        #expect(text.contains("Mann–Whitney"))
        #expect(text.contains("Analysis Plan"))
        // The p-value is in there, but it never arrives alone.
        #expect(text.contains("p = "))
    }

    /// The structural claim: there is no call that returns a statistic without
    /// its assumptions, because the report is the only output shape.
    @Test("even a clean result carries its assumption checks")
    func cleanResultStillReports() async throws {
        let text = try await run("""
        {"test": "anova", "groups": [[5,7,6,8,7,6,7,8,6,7], [9,11,10,12,11,10,11,12,10,11],
                                     [2,4,3,5,4,3,4,5,3,4]]}
        """)
        #expect(text.contains("ANOVA"))
        #expect(text.contains("การแจกแจงปกติ"))
        #expect(text.contains("ความแปรปรวนเท่ากัน"))
    }

    @Test("a chi-square with thin cells is sent to Fisher's exact")
    func thinCells() async throws {
        let text = try await run(#"{"test": "chi_square", "table": [[1,9],[8,2]]}"#)
        #expect(text.contains("Fisher"))
        #expect(text.contains("ต่ำกว่า 5"))
    }

    @Test("the proposed alternative can actually be run")
    func alternativeIsRunnable() async throws {
        let text = try await run(#"{"test": "fisher_exact", "table": [[3,1],[1,3]]}"#)
        #expect(text.contains("0.4857"))
    }

    @Test("regression reports VIF per predictor, by the caller's own names")
    func regressionNamesPredictors() async throws {
        let text = try await run("""
        {"test": "linear_regression",
         "y": [3.1, 4.2, 5.0, 6.3, 7.1, 8.2, 9.0, 10.3, 11.1, 12.2],
         "predictors": [[1,2,3,4,5,6,7,8,9,10], [2,4,7,8,10,12,14,17,18,20]],
         "names": ["อายุ", "น้ำหนัก"]}
        """)
        #expect(text.contains("VIF"))
        #expect(text.contains("อายุ"))
    }

    @Test("data that cannot support the test is refused, not answered")
    func refusesThinData() async throws {
        let gateway = ToolGateway(modes: OperatingModes(autonomy: .fullAutonomous))
        await gateway.register(StatTestTool())
        await #expect(throws: ToolError.self) {
            try await gateway.call("run_stat_test",
                                   argumentsJSON: #"{"test": "welch_t", "groups": [[1],[2,3]]}"#,
                                   context: ToolContext(scope: .central))
        }
    }
}
