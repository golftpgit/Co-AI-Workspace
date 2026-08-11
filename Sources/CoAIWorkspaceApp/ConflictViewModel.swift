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
        var ledger = ConflictLedger()
        // Rebuilt from what was stored rather than recomputed: the weights on
        // this card are the ones the user is looking at.
        let restored = ledger.record(question: conflict.question,
                                     a: conflict.a, b: conflict.b, scope: decisionScope)
        _ = ledger.decide(restored.id, resolution, scope: decisionScope)
        guard let decided = ledger.all.first(where: { $0.id == restored.id }) else { return }

        do {
            try await store.save(decided, scope: decisionScope)
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
}
