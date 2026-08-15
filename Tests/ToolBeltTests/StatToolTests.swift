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
