import SwiftUI
import AgentKit
import CoreEngine
import LLMProviders
import Observability

// ─────────────────────────────────────────────────────────────
// The EOC dashboard (ARCHITECTURE §22.6, P16.5).
//
// Who is commanding whom, and who is actually working. Both come from spans —
// the chain of command because a span carries its parent, and "working" because
// a span that has ended is finished whatever anybody says about it (§2.5).
//
// **Two counts, from two places.** The tree counts the boxes it has lit; the
// server reports how many requests it is generating for (`ServerLoad`, P15.6).
// They are shown side by side rather than reconciled: when they disagree, that
// is the interesting fact — one of them is stale, and which one tells you where
// to look. A single number computed from both would hide exactly that.
// ─────────────────────────────────────────────────────────────

@MainActor
@Observable
final class CommandTreeViewModel {
    private(set) var roots: [CommandNode] = []
    private(set) var load: ServerLoad?
    private(set) var lastReadAt: Date?
    /// Rows the user has collapsed. Collapsed rather than expanded, so a run
    /// that grows a new branch shows it — the opposite default hides new work
    /// behind a disclosure triangle nobody knows to open.
    var collapsed: Set<String> = []

    private var spans: (() async -> [Span])?
    private var loadReader: ServerLoadReader?

    func attach(spans: @escaping () async -> [Span], loadReader: ServerLoadReader?) {
        self.spans = spans
        self.loadReader = loadReader
    }

    func refresh() async {
        guard let spans else { return }
        roots = CommandTree.build(from: await spans())
        load = await loadReader?.read()
        lastReadAt = Date()
    }

    var working: Int { CommandTree.working(in: roots) }

    /// What the two counts say together. Written as a sentence because the
    /// disagreement is the point, and a person reading a dashboard should not
    /// have to hold two numbers in their head to notice it.
    var reconciliation: String {
        guard let load else {
            return "อ่านคิวของเซิร์ฟเวอร์ไม่ได้ — ตัวเลขข้างล่างมาจาก span ฝั่งเราอย่างเดียว"
        }
        if load.running == working {
            return "ตรงกัน: กระดานลง \(working) · เซิร์ฟเวอร์กำลังรัน \(load.running)"
        }
        return "ไม่ตรงกัน: กระดานลง \(working) · เซิร์ฟเวอร์กำลังรัน \(load.running)"
            + (load.waiting > 0 ? " (รออีก \(load.waiting))" : "")
            + " — ตัวใดตัวหนึ่งเก่า ซึ่งเป็นข้อมูลที่ควรเห็น ไม่ใช่สิ่งที่ควรเกลี่ยให้เท่ากัน"
    }
}

struct CommandTreeScreen: View {
    @Bindable var model: CommandTreeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.roots.isEmpty {
                ContentUnavailableView(
                    "ยังไม่มีงานที่บันทึกไว้",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("สายบังคับบัญชาวาดจาก span — เริ่มงานทีมแล้วจะเห็นที่นี่"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Space.tight) {
                        ForEach(model.roots) { root in
                            CommandRows(node: root, depth: 0, model: model)
                        }
                    }
                    .padding(Space.box)
                }
            }
        }
        .task { await model.refresh() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Space.tight) {
                Text("สายบังคับบัญชา").font(.headline)
                // The reconciliation line is the one a person should read, so
                // it is the one next to the title.
                Text(model.reconciliation)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("อ่านใหม่") { Task { await model.refresh() } }
                .accessibilityLabel("อ่านสถานะสายบังคับบัญชาใหม่")
        }
        .padding(Space.box)
    }
}

/// One row and everything under it.
///
/// A flat `LazyVStack` with an indent rather than `OutlineGroup`: the rows have
/// to be reachable and readable one at a time, and each carries its own depth in
/// words for anybody listening (§14.4). Indentation is decoration on top of
/// that, not the thing that carries the meaning.
private struct CommandRows: View {
    let node: CommandNode
    let depth: Int
    @Bindable var model: CommandTreeViewModel

    private var isCollapsed: Bool { model.collapsed.contains(node.id.rawValue) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            row
            if !isCollapsed {
                ForEach(node.children) { child in
                    CommandRows(node: child, depth: depth + 1, model: model)
                }
            }
        }
    }

    private var row: some View {
        HStack(spacing: Space.row) {
            Color.clear.frame(width: CGFloat(depth) * Space.section, height: 1)
            if node.children.isEmpty {
                Color.clear.frame(width: Space.section, height: 1)
            } else {
                Button {
                    if isCollapsed { model.collapsed.remove(node.id.rawValue) }
                    else { model.collapsed.insert(node.id.rawValue) }
                } label: {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCollapsed
                                    ? "กางงานย่อยของ \(node.name)"
                                    : "พับงานย่อยของ \(node.name)")
            }

            statusDot
            Text(node.name).font(.callout)
            if let detail = node.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let duration = node.duration {
                Text("\(Int(duration.rounded())) วิ")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Space.tight)
        // One row, one spoken sentence, in the words `CommandTree` chose: the
        // view must not invent its own vocabulary for a state, or the screen
        // and the log describe the same run differently.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CommandTree.spoken(node, depth: depth))
        .focusable()
    }

    /// Three states, and they are three: working, waiting for a person, done.
    /// Colour alone never carries it — the spoken label says the same thing in
    /// words, because a dot is invisible to a screen reader and to anybody who
    /// does not see the difference between orange and green.
    private var statusDot: some View {
        Circle()
            .fill(node.needsAPerson ? Color.orange
                  : node.isWorking ? Color.green
                  : node.status == .failed ? Color.red : Color.secondary)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}
