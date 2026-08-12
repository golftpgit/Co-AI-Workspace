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
                   "linear_regression", "logistic_regression"],
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
                   "description": "ชื่อตัวแปรต้น ตามลำดับเดียวกับ predictors" }
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
}
