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
                .padding(Space.section)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $model.editing) { editor }
        .task { await model.refreshSpending() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(localised: "Remote models (Tier 1)",
                 "Heading of the endpoints screen. 'Tier 1' is the name of that tier.")
                .font(.headline)
            Button(t("Add endpoint", "Button that starts defining a new server.")) { model.beginAdding() }
            Button(t("Re-check all", "Button that probes every configured endpoint again.")) {
                Task { await model.recheckAll() }
            }
            Spacer()
            if let status = model.status {
                Text(status.message)
                    .font(.caption)
                    .foregroundStyle(status.isError ? .red : .secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 420, alignment: .trailing)
            }
        }
        .padding(Space.box)
    }

    @ViewBuilder
    private var endpointList: some View {
        if model.registry.endpoints.isEmpty {
            ContentUnavailableView(
                t("No endpoint yet", "Empty state on the endpoints screen."),
                systemImage: "network",
                description: Text(localised: "Tier 0.5 already works without one — an endpoint is what lets heavy work run on a stronger machine",
                                  "Empty-state explanation on the endpoints screen. 'Tier 0.5' is the name of the on-device tier."))
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
        Text(localised: "Spending ceilings", "Heading over the per-request, per-day and per-month limits.")
            .font(.subheadline).bold()
        if model.hasMeteredEndpoint {
            // Four ceilings, whichever is reached first (§9.5).
            VStack(alignment: .leading, spacing: 8) {
                CeilingField(label: t("per request", "Spending ceiling: the most one call may cost."),
                             value: model.limits.perRequestUSD) { new in
                    var limits = model.limits; limits.perRequestUSD = new
                    Task { await model.setLimits(limits) }
                }
                CeilingField(label: t("per session", "Spending ceiling: the most one session may cost."),
                             value: model.limits.perSessionUSD,
                             used: model.spend.session) { new in
                    var limits = model.limits; limits.perSessionUSD = new
                    Task { await model.setLimits(limits) }
                }
                CeilingField(label: t("per day", "Spending ceiling: the most one day may cost."),
                             value: model.limits.perDayUSD,
                             used: model.spend.today) { new in
                    var limits = model.limits; limits.perDayUSD = new
                    Task { await model.setLimits(limits) }
                }
                CeilingField(label: t("per month", "Spending ceiling: the most one month may cost."),
                             value: model.limits.perMonthUSD,
                             used: model.spend.month) { new in
                    var limits = model.limits; limits.perMonthUSD = new
                    Task { await model.setLimits(limits) }
                }
                Text(localised: "Going over a ceiling is not an error — the work drops to Tier 1a or 0.5 and carries on, and the reason is written to the span",
                     "Explains what happens at a spending ceiling. The tier names stay as they are.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(Space.box)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: Radius.box))
        } else {
            Text(localised: "No paid endpoint yet — so the ceilings apply to nothing",
                 "Shown when spending limits exist but nothing can spend.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var spendSection: some View {
        Text(localised: "What it went on (this month)", "Heading over the spending breakdown.")
            .font(.subheadline).bold()
        if model.breakdown.isEmpty {
            Text(localised: "No spending yet", "Shown when nothing has been charged this month.")
                .font(.caption).foregroundStyle(.secondary)
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
            Text(model.draft.name.isEmpty
                 ? t("Add endpoint", "Sheet title when defining a new server.")
                 : t("Edit \(model.draft.name)", "Sheet title when editing a server. Placeholder is its name."))
                .font(.headline)

            // `LabeledContent` puts its label beside the field, not *on* it:
            // the text field itself is announced as nothing, and Tab lands on
            // twenty anonymous stops. Found by driving this sheet — the audit
            // script never reached it because it only walks the main window.
            LabeledContent(t("Name", "Field label: what to call this endpoint.")) {
                TextField("GX10", text: $model.draft.name)
                    .accessibilityLabel(t("Endpoint name", "Screen-reader label for the endpoint name field."))
            }
            LabeledContent("URL") {
                TextField("http://192.168.1.205:8000/v1", text: $model.draft.baseURL)
                    .accessibilityLabel(t("Endpoint URL", "Screen-reader label for the endpoint URL field."))
                    .accessibilityHint(t("ends with /v1", "Screen-reader hint about the expected URL shape."))
            }
            LabeledContent(t("Model", "Field label: which model this endpoint serves.")) {
                TextField(t("leave empty = whatever the server is serving",
                            "Placeholder in the model field."),
                          text: $model.draft.model)
                    .accessibilityLabel(t("Model name", "Screen-reader label for the model field."))
                    .accessibilityHint(t("may be left empty if the server serves one model",
                                         "Screen-reader hint for the model field."))
            }
            // §17.1 / P15.1 — the recommended setting for a server that serves
            // one model, which is what every self-hosted one does. A name
            // written here becomes wrong the day the checkpoint is swapped, and
            // the symptom is not an error: the endpoint drops out of the chain
            // and the app answers from the small model on this Mac instead.
                Text(localised: "The model field may be left empty when the server serves one model — the app asks `/v1/models` for the real name every time, so switching checkpoints does not break it · a server that serves several models needs the name",
                     "Explains when the model field can be blank.")
                .font(.caption).foregroundStyle(.secondary)
            Picker(t("Kind", "Picker: whether this endpoint charges money."),
                   selection: $model.draft.kind) {
                Text(localised: "self-hosted (free)", "Endpoint kind: a server you run yourself.")
                    .tag(InferenceEndpoint.Kind.selfHosted)
                Text(localised: "paid (charges money)", "Endpoint kind: a provider that bills per token.")
                    .tag(InferenceEndpoint.Kind.paid)
            }
            .pickerStyle(.segmented)

            if model.draft.kind == .paid {
                // The key is never written to bootstrap.plist — only the name
                // it is filed under. The value goes to the Keychain (P9.3);
                // before that there was nowhere in the app to put it at all.
                SecretField(name: Binding(
                    get: { model.draft.apiKeyEnvironmentVariable ?? "" },
                    set: { model.draft.apiKeyEnvironmentVariable = $0.isEmpty ? nil : $0 }),
                            title: t("API key name", "Label on the field naming the stored API key."),
                            placeholder: "OPENAI_API_KEY")
                LabeledContent(t("Price / million tokens (in)",
                                 "Field label: what the provider charges for input tokens.")) {
                    TextField("3.00", value: $model.draft.inputPricePerMillion,
                              format: .number)
                        .accessibilityLabel(t("Price per million input tokens", "Screen-reader label."))
                }
                LabeledContent(t("Price / million tokens (out)",
                                 "Field label: what the provider charges for output tokens.")) {
                    TextField("15.00", value: $model.draft.outputPricePerMillion,
                              format: .number)
                        .accessibilityLabel(t("Price per million output tokens", "Screen-reader label."))
                }
                Text(localised: "No price means the Budget Governor cannot estimate anything, and it will refuse to use this endpoint at all",
                     "Warning under the price fields. 'Budget Governor' is a component name and stays as is.")
                    .font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button(t("Close", "Button that dismisses the endpoint sheet without saving.")) {
                    model.editing = false
                }
                Button(t("Check and save", "Button that probes the endpoint and saves it only if it answers.")) {
                    Task { await model.save() }
                }
                    .keyboardShortcut(.defaultAction)
            }
            Text(localised: "It saves only if the endpoint answers and really serves a model by that name — a server will accept a model name that does not exist and then fail when you use it",
                 "Explains why saving probes the server first.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(Space.section)
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
                        Text(localised: "paid", "Tag on an endpoint that charges money.")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.orange.opacity(0.2), in: Capsule())
                    }
                    if model.isDefault(endpoint) {
                        Text(localised: "default", "Tag on the endpoint used unless something says otherwise.")
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
                Button(t("Make default", "Button that makes this the endpoint used by default.")) {
                    model.makeDefault(endpoint)
                }
            }
            Button(t("Edit", "Button that opens an endpoint for editing.")) { model.beginEditing(endpoint) }
            Button(role: .destructive) { model.remove(endpoint) } label: {
                Label(t("Delete", "Button that removes an endpoint."), systemImage: "trash")
            }
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.link)
        .padding(Space.box)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: Radius.box))
    }

    /// What to show before anything has been asked of the server. "(whatever
    /// the server serves)" rather than an empty gap, because an empty model
    /// field is a deliberate setting here and a row that shows nothing reads
    /// like a row that is broken.
    private var servedNameFallback: String {
        endpoint.model.isEmpty
            ? t("(whatever the server serves)",
                "Stand-in for an endpoint's model name before the server has been asked.")
            : endpoint.model
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
                                    ? t("reachable", "Endpoint probe result: the server answered.")
                                    : t("not reachable", "Endpoint probe result: the server did not answer."))
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
            TextField(t("no limit", "Placeholder in a spending ceiling field left empty."), text: $text)
                .frame(width: column)
                .onSubmit { onChange(Double(text)) }
            if let used, let value {
                // Spent against the ceiling, on the same line: a limit without
                // the current number beside it is a setting, not a budget.
                ProgressView(value: min(used / max(value, 0.0001), 1))
                    .frame(maxWidth: 200)
                Text(String(format: t("spent $%.4f / $%.2f",
                                      "How much of a spending ceiling has been used. Placeholders: the amount spent and the ceiling, both in the endpoint's own currency."),
                            used, value))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer()
        }
        .task { text = value.map { String(format: "%.2f", $0) } ?? "" }
    }
}
