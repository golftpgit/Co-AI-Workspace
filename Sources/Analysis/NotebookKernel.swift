import Foundation
import Execution
import Observability

// ─────────────────────────────────────────────────────────────
// The Python half of the notebook (ARCHITECTURE §12.5, P6.4).
//
// A kernel is a process that stays: the whole reason to have one is that cell
// 12 can use the dataframe cell 3 built. That single sentence decides the
// design — one long-lived interpreter, one request per cell, and state that
// belongs to the kernel rather than to us.
//
// The protocol is a JSON object per line in each direction. Line-framed because
// it is the only framing a person can debug by hand, and JSON because a cell's
// output contains newlines, tabs and Thai text, all of which have to survive
// the trip without a length prefix nobody can read.
//
// Three things this file refuses to do:
//
//  • **Guess that a cell finished.** A cell that has not answered is running,
//    not done. On a timeout the kernel is interrupted and given a moment to
//    report its own `KeyboardInterrupt`; only if that fails too is it declared
//    dead — because a kernel silently restarted underneath the user takes
//    twenty cells of state with it.
//  • **Mix output with protocol.** The driver keeps a private copy of fd 1 for
//    replies and points fd 1 itself at stderr, so a cell that shells out to
//    something chatty cannot corrupt the framing.
//  • **Let `exit()` in a cell take the kernel down.** `SystemExit` is caught
//    like any other error and reported as a failed cell.
// ─────────────────────────────────────────────────────────────

public struct CellOutput: Sendable, Equatable, Codable {
    /// Everything the cell printed.
    public let stdout: String
    public let stderr: String
    /// The value of the last expression, rendered by Python's `repr` — the
    /// notebook convention, and the reason a cell ending in `df.head()` shows
    /// something.
    public let value: String?
    /// The traceback, verbatim. §13's rule about compiler output applies here
    /// too: a summarised traceback is worse than the traceback.
    public let error: String?

    public var failed: Bool { error != nil }

    public init(stdout: String = "", stderr: String = "",
                value: String? = nil, error: String? = nil) {
        self.stdout = stdout
        self.stderr = stderr
        self.value = value
        self.error = error
    }
}

public enum KernelError: Error, CustomStringConvertible, Equatable {
    case interpreterMissing([String])
    /// Found something, but not something this process can start — see
    /// `ExecutableSearch`. Separate from "missing" because the fix is
    /// different and the screen has to say which one happened.
    case interpreterUnusable(String)
    case notRunning
    case startFailed(String)
    case protocolBroken(String)
    case died(String)

    public var description: String {
        switch self {
        case .interpreterMissing(let tried):
            "ไม่พบ Python บนเครื่องนี้ (ลองหาที่: \(tried.joined(separator: ", ")))"
        case .interpreterUnusable(let reason): reason
        case .notRunning: "เคอร์เนลยังไม่ได้เริ่ม — กด 'เริ่มเคอร์เนล' ก่อน"
        case .startFailed(let message): "เริ่มเคอร์เนลไม่สำเร็จ: \(message)"
        case .protocolBroken(let message): "เคอร์เนลตอบมาในรูปแบบที่อ่านไม่ออก: \(message)"
        case .died(let message): "เคอร์เนลหยุดทำงาน: \(message)"
        }
    }
}

public actor NotebookKernel {
    /// Homebrew first: a machine that has one is a machine where pandas and
    /// numpy live in it, and a kernel without the libraries is a kernel nobody
    /// will use.
    ///
    /// The order — and the fact that `/usr/bin/python3` is *not* the fallback
    /// it looks like — belongs to `ExecutableSearch`, which knows the thing
    /// this list used to only suspect: that path is a shim that cannot run
    /// inside the App Sandbox at all (P9.6). Kept as a computed property so
    /// there is one search on this machine rather than two that disagree.
    public static var searchPaths: [String] {
        ExecutableSearch.toolchainDirectories.map { $0 + "/python3" } + ["/usr/bin/python3"]
    }

    private let interpreter: String
    private let workingDirectory: URL?
    private var process: KernelProcess?
    private var version: String?
    private let log = AppLog.logger("notebook")

    /// How long a cell may run before the kernel is interrupted. Generous:
    /// reading a few million rows into pandas is a normal cell, not a hang.
    public private(set) var cellTimeout: Duration = .seconds(300)

    public func setCellTimeout(_ timeout: Duration) { cellTimeout = timeout }

    public nonisolated let interpreterPath: String

    public init(interpreter: String? = nil, workingDirectory: URL? = nil) throws {
        if let interpreter {
            guard FileManager.default.isExecutableFile(atPath: interpreter) else {
                throw KernelError.interpreterMissing([interpreter])
            }
            self.interpreter = interpreter
        } else {
            do {
                self.interpreter = try ExecutableSearch.resolve("python3")
            } catch {
                // The reason matters here: "no Python" and "the only Python is
                // one this sandbox cannot start" are different problems with
                // different fixes, and the screen shows whichever it is.
                throw KernelError.interpreterUnusable(
                    (error as? ExecutableSearchError)?.description
                        ?? "\(error)")
            }
        }
        self.interpreterPath = self.interpreter
        self.workingDirectory = workingDirectory
    }

    public var isRunning: Bool { process?.isRunning == true }

    /// The interpreter's version, once it has said hello. Nil before that, and
    /// deliberately taken from the running process rather than from `--version`
    /// on a different one.
    public var pythonVersion: String? { version }

    // MARK: - lifecycle

    public func start() async throws {
        guard !isRunning else { return }
        let kernel = try KernelProcess(
            executable: interpreter,
            // -u: unbuffered, so a reply is a reply and not something sitting
            // in a 4 KB buffer waiting for the next cell to push it out.
            arguments: ["-u", "-c", Self.driver],
            workingDirectory: workingDirectory,
            environmentOverrides: ["PYTHONIOENCODING": "utf-8"])
        process = kernel

        // The driver announces itself. A kernel that cannot even do that has
        // usually printed the reason on stderr — a missing developer path, a
        // broken virtualenv — and that message is the only useful thing we can
        // give the user.
        guard let hello = await kernel.nextLine(timeout: .seconds(20)),
              let reply = Self.decode(hello), reply.ready == true else {
            let reason = kernel.errorOutput().trimmingCharacters(in: .whitespacesAndNewlines)
            kernel.terminate()
            process = nil
            throw KernelError.startFailed(reason.isEmpty ? "ไม่มีคำตอบจากเคอร์เนล" : reason)
        }
        version = reply.version
        log.info("kernel up: python \(reply.version ?? "?", privacy: .public)")
    }

    /// Stops the kernel. State goes with it, which is the point of restarting.
    public func stop() {
        process?.terminate()
        process = nil
        version = nil
    }

    public func restart() async throws {
        stop()
        try await start()
    }

    /// SIGINT, for a cell that is taking too long but whose kernel is worth
    /// keeping.
    public func interrupt() {
        process?.interrupt()
    }

    // MARK: - running a cell

    public func execute(_ code: String) async throws -> CellOutput {
        guard let kernel = process, kernel.isRunning else { throw KernelError.notRunning }
        let request = ["code": code]
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let line = String(data: data, encoding: .utf8) else {
            throw KernelError.protocolBroken("เข้ารหัสคำสั่งไม่ได้")
        }
        do {
            try kernel.send(line)
        } catch {
            stop()
            throw KernelError.died(kernel.errorOutput())
        }

        if let answer = await kernel.nextLine(timeout: cellTimeout) {
            return try Self.output(from: answer)
        }
        // Nothing yet. Ask the cell to stop rather than assuming it has: a
        // KeyboardInterrupt traceback is a result, and it keeps the state.
        kernel.interrupt()
        if let answer = await kernel.nextLine(timeout: .seconds(5)) {
            return try Self.output(from: answer)
        }
        // It did not even answer the interrupt. Now it is dead, and saying so
        // is better than a call that never returns.
        let reason = kernel.errorOutput()
        stop()
        throw KernelError.died(reason.isEmpty
            ? "ไม่ตอบสนองต่อการขัดจังหวะ — ต้องเริ่มเคอร์เนลใหม่" : reason)
    }

    // MARK: - the wire

    private struct Reply: Decodable {
        var ready: Bool?
        var version: String?
        var ok: Bool?
        var value: String?
        var error: String?
        var stdout: String?
        var stderr: String?
    }

    private static func decode(_ line: String) -> Reply? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Reply.self, from: data)
    }

    private static func output(from line: String) throws -> CellOutput {
        guard let reply = decode(line) else {
            throw KernelError.protocolBroken(String(line.prefix(200)))
        }
        return CellOutput(stdout: reply.stdout ?? "",
                          stderr: reply.stderr ?? "",
                          value: reply.value,
                          error: reply.ok == false ? (reply.error ?? "ไม่ทราบสาเหตุ") : nil)
    }

    /// The driver, passed on the command line so there is no file to install,
    /// lose, or have go stale against this source.
    static let driver = #"""
    import sys, os, io, json, ast, contextlib, traceback

    # Replies go out on a private copy of fd 1, and fd 1 itself is pointed at
    # stderr. A cell that starts a chatty subprocess then cannot write into the
    # middle of a JSON line.
    _channel = os.fdopen(os.dup(1), "w", encoding="utf-8")
    os.dup2(2, 1)

    # Requests come in on a private copy of fd 0, and fd 0 becomes /dev/null.
    # Two reasons, both found by running this: `exit()` in a cell is
    # `site.Quitter`, which *closes sys.stdin* before raising SystemExit — with
    # the request stream behind sys.stdin, one `exit()` ended the kernel for
    # good. And a cell that reads input() would otherwise eat the next cell.
    _requests = os.fdopen(os.dup(0), "r", encoding="utf-8")
    os.dup2(os.open(os.devnull, os.O_RDONLY), 0)

    _state = {"__name__": "__main__"}
    _LIMIT = 200000

    def _clip(text):
        if len(text) <= _LIMIT:
            return text
        return text[:_LIMIT] + "\n… ตัดที่ %d ตัวอักษร" % _LIMIT

    def _reply(payload):
        _channel.write(json.dumps(payload) + "\n")
        _channel.flush()

    def _run(code):
        block = ast.parse(code, "<cell>", "exec")
        # A trailing expression is the cell's value, the way a notebook shows
        # `df.head()` without anyone writing print.
        if block.body and isinstance(block.body[-1], ast.Expr):
            head = ast.Module(body=block.body[:-1], type_ignores=[])
            exec(compile(head, "<cell>", "exec"), _state)
            tail = ast.Expression(block.body[-1].value)
            return eval(compile(tail, "<cell>", "eval"), _state)
        exec(compile(block, "<cell>", "exec"), _state)
        return None

    _reply({"ready": True, "version": sys.version.split()[0]})

    while True:
        try:
            line = _requests.readline()
        except KeyboardInterrupt:
            continue          # an interrupt with no cell running is not an error
        if not line:
            break             # stdin closed: the app is going away
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except Exception:
            _reply({"ok": False, "error": "คำสั่งที่ส่งมาอ่านไม่ออก", "stdout": "", "stderr": ""})
            continue
        out, err = io.StringIO(), io.StringIO()
        payload = {}
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                value = _run(request.get("code", ""))
            payload["ok"] = True
            if value is not None:
                payload["value"] = _clip(repr(value))
        except BaseException:
            # BaseException, not Exception: exit() in a cell ends the cell, not
            # the kernel, and a KeyboardInterrupt is how a stopped cell reports.
            payload["ok"] = False
            payload["error"] = _clip(traceback.format_exc())
        payload["stdout"] = _clip(out.getvalue())
        payload["stderr"] = _clip(err.getvalue())
        _reply(payload)
    """#
}
