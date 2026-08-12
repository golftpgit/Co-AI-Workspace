import Testing
import Foundation
import AgentKit
@testable import Persistence

// ─────────────────────────────────────────────────────────────
// The Analysis Plan against a real SurrealDB (ARCHITECTURE §12.4, P6.7).
//
// A pre-registration that only exists while the window is open registers
// nothing. What has to survive is not just the text but the *state*: which
// decisions were the agent's, which a person confirmed, and whether the whole
// thing was approved.
// ─────────────────────────────────────────────────────────────

private func settledPlan(title: String) -> AnalysisPlan {
    var plan = AnalysisPlan(title: title, scope: .project(ProjectID("diabetes")))
    plan.add(AnalysisDecision(question: "ประชากรที่ศึกษา",
                              value: "ผู้ป่วยเบาหวานชนิดที่ 2 อายุ 18 ปีขึ้นไป",
                              origin: .proposalStated))
    plan.add(AnalysisDecision(question: "วิธีทางสถิติ", value: "Welch t-test",
                              origin: .agentSuggested))
    return plan
}

@Suite("Analysis plan store", .serialized)
struct AnalysisPlanStoreTests {

    @Test("an approved plan comes back approved, with its origin tags intact",
          .timeLimit(.minutes(2)))
    func approvedPlanRoundTrips() async throws {
        guard let server = try await makeServer(port: 18_492) else { return }
        defer { Task { await server.shutdown() } }
        let store = AnalysisPlanStore(client: await server.client)

        var plan = settledPlan(title: "เมตฟอร์มินกับ HbA1c")
        plan.confirm(plan.agentSuggestions[0].id, value: "Mann–Whitney U")
        try plan.approve(by: "ผู้ใช้")
        try await store.save(plan)

        let loaded = try await store.load(scope: .project(ProjectID("diabetes")))
        let restored = try #require(loaded.first?.plan)
        #expect(restored.id == plan.id)
        #expect(restored.isApproved)
        #expect(restored.approvedBy == "ผู้ใช้")
        // The audit tag is the whole point of §12.4: what came from the
        // proposal, and what a person signed off, must still be distinguishable
        // a year later.
        #expect(restored.agentSuggestions.isEmpty)
        #expect(restored.decisions.map(\.origin) == [.proposalStated, .humanConfirmed])
        #expect(restored.decisions[1].value == "Mann–Whitney U")
    }

    @Test("an unapproved plan keeps its gaps and its unconfirmed suggestions",
          .timeLimit(.minutes(2)))
    func openPlanRoundTrips() async throws {
        guard let server = try await makeServer(port: 18_493) else { return }
        defer { Task { await server.shutdown() } }
        let store = AnalysisPlanStore(client: await server.client)

        var plan = settledPlan(title: "แผนที่ยังไม่จบ")
        plan.add(AnalysisGap(severity: .critical, subject: "ตัวแปร “creatinine”",
                             detail: "ไม่มีคอลัมน์นี้ในฐานข้อมูลที่ต่ออยู่"))
        try await store.save(plan)

        let restored = try #require(
            try await store.load(scope: .project(ProjectID("diabetes"))).first?.plan)
        #expect(!restored.isApproved)
        #expect(restored.blockingGaps.count == 1)
        #expect(restored.agentSuggestions.count == 1)
        // And it is still refused for the same reasons after a restart.
        var reopened = restored
        #expect(throws: PlanApprovalError.self) { try reopened.approve(by: "ผู้ใช้") }
    }

    /// The state that matters most: a plan that lost its approval because the
    /// method changed (§12.3's loop back) must not come back looking approved.
    @Test("a plan sent back for re-approval stays sent back", .timeLimit(.minutes(2)))
    func revisionSurvives() async throws {
        guard let server = try await makeServer(port: 18_494) else { return }
        defer { Task { await server.shutdown() } }
        let store = AnalysisPlanStore(client: await server.client)

        var plan = settledPlan(title: "แผนที่ถูกตีกลับ")
        plan.confirm(plan.agentSuggestions[0].id)
        try plan.approve(by: "ผู้ใช้")
        plan.methodologyChanged(
            reason: "t-test ไม่ผ่านการตรวจการแจกแจงปกติ",
            proposal: AnalysisDecision(question: "วิธีทางสถิติ (แก้ไข)",
                                       value: "Mann–Whitney U", origin: .agentSuggested))
        try await store.save(plan)

        let restored = try #require(
            try await store.load(scope: .project(ProjectID("diabetes"))).first?.plan)
        #expect(!restored.isApproved)
        #expect(restored.revisions == ["t-test ไม่ผ่านการตรวจการแจกแจงปกติ"])
        #expect(restored.agentSuggestions.count == 1)
    }

    @Test("saving twice updates the same plan", .timeLimit(.minutes(2)))
    func savingIsIdempotent() async throws {
        guard let server = try await makeServer(port: 18_495) else { return }
        defer { Task { await server.shutdown() } }
        let store = AnalysisPlanStore(client: await server.client)

        var plan = settledPlan(title: "ชื่อแรก")
        try await store.save(plan)
        plan.title = "ชื่อที่แก้แล้ว"
        try await store.save(plan)

        let loaded = try await store.load(scope: .project(ProjectID("diabetes")))
        #expect(loaded.count == 1)
        #expect(loaded[0].plan.title == "ชื่อที่แก้แล้ว")

        try await store.delete(plan.id)
        #expect(try await store.load(scope: .project(ProjectID("diabetes"))).isEmpty)
    }

    @Test("plans do not leak across scopes", .timeLimit(.minutes(2)))
    func scopeIsRespected() async throws {
        guard let server = try await makeServer(port: 18_496) else { return }
        defer { Task { await server.shutdown() } }
        let store = AnalysisPlanStore(client: await server.client)

        try await store.save(settledPlan(title: "ของโปรเจกต์"))
        var central = settledPlan(title: "ของส่วนกลาง")
        central.scope = .central
        try await store.save(central)

        #expect(try await store.load(scope: .central).map(\.plan.title) == ["ของส่วนกลาง"])
        #expect(try await store.load(scope: .project(ProjectID("diabetes")))
            .map(\.plan.title) == ["ของโปรเจกต์"])
    }
}
