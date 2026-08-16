import Testing
import Foundation
import AgentKit
import Analysis
import RBridge
@testable import ToolBelt

// ─────────────────────────────────────────────────────────────
// P14.2 / P14.3 — R goes through the same door, and its answers become part of
// the analysis rather than a wall of printed text.
//
// The frame used below is the one the real bridge returned on this machine
// (E.28), including the `NA`. The DuckDB half runs against real DuckDB: an
// import that is only tested against a mock is an import that has never met a
// type inference.
// ─────────────────────────────────────────────────────────────

private let liveFrame = RFrame(
    columns: ["id", "name", "value"],
    types: ["integer", "character", "numeric"],
    rows: [["1", "a", "1.5"], ["2", nil, "2.5"], ["3", "c", "3.5"]])

private func context() -> ToolContext { ToolContext(scope: .central, role: .analyst) }

@Suite("r_eval goes through the gate (P14.2)")
struct REvalToolTests {

    /// The Done-when, in the words a person will actually see.
    @Test("a bridge that is not running says how to start it")
    func closedBridgeTellsYouHowToOpenIt() async {
        let tool = REvalTool(bridge: { RBridgeClient(port: 8798, scriptPath: "/Users/me/r-bridge.R") },
                             store: { nil })
        do {
            _ = try await tool.call(argumentsJSON: #"{"code":"1 + 1"}"#, context: context())
            Issue.record("ran against a bridge that is not there")
        } catch let error as ToolError {
            let message = "\(error)"
            #expect(message.contains("Rscript /Users/me/r-bridge.R"))
            #expect(message.lowercased().contains("connection refused") == false)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("the tool is graded by what it can do, not by what it is called")
    func riskIsHigh() {
        let tool = REvalTool(bridge: { RBridgeClient() }, store: { nil })
        // Arbitrary code on somebody's machine. `RiskScorer` grades it the same
        // way, and `StageGate` calls it mutating; both tables are checked
        // elsewhere for agreement.
        #expect(tool.riskLevel == .high)
    }

    @Test("code is required, and a bad table name is refused before anything runs")
    func argumentsAreChecked() {
        #expect(throws: ToolError.self) { _ = try REvalTool.arguments(#"{"code":"  "}"#) }
        #expect(throws: ToolError.self) {
            _ = try REvalTool.arguments(#"{"code":"1","into_table":"drop table x"}"#)
        }
        #expect(throws: ToolError.self) {
            _ = try REvalTool.arguments(#"{"code":"1","into_table":"2024_results"}"#)
        }
        let ok = try? REvalTool.arguments(#"{"code":"head(df)","into_table":"r_out"}"#)
        #expect(ok?.table == "r_out")
    }
}

@Suite("A data frame becomes a table (P14.3)")
struct RFrameImportTests {

    @Test("R's frame is queryable with SQL afterwards")
    func frameLandsInDuckDB() async throws {
        let store = try AnalysisStore()
        let rows = try await RFrameImport.load(liveFrame, into: "r_result", store: store)
        #expect(rows == 3)

        let back = try await store.query("SELECT id, name, value FROM r_result ORDER BY id")
        #expect(back.rowCount == 3)
        #expect(back.rows[0] == ["1", "a", "1.5"])
        // NA came through as NULL, not as the two letters — a numeric column
        // with a missing value must not become text.
        #expect(back.rows[1][1] == nil)

        // And DuckDB inferred types rather than taking everything as VARCHAR,
        // which is the whole reason this goes through a file.
        let schema = try await store.schema(of: "r_result")
        #expect(schema.first(where: { $0.name == "id" })?.type.contains("INT") == true)
        #expect(schema.first(where: { $0.name == "value" })?.type.contains("DOUBLE") == true)
    }

    @Test("a value with a comma or a quote in it survives the trip")
    func csvQuoting() async throws {
        let awkward = RFrame(columns: ["label"], types: ["character"],
                             rows: [[#"เชียงใหม่, ไทย"#], [#"เขาว่า "ดี""#]])
        let store = try AnalysisStore()
        try await RFrameImport.load(awkward, into: "r_labels", store: store)

        let back = try await store.query("SELECT label FROM r_labels")
        #expect(back.rowCount == 2)
        #expect(back.rows.contains(["เชียงใหม่, ไทย"]))
        #expect(back.rows.contains([#"เขาว่า "ดี""#]))
    }

    /// Asking for a table and getting an empty one is worse than an error: the
    /// next query reads it as "no rows matched".
    @Test("asking for a table when the code returned no frame is an error, not an empty table")
    func noFrameIsNotAnEmptyTable() async throws {
        struct NoFrame: REvaluating {
            func eval(_ code: String) async throws -> REvalResult {
                REvalResult(printed: "[1] 42", frame: nil)
            }
        }
        let store = try AnalysisStore()
        let tool = REvalTool(bridge: { NoFrame() }, store: { store })
        do {
            _ = try await tool.call(argumentsJSON: #"{"code":"42","into_table":"r_nothing"}"#,
                                    context: context())
            Issue.record("wrote a table from a value that was not a data frame")
        } catch let error as ToolError {
            #expect("\(error)".contains("ไม่ได้คืนค่าเป็น data frame"))
        }
        // And nothing was created on the way to that error.
        await #expect(throws: (any Error).self) {
            _ = try await store.query("SELECT * FROM r_nothing")
        }
    }

    /// The other half: a frame with no table asked for is shown, not stored.
    @Test("a frame with no table named is previewed rather than filed away")
    func frameWithoutTableIsPreviewed() async throws {
        struct WithFrame: REvaluating {
            func eval(_ code: String) async throws -> REvalResult {
                REvalResult(printed: "", frame: liveFrame)
            }
        }
        let tool = REvalTool(bridge: { WithFrame() }, store: { nil })
        let output = try await tool.call(argumentsJSON: #"{"code":"df"}"#, context: context())
        #expect(output.text.contains("id | name | value"))
        #expect(output.text.contains("into_table"))
    }

    @Test("the empty frame writes an empty table rather than failing")
    func emptyFrameIsAllowed() async throws {
        // R legitimately returns a zero-row data frame — a filter that matched
        // nothing. That is an answer, and it is not the same as no frame.
        let store = try AnalysisStore()
        let empty = RFrame(columns: ["id", "name"], types: ["integer", "character"], rows: [])
        try await RFrameImport.load(empty, into: "r_empty", store: store)
        let back = try await store.query("SELECT * FROM r_empty")
        #expect(back.isEmpty)
        #expect(back.columns.map(\.name) == ["id", "name"])
    }
}

// ─────────────────────────────────────────────────────────────
// P14.4 — installing a package always stops for a person, and cannot be
// smuggled past by calling it something else.
// ─────────────────────────────────────────────────────────────
@Suite("Installing an R package asks, every time (P14.4)")
struct RInstallPackageToolTests {

    /// The hole this closes: `AlwaysAsk` is keyed on the tool name, and
    /// `install.packages("x")` inside a block of R is not a tool name.
    @Test("r_eval refuses to install, and says which tool does")
    func evalRefusesInstalls() {
        for call in ["install.packages(\"dplyr\")",
                     "remotes::install_github(\"tidyverse/dplyr\")",
                     "BiocManager::install(\"limma\")",
                     "pak::pkg_install(\"survival\")"] {
            #expect(throws: ToolError.self) {
                try REvalTool.refuseInstalls(in: "x <- 1\n\(call)\n")
            }
        }
        do {
            try REvalTool.refuseInstalls(in: "install.packages(\"dplyr\")")
            Issue.record("an install slipped through r_eval")
        } catch let error as ToolError {
            #expect("\(error)".contains("r_install_package"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        // Ordinary code is not caught by the crude match.
        #expect(throws: Never.self) {
            try REvalTool.refuseInstalls(in: "library(dplyr); summary(df)")
        }
    }

    /// The argument is a package name, not R. Anything else is a way to run
    /// arbitrary code through a tool whose approval sheet says "install".
    @Test("the package name is a name, not an expression")
    func nameIsANotAnExpression() {
        #expect(throws: ToolError.self) {
            _ = try RInstallPackageTool.arguments(#"{"package":"dplyr\"); system(\"rm -rf ~"}"#)
        }
        #expect(throws: ToolError.self) {
            _ = try RInstallPackageTool.arguments(#"{"package":""}"#)
        }
        #expect(throws: ToolError.self) {
            _ = try RInstallPackageTool.arguments(#"{"package":"dplyr","repository":"http://x"}"#)
        }
        let ok = try? RInstallPackageTool.arguments(#"{"package":"data.table"}"#)
        #expect(ok?.repository == "https://cloud.r-project.org")
    }

    @Test("a closed bridge still says how to open it")
    func closedBridgeMessage() async {
        let tool = RInstallPackageTool(bridge: {
            RBridgeClient(port: 8797, scriptPath: "/Users/me/r-bridge.R")
        })
        do {
            _ = try await tool.call(argumentsJSON: #"{"package":"dplyr"}"#, context: context())
            Issue.record("installed against a bridge that is not there")
        } catch let error as ToolError {
            #expect("\(error)".contains("Rscript /Users/me/r-bridge.R"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
