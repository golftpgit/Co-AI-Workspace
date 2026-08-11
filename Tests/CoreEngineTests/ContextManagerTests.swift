import Testing
import Foundation
import AgentKit
import LLMProviders
@testable import CoreEngine

// ─────────────────────────────────────────────────────────────
// P4.9's Done-when: a session long enough to compact keeps working, and the
// three fields v1 could never fill are not empty (ARCHITECTURE §5.6, App. D-5).
// ─────────────────────────────────────────────────────────────

private func transcript() -> [LLMMessage] {
    var messages: [LLMMessage] = [
        .init(.system, "ตอบเป็นภาษาไทยเสมอ"),
        .init(.user, "ช่วยแก้เทสที่ตกใน Tests/KnowledgeTests/ChunkerTests.swift ให้หน่อย"),
    ]
    // A few rounds of real-looking work: one command that worked, one that did
    // not, an approval, and a lot of output nobody will re-read.
    messages.append(.init(.assistant, "จะลองรันเทสก่อน", toolCalls: [
        LLMToolCall(id: "1", name: "run_shell",
                    argumentsJSON: #"{"command":"swift test --filter ChunkerTests"}"#),
    ]))
    messages.append(.init(.tool, String(repeating: "ผลลัพธ์เทสยาวมาก ", count: 400)
                          + "\nerror: ChunkerTests.swift:42 expectation failed",
                          toolCallID: "1"))
    messages.append(.init(.user, "อนุมัติให้แก้ไฟล์ Sources/Knowledge/Chunker.swift ได้เลย"))
    messages.append(.init(.assistant, "แก้แล้ว", toolCalls: [
        LLMToolCall(id: "2", name: "run_shell",
                    argumentsJSON: #"{"command":"swift build"}"#),
    ]))
    messages.append(.init(.tool, String(repeating: "บรรทัดคอมไพล์ ", count: 400)
                          + "\nBuild complete!", toolCallID: "2"))
    for index in 0..<12 {
        messages.append(.init(.user, "คำถามต่อเนื่องข้อที่ \(index) " + String(repeating: "ก", count: 300)))
        messages.append(.init(.assistant, "คำตอบข้อที่ \(index) " + String(repeating: "ข", count: 300)))
    }
    return messages
}

@Suite("Context compaction")
struct ContextManagerTests {
    @Test("compacting starts before the window is full, not when it overflows")
    func compactsAtThreshold() {
        let manager = ContextManager(budget: 1_000, compactAt: 0.75)
        #expect(manager.threshold == 750)

        let small = [LLMMessage(.user, String(repeating: "ก", count: 300))]
        #expect(!manager.shouldCompact(small))

        let large = [LLMMessage(.user, String(repeating: "ก", count: 3_000))]
        #expect(manager.shouldCompact(large))
    }

    @Test("a compacted transcript is materially smaller")
    func compactionShrinks() async {
        let messages = transcript()
        let manager = ContextManager(budget: 4_000)
        let result = await manager.compact(messages, goal: "แก้เทสที่ตก")

        #expect(result.tokensAfter < result.tokensBefore / 2,
                "compaction saved almost nothing: \(result.tokensBefore) → \(result.tokensAfter)")
    }

    // The debt itself. v1 shipped a handoff whose interesting fields were
    // always empty, so a compacted session forgot what it had decided and
    // re-asked. These come from the transcript, not from a model's opinion.
    @Test("the three fields v1 left empty are filled from evidence")
    func evidenceFieldsAreFilled() async {
        let manager = ContextManager(budget: 4_000)
        let result = await manager.compact(transcript(), goal: "แก้เทสที่ตก")
        let handoff = result.handoff

        #expect(!handoff.openIssues.isEmpty, "a failing command left no open issue")
        #expect(handoff.openIssues.contains { $0.lowercased().contains("error") })

        #expect(!handoff.keyDecisions.isEmpty, "an approval was not recorded as a decision")
        #expect(handoff.keyDecisions.contains { $0.contains("อนุมัติ") })

        #expect(!handoff.filePointers.isEmpty, "no file was remembered")
        #expect(handoff.filePointers.contains { $0.contains("Chunker.swift") })
    }

    @Test("file pointers are paths, never the contents behind them")
    func pointersCarryNoContent() async {
        let secret = String(repeating: "เนื้อหาลับในไฟล์ ", count: 200)
        let messages: [LLMMessage] = [
            .init(.assistant, "อ่านไฟล์", toolCalls: [
                LLMToolCall(id: "1", name: "read", argumentsJSON: #"{"path":"/tmp/report.md"}"#),
            ]),
            .init(.tool, secret, toolCallID: "1"),
        ]
        let handoff = await ContextManager(budget: 4_000)
            .compact(messages, goal: "อ่านรายงาน").handoff

        #expect(handoff.filePointers.contains("/tmp/report.md"))
        for pointer in handoff.filePointers {
            #expect(!pointer.contains("เนื้อหาลับ"), "a pointer carried the file's content")
        }
    }

    /// Instructions given at the start are what a user is most surprised to
    /// lose. In v1 they were the first thing dropped, because they were just
    /// the oldest messages.
    @Test("durable rules survive compaction")
    func durableRulesSurvive() async {
        let result = await ContextManager(budget: 4_000).compact(
            transcript(), goal: "แก้เทสที่ตก",
            durableRules: ["ห้ามแก้ไฟล์ใน vendor/", "ตอบเป็นภาษาไทยเสมอ"])

        let systemText = result.messages.filter { $0.role == .system }
            .map(\.content).joined(separator: "\n")
        #expect(systemText.contains("ห้ามแก้ไฟล์ใน vendor/"))
        #expect(systemText.contains("ตอบเป็นภาษาไทยเสมอ"))
    }

    @Test("the narrative fields come from the model, and its absence is survivable")
    func narrationIsOptional() async {
        let manager = ContextManager(budget: 4_000)

        let withModel = await manager.compact(transcript(), goal: "แก้เทสที่ตก") { _ in
            (completed: ["รันเทสแล้วเห็นว่าตก"], remaining: ["แก้ให้ผ่าน"])
        }
        #expect(withModel.handoff.completedSteps == ["รันเทสแล้วเห็นว่าตก"])
        #expect(withModel.handoff.remainingSteps == ["แก้ให้ผ่าน"])

        // No model reachable: the evidence half still has to arrive, or an
        // offline machine loses the decisions it already made.
        let without = await manager.compact(transcript(), goal: "แก้เทสที่ตก")
        #expect(without.handoff.completedSteps.isEmpty)
        #expect(!without.handoff.isEmpty)
        #expect(!without.handoff.keyDecisions.isEmpty)
    }

    /// The endpoint rejects a `tool` message whose originating `tool_calls` are
    /// gone (ARCHITECTURE E.9), so the cut cannot land between them.
    @Test("compaction never orphans a tool result from its call")
    func toolResultsKeepTheirCall() async {
        let result = await ContextManager(budget: 4_000, keepRecent: 3)
            .compact(transcript(), goal: "แก้เทสที่ตก")

        var seenCallIDs = Set<String>()
        for message in result.messages {
            for call in message.toolCalls { seenCallIDs.insert(call.id) }
            if message.role == .tool, let id = message.toolCallID {
                #expect(seenCallIDs.contains(id),
                        "a tool result was kept without the assistant turn that asked for it")
            }
        }
    }
}
