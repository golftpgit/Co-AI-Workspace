import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// One voice to the user (ARCHITECTURE §22.7, P16.6).
//
// Three teams working means three teams with something to say, and a person
// who receives all of it stops reading any of it — the failure has a name,
// notification fatigue, and it ends with the one message that mattered being
// swiped away with the rest.
//
// So: **only the Incident Commander speaks to the user.** Sub-teams report to
// their lead, leads report to the IC, and the IC decides what is worth a
// person's attention. Two exceptions, and they are exceptions in opposite
// directions:
//
//  • **An escalation goes straight through, now.** §2.5's escalation means a
//    team has stopped and is waiting for a human decision; holding it for the
//    next summary is holding up the work it was raised about.
//  • **Silence past a limit is itself a message.** A run with nothing to say
//    for twenty minutes looks exactly like a run that died, and "still working"
//    is what tells the two apart.
// ─────────────────────────────────────────────────────────────

public struct CommandMessage: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The IC's periodic summary of everything under it.
        case summary
        /// A team is stopped and needs a person (§2.5). Never batched.
        case escalation(team: String)
        /// Nothing to report, but a while has passed. Sent so silence does not
        /// read as a crash.
        case stillWorking
    }

    public let kind: Kind
    public let text: String
    public let at: Date

    public var isUrgent: Bool { if case .escalation = kind { return true }; return false }
}

/// Decides what actually reaches the user, and when.
///
/// A value type with an explicit clock rather than a timer of its own: what it
/// does is decide, and a decision that depends on a hidden `Date()` is a
/// decision nobody can test.
public struct CommandReporter: Sendable {
    /// How long a run may say nothing before it says "still working".
    public let quietLimit: TimeInterval
    /// How often a routine summary may go out. Coarser than the quiet limit on
    /// purpose: a summary every time anything happens is the fatigue this type
    /// exists to prevent.
    public let summaryInterval: TimeInterval

    public init(quietLimit: TimeInterval = 20 * 60,
                summaryInterval: TimeInterval = 5 * 60) {
        self.quietLimit = quietLimit
        self.summaryInterval = summaryInterval
    }

    /// What to send now, given what has happened since the last message.
    ///
    /// - Parameters:
    ///   - pendingEscalations: teams that stopped and are waiting for a person.
    ///   - summary: what the IC would say if it spoke now; nil when there is
    ///     nothing worth saying.
    ///   - lastSentAt: when the user last heard anything.
    ///   - now: the clock, passed in.
    public func next(pendingEscalations: [String],
                     summary: String?,
                     lastSentAt: Date,
                     now: Date) -> [CommandMessage] {
        // Escalations first and unbatched: each is a team that has stopped, and
        // combining two of them into one message makes the second look like
        // context for the first.
        var messages = pendingEscalations.map { team in
            CommandMessage(kind: .escalation(team: team),
                           text: "ทีม \(team) หยุดรอการตัดสินใจของคน — งานส่วนนั้นค้างอยู่จนกว่าจะตอบ",
                           at: now)
        }
        guard messages.isEmpty else { return messages }

        let quiet = now.timeIntervalSince(lastSentAt)
        if let summary, quiet >= summaryInterval {
            messages.append(CommandMessage(kind: .summary, text: summary, at: now))
            return messages
        }
        if quiet >= quietLimit {
            // Deliberately says how long, because "still working" without a
            // duration is the sentence a stuck process would also send.
            messages.append(CommandMessage(
                kind: .stillWorking,
                text: "ยังทำงานอยู่ — ไม่มีอะไรใหม่ที่ต้องตัดสินใจในช่วง "
                    + "\(Int(quiet / 60)) นาทีที่ผ่านมา",
                at: now))
        }
        return messages
    }

    /// Whether this team may speak to the user at all.
    ///
    /// The structural half of §22.7, and the reason it is a function rather
    /// than a convention: a sub-team that can reach the user directly makes the
    /// IC's summary a duplicate rather than the report, and the person is back
    /// to reading three streams.
    public func maySpeakToUser(team: String, incidentCommander: String) -> Bool {
        team == incidentCommander
    }
}
