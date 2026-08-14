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
    public func start(serving instrument: PublishedInstrument,
                      port: UInt16 = 8_760) async throws -> ServingAddress {
        guard listener == nil else { throw FieldServerError.alreadyRunning }

        let parameters = NWParameters.tcp
        // Loopback is not enough — the point is other people's phones — and the
        // internet is not on offer. Binding to the LAN interfaces is exactly the
        // middle, and there is no tunnel here to widen it.
        parameters.allowLocalEndpointReuse = true
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
        listener.start(queue: .global(qos: .userInitiated))

        self.listener = listener
        self.port = port
        self.published = instrument
        self.wave = Wave(instrumentID: instrument.instrument.id,
                         version: instrument.instrument.version)

        log.info("field server open on \(port, privacy: .public) for instrument \(instrument.id, privacy: .public)")
        await spans?.record(Span(name: "field.wave.open", status: .succeeded,
                                 endedAt: Date(),
                                 detail: "instrument \(instrument.instrument.id) "
                                     + "v\(instrument.instrument.version) · wave \(wave?.id ?? "")"))
        return ServingAddress(port: port, hosts: Self.lanAddresses())
    }

    /// Closes the wave and stops listening. Closing first, on purpose: for the
    /// moment between the two, the endpoint is up and refusing, which is the
    /// behaviour §20.7 invariant 5 asks for.
    public func stop() async {
        wave?.close()
        listener?.cancel()
        listener = nil
        if let wave {
            log.info("field server closed wave \(wave.id, privacy: .public)")
            await spans?.record(Span(name: "field.wave.close", status: .succeeded,
                                     endedAt: Date(), detail: "wave \(wave.id)"))
        }
    }

    /// Closes the round without giving up the port — so a late POST gets an
    /// explicit "this round is closed" rather than a connection refused, which
    /// somebody would read as a network problem and retry.
    public func closeWave() async {
        wave?.close()
        if let wave {
            await spans?.record(Span(name: "field.wave.close", status: .succeeded,
                                     endedAt: Date(), detail: "wave \(wave.id)"))
        }
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
            return HTTPResponse.html(200, FormRuntime.page(for: published,
                                                           wave: wave?.id ?? ""))

        case ("POST", "/submit"):
            return await submit(request, published: published)

        case (_, "/submit"), (_, "/"):
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
            let submission = Submission(id: OpaqueID.make("sb"),
                                        instrumentID: published.instrument.id,
                                        version: published.instrument.version,
                                        waveID: wave.id,
                                        consentDigest: validated.consentDigest,
                                        answers: validated.answers,
                                        droppedFields: validated.droppedFields)
            try await store.append(submission)

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
                                                           notice: problem.description))
        } catch {
            log.error("could not store a submission: \(error)")
            return HTTPResponse.html(503, FormRuntime.message(
                title: "บันทึกไม่สำเร็จ",
                text: "ระบบบันทึกคำตอบไม่สำเร็จ กรุณาลองใหม่อีกครั้ง หรือแจ้งผู้วิจัย"))
        }
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

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.wire,
                        completion: .contentProcessed { _ in connection.cancel() })
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
