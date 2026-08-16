import Foundation
import AgentKit
import Analysis

// ─────────────────────────────────────────────────────────────
// The Statistical Verification Gate, as something the Analyst can reach
// (ARCHITECTURE §12.3, P6.6).
//
// §12.3 describes the gate as a PostToolUse hook: every statistical test gets
// its assumptions checked before the result enters the supervisor's context.
// The way that is made true here is that **the assumptions are not a second
// step**. This tool's output is `StatResult.report`, which always carries the
// checks, so there is no call that produces a p-value on its own and no order
// of operations that skips them.
//
// The Analyst's own Definition of Done already says "ผ่าน assumption check ของ
// สถิติที่ใช้" with evidence required (§2.5) — before this tool there was no way
// for it to produce that evidence except by shelling out to R and hoping.
// ─────────────────────────────────────────────────────────────

public struct StatTestTool: AgentTool {
    public let name = "run_stat_test"
    public let toolDescription = """
    รันการทดสอบทางสถิติพร้อมตรวจข้อสมมติของการทดสอบนั้นให้อัตโนมัติ (§12.3) — ผลลัพธ์จะมีทั้งค่าสถิติ \
    ค่า p และผลตรวจข้อสมมติเสมอ ถ้าข้อสมมติไม่ผ่าน ระบบจะเสนอวิธีทางเลือก (non-parametric) \
    และงานต้องกลับไปขออนุมัติที่ Analysis Plan ก่อนเปลี่ยนวิธี ห้ามสรุปผลจากค่า p โดยไม่อ่านผลตรวจข้อสมมติ
    """
    /// Arithmetic on numbers the caller already has: nothing is read, written
    /// or run. The gate still re-scores it — a tool does not get to decide its
    /// own risk (§5.3).
    public let riskLevel: RiskLevel = .low
    public let parametersJSON = """
    {
      "type": "object",
      "properties": {
        "test": {
          "type": "string",
          "enum": ["welch_t", "student_t", "paired_t", "anova", "chi_square",
                   "mann_whitney", "wilcoxon", "kruskal_wallis", "fisher_exact",
                   "linear_regression", "logistic_regression",
                   "risk_ratio", "odds_ratio", "risk_difference", "nnt",
                   "diagnostic_accuracy", "survival", "count_regression", "clustered", "meta_analysis",
                   "mcnemar", "chi_square_trend", "correlation", "spearman", "kappa"],
          "description": "ชนิดการทดสอบ"
        },
        "groups": {
          "type": "array",
          "items": { "type": "array", "items": { "type": "number" } },
          "description": "ข้อมูลรายกลุ่ม สำหรับ t-test/ANOVA/rank tests (paired_t และ wilcoxon ใช้ 2 กลุ่มที่จับคู่กัน)"
        },
        "table": {
          "type": "array",
          "items": { "type": "array", "items": { "type": "integer" } },
          "description": "ตารางความถี่ สำหรับ chi_square และ fisher_exact"
        },
        "y": { "type": "array", "items": { "type": "number" },
               "description": "ตัวแปรตาม สำหรับการถดถอย (logistic ต้องเป็น 0/1)" },
        "predictors": {
          "type": "array",
          "items": { "type": "array", "items": { "type": "number" } },
          "description": "ตัวแปรต้น หนึ่งรายการต่อหนึ่งตัวแปร"
        },
        "names": { "type": "array", "items": { "type": "string" },
                   "description": "ชื่อตัวแปรต้น ตามลำดับเดียวกับ predictors" },
        "effects": {
          "type": "array",
          "items": { "type": "number" },
          "description": "ขนาดผลของแต่ละงาน บนสเกลที่ผลต่างสมมาตร (log OR, log HR, ผลต่างค่าเฉลี่ย) สำหรับ meta_analysis"
        },
        "standard_errors": {
          "type": "array",
          "items": { "type": "number" },
          "description": "standard error ของแต่ละงาน เรียงตรงกับ effects"
        },
        "times": {
          "type": "array",
          "items": { "type": "array", "items": { "type": "number" } },
          "description": "เวลาติดตามรายกลุ่ม สำหรับ survival (สองกลุ่ม)"
        },
        "events": {
          "type": "array",
          "items": { "type": "array", "items": { "type": "number" } },
          "description": "1 = เกิดเหตุการณ์ · 0 = censored (ยังไม่เกิดจนหมดการติดตาม) — ต้องยาวเท่ากับ times ของกลุ่มเดียวกัน"
        },
        "prevalence": {
          "type": "number",
          "description": "ความชุกของโรค **ในประชากรที่จะใช้การทดสอบนี้จริง** (0-1) — จำเป็นสำหรับ diagnostic_accuracy เพราะ PPV/NPV ขึ้นกับความชุก ไม่ใช่คุณสมบัติของการทดสอบ"
        }
      },
      "required": ["test"]
    }
    """

    public init() {}

    public func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutput {
        let arguments = try Arguments(argumentsJSON)
        let test = try arguments.string("test")

        func groups() throws -> [[Double]] {
            let values = try arguments.matrix("groups")
            guard !values.isEmpty else {
                throw ToolError.invalidArguments("การทดสอบนี้ต้องมี 'groups'")
            }
            return values
        }
        func pair() throws -> ([Double], [Double]) {
            let values = try groups()
            guard values.count == 2 else {
                throw ToolError.invalidArguments("การทดสอบนี้ต้องมี 'groups' สองกลุ่มพอดี")
            }
            return (values[0], values[1])
        }
        func table() throws -> [[Int]] {
            let values = try arguments.matrix("table")
            guard !values.isEmpty else {
                throw ToolError.invalidArguments("การทดสอบนี้ต้องมี 'table'")
            }
            return values.map { $0.map { Int($0.rounded()) } }
        }
        func regression() throws -> ([Double], [[Double]], [String]) {
            let y = try arguments.numbers("y")
            let predictors = try arguments.matrix("predictors")
            guard !predictors.isEmpty else {
                throw ToolError.invalidArguments("การถดถอยต้องมี 'predictors' อย่างน้อยหนึ่งตัว")
            }
            return (y, predictors, arguments.strings("names"))
        }

        do {
            let result: StatResult
            switch test {
            case "welch_t":
                let (a, b) = try pair()
                result = try StatGate.twoSample(a, b)
            case "student_t":
                let (a, b) = try pair()
                result = try StatGate.twoSample(a, b, assumingEqualVariance: true)
            case "paired_t":
                let (a, b) = try pair()
                result = try StatGate.paired(a, b)
            case "anova":
                result = try StatGate.oneWayANOVA(try groups())
            case "chi_square":
                result = try StatGate.chiSquare(try table())
            case "fisher_exact":
                result = try StatGate.fisherExact(try table())
            // Bland ch. 13, 11–12 and 20 — the tests the gate could not offer.
            case "mcnemar":
                result = try StatGate.mcNemar(try table())
            case "chi_square_trend":
                let rows = try table()
                // Each row is one group: cases, then the rest of that group.
                result = try StatGate.chiSquareTrend(rows.map { row in
                    (cases: row.first ?? 0, total: row.reduce(0, +))
                })
            case "correlation", "spearman":
                let (a, b) = try pair()
                result = try StatGate.correlation(a, b,
                                                  kind: test == "spearman" ? .spearman : .pearson)
            case "kappa":
                let (a, b) = try pair()
                result = try StatGate.kappa(a.map { Int($0.rounded()) },
                                            b.map { Int($0.rounded()) })
            case "mann_whitney":
                let (a, b) = try pair()
                result = try StatGate.mannWhitney(a, b)
            case "wilcoxon":
                let (a, b) = try pair()
                result = try StatGate.wilcoxonSignedRank(a, b)
            case "kruskal_wallis":
                result = try StatGate.kruskalWallis(try groups())
            case "linear_regression":
                let (y, predictors, names) = try regression()
                result = try StatGate.linearRegression(y: y, predictors: predictors, names: names)
            case "logistic_regression":
                let (y, predictors, names) = try regression()
                result = try StatGate.logisticRegression(y: y, predictors: predictors, names: names)
            // §12.6.1's measures (P19.1/P19.2). Their own branch because they
            // do not produce a `StatResult`: there is no p-value and no
            // assumption to check — an estimate and its interval *is* the
            // answer, and wrapping them in a shape built for hypothesis tests
            // would invent a p-value for a thing that does not have one.
            case "risk_ratio", "odds_ratio", "risk_difference", "nnt":
                return ToolOutput(text: try Self.epidemiology(test, table: try table()))
            case "meta_analysis":
                let effects = try arguments.numbers("effects")
                let errors = try arguments.numbers("standard_errors")
                guard effects.count == errors.count else {
                    throw ToolError.invalidArguments("effects กับ standard_errors ยาวไม่เท่ากัน")
                }
                let studies = zip(effects, errors).enumerated().map {
                    StudyEffect(label: "งานที่ \($0.offset + 1)", effect: $0.element.0,
                                standardError: $0.element.1)
                }
                return ToolOutput(text: try Self.meta(studies))
            case "clustered":
                // `groups` is already "one array per group", which is what a
                // cluster is — so the shape needs no new argument, only the
                // question being asked of it.
                result = try StatGate.clustered(try groups())
            case "count_regression":
                // Counts go in `y` like any other outcome; what makes this its
                // own test is the assumption it checks, not its arguments.
                let (counts, predictors, names) = try regression()
                result = try StatGate.countRegression(counts, predictors: predictors,
                                                      names: names)
            case "survival":
                // Censoring is what makes this its own test rather than a
                // two-sample comparison of times, so the tool asks for it
                // explicitly rather than inferring it from anything.
                let times = try arguments.matrix("times")
                let events = try arguments.matrix("events")
                guard times.count == 2, events.count == 2,
                      times[0].count == events[0].count,
                      times[1].count == events[1].count else {
                    throw ToolError.invalidArguments(
                        "survival ต้องมี 'times' และ 'events' อย่างละสองกลุ่ม และยาวเท่ากันในกลุ่มเดียวกัน")
                }
                func group(_ index: Int) -> [SurvivalObservation] {
                    zip(times[index], events[index]).map {
                        SurvivalObservation(time: $0, event: $1 != 0)
                    }
                }
                result = try StatGate.survival(group(0), group(1))
            case "diagnostic_accuracy":
                return ToolOutput(text: try Self.diagnostic(
                    table: try table(),
                    prevalence: try arguments.number("prevalence")))
            default:
                throw ToolError.invalidArguments("ไม่รู้จักการทดสอบ '\(test)'")
            }

            // The report always carries the assumption checks; the extra line
            // is there so a model skimming the output cannot miss that this
            // result is not usable as it stands.
            var text = result.report
            if !result.isClean {
                text += "\n\nผลนี้ยังใช้สรุปไม่ได้ตามที่เป็นอยู่ — ข้อสมมติข้างบนมีข้อที่ไม่ผ่าน"
                    + "หรือยังตรวจไม่ได้"
                if result.requiresPlanReapproval {
                    text += " การเปลี่ยนไปใช้วิธีที่เสนอถือเป็นการเปลี่ยน methodology "
                        + "ต้องกลับไปอนุมัติที่ Analysis Plan ก่อน (§12.3)"
                }
            }
            return ToolOutput(text: text)
        } catch let error as StatError {
            throw ToolError.invalidArguments("\(error)")
        }
    }

    /// A 2×2 as `[[exposed cases, exposed non-cases], [unexposed cases,
    /// unexposed non-cases]]` — the order a textbook prints it in, said out
    /// loud in the error, because a transposed table inverts the conclusion
    /// without looking wrong.
    private static func twoByTwo(_ rows: [[Int]]) throws -> TwoByTwo {
        guard rows.count == 2, rows.allSatisfy({ $0.count == 2 }) else {
            throw ToolError.invalidArguments(
                "ต้องเป็นตาราง 2×2: [[ป่วย+สัมผัส, ไม่ป่วย+สัมผัส], [ป่วย+ไม่สัมผัส, ไม่ป่วย+ไม่สัมผัส]]")
        }
        return TwoByTwo(exposedCases: rows[0][0], exposedNonCases: rows[0][1],
                        unexposedCases: rows[1][0], unexposedNonCases: rows[1][1])
    }

    private static func line(_ label: String, _ estimate: Estimate) -> String {
        String(format: "%@: %.4f (95%% CI %.4f–%.4f · %@)",
               label, estimate.value, estimate.lower, estimate.upper, estimate.method)
    }

    private static func epidemiology(_ test: String, table rows: [[Int]]) throws -> String {
        let table = try twoByTwo(rows)
        switch test {
        case "risk_ratio": return line("RR", try Epidemiology.riskRatio(table))
        case "odds_ratio": return line("OR", try Epidemiology.oddsRatio(table))
        case "risk_difference": return line("RD", try Epidemiology.riskDifference(table))
        default: return line("NNT", try Epidemiology.numberNeededToTreat(table))
        }
    }

    /// A pooled estimate is never handed back on its own: heterogeneity and
    /// funnel asymmetry are the two facts that decide whether it means
    /// anything, and a model reading a bare number will quote the bare number
    /// (§12.6.1, P19.7).
    private static func meta(_ studies: [StudyEffect]) throws -> String {
        let random = try MetaAnalysis.pool(studies, model: .random)
        let fixed = try MetaAnalysis.pool(studies, model: .fixed)
        let spread = try MetaAnalysis.heterogeneity(studies)
        var lines = [
            String(format: "random effects: %.4f (95%% CI %.4f–%.4f · p = %.4g)",
                   random.effect, random.lower, random.upper, random.pValue),
            String(format: "fixed effect: %.4f (95%% CI %.4f–%.4f)",
                   fixed.effect, fixed.lower, fixed.upper),
            String(format: "Q = %.3f (df = %d, p = %.4g) · I² = %.1f%% · τ² = %.4f",
                   spread.q, spread.degreesOfFreedom, spread.pValue,
                   spread.iSquared, spread.tauSquared),
            spread.interpretation,
        ]
        // Fewer than three studies cannot be tested, and saying that is better
        // than leaving the line out — an absent line reads as a clean result.
        if let asymmetry = try? MetaAnalysis.funnelAsymmetry(studies) {
            lines.append(asymmetry.summary)
        } else {
            lines.append("งานน้อยเกินกว่าจะทดสอบความไม่สมมาตรของ funnel ได้")
        }
        return lines.joined(separator: "\n")
    }

    private static func diagnostic(table rows: [[Int]], prevalence: Double) throws -> String {
        guard rows.count == 2, rows.allSatisfy({ $0.count == 2 }) else {
            throw ToolError.invalidArguments(
                "ต้องเป็นตาราง 2×2: [[TP, FN], [FP, TN]]")
        }
        let table = DiagnosticTable(truePositives: rows[0][0], falseNegatives: rows[0][1],
                                    falsePositives: rows[1][0], trueNegatives: rows[1][1])
        let values = try DiagnosticAccuracy.predictiveValues(table, prevalence: prevalence)
        let ratios = try? DiagnosticAccuracy.likelihoodRatios(table)
        var text = [
            line("sensitivity", try DiagnosticAccuracy.sensitivity(table)),
            line("specificity", try DiagnosticAccuracy.specificity(table)),
            String(format: "PPV: %.4f · NPV: %.4f — **ที่ความชุก %.4f**",
                   values.positive, values.negative, values.atPrevalence),
        ]
        if let ratios {
            text.append(String(format: "LR+: %.3f · LR−: %.3f (ไม่ขึ้นกับความชุก)",
                               ratios.positive, ratios.negative))
        }
        // Said every time, because this is the sentence the numbers above are
        // most often read without: the predictive values are properties of the
        // test *and this population*, and quoting them elsewhere is wrong.
        text.append("PPV/NPV เปลี่ยนตามความชุก — ตัวเลขข้างบนใช้ได้เฉพาะกับประชากรที่มีความชุกตามที่ระบุ")
        return text.joined(separator: "\n")
    }
}
