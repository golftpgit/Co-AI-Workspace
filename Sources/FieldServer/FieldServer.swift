import Foundation
import Network
import AgentKit
import Observability
import Instruments
import OLTP

// ─────────────────────────────────────────────────────────────
// M16 FieldServer (ARCHITECTURE §20.7).
//
// The only surface in the system that takes input from somebody who is not the
// owner of this machine. Everything else is driven by the owner or by a channel
// that has already proved who it is, which is why this is a module of its own
// and not a corner of M15: mixing an untrusted surface into trusted logic is bug
// B2 of v1 wearing different clothes.
//
// What that means in this file:
//
//  • It serves `PublishedInstrument` and nothing else. There is no way to hand it
//    a draft, because a draft has no representation the type system will accept
//    (§20.6 invariant 2). The gate is not consulted here — it cannot be skipped
//    here, which is stronger.
//  • **There are no admin endpoints.** Not protected ones: absent. Starting,
//    stopping, opening and closing a wave all happen in the app, on the owner's
//    side of the wall.
//  • LAN-only is the default and there is no tunnel in the box. Reaching this
//    from the internet has to be somebody's deliberate act with their own
//    router, taken with the warning in front of them.
//  • Closing a wave makes the endpoint refuse. Hiding the button would leave the
//    endpoint answering, and the endpoint is what `curl` talks to.
// ─────────────────────────────────────────────────────────────

/// One round of collection (§20.7). Open, then closed — and closed is a fact the
/// endpoint enforces, not a state the page describes.
public struct Wave: Sendable, Equatable, Identifiable {
    public let id: String
    public let instrumentID: String
    public let version: Int
    public let openedAt: Date
    public private(set) var closedAt: Date?

    public var isOpen: Bool { closedAt == nil }

    public init(id: String = OpaqueID.make("wv"), instrumentID: String, version: Int,
                openedAt: Date = Date(), closedAt: Date? = nil) {
        self.id = id
        self.instrumentID = instrumentID
        self.version = version
        self.openedAt = openedAt
        self.closedAt = closedAt
    }

    public mutating func close(at date: Date = Date()) {
        if closedAt == nil { closedAt = date }
    }
}

public enum FieldServerError: Error, CustomStringConvertible, Equatable {
    case portUnavailable(UInt16, String)
    case alreadyRunning

    public var description: String {
        switch self {
        case .portUnavailable(let port, let message):
            "เปิดพอร์ต \(port) ไม่ได้: \(message)"
        case .alreadyRunning:
            "เซิร์ฟเวอร์กำลังทำงานอยู่แล้ว"
        }
    }
}

/// How the server is reachable, for the app to show and for a person to type
/// into a phone.
public struct ServingAddress: Sendable, Equatable {
    public let port: UInt16
    /// The LAN addresses of this machine. Several, because a laptop on wifi and
    /// ethernet has more than one and only the person in the room knows which
    /// network the respondents are on.
    public let hosts: [String]

    public var urls: [String] { hosts.map { "http://\($0):\(port)/" } }
}

public actor FieldServerHost {
    private let store: ResponseStore
    private let log = AppLog.logger("fieldserver")
    private let spans: (any SpanSink)?

    private var listener: NWListener?
    private var published: PublishedInstrument?
    private var wave: Wave?
    private var port: UInt16 = 0
    /// Requests seen per remote address in the current window — the whole rate
    /// limiter. Crude on purpose: this serves a questionnaire on a local
    /// network, and anything more elaborate would be a second thing to get wrong.
    private var recentRequests: [String: (count: Int, since: Date)] = [:]
    private let requestsPerMinute = 120

    public init(store: ResponseStore, spans: (any SpanSink)? = nil) {
        self.store = store
        self.spans = spans
    }

    public var isRunning: Bool { listener != nil }
    public var currentWave: Wave? { wave }
    public var servingInstrument: PublishedInstrument? { published }

    // MARK: - lifecycle

    /// Opens a wave and starts listening.
    ///
    /// Takes the approved instrument by value: from here on the server serves a
    /// snapshot, so editing in the app — which §20.6 already turns into a new
    /// version — cannot change the form under somebody who is halfway through it.
    /// Starts listening and returns the address it is **actually** on.
    ///
    /// - Parameter port: `0` asks the system for a free one, which is the only
    ///   race-free way to get a port. The old shape — a caller finds a free
    ///   port, then asks to bind it — has a gap between the two in which
    ///   anything else can take it, and that gap is exactly what made
    ///   `SocketTests` fail once in three full runs and pass on its own.
    ///   Picking-then-binding is not slow, it is wrong.
    ///
    /// It also waits until the listener is *ready* before returning. It used to
    /// return as soon as `start` had been called, so the address handed back
    /// named a socket that might not be accepting yet — a second race, latent
    /// for the same reason as the first: the app only ever started one server
    /// and then waited for a human to open a browser.
    public func start(serving instrument: PublishedInstrument,
                      port: UInt16 = 8_760) async throws -> ServingAddress {
        guard listener == nil else { throw FieldServerError.alreadyRunning }

        let parameters = NWParameters.tcp
        // Loopback is not enough — the point is other people's phones — and the
        // internet is not on offer. Binding to the LAN interfaces is exactly the
        // middle, and there is no tunnel here to widen it.
        parameters.allowLocalEndpointReuse = true
        // `NWEndpoint.Port(rawValue: 0)` is `.any`, which is what asks the
        // system to choose.
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw FieldServerError.portUnavailable(port, "หมายเลขพอร์ตไม่ถูกต้อง")
        }

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: endpointPort)
        } catch {
            throw FieldServerError.portUnavailable(port, "\(error)")
        }

        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global(qos: .userInitiated))
            Task { await self?.serve(connection) }
        }
        try await Self.startAndWaitUntilReady(listener, requested: port)

        // What it is really on, which is the requested port unless 0 was asked
        // for. Reported rather than echoed back: a caller told "8760" when the
        // system chose 51234 cannot reach its own server.
        let boundPort = listener.port?.rawValue ?? port

        self.listener = listener
        self.port = boundPort
        self.published = instrument

        // Resume the round that is already open for this version rather than
        // starting a new one. Turning the server off for the night and on again
        // in the morning is not two rounds of data collection, and treating it as
        // two would split one population across two rows in the write-up.
        let existing = try? await store.waves(instrument: instrument.instrument.id,
                                              version: instrument.instrument.version)
        if let open = existing?.first(where: \.isOpen) {
            wave = Wave(id: open.id, instrumentID: instrument.instrument.id,
                        version: instrument.instrument.version, openedAt: open.openedAt)
            log.info("field server resumed wave \(open.id, privacy: .public)")
        } else {
            let fresh = Wave(instrumentID: instrument.instrument.id,
                             version: instrument.instrument.version)
            // Written down before the first answer can arrive: a round nobody can
            // point at afterwards is a round that did not happen, as far as a
            // methods section is concerned.
            try await store.openWave(id: fresh.id, instrument: fresh.instrumentID,
                                     version: fresh.version, at: fresh.openedAt)
            wave = fresh
            await spans?.record(Span(name: "field.wave.open", status: .succeeded,
                                     endedAt: Date(),
                                     detail: "instrument \(instrument.instrument.id) "
                                         + "v\(instrument.instrument.version) · wave \(fresh.id)"))
        }

        log.info("field server open on \(boundPort, privacy: .public) for instrument \(instrument.id, privacy: .public)")
        return ServingAddress(port: boundPort, hosts: Self.lanAddresses())
    }

    /// Starts the listener and does not come back until it is accepting, or
    /// has failed, or ten seconds have passed.
    ///
    /// `nonisolated` and static so the state handler is not hopping onto this
    /// actor while the actor is awaiting it.
    private nonisolated static func startAndWaitUntilReady(_ listener: NWListener,
                                                           requested port: UInt16) async throws {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func claim() -> Bool { lock.withLock { done ? false : { done = true; return true }() } }
        }
        let once = Once()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    // `.waiting` means it cannot bind — usually the port is
                    // taken. Treated as a failure rather than waited on, so a
                    // caller is told rather than left hanging.
                    if once.claim() {
                        continuation.resume(throwing:
                            FieldServerError.portUnavailable(port, "\(error)"))
                    }
                case .cancelled:
                    if once.claim() {
                        continuation.resume(throwing:
                            FieldServerError.portUnavailable(port, "ถูกยกเลิกก่อนเริ่มรับ"))
                    }
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    /// Stops listening. **Does not close the round**, because those are two
    /// different decisions: shutting the laptop is not "we have finished
    /// collecting", and a round that closes itself when the app quits is a round
    /// nobody can resume tomorrow morning.
    public func stop() async {
        listener?.cancel()
        listener = nil
        if let wave {
            log.info("field server stopped, wave \(wave.id, privacy: .public) still open")
        }
    }

    /// Closes the round, durably, without giving up the port — so a late POST
    /// gets an explicit "this round is closed" rather than a connection refused,
    /// which somebody would read as a network problem and retry.
    ///
    /// One way only. Reopening is starting a *new* round, because answers given
    /// after a stated closing date are a different population from the ones given
    /// before it.
    public func closeWave() async {
        guard var current = wave else { return }
        current.close()
        wave = current
        try? await store.closeWave(id: current.id, at: current.closedAt ?? Date())
        // Half-finished forms belong to the round that is now over. They were
        // collected under a consent for that round and nobody will ever submit
        // them, so keeping them is holding personal data with no purpose left
        // (§20.5).
        let discarded = (try? await store.discardDrafts(wave: current.id)) ?? 0
        if discarded > 0 {
            log.info("discarded \(discarded, privacy: .public) unfinished draft(s) with the round")
        }
        await spans?.record(Span(name: "field.wave.close", status: .succeeded,
                                 endedAt: Date(), detail: "wave \(current.id)"))
    }

    public func responseCount() async -> Int {
        guard let published else { return 0 }
        return (try? await store.submissionCount(instrument: published.instrument.id,
                                                 version: published.instrument.version)) ?? 0
    }

    // MARK: - serving

    private func serve(_ connection: NWConnection) async {
        let remote = Self.address(of: connection)
        var buffer = Data()
        while true {
            guard let chunk = await Self.receive(connection) else { break }
            buffer.append(chunk)
            do {
                guard let request = try HTTPParser.parse(buffer) else {
                    if chunk.isEmpty { break }
                    continue
                }
                let response = await handle(request, from: remote)
                send(response, on: connection)
                return
            } catch HTTPParseError.tooLarge {
                log.error("refused an oversized request from \(remote, privacy: .private)")
                send(HTTPResponse.html(413, FormRuntime.message(
                    title: "คำขอใหญ่เกินไป", text: "ข้อมูลที่ส่งมาใหญ่เกินกว่าที่แบบฟอร์มนี้รับ")),
                     on: connection)
                return
            } catch {
                send(HTTPResponse.html(400, FormRuntime.message(
                    title: "คำขอไม่ถูกต้อง", text: "อ่านคำขอนี้ไม่ได้")), on: connection)
                return
            }
        }
        connection.cancel()
    }

    /// The whole routing table. Split from the socket so every path can be
    /// tested by handing it a request — including the ones a browser cannot
    /// produce, which are the ones that matter.
    func handle(_ request: HTTPRequest, from remote: String) async -> HTTPResponse {
        guard allow(remote) else {
            return HTTPResponse.html(429, FormRuntime.message(
                title: "คำขอถี่เกินไป", text: "ส่งคำขอถี่เกินไป กรุณารอสักครู่แล้วลองใหม่"))
        }
        guard let published else {
            return HTTPResponse.html(503, FormRuntime.message(
                title: "ยังไม่เปิดรับคำตอบ", text: "ยังไม่มีแบบสอบถามที่เปิดอยู่"))
        }

        switch (request.method, request.path) {
        case ("GET", "/"), ("HEAD", "/"):
            guard wave?.isOpen == true else { return closedPage() }
            // `?code=P-…` is how a participant's link differs from anybody
            // else's. Passed straight through: to this module it is an opaque
            // string, and the file that could turn it into a person is not in
            // its module graph.
            //
            // `?resume=…` is somebody coming back to a form they started.
            if let token = request.query["resume"], !token.isEmpty {
                return await resume(token: token, published: published)
            }
            return HTTPResponse.html(200, FormRuntime.page(for: published,
                                                           wave: wave?.id ?? "",
                                                           code: request.query["code"]))

        case ("POST", "/save"):
            return await saveDraft(request, published: published)

        case ("POST", "/submit"):
            return await submit(request, published: published)

        case (_, "/save"), (_, "/submit"), (_, "/"):
            return HTTPResponse.html(405, FormRuntime.message(
                title: "วิธีเรียกไม่ถูกต้อง", text: "หน้านี้รับเฉพาะการเปิดหน้าและการส่งแบบฟอร์ม"))

        default:
            // Everything else, including anything that looks like an admin path.
            // There is nothing else here to find.
            return HTTPResponse.html(404, FormRuntime.message(
                title: "ไม่พบหน้านี้", text: "ไม่มีหน้านี้บนเซิร์ฟเวอร์แบบสอบถาม"))
        }
    }

    private func submit(_ request: HTTPRequest,
                        published: PublishedInstrument) async -> HTTPResponse {
        // §20.7 invariant 5, at the endpoint rather than on the page.
        guard let wave, wave.isOpen else { return closedPage(status: 410) }

        let fields = request.formFields
        // A submission naming a different instrument or version is not a late
        // answer to this one — it is an answer to a form this server is not
        // serving, and storing it would put two populations in one table.
        guard fields["__instrument"]?.first == published.instrument.id,
              fields["__version"]?.first == "\(published.instrument.version)" else {
            return HTTPResponse.html(400, FormRuntime.message(
                title: "แบบฟอร์มไม่ตรงกัน",
                text: "แบบฟอร์มที่ส่งมาไม่ตรงกับแบบสอบถามที่เปิดอยู่ กรุณาเปิดหน้าใหม่แล้วกรอกอีกครั้ง"))
        }

        do {
            let validated = try SubmissionValidator.validate(fields, against: published)
            let code = fields["__code"]?.first.flatMap { $0.isEmpty ? nil : $0 }
            let submission = Submission(id: OpaqueID.make("sb"),
                                        instrumentID: published.instrument.id,
                                        version: published.instrument.version,
                                        waveID: wave.id,
                                        consentDigest: validated.consentDigest,
                                        participantCode: code,
                                        answers: validated.answers,
                                        droppedFields: validated.droppedFields)
            try await store.append(submission)
            // A submitted form is not a draft any more. Left behind, it would be
            // a copy of somebody's answers with no purpose and no expiry.
            if let token = fields["__resume"]?.first, !token.isEmpty {
                try? await store.removeDraft(token: token)
            }

            if !validated.droppedFields.isEmpty {
                // Written down twice on purpose: a row, so it can be counted
                // later, and a log line, so somebody watching sees it happen.
                log.error("dropped \(validated.droppedFields.count, privacy: .public) unknown field(s) from a submission")
                await spans?.record(Span(name: "field.foreign_fields", status: .succeeded,
                                         endedAt: Date(),
                                         detail: "\(validated.droppedFields.count) field(s): "
                                             + validated.droppedFields.joined(separator: ", ")))
            }
            return HTTPResponse.html(200, FormRuntime.thanks(for: published))
        } catch let problem as SubmissionProblem {
            // Back to the form with the reason, rather than a bare 400: the
            // person on the other end is a participant, not a client.
            return HTTPResponse.html(400, FormRuntime.page(for: published,
                                                           wave: wave.id,
                                                           code: fields["__code"]?.first,
                                                           notice: problem.description))
        } catch {
            log.error("could not store a submission: \(error)")
            return HTTPResponse.html(503, FormRuntime.message(
                title: "บันทึกไม่สำเร็จ",
                text: "ระบบบันทึกคำตอบไม่สำเร็จ กรุณาลองใหม่อีกครั้ง หรือแจ้งผู้วิจัย"))
        }
    }

    /// Brings somebody back to the form they started (§20.7's SessionStore).
    ///
    /// A draft that belongs to a different instrument or version is refused
    /// rather than half-applied: the questions have changed underneath it, and
    /// pouring old answers into a new form is how a value ends up against a
    /// question nobody asked it for.
    private func resume(token: String, published: PublishedInstrument) async -> HTTPResponse {
        guard let wave, wave.isOpen else { return closedPage() }
        guard let draft = try? await store.draft(token: token),
              draft.instrumentID == published.instrument.id,
              draft.version == published.instrument.version else {
            return HTTPResponse.html(404, FormRuntime.message(
                title: "ไม่พบคำตอบที่บันทึกไว้",
                text: "ลิงก์นี้ไม่ตรงกับแบบสอบถามที่เปิดอยู่ หรือคำตอบที่บันทึกไว้ถูกลบไปแล้ว "
                    + "(คำตอบที่ยังไม่ได้ส่งจะถูกลบเมื่อปิดรอบเก็บข้อมูล)"))
        }
        let answered = HTTPRequest.parseForm(draft.fields)
        return HTTPResponse.html(200, FormRuntime.page(
            for: published, wave: wave.id,
            code: draft.participantCode, resume: draft.token, answered: answered,
            notice: "นี่คือคำตอบที่คุณบันทึกไว้เมื่อ "
                + draft.updatedAt.formatted(date: .abbreviated, time: .shortened)
                + " — กรอกต่อได้เลย"))
    }

    /// Saves a half-finished form and hands back the link that returns to it.
    private func saveDraft(_ request: HTTPRequest,
                           published: PublishedInstrument) async -> HTTPResponse {
        guard let wave, wave.isOpen else { return closedPage() }
        let fields = request.formFields
        guard fields["__instrument"]?.first == published.instrument.id,
              fields["__version"]?.first == "\(published.instrument.version)" else {
            return HTTPResponse.html(400, FormRuntime.message(
                title: "แบบฟอร์มไม่ตรงกัน",
                text: "แบบฟอร์มที่ส่งมาไม่ตรงกับแบบสอบถามที่เปิดอยู่"))
        }
        // Reuse the token if this is somebody saving a second time: one person
        // continuing their own form is not two drafts.
        let existing = fields["__resume"]?.first.flatMap { $0.isEmpty ? nil : $0 }
        let token = existing ?? Self.freshToken()
        let body = String(decoding: request.body, as: UTF8.self)

        do {
            try await store.save(Draft(token: token,
                                       instrumentID: published.instrument.id,
                                       version: published.instrument.version,
                                       waveID: wave.id,
                                       participantCode: fields["__code"]?.first
                                           .flatMap { $0.isEmpty ? nil : $0 },
                                       fields: body,
                                       updatedAt: Date()))
        } catch {
            log.error("could not save a draft: \(error)")
            return HTTPResponse.html(503, FormRuntime.message(
                title: "บันทึกไม่สำเร็จ", text: "บันทึกคำตอบที่กรอกไว้ไม่สำเร็จ กรุณาลองใหม่"))
        }
        let host = Self.lanAddresses().first ?? "127.0.0.1"
        return HTTPResponse.html(200, FormRuntime.saved(
            for: published, link: "http://\(host):\(port)/?resume=\(token)"))
    }

    /// A bearer credential for somebody's partial answers, living in a URL they
    /// keep — so it is long and random rather than short and readable, which is
    /// the opposite of a participant code and for the opposite reason.
    static func freshToken() -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyz0123456789")
        return String((0..<32).map { _ in alphabet.randomElement()! })
    }

    private func closedPage(status: Int = 410) -> HTTPResponse {
        HTTPResponse.html(status, FormRuntime.message(
            title: "ปิดรับคำตอบแล้ว",
            text: "รอบเก็บข้อมูลนี้ปิดแล้ว จึงไม่รับคำตอบเพิ่ม ขอบคุณที่สนใจเข้าร่วม"))
    }

    // MARK: - limits

    private func allow(_ remote: String) -> Bool {
        let now = Date()
        var entry = recentRequests[remote] ?? (0, now)
        if now.timeIntervalSince(entry.since) > 60 { entry = (0, now) }
        entry.count += 1
        recentRequests[remote] = entry
        return entry.count <= requestsPerMinute
    }

    // MARK: - sockets

    /// Sends the reply and closes the stream **gracefully**.
    ///
    /// The obvious version of this — send, then `cancel()` in the completion
    /// handler — is wrong in a way that only shows up under load, and it showed
    /// up: `.contentProcessed` fires when the bytes reach the transport, not when
    /// the other end has them, and `cancel()` resets the connection. With twenty
    /// phones submitting at once, some of them got a failed request for an answer
    /// that had already been stored, which is the worst failure this server has:
    /// the respondent sees an error and submits again.
    ///
    /// `.finalMessage` sends a FIN instead, so the client reads the whole
    /// response and closes; the connection is then cancelled once the peer is
    /// done, with a bound so a client that never closes cannot hold a socket.
    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.wire, contentContext: .finalMessage,
                        isComplete: true, completion: .contentProcessed { _ in
            Task {
                await Self.waitForPeerClose(connection)
                connection.cancel()
            }
        })
    }

    /// Waits for the client to close its side, or gives up after a few seconds.
    private static func waitForPeerClose(_ connection: NWConnection,
                                         timeout: Duration = .seconds(5)) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1) {
                        _, _, _, _ in continuation.resume()
                    }
                }
            }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
        }
    }

    private static func receive(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1,
                               maximumLength: HTTPParser.maximumBody + HTTPParser.maximumHeader) {
                data, _, isComplete, error in
                if let error {
                    _ = error
                    continuation.resume(returning: nil)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private static func address(of connection: NWConnection) -> String {
        switch connection.endpoint {
        case .hostPort(let host, _): "\(host)"
        default: "unknown"
        }
    }

    /// The machine's addresses on networks other people can reach. Loopback is
    /// excluded because it is the one address that helps nobody in the room.
    public static func lanAddresses() -> [String] {
        var addresses: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return addresses }
        defer { freeifaddrs(head) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let raw = current.pointee.ifa_addr else { continue }
            let family = raw.pointee.sa_family
            guard family == UInt8(AF_INET) else { continue }
            let name = String(cString: current.pointee.ifa_name)
            guard name != "lo0", !name.hasPrefix("utun"), !name.hasPrefix("awdl") else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(raw, socklen_t(raw.pointee.sa_len), &host,
                              socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            if !text.isEmpty, text != "127.0.0.1" { addresses.append(text) }
        }
        return addresses
    }
}
