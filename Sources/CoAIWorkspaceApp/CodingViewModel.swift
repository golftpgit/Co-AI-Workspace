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

    /// Adds a passage to be coded.
    ///
    /// The range is where it sits in the transcript, so a quotation in chapter 4
    /// can be traced back to the passage rather than to the whole interview.
    public func addUnit(documentID: String, text: String, start: Int) async {
        guard let store, var book = selected else { return }
        let document = documentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !document.isEmpty, !trimmed.isEmpty else { return }
        do {
            try await store.save(CodingUnit(documentID: document,
                                            range: start..<(start + trimmed.count),
                                            text: trimmed),
                                 codebook: book.id)
            // The order transcripts were coded in is a claim the saturation curve
            // rests on, so it is recorded when a document first appears rather
            // than inferred later from row order.
            if !book.documentOrder.contains(document) {
                book.documentOrder.append(document)
                try await store.save(book)
            }
            await reload()
        } catch {
            status = Status(message: "บันทึกช่วงข้อความไม่สำเร็จ: \(error)", isError: true)
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
