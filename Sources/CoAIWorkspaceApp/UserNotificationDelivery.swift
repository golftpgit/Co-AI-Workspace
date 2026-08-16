import Foundation
import UserNotifications
import AppKit
import Channels
import CoreEngine
import AgentKit
import Observability

// ─────────────────────────────────────────────────────────────
// The four lines of UserNotifications the Notifier does not contain
// (ARCHITECTURE §8.1, P7.5).
//
// It lives in the app and not in M4 for one reason that is easy to discover
// the hard way: `UNUserNotificationCenter.current()` requires a bundle
// identifier and **traps** without one. A `swift test` process has no bundle,
// so a Notifier that called it directly would be a Notifier whose tests
// crashed the runner. Everything worth deciding is on the other side of
// `NotificationDelivering`, where it is tested; this is the part that can only
// be checked by a person seeing a banner.
//
// Authorisation is asked for once, lazily, at the first notification rather
// than at launch: a permission prompt during boot is a prompt about something
// the person has not asked for yet.
// ─────────────────────────────────────────────────────────────

actor UserNotificationDelivery: NotificationDelivering {
    private var authorisation: Bool?
    private let log = AppLog.logger("notifier")

    /// Nil when the process has no bundle — a plain `swift run` of the
    /// executable, which is a normal way to work on this app. Nil means every
    /// notification is dropped quietly rather than the app dying.
    private nonisolated var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    func deliver(_ notification: UserNotification) async {
        guard let center, await allowed(center) else { return }
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = notification.isApproval ? .default : nil
        if notification.isApproval {
            content.categoryIdentifier = Self.approvalCategory
            // Approvals interrupt. A banner asking a question that is holding
            // a turn open has to survive Do Not Disturb; a finished answer
            // does not.
            content.interruptionLevel = .timeSensitive
        }
        do {
            try await center.add(UNNotificationRequest(identifier: notification.identifier,
                                                       content: content, trigger: nil))
        } catch {
            log.error("notification not delivered: \(error, privacy: .public)")
        }
    }

    func withdraw(_ identifier: String) async {
        center?.removeDeliveredNotifications(withIdentifiers: [identifier])
        center?.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    private func allowed(_ center: UNUserNotificationCenter) async -> Bool {
        if let authorisation { return authorisation }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        authorisation = granted
        if !granted { log.info("notifications not permitted — nothing will be shown") }
        return granted
    }

    static let approvalCategory = "coai.approval"
    static let approveAction = "coai.approve"
    static let rejectAction = "coai.reject"

    /// The two buttons on an approval banner (§8.1, P7.5).
    ///
    /// The banner has been asking a question with no way to answer it: the
    /// only route was to open the app and find the request, which for
    /// run-until-done means a turn sits held open until somebody comes back to
    /// their desk — the exact situation the notification exists for.
    ///
    /// **Approve is not destructive and reject is.** That is the right way
    /// round for the button styling and the wrong way round for what people
    /// expect from a banner, so it is stated: the destructive-looking one is
    /// the one that stops the work, because a tap that runs a shell command by
    /// accident is worse than one that refuses something you wanted.
    ///
    /// Neither button opens the app. Approving from the banner is the point;
    /// an action that launched the app to ask again would be the same wait
    /// with an extra step.
    static var approvalActions: UNNotificationCategory {
        UNNotificationCategory(
            identifier: approvalCategory,
            actions: [
                UNNotificationAction(identifier: approveAction, title: "อนุมัติ",
                                     options: [.authenticationRequired]),
                UNNotificationAction(identifier: rejectAction, title: "ไม่อนุมัติ",
                                     options: [.destructive]),
            ],
            intentIdentifiers: [],
            options: [])
    }
}

// ─────────────────────────────────────────────────────────────

/// Turns a tap on a banner button into an answer (§5.4, P7.5).
///
/// Separate from the delivery actor because it is the *receiving* half and it
/// has a rule of its own: the identifier the banner carries is the approval
/// request's id, and an answer for a request that is already resolved is
/// dropped by the broker rather than applied late — the same rule every other
/// channel gets, because a decision arriving after the turn moved on is not a
/// decision, it is a surprise.
@MainActor
final class ApprovalNotificationResponder: NSObject, UNUserNotificationCenterDelegate {
    private let broker: ApprovalBroker

    init(broker: ApprovalBroker) {
        self.broker = broker
    }

    /// Registers the category and starts listening. Called once at boot.
    func attach() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([UserNotificationDelivery.approvalActions])
        center.delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async {
        let decision: ApprovalDecision
        switch response.actionIdentifier {
        case UserNotificationDelivery.approveAction:
            decision = .approved
        case UserNotificationDelivery.rejectAction:
            decision = .rejected(reason: "ปฏิเสธจากการแจ้งเตือน")
        default:
            // Tapping the banner itself opens the app, which is what somebody
            // wanting to read the arguments before deciding is doing.
            return
        }
        await broker.submit(.init(response.notification.request.identifier),
                            decision: decision, from: nil)
    }
}
