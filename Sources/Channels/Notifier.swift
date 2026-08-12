import Foundation
import AgentKit
import Observability

// ─────────────────────────────────────────────────────────────
// M4 `Notifier` (ARCHITECTURE §8.1, P7.5) — the channel that only speaks.
//
// A notification is a claim on someone's attention, so the interesting part of
// this file is not the delivery — that is four lines of UserNotifications, and
// it lives in the app because `UNUserNotificationCenter` needs a bundle. The
// part worth having here, where it can be tested, is *when not to speak*:
//
//  • An answer that arrives while the person is looking at the window is not
//    news. Every other channel is remote by definition; this one is not, and a
//    banner for a reply already on screen is how notifications get turned off.
//  • **An approval is the exception, always.** A request nobody answers stalls
//    the turn, and "they were probably looking" is not good enough for the one
//    message that is a question.
//  • Progress is never worth a banner.
//  • An approval answered somewhere else — from the phone, from the sheet —
//    withdraws its banner (§5.4, first response wins). A notification asking
//    for a decision that has already been made is worse than no notification:
//    it invites a second answer to a question that is closed.
// ─────────────────────────────────────────────────────────────

public struct UserNotification: Sendable, Equatable {
    /// Stable, so the banner for an approval can be withdrawn by the same name
    /// when somebody answers it.
    public let identifier: String
    public let title: String
    public let body: String
    /// Approvals are actionable; the delivering side gives them buttons.
    public let isApproval: Bool

    public init(identifier: String, title: String, body: String, isApproval: Bool) {
        self.identifier = identifier
        self.title = title
        self.body = body
        self.isApproval = isApproval
    }
}

/// The framework half, kept behind a protocol. `UNUserNotificationCenter`
/// requires a bundle identifier and traps without one, which a test process
/// does not have — and a notifier that cannot be tested without a signed app
/// is a notifier nobody will change.
public protocol NotificationDelivering: Sendable {
    func deliver(_ notification: UserNotification) async
    func withdraw(_ identifier: String) async
}

public actor Notifier: Channel {
    public nonisolated let id = ChannelID("notifier")

    private let delivery: any NotificationDelivering
    /// Whether the person is already looking at the app. Asked at the moment
    /// of speaking rather than stored: the answer changes while a turn runs,
    /// and the only moment that matters is this one.
    private let userIsWatching: @Sendable () async -> Bool
    private let log = AppLog.logger("notifier")

    public init(delivery: any NotificationDelivering,
                userIsWatching: @escaping @Sendable () async -> Bool = { false }) {
        self.delivery = delivery
        self.userIsWatching = userIsWatching
    }

    public func send(_ message: AgentMessage) async {
        switch message.kind {
        case .progress:
            return
        case .reply, .summary, .error:
            guard await !userIsWatching() else { return }
        }
        await delivery.deliver(
            UserNotification(identifier: "message:\(OpaqueID.make("ntf"))",
                             title: message.kind == .error ? "งานผิดพลาด" : "งานเสร็จแล้ว",
                             body: Self.shortened(message.text),
                             isApproval: false))
    }

    public func present(_ request: ApprovalRequest) async {
        await delivery.deliver(
            UserNotification(identifier: Self.identifier(for: request.id),
                             title: "ขออนุมัติ · \(request.toolName)",
                             body: Self.shortened(request.detail),
                             isApproval: true))
    }

    public func approvalResolved(_ id: ApprovalRequest.ID, decision: ApprovalDecision) async {
        await delivery.withdraw(Self.identifier(for: id))
    }

    public static func identifier(for id: ApprovalRequest.ID) -> String {
        "approval:\(id.rawValue)"
    }

    /// A banner has about two lines. The full text is in the app, and a
    /// notification that tries to be the whole message is unreadable in both
    /// places.
    static func shortened(_ text: String, limit: Int = 180) -> String {
        let compact = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return compact.count <= limit ? compact : String(compact.prefix(limit)) + "…"
    }
}
