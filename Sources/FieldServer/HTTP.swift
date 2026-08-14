import Foundation

// ─────────────────────────────────────────────────────────────
// Just enough HTTP to serve one form (ARCHITECTURE §20.7).
//
// Written here rather than reused from `Channels` on purpose. The LINE webhook's
// reader is a webhook's reader: one path, one method, a signature header, and a
// body it hands straight to a verifier. This surface is different in the way
// that matters — it is **the only place in the system that takes input from
// somebody who is not the owner of the machine** — so its parser is the thing
// that has to refuse oversized bodies, absurd header counts and paths it does
// not recognise, and none of that belongs in a channel.
//
// It is also deliberately small. There is no routing table, no middleware and no
// content negotiation, because every one of those is a place for a request to
// end up somewhere nobody meant it to go.
// ─────────────────────────────────────────────────────────────

public struct HTTPRequest: Sendable, Equatable {
    public let method: String
    /// Path only — the query is parsed out separately so nothing downstream has
    /// to remember to split it off.
    public let path: String
    public let query: [String: String]
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, query: [String: String] = [:],
                headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    /// `application/x-www-form-urlencoded`, which is what a plain HTML form
    /// sends. Repeated names collect into a list, because a checkbox group is
    /// one question with several answers.
    public var formFields: [String: [String]] {
        Self.parseForm(String(decoding: body, as: UTF8.self))
    }

    static func parseForm(_ text: String) -> [String: [String]] {
        var fields: [String: [String]] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawName = parts.first else { continue }
            let name = percentDecoded(String(rawName))
            let value = parts.count > 1 ? percentDecoded(String(parts[1])) : ""
            fields[name, default: []].append(value)
        }
        return fields
    }

    static func percentDecoded(_ text: String) -> String {
        text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            ?? text.replacingOccurrences(of: "+", with: " ")
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, contentType: String = "text/html; charset=utf-8",
                body: Data = Data(), extraHeaders: [String: String] = [:]) {
        self.status = status
        var headers = extraHeaders
        headers["Content-Type"] = contentType
        headers["Content-Length"] = "\(body.count)"
        headers["Connection"] = "close"
        // The form is one self-contained page. Saying so means a page that has
        // been tampered with in transit cannot pull anything in from elsewhere.
        headers["Content-Security-Policy"] =
            "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; form-action 'self'"
        headers["X-Content-Type-Options"] = "nosniff"
        headers["Referrer-Policy"] = "no-referrer"
        // Nothing here should ever be cached: a half-filled questionnaire in a
        // shared browser's cache is a privacy incident with extra steps.
        headers["Cache-Control"] = "no-store"
        self.headers = headers
        self.body = body
    }

    public static func html(_ status: Int, _ html: String,
                            extraHeaders: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(status: status, body: Data(html.utf8), extraHeaders: extraHeaders)
    }

    public var wire: Data {
        var text = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"
        var data = Data(text.utf8)
        data.append(body)
        return data
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 410: "Gone"
        case 413: "Payload Too Large"
        case 429: "Too Many Requests"
        case 503: "Service Unavailable"
        default: "Error"
        }
    }
}

public enum HTTPParseError: Error, Equatable {
    case malformed
    case tooLarge
}

public enum HTTPParser {
    /// Hard ceilings, applied before anything is interpreted.
    ///
    /// A questionnaire submission is a few kilobytes; anything approaching this
    /// is either a mistake or somebody probing. Refusing at the size check costs
    /// one comparison, and refusing later costs however much memory the sender
    /// chose.
    public static let maximumBody = 256 * 1024
    public static let maximumHeader = 16 * 1024

    /// Returns the request once the whole body has arrived, or `nil` if more
    /// bytes are still needed.
    public static func parse(_ buffer: Data) throws -> HTTPRequest? {
        guard buffer.count <= maximumBody + maximumHeader else { throw HTTPParseError.tooLarge }
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            guard buffer.count <= maximumHeader else { throw HTTPParseError.tooLarge }
            return nil
        }

        let head = String(decoding: buffer[..<separator.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw HTTPParseError.malformed }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { throw HTTPParseError.malformed }
        let method = String(parts[0])
        let target = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let declared = Int(headers["content-length"] ?? "0") ?? 0
        guard declared <= maximumBody else { throw HTTPParseError.tooLarge }
        let bodyStart = separator.upperBound
        let available = buffer.count - bodyStart
        guard available >= declared else { return nil }
        let body = buffer[bodyStart..<(bodyStart + declared)]

        var path = target
        var query: [String: String] = [:]
        if let mark = target.firstIndex(of: "?") {
            path = String(target[..<mark])
            for (name, values) in HTTPRequest.parseForm(String(target[target.index(after: mark)...])) {
                query[name] = values.first
            }
        }

        return HTTPRequest(method: method, path: path, query: query,
                           headers: headers, body: Data(body))
    }
}

/// Escapes text for HTML. Used on **everything** that came from outside or from
/// a person: an instrument's own prompts are typed by a researcher, and a
/// researcher who pastes a `<` into a question should get a `<`, not a tag.
public func htmlEscaped(_ text: String) -> String {
    var out = ""
    out.reserveCapacity(text.count)
    for character in text {
        switch character {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        case "'": out += "&#39;"
        default: out.append(character)
        }
    }
    return out
}
