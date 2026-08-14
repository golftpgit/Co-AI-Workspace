import SwiftUI
import AgentKit
import Instruments

// ─────────────────────────────────────────────────────────────
// The data-collection tab (ARCHITECTURE §20.3, §20.5, P11.2/P11.4).
//
// Laid out in the order the method runs, not the order the types were written:
// research questions → constructs → questions tied to them → consent and ethics →
// expert ratings → the gate. The gate is at the bottom because it is the thing
// that says whether any of the above is finished, and it lists what is missing by
// name rather than refusing silently.
//
// Everything is editable, including things the gate will reject: §20.3's design
// principle is that a person can change any layer, and a builder that refuses to
// save half-finished work is a builder people keep their real draft outside of.
// ─────────────────────────────────────────────────────────────

struct InstrumentsView: View {
    @Bindable var model: InstrumentsViewModel

    @State private var newTitle = ""
    @State private var newQuestion = ""
    @State private var newConstruct = ""
    @State private var newConstructDefinition = ""
    @State private var constructQuestionID: String?
    @State private var newItem = ""
    @State private var newItemKind = ItemKindChoice.likert5
    @State private var newItemConstruct: String?
    @State private var newItemDemographic = false
    @State private var expert = ""
    @State private var approver = ""
    @State private var consentDraft = ConsentDraft()
    @State private var ethicsDraft = EthicsDraft()
    /// Consent and ethics collapse to one line once saved, which is right until
    /// somebody needs to fix a typo in the contact address or the approval number.
    /// A page that can only be written once is a page people keep the real version
    /// of somewhere else (§20.3, design principle 2).
    @State private var editingConsent = false
    @State private var editingEthics = false

    /// The kinds offered in the picker. A subset by design: matrix, ranking and
    /// file upload exist in the model and need their own editors, and a picker
    /// that offers a type this screen cannot configure is a dead end.
    enum ItemKindChoice: String, CaseIterable, Identifiable {
        case likert5, likert7, single, multiple, openText, number, date
        var id: String { rawValue }

        var label: String {
            switch self {
            case .likert5: "Likert 5 ระดับ"
            case .likert7: "Likert 7 ระดับ"
            case .single: "เลือกตอบเดียว"
            case .multiple: "เลือกได้หลายข้อ"
            case .openText: "ข้อความเปิด"
            case .number: "ตัวเลข"
            case .date: "วันที่"
            }
        }

        var kind: ItemKind {
            switch self {
            case .likert5:
                .likert(levels: ["ไม่เห็นด้วยอย่างยิ่ง", "ไม่เห็นด้วย", "เฉย ๆ",
                                 "เห็นด้วย", "เห็นด้วยอย่างยิ่ง"].map { Bilingual($0) })
            case .likert7:
                .likert(levels: (1...7).map { Bilingual("ระดับ \($0)") })
            case .single: .single(options: [Bilingual("ตัวเลือก 1"), Bilingual("ตัวเลือก 2")])
            case .multiple: .multiple(options: [Bilingual("ตัวเลือก 1"),
                                               Bilingual("ตัวเลือก 2")], maximum: nil)
            case .openText: .openText(maximumLength: 1_000)
            case .number: .number(minimum: nil, maximum: nil)
            case .date: .date
            }
        }
    }

    struct ConsentDraft: Equatable {
        var purpose = ""
        var collected = ""
        var voluntary = ""
        var contact = ""
        var isReady: Bool {
            ![purpose, collected, voluntary, contact]
                .contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
    }

    struct EthicsDraft: Equatable {
        var isApproved = true
        var committee = ""
        var number = ""
        var reason = ""
        var declaredBy = ""

        init() {}

        /// Reopens a saved record for correction, with what it already says.
        init(_ record: EthicsRecord) {
            switch record {
            case .approved(let committee, let number, _, let by):
                isApproved = true
                self.committee = committee
                self.number = number
                declaredBy = by
            case .notHumanSubjects(let reason, let by):
                isApproved = false
                self.reason = reason
                declaredBy = by
            }
        }

        var isReady: Bool {
            guard !declaredBy.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            return isApproved
                ? ![committee, number].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }
                : !reason.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        HSplitView {
            list.frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let instrument = model.selected {
                        detail(instrument)
                    } else {
                        Text("ยังไม่มีเครื่องมือในโปรเจกต์นี้ — ตั้งชื่อทางซ้ายเพื่อเริ่มร่าง")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task { await model.reload() }
    }

    // MARK: - list

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("เครื่องมือเก็บข้อมูล").font(.subheadline).bold()
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()

            List {
                ForEach(model.instruments) { instrument in
                    Button {
                        Task { await model.select(instrument.id) }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(instrument.title.thai).font(.callout)
                            Text("เวอร์ชัน \(instrument.version) · \(instrument.items.count) ข้อ")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .fontWeight(model.selectedID == instrument.id ? .semibold : .regular)
                    .accessibilityLabel("เปิดเครื่องมือ \(instrument.title.thai) เวอร์ชัน \(instrument.version)")
                }
                if model.instruments.isEmpty {
                    Text("ยังไม่มีเครื่องมือ").font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()
            HStack {
                TextField("ชื่อเครื่องมือใหม่", text: $newTitle)
                    .textFieldStyle(.roundedBorder)
                Button("สร้าง") {
                    let title = newTitle
                    newTitle = ""
                    Task { await model.create(title: title) }
                }
                .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
            .padding(10)
        }
    }

    // MARK: - detail

    @ViewBuilder
    private func detail(_ instrument: Instrument) -> some View {
        HStack(spacing: 8) {
            Text(instrument.title.thai).font(.title3).bold()
            Text("เวอร์ชัน \(instrument.version)").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let status = model.status {
                Button { model.clearStatus() } label: {
                    Text(status.message)
                        .font(.caption)
                        .foregroundStyle(status.isError ? .red : .secondary)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 420, alignment: .trailing)
                }
                .buttonStyle(.plain)
                .accessibilityHint("ปิดข้อความนี้")
            }
        }

        if let approval = model.approval {
            // Said once at the top rather than only next to each disabled control:
            // the first question somebody has on opening an approved version is
            // why nothing can be typed into it.
            Label("\(approval.summary) — เวอร์ชันนี้แก้ไม่ได้แล้ว กด “สร้างเวอร์ชันใหม่” เพื่อแก้",
                  systemImage: "lock.fill")
                .font(.callout)
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        }

        // Everything that changes the form is closed once the gate has been
        // passed (§20.6 invariant 1); scoring and the gate itself stay open,
        // because a late expert rating is evidence about the version, not a
        // change to it.
        chainBox(instrument).disabled(model.isApproved)
        itemsBox(instrument).disabled(model.isApproved)
        ethicsBox(instrument).disabled(model.isApproved)
        validityBox(instrument)
        gateBox()
        if model.isApproved { fieldBox() }
        // Shown whenever there is anything to show, including after the server
        // has been stopped: the moment somebody most wants to look at what came
        // in is after they have closed the round.
        if !model.responseRows.isEmpty || !model.rounds.isEmpty {
            ResponsesBox(model: model, instrument: instrument)
        }
    }

    /// M16, and only once the gate has been passed (§20.7). There is no control
    /// here that could serve an unapproved instrument, because there is no value
    /// to serve — the button is absent rather than disabled, which is the same
    /// reason the server has no admin endpoints.
    @ViewBuilder
    private func fieldBox() -> some View {
        GroupBox("เปิดฟอร์มให้คนอื่นกรอก (เฉพาะในวงแลนนี้)") {
            VStack(alignment: .leading, spacing: 8) {
                if let serving = model.serving {
                    HStack {
                        Label(model.waveIsOpen ? "กำลังเปิดรับคำตอบ" : "ปิดรับคำตอบแล้ว",
                              systemImage: model.waveIsOpen ? "dot.radiowaves.left.and.right" : "hand.raised.fill")
                            .foregroundStyle(model.waveIsOpen ? Color.green : Color.orange)
                        Text("ได้รับแล้ว \(model.responses) ชุด")
                            .font(.callout).foregroundStyle(.secondary)
                            // Counted again every few seconds while the round is
                            // open. Driving this with a refresh button found the
                            // obvious thing: the one moment somebody watches this
                            // screen is while answers are arriving, and a number
                            // that only moves when you press something reads as a
                            // number that is not moving.
                            .task(id: model.waveIsOpen) {
                                while model.waveIsOpen, !Task.isCancelled {
                                    await model.refreshResponses()
                                    try? await Task.sleep(for: .seconds(3))
                                }
                            }
                        Spacer()
                        if model.waveIsOpen {
                            Button("ปิดรอบเก็บข้อมูล") { Task { await model.closeWave() } }
                        }
                        Button("หยุดเซิร์ฟเวอร์") { Task { await model.stopServing() } }
                    }
                    .controlSize(.small)

                    if serving.urls.isEmpty {
                        Text("เครื่องนี้ยังไม่ได้ต่อเครือข่ายที่คนอื่นเข้าถึงได้ — "
                             + "ต่อ wifi วงเดียวกับผู้ตอบก่อน")
                            .font(.callout).foregroundStyle(.orange)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("ให้ผู้ตอบเปิดลิงก์นี้ในเบราว์เซอร์:")
                                .font(.caption).foregroundStyle(.secondary)
                            // Several, because a laptop on wifi and ethernet has
                            // more than one address and only the person in the
                            // room knows which network the respondents are on.
                            ForEach(serving.urls, id: \.self) { url in
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(url, forType: .string)
                                } label: {
                                    Label(url, systemImage: "doc.on.doc")
                                        .font(.system(.callout, design: .monospaced))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("คัดลอกลิงก์ \(url)")
                                .accessibilityHint("คัดลอกไปยังคลิปบอร์ด")
                            }
                        }
                    }
                } else {
                    HStack {
                        Button("เปิดฟอร์มในวงแลน") { Task { await model.startServing() } }
                        Spacer()
                    }
                    .controlSize(.small)
                }

                Text("ค่าเริ่มต้นคือ LAN-only และไม่มี tunnel ในตัว — เปิดออกอินเทอร์เน็ตต้องเป็นการตั้งค่า "
                     + "router ของคุณเอง · เซิร์ฟเวอร์นี้ไม่มีหน้าจัดการใด ๆ ให้เข้าถึงจากเว็บ และอ่านคำตอบ "
                     + "กลับออกไปทางเว็บไม่ได้ · งานที่เดิมพันสูงยังควรใช้บริการที่ผ่านการตรวจความปลอดภัยแล้ว (R11)")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Research question → construct. The chain §20.3 asks for, built from the top
    /// so that by the time somebody writes a question there is something to tie it
    /// to.
    @ViewBuilder
    private func chainBox(_ instrument: Instrument) -> some View {
        GroupBox("คำถามวิจัยและสิ่งที่จะวัด") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(instrument.researchQuestions) { question in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("RQ: \(question.text.thai)").font(.callout)
                        ForEach(instrument.constructs.filter { $0.researchQuestionID == question.id }) { construct in
                            Text("   ↳ \(construct.name.thai) — วัดด้วย \(instrument.items(measuring: construct.id).count) ข้อ")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if instrument.researchQuestions.isEmpty {
                    Text("ยังไม่มีคำถามวิจัย — construct ต้องผูกกับคำถามวิจัยข้อใดข้อหนึ่ง")
                        .font(.callout).foregroundStyle(.secondary)
                }

                HStack {
                    TextField("คำถามวิจัยใหม่", text: $newQuestion)
                        .textFieldStyle(.roundedBorder)
                    Button("เพิ่ม RQ") {
                        let text = newQuestion
                        newQuestion = ""
                        Task { await model.addResearchQuestion(text) }
                    }
                    .disabled(newQuestion.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .controlSize(.small)

                if !instrument.researchQuestions.isEmpty {
                    HStack {
                        TextField("construct ที่จะวัด", text: $newConstruct)
                            .textFieldStyle(.roundedBorder)
                        TextField("นิยาม", text: $newConstructDefinition)
                            .textFieldStyle(.roundedBorder)
                        Picker("ตอบ RQ ข้อ", selection: $constructQuestionID) {
                            Text("— เลือก RQ —").tag(String?.none)
                            ForEach(instrument.researchQuestions) { question in
                                Text(question.text.thai).tag(String?.some(question.id))
                            }
                        }
                        .labelsHidden().frame(maxWidth: 200)
                        .accessibilityLabel("คำถามวิจัยที่ construct นี้ตอบ")
                        Button("เพิ่ม construct") {
                            guard let questionID = constructQuestionID else { return }
                            let name = newConstruct
                            let definition = newConstructDefinition
                            newConstruct = ""
                            newConstructDefinition = ""
                            Task {
                                await model.addConstruct(name: name, definition: definition,
                                                         questionID: questionID)
                            }
                        }
                        .disabled(constructQuestionID == nil
                                  || newConstruct.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func itemsBox(_ instrument: Instrument) -> some View {
        GroupBox("ข้อคำถาม") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(instrument.ordered) { item in
                    HStack(spacing: 6) {
                        Text("\(item.order).").font(.caption).foregroundStyle(.secondary)
                            .frame(width: 22, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.prompt.thai).font(.callout)
                            Text(label(for: item, in: instrument))
                                .font(.caption2)
                                .foregroundStyle(item.constructID == nil && !item.isDemographic
                                                 ? Color.orange : Color.secondary)
                        }
                        Spacer()
                        Button { Task { await model.removeItem(item.id) } } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("ลบข้อ \(item.prompt.thai)")
                    }
                }
                if instrument.items.isEmpty {
                    Text("ยังไม่มีข้อคำถาม").font(.callout).foregroundStyle(.secondary)
                }

                Divider()
                HStack {
                    TextField("ข้อคำถามใหม่", text: $newItem)
                        .textFieldStyle(.roundedBorder)
                    Picker("ชนิด", selection: $newItemKind) {
                        ForEach(ItemKindChoice.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().frame(maxWidth: 150)
                    .accessibilityLabel("ชนิดของข้อคำถาม")
                    Picker("วัด construct", selection: $newItemConstruct) {
                        Text("— ไม่ผูก —").tag(String?.none)
                        ForEach(instrument.constructs) { construct in
                            Text(construct.name.thai).tag(String?.some(construct.id))
                        }
                    }
                    .labelsHidden().frame(maxWidth: 170)
                    .accessibilityLabel("construct ที่ข้อนี้วัด")
                    Toggle("ข้อมูลพื้นฐาน", isOn: $newItemDemographic)
                        .toggleStyle(.checkbox)
                    Button("เพิ่มข้อ") {
                        let prompt = newItem
                        let kind = newItemKind.kind
                        let construct = newItemConstruct
                        let demographic = newItemDemographic
                        newItem = ""
                        Task {
                            await model.addItem(prompt: prompt, kind: kind,
                                                constructID: construct,
                                                demographic: demographic)
                        }
                    }
                    .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .controlSize(.small)

                Text("ข้อที่ไม่ผูก construct ต้องติดป้าย “ข้อมูลพื้นฐาน” — ข้อที่ไม่วัดอะไรเลยคือคอลัมน์ที่วิเคราะห์ไม่ได้ (§20.3) · บันทึกได้ แต่เผยแพร่ไม่ผ่าน")
                    .font(.caption2).foregroundStyle(.secondary)

                if !model.problems.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.problems) { problem in
                            Text("• " + problem.text)
                                .font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func ethicsBox(_ instrument: Instrument) -> some View {
        GroupBox("ความยินยอมและจริยธรรม") {
            VStack(alignment: .leading, spacing: 8) {
                if let consent = instrument.consent, consent.isComplete, !editingConsent {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("มีหน้าความยินยอมครบแล้ว · ติดต่อ \(consent.contact)")
                                .font(.callout)
                            Text(consent.purpose.thai).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("แก้ข้อความ") {
                            consentDraft = ConsentDraft(purpose: consent.purpose.thai,
                                                        collected: consent.whatIsCollected.thai,
                                                        voluntary: consent.voluntary.thai,
                                                        contact: consent.contact)
                            editingConsent = true
                        }
                        .controlSize(.small)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("วัตถุประสงค์ของการเก็บข้อมูล", text: $consentDraft.purpose)
                            .textFieldStyle(.roundedBorder)
                        TextField("เก็บข้อมูลอะไรบ้าง", text: $consentDraft.collected)
                            .textFieldStyle(.roundedBorder)
                        TextField("ข้อความเรื่องความสมัครใจและการถอนตัว", text: $consentDraft.voluntary)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            TextField("ช่องทางติดต่อผู้วิจัย", text: $consentDraft.contact)
                                .textFieldStyle(.roundedBorder)
                            Button("บันทึกความยินยอม") {
                                let draft = consentDraft
                                editingConsent = false
                                Task {
                                    await model.setConsent(ConsentText(
                                        purpose: Bilingual(draft.purpose),
                                        whatIsCollected: Bilingual(draft.collected),
                                        voluntary: Bilingual(draft.voluntary),
                                        contact: draft.contact))
                                }
                            }
                            .disabled(!consentDraft.isReady)
                        }
                    }
                    .controlSize(.small)
                }

                Divider()
                if let ethics = instrument.ethics, ethics.isComplete, !editingEthics {
                    HStack {
                        Text(ethics.summary).font(.callout)
                        Spacer()
                        Button("แก้บันทึก") {
                            ethicsDraft = EthicsDraft(ethics)
                            editingEthics = true
                        }
                        .controlSize(.small)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("แบบไหน", selection: $ethicsDraft.isApproved) {
                            Text("มีเลขรับรองจริยธรรม").tag(true)
                            Text("ประกาศว่าไม่เข้าข่ายวิจัยในมนุษย์").tag(false)
                        }
                        .pickerStyle(.radioGroup)
                        .accessibilityLabel("ชนิดของบันทึกจริยธรรม")
                        if ethicsDraft.isApproved {
                            HStack {
                                TextField("คณะกรรมการ", text: $ethicsDraft.committee)
                                    .textFieldStyle(.roundedBorder)
                                TextField("เลขรับรอง", text: $ethicsDraft.number)
                                    .textFieldStyle(.roundedBorder)
                            }
                        } else {
                            TextField("เหตุผลที่ไม่เข้าข่าย", text: $ethicsDraft.reason)
                                .textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            TextField("ชื่อผู้แจ้ง", text: $ethicsDraft.declaredBy)
                                .textFieldStyle(.roundedBorder)
                            Button("บันทึกจริยธรรม") {
                                let draft = ethicsDraft
                                editingEthics = false
                                Task {
                                    await model.setEthics(draft.isApproved
                                        ? .approved(committee: draft.committee,
                                                    number: draft.number,
                                                    date: Date(),
                                                    declaredBy: draft.declaredBy)
                                        : .notHumanSubjects(reason: draft.reason,
                                                            declaredBy: draft.declaredBy))
                                }
                            }
                            .disabled(!ethicsDraft.isReady)
                        }
                    }
                    .controlSize(.small)
                }
                Text("ทั้งสองอย่างตรวจที่ประตู ไม่ใช่ที่หน้าจอ — หน้าจอที่ตรวจเองคือหน้าจอที่ทางเข้าอื่นข้ามได้ (§20.5)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Expert ratings, one row per item. §20.4's IOC in the form a panel actually
    /// fills in: +1 congruent, 0 unsure, −1 not congruent.
    @ViewBuilder
    private func validityBox(_ instrument: Instrument) -> some View {
        GroupBox("ความตรงเชิงเนื้อหา (ผู้เชี่ยวชาญให้คะแนน)") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("ชื่อผู้เชี่ยวชาญที่กำลังให้คะแนน", text: $expert)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    Text(model.validity?.summary ?? "ยังไม่มีผลประเมิน")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .controlSize(.small)

                // Demographic items are not on this list on purpose: IOC scores an
                // item against what it claims to measure, and those claim nothing
                // (§20.4). Asking a panel to score them would have made the gate
                // unpassable until somebody invented a number.
                ForEach(instrument.itemsUnderContentReview) { item in
                    HStack(spacing: 6) {
                        Text(item.prompt.thai).font(.caption)
                            .frame(width: 240, alignment: .leading).lineLimit(1)
                        ForEach([1, 0, -1], id: \.self) { score in
                            Button(score == 1 ? "+1" : (score == 0 ? "0" : "−1")) {
                                let name = expert
                                Task {
                                    await model.rate(item: item.id, expert: name,
                                                     congruence: score,
                                                     relevance: score == 1 ? 4 : (score == 0 ? 3 : 1))
                                }
                            }
                            .controlSize(.mini)
                            .disabled(expert.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityLabel("ให้คะแนน \(score) กับข้อ \(item.prompt.thai)")
                        }
                        if let verdict = model.validity?.items.first(where: { $0.itemID == item.id }) {
                            Text(verdict.ioc.map { String(format: "IOC %.2f", $0) } ?? "ยังไม่มีคะแนน")
                                .font(.caption2)
                                .foregroundStyle(verdict.passes ? Color.green : Color.orange)
                            Text("\(verdict.raters) คน").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                if instrument.itemsUnderContentReview.isEmpty && !instrument.items.isEmpty {
                    Text("ทุกข้อในแบบสอบถามนี้เป็นข้อมูลพื้นฐาน จึงไม่มีข้อให้ผู้เชี่ยวชาญประเมินความตรง")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text("IOC ≥ 0.50 ต่อข้อ · I-CVI ≥ 0.78 · S-CVI/Ave ≥ 0.90 · ผู้เชี่ยวชาญอย่างน้อย "
                     + "\(ContentValidity.minimumPanel) คน — เกณฑ์ตามตำรา ปรับในหน้าจอไม่ได้โดยตั้งใจ "
                     + "· ข้อที่ติดป้าย “ข้อมูลพื้นฐาน” ไม่ต้องประเมิน เพราะไม่ได้อ้างว่าวัดอะไร")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func gateBox() -> some View {
        GroupBox("ประตูก่อนเก็บข้อมูล") {
            VStack(alignment: .leading, spacing: 6) {
                if let gate = model.gate {
                    ForEach(Array(gate.conditions.enumerated()), id: \.offset) { _, condition in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: condition.satisfied
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(condition.satisfied ? Color.green : Color.orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(condition.text).font(.callout)
                                if let detail = condition.detail {
                                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                HStack {
                    TextField("ชื่อผู้อนุมัติ", text: $approver)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                    Button("เผยแพร่เครื่องมือ") {
                        let person = approver
                        Task { await model.publish(by: person) }
                    }
                    .disabled(approver.trimmingCharacters(in: .whitespaces).isEmpty
                              || model.isApproved)
                    Button("สร้างเวอร์ชันใหม่") { Task { await model.newVersion() } }
                    Spacer()
                }
                .controlSize(.small)

                if let approval = model.approval {
                    Text("\(approval.summary) · \(approval.validity)")
                        .font(.callout).foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Beside the button, not only in the header: this box is at the
                // bottom of a page that scrolls, and an answer the presser has to
                // scroll up to find reads as "nothing happened".
                if let refusal = model.refusal {
                    Text(refusal)
                        .font(.callout).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("เครื่องมือที่ยังไม่ผ่านประตูนี้ **ไม่มีรูปแบบที่เซิร์ฟเวอร์รับได้เลย** — ไม่ใช่กฎที่ต้องจำ แต่เป็นสิ่งที่คอมไพล์ไม่ผ่าน (§20.6)")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func label(for item: Item, in instrument: Instrument) -> String {
        var parts = [item.kind.label]
        if let constructID = item.constructID,
           let construct = instrument.constructs.first(where: { $0.id == constructID }) {
            parts.append("วัด \(construct.name.thai)")
        } else if item.isDemographic {
            parts.append("ข้อมูลพื้นฐาน")
        } else {
            parts.append("ยังไม่ผูกกับอะไร — เผยแพร่ไม่ผ่าน")
        }
        return parts.joined(separator: " · ")
    }
}
