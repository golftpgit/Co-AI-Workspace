import Foundation
import Observation
import AgentKit
import Config
import Instruments
import Persistence
import Observability
import FieldServer
import OLTP
import Linkage
import Analysis

// ─────────────────────────────────────────────────────────────
// The data-collection tab's state (ARCHITECTURE §20.3, P11.2/P11.4).
//
// The Workbench's first sub-tab said "ยังไม่ได้ทำ — P11" until now, which was
// honest and useless. This is what makes it a place to work: draft an instrument,
// tie each question to what it measures, collect the expert ratings content
// validity needs, publish — where the gate refuses and says why — and then open
// the form to the people who are going to answer it.
//
// Publishing produces a `PublishedInstrument`, which is the only thing M16 will
// ever accept (§20.6). Nothing here can construct one; it can only ask the gate.
// That is why the "open the form" controls are absent rather than disabled until
// a version has passed: there is no value to hand the server.
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
    /// Set once the gate has been passed in this session. The only value M16
    /// will accept, and the only one the gate produces.
    public private(set) var published: PublishedInstrument?
    /// The approval on record for the selected version, read back from the
    /// database rather than remembered. This is what makes an approved version
    /// still look approved after the tab has been left and come back to.
    public private(set) var approval: InstrumentApproval?
    public private(set) var status: Status?
    /// Why the last publish attempt failed, shown beside the button that made it
    /// — the header is a long scroll away from the bottom of this screen.
    public private(set) var refusal: String?

    // ── M16, the other half of the tab (§20.7) ──
    /// Where the form is reachable, once it is being served. `nil` means the
    /// server is not running — which is the default, and the only state in which
    /// nothing outside this machine can reach the app.
    public private(set) var serving: ServingAddress?
    public private(set) var waveIsOpen = false
    public private(set) var responses = 0
    /// The version being served. Held separately from `selected` because the
    /// server keeps serving what it started with even if the list selection
    /// moves — the respondent's form must not change under them.
    public private(set) var servingVersion: Int?

    // ── the answers themselves (§19.17, P11.6c/P11.7) ──
    /// One respondent per row, in the order the answers arrived.
    public private(set) var responseRows: [ResponseRow] = []
    /// Every round for the selected version, newest first.
    public private(set) var rounds: [WaveRecord] = []
    /// What the last pull into the analytical store produced (§19.17).
    public private(set) var materialized: MaterializedResponses?

    // ── who answered (§20.7, P11.7b) ──
    public private(set) var participants: [Participant] = []
    public private(set) var attrition: [Attrition] = []
    /// The identity behind a code, only while somebody is looking at it. Never
    /// stored on this object beyond the moment: a screen that keeps a resolved
    /// name around is a screen that shows it to whoever walks past next.
    public private(set) var revealed: (code: String, identity: String)?

    /// A respondent's answers, ready to be drawn as a row: the values that are
    /// current, each still carrying whatever it was before somebody corrected it.
    public struct ResponseRow: Identifiable, Equatable {
        public let submission: SubmissionRecord
        /// Keyed by item id, so a row can be drawn against the instrument's own
        /// question order rather than whatever order the answers came back in.
        public let answers: [String: ResolvedAnswer]
        public var id: String { submission.id }
    }

    private var store: InstrumentStore?
    private var responseStore: ResponseStore?
    private var scope: Scope = .central
    private var paths: AppPaths?
    private var spans: (any SpanSink)?
    private var host: FieldServerHost?
    private var analysis: AnalysisStore?
    private var linkage: LinkageStore?
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

    public func attach(store: InstrumentStore, scope: Scope,
                       paths: AppPaths, analysis: AnalysisStore? = nil,
                       spans: (any SpanSink)? = nil) async {
        self.analysis = analysis
        self.store = store
        self.scope = scope
        self.paths = paths
        self.spans = spans
        // A different project is a different answer database — and a different
        // linkage file, with a different key. Dropping both handles here is what
        // stops one project's responses being drawn under another's instrument,
        // and one study's codes being resolved with another study's key.
        self.responseStore = nil
        self.linkage = nil
        self.revealed = nil
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
            status = Status(message: "ผ่านประตูเครื่องมือแล้ว — เปิดฟอร์มให้คนอื่นกรอกได้แล้วจากกล่องด้านล่าง",
                            isError: false)
            await refresh()
        } catch {
            published = nil
            refusal = "\(error)"
            status = Status(message: "\(error)", isError: true)
        }
    }

    // MARK: - M16: opening the form to other people (§20.7)

    /// Starts serving the version that passed the gate.
    ///
    /// Takes `published` from this session or rebuilds nothing: the argument is a
    /// `PublishedInstrument`, so an instrument that has not been approved cannot
    /// be passed here — not because this method checks, but because there is no
    /// such value to pass (§20.6 invariant 2).
    public func startServing(port: UInt16 = 8_760) async {
        guard let paths, case .project(let project) = scope else { return }
        var approvedNow = published
        if approvedNow == nil { approvedNow = await reapprove() }
        guard let approved = approvedNow else {
            status = Status(message: "ต้องผ่านประตูก่อนจึงจะเปิดฟอร์มให้คนอื่นกรอกได้ — "
                            + "กรอกชื่อผู้อนุมัติแล้วกด “เผยแพร่เครื่องมือ”", isError: true)
            return
        }
        do {
            let projectPaths = paths.project(project)
            try projectPaths.createDirectories()
            let responses = try await ResponseStore(path: projectPaths.responsesDatabase)
            let host = FieldServerHost(store: responses, spans: spans)
            serving = try await host.start(serving: approved, port: port)
            self.host = host
            // Read back rather than assumed: starting may have *resumed* a round
            // that was already open, and it will refuse to reopen one that was
            // closed. Either way the screen shows what the database says.
            waveIsOpen = await host.currentWave?.isOpen ?? false
            servingVersion = approved.instrument.version
            await refreshResponses()
            status = Status(message: "เปิดฟอร์มแล้วในวงแลนนี้เท่านั้น — "
                            + "คนอื่นในเครือข่ายเดียวกันเปิดลิงก์แล้วกรอกได้ · ไม่มีทางเข้าจากอินเทอร์เน็ต",
                            isError: false)
        } catch {
            status = Status(message: "เปิดเซิร์ฟเวอร์ไม่สำเร็จ: \(error)", isError: true)
        }
    }

    /// Closes the round but leaves the listener up for a moment, so a page
    /// somebody left open gets "this round is closed" rather than a connection
    /// error they would read as a network problem and retry.
    public func closeWave() async {
        guard let host else { return }
        await host.closeWave()
        waveIsOpen = false
        await refreshResponses()
        status = Status(message: "ปิดรอบเก็บข้อมูลแล้ว — คำตอบที่ส่งเข้ามาหลังจากนี้ถูกปฏิเสธที่ endpoint "
                        + "ไม่ใช่แค่ซ่อนปุ่มบนหน้าเว็บ", isError: false)
    }

    /// Stops listening. The round stays open unless somebody closed it — shutting
    /// the laptop is not "we have finished collecting", and saying otherwise on
    /// this screen would be the app claiming a closing date nobody chose.
    public func stopServing() async {
        guard let host else { return }
        let stillOpen = await host.currentWave?.isOpen ?? false
        await host.stop()
        self.host = nil
        serving = nil
        waveIsOpen = false
        servingVersion = nil
        await loadResponses()
        status = Status(message: stillOpen
                        ? "ปิดเซิร์ฟเวอร์แล้ว — รอบเก็บข้อมูลยังเปิดอยู่ เปิดเซิร์ฟเวอร์ใหม่แล้วเก็บต่อรอบเดิมได้"
                        : "ปิดเซิร์ฟเวอร์แล้ว", isError: false)
    }

    public func refreshResponses() async {
        if let host { responses = await host.responseCount() }
        await loadResponses()
    }

    // MARK: - reading the answers (§19.17's "responses" page)

    /// Opens the project's answer database on demand. Reading answers must not
    /// require the server to be running: the moment somebody most wants to look
    /// at what came in is after they have closed the round and stopped serving.
    private func answerStore() async -> ResponseStore? {
        if let responseStore { return responseStore }
        guard let paths, case .project(let project) = scope else { return nil }
        let projectPaths = paths.project(project)
        try? projectPaths.createDirectories()
        responseStore = try? await ResponseStore(path: projectPaths.responsesDatabase)
        return responseStore
    }

    public func loadResponses() async {
        guard let instrument = selected, let store = await answerStore() else {
            responseRows = []
            rounds = []
            return
        }
        do {
            rounds = try await store.waves(instrument: instrument.id,
                                           version: instrument.version)
            responses = try await store.submissionCount(instrument: instrument.id,
                                                        version: instrument.version)
            let submissions = try await store.submissions(instrument: instrument.id,
                                                          version: instrument.version)
            let answers = try await store.answers(instrument: instrument.id,
                                                  version: instrument.version)
            let bySubmission = Dictionary(grouping: answers, by: \.submissionID)
            await recordResponses(submissions)
            await loadParticipants()
            responseRows = submissions.map { submission in
                let keyed = Dictionary(
                    (bySubmission[submission.id] ?? []).map { ($0.itemID, $0) },
                    uniquingKeysWith: { first, _ in first })
                return ResponseRow(submission: submission, answers: keyed)
            }
        } catch {
            log.error("loading responses: \(error)")
            responseRows = []
        }
    }

    /// Records a change to an answer. The row that arrived is never touched
    /// (§19.17 invariant 2) — this writes a correction beside it, and the screen
    /// then shows the corrected value with a mark and the original underneath.
    public func correct(submission: String, item: String, previous: String,
                        to newText: String, reason: String, by person: String) async {
        guard let store = await answerStore() else { return }
        do {
            try await store.correct(Correction(submissionID: submission, itemID: item,
                                               previousText: previous, newText: newText,
                                               reason: reason, correctedBy: person))
            await loadResponses()
            status = Status(message: "บันทึกการแก้ค่าแล้ว — ค่าเดิมยังอยู่ และดูได้จากช่องนั้น",
                            isError: false)
        } catch {
            status = Status(message: "\(error)", isError: true)
        }
    }

    /// Re-derives the approval for a version that passed the gate in an earlier
    /// session. The record says it passed; the servable value has to come from
    /// the gate again, because the gate is the only producer there is.
    private func reapprove() async -> PublishedInstrument? {
        guard let instrument = selected, let approval, approval.version == instrument.version
        else { return nil }
        return try? InstrumentGate.approve(instrument, validity: validity,
                                           by: approval.approvedBy, at: approval.approvedAt)
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
            responseRows = []
            rounds = []
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
        await loadResponses()
    }

    /// Pulls this version's answers into the project's analytical store, so the
    /// notebook can reach them (§19.17).
    ///
    /// The app pulls; M16 never pushes. That direction is what keeps a web
    /// request unable to touch DuckDB, and it is why this button lives here
    /// rather than anywhere near the server.
    public func materialize() async {
        guard let instrument = selected, let analysis,
              let responses = await answerStore() else {
            status = Status(message: "ยังเปิดฐานข้อมูลวิเคราะห์ของโปรเจกต์นี้ไม่ได้", isError: true)
            return
        }
        do {
            let prompts = Dictionary(instrument.items.map { ($0.id, $0.prompt.thai) },
                                     uniquingKeysWith: { first, _ in first })
            let result = try await ResponseMaterializer(reading: responses, into: analysis,
                                                        spans: spans)
                .materialize(instrument: instrument.id, version: instrument.version,
                             prompts: prompts)
            materialized = result
            status = Status(message: "ส่งเข้าตาราง \(result.table) แล้ว — \(result.rows) แถว "
                            + "จาก \(result.submissions) ชุด"
                            + (result.corrections > 0
                               ? " · มี \(result.corrections) ค่าที่ถูกแก้หลังเก็บ (คอลัมน์ was_corrected)"
                               : ""),
                            isError: false)
        } catch {
            status = Status(message: "ส่งเข้าฐานข้อมูลวิเคราะห์ไม่สำเร็จ: \(error)", isError: true)
        }
    }

    // MARK: - participants (§20.7)

    /// Opens the project's linkage file on demand — a different file from the
    /// answers, with a key of its own (§20.7).
    private func linkageStore() async -> LinkageStore? {
        if let linkage { return linkage }
        guard let paths, case .project(let project) = scope else { return nil }
        let projectPaths = paths.project(project)
        try? projectPaths.createDirectories()
        linkage = try? await LinkageStore(path: projectPaths.linkageDatabase,
                                          project: project.rawValue,
                                          keys: KeychainLinkageKeys(),
                                          spans: spans)
        return linkage
    }

    public func loadParticipants() async {
        guard let store = await linkageStore() else {
            participants = []
            attrition = []
            return
        }
        participants = (try? await store.participants()) ?? []
        attrition = (try? await store.attrition()) ?? []
    }

    /// Registers a person and gives back the code that stands for them.
    public func enrol(identity: String) async {
        guard let store = await linkageStore() else {
            status = Status(message: "เปิดไฟล์ตัวตนของโปรเจกต์นี้ไม่ได้ — "
                            + "อาจเข้าถึง Keychain ไม่ได้ ซึ่งถูกต้องกว่าการเก็บโดยไม่เข้ารหัส",
                            isError: true)
            return
        }
        do {
            let participant = try await store.enrol(identity: identity)
            await loadParticipants()
            status = Status(message: "ลงทะเบียนแล้ว — รหัสของผู้เข้าร่วมคนนี้คือ \(participant.code) "
                            + "· ส่งลิงก์ที่ลงท้ายด้วย ?code=\(participant.code) ให้เขา",
                            isError: false)
        } catch {
            status = Status(message: "\(error)", isError: true)
        }
    }

    /// Invites everybody enrolled to the round that is open now.
    public func inviteAllToCurrentWave() async {
        guard let store = await linkageStore(), let host,
              let wave = await host.currentWave, wave.isOpen else {
            status = Status(message: "ต้องเปิดรอบเก็บข้อมูลก่อนจึงจะเชิญผู้เข้าร่วมเข้ารอบได้",
                            isError: true)
            return
        }
        do {
            try await store.invite(participants.map(\.code), to: wave.id)
            await loadParticipants()
            status = Status(message: "เชิญผู้เข้าร่วม \(participants.count) คนเข้ารอบนี้แล้ว — "
                            + "ตัวเลขที่ตอบกลับจะขึ้นเองเมื่อคำตอบเข้ามา", isError: false)
        } catch {
            status = Status(message: "\(error)", isError: true)
        }
    }

    /// Turns a code back into a person, behind a reason and a name — both of
    /// which go into the audit span the store writes (§20.7 invariant 3).
    public func reveal(code: String, reason: String, by person: String) async {
        guard !reason.trimmingCharacters(in: .whitespaces).isEmpty,
              !person.trimmingCharacters(in: .whitespaces).isEmpty else {
            status = Status(message: "ต้องบอกเหตุผลและชื่อคนที่เปิดดู — การเปิดดูตัวตนถูกบันทึกทุกครั้ง",
                            isError: true)
            return
        }
        guard let store = await linkageStore() else { return }
        do {
            if let identity = try await store.resolve(code: code, reason: reason, by: person) {
                revealed = (code, identity)
            } else {
                status = Status(message: "ไม่พบรหัส \(code) ในโปรเจกต์นี้", isError: true)
            }
        } catch {
            status = Status(message: "\(error)", isError: true)
        }
    }

    public func hideRevealed() { revealed = nil }

    /// Marks the codes that answered as having answered, so attrition is the
    /// difference between who was asked and who replied rather than a guess.
    ///
    /// Done here, in the app, and never by the server: M16 stores a code because
    /// a code is not an identity, and has no way to reach the file where one
    /// becomes a person.
    private func recordResponses(_ rows: [SubmissionRecord]) async {
        guard let store = await linkageStore() else { return }
        for row in rows {
            guard let code = row.participantCode else { continue }
            try? await store.recordResponse(code: code, wave: row.waveID, at: row.receivedAt)
        }
    }

    public func clearStatus() { status = nil }
}
