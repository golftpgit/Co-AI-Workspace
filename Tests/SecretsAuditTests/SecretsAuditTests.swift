import Testing
import Foundation
import AgentKit
import Config
import Channels
import Analysis
import MCPBridge

// ─────────────────────────────────────────────────────────────
// P9.3's Done-when, run as a test: **grep and find no token in any file.**
//
// The claim is a property of the whole app rather than of any one module —
// "nothing anywhere writes a secret to disk" — which is why it could not be
// checked from inside any existing test target, and why it had never been
// checked at all. This target exists to reach all four stores that hold a
// secret's *name*: endpoints, chat bots, database connectors, MCP servers.
//
// The method is the one the plan asked for and not a proxy for it. A canary
// value goes into the vault, every store is driven through a normal save, and
// then **every byte under the directory is searched for the canary**. Not the
// fields we remembered to check — the bytes. A test that asserted
// `connector.secretVariable == "PGPASSWORD"` would pass just as happily on the
// day somebody adds a `cachedPassword` field beside it.
//
// The searcher itself is checked against a file that really does contain the
// secret (`theSearchItselfWorks`), because an audit that cannot fail is an
// audit that proves nothing — the same reason `check.sh`'s rules are each
// proven to fail before they are trusted.
// ─────────────────────────────────────────────────────────────

/// The value nothing may write down. Distinctive enough that a hit is a hit.
private let canary = "CANARY-a7f3e1-do-not-write-me-down"
private let canaryName = "COAI_AUDIT_CANARY"

private func temporaryDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "secrets-audit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // Resolved, because `/var` is a symlink to `/private/var` on macOS and the
    // enumerator hands back the resolved side. Trimming an unresolved prefix
    // leaves "/private/…" glued to every path in the report.
    return directory.resolvingSymlinksInPath()
}

/// Every file under `directory` that contains `needle`, searched as bytes so
/// that plists, JSON, SQLite pages and log files are all treated the same.
private func filesContaining(_ needle: String, under directory: URL) -> [String] {
    let bytes = Array(needle.utf8)
    // `/var` is a symlink to `/private/var`, and the enumerator hands back the
    // resolved side — so the prefix being trimmed has to be the resolved one
    // too, or every reported path keeps a "/private" stuck to the front.
    let root = directory.resolvingSymlinksInPath().path
    guard let walker = FileManager.default.enumerator(at: directory,
                                                      includingPropertiesForKeys: [.isRegularFileKey])
    else { return [] }
    var hits: [String] = []
    for case let url as URL in walker {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              let data = try? Data(contentsOf: url) else { continue }
        if data.range(of: Data(bytes)) != nil {
            hits.append(url.resolvingSymlinksInPath().path
                .replacingOccurrences(of: root, with: ""))
        }
    }
    return hits
}

@Suite("Secrets audit — nothing writes a secret to disk", .serialized)
struct SecretsOnDiskAuditTests {

    // The audit's own smoke test. If this ever passes with an empty result,
    // every other test in this file is decoration.
    @Test("the search itself works — a file that does contain the secret is found")
    func theSearchItselfWorks() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try "password=\(canary)".write(to: directory.appending(path: "leaky.conf"),
                                       atomically: true, encoding: .utf8)
        #expect(filesContaining(canary, under: directory) == ["/leaky.conf"])
    }

    @Test("a paid endpoint saved to bootstrap.plist carries the name, never the key")
    func endpointConfig() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        SecretStore.override(canaryName, canary)
        defer { SecretStore.override(canaryName, nil) }

        let endpoint = InferenceEndpoint(name: "ผู้ให้บริการที่คิดเงิน",
                                         baseURL: "https://api.example.com/v1",
                                         model: "big-model", kind: .paid,
                                         apiKeyEnvironmentVariable: canaryName,
                                         inputPricePerMillion: 3, outputPricePerMillion: 15)
        // The key really is reachable at this point — otherwise this test would
        // be proving that nothing leaks because nothing works.
        #expect(endpoint.apiKey == canary)

        let paths = AppPaths(root: directory)
        try BootstrapStore(paths: paths).save(
            BootstrapConfig(surrealPort: 8000, searxngPort: 8888, logLevel: .info,
                            endpointRegistry: EndpointRegistry(endpoints: [endpoint],
                                                               defaultEndpointID: endpoint.id)))

        #expect(filesContaining(canary, under: directory) == [])
        // And the name is there, so the endpoint can still find its key again.
        #expect(filesContaining(canaryName, under: directory).isEmpty == false)
    }

    @Test("a bot account file holds the name of the token, never the token")
    func channelAccounts() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        SecretStore.override(canaryName, canary)
        SecretStore.override("\(canaryName)_SIGNING", canary)
        defer {
            SecretStore.override(canaryName, nil)
            SecretStore.override("\(canaryName)_SIGNING", nil)
        }

        let account = ChannelAccount(platform: .line, name: "บอทกลุ่มวิจัย",
                                     tokenVariable: canaryName,
                                     allowedChats: ["U123"],
                                     signingSecretVariable: "\(canaryName)_SIGNING")
        #expect(account.token == canary)
        #expect(account.isReady)

        try ChannelAccountStore(file: directory.appending(path: "channels.json")).add(account)
        #expect(filesContaining(canary, under: directory) == [])
    }

    @Test("a database connector file holds no password")
    func connectors() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        SecretStore.override(canaryName, canary)
        defer { SecretStore.override(canaryName, nil) }

        let connector = DBConnector(alias: "lab", kind: .postgres,
                                    target: "host=db.example.org dbname=lab user=reader",
                                    secretVariable: canaryName)
        #expect(connector.secretIsAvailable)

        try ConnectorStore(file: directory.appending(path: "connectors.json")).add(connector)
        #expect(filesContaining(canary, under: directory) == [])
    }

    @Test("an MCP server entry holds no token")
    func mcpServers() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        SecretStore.override(canaryName, canary)
        defer { SecretStore.override(canaryName, nil) }

        let server = MCPServerConfig(name: "weather", command: "npx",
                                     arguments: ["-y", "weather-mcp"],
                                     environmentVariables: ["WEATHER_API_KEY": canaryName])
        #expect(server.isReady)
        // The value does reach the launched process — that is the point of it.
        #expect(server.resolvedEnvironment()["WEATHER_API_KEY"] == canary)

        try MCPServerStore(file: directory.appending(path: "mcp.json")).save([server])
        #expect(filesContaining(canary, under: directory) == [])
    }
}

@Suite("Secrets audit — nothing shows a secret either")
struct SecretsInMessagesAuditTests {

    // `AnalysisError.queryFailed` carries its SQL by design, and for
    // `ATTACH '…password=…'` that SQL *is* the credential. This is the one
    // place in the app that interpolates a secret into a string at all.
    @Test("a failed connection reports the failure without the password in it")
    func connectFailureIsRedacted() async throws {
        SecretStore.override(canaryName, canary)
        defer { SecretStore.override(canaryName, nil) }

        let store = try AnalysisStore()
        let connector = DBConnector(alias: "lab", kind: .postgres,
                                    target: "host=127.0.0.1 port=1 dbname=nothing user=nobody",
                                    secretVariable: canaryName)
        do {
            try await store.attach(connector)
            Issue.record("the attach unexpectedly succeeded, so nothing was proven")
        } catch {
            #expect("\(error)".contains(canary) == false,
                    "the password reached an error message, and from there a log and a span")
        }
    }

    // Every sentence the UI can draw about a secret, checked for the value.
    @Test("no status sentence about a secret contains the secret")
    func presentationNeverShowsTheValue() {
        let sentences = [
            SecretPresentation.display(name: canaryName, status: .present(source: .keychain)),
            SecretPresentation.display(name: canaryName, status: .present(source: .environment)),
            SecretPresentation.display(name: canaryName, status: .present(source: .override)),
            SecretPresentation.display(name: canaryName, status: .absent),
            SecretPresentation.display(name: canaryName, status: .unreadable("OSStatus -25308")),
            SecretPresentation.display(name: nil, status: .absent),
        ]
        for sentence in sentences {
            #expect(sentence.text.contains(canary) == false)
        }
    }

    // The distinction the rest of P9.3 rests on, at the layer a person reads.
    @Test("'could not read' and 'not set' are not the same sentence or the same colour")
    func unreadableLooksDifferentFromAbsent() {
        let absent = SecretPresentation.display(name: canaryName, status: .absent)
        let unreadable = SecretPresentation.display(name: canaryName,
                                                    status: .unreadable("OSStatus -25308"))
        #expect(absent.tone == .missing)
        #expect(unreadable.tone == .problem)
        #expect(absent.text != unreadable.text)
        // And it tells the person not to do the thing that loses the key.
        #expect(unreadable.text.contains("which does not mean it was never set"))
    }

    // Honest about the weaker of the two sources rather than showing one tick
    // for both: a `launchctl setenv` value is readable by every process this
    // user runs.
    @Test("a secret coming from the environment is not shown as if it were in the Keychain")
    func environmentIsFlagged() {
        let keychain = SecretPresentation.display(name: canaryName,
                                                  status: .present(source: .keychain))
        let environment = SecretPresentation.display(name: canaryName,
                                                     status: .present(source: .environment))
        #expect(keychain.tone == .ok)
        #expect(environment.tone == .caution)
    }
}
