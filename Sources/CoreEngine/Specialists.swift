import Foundation
import AgentKit
import LLMProviders
import Observability

// ─────────────────────────────────────────────────────────────
// The team's members (ARCHITECTURE §2.3, §2.4, P4.1).
//
// Each is a Swift `actor`, and that is the whole mechanism: a specialist's
// working context — its messages, its tool output, its dead ends — cannot
// leave it, because the only thing it can hand back is a `Deliverable`. v1
// relied on discipline for this and lost; here the compiler enforces it.
//
// The second rule, and the one that makes review possible: **evidence is
// collected from what actually ran**, never from what the model said it did.
// A specialist claiming "tests pass" produces nothing a reviewer can use; a
// recorded `run_shell` with exit code 0 does (§2.5).
// ─────────────────────────────────────────────────────────────

/// What every specialist shares: a model, a gate, and the rule that it may
/// only touch the tools its role is allowed.
public struct SpecialistEnvironment: Sendable {
    let router: ModelRouter
    let gateway: ToolGateway
    let maxToolRounds: Int

    public init(router: ModelRouter, gateway: ToolGateway, maxToolRounds: Int = 8) {
        self.router = router
        self.gateway = gateway
        self.maxToolRounds = maxToolRounds
    }
}

/// The shared body of a specialist's turn. A struct rather than a base class
/// because actors cannot inherit — and because the isolation belongs to the
/// actor, not to this.
struct SpecialistEngine: Sendable {
    let role: Role
    let environment: SpecialistEnvironment
    let allowedTools: Set<String>
    let systemPrompt: String
    private let log = AppLog.logger("specialist")

    /// Runs the assignment to a deliverable. Everything in between — the
    /// messages, the raw tool output — stays inside the caller's actor and is
    /// never returned.
    func run(_ assignment: Assignment, scope: Scope,
             workingDirectory: URL?) async throws -> Deliverable {
        var messages: [LLMMessage] = [
            .init(.system, systemPrompt),
            .init(.system, Self.brief(assignment)),
            .init(.user, assignment.goal),
        ]

        var transcript: [ToolTranscript.Entry] = []
        var artifacts: [String] = []
        var summary = ""

        let adverts = await environment.gateway.adverts
            .filter { allowedTools.contains($0.name) }
        let tools = adverts.map {
            LLMToolSpec(name: $0.name, description: $0.description,
                        parametersJSON: $0.parametersJSON)
        }

        for _ in 0..<environment.maxToolRounds {
            var request = LLMRequest(messages: messages)
            request.tools = tools
            request.maxTokens = 2_048

            let completion: LLMCompletion
            do {
                completion = try await environment.router.complete(
                    request, policy: .init(impact: assignment.role == .engineer ? .high : .medium))
            } catch {
                throw SpecialistError.modelUnavailable("\(error)")
            }

            if !completion.text.isEmpty { summary = completion.text }
            guard !completion.toolCalls.isEmpty else { break }

            messages.append(.init(.assistant, completion.text,
                                  toolCalls: completion.toolCalls))

            for call in completion.toolCalls {
                // Every call goes through the gate. A specialist is not a way
                // around the hook chain (§5.3), and a role asking for a tool
                // it was not given is refused here rather than silently
                // succeeding.
                guard allowedTools.contains(call.name) else {
                    messages.append(.init(.tool,
                                          "เครื่องมือ \(call.name) ไม่ได้อยู่ในสิทธิ์ของ \(role.rawValue)",
                                          toolCallID: call.id))
                    continue
                }

                let outcome = try await environment.gateway.call(
                    call.name, argumentsJSON: call.argumentsJSON,
                    context: ToolContext(scope: scope, workingDirectory: workingDirectory))

                let entry = ToolTranscript.Entry(
                    toolName: call.name,
                    executed: outcome.didExecute,
                    text: outcome.transcriptText)
                transcript.append(entry)
                if case .executed(let output, _, _) = outcome {
                    artifacts.append(contentsOf: output.artifacts)
                }
                messages.append(.init(.tool, ToolTranscript.encode(entry),
                                      toolCallID: call.id))
            }
        }

        return Deliverable(
            assignmentID: assignment.id,
            summary: summary.isEmpty ? "ไม่มีข้อสรุปจาก \(role.rawValue)" : summary,
            artifacts: Array(Set(artifacts)).sorted(),
            // Derived from the transcript, not from the summary: what the
            // model claims and what it did are different things.
            evidence: EvidenceReader.evidence(from: transcript, role: role))
    }

    private static func brief(_ assignment: Assignment) -> String {
        let criteria = assignment.acceptanceCriteria.enumerated().map {
            "\($0.offset + 1). \($0.element.text) — ต้องมีหลักฐาน: \($0.element.evidenceRequired)"
        }.joined(separator: "\n")
        return """
        งานที่ได้รับมอบหมาย (id: \(assignment.id))
        ผลงานที่ต้องส่ง: \(assignment.deliverableType)

        เกณฑ์ที่จะถูกตรวจ:
        \(criteria)

        ข้อมูลตั้งต้น:
        \(assignment.inputs.isEmpty ? "— ไม่มี —" : assignment.inputs.joined(separator: "\n"))
        """
    }
}

public enum SpecialistError: Error, CustomStringConvertible, Equatable {
    case modelUnavailable(String)
    /// §2.4: the Engineer works in one context and may not split itself.
    case fanOutForbidden(Role)

    public var description: String {
        switch self {
        case .modelUnavailable(let message): "เรียกโมเดลไม่ได้: \(message.prefix(120))"
        case .fanOutForbidden(let role): "\(role.rawValue) ห้ามแตกงานย่อยเป็นหลาย context (§2.4)"
        }
    }
}

// MARK: - the four roles

/// What each role may touch, in one table.
///
/// Written once because two places that both know a role's tool list are two
/// places that can disagree — and the second one is `base:` in a manifest
/// (§7.2), which inherits from here. `RosterTests` checks the mirror rather
/// than trusting it.
public enum SpecialistTools {
    public static let byRole: [Role: Set<String>] = [
        // `ingest_url` belongs to the role that finds sources: a page worth
        // citing later has to be *in* the knowledge base, and `fetch_page`
        // only reads it once.
        .researcher: ["kb_search", "web_search", "fetch_page", "ingest_url"],
        // The three analysis tools were missing here until 2026-08-12, which
        // meant the specialist whose entire job is analysis had to reach the
        // store through `run_shell` or not at all.
        .analyst: ["kb_search", "run_shell", "run_stat_test",
                   "analysis_query", "analysis_execute", "pull_db_table"],
        .engineer: ["run_shell", "kb_search"],
        // A Writer that cannot write a file is a Writer that hands back prose
        // for somebody else to paste (§14.1).
        .writer: ["kb_search", "save_document"],
    ]

    static func forRole(_ role: Role) -> Set<String> { byRole[role] ?? [] }
}

public actor Researcher: Specialist {
    public nonisolated let role = Role.researcher
    /// §2.5: two sources, read rather than skimmed, and disagreements filed.
    public nonisolated let definitionOfDone = [
        Criterion(text: "ทุกข้อสรุปมีอย่างน้อย 2 แหล่ง",
                  evidenceRequired: "citation พร้อม tier อย่างน้อย 2 รายการ"),
        Criterion(text: "อ่านเนื้อหาจริง ไม่ตัดสินจาก snippet",
                  evidenceRequired: "มีการเรียก fetch_page ที่รันจริง"),
    ]

    private let engine: SpecialistEngine

    public init(environment: SpecialistEnvironment) {
        engine = SpecialistEngine(
            role: .researcher, environment: environment,
            allowedTools: SpecialistTools.forRole(.researcher),
            systemPrompt: """
            คุณคือ Researcher ของทีมวิจัย หน้าที่คือหาหลักฐานที่อ้างอิงได้
            - ค้นจากคลังความรู้ก่อนเสมอ (kb_search) แล้วจึงค้นเว็บถ้ายังไม่พอ
            - **ห้ามสรุปจาก snippet ของผลค้นหา** ต้องเรียก fetch_page อ่านหน้านั้นจริงก่อน
            - ทุกข้อสรุปต้องมีอย่างน้อย 2 แหล่ง และระบุ tier ของแต่ละแหล่ง
            - แหล่ง T5 สองแหล่งยังถือว่าอ่อน ต้องพยายามหา T1–T2
            - ถ้าพบว่าสองแหล่งขัดกัน ให้รายงานทั้งสองฝั่ง **ห้ามเลือกข้างเอง**
            """)
    }

    public func execute(_ assignment: Assignment) async throws -> Deliverable {
        try await engine.run(assignment, scope: .central, workingDirectory: nil)
    }

    public func execute(_ assignment: Assignment, scope: Scope) async throws -> Deliverable {
        try await engine.run(assignment, scope: scope, workingDirectory: nil)
    }
}

public actor Analyst: Specialist {
    public nonisolated let role = Role.analyst
    public nonisolated let definitionOfDone = [
        Criterion(text: "ผ่าน assumption check ของสถิติที่ใช้",
                  evidenceRequired: "ผลการตรวจ assumption ที่รันจริง"),
    ]

    private let engine: SpecialistEngine

    public init(environment: SpecialistEnvironment) {
        engine = SpecialistEngine(
            role: .analyst, environment: environment,
            // `run_stat_test` is how this role produces the evidence its own
            // Definition of Done asks for: the gate hands back the assumption
            // checks with the p-value, never one without the other (§12.3).
            allowedTools: SpecialistTools.forRole(.analyst),
            systemPrompt: """
            คุณคือ Analyst หน้าที่คือวิเคราะห์ข้อมูลอย่างตรวจสอบได้
            - ใช้ run_stat_test ทุกครั้งที่ต้องทดสอบทางสถิติ อย่าคำนวณค่า p เอง
            - ระบุสมมติฐานของวิธีทางสถิติที่เลือกใช้ทุกครั้ง และตรวจสอบก่อนสรุป
            - ทุกนิยามตัวแปรต้องบอกที่มา
            - ห้ามสรุปผลที่ข้อมูลไม่รองรับ ถ้าข้อมูลไม่พอให้บอกว่าไม่พอ
            """)
    }

    public func execute(_ assignment: Assignment) async throws -> Deliverable {
        try await engine.run(assignment, scope: .central, workingDirectory: nil)
    }
}

/// §2.4: works in one context, never fans out. The rule is enforced by this
/// type having no way to create sub-assignments, not by asking it not to.
public actor Engineer: Specialist {
    public nonisolated let role = Role.engineer
    public nonisolated let definitionOfDone = [
        Criterion(text: "build/test ผ่านจริง",
                  evidenceRequired: "tool call ที่รัน build หรือ test แล้วได้ exit code 0"),
    ]

    private let engine: SpecialistEngine
    private let workingDirectory: URL?

    public init(environment: SpecialistEnvironment, workingDirectory: URL? = nil) {
        self.workingDirectory = workingDirectory
        engine = SpecialistEngine(
            role: .engineer, environment: environment,
            allowedTools: SpecialistTools.forRole(.engineer),
            systemPrompt: """
            คุณคือ Engineer หน้าที่คือแก้โค้ดให้ผ่านการทดสอบจริง
            - งานเสร็จเมื่อ build/test รันจริงแล้วผ่าน ไม่ใช่เมื่อคุณคิดว่าแก้ถูกแล้ว
            - ถ้าเทสไม่ผ่าน ให้อ่าน output จริงแล้วแก้ต่อ ห้ามอ้างว่าน่าจะผ่าน
            - ทำงานใน context เดียว ห้ามแตกงานย่อยให้ใครอื่น
            """)
    }

    public func execute(_ assignment: Assignment) async throws -> Deliverable {
        try await engine.run(assignment, scope: .central, workingDirectory: workingDirectory)
    }
}

public actor Writer: Specialist {
    public nonisolated let role = Role.writer
    public nonisolated let definitionOfDone = [
        Criterion(text: "ทุกประโยคจาก KB มี citation",
                  evidenceRequired: "citation ที่ผูกกับ provenance จริง"),
    ]

    private let engine: SpecialistEngine

    public init(environment: SpecialistEnvironment) {
        engine = SpecialistEngine(
            role: .writer, environment: environment,
            allowedTools: SpecialistTools.forRole(.writer),
            systemPrompt: """
            คุณคือ Writer หน้าที่คือเรียบเรียงให้อ่านรู้เรื่องและตรวจสอบย้อนกลับได้
            - ทุกประโยคที่มาจากคลังความรู้ต้องมี citation ระบุเอกสารและ tier
            - ข้อสันนิษฐานที่ agent เสนอเอง ต้องขึ้นบัญชีไว้ในหัวข้อข้อจำกัด
            - ห้ามเพิ่มข้อเท็จจริงที่ไม่มีในหลักฐานที่ได้รับ
            """)
    }

    public func execute(_ assignment: Assignment) async throws -> Deliverable {
        try await engine.run(assignment, scope: .central, workingDirectory: nil)
    }
}

// MARK: - evidence

/// Reads evidence out of what actually happened. Every rule here answers the
/// same question — "what would a reviewer accept?" — and the answer is never
/// "the model said so" (§2.5).
enum EvidenceReader {
    static func evidence(from transcript: [ToolTranscript.Entry], role: Role) -> [Evidence] {
        var evidence: [Evidence] = []

        for entry in transcript where entry.executed {
            switch entry.toolName {
            case "run_shell":
                // The exit code is the external truth an Engineer's "done"
                // has to be gated on.
                let passed = entry.text.contains("exit code: 0")
                    || entry.text.contains("exit 0")
                evidence.append(Evidence(
                    kind: .commandExit,
                    summary: String(entry.text.prefix(200)),
                    passed: passed))

            case "fetch_page":
                // A citation exists because a page was read, not because a
                // search returned a link — and it carries the tier the tool
                // declared, because "two sources" without tiers is the claim
                // §14.1 exists to refuse (P13.2).
                evidence.append(Evidence(
                    kind: .citation,
                    summary: String(entry.text.prefix(200)),
                    passed: true,
                    tier: CitationTier.tier(in: entry.text)))

            case "kb_search":
                let found = !entry.text.contains("ไม่พบข้อมูล")
                evidence.append(Evidence(
                    kind: .citation,
                    summary: String(entry.text.prefix(200)),
                    passed: found,
                    tier: CitationTier.tier(in: entry.text)))

            default:
                break
            }
        }
        return evidence
    }
}
