import Testing
import Foundation
@testable import AgentKit

@Suite("How a scope is written down")
struct ScopeCodingTests {
    @Test("a scope encodes as its storage key")
    func encodesAsString() throws {
        let data = try JSONEncoder().encode(Scope.project(ProjectID("diabetes")))
        #expect(String(decoding: data, as: UTF8.self) == "\"project\\/diabetes\"")
    }

    @Test("every case round-trips")
    func roundTrips() throws {
        for scope: Scope in [.central, .policy, .project(ProjectID("p1")), .board("run-1")] {
            let data = try JSONEncoder().encode(scope)
            #expect(try JSONDecoder().decode(Scope.self, from: data) == scope)
        }
    }

    @Test("a file written by an earlier build still decodes")
    func legacyShapeStillDecodes() throws {
        let legacy = #"{"project":{"_0":{"rawValue":"diabetes"}}}"#
        #expect(try JSONDecoder().decode(Scope.self, from: Data(legacy.utf8))
                == .project(ProjectID("diabetes")))
    }
}

/// Reproducing the crash that appeared when `Scope` grew a fourth case: the
/// encoder used by `ConnectorStore`, on a value shaped like a connector.
private struct ConnectorShape: Codable, Equatable {
    let id: String
    let alias: String
    let target: String
    let secretVariable: String?
    let scope: Scope
    let readOnly: Bool
}

@Suite("Encoding a value that carries a scope")
struct ScopeInsideAValueTests {
    @Test("pretty-printed and sorted, the way the connector list is written")
    func encodesInsideAStruct() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let value = ConnectorShape(id: "con_1", alias: "lab", target: "/tmp/lab.sqlite",
                                   secretVariable: nil,
                                   scope: .project(ProjectID("diabetes")), readOnly: true)
        let data = try encoder.encode([value])
        #expect(try JSONDecoder().decode([ConnectorShape].self, from: data) == [value])
    }
}
