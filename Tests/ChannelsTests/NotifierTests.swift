import Testing
import Foundation
import AgentKit
@testable import Channels

// ─────────────────────────────────────────────────────────────
// The Notifier (ARCHITECTURE §8.1, P7.5).
//
// Every test here is about restraint. Delivering a notification is trivial;
// the reason this type exists as something testable is that the wrong ones
// are what make a person turn all of them off, and then miss the approval
// that mattered.
// ─────────────────────────────────────────────────────────────

private actor SpyDelivery: NotificationDelivering {
    private(set) var delivered: [UserNotification] = []
    private(set) var withdrawn: [String] = []

    func deliver(_ notification: UserNotification) async { delivered.append(notification) }
    func withdraw(_ identifier: String) async { withdrawn.append(identifier) }
}

private func approval(tool: String = "run_shell",
                      detail: String = "rm -rf build/") -> ApprovalRequest {
    ApprovalRequest(toolName: tool, risk: .high, detail: detail)
}

@Suite("Notifier")
struct NotifierTests {

    @Test("an approval becomes a notification with the tool and what it would do")
    func approvalIsAnnounced() async {
        let spy = SpyDelivery()
        let notifier = Notifier(delivery: spy)

        await notifier.present(approval())

        let delivered = await spy.delivered
        #expect(delivered.count == 1)
        #expect(delivered.first?.title.contains("run_shell") == true)
        #expect(delivered.first?.body.contains("rm -rf build/") == true)
        #expect(delivered.first?.isApproval == true)
    }

    /// The one message that is a question. A turn stops until it is answered,
    /// so "they were probably looking at the screen" is not a good enough
    /// reason to stay quiet.
    @Test("an approval is announced even while the person is looking at the app")
    func approvalsIgnoreTheForegroundRule() async {
        let spy = SpyDelivery()
        let notifier = Notifier(delivery: spy, userIsWatching: { true })

        await notifier.present(approval())

        #expect(await spy.delivered.count == 1)
    }

    /// §5.4 — first response wins. A banner still asking about a decision
    /// that has been made invites a second answer to a closed question.
    @Test("answering an approval anywhere withdraws its notification")
    func answeredApprovalsAreWithdrawn() async {
        let spy = SpyDelivery()
        let notifier = Notifier(delivery: spy)
        let request = approval()

        await notifier.present(request)
        await notifier.approvalResolved(request.id, decision: .approved)

        #expect(await spy.withdrawn == [Notifier.identifier(for: request.id)])
        // The same name it was delivered under, or the withdrawal withdraws
        // nothing and nobody finds out until they see the stale banner.
        #expect(await spy.delivered.first?.identifier == Notifier.identifier(for: request.id))
    }

    @Test("a finished answer is announced only when the person is not looking")
    func repliesRespectTheForeground() async {
        let watching = SpyDelivery()
        await Notifier(delivery: watching, userIsWatching: { true })
            .send(AgentMessage(text: "เสร็จแล้ว"))
        #expect(await watching.delivered.isEmpty)

        let away = SpyDelivery()
        await Notifier(delivery: away, userIsWatching: { false })
            .send(AgentMessage(text: "เสร็จแล้ว"))
        #expect(await away.delivered.count == 1)
        #expect(await away.delivered.first?.isApproval == false)
    }

    @Test("progress is never worth a banner")
    func progressIsSilent() async {
        let spy = SpyDelivery()
        await Notifier(delivery: spy, userIsWatching: { false })
            .send(AgentMessage(kind: .progress, text: "· run_shell: ไม่ได้รัน"))
        #expect(await spy.delivered.isEmpty)
    }

    @Test("an error says so in the title")
    func errorsAreLabelled() async {
        let spy = SpyDelivery()
        await Notifier(delivery: spy).send(AgentMessage(kind: .error, text: "ต่อฐานข้อมูลไม่ได้"))
        #expect(await spy.delivered.first?.title == "งานผิดพลาด")
    }

    /// A banner has two lines. A notification that tries to be the whole
    /// message is unreadable in the banner and duplicated in the app.
    @Test("a long body is shortened to something a banner can show")
    func longBodiesAreShortened() {
        let long = String(repeating: "ก", count: 500)
        let shortened = Notifier.shortened(long)
        #expect(shortened.count < 200)
        #expect(shortened.hasSuffix("…"))
        #expect(Notifier.shortened("บรรทัดแรก\nบรรทัดสอง") == "บรรทัดแรก บรรทัดสอง")
    }
}
