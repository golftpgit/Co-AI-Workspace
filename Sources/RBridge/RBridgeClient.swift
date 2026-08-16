import Foundation

// ─────────────────────────────────────────────────────────────
// Talking to the bridge (§12.7, P14.1/P14.2).
//
// The rule this file exists for is in P14.2's Done-when: **calling a bridge
// that is not running gives a message that says how to open it, not
// "connection refused".** The person on the other end of that message is an
// analyst who has R, wrote some code, and has no reason to know that the app
// talks to R over a socket at all.
// ─────────────────────────────────────────────────────────────

/// A data frame that came back from R, kept as text on purpose: DuckDB infers
/// the types on import (P14.3), and a second type-guessing layer here would be
/// one more place for a factor to become a number.
public struct RFrame: Sendable, Equatable {
    public let columns: [String]
    /// R's own class for each column — `numeric`, `factor`, `Date` — carried so
    /// a surprising import can be explained.
    public let types: [String]
    /// Row-major. `nil` is R's `NA`, kept distinct from the string "NA", which
    /// is a value somebody may have in a column of country codes.
    public let rows: [[String?]]

    public init(columns: [String], types: [String], rows: [[String?]]) {
        self.columns = columns
        self.types = types
        self.rows = rows
    }
}

public struct REvalResult: Sendable, Equatable {
    /// Everything the code printed, in order.
    public let printed: String
    /// The value, when it was a data frame. `nil` for everything else — a plot,
    /// a model object, an assignment — and that is not a failure.
    public let frame: RFrame?

    public init(printed: String, frame: RFrame?) {
        self.printed = printed
        self.frame = frame
    }
}

/// What a caller needs from the bridge. A protocol so the rules that are not
/// about R — what happens when the code returns no data frame, what the person
/// is told when nothing is listening — can be tested without an R installed.
public protocol REvaluating: Sendable {
    func eval(_ code: String) async throws -> REvalResult
}

extension RBridgeClient: REvaluating {}

public enum RBridgeError: Error, CustomStringConvertible, Equatable {
    /// Nothing is listening. The one this file is really about.
    case notRunning(port: Int, startWith: String)
    case rejected(status: Int, message: String)
    /// R ran the code and R said no. The message is R's own, verbatim: it is
    /// the only thing that says which line was wrong.
    case codeFailed(String)
    case badReply(String)

    public var description: String {
        switch self {
        case .notRunning(let port, let startWith):
            "สะพาน R ยังไม่ได้เปิด (ไม่มีอะไรฟังอยู่ที่ 127.0.0.1:\(port)) — "
                + "เปิดเทอร์มินัลแล้วสั่ง: \(startWith) · หน้าตั้งค่า R มีปุ่มคัดลอกคำสั่งนี้ให้"
        case .rejected(let status, let message):
            "สะพาน R ปฏิเสธคำขอ (HTTP \(status)): \(message)"
        case .codeFailed(let message):
            "R รันโค้ดแล้วผิดพลาด: \(message)"
        case .badReply(let detail):
            "สะพาน R ตอบมาในรูปที่อ่านไม่ออก (\(detail)) — "
                + "ถ้าคุณแก้ r-bridge.R เอง ให้เทียบกับไฟล์ที่แอปสร้างอีกครั้ง"
        }
    }
}

public actor RBridgeClient {
    private let port: Int
    private let scriptPath: String
    private let session: URLSession
    private let token: String?

    public init(port: Int = BridgeScript.defaultPort,
                scriptPath: String = BridgeScript.fileName,
                token: String? = nil,
                session: URLSession = .shared) {
        self.port = port
        self.scriptPath = scriptPath
        self.token = token
        self.session = session
    }

    private var base: URL { URL(string: "http://127.0.0.1:\(port)")! }

    /// Whether the bridge is answering, and which R it is. Used by the setup
    /// screen's health light, so it returns the reason rather than a bool.
    public func health() async -> Result<String, RBridgeError> {
        var request = URLRequest(url: base.appending(path: "health"))
        request.timeoutInterval = 5
        do {
            let (data, response) = try await session.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
                return .failure(.badReply("health ตอบไม่ใช่ 200"))
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = object["r"] as? String else {
                return .failure(.badReply("health ไม่มีเวอร์ชันของ R"))
            }
            return .success(version)
        } catch {
            return .failure(notRunning)
        }
    }

    public func eval(_ code: String) async throws -> REvalResult {
        var request = URLRequest(url: base.appending(path: "eval"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: String] = ["code": code]
        if let token { payload["token"] = token }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // Every transport failure lands here, and every one of them means
            // the same thing to the person: the bridge is not up.
            throw notRunning
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RBridgeError.badReply("ตัวตอบไม่ใช่ JSON")
        }
        if status != 200 {
            let message = object["error"] as? String ?? "ไม่มีรายละเอียด"
            // 400 from this bridge means R itself refused the code. Reporting
            // that as an HTTP problem would send somebody to check the network
            // over a missing bracket.
            throw status == 400 ? RBridgeError.codeFailed(message)
                                : RBridgeError.rejected(status: status, message: message)
        }
        return REvalResult(printed: object["printed"] as? String ?? "",
                           frame: Self.frame(from: object["frame"]))
    }

    private var notRunning: RBridgeError {
        .notRunning(port: port,
                    startWith: BridgeScript.startCommand(scriptPath: scriptPath, port: port))
    }

    /// Decodes the frame shape the generated script produces. Written by hand
    /// rather than with `Codable` because `NA` arrives as JSON null inside an
    /// array of strings, and that is exactly the distinction worth keeping.
    static func frame(from value: Any?) -> RFrame? {
        guard let object = value as? [String: Any],
              let columns = object["columns"] as? [String] else { return nil }
        let types = object["types"] as? [String] ?? Array(repeating: "unknown", count: columns.count)
        let rawRows = object["rows"] as? [[Any]] ?? []
        let rows = rawRows.map { row in row.map { $0 as? String } }
        return RFrame(columns: columns, types: types, rows: rows)
    }
}
