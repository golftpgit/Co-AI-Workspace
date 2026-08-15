import SwiftUI
import Config
import AgentKit

// ─────────────────────────────────────────────────────────────
// Endpoints and budget (ARCHITECTURE §9.3/§9.5, P5.5–P5.7).
//
// Three things, in the order they matter: what this machine can reach, what it
// is allowed to spend, and what it has spent. The last one is not a report
// filed elsewhere — a budget nobody can see is one nobody trusts, and the
// first thing anyone asks when a number surprises them is "on what?".
// ─────────────────────────────────────────────────────────────

struct EndpointsView: View {
    @Bindable var model: EndpointsViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    endpointList
                    budgetSection
                    if model.hasMeteredEndpoint { spendSection }
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $model.editing) { editor }
        .task { await model.refreshSpending() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("โมเดลระยะไกล (Tier 1)").font(.headline)
            Button("เพิ่ม endpoint") { model.beginAdding() }
            Button("ตรวจใหม่ทั้งหมด") { Task { await model.recheckAll() } }
            Spacer()
            if let status = model.status {
                Text(status.message)
                    .font(.caption)
                    .foregroundStyle(status.isError ? .red : .secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 420, alignment: .trailing)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var endpointList: some View {
        if model.registry.endpoints.isEmpty {
            ContentUnavailableView(
                "ยังไม่มี endpoint",
                systemImage: "network",
                description: Text("Tier 0.5 ทำงานได้อยู่แล้วโดยไม่ต้องมีอันนี้ — "
                                  + "endpoint คือของที่ทำให้งานหนักไปรันบนเครื่องที่แรงกว่าได้"))
                .frame(height: 150)
        } else {
            ForEach(model.registry.endpoints) { endpoint in
                EndpointRow(model: model, endpoint: endpoint)
            }
        }
    }

    // MARK: - budget

    @ViewBuilder
    private var budgetSection: some View {
        Text("เพดานค่าใช้จ่าย").font(.subheadline).bold()
        if model.hasMeteredEndpoint {
            // Four ceilings, whichever is reached first (§9.5).
            VStack(alignment: .leading, spacing: 8) {
                CeilingField(label: "ต่อครั้ง", value: model.limits.perRequestUSD) { new in
                    var limits = model.limits; limits.perRequestUSD = new
                    Task { await model.setLimits(limits) }
                }
                CeilingField(label: "ต่อ session", value: model.limits.perSessionUSD,
                             used: model.spend.session) { new in
                    var limits = model.limits; limits.perSessionUSD = new
                    Task { await model.setLimits(limits) }
                }
                CeilingField(label: "ต่อวัน", value: model.limits.perDayUSD,
                             used: model.spend.today) { new in
                    var limits = model.limits; limits.perDayUSD = new
                    Task { await model.setLimits(limits) }
                }
                CeilingField(label: "ต่อเดือน", value: model.limits.perMonthUSD,
                             used: model.spend.month) { new in
                    var limits = model.limits; limits.perMonthUSD = new
                    Task { await model.setLimits(limits) }
                }
                Text("เกินเพดานไม่ใช่ error — งานจะตกไป Tier 1a หรือ 0.5 แล้วทำต่อ "
                     + "และเหตุผลถูกบันทึกลง span")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        } else {
            Text("ยังไม่มี endpoint ที่คิดเงิน — เพดานจึงยังไม่มีผลกับอะไร")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var spendSection: some View {
        Text("ใช้ไปกับอะไร (เดือนนี้)").font(.subheadline).bold()
        if model.breakdown.isEmpty {
            Text("ยังไม่มีการใช้จ่าย").font(.caption).foregroundStyle(.secondary)
        } else {
            ForEach(model.breakdown, id: \.key) { row in
                HStack {
                    Text(row.key).font(.callout)
                    Spacer()
                    Text("\(row.tokens) tokens").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "$%.4f", row.costUSD))
                        .font(.callout).monospacedDigit()
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - the editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.draft.name.isEmpty ? "เพิ่ม endpoint" : "แก้ \(model.draft.name)")
                .font(.headline)

            LabeledContent("ชื่อ") { TextField("GX10", text: $model.draft.name) }
            LabeledContent("URL") {
                TextField("http://gx10:8000/v1", text: $model.draft.baseURL)
            }
            LabeledContent("โมเดล") {
                TextField("เว้นว่าง = ใช้ที่เซิร์ฟเวอร์เสิร์ฟอยู่", text: $model.draft.model)
            }
            // §17.1 / P15.1 — the recommended setting for a server that serves
            // one model, which is what every self-hosted one does. A name
            // written here becomes wrong the day the checkpoint is swapped, and
            // the symptom is not an error: the endpoint drops out of the chain
            // and the app answers from the small model on this Mac instead.
            Text("เว้นช่องโมเดลว่างได้ถ้าเซิร์ฟเวอร์เสิร์ฟโมเดลเดียว — แอปจะถาม "
                 + "`/v1/models` เอาชื่อจริงทุกครั้ง จึงไม่พังตอนสลับ checkpoint · "
                 + "เซิร์ฟเวอร์ที่เสิร์ฟหลายโมเดลต้องระบุชื่อ")
                .font(.caption).foregroundStyle(.secondary)
            Picker("ชนิด", selection: $model.draft.kind) {
                Text("self-hosted (ฟรี)").tag(InferenceEndpoint.Kind.selfHosted)
                Text("paid (คิดเงิน)").tag(InferenceEndpoint.Kind.paid)
            }
            .pickerStyle(.segmented)

            if model.draft.kind == .paid {
                // The key is never written to bootstrap.plist — only the name
                // it is filed under. The value goes to the Keychain (P9.3);
                // before that there was nowhere in the app to put it at all.
                SecretField(name: Binding(
                    get: { model.draft.apiKeyEnvironmentVariable ?? "" },
                    set: { model.draft.apiKeyEnvironmentVariable = $0.isEmpty ? nil : $0 }),
                            title: "ชื่อคีย์ API",
                            placeholder: "OPENAI_API_KEY")
                LabeledContent("ราคา / ล้านโทเคน (เข้า)") {
                    TextField("3.00", value: $model.draft.inputPricePerMillion,
                              format: .number)
                }
                LabeledContent("ราคา / ล้านโทเคน (ออก)") {
                    TextField("15.00", value: $model.draft.outputPricePerMillion,
                              format: .number)
                }
                Text("ไม่ใส่ราคา = Budget Governor ประเมินไม่ได้ และจะไม่ยอมใช้ endpoint นี้เลย")
                    .font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("ปิด") { model.editing = false }
                Button("ตรวจแล้วบันทึก") { Task { await model.save() } }
                    .keyboardShortcut(.defaultAction)
            }
            Text("บันทึกได้ต่อเมื่อ endpoint ตอบ และมีโมเดลชื่อนี้จริง — "
                 + "เซิร์ฟเวอร์ยอมรับชื่อโมเดลที่ไม่มีอยู่ แล้วไปพังตอนใช้")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 520)
    }
}

private struct EndpointRow: View {
    @Bindable var model: EndpointsViewModel
    let endpoint: InferenceEndpoint

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusDot
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(endpoint.name).font(.body).bold()
                    if endpoint.kind == .paid {
                        Text("คิดเงิน")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.orange.opacity(0.2), in: Capsule())
                    }
                    if model.isDefault(endpoint) {
                        Text("ค่าเริ่มต้น")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.tint.opacity(0.15), in: Capsule())
                    }
                }
                // The model actually in use, which is not always the one in the
                // config: an endpoint with the name left blank is serving
                // whatever it is serving, and the row has to say which
                // (§17.1, P15.1). Falls back to the configured name until the
                // first check answers.
                Text("\(model.check(for: endpoint)?.resolvedModel ?? servedNameFallback) · "
                     + endpoint.baseURL)
                    .font(.caption).foregroundStyle(.secondary)
                if let check = model.check(for: endpoint) {
                    Text(check.message)
                        .font(.caption2)
                        .foregroundStyle(check.isUsable ? Color.secondary : Color.orange)
                }
            }
            Spacer()
            if !model.isDefault(endpoint) {
                Button("ตั้งเป็นค่าเริ่มต้น") { model.makeDefault(endpoint) }
            }
            Button("แก้") { model.beginEditing(endpoint) }
            Button(role: .destructive) { model.remove(endpoint) } label: {
                Label("ลบ", systemImage: "trash")
            }
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.link)
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    /// What to show before anything has been asked of the server. "(ตามที่
    /// เซิร์ฟเวอร์เสิร์ฟ)" rather than an empty gap, because an empty model
    /// field is a deliberate setting here and a row that shows nothing reads
    /// like a row that is broken.
    private var servedNameFallback: String {
        endpoint.model.isEmpty ? "(ตามที่เซิร์ฟเวอร์เสิร์ฟ)" : endpoint.model
    }

    /// §9.3 asks for a permanent dot rather than a probe per request: it costs
    /// nothing to look at and tokens to ask.
    @ViewBuilder
    private var statusDot: some View {
        if model.isChecking(endpoint) {
            ProgressView().controlSize(.small)
        } else {
            Circle()
                .fill(model.check(for: endpoint)?.isUsable == true ? Color.green : Color.orange)
                .frame(width: 9, height: 9)
                .padding(.top, 6)
                .accessibilityLabel(model.check(for: endpoint)?.isUsable == true
                                    ? "ต่อได้" : "ต่อไม่ได้")
        }
    }
}

private struct CeilingField: View {
    let label: String
    let value: Double?
    var used: Double?
    let onChange: (Double?) -> Void

    @State private var text = ""
    /// Scales with Dynamic Type — see the note in BootStatusView.
    @ScaledMetric private var column: CGFloat = 90

    var body: some View {
        HStack {
            Text(label).frame(width: column, alignment: .leading)
            TextField("ไม่จำกัด", text: $text)
                .frame(width: column)
                .onSubmit { onChange(Double(text)) }
            if let used, let value {
                // Spent against the ceiling, on the same line: a limit without
                // the current number beside it is a setting, not a budget.
                ProgressView(value: min(used / max(value, 0.0001), 1))
                    .frame(maxWidth: 200)
                Text(String(format: "ใช้ไป $%.4f / $%.2f", used, value))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer()
        }
        .task { text = value.map { String(format: "%.2f", $0) } ?? "" }
    }
}
