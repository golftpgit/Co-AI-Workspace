import Foundation
import Observation
import AgentKit
import Knowledge
import Persistence
import Observability

// ─────────────────────────────────────────────────────────────
// The Conflict Card's state (ARCHITECTURE §11.6, P3.7).
//
// The screen exists so a disagreement is decided by a person with the evidence
// in front of them. Everything it needs is already stored — both passages
// verbatim, both sources, the weights as they were written — so this holds no
// judgement of its own; it presents and records.
// ─────────────────────────────────────────────────────────────

@MainActor
@Observable
public final class ConflictViewModel {
    public struct Status: Equatable {
        public var message: String
        public var isError: Bool
    }

    public private(set) var conflicts: [StoredConflict] = []
    public private(set) var status: Status?
    public private(set) var isWorking = false
    public var scope: Scope = .central
    /// Shown separately from the open ones: a settled question is the record
    /// of a decision, not a task.
    public var showsDecided = false

    /// The history of whichever card is expanded (§11.6, P3.7). Loaded on
    /// demand rather than with the list: most cards are never reopened, and a
    /// query per card on every reload would be paid by everybody for the
    /// benefit of nobody.
    public private(set) var history: [ConflictDecisionRecord] = []
    public private(set) var historyFor: String?

    private var store: ConflictStore?
    private let log = AppLog.logger("conflict-ui")

    public init() {}

    public var visible: [StoredConflict] {
        showsDecided ? conflicts : conflicts.filter(\.isOpen)
    }

    public var openCount: Int { conflicts.count(where: \.isOpen) }

    public func attach(store: ConflictStore) async {
        self.store = store
        await reload()
    }

    public func reload() async {
        guard let store else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            conflicts = try await store.load(scope: scope)
        } catch {
            log.error("loading conflicts: \(error)")
            status = Status(message: "โหลดรายการข้อขัดแย้งไม่สำเร็จ: \(error)", isError: true)
        }
    }

    public func changeScope(to scope: Scope) async {
        self.scope = scope
        await reload()
    }

    /// Records what the human decided. `asPrecedent` is §11.6's last row: a
    /// decision can apply to this project only, or stand everywhere.
    public func decide(_ conflict: StoredConflict,
                       _ resolution: ConflictResolution,
                       asPrecedent: Bool) async {
        guard let store else {
            status = Status(message: "ยังต่อฐานข้อมูลไม่ได้ — คำตัดสินจะไม่ถูกบันทึก",
                            isError: true)
            return
        }
        isWorking = true
        defer { isWorking = false }

        let decisionScope: Scope = asPrecedent ? .central : scope
        // Written straight against the stored row. Going back through
        // `ConflictLedger.record` would re-weigh both sides and save the new
        // numbers over the ones on the card the user just read.
        let decision = ConflictDecision(resolution: resolution, scope: decisionScope,
                                        decidedByHuman: true)

        do {
            try await store.recordDecision(decision, for: conflict.id)
            await reload()
            status = Status(message: asPrecedent
                            ? "บันทึกเป็นคำตัดสินกลาง — ใช้กับทุกโปรเจกต์"
                            : "บันทึกคำตัดสินสำหรับขอบเขตนี้แล้ว",
                            isError: false)
        } catch {
            log.error("saving decision: \(error)")
            status = Status(message: "บันทึกคำตัดสินไม่สำเร็จ: \(error)", isError: true)
        }
    }

    /// Everything ever decided about this card, oldest first.
    public func loadHistory(of conflict: StoredConflict) async {
        guard let store else { return }
        historyFor = conflict.id
        do {
            history = try await store.history(of: conflict.id)
        } catch {
            log.error("loading conflict history: \(error)")
            history = []
        }
    }

    public func closeHistory() {
        historyFor = nil
        history = []
    }

    /// Takes a decision back (P3.7). The old decision stays in the history —
    /// this adds an entry saying the card was reopened and why, which is what
    /// somebody meeting it in six months needs in order to tell a change of
    /// mind from a mis-click.
    public func reopen(_ conflict: StoredConflict, reason: String) async {
        guard let store else {
            status = Status(message: "ยังต่อฐานข้อมูลไม่ได้ — การกลับคำตัดสินจะไม่ถูกบันทึก",
                            isError: true)
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try await store.reopen(conflict.id, reason: reason)
            await reload()
            if historyFor == conflict.id { await loadHistory(of: conflict) }
            status = Status(message: "กลับมาเป็นคำถามที่ยังไม่ตัดสิน — คำตัดสินเดิมยังอยู่ในประวัติ",
                            isError: false)
        } catch let error as ConflictHistoryError {
            status = Status(message: error.description, isError: true)
        } catch {
            log.error("reopening conflict: \(error)")
            status = Status(message: "กลับคำตัดสินไม่สำเร็จ: \(error)", isError: true)
        }
    }
}
