import Foundation
import AgentKit
import Analysis
import RBridge
import Observability

// ─────────────────────────────────────────────────────────────
// `r_eval` — R through the same door as everything else (§12.7, P14.2/P14.3).
//
// The bridge is an HTTP server on loopback that evaluates R. That is a shell
// with a different syntax, and the only reason it is safe to have is that it
// goes through the gate every other tool goes through: risk scored on this
// side (`RiskScorer` grades it high), stage-classified as `.mutating` so the
// planning and closing stages refuse it, and approved by a person under any
// autonomy setting that stops for high risk.
//
// **Two rules that are not about R at all.**
//
// A bridge that is not running produces "how to start it", never "connection
// refused" — P14.2 says so and `RBridgeError` carries the sentence. The
// analyst on the other end has R, wrote R, and has no reason to know the app
// talks to it over a socket.
//
// And a data frame becomes a table (P14.3) **only when asked**. An `r_eval`
// that silently created a table per call would fill somebody's project with
// `r_result_7`, and the point of §12.7 is that R's answers become part of the
// analysis rather than a wall of printed output — which means named, by the
// person who will cite it.
// ─────────────────────────────────────────────────────────────

public struct REvalTool: AgentTool {
    public let name = "r_eval"
    public let toolDescription = """
    รันโค้ด R บนสะพาน R ของเครื่องนี้ (ต้องเปิดสะพานไว้ก่อน) แล้วคืนสิ่งที่โค้ดพิมพ์ออกมา \
    ถ้าโค้ดคืนค่าเป็น data frame และระบุ `into_table` ไว้ ตารางนั้นจะถูกเขียนลงคลังข้อมูลวิเคราะห์ \
    เพื่อ query ด้วย SQL ต่อได้ · ใช้เมื่อจำเป็นต้องใช้แพ็กเกจของ R จริง ๆ — \
    สถิติที่ระบบทำเองอยู่แล้วให้ใช้ `run_stat_test` ซึ่งตรวจเงื่อนไขให้ด้วย
    """
    /// Arbitrary code on the person's machine, with their libraries and their
    /// files. Nothing about "it is only statistics" makes that lower than high.
    public let riskLevel: RiskLevel = .high
    public let parametersJSON = """
    {
      "type": "object",
      "properties": {
        "code": { "type": "string", "description": "โค้ด R ที่จะรัน" },
        "into_table": {
          "type": "string",
          "description": "ชื่อตารางในคลังข้อมูลวิเคราะห์ที่จะเก็บ data frame ที่คืนมา (ถ้าไม่ระบุ จะไม่เขียนตาราง)"
        }
      },
      "required": ["code"]
    }
    """

    private let bridge: @Sendable () async -> any REvaluating
    private let store: @Sendable () async -> AnalysisStore?

    public init(bridge: @escaping @Sendable () async -> any REvaluating,
                store: @escaping @Sendable () async -> AnalysisStore?) {
        self.bridge = bridge
        self.store = store
    }

    public func precheck(argumentsJSON: String, context: ToolContext) throws {
        _ = try Self.arguments(argumentsJSON)
    }

    public func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutput {
        let (code, table) = try Self.arguments(argumentsJSON)
        let result: REvalResult
        do {
            result = try await bridge().eval(code)
        } catch let error as RBridgeError {
            // Passed through as written. `ToolError` wrapping the description
            // keeps the sentence that tells somebody what to do.
            throw ToolError.executionFailed(error.description)
        }

        var text = result.printed.isEmpty ? "(โค้ดรันแล้ว ไม่มีอะไรพิมพ์ออกมา)" : result.printed

        guard let table else {
            if let frame = result.frame {
                text += "\n\n" + Self.preview(frame)
                    + "\n(ยังไม่ได้เก็บเป็นตาราง — ระบุ into_table ถ้าต้องการ query ต่อด้วย SQL)"
            }
            return ToolOutput(text: text)
        }
        guard let frame = result.frame else {
            // Asked for a table and got no frame: saying so beats creating an
            // empty table that a later query will read as "no rows found".
            throw ToolError.executionFailed(
                "ระบุ into_table ไว้ แต่โค้ดไม่ได้คืนค่าเป็น data frame — "
                    + "ค่าที่คืนมาเป็นชนิดอื่น จึงยังไม่ได้เขียนตารางอะไร")
        }
        guard let store = await store() else {
            throw ToolError.executionFailed("คลังข้อมูลวิเคราะห์เปิดไม่ได้ตอนเริ่มแอป")
        }
        let rows = try await RFrameImport.load(frame, into: table, store: store)
        text += "\n\nเขียนลงตาราง \(table) แล้ว \(rows) แถว — query ต่อด้วย analysis_query ได้"
        return ToolOutput(text: text)
    }

    static func preview(_ frame: RFrame, limit: Int = 10) -> String {
        let header = frame.columns.joined(separator: " | ")
        let shown = frame.rows.prefix(limit).map { row in
            row.map { $0 ?? "NA" }.joined(separator: " | ")
        }
        var text = "\(header)\n" + shown.joined(separator: "\n")
        if frame.rows.count > limit {
            text += "\n… แสดง \(limit) จาก \(frame.rows.count) แถว"
        }
        return text
    }

    /// R can install its own packages from inside `r_eval`, which would walk
    /// straight past `AlwaysAsk` — the list is keyed on the tool name, and
    /// `install.packages("x")` inside a block of R is not a tool name. So the
    /// call is refused here and pointed at the tool that does stop for a
    /// person, every time, under every autonomy setting (§5.5, P14.4).
    ///
    /// A crude match on purpose, exactly like `RunShellTool`'s destructive
    /// patterns: the cost of a false alarm is one redirected call, and the
    /// cost of a miss is other people's code running on somebody's machine
    /// without them being asked.
    static let installCalls = ["install.packages", "remotes::install",
                               "devtools::install", "BiocManager::install",
                               "renv::install", "pak::pkg_install"]

    static func refuseInstalls(in code: String) throws {
        guard let found = installCalls.first(where: { code.contains($0) }) else { return }
        throw ToolError.invalidArguments(
            "โค้ดนี้เรียก \(found) — การติดตั้งแพ็กเกจต้องใช้ทูล r_install_package "
                + "ซึ่งหยุดถามคนทุกครั้งแม้อยู่โหมดทำงานเองทั้งหมด (§5.5) "
                + "· ไม่ใช่เพราะติดตั้งไม่ได้ แต่เพราะมันคือการรันโค้ดของคนอื่นบนเครื่องคุณ")
    }

    static func arguments(_ json: String) throws -> (code: String, table: String?) {
        struct Payload: Decodable {
            let code: String
            let into_table: String?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(json.utf8)),
              !payload.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.invalidArguments("ต้องระบุ 'code'")
        }
        try refuseInstalls(in: payload.code)
        if let table = payload.into_table {
            try RFrameImport.checkName(table)
        }
        return (payload.code, payload.into_table)
    }
}

/// A data frame becoming a DuckDB table (P14.3).
///
/// Written through a CSV file rather than a generated `INSERT`: DuckDB infers
/// the column types on read, which is the same path every other import in this
/// app takes (`AnalysisStore.importFile`), so an R numeric ends up the same
/// type as the same column read from a file. A hand-built `INSERT` would mean
/// a second type-guessing implementation, and the first thing it would get
/// wrong is a factor that looks like a number.
public enum RFrameImport {

    /// The table name is an identifier in a statement, so it is checked before
    /// it is anywhere near one. `AnalysisStore` quotes identifiers properly;
    /// this refuses the ones that are not names at all, which is a better
    /// error than a quoted nonsense table.
    public static func checkName(_ table: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        guard !table.isEmpty,
              table.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              table.first?.isNumber == false else {
            throw ToolError.invalidArguments(
                "ชื่อตาราง '\(table)' ใช้ไม่ได้ — ใช้ตัวอักษร ตัวเลข และ _ และห้ามขึ้นต้นด้วยตัวเลข")
        }
    }

    @discardableResult
    public static func load(_ frame: RFrame,
                            into table: String,
                            store: AnalysisStore) async throws -> Int {
        try checkName(table)
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "co-ai-r-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "\(table).csv")
        defer { try? FileManager.default.removeItem(at: directory) }

        try csv(frame).write(to: file, atomically: true, encoding: .utf8)
        try await store.importFile(file, into: table)
        return frame.rows.count
    }

    /// RFC 4180 quoting, and `NA` written as an empty field — which is what
    /// DuckDB reads as NULL. Writing the two letters would turn every numeric
    /// column with a missing value into text.
    static func csv(_ frame: RFrame) -> String {
        var lines = [frame.columns.map(quote).joined(separator: ",")]
        for row in frame.rows {
            lines.append(row.map { $0.map(quote) ?? "" }.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func quote(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}


// ─────────────────────────────────────────────────────────────
// `r_install_package` (§12.7, P14.4).
//
// Separate from `r_eval` for one reason: **this one always asks.**
// `AlwaysAsk` is keyed on the tool name, so an install hidden inside a block
// of R would be a high-risk call that full autonomy waves through. Giving it
// its own name is what makes the rule reachable.
//
// The reason it belongs on that list is the same one `install_package` gives:
// installing a package runs other people's code — an R package with
// compiled sources runs its configure script during installation — and
// whatever that did is not in the output, not in the transcript, and not
// visible in whatever the package is later used for. "The model was
// confident" is not an answer to that.
// ─────────────────────────────────────────────────────────────

public struct RInstallPackageTool: AgentTool {
    public let name = "r_install_package"
    public let toolDescription = """
    ติดตั้งแพ็กเกจ R ลงไลบรารีของผู้ใช้ผ่านสะพาน R — **ถามคนก่อนเสมอ** ไม่ว่าจะตั้งโหมดอัตโนมัติไว้แค่ไหน \
    เพราะการติดตั้งแพ็กเกจคือการรันโค้ดของคนอื่นบนเครื่องนี้
    """
    public let riskLevel: RiskLevel = .high
    public let parametersJSON = """
    {
      "type": "object",
      "properties": {
        "package": { "type": "string", "description": "ชื่อแพ็กเกจ R (ชื่อล้วน)" },
        "repository": { "type": "string", "description": "CRAN mirror (ไม่ระบุ = cloud.r-project.org)" }
      },
      "required": ["package"]
    }
    """

    private let bridge: @Sendable () async -> any REvaluating

    public init(bridge: @escaping @Sendable () async -> any REvaluating) {
        self.bridge = bridge
    }

    public func precheck(argumentsJSON: String, context: ToolContext) throws {
        _ = try Self.arguments(argumentsJSON)
    }

    public func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutput {
        let (package, repository) = try Self.arguments(argumentsJSON)
        // Built here rather than taken as code: the whole point of this tool is
        // that the person approving it can read what it will do, and a free-text
        // R expression is not that.
        let code = """
        install.packages("\(package)", repos = "\(repository)")
        cat(if ("\(package)" %in% rownames(installed.packages())) \
            paste("ติดตั้งแล้ว:", packageVersion("\(package)")) else "ติดตั้งไม่สำเร็จ")
        """
        do {
            let result = try await bridge().eval(code)
            return ToolOutput(text: result.printed.isEmpty
                              ? "สั่งติดตั้งแล้ว แต่ R ไม่ได้รายงานอะไรกลับมา"
                              : result.printed)
        } catch let error as RBridgeError {
            throw ToolError.executionFailed(error.description)
        }
    }

    static func arguments(_ json: String) throws -> (package: String, repository: String) {
        struct Payload: Decodable {
            let package: String
            let repository: String?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(json.utf8)) else {
            throw ToolError.invalidArguments("ต้องระบุ 'package'")
        }
        // A package name, not an expression. Everything else is a way to run
        // arbitrary R through a tool whose approval sheet says "install".
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._"))
        guard !payload.package.isEmpty,
              payload.package.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw ToolError.invalidArguments(
                "ชื่อแพ็กเกจ '\(payload.package)' ใช้ไม่ได้ — ใส่ชื่อล้วน ไม่ใช่โค้ด R")
        }
        let repository = payload.repository ?? "https://cloud.r-project.org"
        guard repository.hasPrefix("https://") else {
            throw ToolError.invalidArguments("repository ต้องเป็น https")
        }
        return (payload.package, repository)
    }
}
