import Foundation
import Observation
import AgentKit
import DocGen
import Persistence

// ─────────────────────────────────────────────────────────────
// The screen behind the five-chapter manuscript (ARCHITECTURE §20.8, P11.9).
//
// P11.9 built the guarantee — a reported number is a `ResultReference` bound to
// a run that happened — and `AnalysisViewModel.exportManuscript` to write the
// document out. Nothing constructed a `Manuscript`, so nothing ever called it:
// the whole feature was reachable from its tests and from nowhere else, which
// is D6 and is why this file exists.
//
// Two decisions worth stating:
//
// 1. **The preview and the export are checked against the same evidence.**
//    Both go through `AnalysisViewModel.manuscriptEvidence()`. A screen that
//    says "พร้อมส่งออก" beside a button that then refuses is worse than a
//    screen with no preview, because it teaches the author to distrust the
//    check that is the point of the feature.
// 2. **Saving is not export.** A draft is saved constantly and half-finished;
//    a document is produced once and has to be right. So the store accepts a
//    manuscript with unbound numbers in it — the refusal lives at the export,
//    where it belongs — and the screen shows the problems the whole time.
// ─────────────────────────────────────────────────────────────

@MainActor
@Observable
final class ManuscriptViewModel {
    private(set) var manuscripts: [Manuscript] = []
    var selected: Manuscript?
    private(set) var preview: ManuscriptPreview?
    private(set) var status: String?
    private(set) var isError = false

    /// The cells that have actually run, for the number picker. A picker over
    /// every cell would offer references that cannot bind, which is a
    /// refusal the author would meet later instead of a choice they cannot
    /// make wrongly now.
    private(set) var runs: [CellRun] = []

    private var store: ManuscriptStore?
    private var analysis: AnalysisViewModel?
    private var scope: Scope = .central

    func attach(store: ManuscriptStore?, analysis: AnalysisViewModel?, scope: Scope) {
        self.store = store
        self.analysis = analysis
        self.scope = scope
    }

    func load() async {
        guard let store else { return }
        do {
            manuscripts = try await store.load(scope: scope).map(\.manuscript)
            if let selected, let fresh = manuscripts.first(where: { $0.id == selected.id }) {
                self.selected = fresh
            }
            await refreshPreview()
        } catch {
            report(ReadableFailure.message(for: error, doing: "อ่านรายการต้นฉบับ"), isError: true)
        }
    }

    func create(title: String) async {
        // §20.8 is about a study's results. A manuscript that belongs to no
        // project is a thesis with no data behind it.
        guard case .project = scope else {
            report("ต้นฉบับเป็นของโครงการ — เลือกโครงการก่อนจึงจะสร้างได้", isError: true)
            return
        }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var fresh = Manuscript(scope: scope, title: trimmed)
        // Chapter 4 is where the bound numbers live, so it starts with a
        // section rather than making the first thing the author does be
        // administrative.
        fresh.sections[.results] = [ManuscriptSection(heading: "4.1 ผลการวิเคราะห์")]
        // Selected *before* saving, not after. Driven: pressing "สร้าง" put
        // the new manuscript in the list and left the editor showing
        // "ยังไม่ได้เลือกต้นฉบับ" until you clicked the row you had just made
        // — because `save` reloads, and the reload decided what was selected
        // while this was still nil (U33-5).
        selected = fresh
        await save(fresh)
    }

    func save(_ manuscript: Manuscript) async {
        guard let store else { return }
        do {
            try await store.save(manuscript)
            if selected?.id == manuscript.id { selected = manuscript }
            await load()
        } catch {
            report(ReadableFailure.message(for: error, doing: "บันทึกต้นฉบับ"), isError: true)
        }
    }

    func delete(_ manuscript: Manuscript) async {
        guard let store else { return }
        try? await store.delete(manuscript.id)
        if selected?.id == manuscript.id { selected = nil }
        await load()
    }

    // MARK: - editing

    func addSection(to chapter: ManuscriptChapter) async {
        guard var manuscript = selected else { return }
        var sections = manuscript.sections[chapter] ?? []
        sections.append(ManuscriptSection(
            heading: "\(chapter.rawValue).\(sections.count + 1) หัวข้อใหม่"))
        manuscript.sections[chapter] = sections
        await save(manuscript)
    }

    func update(_ section: ManuscriptSection, at index: Int,
                in chapter: ManuscriptChapter) async {
        guard var manuscript = selected,
              var sections = manuscript.sections[chapter], index < sections.count else { return }
        sections[index] = section
        manuscript.sections[chapter] = sections
        await save(manuscript)
    }

    func removeSection(at index: Int, in chapter: ManuscriptChapter) async {
        guard var manuscript = selected,
              var sections = manuscript.sections[chapter], index < sections.count else { return }
        sections.remove(at: index)
        manuscript.sections[chapter] = sections
        await save(manuscript)
    }

    // MARK: - the preview, and the export

    func refreshPreview() async {
        guard let manuscript = selected, let analysis else { preview = nil; return }
        let evidence = await analysis.manuscriptEvidence()
        runs = evidence.runs
        preview = ManuscriptPreview.of(manuscript, runs: evidence.runs,
                                       currentSources: evidence.currentSources)
    }

    /// Whether the export can succeed, answered from the same check the export
    /// itself runs. `nil` means nothing has been previewed yet.
    var isExportable: Bool { preview?.isExportable ?? false }

    func export(to url: URL) async {
        guard let manuscript = selected, let analysis else { return }
        await analysis.exportManuscript(manuscript, to: url)
        // The analysis model owns the sentence about what happened — including
        // the refusal, which is the message that matters.
        if let analysisStatus = analysis.status {
            report(analysisStatus.message, isError: analysisStatus.isError)
        }
    }

    private func report(_ message: String, isError: Bool) {
        status = message
        self.isError = isError
    }
}
