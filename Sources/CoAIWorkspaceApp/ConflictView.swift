import SwiftUI
import AgentKit
import Knowledge
import Persistence

// ─────────────────────────────────────────────────────────────
// The Conflict Card (ARCHITECTURE §11.6, P3.7).
//
// §11.6 is specific about what has to be on it, and each row of that table is
// there because leaving it out pushes the user back to the documents:
//
//   both passages verbatim · where each came from, with its tier and year ·
//   the weights as reasons · the system's suggestion, marked as a suggestion ·
//   four choices including "both, in different contexts" and "not yet" ·
//   and whether the decision binds one project or everything.
// ─────────────────────────────────────────────────────────────

struct ConflictView: View {
    @Bindable var model: ConflictViewModel
    @State private var deciding: StoredConflict?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if model.visible.isEmpty {
                ContentUnavailableView(
                    model.showsDecided ? "ยังไม่มีข้อขัดแย้งที่บันทึกไว้" : "ไม่มีข้อขัดแย้งที่รอตัดสิน",
                    systemImage: "checkmark.seal",
                    description: Text("ระบบจะยกขึ้นมาเองเมื่อพบว่าสองแหล่งตอบคำถามเดียวกันไม่ตรงกัน"))
                    // Takes the space under the header so it centres there,
                    // rather than leaving the stack short enough to be centred
                    // as a whole.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(model.visible) { conflict in
                            ConflictCard(conflict: conflict,
                                         decide: { deciding = conflict },
                                         model: model)
                        }
                    }
                    .padding(16)
                }
            }
        }
        // Pinned to the top. `ContentUnavailableView` sizes to its content, so
        // with an empty list the stack was shorter than the window and got
        // centred — carrying the header and its divider down into the middle of
        // the screen, which only looked right once a card was there to fill it.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay { if model.isWorking { ProgressView().controlSize(.large) } }
        .sheet(item: $deciding) { conflict in
            DecisionSheet(conflict: conflict) { resolution, asPrecedent in
                Task { await model.decide(conflict, resolution, asPrecedent: asPrecedent) }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ความรู้ที่ขัดกัน").font(.headline)
                if model.openCount > 0 {
                    Text("\(model.openCount) รอตัดสิน")
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.orange)
                }
                Spacer()
                Toggle("แสดงที่ตัดสินแล้ว", isOn: $model.showsDecided)
                    .toggleStyle(.switch)
                    .accessibilityLabel("แสดงข้อขัดแย้งที่ตัดสินไปแล้วด้วย")
            }

            if let status = model.status {
                Label(status.message, systemImage: status.isError
                      ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(status.isError ? .orange : .secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
    }
}

// MARK: - card

private struct ConflictCard: View {
    let conflict: StoredConflict
    let decide: () -> Void
    /// For the history (§11.6, P3.7) — read and reversed from the card, since
    /// the card is where somebody is standing when they realise the decision
    /// was wrong.
    @Bindable var model: ConflictViewModel
    @State private var reopening = false
    @State private var reason = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(conflict.headline).font(.title3.weight(.semibold))
                Spacer()
                if let decision = conflict.decision {
                    Label(decision.decidedByHuman ? "คุณตัดสินแล้ว" : "ระบบตัดสินให้",
                          systemImage: decision.decidedByHuman ? "person.fill.checkmark" : "wand.and.stars")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                SideColumn(label: "ฝั่ง A", side: conflict.a,
                           reasons: conflict.weightAReasons, score: conflict.scoreA)
                SideColumn(label: "ฝั่ง B", side: conflict.b,
                           reasons: conflict.weightBReasons, score: conflict.scoreB)
            }

            if let decision = conflict.decision {
                DecisionSummary(decision: decision)
                decisionHistory
            } else {
                // Marked as a suggestion, in words, because §11.6 says the
                // system proposes and the human decides — and it names the side
                // and the reason, because "the heavier side" makes the user
                // rebuild the proposal from two numbers.
                Label(proposalText, systemImage: "lightbulb")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button("ตัดสินข้อขัดแย้งนี้", action: decide)
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("เปิดหน้าต่างตัดสินข้อขัดแย้ง \(conflict.headline)")
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    /// The history, and the way back out of a decision (P3.7).
    ///
    /// Reversing needs a reason and the button says so, because a reversal
    /// with no reason is indistinguishable from a mis-click to whoever meets
    /// it later. Nothing here deletes anything: reopening adds an entry.
    @ViewBuilder
    private var decisionHistory: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { model.historyFor == conflict.id },
            set: { expanded in
                Task {
                    if expanded { await model.loadHistory(of: conflict) }
                    else { model.closeHistory() }
                }
            })) {
            VStack(alignment: .leading, spacing: Space.row) {
                ForEach(Array(model.history.enumerated()), id: \.offset) { _, record in
                    HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                        Image(systemName: record.isReopening
                              ? "arrow.uturn.backward" : "checkmark.seal")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.isReopening
                                 ? "กลับคำตัดสิน — \(record.note)"
                                 : (record.note.isEmpty ? "ตัดสิน" : record.note))
                                .font(.callout)
                            Text(record.recordedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

                if reopening {
                    HStack(spacing: Space.row) {
                        TextField("ทำไมถึงกลับคำตัดสิน", text: $reason)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("เหตุผลที่กลับคำตัดสิน")
                        Button("ยืนยัน") {
                            Task {
                                await model.reopen(conflict, reason: reason)
                                reason = ""
                                reopening = false
                            }
                        }
                        .disabled(reason.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("ยกเลิก") { reopening = false; reason = "" }
                    }
                } else {
                    Button("กลับคำตัดสินนี้") { reopening = true }
                        .accessibilityHint("คำตัดสินเดิมจะยังอยู่ในประวัติ และต้องบอกเหตุผล")
                }
            }
            .padding(.top, Space.row)
        } label: {
            Text("ประวัติคำตัดสิน").font(.caption)
        }
    }

    /// Always ends by saying it is a proposal. A conflict filed before the
    /// proposal was stored has none to show, and says that rather than
    /// inventing one.
    private var proposalText: String {
        let suggestion: String? = switch conflict.proposal {
        case .preferA(let reason): "ระบบเสนอให้ใช้ฝั่ง A — \(reason)"
        case .preferB(let reason): "ระบบเสนอให้ใช้ฝั่ง B — \(reason)"
        case .bothInContext(let condition): "ระบบเสนอว่าถูกทั้งคู่ในบริบทต่างกัน — \(condition)"
        case .unresolved: "ระบบไม่เสนอฝั่งใด — น้ำหนักสองฝั่งใกล้กันเกินไป"
        case nil: nil
        }
        guard let suggestion else { return "ยังไม่มีข้อเสนอของระบบสำหรับข้อขัดแย้งนี้" }
        return suggestion + " (เป็นข้อเสนอ ไม่ใช่ข้อสรุป)"
    }
}

private struct SideColumn: View {
    let label: String
    let side: ConflictSide
    let reasons: String
    let score: Double

    /// Every string on this screen is Thai, so its dates are too. Left to the
    /// default the two halves disagree: a Thai system locale supplies the
    /// Buddhist era while the app's English localisation supplies the month
    /// name and the separator, and the card reads "11 Aug 2569 BE at 17:00".
    private static let accessed = Date.FormatStyle(date: .abbreviated, time: .shortened)
        .locale(Locale(identifier: "th_TH"))

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)

            // Verbatim. A summary here would be the agent deciding what the
            // sources said, which is the thing this screen exists to prevent.
            Text(side.text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 6) {
                TierChip(tier: side.provenance.tier)
                Text(side.provenance.title).lineLimit(1)
                if let year = side.provenance.year { Text("· \(String(year))") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text("เข้าถึงเมื่อ \(side.provenance.accessedAt.formatted(Self.accessed))")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Text(reasons)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(String(format: "น้ำหนักรวม %.2f", score))
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TierChip: View {
    let tier: SourceTier?
    var body: some View {
        Text(tier?.rawValue.uppercased() ?? "—")
            .font(.caption2.monospaced())
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.secondary.opacity(0.18), in: Capsule())
            .accessibilityLabel(tier.map { "ระดับความน่าเชื่อถือ \($0.rawValue.uppercased())" }
                                ?? "ไม่มีระดับความน่าเชื่อถือภายนอก")
    }
}

private struct DecisionSummary: View {
    let decision: ConflictDecision

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(text, systemImage: "checkmark.seal")
                .font(.callout)
            Text(scopeText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }

    private var text: String {
        switch decision.resolution {
        case .preferA(let reason): "ใช้ฝั่ง A — \(reason)"
        case .preferB(let reason): "ใช้ฝั่ง B — \(reason)"
        case .bothInContext(let condition): "ถูกทั้งคู่ในบริบทต่างกัน — \(condition)"
        case .unresolved: "ยังไม่ตัดสิน — เอกสารต้องระบุว่าเรื่องนี้ยังไม่ยุติ"
        }
    }

    private var scopeText: String {
        switch decision.scope {
        case .central: "ใช้เป็นคำตัดสินกลาง ทุกโปรเจกต์"
        case .project(let id): "ใช้เฉพาะโปรเจกต์ \(id.rawValue)"
        case .board(let runID): "ใช้เฉพาะการรันนี้ (\(runID))"
        case .policy: "ขอบเขตนโยบาย"
        }
    }
}

// MARK: - deciding

private struct DecisionSheet: View {
    let conflict: StoredConflict
    let save: (ConflictResolution, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var choice: Choice
    @State private var condition = ""
    @State private var reason = ""
    @State private var asPrecedent = false

    init(conflict: StoredConflict, save: @escaping (ConflictResolution, Bool) -> Void) {
        self.conflict = conflict
        self.save = save
        // Opens on what the system proposed. It used to open on A whatever the
        // card recommended, so the one-click answer was sometimes the opposite
        // of the evidence the user had just read.
        _choice = State(initialValue: Choice(proposal: conflict.proposal))

        // Its wording comes along with it, so the user edits the reasoning
        // rather than retyping it — and a proposed "both, in different
        // contexts" arrives with the condition it depends on.
        switch conflict.proposal {
        case .preferA(let reason), .preferB(let reason): _reason = State(initialValue: reason)
        case .bothInContext(let condition): _condition = State(initialValue: condition)
        case .unresolved, nil: break
        }
    }

    private enum Choice: String, CaseIterable, Identifiable {
        case a, b, both, unresolved
        var id: String { rawValue }

        init(proposal: ConflictResolution?) {
            switch proposal {
            case .preferA: self = .a
            case .preferB: self = .b
            case .bothInContext: self = .both
            // No proposal is not a recommendation to pick A — it is the system
            // having nothing to say, and the sheet says that too.
            case .unresolved, nil: self = .unresolved
            }
        }

        var label: String {
            switch self {
            case .a: "ใช้ฝั่ง A"
            case .b: "ใช้ฝั่ง B"
            case .both: "ถูกทั้งคู่ ในบริบทต่างกัน"
            case .unresolved: "ยังไม่ตัดสิน"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(conflict.question).font(.headline)

            Picker("คำตัดสิน", selection: $choice) {
                ForEach(Choice.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .accessibilityLabel("เลือกคำตัดสิน")

            switch choice {
            case .both:
                // Required: "it depends" with nothing after it settles nothing.
                TextField("ระบุเงื่อนไข เช่น ผู้ใหญ่ใช้ค่าหนึ่ง เด็กใช้อีกค่า", text: $condition)
                    .textFieldStyle(.roundedBorder)
            case .unresolved:
                Text("เอกสารที่อ้างเรื่องนี้จะถูกเขียนให้ระบุว่ายังไม่ยุติ")
                    .font(.caption).foregroundStyle(.secondary)
            case .a, .b:
                TextField("เหตุผล (ไม่บังคับ)", text: $reason)
                    .textFieldStyle(.roundedBorder)
            }

            Toggle("ใช้เป็นคำตัดสินกลางสำหรับทุกโปรเจกต์", isOn: $asPrecedent)
                .accessibilityHint("ถ้าปิดไว้ คำตัดสินจะใช้เฉพาะขอบเขตที่กำลังดูอยู่")

            HStack {
                Spacer()
                Button("ยกเลิก") { dismiss() }
                Button("บันทึก") {
                    save(resolution, asPrecedent)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(choice == .both && condition.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 520)
    }

    private var resolution: ConflictResolution {
        switch choice {
        case .a: .preferA(reason: reason.isEmpty ? "ผู้ใช้เลือก" : reason)
        case .b: .preferB(reason: reason.isEmpty ? "ผู้ใช้เลือก" : reason)
        case .both: .bothInContext(condition: condition)
        case .unresolved: .unresolved
        }
    }
}
