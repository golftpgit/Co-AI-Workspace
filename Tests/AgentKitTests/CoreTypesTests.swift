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

// ─────────────────────────────────────────────────────────────
// §14.1's corroboration rule, and the two tier enums (P13.2).
// ─────────────────────────────────────────────────────────────

@Suite("Corroboration")
struct CorroborationTests {

    @Test("ten weak sources are not two strong ones")
    func weakSourcesDoNotAddUp() {
        // The rule the whole thing exists for: opening T5 must not make the
        // standard easier to meet.
        let manyWeak = Array(repeating: CredibilityTier?.some(.t5), count: 10)
        guard case .weak(let reason) = Corroboration.assess(tiers: manyWeak) else {
            Issue.record("T5 สิบแหล่งไม่ควรผ่าน")
            return
        }
        #expect(reason.contains("ต้องมีแหล่ง T1–T3"))
        #expect(!Corroboration.assess(tiers: manyWeak).isEnoughForQA)
    }

    @Test("two peer-reviewed sources may be stated plainly; one may not")
    func strongNeedsTwo() {
        #expect(Corroboration.assess(tiers: [.t1, .t2]) == .strong)
        #expect(Corroboration.assess(tiers: [.t1, .t2]).mayStatePlainly)
        // One source is never cross-checked, however good it is.
        guard case .weak = Corroboration.assess(tiers: [.t1]) else {
            Issue.record("แหล่งเดียวไม่ควรนับว่ายืนยันข้ามแหล่งแล้ว")
            return
        }
    }

    @Test("one T1–T3 behind weak sources is adequate, and enough for QA")
    func oneStrongIsEnoughToState() {
        let verdict = Corroboration.assess(tiers: [.t3, .t5, .t5])
        #expect(verdict == .adequate)
        // Adequate passes the gate but still carries its qualification into the
        // document's Limitations section.
        #expect(verdict.isEnoughForQA)
        #expect(verdict.note != nil)
    }

    @Test("no sources at all is refused before anything else")
    func nothingIsWeakest() {
        guard case .weak(let reason) = Corroboration.assess(tiers: []) else {
            Issue.record("ไม่มีแหล่งเลยต้องไม่ผ่าน")
            return
        }
        #expect(reason.contains("ไม่มีแหล่งอ้างอิงเลย"))
    }

    @Test("an untiered source counts as a source and never as a strong one")
    func nilTierIsNotStrong() {
        #expect(!Corroboration.assess(tiers: [nil, nil]).isEnoughForQA)
        // But it is still *a* source: two of them are not "no sources".
        guard case .weak(let reason) = Corroboration.assess(tiers: [nil, nil]) else {
            Issue.record("ควรไม่ผ่าน")
            return
        }
        #expect(!reason.contains("ไม่มีแหล่งอ้างอิงเลย"))
    }

    @Test("the tier marker round-trips through tool output")
    func markerRoundTrips() {
        for tier in CredibilityTier.allCases {
            let output = CitationTier.marker(tier) + "\nชื่อหน้า\nhttps://example.org/x\n\nเนื้อหา"
            #expect(CitationTier.tier(in: output) == tier)
        }
        // A tool that says nothing leaves `nil` rather than a default, which is
        // what makes "untiered cannot carry a claim" meaningful.
        #expect(CitationTier.tier(in: "ชื่อหน้า\nhttps://example.org/x") == nil)
        #expect(CitationTier.tier(in: CitationTier.marker(nil)) == nil)
        // Truncating the text to an evidence summary must not lose it — which is
        // why the marker is the first line.
        let long = CitationTier.marker(.t2) + "\n" + String(repeating: "ก", count: 5_000)
        #expect(CitationTier.tier(in: String(long.prefix(200))) == .t2)
    }
}
