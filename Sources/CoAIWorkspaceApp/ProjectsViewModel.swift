import Foundation
import Observation
import AgentKit
import ProjectKit
import CoreEngine
import Persistence
import Observability

// ─────────────────────────────────────────────────────────────
// The workspace switch and the project screen (ARCHITECTURE §19.1, §19.4).
//
// This is also where the app answers "which scope am I in": every screen reads
// `selection` rather than deciding for itself, which is what replaced the
// literal `ProjectID("default")` that used to stand in for a project the system
// did not actually have.
// ─────────────────────────────────────────────────────────────

@MainActor
@Observable
public final class ProjectsViewModel {
    /// General or one project. There is no third state on purpose: `policy`
    /// scope is a knowledge partition, not a place to work (§11.2).
    public enum Selection: Equatable {
        case general
        case project(ProjectID)
    }

    public struct Status: Equatable {
        public var message: String
        public var isError: Bool
    }

    public private(set) var projects: [Project] = []
    public private(set) var status: Status?
    public private(set) var isWorking = false
    public private(set) var selection: Selection = .general
    /// The gate for whatever is selected, recomputed after every change, so the
    /// screen never shows a stale "ready to advance".
    public private(set) var gate: GateEvaluation?
    /// The selected project's plan (§19.6). Read after every change rather
    /// than mutated in place: the gate reads the same value the screen draws,
    /// and two copies of a plan is how a gate starts disagreeing with the
    /// thing it is gating.
    public private(set) var wbs = WorkBreakdown()
    public private(set) var problems: [WBSProblem] = []

    private var service: ProjectService?
    private let log = AppLog.logger("projects-ui")

    public init() {}

    /// What every other screen asks for. General is `central`: shared
    /// knowledge, no ledger, no lifecycle.
    public var scope: Scope {
        switch selection {
        case .general: .central
        case .project(let id): .project(id)
        }
    }

    public var selected: Project? {
        guard case .project(let id) = selection else { return nil }
        return projects.first { $0.id == id }
    }

    public var openProjects: [Project] { projects.filter(\.isOpen) }

    public func attach(service: ProjectService) async {
        self.service = service
        await reload()
    }

    public func reload() async {
        guard let service else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            projects = try await service.projects()
            // A project deleted or closed elsewhere must not leave the app
            // pointed at it; falling back to General is always safe.
            if case .project(let id) = selection, !projects.contains(where: { $0.id == id }) {
                selection = .general
            }
            await refreshGate()
        } catch {
            log.error("loading projects: \(error)")
            status = Status(message: "โหลดรายการโปรเจกต์ไม่สำเร็จ: \(error)", isError: true)
        }
    }

    public func select(_ selection: Selection) async {
        self.selection = selection
        status = nil
        await refreshGate()
    }

    public func create(name: String, kind: ProjectKind) async {
        guard let service else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            status = Status(message: "ตั้งชื่อโปรเจกต์ก่อน", isError: true)
            return
        }
        do {
            let project = try await service.create(name: trimmed, kind: kind)
            await reload()
            await select(.project(project.id))
            status = Status(message: "สร้าง '\(trimmed)' แล้ว — อยู่ขั้นเริ่มต้น", isError: false)
        } catch {
            status = Status(message: "สร้างโปรเจกต์ไม่สำเร็จ: \(error)", isError: true)
        }
    }

    /// Edits land immediately. The brief and the scope statement are what G1
    /// reads, so making them a modal with a Save button would put a gate
    /// condition behind a second decision.
    public func update(_ project: Project) async {
        guard let service else { return }
        do {
            try await service.update(project)
            await reload()
        } catch {
            status = Status(message: "บันทึกไม่สำเร็จ: \(error)", isError: true)
        }
    }

    public func advance() async {
        guard let service, let project = selected else { return }
        do {
            let moved = try await service.advance(project.id)
            await reload()
            status = Status(message: "ผ่าน \(project.stage.exitGate ?? "") แล้ว — ตอนนี้อยู่ขั้น\(moved.stage.label)",
                            isError: false)
        } catch {
            // The refusal names what is missing. A gate that says only "no" is
            // a gate people route around.
            status = Status(message: "\(error)", isError: true)
        }
    }

    public func terminate(reason: String) async {
        guard let service, let project = selected else { return }
        do {
            _ = try await service.terminate(project.id, reason: reason)
            await reload()
            status = Status(message: "ยุติโครงการแล้ว — บันทึกไว้ว่า 'ยุติก่อนกำหนด' ไม่ใช่ 'สำเร็จ'",
                            isError: false)
        } catch {
            status = Status(message: "ปิดโครงการไม่สำเร็จ: \(error)", isError: true)
        }
    }

    /// General → Project (§19.1, P10.3).
    ///
    /// Creates the project from the drafted brief and moves the conversation
    /// that produced it. Order matters: the project has to exist before the
    /// conversation can point at it, and a failed move must not leave a
    /// project with no history behind it — so the failure is reported with the
    /// project already made, and the conversation stays where it is.
    public func promote(_ draft: DraftedBrief,
                        conversationID: String?,
                        conversations: ConversationStore) async {
        guard let service else { return }
        do {
            let project = try await service.create(name: draft.name,
                                                   kind: .blank,
                                                   brief: draft.brief,
                                                   statement: draft.statement)
            if let conversationID {
                try await conversations.reassign(conversationID, to: project.scope)
            }
            await reload()
            await select(.project(project.id))
            status = Status(
                message: draft.isReadyForG1
                    ? "ยกระดับเป็นโปรเจกต์แล้ว — ตรวจขอบเขตอีกครั้งแล้วกดผ่าน G1 ได้เลย"
                    : "ยกระดับเป็นโปรเจกต์แล้ว — ยังผ่าน G1 ไม่ได้จนกว่าจะเติมช่องที่ค้าง",
                isError: false)
        } catch {
            status = Status(message: "ยกระดับเป็นโปรเจกต์ไม่สำเร็จ: \(error)", isError: true)
        }
    }

    // MARK: - the plan

    public func addPackage(title: String, parent: String?) async {
        guard let service, let project = selected else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let siblings = wbs.children(of: parent)
        do {
            try await service.save(WorkPackage(
                projectID: project.id,
                parent: parent,
                title: trimmed,
                // Pre-filled when the project has exactly one thing in scope,
                // because that is the common case and an empty required field
                // teaches people to ignore required fields.
                scopeRef: project.statement.inScope.count == 1
                    ? project.statement.inScope.first : nil,
                acceptanceCriteria: [],
                order: (siblings.map(\.order).max() ?? -1) + 1))
            await refreshGate()
        } catch {
            status = Status(message: "เพิ่มใบงานไม่สำเร็จ: \(error)", isError: true)
        }
    }

    public func update(_ package: WorkPackage) async {
        guard let service else { return }
        do {
            try await service.save(package)
            await refreshGate()
        } catch {
            status = Status(message: "บันทึกใบงานไม่สำเร็จ: \(error)", isError: true)
        }
    }

    public func removePackage(_ packageID: String) async {
        guard let service, let project = selected else { return }
        do {
            try await service.removePackage(packageID, from: project.id)
            await refreshGate()
        } catch {
            status = Status(message: "ลบใบงานไม่สำเร็จ: \(error)", isError: true)
        }
    }

    /// Closing a leaf by hand. The evidence rule lives in `WorkBreakdown`, so
    /// the refusal here is the same refusal an agent gets.
    public func complete(_ packageID: String, evidence: [Evidence]) async {
        guard let service, let project = selected else { return }
        do {
            try await service.complete(packageID, in: project.id, with: evidence)
            await refreshGate()
        } catch {
            status = Status(message: "\(error)", isError: true)
        }
    }

    private func refreshGate() async {
        guard let service, case .project(let id) = selection else {
            gate = nil
            wbs = WorkBreakdown()
            problems = []
            return
        }
        wbs = await service.breakdown(of: id)
        problems = wbs.problems(inScope: selected?.statement.inScope ?? [])
        gate = await service.gate(for: id)
    }
}
