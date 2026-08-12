import Foundation
import AgentKit
import Observability

// ─────────────────────────────────────────────────────────────
// What the metered tier has cost (ARCHITECTURE §9.5/§9.7, P5.6–P5.7).
//
// Durable because the ceilings are per day and per month: a budget that resets
// when the app restarts is not a budget. And itemised because §9.5's last row
// asks for "รายงานย้อนหลังต่อ session/role/โมเดล" — a single running total
// answers "how much" but never "on what", which is the question someone asks
// when the number surprises them.
// ─────────────────────────────────────────────────────────────

public struct SpendEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let at: Date
    public let costUSD: Double
    public let promptTokens: Int
    public let completionTokens: Int
    public let endpoint: String
    public let model: String
    public let role: String?

    public var tokens: Int { promptTokens + completionTokens }
}

public actor SurrealSpendLedger: SpendLedger {
    private let client: SurrealClient
    private let log = AppLog.logger("spend")
    /// Session totals are the one window that cannot come from the database:
    /// "this session" is a fact about this launch.
    private var sessionTotal: Double = 0

    public init(client: SurrealClient) {
        self.client = client
    }

    public func spend(now: Date) async -> SpendWindow {
        let entries = (try? await self.entries(since: startOfMonth(before: now))) ?? []
        let calendar = Calendar.current
        return SpendWindow(
            session: sessionTotal,
            today: entries.filter { calendar.isDate($0.at, inSameDayAs: now) }
                .reduce(0) { $0 + $1.costUSD },
            month: entries.reduce(0) { $0 + $1.costUSD })
    }

    public func record(cost: Double, promptTokens: Int, completionTokens: Int,
                       endpoint: String, model: String, role: String?, at: Date) async {
        sessionTotal += cost

        var content = ContentBuilder()
        content.setString("uid", OpaqueID.make("sp"))
        content.set("cost", cost)
        content.set("prompt_tokens", promptTokens)
        content.set("completion_tokens", completionTokens)
        content.setString("endpoint", endpoint)
        content.setString("model", model)
        content.setString("role", role)
        content.raw("at", "time::now()")
        do {
            try await client.exec("CREATE spend CONTENT \(content.content)", vars: content.vars)
        } catch {
            // Loud, like the task ledger: a spend row that silently fails to
            // write means tomorrow's ceiling is measured against yesterday's
            // incomplete total, and the budget quietly stops being one.
            log.error("spend write failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Everything since a date, newest first — what the usage report reads.
    public func entries(since: Date) async throws -> [SpendEntry] {
        let rows = try await client.query(
            "SELECT * FROM spend WHERE at >= $since ORDER BY at DESC",
            vars: ["since": ISO8601DateFormatter().string(from: since)]).first?.rows ?? []

        return rows.compactMap { row -> SpendEntry? in
            guard let id = row["uid"]?.stringValue else { return nil }
            return SpendEntry(
                id: id,
                // SurrealDB hands datetimes back as strings; parsed here so
                // the day/month windows are grouped on the row's own time
                // rather than on when it happened to be read.
                at: (row["at"]?.stringValue).flatMap(Self.date) ?? Date.distantPast,
                costUSD: row["cost"]?.doubleValue ?? 0,
                promptTokens: row["prompt_tokens"]?.intValue ?? 0,
                completionTokens: row["completion_tokens"]?.intValue ?? 0,
                endpoint: row["endpoint"]?.stringValue ?? "",
                model: row["model"]?.stringValue ?? "",
                role: row["role"]?.stringValue)
        }
    }

    /// Grouped the way the question is usually asked: "what did the money go
    /// on?" rather than "how much was there".
    public func totals(since: Date) async throws -> [(key: String, costUSD: Double, tokens: Int)] {
        let entries = try await self.entries(since: since)
        var byModel: [String: (Double, Int)] = [:]
        for entry in entries {
            let key = entry.role.map { "\(entry.model) · \($0)" } ?? entry.model
            let current = byModel[key] ?? (0, 0)
            byModel[key] = (current.0 + entry.costUSD, current.1 + entry.tokens)
        }
        return byModel.map { (key: $0.key, costUSD: $0.value.0, tokens: $0.value.1) }
            .sorted { $0.costUSD > $1.costUSD }
    }

    static func date(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private func startOfMonth(before date: Date) -> Date {
        Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: date))
            ?? date
    }
}
