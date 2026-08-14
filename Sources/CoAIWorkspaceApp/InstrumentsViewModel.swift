import Foundation
import Observation
import AgentKit
import Instruments
import Persistence
import Observability

// ─────────────────────────────────────────────────────────────
// The data-collection tab's state (ARCHITECTURE §20.3, P11.2/P11.4).
//
// The Workbench's first sub-tab said "ยังไม่ได้ทำ — P11" until now, which was
// honest and useless. This is what makes it a place to work: draft an instrument,
// tie each question to what it measures, collect the expert ratings content
// validity needs, and try to publish — where the gate refuses and says why.
//
// Publishing produces a `PublishedInstrument`, which is the only thing M16 will
// ever accept (§20.6). Nothing here can construct one; it can only ask the gate.
// ─────────────────────────────────────────────────────────────

@MainActor
@Observable
public final class InstrumentsViewModel {
    public struct Status: Equatable {
        public var message: String
        public var isError: Bool
    }

    public private(set) var instruments: [Instrument] = []
    public private(set) var selectedID: String?
    public private(set) var ratings: [ExpertRating] = []
    public private(set) var problems: [BlueprintProblem] = []
    public private(set) var gate: InstrumentEvaluation?
    public private(set) var validity: ContentValidity?
    /// Set once the gate has been passed in this session. Serving the form is
    /// M16's job, and this module has no network.
    public private(set) var published: PublishedInstrument?
    /// The approval on record for the selected version, read back from the
    /// database rather than remembered. This is what makes an approved version
    /// still look approved after the tab has been left and come back to.
    public private(set) var approval: InstrumentApproval?
    public private(set) var status: Status?
    /// Why the last publish attempt failed, shown beside the button that made it
    /// — the header is a long scroll away from the bottom of this screen.
    public private(set) var refusal: String?

    private var store: InstrumentStore?
    private var scope: Scope = .central
    private let log = AppLog.logger("instruments-ui")

    public init() {}

    public var selected: Instrument? {
        instruments.first { $0.id == selectedID }
    }

    /// Whether the selected version has been through the gate. §20.6's first
    /// invariant is that editing a published instrument makes a new version — so
    /// once this is true, everything that changes the form is closed and the only
    /// way forward is "สร้างเวอร์ชันใหม่".
    public var isApproved: Bool { approval != nil }

    public func attach(store: InstrumentStore, scope: Scope) async {
        self.store = store
        self.scope = scope
        await reload()
    }

    public func select(_ id: String?) async {
        selectedID = id
        published = nil
        refusal = nil
        await refresh()
    }

    public func reload() async {
        guard let store, case .project(let project) = scope else {
            // §20.5 — collecting data from people needs ethics and a scope, and
            // General has neither. The Workbench does not offer this tab there.
            instruments = []
            selectedID = nil
            return
        }
        do {
            instruments = try await store.all(project: project)
            if selectedID == nil || !instruments.contains(where: { $0.id == selectedID }) {
                selectedID = instruments.first?.id
            }
            await refresh()
        } catch {
            log.error("loading instruments: \(error)")
            status = Status(message: "โหลดเครื่องมือไม่สำเร็จ: \(error)", isError: true)
        }
    }

    // MARK: - editing

    public func create(title: String) async {
        guard let store, case .project(let project) = scope else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let instrument = Instrument(projectID: project, title: Bilingual(trimmed))
        await save(instrument, note: "สร้าง “\(trimmed)” แล้ว — เพิ่มคำถามวิจัยและ construct ก่อนใส่ข้อคำถาม")
        selectedID = instrument.id
        await refresh()
        _ = store
    }

    /// Refuses an edit to a version that has already been approved, and says where
    /// to go instead. Checked once here rather than at every call site: this is the
    /// half of §20.6 invariant 1 that the type system cannot express, because
    /// `Instrument` stays editable by design until it passes.
    private func editable() -> Instrument? {
        guard let instrument = selected else { return nil }
        guard !isApproved else {
            status = Status(message: "เวอร์ชัน \(instrument.version) ผ่านประตูแล้ว จึงแก้ไม่ได้ — "
                            + "กด “สร้างเวอร์ชันใหม่” เพราะข้อมูลที่เก็บมาแล้วต้องยังตรงกับฟอร์มที่ใช้เก็บ",
                            isError: true)
            return nil
        }
        return instrument
    }

    public func addResearchQuestion(_ text: String) async {
        guard var instrument = editable() else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        instrument.researchQuestions.append(ResearchQuestion(text: Bilingual(trimmed)))
        await save(instrument)
    }

    public func addConstruct(name: String, definition: String, questionID: String) async {
        guard var instrument = editable() else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        instrument.constructs.append(Construct(name: Bilingual(trimmed),
                                               definition: definition,
                                               researchQuestionID: questionID))
        await save(instrument)
    }

    /// Adds a question. `constructID == nil` together with `demographic == false`
    /// is a legal thing to *save* and an illegal thing to publish — the blueprint
    /// reports it rather than the editor refusing it, because half-finished work
    /// has to be saveable (§20.3, design principle 2).
    public func addItem(prompt: String, kind: ItemKind,
                        constructID: String?, demographic: Bool) async {
        guard var instrument = editable() else { return }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let order = (instrument.items.map(\.order).max() ?? 0) + 1
        instrument.items.append(Item(prompt: Bilingual(trimmed), kind: kind,
                                     constructID: constructID,
                                     isDemographic: demographic, order: order))
        await save(instrument)
    }

    public func removeItem(_ id: String) async {
        guard var instrument = editable() else { return }
        instrument.items.removeAll { $0.id == id }
        await save(instrument)
    }

    public func setConsent(_ consent: ConsentText) async {
        guard var instrument = editable() else { return }
        instrument.consent = consent
        await save(instrument)
    }

    public func setEthics(_ ethics: EthicsRecord) async {
        guard var instrument = editable() else { return }
        instrument.ethics = ethics
        await save(instrument)
    }

    /// One expert's score for one item (§20.4). Recorded as its own row, so two
    /// experts scoring the same instrument cannot overwrite each other.
    public func rate(item: String, expert: String, congruence: Int, relevance: Int?) async {
        guard let store, let instrument = selected else { return }
        let name = expert.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            status = Status(message: "ต้องมีชื่อผู้เชี่ยวชาญ — คะแนนที่ไม่มีคนให้ ป้องกันตัวเองในสอบไม่ได้",
                            isError: true)
            return
        }
        do {
            try await store.save(ExpertRating(itemID: item, expert: name,
                                              congruence: congruence, relevance: relevance),
                                 instrument: instrument.id)
            await refresh()
        } catch {
            status = Status(message: "บันทึกคะแนนไม่สำเร็จ: \(error)", isError: true)
        }
    }

    /// The next version, for editing something already published (§20.6).
    public func newVersion() async {
        guard let instrument = selected else { return }
        let next = instrument.nextVersion()
        await save(next, note: "สร้างเวอร์ชัน \(next.version) — เวอร์ชันก่อนหน้าไม่ถูกแก้ ข้อมูลที่เก็บมาแล้วยังตรงกับฟอร์มที่ใช้เก็บ")
        selectedID = next.id
        published = nil
        refusal = nil
        await refresh()
    }

    // MARK: - the gate (§20.1 step 5)

    public func publish(by person: String) async {
        guard let store, let instrument = selected else { return }
        do {
            // The only producer of `PublishedInstrument`. If this throws, there is
            // no representation of this instrument that a server could serve.
            let approved = try InstrumentGate.approve(instrument, validity: validity, by: person)
            // Written down before it is announced: an approval nobody can read
            // back tomorrow is the same as no approval, and this is the one button
            // on the screen whose consequence cannot be undone.
            try await store.save(approved.approval)
            published = approved
            refusal = nil
            log.info("instrument \(instrument.id) v\(instrument.version) approved by \(person)")
            status = Status(message: "ผ่านประตูเครื่องมือแล้ว — เผยแพร่ได้ (การเสิร์ฟฟอร์มเป็นงานของ M16 ซึ่งยังไม่ได้ทำ)",
                            isError: false)
            await refresh()
        } catch {
            published = nil
            refusal = "\(error)"
            status = Status(message: "\(error)", isError: true)
        }
    }

    private func save(_ instrument: Instrument, note: String? = nil) async {
        guard let store else { return }
        var updated = instrument
        updated.updatedAt = Date()
        do {
            try await store.save(updated)
            await reload()
            if let note { status = Status(message: note, isError: false) }
        } catch {
            status = Status(message: "บันทึกไม่สำเร็จ: \(error)", isError: true)
        }
    }

    private func refresh() async {
        guard let store, let instrument = selected else {
            problems = []
            gate = nil
            validity = nil
            ratings = []
            approval = nil
            return
        }
        ratings = (try? await store.ratings(instrument: instrument.id)) ?? []
        approval = try? await store.approval(instrument: instrument.id)
        problems = Blueprint.problems(in: instrument)
        // Demographic items are left out: IOC scores an item against what it
        // claims to measure, and those claim nothing (§20.4).
        let reviewed = instrument.itemsUnderContentReview.map(\.id)
        // No ratings at all leaves validity `nil` rather than an empty pass: the
        // gate treats "nobody assessed it" as unmet, not as fine.
        validity = ratings.isEmpty
            ? nil
            : ContentValidity.assess(ratings: ratings, itemIDs: reviewed)
        gate = InstrumentGate.evaluate(instrument, validity: validity)
    }

    public func clearStatus() { status = nil }
}
