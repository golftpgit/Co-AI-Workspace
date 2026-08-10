import Testing
import Foundation
@testable import AgentKit

@Suite("Scope round-trips through storage")
struct ScopeTests {
    @Test("storageKey round-trip for every case shape")
    func roundTrip() throws {
        let cases: [Scope] = [.central, .policy, .project(ProjectID("abc-123"))]
        for scope in cases {
            let restored = Scope(storageKey: scope.storageKey)
            #expect(restored == scope)
        }
    }

    @Test("malformed storage keys are rejected, not silently coerced")
    func rejectsMalformed() {
        #expect(Scope(storageKey: "") == nil)
        #expect(Scope(storageKey: "project:") == nil)
        #expect(Scope(storageKey: "nonsense") == nil)
    }

    @Test("Codable round-trip keeps the associated value")
    func codable() throws {
        let scope = Scope.project(ProjectID("p1"))
        let data = try JSONEncoder().encode(scope)
        #expect(try JSONDecoder().decode(Scope.self, from: data) == scope)
    }
}

@Suite("Risk and credibility ordering")
struct OrderingTests {
    @Test("risk orders low < medium < high")
    func riskOrdering() {
        #expect(RiskLevel.low < RiskLevel.medium)
        #expect(RiskLevel.medium < RiskLevel.high)
        #expect(RiskLevel.allCases.max() == .high)
    }

    /// T1 is the most credible, so it must sort as the *greatest* value —
    /// this is the comparison the Conflict Ledger relies on (§11.6).
    @Test("credibility: T1 outranks T5 despite the smaller raw value")
    func credibilityOrdering() {
        #expect(CredibilityTier.t5 < CredibilityTier.t1)
        #expect(CredibilityTier.allCases.max() == .t1)
        #expect(CredibilityTier.t2.label == "T2")
    }
}
