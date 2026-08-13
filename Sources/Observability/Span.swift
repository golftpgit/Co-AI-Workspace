import Foundation
import AgentKit
import os

// ─────────────────────────────────────────────────────────────
// Observability (ARCHITECTURE §16) — ONE span stream for everything.
// v1 kept Live Monitor and Process Manager on separate, drifting data
// sources; here every module emits into the same sink and every view
// (session, global audit, process list) is a filter over it.
// P0 ships the type + console sink; the SurrealDB sink lands in P1.6.
// ─────────────────────────────────────────────────────────────

public struct SpanID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    /// Opaque and prefixed so the database never re-types it (AgentKit.OpaqueID).
    public init() { self.rawValue = OpaqueID.make(OpaqueID.span) }
    public var description: String { rawValue }
}

public enum SpanStatus: String, Sendable, Codable {
    case running, succeeded, failed, cancelled, awaitingApproval
}

public struct Span: Sendable, Codable, Identifiable {
    public let id: SpanID
    public let parent: SpanID?
    /// Human-facing name: "kb_search", "researcher: gather sources", …
    public let name: String
    public let role: Role?
    public let scope: Scope?
    public var status: SpanStatus
    public let startedAt: Date
    public var endedAt: Date?
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var detail: String?
    /// Which leaf of the plan this happened against (§19.6, P10.15).
    ///
    /// The link the schedule and four of the six tolerances were waiting for:
    /// spans have always known how long something took, and until now nothing
    /// could say what it took that long *for*.
    public var workPackage: String?

    public var duration: TimeInterval? {
        endedAt.map { $0.timeIntervalSince(startedAt) }
    }

    public init(id: SpanID = SpanID(),
                parent: SpanID? = nil,
                name: String,
                role: Role? = nil,
                scope: Scope? = nil,
                status: SpanStatus = .running,
                startedAt: Date = Date(),
                endedAt: Date? = nil,
                promptTokens: Int? = nil,
                completionTokens: Int? = nil,
                detail: String? = nil,
                workPackage: String? = nil) {
        self.id = id
        self.parent = parent
        self.name = name
        self.role = role
        self.scope = scope
        self.status = status
        self.workPackage = workPackage
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.detail = detail
    }
}

/// Where spans go. P1.6 adds a SurrealDB-backed sink; tests use an in-memory one.
public protocol SpanSink: Sendable {
    func record(_ span: Span) async
}

public actor InMemorySpanSink: SpanSink {
    public private(set) var spans: [Span] = []
    public init() {}
    public func record(_ span: Span) { spans.append(span) }
    public func spans(named name: String) -> [Span] { spans.filter { $0.name == name } }
    public func clear() { spans.removeAll() }
}

public struct ConsoleSpanSink: SpanSink {
    private let logger = Logger(subsystem: AppLog.subsystem, category: "span")
    public init() {}
    public func record(_ span: Span) {
        let ms = span.duration.map { String(format: "%.0fms", $0 * 1000) } ?? "…"
        logger.debug("[\(span.status.rawValue, privacy: .public)] \(span.name, privacy: .public) \(ms, privacy: .public)")
    }
}

/// Convenience for the common begin/end pair; guarantees an end span is
/// recorded even when the body throws (a running span that never closes is
/// how observability quietly lies).
public struct SpanRecorder: Sendable {
    private let sink: any SpanSink
    public init(sink: any SpanSink) { self.sink = sink }

    public func run<T>(_ name: String,
                       role: Role? = nil,
                       scope: Scope? = nil,
                       parent: SpanID? = nil,
                       body: () async throws -> T) async rethrows -> T {
        var span = Span(parent: parent, name: name, role: role, scope: scope)
        await sink.record(span)
        do {
            let value = try await body()
            span.status = .succeeded
            span.endedAt = Date()
            await sink.record(span)
            return value
        } catch {
            span.status = error is CancellationError ? .cancelled : .failed
            span.endedAt = Date()
            span.detail = "\(error)"
            await sink.record(span)
            throw error
        }
    }
}

public enum AppLog {
    public static let subsystem = "com.coaiworkspace.app"
    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
