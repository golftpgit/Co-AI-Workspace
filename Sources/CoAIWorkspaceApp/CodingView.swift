import SwiftUI
import AgentKit
import Instruments

// ─────────────────────────────────────────────────────────────
// Coding transcripts, and what the coding says about itself
// (ARCHITECTURE §20.3, P11.8).
//
// The quantitative tab is about designing an instrument before anybody answers
// it. This one is the other order: the text exists, and the categories are built
// out of it. So the screen reads downwards in the order the work happens —
// codebook, passages, coding, and then the two things a methods section has to
// report about them.
//
// κ and the saturation curve are computed as you look at them rather than behind
// a button. They are cheap here (counting, not a hundred eigen-decompositions),
// and a reliability figure that only appears when asked for is one people ask
// for at the end, which is the one moment it is too late to act on.
// ─────────────────────────────────────────────────────────────

struct CodingView: View {
    @Bindable var model: CodingViewModel
    /// Sending a transcript to the knowledge base (§20.9, P11.8). A closure
    /// rather than a second view model on this screen: the knowledge base is
    /// owned by its own screen, and two models over one index would be two
    /// answers to "what is in the library".
    var ingest: ((Transcript) async -> Void)?
    @State private var ingesting: String?

    @State private var newBook = ""
    @State private var newCode = ""
    @State private var newCodeDefinition = ""
    @State private var newCodeParent: String?
    @State private var newTranscriptTitle = ""
    @State private var newTranscriptCode = ""
    @State private var newTranscriptBy = ""
    @State private var newTranscriptText = ""

    var body: some View {
        HSplitView {
            list.frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let book = model.selected {
                        detail(book)
                    } else {
                        Text("ยังไม่มีสมุดรหัสในโปรเจกต์นี้ — ตั้งชื่อทางซ้ายเพื่อเริ่ม "
                             + "· สมุดรหัสคือชุดหมวดที่ใช้อ่านบทถอดเทป และเป็นสิ่งที่ κ วัดความสอดคล้องของมัน")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Space.box)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task { await model.reload() }
    }

    // MARK: - list

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("สมุดรหัส").font(.subheadline).bold()
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()

            List {
                ForEach(model.codebooks) { book in
                    Button {
                        Task { await model.select(book.id) }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(book.title.thai).font(.callout)
                            Text("\(book.codes.count) รหัส · \(book.documentOrder.count) ฉบับ")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .fontWeight(model.selectedID == book.id ? .semibold : .regular)
                    .accessibilityLabel("เปิดสมุดรหัส \(book.title.thai)")
                }
                if model.codebooks.isEmpty {
                    Text("ยังไม่มีสมุดรหัส").font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()
            HStack {
                TextField("ชื่อสมุดรหัสใหม่", text: $newBook)
                    .textFieldStyle(.roundedBorder)
                Button("สร้าง") {
                    let title = newBook
                    newBook = ""
                    Task { await model.createCodebook(title: title) }
                }
                .disabled(newBook.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
            .padding(Space.box)
        }
    }

    // MARK: - detail

    @ViewBuilder
    private func detail(_ book: Codebook) -> some View {
        HStack(spacing: 8) {
            Text(book.title.thai).font(.title3).bold()
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

        coderBox()
        codesBox(book)
        unitsBox(book)
        if model.reliability != nil || model.saturation != nil { reportBox() }
    }

    /// Who is coding. First, and unmissable, because every row written below it
    /// carries this name into a κ.
    @ViewBuilder
    private func coderBox() -> some View {
        GroupBox("ผู้ลงรหัสที่กำลังทำอยู่") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("ชื่อผู้ลงรหัส", text: $model.coder)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                        .accessibilityLabel("ชื่อผู้ลงรหัสที่กำลังทำอยู่")
                    if !model.progress.isEmpty {
                        Text(model.progress
                            .map { "\($0.coder) \($0.done)/\(model.units.count)" }
                            .joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .controlSize(.small)
                Text("ไม่ถูกจำข้ามครั้ง และไม่มีค่าตั้งต้นโดยตั้งใจ — κ เป็นข้อความเกี่ยวกับคน "
                     + "และวิธีที่การศึกษาความสอดคล้องพังบ่อยที่สุดคือคนที่สองมานั่งลงกับเครื่องที่ยังเป็นชื่อคนแรก")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - the codes

    @ViewBuilder
    private func codesBox(_ book: Codebook) -> some View {
        GroupBox("รหัส (\(book.codes.count))") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(book.codes) { code in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            if let parent = code.parentID, let name = book.code(parent)?.name.thai {
                                Text("\(name) ›").font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(code.name.thai).font(.callout)
                            Spacer()
                        }
                        Text(code.definition.isEmpty ? "ยังไม่มีนิยาม" : code.definition)
                            .font(.caption2)
                            .foregroundStyle(code.definition.isEmpty ? Color.orange : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if book.codes.isEmpty {
                    Text("ยังไม่มีรหัส — รหัสตัวแรกมักมาจากการอ่านบทถอดเทปฉบับแรกจนจบ")
                        .font(.callout).foregroundStyle(.secondary)
                }

                HStack {
                    TextField("ชื่อรหัส", text: $newCode)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                    TextField("นิยาม — อะไรนับ อะไรไม่นับ", text: $newCodeDefinition)
                        .textFieldStyle(.roundedBorder)
                    Picker("อยู่ใต้", selection: $newCodeParent) {
                        Text("— รหัสเปิด —").tag(String?.none)
                        ForEach(book.codes) { code in
                            Text(code.name.thai).tag(String?.some(code.id))
                        }
                    }
                    .labelsHidden().frame(maxWidth: 150)
                    .accessibilityLabel("รหัสแม่ของรหัสนี้")
                    Button("เพิ่มรหัส") {
                        let name = newCode
                        let definition = newCodeDefinition
                        let parent = newCodeParent
                        newCode = ""
                        newCodeDefinition = ""
                        Task { await model.addCode(name: name, definition: definition,
                                                   parentID: parent) }
                    }
                    .disabled(newCode.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .controlSize(.small)

                ForEach(book.problems, id: \.text) { problem in
                    Label(problem.text, systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - the passages, and coding them

    @ViewBuilder
    private func unitsBox(_ book: Codebook) -> some View {
        GroupBox("ช่วงข้อความ (\(model.units.count))") {
            VStack(alignment: .leading, spacing: 8) {
                Text("ช่วงข้อความถูกกำหนดครั้งเดียวแล้วทุกคนลงรหัสชุดเดียวกัน — "
                     + "ผู้ลงรหัสสองคนที่ต่างคนต่างเลือกว่าช่วงเริ่มตรงไหน ไม่ได้เห็นตรงกันหรือไม่ตรงกันกับอะไรที่เทียบได้")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(model.units) { unit in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(model.transcript(unit.documentID)?.title ?? unit.documentID)
                                .font(.caption2).foregroundStyle(.secondary)
                            // Taken from the transcript, not read off the unit's
                            // own copy: the two can drift, and only one of them
                            // is what the participant said.
                            Text(model.quotation(for: unit)?.text ?? unit.text)
                                .font(.caption).lineLimit(2)
                            Spacer()
                            if let quotation = model.quotation(for: unit) {
                                Text("ช่วง \(quotation.span.start)–\(quotation.span.end)")
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .accessibilityLabel("ตำแหน่งในบทถอดเทป "
                                        + "\(quotation.span.start) ถึง \(quotation.span.end)")
                            } else {
                                Text("อ้างกลับไม่ได้")
                                    .font(.caption2).foregroundStyle(.orange)
                                    .help("ตำแหน่งนี้ไม่ตรงกับบทถอดเทปแล้ว — "
                                          + "อาจถูกแก้หลังลงรหัส · ยกมาอ้างไม่ได้จนกว่าจะแบ่งช่วงใหม่")
                            }
                        }
                        HStack(spacing: 4) {
                            ForEach(book.codes) { code in
                                codeButton(unit: unit, code: code.id, label: code.name.thai)
                            }
                            codeButton(unit: unit, code: nil, label: "ไม่เข้ารหัสไหน")
                            Spacer()
                        }
                        .controlSize(.mini)
                    }
                    Divider()
                }
                if model.units.isEmpty {
                    Text("ยังไม่มีช่วงข้อความ").font(.callout).foregroundStyle(.secondary)
                }

                // The transcripts themselves, and the one thing P11.8 could not
                // do until now: put one in the knowledge base. `TranscriptIngest`
                // and its tests have been ready since P11.8 and nothing called
                // them, which made the chunks-with-spans a capability the app
                // did not have.
                if !model.transcripts.isEmpty {
                    Divider()
                    Text("บทถอดเทปในโครงการนี้").font(.callout).fontWeight(.medium)
                    ForEach(model.transcripts) { transcript in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(transcript.title).font(.callout)
                                // Not `\(transcript.participantCode)` — it is
                                // optional, and interpolating it drew
                                // `Optional("P-7QK2")` on screen. A transcript
                                // with no code is also an ordinary thing (§20.7
                                // asks for a code, not for every study to have
                                // one), so it says that instead of nothing.
                                Text("\(transcript.paragraphs.count) ย่อหน้า · "
                                     + (transcript.participantCode.map { "รหัสผู้เข้าร่วม \($0)" }
                                        ?? "ยังไม่ได้ใส่รหัสผู้เข้าร่วม"))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if ingesting == transcript.id {
                                ProgressView().controlSize(.small)
                            } else if let ingest {
                                Button("ส่งเข้าคลังความรู้") {
                                    ingesting = transcript.id
                                    Task {
                                        await ingest(transcript)
                                        ingesting = nil
                                    }
                                }
                                .controlSize(.small)
                                .accessibilityLabel("ส่ง \(transcript.title) เข้าคลังความรู้ของโครงการ")
                            }
                        }
                    }
                    Text("แต่ละส่วนที่เข้าคลังพกช่วงข้อความของตัวเองไป — ผลค้นจึงอ้างกลับไปที่ย่อหน้า "
                         + "ไม่ใช่อ้างทั้งบทสัมภาษณ์สองชั่วโมง · ส่งซ้ำได้ ระบบจะแทนที่ของเดิม "
                         + "ไม่ใช่เก็บไว้ทั้งสองรุ่น")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                }

                // A transcript goes in whole and is split into passages here,
                // rather than passages being typed in one at a time. The offsets
                // are the reason: a passage typed by hand has a range somebody
                // invented, and P11.8's promise is that a citation points back
                // into the real text.
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("ชื่อบทถอดเทป (เช่น INT-01)", text: $newTranscriptTitle)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 170)
                        TextField("รหัสผู้เข้าร่วม (ไม่ใช่ชื่อ)", text: $newTranscriptCode)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 150)
                        TextField("ผู้ถอดเทป", text: $newTranscriptBy)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 150)
                        Spacer()
                    }
                    TextEditor(text: $newTranscriptText)
                        .font(.callout)
                        .frame(height: 90)
                        .overlay(RoundedRectangle(cornerRadius: Radius.control)
                            .stroke(Color.secondary.opacity(0.3)))
                        .accessibilityLabel("ข้อความบทถอดเทป")
                    HStack {
                        Button("เพิ่มบทถอดเทปและแบ่งเป็นช่วงตามย่อหน้า") {
                            let title = newTranscriptTitle
                            let code = newTranscriptCode
                            let by = newTranscriptBy
                            let text = newTranscriptText
                            newTranscriptText = ""
                            newTranscriptTitle = ""
                            Task {
                                await model.addTranscript(title: title, participantCode: code,
                                                          transcribedBy: by, text: text)
                            }
                        }
                        .disabled(newTranscriptTitle.trimmingCharacters(in: .whitespaces).isEmpty
                                  || newTranscriptText.trimmingCharacters(in: .whitespaces).isEmpty)
                        Spacer()
                    }
                    .controlSize(.small)
                    Text("เก็บรหัสผู้เข้าร่วม ไม่เก็บชื่อ — บทถอดเทปคือสิ่งที่ถูกแบ่ง จัดทำดัชนี ค้น ส่งออก และยกมาอ้าง "
                         + "ตัวตนที่เข้ามาตรงนี้จะโผล่ออกไปทั้งห้าทาง (§20.7)")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func codeButton(unit: CodingUnit, code: String?, label: String) -> some View {
        let mine = model.assignment(for: unit)
        let chosen = mine != nil && mine?.codeID == code
        Button(label) {
            Task { await model.code(unit: unit, as: code) }
        }
        .buttonStyle(.bordered)
        .tint(chosen ? .accentColor : .secondary)
        .disabled(model.coder.trimmingCharacters(in: .whitespaces).isEmpty)
        .accessibilityLabel("ลงรหัส \(label) ให้ช่วง \(unit.text.prefix(30))")
    }

    // MARK: - what the coding says about itself

    @ViewBuilder
    private func reportBox() -> some View {
        GroupBox("ความสอดคล้องระหว่างผู้ลงรหัส และความอิ่มตัว") {
            VStack(alignment: .leading, spacing: 8) {
                if let reliability = model.reliability {
                    Text(reliability.summary)
                        .font(.callout)
                        .foregroundStyle(reliability.isSubstantial ? Color.green : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(reliability.perCode) { row in
                            HStack(spacing: 8) {
                                Text(row.name).font(.caption)
                                    .frame(width: 200, alignment: .leading)
                                Text(String(format: "κ %.2f", row.kappa))
                                    .font(.caption).monospacedDigit()
                                    .foregroundStyle(row.applications == 0 ? Color.secondary
                                                     : (row.kappa >= 0.61 ? .green : .orange))
                                Text(row.applications == 0
                                     ? "ยังไม่เคยถูกใช้"
                                     : "ใช้ \(row.applications) ครั้ง")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                    }
                    Text("κ ต่ำเพราะหมวดเดียวกินหมด เป็นคนละเรื่องกับผู้ลงรหัสไม่เก่ง จึงรายงาน % ที่ตรงกันจริงคู่กันเสมอ "
                         + "· เกณฑ์ .61 (substantial) เป็นธรรมเนียมที่ใช้อ้าง ไม่ใช่ประตูที่นี่บังคับ — "
                         + "κ ต่ำคือผลที่ต้องเล่า ไม่ใช่ความผิดที่ต้องซ่อน")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("ต้องมีผู้ลงรหัสอย่างน้อย \(CodingAnalysis.minimumCoders) คน "
                         + "และช่วงข้อความที่ทุกคนลงครบอย่างน้อยหนึ่งช่วง จึงจะคำนวณ κ ได้")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let saturation = model.saturation {
                    Divider()
                    Text(saturation.summary).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(saturation.points) { point in
                        HStack(spacing: 8) {
                            Text("\(point.position). \(point.documentID)")
                                .font(.caption2).frame(width: 160, alignment: .leading)
                            Text(point.newCodes == 0 ? "ไม่มีรหัสใหม่" : "รหัสใหม่ \(point.newCodes)")
                                .font(.caption2)
                                .foregroundStyle(point.newCodes == 0 ? Color.secondary : .primary)
                            Text("สะสม \(point.cumulative)")
                                .font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
