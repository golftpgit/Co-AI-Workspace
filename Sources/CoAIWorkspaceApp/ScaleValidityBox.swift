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
        GroupBox(t("Reliability and construct validity (§20.4)",
                   "Box heading over α, ω and the factor analysis.")) {
            VStack(alignment: .leading, spacing: 10) {
                controls
                if let analysis = model.scaleReport {
                    if model.scaleReportIsStale {
                        // The round is still open and answers have arrived since.
                        // Saying so beats both alternatives: dropping the table
                        // throws away work somebody waited for, and redrawing it
                        // unmarked would put these numbers beside answers they
                        // were not computed from.
                        Label(t("Responses changed after this was computed — the numbers below come from the \(analysis.respondents) respondents it used. Compute again to include the new ones.",
                                "Warning that the analysis is stale. Placeholder is how many respondents it used."),
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
                    Text(localised: "Computed from the answers really collected for this version — α and ω per subscale, then an exploratory factor analysis across all items together",
                         "Explains what the reliability box computes and from what.")
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
            Button(t("Compute reliability and factors", "Button that runs the psychometric analysis.")) {
                Task { await model.analyseScale() }
            }
            .disabled(model.isAnalysingScale || model.responseRows.isEmpty)

            if model.isAnalysingScale {
                ProgressView().controlSize(.small)
                Text(localised: "Computing — parallel analysis draws 100 random comparison sets",
                     "Progress note, saying why the computation takes a while.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .controlSize(.small)

        // The retention rule is offered rather than chosen, and both answers stay
        // visible below — a solution that changes with the rule is a finding, not
        // a setting.
        if model.scaleReport?.solution != nil {
            Picker(t("Rule for how many factors",
                     "Picker over the criteria for choosing the number of factors."),
                   selection: Binding(
                get: { RuleChoice(model.retentionRule) },
                set: { choice in Task { await model.analyseScale(rule: choice.rule) } })) {
                ForEach(RuleChoice.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .accessibilityLabel(t("Rule used to decide the number of factors", "Screen-reader label."))
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
        var parts = [t("\(analysis.respondents) respondents used",
                       "Part of the analysis summary. Placeholder is a count of respondents."),
                     t("\(analysis.scoredItemIDs.count) scorable items",
                       "Part of the analysis summary. Placeholder is a count of items.")]
        if analysis.droppedRespondents > 0 {
            // Said rather than absorbed: listwise deletion that nobody mentions
            // is how a sample of 120 becomes 78 between two paragraphs.
            parts.append(t("\(analysis.droppedRespondents) dropped for not answering every item",
                           "Part of the analysis summary. Placeholder is a count of respondents."))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - α and ω

    @ViewBuilder
    private func reliability(_ analysis: ScaleReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(localised: "Reliability per subscale", "Heading over α and ω for each subscale.")
                .font(.callout).bold()
            ForEach(analysis.subscales) { subscale in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 8) {
                        Text(subscale.name).font(.callout)
                        Text(localised: "\(subscale.itemIDs.count) items",
                             "How many items a subscale holds. Placeholder is a count.")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        if let alpha = subscale.alpha {
                            Text(String(format: "α %.3f", alpha.alpha))
                                .font(.callout)
                                .foregroundStyle(alpha.passes ? Color.green : Color.orange)
                        } else {
                            Text(localised: "α cannot be computed", "Shown when a subscale has too little data.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let omega = subscale.omega {
                            Text(String(format: "ω %.3f", omega.omega))
                                .font(.callout)
                                .foregroundStyle(omega.passes ? Color.green : Color.orange)
                        }
                    }
                    if let weakest = subscale.weakestItem {
                        Text(String(format: t("Item %@ correlates with the rest of this subscale at only %.2f — ",
                                              "Warning about a weak item. Placeholders: the item and its correlation."),
                                    prompt(weakest.item), weakest.correlation)
                             + t("below .30, the threshold usually taken to mean it measures something else",
                                 "Completes the weak-item warning."))
                            .font(.caption2).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if subscale.alpha != nil && subscale.omega == nil {
                        Text(localised: "ω needs at least 3 items and more respondents than items — this subscale has neither, so only α is shown",
                             "Explains why ω is missing for a subscale.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Text(localised: "α assumes every item is equally good, which is almost never true · ω does not, so both are reported — and a large gap between them means some items measure noticeably better than others",
                 "Explains why both α and ω are shown.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - is there anything to factor

    @ViewBuilder
    private func adequacy(_ solution: FactorSolution) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(localised: "Is the data suitable for factor analysis?",
                 "Heading over the KMO and Bartlett checks.")
                .font(.callout).bold()
            Text(solution.adequacy.summary)
                .font(.caption)
                .foregroundStyle(solution.adequacy.isFactorable ? .secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
            Text(localised: "Eigenvalues: \(solution.eigenvalues.map { String(format: "%.2f", $0) }.joined(separator: " · "))",
                 "The eigenvalues of the factor solution. Placeholder is the list of them.")
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
                Text(localised: "Item", "Column heading in the factor loading table.")
                    .font(.caption2).foregroundStyle(.secondary)
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
            Text(localised: "Bold = |loading| ≥ \(String(format: "%.2f", FactorLoading.salient)) · h² = the share of that item's variance the factors explain · varimax rotation after principal axis factoring · a reverse-worded item loads negative, which is how you notice it has not been reverse-scored",
                 "Legend under the factor loading table. Placeholder is the salience threshold.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - declared against found

    @ViewBuilder
    private func constructFit(_ fit: ConstructFit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(localised: "Do the items land on the constructs they were declared for?",
                 "Heading over the construct alignment table.")
                .font(.callout).bold()
            ForEach(fit.constructs) { row in
                HStack(spacing: 6) {
                    Image(systemName: row.isClean ? "checkmark.circle" : "exclamationmark.circle")
                        .foregroundStyle(row.isClean ? Color.green : Color.orange)
                    Text(constructName(row.constructID)).font(.caption)
                    Text(row.factor.map {
                        t("→ F\($0 + 1) · \(row.itemsOnFactor)/\(row.itemsDeclared) items",
                          "Which factor a construct's items landed on. Placeholders: the factor number, how many landed there, and how many were declared.")
                    } ?? t("no factor holds this construct's items together",
                           "Shown when a construct's items did not group."))
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            if !fit.misplaced.isEmpty {
                Text(localised: "Items that landed on a different factor than declared: \(fit.misplaced.map { prompt($0) }.joined(separator: " · "))",
                     "Names the cross-loading items. Placeholder is the list of them.")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(fit.mergedConstructs.enumerated()), id: \.offset) { _, merged in
                Text(localised: "The data cannot separate these constructs: \(merged.map { constructName($0) }.joined(separator: " + "))",
                     "Names constructs the factor solution merged. Placeholder is the list of them.")
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
            Text(localised: "Items not included in the computation",
                 "Heading over items excluded from the analysis.")
                .font(.caption).bold().foregroundStyle(.secondary)
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
