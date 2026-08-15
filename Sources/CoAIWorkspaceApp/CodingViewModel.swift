import Foundation
import Observation
import AgentKit
import Instruments
import Persistence
import Observability

// ─────────────────────────────────────────────────────────────
// The qualitative tab's state (ARCHITECTURE §20.3, P11.8).
//
// Same division as the quantitative side: everything with a decision in it lives
// in M15 where `swift test` can reach it, and what is here is loading, saving
// and which coder is currently at the keyboard.
//
// That last one is the only piece of state on this screen that matters. κ is a
// statement about *people*, so every coding has to carry whose it was, and the
// commonest way to ruin an intercoder study is for the second coder to sit down
// at a machine still logged in as the first. The name is therefore never
// remembered between sessions and never defaulted — it is asked for, and until
// it is given the coding buttons do not work.
// ─────────────────────────────────────────────────────────────

@MainActor
@Observable
public final class CodingViewModel {
    public struct Status: Equatable {
        public var message: String
        public var isError: Bool
    }

    public private(set) var codebooks: [Codebook] = []
    public private(set) var selectedID: String?
    public private(set) var units: [CodingUnit] = []
    public private(set) var assignments: [CodeAssignment] = []
    /// The texts the units' offsets point into (§20.3, P11.8). Held so a
    /// quotation can be *taken* from the source rather than read off the unit's
    /// own copy — the two drift, and only one of them is evidence.
    public private(set) var transcripts: [Transcript] = []
    public private(set) var status: Status?

    /// Who is coding right now. Deliberately not persisted — see the note above.
    public var coder: String = ""

    private var store: CodebookStore?
    private var scope: Scope = .central
    private var spans: (any SpanSink)?
    private let log = AppLog.logger("coding-ui")

    public init() {}

    public var selected: Codebook? { codebooks.first { $0.id == selectedID } }

    /// κ and the per-code breakdown, or `nil` when the design cannot support one.
    public var reliability: CodingReliability? {
        guard let selected else { return nil }
        return CodingAnalysis.reliability(units: units, assignments: assignments,
                                          codebook: selected)
    }

    public var saturation: SaturationCurve? {
        guard let selected, !units.isEmpty else { return nil }
        return CodingAnalysis.saturation(units: units, assignments: assignments,
                                         order: selected.documentOrder)
    }

    /// What this coder has already decided, so the screen can show their own
    /// work and not somebody else's.
    public func assignment(for unit: CodingUnit) -> CodeAssignment? {
        let name = coder.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return assignments.first { $0.unitID == unit.id && $0.coder == name }
    }

    /// How many of the units each coder has been through — the number that says
    /// whether κ is about the whole set or about the first eleven passages.
    public var progress: [(coder: String, done: Int)] {
        Dictionary(grouping: assignments, by: \.coder)
            .map { (coder: $0.key, done: $0.value.count) }
            .sorted { $0.coder < $1.coder }
    }

    public func attach(store: CodebookStore, scope: Scope,
                       spans: (any SpanSink)? = nil) async {
        self.store = store
        self.scope = scope
        self.spans = spans
        await reload()
    }

    public func reload() async {
        guard let store, case .project(let project) = scope else {
            codebooks = []
            selectedID = nil
            units = []
            assignments = []
            return
        }
        do {
            transcripts = (try? await store.transcripts(project: project)) ?? []
            codebooks = try await store.all(project: project)
            if selectedID == nil || !codebooks.contains(where: { $0.id == selectedID }) {
                selectedID = codebooks.first?.id
            }
            await refresh()
        } catch {
            log.error("loading codebooks: \(error)")
            status = Status(message: "โหลดสมุดรหัสไม่สำเร็จ: \(error)", isError: true)
        }
    }

    public func select(_ id: String?) async {
        selectedID = id
        await refresh()
    }

    private func refresh() async {
        guard let store, let selected else {
            units = []
            assignments = []
            return
        }
        if case .project(let project) = scope {
            transcripts = (try? await store.transcripts(project: project)) ?? []
        }
        units = (try? await store.units(codebook: selected.id)) ?? []
        assignments = (try? await store.assignments(codebook: selected.id)) ?? []
    }

    // MARK: - the book

    public func createCodebook(title: String) async {
        guard let store, case .project(let project) = scope else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let book = Codebook(projectID: project, title: Bilingual(trimmed))
        do {
            try await store.save(book)
            selectedID = book.id
            await reload()
            status = Status(message: "สร้าง “\(trimmed)” แล้ว — เพิ่มรหัสพร้อมนิยาม แล้วจึงเพิ่มช่วงข้อความ",
                            isError: false)
        } catch {
            status = Status(message: "บันทึกไม่สำเร็จ: \(error)", isError: true)
        }
    }

    public func addCode(name: String, definition: String, parentID: String?) async {
        guard let store, var book = selected else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        book.codes.append(Code(name: Bilingual(trimmed), definition: definition,
                               parentID: parentID))
        await save(book)
        _ = store
    }

    /// Puts a sentence from another screen on this one.
    ///
    /// The knowledge base owns what happened to an ingested transcript —
    /// including the refusals — and the person is looking at this screen when
    /// they press the button, so this is where the answer has to appear.
    public func report(_ status: Status?) {
        self.status = status
    }

    // MARK: - transcripts

    public func transcript(_ id: String) -> Transcript? {
        transcripts.first { $0.id == id }
    }

    /// The quotation behind a coded passage, taken from the transcript.
    ///
    /// `nil` when the transcript is not loaded or the offsets no longer fit it —
    /// which is the honest answer for a transcript that was corrected after
    /// coding, and the reason this goes through `TranscriptQuotation` rather
    /// than reading `unit.text`.
    public func quotation(for unit: CodingUnit) -> TranscriptQuotation? {
        guard let source = transcript(unit.documentID) else { return nil }
        return TranscriptQuotation.of(source, unit: unit)
    }

    /// Adds a transcript and turns its paragraphs into passages to code.
    ///
    /// One step rather than two because the offsets are the point: a passage
    /// typed in by hand has a range somebody made up, and a citation resting on
    /// a made-up range is exactly what P11.8's Done-when is about. Splitting the
    /// text the app is holding gives ranges that are true by construction.
    public func addTranscript(title: String, participantCode: String,
                              transcribedBy: String, text: String) async {
        guard let store, var book = selected, case .project(let project) = scope else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !body.isEmpty else { return }

        let code = participantCode.trimmingCharacters(in: .whitespaces)
        let transcript = Transcript(projectID: project, title: name,
                                    participantCode: code.isEmpty ? nil : code,
                                    transcribedBy: transcribedBy
                                        .trimmingCharacters(in: .whitespaces),
                                    text: body)
        do {
            try await store.save(transcript)
            let spans = transcript.paragraphs
            guard !spans.isEmpty else {
                status = Status(message: "ไม่พบย่อหน้าในบทถอดเทปนี้", isError: true)
                return
            }
            for span in spans {
                guard let quotation = TranscriptQuotation.of(transcript, at: span) else { continue }
                try await store.save(CodingUnit(documentID: transcript.id, range: span.range,
                                                text: quotation.text),
                                     codebook: book.id)
            }
            // The order transcripts were coded in is a claim the saturation curve
            // rests on, so it is recorded when a document first appears rather
            // than inferred later from row order.
            if !book.documentOrder.contains(transcript.id) {
                book.documentOrder.append(transcript.id)
                try await store.save(book)
            }
            await reload()
            status = Status(message: "เพิ่ม “\(name)” แล้ว — แบ่งเป็น \(spans.count) ช่วงตามย่อหน้า "
                            + "· ตำแหน่งของทุกช่วงอ้างกลับไปที่ข้อความจริง ไม่ใช่เลขที่พิมพ์เอง",
                            isError: false)
        } catch {
            status = Status(message: "บันทึกบทถอดเทปไม่สำเร็จ: \(error)", isError: true)
        }
    }

    // MARK: - coding

    /// Records this coder's decision about one passage.
    ///
    /// `codeID: nil` is "none of these codes apply", which is a decision and is
    /// stored as one — different from never having looked, which is the absence
    /// of a row (§20.3, and the reason κ can be computed at all).
    public func code(unit: CodingUnit, as codeID: String?) async {
        guard let store, let book = selected else { return }
        let name = coder.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            status = Status(message: "ใส่ชื่อผู้ลงรหัสก่อน — κ เป็นข้อความเกี่ยวกับคน "
                            + "การลงรหัสที่ไม่รู้ว่าใครลงจึงคำนวณอะไรไม่ได้", isError: true)
            return
        }
        do {
            try await store.save(CodeAssignment(unitID: unit.id, coder: name, codeID: codeID),
                                 codebook: book.id)
            await refresh()
        } catch {
            status = Status(message: "บันทึกการลงรหัสไม่สำเร็จ: \(error)", isError: true)
        }
    }

    private func save(_ book: Codebook) async {
        guard let store else { return }
        do {
            try await store.save(book)
            await reload()
        } catch {
            status = Status(message: "บันทึกไม่สำเร็จ: \(error)", isError: true)
        }
    }

    public func clearStatus() { status = nil }
}
