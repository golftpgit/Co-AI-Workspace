import Foundation
import AgentKit
import Observability

// ─────────────────────────────────────────────────────────────
// Workflow Builder (ARCHITECTURE §14.2, P8.6) — a procedure worth keeping.
//
// **What v1 had, and what was wrong with it.** v1 shipped an n8n-style node
// canvas with a tool palette, and Phase F then discovered that its execution
// path *did not run through the gate at all* — the same class of hole as bug
// B2, on the surface people used to automate the riskiest work. It also had
// B3: node ids were counters, so two workflows loaded together collided.
//
// So the thing being rebuilt here is the half that was valuable — **a saved,
// re-runnable sequence** — on top of the machinery v2 already has, rather than
// the half that was dangerous. A workflow here is a list of steps, and the only
// way a step touches a tool is `ToolGateway`, which means Critic → StageGate →
// Risk → Policy → HITL apply to every one of them without this file knowing
// those exist.
//
// **What is deliberately not here: the drag-and-drop node graph.** v2 already
// has three shapes that are "an ordered thing you edit and approve" — the team
// plan (§2.6), the notebook (§12.5), and the WBS (§19.6). A fourth, with edges
// and a canvas, would be a fourth place to look for "what is this system going
// to do", which §0.2's consolidation rule and R10 both argue against. Steps run
// in order; branching is the orchestrator's decision (§2.2), not a line someone
// draws. The list is the graph, and it is the graph v2's own execution model
// can actually honour.
//
// Three rules, each one a thing v1 got wrong:
//
// 1. **A step naming a tool that does not exist is refused when it is saved,**
//    not when it runs — the P8.1/P8.5 rule. A workflow that fails halfway
//    through on a typo has already done the first half.
// 2. **Ids are opaque and generated, never positional.** B3 was ids that
//    collided after a load, and the fix is that nothing derives an id from
//    where a step sits.
// 3. **A run stops at the first step that fails and records which one.** "The
//    workflow failed" is the message that made v1's runs unreadable.
// ─────────────────────────────────────────────────────────────

public struct WorkflowStep: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    /// The tool to call, by the name the model would use.
    public var tool: String
    public var argumentsJSON: String
    /// What this step is for, in the author's words. Shown in the step card so
    /// somebody approving it knows why it is being asked for.
    public var note: String

    public init(id: String = OpaqueID.make("wfs"),
                tool: String, argumentsJSON: String = "{}", note: String = "") {
        self.id = id
        self.tool = tool
        self.argumentsJSON = argumentsJSON
        self.note = note
    }
}

public struct Workflow: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var steps: [WorkflowStep]
    public var updatedAt: Date

    public init(id: String = OpaqueID.make("wf"),
                name: String, steps: [WorkflowStep] = [], updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.steps = steps
        self.updatedAt = updatedAt
    }
}

public enum WorkflowError: Error, CustomStringConvertible, Equatable {
    case unknownTools([String], known: [String])
    case empty(String)
    case nameless

    public var description: String {
        switch self {
        case .unknownTools(let names, let known):
            return """
            ไม่รู้จักทูล \(names.map { "`\($0)`" }.joined(separator: ", ")) — บันทึกไม่ได้
            ทูลที่มีจริงตอนนี้: \(known.sorted().joined(separator: ", "))
            (ปฏิเสธตอนบันทึก ไม่ใช่ตอนรัน เพราะลำดับที่พังกลางคัน คือลำดับที่ทำครึ่งแรกไปแล้ว)
            """
        case .empty(let name):
            return "\(name) ยังไม่มีขั้นตอนสักขั้น — รันแล้วจะไม่เกิดอะไรขึ้น"
        case .nameless:
            return "ต้องตั้งชื่อลำดับงานก่อน เพราะชื่อคือสิ่งเดียวที่ทำให้เดือนหน้าหยิบอันที่ถูกมาใช้ได้"
        }
    }
}

/// What one step did. Kept per step rather than per run so a stopped run says
/// where it stopped, which is the question somebody actually has.
///
/// `Stop` matters as much as the boolean: the gate answers a call in several
/// different voices, and collapsing them into "failed" loses the difference
/// between a tool that broke, a rule that forbade the work, and **a person who
/// said no** — which is not a failure at all, it is the gate working.
public struct WorkflowStepOutcome: Sendable, Equatable {
    public enum Stop: Sendable, Equatable {
        case toolFailed
        /// A human declined it (§5.4).
        case declined
        case policy
        case stage
        /// Plan-only mode is on, so nothing was ever going to run (§5.5).
        case planOnly
        /// Refused before it ran — bad arguments, or a tool that is not there.
        case refused

        public var label: String {
            switch self {
            case .toolFailed: "ทูลทำงานไม่สำเร็จ"
            case .declined: "คนไม่อนุมัติ"
            case .policy: "ขัดนโยบาย"
            case .stage: "ขั้นของโปรเจกต์ยังไม่อนุญาต"
            case .planOnly: "อยู่ในโหมดวางแผนอย่างเดียว"
            case .refused: "ถูกปฏิเสธก่อนรัน"
            }
        }
    }

    public let stepID: String
    public let tool: String
    /// `nil` when the step ran.
    public let stop: Stop?
    public let detail: String

    public var succeeded: Bool { stop == nil }
}

public struct WorkflowRun: Sendable, Equatable {
    public let workflowID: String
    public let outcomes: [WorkflowStepOutcome]
    /// The step that stopped the run, if one did.
    public let stoppedAt: WorkflowStepOutcome?

    public var completed: Bool { stoppedAt == nil }
}

/// Runs a workflow's steps in order, through the gate.
///
/// It holds a `ToolGateway` and nothing else that can execute — there is no
/// path from here to a tool that skips the hook chain, which is exactly the
/// property v1's workflow engine lacked.
public struct WorkflowRunner: Sendable {
    private let gateway: ToolGateway
    private let log = AppLog.logger("workflow")

    public init(gateway: ToolGateway) {
        self.gateway = gateway
    }

    /// Names of every tool a session can reach right now. Read at validation
    /// time rather than captured, because MCP servers and plugins arrive while
    /// the app is running (the P8.5 rule).
    public func knownTools() async -> [String] {
        await gateway.adverts.map(\.name)
    }

    /// Refuses a workflow that could not run, in the words to show the author.
    /// Returns `nil` when it would run.
    public func refusal(for workflow: Workflow, known: [String]) -> String? {
        if workflow.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return WorkflowError.nameless.description
        }
        if workflow.steps.isEmpty {
            return WorkflowError.empty(workflow.name).description
        }
        let unknown = workflow.steps.map(\.tool).filter { !known.contains($0) }
        if !unknown.isEmpty {
            return WorkflowError.unknownTools(Array(Set(unknown)), known: known).description
        }
        return nil
    }

    /// Runs every step in order, stopping at the first one that does not run.
    public func run(_ workflow: Workflow, context: ToolContext) async -> WorkflowRun {
        var outcomes: [WorkflowStepOutcome] = []
        for step in workflow.steps {
            var stop: WorkflowStepOutcome.Stop?
            var detail: String
            do {
                let gate = try await gateway.call(step.tool,
                                                  argumentsJSON: step.argumentsJSON,
                                                  context: context)
                switch gate {
                case .executed(let output, _, let warnings):
                    detail = ([output.text] + warnings).joined(separator: "\n")
                case .denied(let reason):
                    stop = .declined; detail = reason ?? "ไม่อนุมัติ"
                case .blockedByPolicy(let why):
                    stop = .policy; detail = why
                case .blockedByStage(let why):
                    stop = .stage; detail = why
                case .planOnly:
                    stop = .planOnly; detail = gate.transcriptText
                case .sentBack(let reason):
                    stop = .refused; detail = reason
                case .unknownTool(let name):
                    stop = .refused; detail = "ไม่รู้จักทูล \(name)"
                }
            } catch {
                stop = .toolFailed; detail = "\(error)"
            }
            let outcome = WorkflowStepOutcome(stepID: step.id, tool: step.tool,
                                              stop: stop, detail: detail)
            outcomes.append(outcome)
            guard outcome.succeeded else {
                // Everything after this depended on it. Carrying on would be
                // guessing that it did not matter.
                log.error("workflow stopped at \(step.tool, privacy: .public)")
                return WorkflowRun(workflowID: workflow.id, outcomes: outcomes,
                                   stoppedAt: outcome)
            }
        }
        return WorkflowRun(workflowID: workflow.id, outcomes: outcomes, stoppedAt: nil)
    }
}

/// Saved procedures, one JSON file per workspace.
///
/// Follows the shape P9.2 settled on for the app's other list files: a file
/// that will not decode is copied aside *before* anything can save over it,
/// because the failure that costs someone their work is not the unreadable
/// file, it is the empty list being written on top of it.
public struct WorkflowStore: Sendable {
    public let file: URL
    private let log = AppLog.logger("workflow")

    public init(file: URL) { self.file = file }

    public func load() -> [Workflow] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        // Must match `save`. They were written apart once, and the result was
        // that every save came back unreadable: the file was fine, the reader
        // disagreed with the writer about dates, and the store then reported an
        // empty list — the P9.2 failure exactly, from inside one type.
        decoder.dateDecodingStrategy = .iso8601
        guard let saved = try? decoder.decode([Workflow].self, from: data) else {
            if let backup = FileStoreSafety.preserveUnreadable(file) {
                log.error("""
                    workflow file unreadable — kept a copy at \
                    \(backup.lastPathComponent, privacy: .public) and starting from an empty list
                    """)
            }
            return []
        }
        return saved.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func save(_ workflows: [Workflow]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try encoder.encode(workflows).write(to: file, options: .atomic)
    }

    @discardableResult
    public func upsert(_ workflow: Workflow) throws -> [Workflow] {
        var all = load().filter { $0.id != workflow.id }
        var updated = workflow
        updated.updatedAt = Date()
        all.append(updated)
        try save(all)
        return all.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func remove(_ id: String) throws {
        try save(load().filter { $0.id != id })
    }
}
