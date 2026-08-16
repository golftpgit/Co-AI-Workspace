import Foundation

// ─────────────────────────────────────────────────────────────
// The bridge itself, as a file the person can read (§12.7, P14.1).
//
// **Why not plumber.** §12.7 illustrates the bridge with plumber, and plumber
// is not installed on this machine — measured, not assumed (E.28). Reaching
// for it would mean the setup helper's first instruction is "install a package
// so the helper can work", which is a poor trade for a decorator syntax:
// plumber is itself a layer over `httpuv`, and `httpuv` and `jsonlite` are
// both already here. The bridge is thirty lines either way. This is a
// departure from the picture in the architecture and not from the rule under
// it — a small, readable R file the person starts themselves.
//
// **Why the person starts it.** Nothing here launches R. A bridge that the app
// spawns is a bridge whose lifetime, working directory and library paths are
// the app's rather than the analyst's, and §12.7 asks for something that sits
// beside RStudio — the same R, the same packages, the same session habits. So
// this generates a file and a command, and the app checks whether the result
// is answering.
// ─────────────────────────────────────────────────────────────

public enum BridgeScript {
    public static let defaultPort = 8787
    public static let fileName = "r-bridge.R"

    /// The bridge, ready to write to disk.
    ///
    /// Binds `127.0.0.1` and nothing else. A bridge that evaluates arbitrary R
    /// is a shell; a shell on `0.0.0.0` is a shell for the coffee shop.
    public static let contents = #"""
    # r-bridge.R — สะพาน R สำหรับ Co-AI Workspace (ARCHITECTURE §12.7)
    #
    # สร้างโดยแอป แก้ได้ตามสบาย: มันเป็นไฟล์ของคุณ ไม่ใช่ของแอป
    # เปิดด้วย:  Rscript r-bridge.R
    #
    # ฟังเฉพาะ 127.0.0.1 โดยตั้งใจ — สะพานนี้รัน R อะไรก็ได้ที่ส่งมา
    # ถ้าเปิดออกนอกเครื่อง ก็เท่ากับเปิดเชลล์ให้คนทั้งวง

    library(httpuv)
    library(jsonlite)

    port <- as.integer(Sys.getenv("CO_AI_R_BRIDGE_PORT", "8787"))
    token <- Sys.getenv("CO_AI_R_BRIDGE_TOKEN", "")

    json_response <- function(status, payload) {
      list(status = status,
           headers = list("Content-Type" = "application/json"),
           body = toJSON(payload, auto_unbox = TRUE, na = "null", null = "null"))
    }

    read_body <- function(req) {
      input <- req[["rook.input"]]
      if (is.null(input)) return("")
      rawToChar(input$read())
    }

    # data.frame -> คอลัมน์ ชนิด และแถวเป็นสตริง เพื่อให้ฝั่ง Swift ลง DuckDB ต่อได้
    as_frame <- function(value) {
      if (!is.data.frame(value)) return(NULL)
      cols <- names(value)
      types <- vapply(value, function(col) class(col)[1], character(1), USE.NAMES = FALSE)
      rows <- if (nrow(value) == 0) list() else lapply(seq_len(nrow(value)), function(i) {
        vapply(cols, function(name) {
          cell <- value[[name]][i]
          if (is.na(cell)) NA_character_ else as.character(cell)
        }, character(1), USE.NAMES = FALSE)
      })
      list(columns = cols, types = types, rows = rows)
    }

    run_code <- function(code) {
      env <- new.env(parent = globalenv())
      value <- NULL
      printed <- capture.output(value <- eval(parse(text = code), envir = env))
      list(printed = paste(printed, collapse = "\n"), frame = as_frame(value))
    }

    app <- list(call = function(req) {
      path <- req$PATH_INFO
      if (identical(path, "/health")) {
        return(json_response(200L, list(ok = TRUE,
                                        r = as.character(getRversion()),
                                        pid = Sys.getpid())))
      }
      if (!identical(path, "/eval")) {
        return(json_response(404L, list(error = paste("ไม่มี endpoint", path))))
      }
      if (!identical(req$REQUEST_METHOD, "POST")) {
        return(json_response(405L, list(error = "endpoint นี้ต้องเป็น POST")))
      }
      parsed <- tryCatch(fromJSON(read_body(req)), error = function(e) NULL)
      if (is.null(parsed) || is.null(parsed$code)) {
        return(json_response(400L, list(error = "ต้องส่ง JSON ที่มีคีย์ code")))
      }
      if (nzchar(token) && !identical(parsed$token, token)) {
        return(json_response(403L, list(error = "โทเคนไม่ตรงกับที่สะพานตั้งไว้")))
      }
      # ข้อผิดพลาดของ R กลับไปเป็นข้อความ ไม่ใช่ 500 เปล่า ๆ — ข้อความของ R
      # คือสิ่งเดียวที่บอกได้ว่าโค้ดผิดตรงไหน
      result <- tryCatch(run_code(parsed$code),
                         error = function(e) list(error = conditionMessage(e)))
      if (!is.null(result$error)) {
        return(json_response(400L, list(error = result$error)))
      }
      json_response(200L, result)
    })

    cat(sprintf("co-ai r-bridge: ฟังอยู่ที่ 127.0.0.1:%d\n", port))
    runServer("127.0.0.1", port, app)
    """#

    /// The command to copy. One line, because a person is going to paste it.
    public static func startCommand(scriptPath: String, port: Int = defaultPort) -> String {
        port == defaultPort
            ? "Rscript \(quoted(scriptPath))"
            : "CO_AI_R_BRIDGE_PORT=\(port) Rscript \(quoted(scriptPath))"
    }

    /// A launchd job, for somebody who wants the bridge back after a reboot.
    /// Optional on purpose: a background service nobody remembers agreeing to
    /// is how an R process ends up running for a year.
    public static func launchdPlist(scriptPath: String,
                                    rscriptPath: String,
                                    port: Int = defaultPort) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>com.co-ai.r-bridge</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(rscriptPath)</string>
                <string>\(scriptPath)</string>
            </array>
            <key>EnvironmentVariables</key>
            <dict><key>CO_AI_R_BRIDGE_PORT</key><string>\(port)</string></dict>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><false/>
        </dict>
        </plist>
        """
    }

    /// Writes the script beside wherever the app keeps its own files, and
    /// returns where it went. Never overwrites a file the person has edited:
    /// the header says it is theirs, and a helper that means it does not
    /// rewrite their changes on the next launch.
    @discardableResult
    public static func write(into directory: URL,
                             overwrite: Bool = false) throws -> URL {
        let url = directory.appending(path: fileName)
        if FileManager.default.fileExists(atPath: url.path) && !overwrite { return url }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func quoted(_ path: String) -> String {
        path.contains(" ") ? "\"\(path)\"" : path
    }
}
