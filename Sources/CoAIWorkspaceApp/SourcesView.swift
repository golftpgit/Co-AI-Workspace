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
// "ยังไม่ผ่าน QA เพราะแหล่งอ่อน" had no way to find out what the system thinks
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
                Text("แหล่งและชั้นความน่าเชื่อถือ").font(.headline)
                Picker("สาขา", selection: $discipline) {
                    Text("ทุกสาขา").tag(Discipline?.none)
                    ForEach(Discipline.allCases, id: \.self) { subject in
                        Text(subject.label).tag(Discipline?.some(subject))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
                .accessibilityLabel("กรองแหล่งตามสาขา")
                Spacer()
                Text("\(shown.count) แหล่ง").font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
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
            Text("โดเมนที่ไม่อยู่ในทะเบียนนี้ถือเป็น T5 (เว็บทั่วไป) ไม่ใช่ \"ไม่รู้จัก\" — "
                 + "หน้าที่ไม่มีใครรับรองคือเว็บทั่วไป และการปล่อยให้มันไม่มี tier "
                 + "จะทำให้มันหลุดตัวกรองที่ตรวจ tier · แก้รายการยังทำไม่ได้ (P13)")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(10)
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
                Text("ค้นเว็บทั่วไป (T5)").font(.headline)
                Text("ผ่าน \(source.name) ในเบราว์เซอร์ของแอปเอง")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 8) {
                TextField("คำค้น เช่น ความชุกภาวะหมดไฟในพยาบาลไทย", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { run(source) }
                    .accessibilityLabel("คำค้นสำหรับค้นเว็บทั่วไป")
                Button("ค้น") { run(source) }
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
                            Button(reading == result.url.absoluteString ? "กำลังอ่าน…" : "อ่านหน้านี้") {
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
                .accessibilityLabel("ผลค้น \(result.title) ชั้น \(result.tier.rawValue) จาก \(result.url.host() ?? "")")
            }

            if let page {
                Divider()
                Text("อ่านแล้ว: \(page.title ?? page.finalURL.absoluteString)")
                    .font(.callout).bold()
                Text("\(page.paragraphs.count) ย่อหน้า · tier \(page.provenance.tier?.rawValue ?? "—") · "
                     + "เข้าท่อ ingest เส้นเดิมได้ทั้งหมด")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(page.paragraphs.prefix(3).joined(separator: "\n\n"))
                    .font(.caption).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("snippet ใช้เลือกว่าจะเปิดอันไหน ห้ามอ้างอิง — ต้องอ่านหน้าจริงก่อนเสมอ (§1.4) · "
                 + "ระบบไม่แก้ CAPTCHA: เจอด่านแล้วจะบอกให้คนไปเปิดเอง")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
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
                    Text("ปิดอยู่").font(.caption2).foregroundStyle(.orange)
                }
            }
            Text(source.disciplines.map(\.label).joined(separator: " · ")
                 + " · เข้าถึงโดย \(accessLabel(source.access))")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(source.name) โดเมน \(source.domain) ชั้น \(source.tier.rawValue)")
    }

    private func tierMeaning(_ tier: SourceTier) -> String {
        switch tier {
        case .t1: "เอกสารทางการ · มาตรฐาน · กฎหมาย"
        case .t2: "ผ่าน peer review"
        case .t3: "preprint และรายงานกึ่งทางการ"
        case .t4: "ชุมชนที่ตรวจกันเอง"
        case .t5: "เว็บทั่วไป — ต้องมีแหล่งชั้นบนยืนยัน"
        }
    }

    private func accessLabel(_ access: AccessMethod) -> String {
        switch access {
        case .api(let name): "API ของ \(name)"
        case .siteQuery: "ค้นเฉพาะโดเมน"
        case .metaSearch: "meta-search แล้วอ่านหน้าจริง"
        }
    }
}
