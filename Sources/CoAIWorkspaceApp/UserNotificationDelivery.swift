import Foundation
import UserNotifications
import AppKit
import Channels
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
}
