import Foundation
import Analysis
import AgentKit

// ─────────────────────────────────────────────────────────────
// P6.3 — the connectors, against real servers (§12.2).
//
// The plan has said since P6.2 that PostgreSQL and MySQL "use exactly the same
// path" and that nobody had confirmed it with a server, because there was no
// server. There is one now: two throwaway containers on this machine. This is
// the probe that talks to them.
//
// An executable rather than a test for the usual reason — a suite that only
// passes where a database happens to be running is not a suite.
// ─────────────────────────────────────────────────────────────

@main
struct ConnectorCheck {
    static func main() async throws {
        let store = try AnalysisStore()

        // The claim that matters most is not that a good password works. It
        // is that a bad one fails *without printing the password*: DuckDB
        // quotes the failing statement back, and the statement is the
        // connection string with the credential in it (§12.2, P9.3).
        SecretStore.override("COAI_PROBE_WRONG", "hunter2-should-never-appear")
        let bad = DBConnector(alias: "bad", kind: .postgres,
                              target: "host=127.0.0.1 port=15432 user=postgres dbname=probe",
                              secretVariable: "COAI_PROBE_WRONG", readOnly: true)
        do {
            _ = try await store.attach(bad)
            print("== redaction: FAILED — a wrong password connected")
        } catch {
            let message = "\(error)"
            print("== redaction")
            print("  error: \(message.prefix(180))")
            print("  password in the message: \(message.contains("hunter2") ? "YES — LEAK" : "no")")
        }

        for (name, connector, query) in cases() {
            print("\n== \(name)")
            do {
                let attached = try await store.attach(connector)
                print("  attached as \(attached.alias)")
                let tables = try await store.query(
                    "SELECT table_name FROM information_schema.tables "
                        + "WHERE table_catalog = '\(attached.alias)' LIMIT 20")
                print("  tables: \(tables.rows.compactMap { $0.first ?? nil }.joined(separator: ", "))")

                let result = try await store.query(query)
                print("  \(query)")
                for row in result.rows.prefix(5) {
                    print("    " + row.map { $0 ?? "NULL" }.joined(separator: " | "))
                }
                print("  columns: " + result.columns.map { "\($0.name) \($0.type)" }
                    .joined(separator: ", "))
            } catch {
                print("  FAILED: \(error)")
            }
        }
    }

    static func cases() -> [(String, DBConnector, String)] {
        SecretStore.override("COAI_PROBE_PG", "probe")
        SecretStore.override("COAI_PROBE_MYSQL", "probe")
        return [
            ("PostgreSQL 16",
             DBConnector(alias: "pg", kind: .postgres,
                         target: "host=127.0.0.1 port=15432 user=postgres dbname=probe",
                         secretVariable: "COAI_PROBE_PG", readOnly: true),
             #"SELECT "ชื่อ", "คะแนน" FROM pg."ผู้ป่วย" ORDER BY id"#),
            ("MySQL 8",
             DBConnector(alias: "my", kind: .mysql,
                         target: "host=127.0.0.1 port=13306 user=root database=probe",
                         secretVariable: "COAI_PROBE_MYSQL", readOnly: true),
             "SELECT label, value FROM my.readings ORDER BY id"),
        ]
    }
}
