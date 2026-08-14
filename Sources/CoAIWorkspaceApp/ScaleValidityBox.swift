import SwiftUI
import Instruments

// ─────────────────────────────────────────────────────────────
// Reliability and construct validity, on screen (ARCHITECTURE §20.4, P11.3).
//
// The arithmetic passed its tests months before anything could reach it, which
// is this project's oldest failure shape — a capability that is built, tested,
// and connected to nothing (v1's MCP client, ConflictDetector, nine tools at
// once). This is the screen that makes α, ω, ICC and the factor solution
// something a researcher can get to.
//
// It reports and refuses nothing. EFA runs after fieldwork, so a gate here would
// be a gate on data that has already been collected — the useful thing it can do
// is put the number, the warning and the item that caused it in the same place,
// so what goes in chapter 3 is what the data actually says.
// ─────────────────────────────────────────────────────────────

struct ScaleValidityBox: View {
    @Bindable var model: InstrumentsViewModel
    let instrument: Instrument

    var body: some View {
        GroupBox("ความเที่ยงและความตรงเชิงโครงสร้าง (§20.4)") {
            VStack(alignment: .leading, spacing: 10) {
                controls
                if let analysis = model.scaleReport {
                    if model.scaleReportIsStale {
                        // The round is still open and answers have arrived since.
                        // Saying so beats both alternatives: dropping the table
                        // throws away work somebody waited for, and redrawing it
                        // unmarked would put these numbers beside answers they
                        // were not computed from.
                        Label("มีคำตอบเปลี่ยนไปหลังจากคำนวณครั้งนี้ — ตัวเลขข้างล่างมาจากผู้ตอบ "
                              + "\(analysis.respondents) คนที่คำนวณไว้ กดคำนวณอีกครั้งเพื่อรวมของใหม่",
                              systemImage: "clock.arrow.circlepath")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    sample(analysis)
                    if !analysis.subscales.isEmpty { reliability(analysis) }
                    if let solution = analysis.solution {
                        adequacy(solution)
                        factors(solution)
                        if let fit = analysis.fit { constructFit(fit) }
                        warnings(solution)
                    } else if let refusal = analysis.refusal {
                        Label(refusal, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !analysis.skippedItems.isEmpty { skipped(analysis) }
                } else {
                    Text("คำนวณจากคำตอบที่เก็บได้จริงในเวอร์ชันนี้ — α และ ω รายมาตรวัด "
                         + "แล้ววิเคราะห์องค์ประกอบเชิงสำรวจกับข้อทุกข้อรวมกัน")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - controls

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 10) {
            Button("คำนวณความเที่ยงและองค์ประกอบ") {
                Task { await model.analyseScale() }
            }
            .disabled(model.isAnalysingScale || model.responseRows.isEmpty)

            if model.isAnalysingScale {
                ProgressView().controlSize(.small)
                Text("กำลังคำนวณ — parallel analysis สุ่มข้อมูลเทียบ 100 รอบ")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .controlSize(.small)

        // The retention rule is offered rather than chosen, and both answers stay
        // visible below — a solution that changes with the rule is a finding, not
        // a setting.
        if model.scaleReport?.solution != nil {
            Picker("เกณฑ์จำนวนองค์ประกอบ", selection: Binding(
                get: { RuleChoice(model.retentionRule) },
                set: { choice in Task { await model.analyseScale(rule: choice.rule) } })) {
                ForEach(RuleChoice.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .accessibilityLabel("เกณฑ์ที่ใช้ตัดสินจำนวนองค์ประกอบ")
        }
    }

    enum RuleChoice: String, CaseIterable, Identifiable {
        case parallel, kaiser
        var id: String { rawValue }

        init(_ rule: RetentionRule) {
            self = rule == .kaiser ? .kaiser : .parallel
        }

        var rule: RetentionRule {
            switch self {
            case .parallel: .parallelAnalysis
            case .kaiser: .kaiser
            }
        }

        var label: String {
            switch self {
            case .parallel: "parallel analysis"
            case .kaiser: "Kaiser (eigenvalue > 1)"
            }
        }
    }

    // MARK: - what was analysed

    @ViewBuilder
    private func sample(_ analysis: ScaleReport) -> some View {
        Text(sampleLine(analysis)).font(.caption).foregroundStyle(.secondary)
    }

    private func sampleLine(_ analysis: ScaleReport) -> String {
        var parts = ["ผู้ตอบที่นำมาคำนวณ \(analysis.respondents) คน",
                     "ข้อที่ให้คะแนนได้ \(analysis.scoredItemIDs.count) ข้อ"]
        if analysis.droppedRespondents > 0 {
            // Said rather than absorbed: listwise deletion that nobody mentions
            // is how a sample of 120 becomes 78 between two paragraphs.
            parts.append("ตัดออก \(analysis.droppedRespondents) คนที่ตอบไม่ครบทุกข้อ")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - α and ω

    @ViewBuilder
    private func reliability(_ analysis: ScaleReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ความเที่ยงรายมาตรวัด").font(.callout).bold()
            ForEach(analysis.subscales) { subscale in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 8) {
                        Text(subscale.name).font(.callout)
                        Text("\(subscale.itemIDs.count) ข้อ")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        if let alpha = subscale.alpha {
                            Text(String(format: "α %.3f", alpha.alpha))
                                .font(.callout)
                                .foregroundStyle(alpha.passes ? Color.green : Color.orange)
                        } else {
                            Text("α คำนวณไม่ได้").font(.caption).foregroundStyle(.secondary)
                        }
                        if let omega = subscale.omega {
                            Text(String(format: "ω %.3f", omega.omega))
                                .font(.callout)
                                .foregroundStyle(omega.passes ? Color.green : Color.orange)
                        }
                    }
                    if let weakest = subscale.weakestItem {
                        Text(String(format: "ข้อ %@ สัมพันธ์กับข้ออื่นในมาตรวัดนี้เพียง %.2f — ",
                                    prompt(weakest.item), weakest.correlation)
                             + "ต่ำกว่า .30 ซึ่งเป็นเกณฑ์ที่มักใช้ตัดสินว่าข้อนี้วัดคนละเรื่องกับข้ออื่น")
                            .font(.caption2).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if subscale.alpha != nil && subscale.omega == nil {
                        Text("ω ต้องการอย่างน้อย 3 ข้อและผู้ตอบมากกว่าจำนวนข้อ — "
                             + "มาตรวัดนี้ยังไม่ถึง จึงมีแต่ α")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Text("α ตั้งอยู่บนสมมติฐานว่าทุกข้อดีเท่ากัน ซึ่งแทบไม่จริง · ω ไม่ต้องใช้สมมติฐานนั้น "
                 + "จึงรายงานคู่กัน และถ้าสองค่าต่างกันมากแปลว่ามีข้อที่วัดได้ดีกว่าข้ออื่นชัดเจน")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - is there anything to factor

    @ViewBuilder
    private func adequacy(_ solution: FactorSolution) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ข้อมูลเหมาะกับการวิเคราะห์องค์ประกอบไหม").font(.callout).bold()
            Text(solution.adequacy.summary)
                .font(.caption)
                .foregroundStyle(solution.adequacy.isFactorable ? .secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
            Text("ค่าลักษณะเฉพาะ: "
                 + solution.eigenvalues.map { String(format: "%.2f", $0) }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - the loading table

    @ViewBuilder
    private func factors(_ solution: FactorSolution) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(solution.summary).font(.callout).bold()
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text("ข้อ").font(.caption2).foregroundStyle(.secondary)
                    .frame(width: 220, alignment: .leading)
                ForEach(0..<solution.retained, id: \.self) { factor in
                    Text(String(format: "F%d (%.0f%%)", factor + 1,
                                solution.varianceExplained[factor] * 100))
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(width: 78, alignment: .trailing)
                }
                Text("h²").font(.caption2).foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .trailing)
            }
            ForEach(solution.loadings) { row in
                HStack(spacing: 8) {
                    Text(prompt(row.itemID)).font(.caption)
                        .frame(width: 220, alignment: .leading)
                        .lineLimit(2)
                    ForEach(row.loadings.indices, id: \.self) { factor in
                        // Salient loadings are the ones a methods section quotes;
                        // the rest are printed faintly rather than blanked out,
                        // because a table with holes in it hides cross-loadings.
                        Text(String(format: "%.3f", row.loadings[factor]))
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(abs(row.loadings[factor]) >= FactorLoading.salient
                                             ? Color.primary : Color.secondary.opacity(0.55))
                            .frame(width: 78, alignment: .trailing)
                    }
                    Text(String(format: "%.2f", row.communality))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                }
            }
            Text("ตัวหนา = |น้ำหนัก| ≥ \(String(format: "%.2f", FactorLoading.salient)) "
                 + "· h² = ส่วนของความแปรปรวนของข้อนั้นที่องค์ประกอบอธิบายได้ "
                 + "· หมุนแกนแบบ varimax หลังสกัดด้วย principal axis factoring "
                 + "· ข้อที่ถามกลับด้านจะได้น้ำหนักติดลบ ซึ่งเป็นวิธีสังเกตว่ายังไม่ได้กลับคะแนน")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - declared against found

    @ViewBuilder
    private func constructFit(_ fit: ConstructFit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ข้อลงตรงกับ construct ที่ประกาศไว้ไหม").font(.callout).bold()
            ForEach(fit.constructs) { row in
                HStack(spacing: 6) {
                    Image(systemName: row.isClean ? "checkmark.circle" : "exclamationmark.circle")
                        .foregroundStyle(row.isClean ? Color.green : Color.orange)
                    Text(constructName(row.constructID)).font(.caption)
                    Text(row.factor.map { "→ F\($0 + 1) · \(row.itemsOnFactor)/\(row.itemsDeclared) ข้อ" }
                         ?? "ไม่มีองค์ประกอบไหนที่ข้อของ construct นี้เกาะร่วมกัน")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            if !fit.misplaced.isEmpty {
                Text("ข้อที่ลงคนละองค์ประกอบกับที่ประกาศไว้: "
                     + fit.misplaced.map { prompt($0) }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(fit.mergedConstructs.enumerated()), id: \.offset) { _, merged in
                Text("ข้อมูลแยก construct เหล่านี้ออกจากกันไม่ได้: "
                     + merged.map { constructName($0) }.joined(separator: " + "))
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - what has to be said beside the table

    @ViewBuilder
    private func warnings(_ solution: FactorSolution) -> some View {
        if !solution.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(solution.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func skipped(_ analysis: ScaleReport) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ข้อที่ไม่ได้นำมาคำนวณ").font(.caption).bold().foregroundStyle(.secondary)
            ForEach(analysis.skippedItems) { item in
                Text("• \(item.prompt) — \(item.reason)")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - names

    private func prompt(_ itemID: String) -> String {
        instrument.items.first { $0.id == itemID }?.prompt.thai ?? itemID
    }

    private func constructName(_ constructID: String) -> String {
        instrument.constructs.first { $0.id == constructID }?.name.thai ?? constructID
    }
}
