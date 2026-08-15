import Foundation

// ─────────────────────────────────────────────────────────────
// How busy the server actually is (ARCHITECTURE §17.1, §22.6 · P15.5/P15.6).
//
// **Why this is not a field on an agent.** §2.5's rule — evidence, not claims —
// applies to the system's own status as much as to a specialist's work. An
// organisation chart where each box reports its own state is a chart that says
// what everybody believes; the queue inside vLLM is what is true. `/metrics` has
// been open all along, so the busy light can be read rather than asked for.
//
// Prometheus text format, parsed for the two gauges that answer the question:
//
//     vllm:num_requests_running{model_name="…"} 3.0
//     vllm:num_requests_waiting{model_name="…"} 1.0
//
// Everything else in that endpoint is left alone deliberately. A parser that
// tries to understand the whole format is a parser that breaks when vLLM adds a
// histogram bucket.
// ─────────────────────────────────────────────────────────────

public struct ServerLoad: Sendable, Equatable {
    /// Requests the server is generating for right now.
    public let running: Int
    /// Requests admitted and queued behind them.
    public let waiting: Int

    public init(running: Int, waiting: Int) {
        self.running = running
        self.waiting = waiting
    }

    /// Nothing queued and nothing generating. The only honest form of "idle" —
    /// a server can be idle for this app and busy for somebody else on the LAN,
    /// and this reports the machine, not the app's share of it.
    public var isIdle: Bool { running == 0 && waiting == 0 }

    public var total: Int { running + waiting }

    /// Reads the two gauges out of a Prometheus exposition body.
    ///
    /// Returns nil when neither gauge is there at all — a server with metrics
    /// switched off must be tellable from a server with nothing running, or the
    /// screen would show a confident zero for a machine it cannot see.
    public static func parse(_ text: String) -> ServerLoad? {
        var running: Int?
        var waiting: Int?
        for line in text.split(separator: "\n") {
            // `# HELP` and `# TYPE` carry the same metric names as the samples,
            // so comments are skipped before matching rather than after.
            guard !line.hasPrefix("#") else { continue }
            if let value = value(of: "vllm:num_requests_running", in: line) { running = value }
            if let value = value(of: "vllm:num_requests_waiting", in: line) { waiting = value }
        }
        guard running != nil || waiting != nil else { return nil }
        return ServerLoad(running: running ?? 0, waiting: waiting ?? 0)
    }

    /// The value of one sample line. The gauges are floats in the exposition
    /// format (`3.0`) and whole requests in reality, so they are read as
    /// doubles and reported as counts.
    private static func value(of metric: String, in line: Substring) -> Int? {
        guard line.hasPrefix(metric) else { return nil }
        // A label set may follow the name; the value is always the last field.
        guard let last = line.split(separator: " ").last, let number = Double(last) else {
            return nil
        }
        return Int(number.rounded())
    }
}

/// Asks an OpenAI-compatible server how busy it is.
///
/// Separate from `VLLMExecutor` because it is not part of answering a request:
/// the busy light is read on a timer by whatever is showing it, and a screen
/// polling this must not be able to hold up a turn.
public struct ServerLoadReader: Sendable {
    /// The endpoint's `/metrics`, which is beside `/v1` rather than under it.
    private let metricsURL: URL

    /// - Parameter baseURL: the same `…/v1` URL the executor uses.
    public init(baseURL: URL) {
        self.metricsURL = baseURL.deletingLastPathComponent().appending(path: "metrics")
    }

    /// Nil when the server does not answer or does not expose the gauges —
    /// which is a different thing from an idle server, and stays different all
    /// the way to the screen.
    public func read(timeout: TimeInterval = 3) async -> ServerLoad? {
        var request = URLRequest(url: metricsURL)
        request.timeoutInterval = timeout
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return ServerLoad.parse(text)
    }
}
