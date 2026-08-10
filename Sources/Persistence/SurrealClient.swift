import Foundation

// ─────────────────────────────────────────────────────────────
// SurrealClient — thin JSON-RPC-over-WebSocket client written by us.
// Deliberately NOT surrealdb.swift: that SDK is alpha, has no releases and
// warns its API breaks without notice (ARCHITECTURE §11.5, E.4).
// Surface we need: signin / use / query (+ live queries later).
//
// Proven end to end before adoption — BM25, HNSW, RELATE traversal, hybrid
// fusion, concurrency and reconnect all verified (ARCHITECTURE E.8).
//
// Swift 6 rejects `Any` across actor boundaries, so the wire type is a
// Sendable enum; that turns out to be the better shape anyway.
// ─────────────────────────────────────────────────────────────

public enum SurrealValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([SurrealValue])
    case object([String: SurrealValue])

    init(json: Any) {
        // ⚠️ Order matters: `x as? Bool` succeeds for ANY NSNumber in Swift
        // (0.84 → true), so NSNumber must be inspected *before* any Bool cast,
        // and boolean-ness decided by CFBoolean identity, not by casting.
        switch json {
        case is NSNull: self = .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) }
            else if String(cString: n.objCType) == "d" || String(cString: n.objCType) == "f" {
                self = .double(n.doubleValue)
            } else { self = .int(n.intValue) }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { SurrealValue(json: $0) })
        case let d as [String: Any]: self = .object(d.mapValues { SurrealValue(json: $0) })
        default: self = .string(String(describing: json))
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var intValue: Int? {
        switch self { case .int(let i): return i; case .double(let d): return Int(d); default: return nil }
    }
    public var doubleValue: Double? {
        switch self { case .double(let d): return d; case .int(let i): return Double(i); default: return nil }
    }
    public var arrayValue: [SurrealValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: [String: SurrealValue]? { if case .object(let o) = self { return o }; return nil }
    public subscript(_ key: String) -> SurrealValue? { objectValue?[key] }

    /// Compact debug rendering, used by the spike output.
    public var short: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return "\(b)"
        case .int(let i): return "\(i)"
        case .double(let d): return String(format: "%.4f", d)
        case .string(let s): return s
        case .array(let a): return "[" + a.map(\.short).joined(separator: ", ") + "]"
        case .object(let o): return "{" + o.map { "\($0.key)=\($0.value.short)" }.sorted().joined(separator: " ") + "}"
        }
    }
}

public enum SurrealError: Error, CustomStringConvertible {
    case notConnected
    case transport(String)
    case server(code: Int, message: String)
    case decoding(String)
    case timeout(method: String)

    public var description: String {
        switch self {
        case .notConnected: return "notConnected"
        case .transport(let m): return "transport(\(m))"
        case .server(let c, let m): return "server(\(c)): \(m)"
        case .decoding(let m): return "decoding(\(m))"
        case .timeout(let m): return "timeout(\(m))"
        }
    }
}

/// One statement's result inside a `query` response.
public struct QueryResult: Sendable {
    public let status: String
    public let time: String
    public let result: SurrealValue
    public var ok: Bool { status == "OK" }
    /// `result` as rows (the common SELECT shape).
    public var rows: [[String: SurrealValue]] {
        (result.arrayValue ?? []).compactMap(\.objectValue)
    }
}

public actor SurrealClient {
    private let url: URL
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var nextID = 1
    private var pending: [String: CheckedContinuation<SurrealValue, Error>] = [:]
    private var receiveLoop: Task<Void, Never>?

    public init(url: URL) { self.url = url }

    // MARK: connection

    public func connect() throws {
        let s = URLSession(configuration: .default)
        var req = URLRequest(url: url)
        // v3 speaks CBOR by default — ask for JSON explicitly
        req.setValue("json", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let t = s.webSocketTask(with: req)
        t.resume()
        session = s
        task = t
        receiveLoop = Task { await self.readLoop() }
    }

    public func close() {
        receiveLoop?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        for (_, c) in pending { c.resume(throwing: SurrealError.notConnected) }
        pending.removeAll()
    }

    private func readLoop() async {
        while !Task.isCancelled, let t = task {
            do {
                let msg = try await t.receive()
                let data: Data
                switch msg {
                case .data(let d): data = d
                case .string(let s): data = Data(s.utf8)
                @unknown default: continue
                }
                handle(data)
            } catch {
                if Task.isCancelled { return }
                for (_, c) in pending { c.resume(throwing: SurrealError.transport("\(error)")) }
                pending.removeAll()
                return
            }
        }
    }

    private func handle(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let id: String
        if let s = obj["id"] as? String { id = s }
        else if let n = obj["id"] as? Int { id = String(n) }
        else { return }   // notification (live query) — not used by this spike
        guard let cont = pending.removeValue(forKey: id) else { return }
        if let err = obj["error"] as? [String: Any] {
            cont.resume(throwing: SurrealError.server(
                code: err["code"] as? Int ?? -1,
                message: err["message"] as? String ?? "unknown"))
        } else {
            cont.resume(returning: SurrealValue(json: obj["result"] ?? NSNull()))
        }
    }

    // MARK: RPC

    @discardableResult
    private func rpc(_ method: String, _ params: [Any], timeout: Double = 30) async throws -> SurrealValue {
        guard let t = task else { throw SurrealError.notConnected }
        let id = String(nextID); nextID += 1
        let payload: [String: Any] = ["id": id, "method": method, "params": params]
        // `.withoutEscapingSlashes` is load-bearing: Foundation escapes "/" as
        // "\/" by default, and SurrealDB's WS parser never answers a frame
        // containing that escape — the call just hangs until it times out.
        // Every file path and URL we bind depends on this (ARCHITECTURE App. C.0).
        let data = try JSONSerialization.data(withJSONObject: payload,
                                              options: [.withoutEscapingSlashes])
        let text = String(data: data, encoding: .utf8)!

        // Timeout is a separate task that fails the *pending* entry, rather
        // than a task-group race. A group child closure is nonisolated, so the
        // continuation could only be registered from inside another Task —
        // and a fast reply then arrives before that Task runs, finds no
        // waiter, gets dropped, and the caller hangs forever. Registering
        // synchronously on the actor is what makes this correct.
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.fail(id: id, error: SurrealError.timeout(method: method))
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<SurrealValue, Error>) in
            pending[id] = c                       // registered before the frame goes out
            Task { [weak self] in
                do { try await t.send(.string(text)) }
                catch { await self?.fail(id: id, error: SurrealError.transport("\(error)")) }
            }
        }
    }

    /// Resolves a waiting call with an error. `removeValue` returning nil means
    /// the reply already landed, so a late timeout can never double-resume.
    private func fail(id: String, error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    // MARK: public API

    public func signin(user: String, pass: String) async throws {
        _ = try await rpc("signin", [["user": user, "pass": pass]])
    }

    public func use(namespace: String, database: String) async throws {
        _ = try await rpc("use", [namespace, database])
    }

    /// Runs SurrealQL; returns one `QueryResult` per statement.
    @discardableResult
    public func query(_ sql: String, vars: [String: Any] = [:], timeout: Double = 60) async throws -> [QueryResult] {
        let raw = try await rpc("query", vars.isEmpty ? [sql] : [sql, vars], timeout: timeout)
        guard let arr = raw.arrayValue else {
            throw SurrealError.decoding("unexpected query shape: \(raw.short.prefix(120))")
        }
        return arr.map {
            QueryResult(status: $0["status"]?.stringValue ?? "?",
                        time: $0["time"]?.stringValue ?? "?",
                        result: $0["result"] ?? .null)
        }
    }

    /// Runs SurrealQL and throws unless every statement succeeded.
    @discardableResult
    public func exec(_ sql: String, vars: [String: Any] = [:]) async throws -> [QueryResult] {
        let results = try await query(sql, vars: vars)
        for (i, r) in results.enumerated() where !r.ok {
            throw SurrealError.server(code: i, message: "stmt \(i) \(r.status): \(r.result.short.prefix(160))")
        }
        return results
    }
}
