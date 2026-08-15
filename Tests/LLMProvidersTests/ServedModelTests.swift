import Testing
import Foundation
import Network
import AgentKit
@testable import LLMProviders

// ─────────────────────────────────────────────────────────────
// P15.1 — the model name comes from the server, not from the config.
//
// A pinned name is correct until the checkpoint is swapped, and then it is
// wrong in the least useful way available: the endpoint reports itself
// unavailable, drops out of the routing chain, and the app answers from the
// small model on this Mac with nothing on screen saying why. Measured once
// already — the GX10's name changed the day `--served-model-name` was dropped
// (E.21).
//
// These run against a loopback server rather than a real endpoint, because what
// is under test is what the *app* sends: no machine on the network can be asked
// to swap a checkpoint in the middle of a test.
// ─────────────────────────────────────────────────────────────

/// The smallest OpenAI-compatible server that can answer these questions.
private final class StubEndpoint: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var _served: [String]
    private var _chatStatus = 200
    private var _dropsMidStream = false
    private var _chunks: [String]?
    private var _bodies: [String] = []
    /// How many chat requests must be connected before any of them is answered,
    /// and how many have arrived. Its own condition rather than the main lock:
    /// the waiting happens while holding it, and everything else must stay
    /// answerable meanwhile.
    private let gate = NSCondition()
    private var gateSize = 0
    private var arrived = 0
    /// Filled in after the listener is up. A `var` so every stored property is
    /// initialised before `newConnectionHandler` — which reaches back into this
    /// object — is set, and that handler **must** be set before `start`, or the
    /// listener fails with EINVAL and never becomes ready.
    private(set) var port: UInt16 = 0

    init(serving: [String]) throws {
        _served = serving
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Port 0 — the system picks, and the port is read back below. A test
        // that picks its own number is a test that fails on whichever machine
        // is already using it (the same rule `check.sh` enforces).
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: 0)!)
        let ready = DispatchSemaphore(value: 0)
        let seen = Reported()
        listener.stateUpdateHandler = { state in
            seen.record("\(state)")
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            self?.read(connection, buffer: Data())
        }
        listener.start(queue: .global())
        guard ready.wait(timeout: .now() + 5) == .success, let real = listener.port else {
            throw StubError.didNotStart(seen.all())
        }
        port = real.rawValue
    }

    enum StubError: Error { case didNotStart(String) }

    private final class Reported: @unchecked Sendable {
        private let lock = NSLock()
        private var states: [String] = []
        func record(_ state: String) { lock.withLock { states.append(state) } }
        func all() -> String { lock.withLock { states.joined(separator: " → ") } }
    }

    deinit { listener.cancel() }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/v1")! }

    /// Swaps the checkpoint, exactly as somebody restarting vllm would.
    func swap(to models: [String], chatStatus: Int = 200) {
        lock.withLock { _served = models; _chatStatus = chatStatus }
    }

    /// Answers, starts the stream, and then goes away — a cable pulled while
    /// the model was talking.
    func dropMidStream() { lock.withLock { _dropsMidStream = true } }

    /// Says exactly these pieces, one SSE chunk each — including tags split
    /// across a boundary, which is how they really arrive.
    func says(_ chunks: [String]) { lock.withLock { _chunks = chunks } }

    /// Answers nobody until this many chat requests are connected at once.
    ///
    /// The only way to ask "how many can be in flight" and get an answer that
    /// is not a stopwatch reading: if the client can only open six sockets, the
    /// seventh request never arrives, the gate never opens, and the test says
    /// so by timing out rather than by being slow.
    func holdUntil(_ streams: Int) { gate.withLock { gateSize = streams } }

    /// The `model` field of every chat request received, in order.
    var modelsAskedFor: [String] {
        lock.withLock { _bodies }.compactMap { body in
            guard let data = body.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return object["model"] as? String
        }
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] chunk, _, isComplete, _ in
            guard let self else { return }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }
            guard let text = String(data: buffer, encoding: .utf8),
                  let headerEnd = text.range(of: "\r\n\r\n") else {
                if isComplete { connection.cancel() } else { self.read(connection, buffer: buffer) }
                return
            }
            let head = String(text[text.startIndex..<headerEnd.lowerBound])
            let body = String(text[headerEnd.upperBound...])
            // Wait for the whole body before answering — a request split across
            // packets is the ordinary case, not the exception.
            if let length = Self.contentLength(in: head), body.utf8.count < length {
                self.read(connection, buffer: buffer)
                return
            }
            self.answer(connection, head: head, body: body)
        }
    }

    private static func contentLength(in head: String) -> Int? {
        head.split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) }
    }

    private func answer(_ connection: NWConnection, head: String, body: String) {
        let isModels = head.contains("/v1/models")
        let served = lock.withLock { _served }
        let status = isModels ? 200 : lock.withLock { _chatStatus }
        if !isModels { lock.withLock { _bodies.append(body) } }

        // Everybody waits for everybody, when a test asked for that.
        if !isModels {
            gate.lock()
            if gateSize > 0 {
                arrived += 1
                if arrived >= gateSize {
                    gate.broadcast()
                } else {
                    // Bounded: a client that cannot open this many connections
                    // must fail the assertion, not hang the suite.
                    _ = gate.wait(until: Date().addingTimeInterval(10))
                }
            }
            gate.unlock()
        }

        let payload: String
        if isModels {
            let entries = served
                .map { #"{"id":"\#($0)","max_model_len":32768}"# }
                .joined(separator: ",")
            payload = #"{"object":"list","data":[\#(entries)]}"#
        } else if status == 200 {
            let pieces = lock.withLock { _chunks } ?? ["ok"]
            let events = pieces.map { piece in
                let escaped = piece
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "\n", with: "\\n")
                return #"data: {"choices":[{"delta":{"content":"\#(escaped)"}}]}"#
            }
            payload = (events
                + [#"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#, "data: [DONE]", "", ""])
                .joined(separator: "\n\n")
        } else {
            payload = #"{"error":{"message":"model not found"}}"#
        }

        // A stream that stops halfway: the headers promise more than is sent,
        // and then the connection goes away.
        let drops = !isModels && lock.withLock { _dropsMidStream }
        let announced = drops ? payload.utf8.count + 4_096 : payload.utf8.count
        let body = drops ? String(payload.prefix(20)) : payload

        let response = """
            HTTP/1.1 \(status) OK\r
            Content-Type: \(isModels || status != 200 ? "application/json" : "text/event-stream")\r
            Content-Length: \(announced)\r
            Connection: close\r
            \r
            \(body)
            """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.forceCancel()
        })
    }
}

private func request(_ text: String = "hi") -> LLMRequest {
    var request = LLMRequest(messages: [.init(.user, text)])
    request.timeout = 10
    return request
}

@Suite("Which model the app asks for (P15.1)", .serialized)
struct ServedModelTests {

    @Test("an empty model name is filled in from what the server serves",
          .timeLimit(.minutes(1)))
    func blankNameUsesTheServedModel() async throws {
        let stub = try StubEndpoint(serving: ["unsloth/Qwen3.8-27B-NVFP4"])
        let executor = VLLMExecutor(baseURL: stub.baseURL, model: "")

        _ = try await executor.complete(request())
        #expect(stub.modelsAskedFor == ["unsloth/Qwen3.8-27B-NVFP4"])
    }

    @Test("a checkpoint swapped under a running app is picked up, not retried forever",
          .timeLimit(.minutes(1)))
    func aSwapIsPickedUp() async throws {
        let stub = try StubEndpoint(serving: ["old-checkpoint"])
        let executor = VLLMExecutor(baseURL: stub.baseURL, model: "")
        _ = try await executor.complete(request())

        // vllm restarted on a different checkpoint. The old name is refused,
        // which is the signal to ask again rather than keep sending it.
        stub.swap(to: ["new-checkpoint"], chatStatus: 404)
        _ = try? await executor.complete(request())
        stub.swap(to: ["new-checkpoint"], chatStatus: 200)
        _ = try await executor.complete(request())

        #expect(stub.modelsAskedFor == ["old-checkpoint", "old-checkpoint", "new-checkpoint"],
                "the app kept asking for a checkpoint the server no longer has")
    }

    @Test("a server with several models is asked to be told which, not guessed at",
          .timeLimit(.minutes(1)))
    func manyModelsIsRefused() async throws {
        let stub = try StubEndpoint(serving: ["gpt-4o", "gpt-4o-mini"])
        let executor = VLLMExecutor(baseURL: stub.baseURL, model: "")

        await #expect(throws: LLMError.self) { _ = try await executor.complete(request()) }
        // Nothing was sent: guessing here would put the request on whichever
        // model happened to be listed first, and on a metered endpoint that is
        // a bill somebody did not agree to.
        #expect(stub.modelsAskedFor.isEmpty)
        #expect(await executor.isAvailable() == false)
    }

    // P15.1's other half, and P9.4's rule: the network going away mid-answer is
    // the case where the app used to print Foundation's English sentence into
    // the middle of a Thai screen — "สตรีมคำตอบขาดกลางคัน: Error
    // Domain=NSURLErrorDomain Code=-1005".
    @Test("a connection lost mid-answer is explained in words, not in an error code",
          .timeLimit(.minutes(1)))
    func aDroppedStreamIsReadable() async throws {
        let stub = try StubEndpoint(serving: ["m"])
        stub.dropMidStream()
        let executor = VLLMExecutor(identifier: "GX10", baseURL: stub.baseURL, model: "m")

        do {
            _ = try await executor.complete(request())
            Issue.record("a dropped stream came back as a finished answer")
        } catch let error as LLMError {
            let message = "\(error)"
            #expect(message.contains("GX10"), "the message does not say which endpoint went away")
            #expect(message.contains("ไม่ตอบ") || message.contains("นานเกินกำหนด"),
                    "not a sentence anybody can act on: \(message)")
            #expect(message.contains("NSURLErrorDomain") == false,
                    "Foundation's error code reached the person: \(message)")
        }
    }

    // P15.2b — a server started without `--reasoning-parser` streams the tags
    // inside `content`, exactly as the local tier does. Measured twice on this
    // endpoint (E.21), and the symptom is the model's English deliberation
    // printed above a Thai answer.
    @Test("thinking that arrives inside the answer is still kept out of it",
          .timeLimit(.minutes(1)))
    func unparsedReasoningIsSplitHere() async throws {
        let stub = try StubEndpoint(serving: ["m"])
        // The tags land across chunk boundaries, because that is how a stream
        // delivers them.
        stub.says(["<thi", "nk>The user asks in Thai. I should",
                   " answer in Thai.</think", ">\n\nสวัสดีครับ"])
        let executor = VLLMExecutor(baseURL: stub.baseURL, model: "m")

        let completion = try await executor.complete(request())
        #expect(completion.text == "สวัสดีครับ",
                "the model's thinking reached the answer: \(completion.text)")
        #expect(completion.reasoning.contains("answer in Thai"),
                "the thinking was dropped instead of kept apart")
        #expect(completion.text.contains("<think>") == false)
    }

    @Test("a server that does its own splitting is left alone",
          .timeLimit(.minutes(1)))
    func aParsedServerIsUntouched() async throws {
        let stub = try StubEndpoint(serving: ["m"])
        stub.says(["คำตอบ", "ที่ไม่มีแท็ก"])
        let executor = VLLMExecutor(baseURL: stub.baseURL, model: "m")

        let completion = try await executor.complete(request())
        #expect(completion.text == "คำตอบที่ไม่มีแท็ก")
        #expect(completion.reasoning.isEmpty)
    }

    // P15.5 — measured on the GX10 before it was written down: six streams
    // answered in the same time as one, and the seventh took 60% longer for
    // reasons that had nothing to do with the GPU. `URLSession.shared` allows
    // six connections per host, so a team of four specialists plus chat plus a
    // workflow was already queueing inside Foundation, silently, and the
    // "span of control" P16 is built on would have been a property of a default
    // nobody chose.
    @Test("more than six requests to one host really are in flight at once",
          .timeLimit(.minutes(1)))
    func concurrencyIsNotCappedAtSix() async throws {
        let stub = try StubEndpoint(serving: ["m"])
        let streams = 8
        stub.holdUntil(streams)
        let executor = VLLMExecutor(baseURL: stub.baseURL, model: "m")
        // Resolve the name first, so the catalogue request is not one of the
        // eight being counted.
        _ = try await executor.resolveModel()

        let answered = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<streams {
                group.addTask { (try? await executor.complete(request())) != nil }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(answered == streams,
                "only \(answered) of \(streams) got through — the rest were queued by the client")
    }

    @Test("a configured name is still checked against the catalogue",
          .timeLimit(.minutes(1)))
    func configuredNameIsStillChecked() async throws {
        let stub = try StubEndpoint(serving: ["served-model"])
        let wrong = VLLMExecutor(baseURL: stub.baseURL, model: "not-served")
        #expect(await wrong.isAvailable() == false)

        let right = VLLMExecutor(baseURL: stub.baseURL, model: "served-model")
        #expect(await right.isAvailable())
        _ = try await right.complete(request())
        #expect(stub.modelsAskedFor == ["served-model"])
    }
}
