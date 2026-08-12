import Foundation
import Observability

// ─────────────────────────────────────────────────────────────
// The one place a channel touches the network (ARCHITECTURE §8).
//
// Behind a protocol so every channel in this module can be driven end to end
// without a bot token: the tests hand it canned platform payloads and assert on
// what the channel does with them. P3.3 learned the alternative the hard way —
// code that can only be exercised against somebody else's live API gets
// exercised once, by hand, and then never again.
//
// It is also the only place a token appears in a URL, which is why the logging
// here redacts before it writes: Telegram puts the bot token in the *path*.
// ─────────────────────────────────────────────────────────────

public protocol HTTPTransport: Sendable {
    /// Returns the body, or throws. Non-2xx is an error carrying the body,
    /// because every platform below explains itself in the body.
    func send(_ request: URLRequest) async throws -> Data
}

public enum TransportError: Error, CustomStringConvertible, Equatable {
    case badStatus(code: Int, body: String)
    case notJSON(String)
    case platform(String)

    public var description: String {
        switch self {
        case .badStatus(let code, let body): "HTTP \(code): \(body.prefix(300))"
        case .notJSON(let text): "คำตอบไม่ใช่ JSON: \(text.prefix(200))"
        case .platform(let message): "แพลตฟอร์มปฏิเสธ: \(message)"
        }
    }
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 60) {
        let configuration = URLSessionConfiguration.ephemeral
        // Long polling holds a request open for its full timeout on purpose;
        // the request timeout has to be longer than the poll or every poll ends
        // as a cancellation.
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return data }
        guard (200..<300).contains(http.statusCode) else {
            throw TransportError.badStatus(code: http.statusCode,
                                           body: String(decoding: data, as: UTF8.self))
        }
        return data
    }
}

/// Small helpers every channel below needs, kept out of their files so the
/// platform code stays about the platform.
enum JSONHelp {
    static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TransportError.notJSON(String(decoding: data, as: UTF8.self))
        }
        return object
    }

    static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}

/// Removes a token from anything about to be logged. Telegram puts the token in
/// the URL path, so a plain "request failed: <url>" line would publish it into
/// the log stream.
func redacted(_ text: String, token: String?) -> String {
    guard let token, !token.isEmpty else { return text }
    return text.replacingOccurrences(of: token, with: "••••")
}
