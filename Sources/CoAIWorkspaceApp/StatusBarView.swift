import SwiftUI
import AgentKit
import ProjectKit

// ─────────────────────────────────────────────────────────────
// The status bar (ARCHITECTURE §19.2.3, P10.15 second half).
//
// §19.2.3's claim is that this is a dashboard, not a row of labels: every cell
// opens with where its number came from and a button that does something. The
// reason it is worth building as one strip rather than six widgets is the thing
// driving the screen kept showing — the facts that decide what to do next
// (which gate, which frame, what stopped) were always one screen away from
// whatever was being worked on.
//
// Two rules the cells follow, both learned the hard way:
//
//  • **A number nobody measured is not shown as a number.** An unread tolerance
//    says "ยังไม่ได้วัด"; an empty popover says nothing was recorded rather than
//    showing zeros that read as "checked and fine".
//  • **Every button writes to the register.** Not by convention here — the
//    actions are `StatusAction` values and `ProjectService.perform` is what runs
//    them, so a one-click dashboard cannot become a place decisions vanish.
// ─────────────────────────────────────────────────────────────

struct StatusBarView: View {
    @Bindable var model: ProjectsViewModel
    /// Jumping to the cause of an unmet gate condition (§19.2.3). Passed in
    /// because this strip does not know what screens exist.
    let openPlan: () -> Void

    @State private var open: Cell?
    @State private var decision = ""
    @State private var limitDraft = ""
    @State private var reason = ""

    enum Cell: String, Identifiable {
        case stage, time, cost, quality, scope, exception
        var id: String { rawValue }
    }

    var body: some View {
        if let project = model.selected {
            HStack(spacing: 0) {
                cell(.stage, label: "ขั้น", value: project.stage.label,
                     alert: model.gate?.passed == true ? nil : "•")
                divider
                cell(.time, label: "เวลา", value: elapsedText,
                     alert: breached(.time) ? "!" : nil)
                divider
                cell(.cost, label: "งบเดือนนี้", value: money(model.spendTotal),
                     alert: breached(.cost) ? "!" : nil)
                divider
                cell(.quality, label: "rework", value: model.rework.isEmpty
                     ? "ไม่มี" : "\(model.rework.count) งาน",
                     alert: breached(.quality) ? "!" : nil)
                divider
                cell(.scope, label: "ขอบเขต", value: model.drift?.summary ?? "ยังไม่มี baseline",
                     alert: model.drift?.isEmpty == false ? "•" : nil)
                if !model.openExceptions.isEmpty {
                    divider
                    cell(.exception, label: "หยุดรอคุณ",
                         value: "\(model.openExceptions.count) เรื่อง", alert: "!")
                }
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private var divider: some View {
        Divider().frame(height: 18)
    }

    @ViewBuilder
    private func cell(_ which: Cell, label: String, value: String, alert: String?) -> some View {
        Button {
            open = which
            seedDrafts(for: which)
        } label: {
            HStack(spacing: 5) {
                Text(label).foregroundStyle(.secondary)
                Text(value).fontWeight(.medium)
                if let alert {
                    Text(alert)
                        .foregroundStyle(alert == "!" ? Color.red : Color.orange)
                        .fontWeight(.bold)
                }
            }
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) \(value) — กดเพื่อดูที่มาและสิ่งที่ทำได้")
        .popover(isPresented: Binding(get: { open == which },
                                      set: { if !$0 { open = nil } })) {
            popover(which)
                .padding(14)
                .frame(width: 380)
        }
    }

    // MARK: - what each cell opens with

    @ViewBuilder
    private func popover(_ which: Cell) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch which {
            case .stage: stagePopover
            case .time: timePopover
            case .cost: costPopover
            case .quality: qualityPopover
            case .scope: scopePopover
            case .exception: exceptionPopover
            }
        }
    }

    @ViewBuilder
    private var stagePopover: some View {
        if let gate = model.gate {
            Text("\(gate.gate): \(gate.from.label) → \(gate.to.label)").font(.headline)
            ForEach(Array(gate.conditions.enumerated()), id: \.offset) { _, condition in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: condition.satisfied
                          ? (condition.vacuous ? "circle.dotted" : "checkmark.circle.fill")
                          : "circle")
                        .foregroundStyle(condition.satisfied
                                         ? (condition.vacuous ? Color.secondary : Color.green)
                                         : Color.orange)
                    Text(condition.text).font(.callout)
                }
            }
            // §19.2.3: an unmet condition is a place to go, not a fact to read.
            if !gate.passed {
                Button("ไปที่แผนเพื่อแก้ข้อที่ค้าง") {
                    open = nil
                    openPlan()
                }
                .controlSize(.small)
            }
            Text("วงกลมจุดประ = ยังไม่มีอะไรให้ตรวจ ไม่ใช่ตรวจแล้วผ่าน")
                .font(.caption2).foregroundStyle(.secondary)
        } else {
            Text("โครงการปิดแล้ว — ไม่มีประตูถัดไป").font(.callout)
        }
    }

    @ViewBuilder
    private var timePopover: some View {
        Text("เวลาที่ใช้ไป").font(.headline)
        Text("รวมจาก span ที่ผูกกับใบงานของโครงการนี้: \(elapsedText)")
            .font(.callout)
        if let forecast = model.forecast {
            // The band names its own population, and the label is read off
            // `basis` rather than written here. It has been wrong twice —
            // "งานชนิดเดียวกัน" over a band of tool calls, then over a band of
            // chat turns — both times because the sentence lived at the screen
            // and the data lived three modules away.
            Text("\(basisHeadline(forecast.basis)): p50 \(minutes(forecast.p50)) "
                 + "· p90 \(minutes(forecast.p90)) "
                 + "(จาก \(forecast.sampleCount) \(forecast.unit))")
                .font(.callout)
            switch forecast.basis {
            case .assignments:
                Text("ข้ามโปรเจกต์ — p90 ที่คิดจากโปรเจกต์ตัวเองไม่ได้บอกอะไร · นับทั้งงาน ตั้งแต่มอบหมายจนผ่านการตรวจ **รวมรอบที่ต้องแก้** เพราะแผนที่คิดเฉพาะรอบที่ผ่านตั้งแต่แรกคือแผนที่ไม่มีใครทำทัน")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .turns:
                // One literal: SwiftUI parses markdown only in a string literal,
                // and `"a" + "b"` prints its own asterisks (check.sh's rule,
                // which has now caught me twice).
                Text("ข้ามโปรเจกต์ — p90 ที่คิดจากโปรเจกต์ตัวเองไม่ได้บอกอะไร · **ยังไม่ใช่ประวัติของงานชนิดเดียวกัน** เพราะงานที่เสร็จแล้วของชนิดส่งมอบนี้ยังไม่ถึงสามชิ้น เทิร์นเป็นหน่วยที่เล็กกว่างาน แถบนี้จึงต่ำกว่าความจริง")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("ยังไม่มีงานที่เสร็จแล้วพอจะเทียบ — จึงยังไม่มีแถบ p50–p90")
                .font(.callout).foregroundStyle(.secondary)
        }
        widenControl(.time)
    }

    @ViewBuilder
    private var costPopover: some View {
        Text("ค่าใช้จ่ายเดือนนี้ \(money(model.spendTotal))").font(.headline)
        if model.spendByRole.isEmpty {
            Text("ยังไม่มีการใช้จ่ายที่บันทึกไว้ในเดือนนี้")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            Text("แยกตามบทบาท").font(.caption).foregroundStyle(.secondary)
            ForEach(model.spendByRole) { slice in
                barRow(slice.key, amount: money(slice.amount),
                       fraction: model.spendTotal > 0 ? slice.amount / model.spendTotal : 0)
            }
            Text("แยกตามโมเดล").font(.caption).foregroundStyle(.secondary)
            ForEach(model.spendByModel) { slice in
                barRow(slice.key, amount: money(slice.amount),
                       fraction: model.spendTotal > 0 ? slice.amount / model.spendTotal : 0)
            }
        }
        Divider()
        // The honest half of "แยกตามทูล": money is charged per model call, so
        // splitting a bill by tool would be inventing the split. What each tool
        // *did* is recorded, so that is what this shows.
        Text("ทูลที่ถูกเรียก (จำนวนครั้ง — ไม่ใช่ค่าใช้จ่าย: เงินคิดต่อการเรียกโมเดล ไม่ใช่ต่อทูล)")
            .font(.caption).foregroundStyle(.secondary)
        if model.toolActivity.isEmpty {
            Text("ยังไม่มี tool call ในโปรเจกต์นี้").font(.callout).foregroundStyle(.secondary)
        } else {
            ForEach(model.toolActivity.prefix(6)) { slice in
                Text("\(slice.tool) — \(slice.calls) ครั้ง · \(minutes(slice.seconds))")
                    .font(.callout)
            }
        }
        widenControl(.cost)
    }

    @ViewBuilder
    private var qualityPopover: some View {
        Text("งานที่ต้องทำซ้ำ").font(.headline)
        if model.rework.isEmpty {
            Text("ยังไม่มีงานที่ถูกตีกลับ").font(.callout).foregroundStyle(.secondary)
        } else {
            ForEach(model.rework) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(row.goal) · \(row.role) · \(row.attempts) รอบ")
                        .font(.callout)
                    // Every round's reason, not just the last: §19.2.3 asks for
                    // "เหตุผลจาก QA ทุกรอบ", and the pattern across rounds is
                    // what tells a person whether to loosen the DoD or the model.
                    ForEach(Array(row.findings.enumerated()), id: \.offset) { _, finding in
                        Text("• \(finding)").font(.caption).foregroundStyle(.secondary)
                    }
                    if row.needsHuman {
                        Text("ยกให้คนแล้ว").font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
        }
        widenControl(.quality)
        Text("ผ่อนเกณฑ์เสร็จ (DoD) ทำที่หน้าแผน — มันคือการแก้สัญญา ไม่ใช่การแก้กรอบ")
            .font(.caption2).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var scopePopover: some View {
        Text("ส่วนต่างจากแผนที่ตกลงไว้").font(.headline)
        if let drift = model.drift, !drift.isEmpty {
            ForEach(drift.added, id: \.id) { package in
                Text("+ \(package.title)").font(.callout).foregroundStyle(.orange)
            }
            ForEach(drift.removed, id: \.id) { package in
                Text("− \(package.title)").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(drift.changed, id: \.id) { package in
                Text("แก้ \(package.title)").font(.callout)
            }
            if drift.scopeChanged {
                Text("ข้อความขอบเขตเปลี่ยนจาก baseline").font(.callout)
            }
            Button("เปิดคำขอเปลี่ยนแปลงจากส่วนต่างนี้") {
                let action = StatusAction.requestChange(
                    title: "ปรับแผนให้ตรงกับที่ทำอยู่: \(drift.summary)",
                    scopeImpact: drift.summary,
                    timeImpact: "ยังประเมินไม่ได้จากแถบสถานะ",
                    costImpact: "ยังประเมินไม่ได้จากแถบสถานะ")
                open = nil
                Task { await model.perform(action) }
            }
            .controlSize(.small)
        } else if model.drift == nil {
            Text("ยังไม่มี baseline — แผนยังไม่ได้ถูก freeze เป็นข้อตกลง")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            Text("แผนวันนี้ตรงกับ baseline ล่าสุด").font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var exceptionPopover: some View {
        ForEach(model.openExceptions) { report in
            VStack(alignment: .leading, spacing: 6) {
                Text(report.message)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField("คำตัดสินของคุณ", text: $decision)
                        .textFieldStyle(.roundedBorder)
                    // The Done-when's first clause: decided here, not on another
                    // screen. The decision text is what the report asked for in
                    // its "ต้องการจากคุณ" field.
                    Button("ตัดสินตรงนี้") {
                        let text = decision
                        decision = ""
                        open = nil
                        Task { await model.perform(.decideException(report, decision: text)) }
                    }
                    .disabled(decision.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - the one control three popovers share

    @ViewBuilder
    private func widenControl(_ dimension: ToleranceDimension) -> some View {
        let status = model.tolerances.first { $0.dimension == dimension }
        Divider()
        VStack(alignment: .leading, spacing: 4) {
            Text("กรอบ\(dimension.label) ตอนนี้ \(number(status?.limit ?? 0)) \(dimension.unit)")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("กรอบใหม่", text: $limitDraft)
                    .textFieldStyle(.roundedBorder).frame(width: 90)
                TextField("เหตุผล", text: $reason)
                    .textFieldStyle(.roundedBorder)
                Button("ขยายกรอบ") {
                    guard let limit = Double(limitDraft.trimmingCharacters(in: .whitespaces))
                    else { return }
                    let text = reason
                    open = nil
                    Task {
                        await model.perform(.widenTolerance(dimension, to: limit, reason: text))
                    }
                }
                .disabled(Double(limitDraft.trimmingCharacters(in: .whitespaces)) == nil
                          || reason.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
            Text("บันทึกเป็นการตัดสินใจพร้อมเหตุผลทุกครั้ง — และถ้าผ่าน G2 แล้ว จะเปิดคำขอเปลี่ยนแปลงให้ด้วย")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func barRow(_ key: String, amount: String, fraction: Double) -> some View {
        HStack(spacing: 6) {
            Text(key).font(.callout).frame(width: 130, alignment: .leading).lineLimit(1)
            ProgressView(value: min(max(fraction, 0), 1)).frame(width: 90)
            Text(amount).font(.system(.caption, design: .monospaced))
        }
    }

    // MARK: - formatting

    private func seedDrafts(for which: Cell) {
        reason = ""
        decision = ""
        let dimension: ToleranceDimension? = switch which {
        case .time: .time
        case .cost: .cost
        case .quality: .quality
        default: nil
        }
        limitDraft = dimension
            .flatMap { target in model.tolerances.first { $0.dimension == target } }
            .map { number($0.limit) } ?? ""
    }

    private func breached(_ dimension: ToleranceDimension) -> Bool {
        model.tolerances.first { $0.dimension == dimension }?.breached == true
    }

    private var elapsedText: String {
        let total = model.elapsed.values.reduce(0, +)
        return total > 0 ? minutes(total) : "ยังไม่ได้วัด"
    }

    /// Names the population in the reader's words. Exhaustive with no
    /// `default:` — a basis added later must be given a sentence rather than
    /// quietly inheriting somebody else's.
    private func basisHeadline(_ basis: ScheduleEstimate.Basis) -> String {
        switch basis {
        case .assignments(let kind): "งานที่เสร็จแล้วชนิด “\(kind)”"
        case .turns: "เทิร์นที่เสร็จแล้วของบทบาทที่โปรเจกต์นี้ใช้"
        }
    }

    private func minutes(_ seconds: TimeInterval) -> String {
        seconds >= 3_600
            ? String(format: "%.1f ชม.", seconds / 3_600)
            : "\(Int((seconds / 60).rounded())) นาที"
    }

    private func money(_ amount: Double) -> String {
        amount == 0 ? "฿0" : String(format: "฿%.2f", amount)
    }

    private func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}
