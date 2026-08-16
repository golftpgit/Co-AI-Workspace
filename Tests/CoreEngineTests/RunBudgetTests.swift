import Testing
import Foundation
import AgentKit
import LLMProviders
@testable import CoreEngine

// ─────────────────────────────────────────────────────────────
// P4.8's remaining half — a ceiling on what one run may spend.
//
// `continuationCap` bounds how many times run-until-done picks the ledger back
// up, and `BudgetGovernor` bounds money per endpoint. Neither answers the
// question a person asks when they turn run-until-done on and leave: how much
// has this run used? Three assignments with three retries each is nine
// conversations, and nothing counted them.
// ─────────────────────────────────────────────────────────────

/// A specialist that burns a fixed number of tokens per attempt and then fails
/// its review, so a run keeps going until something stops it.
private actor Burner: Specialist {
    nonisolated let role: Role
    nonisolated let definitionOfDone = [Criterion(text: "เทสผ่าน", evidenceRequired: "exit code 0")]
    private let budget: RunBudget
    private let perAttempt: Int
    private(set) var attempts = 0

    init(role: Role, budget: RunBudget, perAttempt: Int) {
        self.role = role
        self.budget = budget
        self.perAttempt = perAttempt
    }

    func execute(_ assignment: Assignment) async throws -> Deliverable {
        attempts += 1
        await budget.record(LLMUsage(promptTokens: perAttempt, completionTokens: 0))
        // No evidence, so the reviewer sends it back — which is what makes this
        // a run that would otherwise spend its full retry budget.
        return Deliverable(assignmentID: assignment.id, summary: "ลองแล้ว")
    }

    func attemptCount() -> Int { attempts }
}

private actor EventLog {
    private(set) var events: [TeamEvent] = []
    func record(_ event: TeamEvent) { events.append(event) }
    var exhaustion: (summary: String, remaining: Int)? {
        events.compactMap {
            if case .budgetExhausted(let summary, let remaining) = $0 {
                return (summary: summary, remaining: remaining)
            }
            return nil
        }.first
    }
}

/// One assignment per role: §2.4 refuses a plan that splits the Engineer, so
/// a three-assignment plan has to be three different people.
private let roles: [Role] = [.researcher, .analyst, .writer]

private func plan(_ count: Int) -> TeamPlan {
    TeamPlan(goal: "งานหลายชิ้น", assignments: (0..<count).map { index in
        Assignment(id: "a\(index + 1)", role: roles[index], goal: "ทำงานที่ \(index + 1)",
                   acceptanceCriteria: [Criterion(text: "เทสผ่าน", evidenceRequired: "exit code 0")],
                   deliverableType: "เอกสาร")
    })
}

/// The same burner for every role, so the run keeps spending until something
/// stops it.
private func burners(_ budget: RunBudget, perAttempt: Int) -> [Role: any Specialist] {
    Dictionary(uniqueKeysWithValues: roles.map {
        ($0, Burner(role: $0, budget: budget, perAttempt: perAttempt) as any Specialist)
    })
}

@Suite("A run has a ceiling on what it may spend (P4.8)")
struct RunBudgetTests {

    @Test("tokens spent on attempts that failed still count")
    func failedAttemptsCount() async {
        // The loosest possible ceiling is one that only counts work that went
        // well — a run going badly is a run spending the most.
        let budget = RunBudget(ceiling: 100)
        await budget.record(LLMUsage(promptTokens: 40, completionTokens: 20))
        await budget.record(LLMUsage(promptTokens: 30, completionTokens: 20))
        #expect(await budget.isExhausted)
        #expect(await budget.used.total == 110)
        #expect(await budget.remaining == 0)
    }

    @Test("no ceiling is the default, and it does not stop anything")
    func noCeilingMeansNoStopping() async {
        let budget = RunBudget()
        await budget.record(LLMUsage(promptTokens: 1_000_000, completionTokens: 1_000_000))
        #expect(await budget.isExhausted == false)
        #expect(await budget.remaining == nil)
        #expect(await budget.summary.contains("ไม่ได้ตั้งเพดาน"))
    }

    @Test("a new run starts from zero")
    func ceilingIsPerRun() async {
        let budget = RunBudget(ceiling: 50)
        await budget.record(LLMUsage(promptTokens: 60, completionTokens: 0))
        #expect(await budget.isExhausted)
        // Carrying yesterday's tokens into today would stop the next run before
        // it asked anything.
        await budget.begin(ceiling: 50)
        #expect(await budget.isExhausted == false)
        #expect(await budget.used.total == 0)
    }

    /// The Done-when for this half: the run stops, and it stops *between*
    /// assignments rather than by abandoning one halfway.
    @Test("a run that hits the ceiling stops and leaves the rest for a person")
    func exhaustedRunStopsAndSaysSo() async {
        let budget = RunBudget()
        let specialists = burners(budget, perAttempt: 400)
        let first = specialists[.researcher] as! Burner
        let team = TeamOrchestrator(router: ModelRouter(executors: []),
                                    specialists: specialists,
                                    retryCap: 3, budget: budget)
        let log = EventLog()

        let delivered = await team.run(goal: "งานหลายชิ้น", plan: plan(3),
                                       tokenCeiling: 500) { event in
            Task { await log.record(event) }
        }
        // Let the emitted events land — the callback hops to the log's actor.
        try? await Task.sleep(for: .milliseconds(50))

        #expect(delivered.isEmpty)
        // The first assignment used its retries; the ceiling stopped the run
        // before the second one started, rather than mid-conversation.
        #expect(await first.attemptCount() == 3)

        let entries = await team.entries
        #expect(entries.count == 3, "assignments that never started vanished from the ledger")
        #expect(entries.filter(\.needsHuman).count == 3)
        #expect(entries.contains { $0.findings.contains { $0.contains("เพดานโทเคน") } })

        let exhaustion = await log.exhaustion
        #expect(exhaustion != nil, "the run stopped on budget and never said so")
        // The number the person set is in the sentence: "over budget" without
        // it is a mystery to anybody who did not set it.
        #expect(exhaustion?.summary.contains("500") == true)
        #expect(exhaustion?.remaining == 3)
    }

    @Test("a run under the ceiling is not interrupted")
    func generousCeilingChangesNothing() async {
        let budget = RunBudget()
        let specialists = burners(budget, perAttempt: 10)
        let team = TeamOrchestrator(router: ModelRouter(executors: []),
                                    specialists: specialists,
                                    retryCap: 2, budget: budget)
        let log = EventLog()

        _ = await team.run(goal: "งานหลายชิ้น", plan: plan(2),
                           tokenCeiling: 100_000) { event in
            Task { await log.record(event) }
        }
        try? await Task.sleep(for: .milliseconds(50))

        // Both assignments were attempted to their retry cap; nothing was cut.
        let attempts = await (specialists[.researcher] as! Burner).attemptCount()
            + (specialists[.analyst] as! Burner).attemptCount()
        #expect(attempts == 4)
        #expect(await log.exhaustion == nil)
    }
}
