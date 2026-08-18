import SwiftUI
import AgentKit
import Knowledge
import WebSearch

// ─────────────────────────────────────────────────────────────
// The source registry, visible (ARCHITECTURE §1.4, §19.2, P10.12).
//
// The registry has decided every citation's tier since P3, and until now nobody
// could see it. That matters more here than for most tables: §14.1's rule is
// that a claim needs corroboration from a good enough tier, so a person reading
// "QA rejected it because the sources are weak" had no way to find out what the system thinks
// is strong.
//
// Read-only for now, and it says so. Turning a source off is a setting that has
// to survive a relaunch, and the registry is still a value built at boot rather
// than a stored one (P13) — a toggle that forgets itself overnight is worse than
// a list that admits it cannot be edited yet.
// ─────────────────────────────────────────────────────────────

struct SourcesView: View {
    let registry: SourceRegistry
    /// The T5 bridge, when the app has one (§1.4.1, P13.1). Optional so this
    /// screen still lists the registry on a build without it.
    let search: (any WebSearching)?
    let read: (any PageReading)?
    @State private var discipline: Discipline?
    @State private var query = ""
    @State private var results: [WebResult] = []
    @State private var searching = false
    @State private var problem: String?
    @State private var reading: String?
    @State private var page: FetchedPage?

    init(registry: SourceRegistry, search: (any WebSearching)? = nil,
         read: (any PageReading)? = nil) {
        self.registry = registry
        self.search = search
        self.read = read
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let search { searchPanel(search) ; Divider() }
            HStack(spacing: 10) {
                Text(localised: "Sources and their trust tiers", "Heading of the sources screen.")
                    .font(.headline)
                Picker(t("Discipline", "Picker: filter sources by field of study."), selection: $discipline) {
                    Text(localised: "All disciplines", "Picker option: no discipline filter.")
                        .tag(Discipline?.none)
                    ForEach(Discipline.allCases, id: \.self) { subject in
                        Text(subject.label).tag(Discipline?.some(subject))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
                .accessibilityLabel(t("Filter sources by discipline", "Screen-reader label."))
                Spacer()
                Text(localised: "\(shown.count) sources",
                     "How many sources are listed. Placeholder is a count.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(Space.box)
            Divider()

            List {
                ForEach(SourceTier.allCases, id: \.self) { tier in
                    let sources = shown.filter { $0.tier == tier }
                    if !sources.isEmpty {
                        Section {
                            ForEach(sources) { source in
                                row(source)
                            }
                        } header: {
                            Text("\(tier.rawValue.uppercased()) — \(tierMeaning(tier))")
                        }
                    }
                }
            }

            Divider()
            Text(localised: "A domain not in this register counts as T5 (the open web), not as “unknown” — a page nobody vouches for is the open web, and leaving it without a tier would let it slip past the filters that check tiers · editing the list is not possible yet (P13)",
                 "Explains the default tier and why it is not “unknown”.")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(Space.box)
        }
    }


    // MARK: - the T5 bridge (§1.4.1, P13.1)

    /// Searching the open web through the app's own web view, and reading one of
    /// the results with it.
    ///
    /// On screen rather than only behind the agent's tool because P13.1 is judged
    /// on a person getting real results out of the sandboxed `.app` — and because
    /// the two failure modes that matter are ones a person has to see: a bot wall
    /// asking for a human, and an extractor that has gone stale.
    @ViewBuilder
    private func searchPanel(_ source: any WebSearching) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(localised: "Search the open web (T5)", "Heading over the web search box.")
                    .font(.headline)
                Text(localised: "Through \(source.name), in the app's own browser",
                     "Says which search service is used. Placeholder is its name.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 8) {
                TextField(t("Search terms, for example: prevalence of burnout among nurses",
                            "Placeholder in the open-web search field."),
                          text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { run(source) }
                    .accessibilityLabel(t("Search terms for the open web", "Screen-reader label."))
                Button(t("Search", "Button that runs the knowledge search.")) { run(source) }
                    .disabled(searching || query.trimmingCharacters(in: .whitespaces).isEmpty)
                if searching { ProgressView().controlSize(.small) }
            }

            if let problem {
                // The two errors worth their own colour: a wall is a request for
                // a person, and a stale extractor is a bug in us. Neither is
                // "no results" (§1.4.1).
                Text(problem)
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            ForEach(results, id: \.url) { result in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(result.tier.rawValue.uppercased())
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                        Text(result.title).font(.callout).lineLimit(1)
                        Spacer()
                        if read != nil {
                            Button(reading == result.url.absoluteString
                                   ? t("reading…", "Button label while a page is being fetched.")
                                   : t("Read this page", "Button that fetches and reads a search result.")) {
                                readPage(result.url)
                            }
                            .controlSize(.small)
                            .disabled(reading != nil)
                        }
                    }
                    Text(result.url.absoluteString)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    if !result.snippet.isEmpty {
                        // Shown for choosing what to open — never citable (§1.4).
                        Text(result.snippet).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(t("Result \(result.title), tier \(result.tier.rawValue), from \(result.url.host() ?? "")",
                                      "Screen-reader label for a search result. Placeholders: its title, tier and host."))
            }

            if let page {
                Divider()
                Text(localised: "Read: \(page.title ?? page.finalURL.absoluteString)",
                     "Says which page was read. Placeholder is its title or address.")
                    .font(.callout).bold()
                Text(localised: "\(page.paragraphs.count) paragraphs · tier \(page.provenance.tier?.rawValue ?? "—") · all of it can go through the usual ingest path",
                     "Summary of a page that was read. Placeholders: how many paragraphs and its tier.")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(page.paragraphs.prefix(3).joined(separator: "\n\n"))
                    .font(.caption).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(localised: "A snippet is for choosing which page to open, never for citing — the real page has to be read first (§1.4) · the system does not solve CAPTCHAs: when it meets one it says so and asks a person to open it",
                 "States two rules about web search results.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(Space.box)
    }

    private func run(_ source: any WebSearching) {
        let text = query
        searching = true
        problem = nil
        results = []
        page = nil
        Task {
            do {
                results = try await source.search(text, limit: 8)
            } catch {
                problem = "\(error)"
            }
            searching = false
        }
    }

    private func readPage(_ url: URL) {
        guard let read else { return }
        reading = url.absoluteString
        problem = nil
        Task {
            do {
                page = try await read.fetch(url)
            } catch {
                problem = "\(error)"
            }
            reading = nil
        }
    }

    private var shown: [Source] {
        guard let discipline else { return registry.sources }
        return registry.sources.filter {
            $0.disciplines.contains(discipline) || $0.disciplines.contains(.general)
        }
    }

    @ViewBuilder
    private func row(_ source: Source) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(source.name).font(.callout)
                Text(source.domain).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !source.isEnabled {
                    Text(localised: "off", "Marker on a source that is switched off.")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            Text(source.disciplines.map(\.label).joined(separator: " · ")
                 + t(" · reached by \(accessLabel(source.access))",
                     "Appended to a source row. Placeholder is how the source is reached."))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(t("\(source.name), domain \(source.domain), tier \(source.tier.rawValue)",
                              "Screen-reader label for a source row. Placeholders: its name, domain and tier."))
    }

    private func tierMeaning(_ tier: SourceTier) -> String {
        switch tier {
        case .t1: t("official documents · standards · law", "What a T1 source is.")
        case .t2: t("peer reviewed", "What a T2 source is.")
        case .t3: t("preprints and semi-official reports", "What a T3 source is.")
        case .t4: t("communities that review each other", "What a T4 source is.")
        case .t5: t("the open web — needs a higher tier to confirm it", "What a T5 source is.")
        }
    }

    private func accessLabel(_ access: AccessMethod) -> String {
        switch access {
        case .api(let name): t("the \(name) API",
                               "How a source is reached. Placeholder is the service name.")
        case .siteQuery: t("a search restricted to the domain", "How a source is reached.")
        case .metaSearch: t("meta-search, then reading the real page", "How a source is reached.")
        }
    }
}
