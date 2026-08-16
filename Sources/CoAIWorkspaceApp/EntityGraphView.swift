import SwiftUI
import AgentKit
import Knowledge

// ─────────────────────────────────────────────────────────────
// The knowledge graph on screen (ARCHITECTURE §11.4, P2.7 · U4).
//
// The relations have been extracted and stored since P2.7 and **read by no
// view**: `KnowledgeViewModel.relations` was loaded at attach time and never
// rendered. So the graph has existed as data and never as anything a person
// could look at, which is the shape this project keeps finding.
//
// Two things a drawn graph has to get right that a list does not:
//
//  • **A node must be a control, not a shape.** A canvas of circles is the
//    classic place accessibility dies — and this project's own script fails
//    the build for it. Each node is a `Button` with a label saying what it is
//    and how many things it connects to, so it can be reached by keyboard and
//    read aloud, and pressing one re-centres the graph there.
//  • **An arrow looks like a fact.** Selecting an edge shows the sentence and
//    the document it came from, because `Relation.chunkID` exists precisely so
//    that a claim in the graph can be checked against the text that says it.
// ─────────────────────────────────────────────────────────────

struct EntityGraphView: View {
    @Bindable var model: KnowledgeViewModel

    @State private var focus: String?
    @State private var hops = 2
    @State private var selectedEdge: EntityGraph.Edge?

    private var relations: [EntityGraph.Relation] { model.relations.map(\.forGraph) }

    private var graph: EntityGraph? {
        focus.map { EntityGraph.around($0, in: relations, hops: hops) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.relations.isEmpty {
                ContentUnavailableView(
                    "ยังไม่มีความสัมพันธ์ในขอบเขตนี้",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("ความสัมพันธ์ถูกสกัดตอนเพิ่มเอกสารเข้าคลัง และต้องใช้โมเดล — เครื่องที่ยังโหลดโมเดลไม่ได้จะได้เอกสารครบแต่ไม่มีกราฟ"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let graph {
                canvas(graph)
                Text(graph.summary).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                edgeList(graph)
            } else {
                Text("เลือกสิ่งที่อยากดูความเชื่อมโยงจากรายการด้านบน")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(Space.section)
        .task(id: model.relations.count) {
            if focus == nil { focus = EntityGraph.busiestEntities(in: relations).first }
        }
        .sheet(item: $selectedEdge) { edge in
            EdgeSourceSheet(edge: edge, model: model)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("กราฟความรู้").font(.headline)
                // Which library this is a picture of. Driving found the graph
                // still showing central's relations after switching project,
                // with nothing on screen saying so — a graph that does not name
                // whose knowledge it is drawing is a chart with no axis label.
                Picker("ขอบเขต", selection: Binding(
                    get: { ScopeChoice(model.scope) },
                    set: { choice in
                        guard let scope = choice.scope(of: model.currentProject) else { return }
                        focus = nil
                        Task { await model.changeScope(to: scope) }
                    })) {
                    ForEach(ScopeChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                            .disabled(choice == .project && model.currentProject == nil)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                .accessibilityLabel("เลือกขอบเขตของกราฟ")
                Spacer()
                // A neighbourhood, always — the whole graph at once is a
                // hairball that looks like a lot and answers nothing.
                Picker("ระยะ", selection: $hops) {
                    ForEach(1...4, id: \.self) { Text("\($0) ชั้น").tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 240)
                .accessibilityLabel("ระยะที่เดินจากจุดกึ่งกลาง")
            }
            if !model.relations.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(EntityGraph.busiestEntities(in: relations), id: \.self) { entity in
                            Button(entity) { focus = entity }
                                .buttonStyle(.bordered)
                                .tint(entity == focus ? .accentColor : .secondary)
                                .font(.caption)
                                .accessibilityLabel("ดูความเชื่อมโยงของ \(entity)")
                        }
                    }
                }
                .frame(height: 34)
            }
        }
    }

    /// The picture. Radial rings, laid out by `EntityGraph` so the same data
    /// always draws the same way.
    private func canvas(_ graph: EntityGraph) -> some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let radius = max(40, (side / 2) - 60)
            let centre = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let scale = radius / Double(max(1, hops))
            let place: (EntityGraph.Node) -> CGPoint = { node in
                CGPoint(x: centre.x + node.x * scale, y: centre.y + node.y * scale)
            }
            let positions = Dictionary(uniqueKeysWithValues:
                graph.nodes.map { (EntityGraph.normalise($0.entity), place($0)) })

            // Computed once per draw rather than per edge: the map is over
            // every document in the scope, and doing it inside the loop would
            // rebuild it for every line.
            let classes = model.classesByEntity

            ZStack {
                ForEach(graph.edges) { edge in
                    if let from = positions[EntityGraph.normalise(edge.subject)],
                       let to = positions[EntityGraph.normalise(edge.object)] {
                        // §11.9/P18.5 — the line from RA to QA is the finding;
                        // the lines inside RA are the background it stands out
                        // from. Weight and opacity rather than colour alone,
                        // because a difference carried only by hue is a
                        // difference some readers do not have.
                        let crosses = model.crossesClasses(edge, using: classes)
                        Path { path in
                            path.move(to: from)
                            path.addLine(to: to)
                        }
                        .stroke(edge.id == selectedEdge?.id ? Color.accentColor
                                    : crosses ? Color.secondary.opacity(0.85)
                                              : Color.secondary.opacity(0.25),
                                lineWidth: edge.id == selectedEdge?.id ? 3
                                    : crosses ? 2.5 : 1)
                    }
                }
                ForEach(graph.nodes) { node in
                    // A control, not a shape — see the header.
                    Button {
                        focus = node.entity
                    } label: {
                        Text(node.entity)
                            .font(node.hop == 0 ? .callout.bold() : .caption2)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(node.hop == 0 ? Color.accentColor.opacity(0.2)
                                                      : Color.secondary.opacity(0.12),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .position(place(node))
                    .accessibilityLabel("\(node.entity) · ห่างจากจุดกึ่งกลาง \(node.hop) ชั้น · "
                                        + "เชื่อมกับ \(node.degree) อย่าง")
                    .accessibilityHint("กดเพื่อย้ายจุดกึ่งกลางมาที่นี่")
                }
            }
        }
        .frame(minHeight: 320)
    }

    /// The edges as text as well as lines. A picture is not readable by a
    /// screen reader and is not searchable; the list is how somebody finds the
    /// claim they are looking for, and how they reach its source.
    private func edgeList(_ graph: EntityGraph) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(graph.edges) { edge in
                    Button {
                        selectedEdge = edge
                    } label: {
                        Text("\(edge.subject) — *\(edge.predicate)* → \(edge.object)")
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // The list is where a screen reader meets the graph, so the
                    // crossing has to be a word here — a thicker line says
                    // nothing to somebody listening.
                    .accessibilityLabel("\(edge.subject) \(edge.predicate) \(edge.object)"
                                        + (model.crossesClasses(edge, using: model.classesByEntity)
                                           ? " · ข้ามหมวด" : ""))
                    .accessibilityHint("กดเพื่อดูข้อความที่เป็นที่มาของความสัมพันธ์นี้")
                }
            }
        }
        .frame(maxHeight: 140)
    }
}

// ─────────────────────────────────────────────────────────────

/// Where an arrow came from.
///
/// The reason this sheet exists is in `EntityGraph`'s header: an arrow between
/// two words reads as a fact, and the only thing that makes it checkable is the
/// passage that says it. Extracted relations are a model's reading of a
/// sentence, and this is where somebody disagrees with it.
private struct EdgeSourceSheet: View {
    let edge: EntityGraph.Edge
    @Bindable var model: KnowledgeViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ที่มาของความสัมพันธ์นี้").font(.headline)
            Text("\(edge.subject) — \(edge.predicate) → \(edge.object)")
                .font(.callout).textSelection(.enabled)
            Divider()
            if let chunk = model.chunk(id: edge.chunkID) {
                ScrollView {
                    Text(chunk.text).font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                Text("จาก “\(chunk.provenance.title)”")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                // Honest rather than blank: the chunk may have been deleted
                // with its document, and an edge whose source is gone should
                // say so rather than show nothing.
                Text("หาข้อความต้นทางไม่เจอ — อาจถูกลบไปพร้อมเอกสารแล้ว "
                     + "(ความสัมพันธ์จะถูกลบตามในการล้างครั้งถัดไป)")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                // Disagreeing with the reading is the point of this sheet, so
                // the way to do it is in it (§11.4). Destructive styling
                // because it removes something a person will not see again —
                // but what it removes is a claim, not the passage above it.
                if let stored = model.relation(matching: edge) {
                    Button("ไม่ใช่ความสัมพันธ์นี้ — ลบออก", role: .destructive) {
                        Task {
                            await model.rejectRelation(stored)
                            dismiss()
                        }
                    }
                    .accessibilityHint("ลบเฉพาะเส้นความสัมพันธ์ ข้อความต้นทางยังอยู่ "
                                       + "และการอ่านเอกสารซ้ำจะไม่สร้างเส้นนี้ขึ้นมาอีก")
                }
                Spacer()
                Button("ปิด") { dismiss() }
            }
        }
        .padding(Space.section)
        .frame(width: 520)
    }
}
