import Foundation
import AgentKit
import Observability

// ─────────────────────────────────────────────────────────────
// Who is commanding whom, and who is actually working (§22.6, P16.5).
//
// The dashboard §22.6 asks for is a tree, and the tree already exists: spans
// carry a parent, so the chain of command is recorded rather than reconstructed.
// This turns that into something a screen can draw.
//
// **Busy is never an agent's claim.** §2.5's rule applies to the system's own
// status as much as to a specialist's work: an organisation chart where each
// box reports its own state says what everybody believes. A span that has
// ended is not working, whatever anything says — and the case that made this a
// Done-when is the opposite one, a team that finished and stayed lit, which
// makes the whole board untrustworthy the first time somebody notices.
//
// A pure function over spans, so the drawing can be checked without a database,
// a window or a run in flight.
// ─────────────────────────────────────────────────────────────

public struct CommandNode: Sendable, Equatable, Identifiable {
    public let id: SpanID
    public let name: String
    public let role: Role?
    public let status: SpanStatus
    public let startedAt: Date
    public let endedAt: Date?
    public let detail: String?
    public let children: [CommandNode]

    /// Whether this box should be lit.
    ///
    /// Both halves are required: a span whose status still says `running`
    /// because the process died mid-write, and one that has an end time, are
    /// both finished. Reading only the status is how a crashed run shows a team
    /// working forever.
    public var isWorking: Bool { status == .running && endedAt == nil }

    /// Working, or waiting for a person — which is not the same thing and has
    /// to look different: one needs patience, the other needs somebody.
    public var needsAPerson: Bool { status == .awaitingApproval && endedAt == nil }

    public var duration: TimeInterval? {
        endedAt.map { $0.timeIntervalSince(startedAt) }
    }

    /// Everything under this node, itself included, in the order a person reads
    /// it — which is also the order a screen reader announces it.
    public var flattened: [CommandNode] { [self] + children.flatMap(\.flattened) }
}

public enum CommandTree {

    /// Builds the tree, roots first, newest last.
    ///
    /// A span whose parent is not in the set becomes a root rather than being
    /// dropped: the usual reason is that the query window starts after the
    /// parent began, and losing a whole branch because its top is out of view
    /// would make the dashboard quietly wrong rather than visibly partial.
    public static func build(from spans: [Span]) -> [CommandNode] {
        var childrenByParent: [SpanID: [Span]] = [:]
        let known = Set(spans.map(\.id))
        var roots: [Span] = []

        for span in spans {
            if let parent = span.parent, known.contains(parent) {
                childrenByParent[parent, default: []].append(span)
            } else {
                roots.append(span)
            }
        }

        func node(_ span: Span, depth: Int) -> CommandNode {
            // Bounded in case a stored parent chain ever loops: a dashboard
            // that hangs the app is worse than one that shows a shallow tree.
            let children = depth >= 12 ? [] :
                (childrenByParent[span.id] ?? [])
                    .sorted { $0.startedAt < $1.startedAt }
                    .map { node($0, depth: depth + 1) }
            return CommandNode(id: span.id, name: span.name, role: span.role,
                               status: span.status, startedAt: span.startedAt,
                               endedAt: span.endedAt, detail: span.detail,
                               children: children)
        }

        return roots.sorted { $0.startedAt < $1.startedAt }.map { node($0, depth: 0) }
    }

    /// How many boxes are lit, counted from the spans rather than asked of
    /// anybody. The number a person compares against the server's own queue
    /// (`ServerLoad`) — two counts of the same work, from two places that
    /// cannot both be lying in the same direction.
    public static func working(in nodes: [CommandNode]) -> Int {
        nodes.flatMap(\.flattened).count(where: \.isWorking)
    }

    /// What a screen reader says for one row.
    ///
    /// Written here rather than in the view because it is the part that has to
    /// be right: §14.4's rule is that everything reachable by eye is reachable
    /// by ear, and a tree drawn with indentation says nothing about depth to
    /// somebody listening. Depth, state and duration go into words.
    public static func spoken(_ node: CommandNode, depth: Int) -> String {
        var parts = ["ชั้นที่ \(depth + 1)", node.name]
        if let role = node.role { parts.append("บทบาท \(role.rawValue)") }
        if node.needsAPerson {
            parts.append("รอคนตัดสินใจ")
        } else if node.isWorking {
            parts.append("กำลังทำอยู่")
        } else {
            parts.append(status(node))
        }
        if let duration = node.duration {
            parts.append("ใช้เวลา \(Int(duration.rounded())) วินาที")
        }
        if !node.children.isEmpty { parts.append("มีงานย่อย \(node.children.count) รายการ") }
        return parts.joined(separator: " · ")
    }

    private static func status(_ node: CommandNode) -> String {
        switch node.status {
        case .succeeded: "เสร็จแล้ว"
        case .failed: "ล้มเหลว"
        case .cancelled: "ถูกยกเลิก"
        case .awaitingApproval, .running:
            // Ended while still marked running or awaiting: the process stopped
            // between the work and the write. Said as what it is rather than
            // shown as live work, which is the failure this whole type guards.
            "จบไปแล้วโดยไม่มีการปิดสถานะ"
        }
    }
}
