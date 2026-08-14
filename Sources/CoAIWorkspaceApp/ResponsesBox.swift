import SwiftUI
import Instruments
import OLTP

// ─────────────────────────────────────────────────────────────
// What came back (ARCHITECTURE §19.17, P11.6c/P11.7).
//
// §19.17 puts it exactly: this **works like a sheet and is not one**. A cell can
// be changed, and changing it does not write over what arrived — it records a
// correction with a reason and a name against it, and the cell then shows the new
// value with a mark and the old one behind it.
//
// That is the whole design, and it is not pedantry. A spreadsheet of research
// data that can be edited in place is a spreadsheet nobody can prove was not
// edited, and "nobody can prove it was not edited" is indistinguishable, at a
// defence, from "it was edited".
// ─────────────────────────────────────────────────────────────

struct ResponsesBox: View {
    @Bindable var model: InstrumentsViewModel
    let instrument: Instrument

    /// Which cell is open for correction. One at a time: a grid where several
    /// edits are in flight is a grid where somebody loses one.
    @State private var editing: Cell?
    @State private var draft = ""
    @State private var reason = ""
    @State private var person = ""

    struct Cell: Identifiable, Equatable {
        let submissionID: String
        let itemID: String
        var id: String { "\(submissionID)|\(itemID)" }
    }

    private var columns: [Item] { instrument.ordered }

    var body: some View {
        GroupBox("คำตอบที่เก็บได้ (เวอร์ชัน \(instrument.version))") {
            VStack(alignment: .leading, spacing: 8) {
                rounds
                if model.responseRows.isEmpty {
                    Text("ยังไม่มีคำตอบสำหรับเวอร์ชันนี้ — เปิดฟอร์มในวงแลนแล้วส่งลิงก์ให้ผู้ตอบ")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    table
                    HStack {
                        Button("ส่งเข้าฐานข้อมูลวิเคราะห์") { Task { await model.materialize() } }
                        if let done = model.materialized {
                            Text("ตาราง \(done.table) · \(done.rows) แถว"
                                 + (done.corrections > 0 ? " · \(done.corrections) ค่าที่ถูกแก้" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .controlSize(.small)
                    Text("คำตอบดิบอยู่ใน SQLite ของโปรเจกต์ · กดปุ่มนี้เพื่อคัดลอกเข้า DuckDB "
                         + "แล้วเปิดในสมุดงานได้ — แอปเป็นฝ่ายดึง เซิร์ฟเวอร์แตะ DuckDB ไม่ได้เลย (§19.17) "
                         + "· ค่าที่ถูกแก้จะไปในรูปค่าที่แก้แล้ว พร้อมคอลัมน์ `was_corrected` บอกว่าแก้")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("ตารางนี้ทำงานเหมือน Sheet แต่ไม่ใช่ Sheet — แก้ค่าหนึ่งช่องจะถูกเก็บเป็น "
                         + "“บันทึกการแก้ไข” (ค่าเดิม · ค่าใหม่ · เหตุผล · ใครแก้ · เมื่อไร) "
                         + "ไม่ใช่การเขียนทับ (§19.17)")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - rounds

    @ViewBuilder
    private var rounds: some View {
        if model.rounds.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.rounds) { round in
                    HStack(spacing: 6) {
                        Image(systemName: round.isOpen ? "dot.radiowaves.left.and.right" : "checkmark.seal")
                            .foregroundStyle(round.isOpen ? Color.green : Color.secondary)
                        // The dates are the claim a methods section makes, so they
                        // are shown rather than summarised.
                        // The date format puts a comma before the time, so the
                        // count needs its own separator or the line reads
                        // "…at 10:58, 0 ชุด" as though the count were part of
                        // the timestamp.
                        Text(round.isOpen
                             ? "รอบที่เปิดอยู่ · เริ่ม \(round.openedAt.formatted(date: .abbreviated, time: .shortened))"
                             : "ปิดแล้ว · \(round.openedAt.formatted(date: .abbreviated, time: .omitted))"
                                + " – \(round.closedAt?.formatted(date: .abbreviated, time: .shortened) ?? "")")
                            .font(.caption)
                        Text("· \(round.submissions) ชุด").font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: - the grid

    /// Both axes, and driving the screen with forty answers in it is what showed
    /// why. A horizontal-only `ScrollView` under a `maxHeight` does not clip what
    /// overflows downwards: the rows carried on past the box and were drawn over
    /// the captions beneath it. With one test submission — which is what every
    /// round before this had — the content fit, so nothing ever looked wrong.
    private var table: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    header("เมื่อไร", width: 130)
                    ForEach(columns) { item in
                        header(item.prompt.thai, width: 150)
                    }
                }
                Divider()
                ForEach(model.responseRows) { row in
                    HStack(spacing: 0) {
                        Text(row.submission.receivedAt.formatted(date: .abbreviated,
                                                                 time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(width: 130, alignment: .leading)
                            .padding(.vertical, 3)
                        ForEach(columns) { item in
                            cell(row: row, item: item)
                        }
                    }
                    Divider()
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 260)
    }

    private func header(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.caption).bold()
            .lineLimit(1)
            .frame(width: width, alignment: .leading)
            .padding(.vertical, 3)
    }

    @ViewBuilder
    private func cell(row: InstrumentsViewModel.ResponseRow, item: Item) -> some View {
        let answer = row.answers[item.id]
        let cell = Cell(submissionID: row.submission.id, itemID: item.id)
        Button {
            draft = answer?.text ?? ""
            reason = ""
            editing = cell
        } label: {
            HStack(spacing: 3) {
                Text(answer?.text ?? "—")
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(answer == nil ? Color.secondary : Color.primary)
                if answer?.wasCorrected == true {
                    // The mark §19.17 asks for. Not a colour alone: a mark that is
                    // only a colour is invisible to a screen reader and to the
                    // people this project keeps writing accessibility rules for.
                    Image(systemName: "pencil.circle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 150, alignment: .leading)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(answer == nil)
        .accessibilityLabel(label(for: answer, item: item))
        .accessibilityHint("เปิดหน้าต่างแก้ค่าคำตอบนี้")
        .popover(isPresented: Binding(get: { editing == cell },
                                      set: { if !$0 { editing = nil } })) {
            correctionForm(row: row, item: item, answer: answer)
        }
    }

    private func label(for answer: ResolvedAnswer?, item: Item) -> String {
        guard let answer else { return "\(item.prompt.thai): ไม่มีคำตอบ" }
        guard let correction = answer.corrected else {
            return "\(item.prompt.thai): \(answer.text)"
        }
        return "\(item.prompt.thai): \(answer.text) — แก้จาก \(correction.previousText) "
            + "โดย \(correction.correctedBy) เพราะ \(correction.reason)"
    }

    @ViewBuilder
    private func correctionForm(row: InstrumentsViewModel.ResponseRow, item: Item,
                                answer: ResolvedAnswer?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.prompt.thai).font(.headline)
            if let correction = answer?.corrected {
                // The original, still readable — which is the point of keeping it.
                VStack(alignment: .leading, spacing: 2) {
                    Text("ค่าเดิมที่ผู้ตอบส่งมา: \(correction.previousText)")
                    Text("แก้เป็น \(correction.newText) โดย \(correction.correctedBy) · "
                         + correction.correctedAt.formatted(date: .abbreviated, time: .shortened))
                    Text("เหตุผล: \(correction.reason)")
                }
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            TextField("ค่าใหม่", text: $draft)
                .textFieldStyle(.roundedBorder)
            TextField("เหตุผลที่แก้", text: $reason)
                .textFieldStyle(.roundedBorder)
            TextField("ชื่อผู้แก้", text: $person)
                .textFieldStyle(.roundedBorder)
            Text("ทั้งเหตุผลและชื่อผู้แก้เป็นสิ่งที่ต้องมี — การแก้ที่ไม่มีทั้งสองอย่าง "
                 + "แยกไม่ออกจากการแก้ที่หวังว่าไม่มีใครสังเกต")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("ยกเลิก") { editing = nil }
                Button("บันทึกการแก้ไข") {
                    let previous = answer?.text ?? ""
                    let newText = draft, why = reason, who = person
                    editing = nil
                    Task {
                        await model.correct(submission: row.submission.id, item: item.id,
                                            previous: previous, to: newText,
                                            reason: why, by: who)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty
                          || reason.trimmingCharacters(in: .whitespaces).isEmpty
                          || person.trimmingCharacters(in: .whitespaces).isEmpty
                          || draft == answer?.text)
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}
