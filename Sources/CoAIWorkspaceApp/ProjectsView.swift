import SwiftUI
import AgentKit
import Roster
import ProjectKit

// ─────────────────────────────────────────────────────────────
// The project screen (ARCHITECTURE §19.1, §19.4, §19.6).
//
// Small on purpose: the full Plan area with WBS, Gantt, Kanban and the
// registers is P10.4–P10.12. What has to exist *now* is everything the stage
// gate depends on — a project, its scope statement, and a visible reason why
// the next gate has not opened. Shipping the gate without this screen would
// mean a project that can never leave Initiation, which is a worse bug than
// having no gate at all.
// ─────────────────────────────────────────────────────────────

struct ProjectsView: View {
    @Bindable var model: ProjectsViewModel
    /// The types read from files at boot (§20.2). Passed in rather than looked
    /// up here, because "which types exist" is an answer the engine has already
    /// worked out and a screen that recomputed it could disagree with it.
    let types: [ProjectTypeManifest]
    @State private var newName = ""
    @State private var newType: String?
    @State private var newPackageTitle = ""
    @State private var selectedParent: String?
    @State private var decision = ""
    @State private var decider = ""
    @State private var registerTitle = ""
    @State private var registerKind = RegisterKind.risk
    @State private var draft = Draft()
    @State private var saving = false
    /// The closing tab's forms (§19.12). Plain state rather than a sheet: every
    /// one of these is a gate condition, and putting a gate condition behind a
    /// modal is what made the Executive seat unreachable for five phases.
    @State private var benefitDraft = BenefitDraft()
    @State private var measurements: [String: String] = [:]
    @State private var tailoringReason = ""
    @State private var dispositionAction = DataDisposition.Action.keep
    @State private var dispositionPolicy = ""
    /// Per-leaf editing buffers, keyed by package id. Same reason as `draft`.
    @State private var criteriaDrafts: [String: String] = [:]
    /// Titles and tolerance limits, buffered the same way and for the same
    /// reason: both are text fields on values the gate reads.
    @State private var titleDrafts: [String: String] = [:]
    @State private var limitDrafts: [String: String] = [:]
    @State private var tab = PlanTab.overview

    /// The Plan area's sections (§19.2). Driving the screen by hand is what
    /// showed why they are needed: with everything on one page, reaching the
    /// registers meant scrolling past four boxes, and the gate — the one thing
    /// that says what to do next — was below all of them.
    enum PlanTab: String, CaseIterable, Identifiable {
        case overview, plan, board, team, closing
        var id: String { rawValue }
        var label: String {
            switch self {
            case .overview: "ภาพรวม"
            case .plan: "แผนงาน + ลำดับ"
            case .board: "กระดานงาน"
            case .team: "ทีม & RACI"
            case .closing: "ประโยชน์ & ปิดงาน"
            }
        }
    }

    /// One benefit being typed. Numbers as text on purpose: a `TextField` bound
    /// to a `Double` shows `0` for an empty field, and a baseline of zero that
    /// nobody typed is exactly the fake measurement §19.12 is about.
    struct BenefitDraft: Equatable {
        var title = ""
        var measure = ""
        var baseline = ""
        var target = ""
        var owner = ""
        var reviewAt = Date()

        var isReady: Bool {
            !title.trimmingCharacters(in: .whitespaces).isEmpty
                && Double(baseline) != nil && Double(target) != nil
        }
    }
    /// Sends an exception report out through every running channel. Passed in
    /// rather than reached for: this screen does not know what a channel is.
    let announce: (String) async -> Void
    /// Hands a leaf to the team screen as a draft assignment (§19.6, P10.4).
    /// A closure rather than the team model itself: the plan screen has no
    /// business knowing how a run is started, and which team lead belongs to
    /// this workspace is the shell's question (§19.1.1).
    var startWork: ((WorkPackage) -> Bool)?

    var body: some View {
        HSplitView {
            list.frame(minWidth: 240, idealWidth: 280, maxWidth: 380)
            detail.frame(minWidth: 420, maxWidth: .infinity)
        }
        .task { await model.reload() }
        .onChange(of: model.selected?.id.rawValue) { _, _ in seedDraftIfNeeded(model.selected) }
        .onChange(of: model.projects.count) { _, _ in seedDraftIfNeeded(model.selected) }
        // Debounce: every edit restarts this, and only a pause commits. The
        // sleep is cancelled by the next keystroke, so a sentence is one write
        // rather than one write per character.
        .task(id: draft) {
            guard !draft.projectID.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await commitDraft()
        }
        .task(id: criteriaDrafts) {
            guard !criteriaDrafts.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            for package in model.wbs.packages { commitCriteria(for: package) }
        }
        .task(id: titleDrafts) {
            guard !titleDrafts.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            for package in model.wbs.packages { commitTitle(for: package) }
        }
    }

    // MARK: - list

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("พื้นที่ทำงาน")
                .font(.headline)
                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)

            List {
                Section {
                    Button {
                        Task { await model.focus(.general) }
                    } label: {
                        Label("General — คุยทั่วไป", systemImage: "bubble.left")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .fontWeight(model.selection == .general ? .semibold : .regular)
                }

                Section("โปรเจกต์") {
                    ForEach(model.projects) { project in
                        Button {
                            Task { await model.open(project) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(project.name)
                                    Text(project.kind.label)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(project.stage.label)
                                    .font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .fontWeight(model.selection == .project(project.id) ? .semibold : .regular)
                        .accessibilityLabel("เปิดโปรเจกต์ \(project.name) ขั้น\(project.stage.label)")
                    }
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                TextField("ชื่อโปรเจกต์ใหม่", text: $newName)
                    // A placeholder is not a label: it disappears the moment
                    // somebody types, and VoiceOver announced this as an
                    // unnamed text field (measured with the driver, E.30).
                    .accessibilityLabel("ชื่อโปรเจกต์ใหม่")
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Picker("ชนิด", selection: $newType) {
                        ForEach(types) { type in
                            Text(type.label).tag(String?.some(type.type))
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("ชนิดของโปรเจกต์ใหม่")
                    Button("สร้าง") {
                        guard let chosen = types.first(where: { $0.type == newType })
                            ?? types.first else { return }
                        let name = newName
                        newName = ""
                        Task { await model.create(name: name, type: chosen) }
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty
                              || types.isEmpty)
                }
                if let chosen = types.first(where: { $0.type == newType }) {
                    // What choosing this type will actually do, before it is
                    // chosen. A picker whose options only differ in a word is a
                    // picker people pick the first item of.
                    Text(chosen.description).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if types.isEmpty {
                    Text("ยังโหลดชนิดโปรเจกต์ไม่ได้ — ดูข้อความที่ ระบบ → สถานะระบบ")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            .padding(Space.box)
            .task(id: types.count) {
                if newType == nil { newType = types.first?.type }
            }
        }
    }

    // MARK: - detail

    @ViewBuilder
    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let status = model.status {
                    Text(status.message)
                        .font(.callout)
                        .foregroundStyle(status.isError ? Color.red : Color.secondary)
                        .textSelection(.enabled)
                }

                if let project = model.selected {
                    projectDetail(project)
                } else {
                    generalDetail
                }
            }
            .padding(Space.section)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var generalDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("General").font(.title3).bold()
            Text("""
                 คุยและสั่งงานสั้น ๆ ได้ทันที ไม่มีทีม ไม่มีบันทึกงาน ไม่มีขั้นของโครงการ \
                 ความรู้ที่เก็บระหว่างคุยจะอยู่ในคลังส่วนกลาง
                 """)
                .foregroundStyle(.secondary)
            Text("งานที่มีเป้าหมายและวันจบ ให้สร้างเป็นโปรเจกต์ — เครื่องมือที่เปลี่ยนข้อมูลจะเดินตามขั้นของโครงการ")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func projectDetail(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(project.name).font(.title3).bold()
            HStack(spacing: 8) {
                Text("ขั้น\(project.stage.label)")
                if let closure = project.closure {
                    Text("· \(closure.label)").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }

        stageStrip(project.stage)

        // The gate sits directly under the stage strip, not at the bottom of
        // the page. It is the only thing here that answers "what do I do
        // next", and driving the screen by hand showed it four sections down,
        // below everything it is supposed to be steering.
        if let gate = model.gate {
            gateBox(gate)
        } else {
            Text("โครงการปิดแล้ว — อ่านได้ แต่เครื่องมือที่เปลี่ยนข้อมูลใช้ไม่ได้แล้ว")
                .font(.callout).foregroundStyle(.secondary)
        }

        if let pending = model.pendingEdit { changeRequestBar(pending) }

        Picker("ส่วนของแผน", selection: $tab) {
            ForEach(PlanTab.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("เลือกส่วนของแผน")

        if tab == .overview {
        GroupBox("เหตุผลที่ทำ") {
            VStack(alignment: .leading, spacing: 4) {
                TextEditor(text: $draft.brief)
                    .frame(minHeight: 60)
                    .font(.body)
                    .accessibilityLabel("เหตุผลที่ทำโครงการนี้")
                savedHint
            }
        }

        // §19.5 — G1 asks for a person's name here, and until this field
        // existed the gate could never open from the app: the condition was
        // enforced, the type was there, and the screen had no door. That is
        // the fifth time this project has shipped something unreachable, and
        // the first time driving the screen caught it the same day.
        GroupBox("หมวกที่คนถือ") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("ผู้รับผิดชอบทางธุรกิจ (Executive)")
                        .font(.callout).frame(width: 220, alignment: .leading)
                    TextField("ชื่อคน", text: $draft.executive)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("ชื่อผู้รับผิดชอบทางธุรกิจ")
                }
                HStack {
                    Text("ตัวแทนผู้ใช้ (Senior User)")
                        .font(.callout).frame(width: 220, alignment: .leading)
                    TextField("ชื่อคน (ไม่บังคับ)", text: $draft.seniorUser)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("ชื่อตัวแทนผู้ใช้")
                }
                Text("ที่นั่งนี้เป็นของคนเสมอ — ไม่มีทางมอบให้ agent ได้ แม้จะอยากก็ตาม")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        GroupBox("ขอบเขต") {
            VStack(alignment: .leading, spacing: 10) {
                lineEditor("ทำ", text: $draft.inScope)
                lineEditor("ไม่ทำ", text: $draft.outOfScope)
                lineEditor("เกณฑ์รับงาน", text: $draft.acceptance)
                Text("บรรทัดละหนึ่งข้อ · ช่อง “ไม่ทำ” ว่างไม่ได้ — ขอบเขตที่ไม่เคยบอกว่าไม่ทำอะไร คือขอบเขตที่บานทุกครั้ง")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        toleranceBox()

        baselineBox()
        }

        if tab == .plan {
            wbsBox(project)
            scheduleBox()
            timelineBox()
            projectionBox()
        }

        if tab == .board {
            kanbanBox()
            registerBox()
        }

        if tab == .team {
            raciBox(project)
            raciTableBox()
        }

        if tab == .closing {
            reportsBox()
            benefitsBox()
            conformanceBox()
            dispositionBox(project)
        }
    }

    // MARK: - reporting (§19.13)

    /// The three reports, and the last thing each one said. Issuing is a button
    /// rather than a schedule because a report on a timer that nobody reads is
    /// the thing status reporting usually degrades into — the cycle can come
    /// later; being able to produce one from real rows is the point.
    @ViewBuilder
    private func reportsBox() -> some View {
        GroupBox("รายงาน") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ForEach(ReportKind.allCases, id: \.self) { kind in
                        Button(kind.label) { issue(kind) }
                    }
                    Spacer()
                    // §19.13 / P10.13 — how often somebody wants telling. The
                    // cycle never issues anything itself: it says one is due,
                    // and the button above is what issues it, so nothing can
                    // arrive by a path that skips what manual issuing checks.
                    Picker("ออกเอง", selection: $model.reportCycle) {
                        ForEach(ReportSchedule.Cycle.allCases, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    .labelsHidden().fixedSize()
                    .accessibilityLabel("รอบการออกรายงานความคืบหน้าอัตโนมัติ")
                }
                .controlSize(.small)

                if let due = model.reportDue {
                    HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                        Label("ถึงรอบออกรายงานความคืบหน้าแล้ว", systemImage: "clock.badge")
                            .font(.callout).foregroundStyle(.orange)
                        Button("ออกตอนนี้") { issue(.highlight) }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                    if let gap = due.gapNote {
                        // Three weeks away is one report and this sentence, not
                        // three reports: backfilled ones put numbers under
                        // dates nobody was working on.
                        Text(gap).font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if model.reports.isEmpty {
                    Text("ยังไม่มีรายงาน — ทุกบรรทัดในรายงานประกอบจากแผนงาน · ทะเบียน · span · baseline · ทะเบียนประโยชน์ ไม่ใช่ข้อความที่โมเดลแต่ง")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.reports) { report in
                    DisclosureGroup {
                        Text(report.rendered)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text("\(report.kind.label) · ขั้น\(report.stageAtIssue.label) · "
                             + report.generatedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.callout)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func issue(_ kind: ReportKind) {
        Task {
            // A report is also something to tell people about, on whatever
            // channel they are on (§19.13, §8.2) — the same text that is in the
            // file, not a summary of it.
            if let text = await model.issueReport(kind) { await announce(text) }
        }
    }

    // MARK: - benefits, conformance and closing (§19.12, §19.16)

    /// The benefit ledger. Deliberately editable after the project closes: the
    /// review date is usually months out, and a system that requires reopening a
    /// project to record what it achieved gets the review skipped.
    @ViewBuilder
    private func benefitsBox() -> some View {
        GroupBox("ประโยชน์ที่จะได้ (benefit)") {
            VStack(alignment: .leading, spacing: 8) {
                if model.benefits.isEmpty {
                    Text("ยังไม่มีรายการ — โครงการที่ส่งมอบครบทุกใบงานแล้วยังไร้ประโยชน์ได้ ถ้าไม่มีใครเขียนไว้ว่าอยากได้อะไร")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.benefits.benefits) { benefit in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(benefit.title).font(.callout)
                            Spacer()
                            if let achieved = benefit.achievement {
                                Text("\(Int(achieved * 100))% ของเป้า")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(achieved >= 1 ? Color.green : Color.orange)
                            } else {
                                Text(benefit.isDue() ? "ถึงกำหนดวัดแล้ว" : "ยังไม่ถึงกำหนดวัด")
                                    .font(.caption)
                                    .foregroundStyle(benefit.isDue() ? Color.orange : Color.secondary)
                            }
                            Button("ลบ") { Task { await model.removeBenefit(benefit) } }
                                .controlSize(.small)
                        }
                        Text("\(benefit.measure) · จาก \(format(benefit.baselineValue)) → \(format(benefit.target))"
                             + " · วัดโดย \(benefit.owner.label)"
                             + " · กำหนด \(benefit.reviewAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption2).foregroundStyle(.secondary)
                        if let result = benefit.result {
                            Text("วัดได้ \(format(result.value)) โดย \(result.measuredBy)"
                                 + (result.note.isEmpty ? "" : " — \(result.note)"))
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            HStack {
                                TextField("ค่าที่วัดได้", text: Binding(
                                    get: { measurements[benefit.id] ?? "" },
                                    set: { measurements[benefit.id] = $0 }))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 120)
                                TextField("ชื่อคนที่วัด", text: $decider)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 160)
                                Button("บันทึกผล") { recordMeasurement(benefit) }
                                    .disabled(Double(measurements[benefit.id] ?? "") == nil
                                              || decider.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                            .controlSize(.small)
                        }
                    }
                }

                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("ประโยชน์ที่อยากได้", text: $benefitDraft.title)
                            .textFieldStyle(.roundedBorder)
                        TextField("ตัววัด + หน่วย", text: $benefitDraft.measure)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        TextField("ค่าฐานวันนี้", text: $benefitDraft.baseline)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 110)
                        TextField("ค่าเป้าหมาย", text: $benefitDraft.target)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 110)
                        DatePicker("วัดเมื่อ", selection: $benefitDraft.reviewAt,
                                   displayedComponents: .date)
                            .labelsHidden()
                        TextField("ใครวัด", text: $benefitDraft.owner)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 130)
                        Button("เพิ่ม") { addBenefit() }
                            .disabled(!benefitDraft.isReady)
                    }
                    Text("ค่าฐานบังคับ เพราะ “ดีขึ้น” ที่ไม่มีจุดเริ่มต้น ตรวจย้อนหลังไม่ได้ · เป้าที่ต่ำกว่าค่าฐานก็ได้ (เช่นลดเวลา) ระบบคิดทิศทางให้เอง")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The conformance matrix, and the one thing that makes it worth reading:
    /// every green row names what it counted, and a row satisfied by a decision
    /// not to do the practice looks different from one satisfied by doing it.
    @ViewBuilder
    private func conformanceBox() -> some View {
        let gaps = model.conformance.filter { !$0.satisfied }
        GroupBox("ความครบตามมาตรฐาน (ISO 21502 · 17 practice)") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.conformance) { status in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: status.satisfied
                              ? (status.isTailored ? "minus.circle" : "checkmark.circle.fill")
                              : "exclamationmark.circle")
                            .foregroundStyle(status.satisfied
                                             ? (status.isTailored ? Color.secondary : Color.green)
                                             : Color.orange)
                        Text(status.practice.label)
                            .font(.callout).frame(width: 180, alignment: .leading)
                        if let evidence = status.evidence {
                            Text(evidence).font(.caption).foregroundStyle(.secondary)
                        } else if let record = status.tailoring {
                            Text("ไม่ทำ: \(record.reason) — ตัดสินโดย \(record.decidedBy)")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("ยังไม่มีทั้งของจริงและบันทึกว่าไม่ทำ")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }

                if !gaps.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("บันทึกว่าไม่ทำ practice ไหน พร้อมเหตุผล — ปิดโครงการไม่ได้ถ้ายังมีข้อที่ไม่ได้ตอบ")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(gaps) { status in
                            HStack {
                                Text(status.practice.label)
                                    .font(.callout).frame(width: 180, alignment: .leading)
                                TextField("เหตุผลที่ไม่ทำ", text: $tailoringReason)
                                    .textFieldStyle(.roundedBorder)
                                TextField("ชื่อคนที่ตัดสิน", text: $decider)
                                    .textFieldStyle(.roundedBorder).frame(maxWidth: 150)
                                Button("บันทึก") { tailor(status.practice) }
                                    .disabled(tailoringReason.trimmingCharacters(in: .whitespaces).isEmpty
                                              || decider.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func dispositionBox(_ project: Project) -> some View {
        GroupBox("ข้อมูลและไฟล์ที่เหลือ") {
            VStack(alignment: .leading, spacing: 6) {
                if let decided = project.dataDisposition, decided.isDecided {
                    Text("\(decided.action.label) · ตามนโยบาย “\(decided.policy)” · ตัดสินโดย \(decided.decidedBy)")
                        .font(.callout)
                } else {
                    Text("ยังไม่ได้ตัดสิน — ข้อนี้เป็นเงื่อนไขข้อที่ 8 ของการปิดโครงการ")
                        .font(.callout).foregroundStyle(.orange)
                }
                HStack {
                    Picker("ทำอะไรกับของที่เหลือ", selection: $dispositionAction) {
                        ForEach(DataDisposition.Action.allCases, id: \.self) { action in
                            Text(action.label).tag(action)
                        }
                    }
                    .labelsHidden()
                    TextField("นโยบายที่ใช้", text: $dispositionPolicy)
                        .textFieldStyle(.roundedBorder)
                    TextField("ชื่อคนที่ตัดสิน", text: $decider)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 150)
                    Button("บันทึก") { decideDisposition() }
                        .disabled(dispositionPolicy.trimmingCharacters(in: .whitespaces).isEmpty
                                  || decider.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .controlSize(.small)
                Text("ระบบบันทึกการตัดสิน ไม่ลบไฟล์ให้เอง — การลบของคนอื่นย้อนกลับไม่ได้")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func addBenefit() {
        let draft = benefitDraft
        benefitDraft = BenefitDraft()
        Task {
            await model.addBenefit(title: draft.title, measure: draft.measure,
                                   baselineValue: Double(draft.baseline) ?? 0,
                                   target: Double(draft.target) ?? 0,
                                   reviewAt: draft.reviewAt, owner: draft.owner)
        }
    }

    private func recordMeasurement(_ benefit: Benefit) {
        guard let value = Double(measurements[benefit.id] ?? "") else { return }
        let person = decider
        measurements[benefit.id] = nil
        Task { await model.measure(benefit, value: value, by: person) }
    }

    private func tailor(_ practice: Practice) {
        let reason = tailoringReason
        let person = decider
        tailoringReason = ""
        Task { await model.tailor(practice, reason: reason, by: person) }
    }

    private func decideDisposition() {
        let policy = dispositionPolicy
        let person = decider
        let action = dispositionAction
        Task { await model.decideDisposition(action: action, policy: policy, by: person) }
    }

    // MARK: - editing an agreed plan (§19.2.4, P10.16)

    /// The bar §19.2.4 asks for: not a block and not a warning afterwards, but
    /// the consequence stated where the hand already is, with two buttons.
    @ViewBuilder
    private func changeRequestBar(_ proposal: PlanChangeProposal) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text(proposal.title).font(.callout).bold()
                Text(proposal.headline)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("ส่วนต่างจาก baseline หลังแก้: \(proposal.driftAfter)")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("ยืนยันและเปิดคำขอ") { Task { await model.confirmPendingEdit() } }
                        .keyboardShortcut(.defaultAction)
                    Button("ยกเลิก") { model.cancelPendingEdit() }
                    Spacer()
                    Text("ประตูขั้นถัดไปจะยังไม่เปิดจนกว่าจะมีคนตัดสินคำขอนี้")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("แผนนี้ตกลงกันไว้แล้ว — การแก้จะกลายเป็นคำขอเปลี่ยนแปลง",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("คำขอเปลี่ยนแปลงที่รอการยืนยัน: \(proposal.headline)")
    }

    /// §21.1 layer 3 / P12.8 — what each role has actually been able to do.
    ///
    /// Beside RACI because that is where somebody decides who to give work to,
    /// and this is the only place in the app that answers "have they done this
    /// kind of thing before". A tool used fewer than five times shows no
    /// percentage: one call out of one is 100%, and a panel that prints that
    /// teaches people either to trust it wrongly or to stop reading it.
    @ViewBuilder private var proficiencyPanel: some View {
        if !model.proficiency.isEmpty {
            DisclosureGroup("ความชำนาญเครื่องมือของแต่ละบทบาท") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Role.allCases, id: \.self) { role in
                        let rows = model.proficiency(for: role)
                        if !rows.isEmpty {
                            Text(role.rawValue).font(.caption).fontWeight(.medium)
                            ForEach(rows, id: \.tool) { row in
                                Text("· \(row.tool) — \(row.summary)")
                                    .font(.caption2)
                                    .foregroundStyle(row.isTooFewToJudge ? .secondary : .primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    // The threshold from the type, not a number typed again
                    // here: two copies of it drift, and the caption is the only
                    // place a reader learns why some rows have no percentage.
                    Text("นับข้ามโปรเจกต์ · การเรียกที่ถูกกฎหยุดไว้ไม่นับเป็นความผิดของบทบาท "
                         + "และเครื่องมือที่ใช้ไม่ถึง \(ToolProficiency.leastMeaningfulSample) ครั้ง "
                         + "ไม่แสดงเปอร์เซ็นต์ เพราะ 1 จาก 1 คือ 100% และไม่ได้บอกอะไร")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.callout)
        }
    }

    // MARK: - order, board and RACI (§19.7–§19.9)

    /// Not a Gantt, and it says so. §19.7: the horizontal axis of a real Gantt
    /// is calendar time. The spans now carry a work package *and* a duration —
    /// `SurrealSpanSink.assignments(project:)` returns the rows a bar would be
    /// drawn from — so what stands between this and a calendar axis is no longer
    /// missing data. It is one unanswered question: a leaf touched on Monday and
    /// again on Thursday did not take four days, and a bar spanning them says it
    /// did (P10.9). What *is* true today is the order, which chain decides the
    /// end, and how long each leaf has actually cost.
    @ViewBuilder
    private func scheduleBox() -> some View {
        let ordered = Schedule.order(model.wbs)
        let paths = Schedule.criticalPaths(model.wbs)
        let critical = Set(paths.flatMap { $0 })
        let ready = Set(Schedule.ready(model.wbs).map(\.id))

        GroupBox("ลำดับงานและเส้นทางวิกฤต") {
            VStack(alignment: .leading, spacing: 6) {
                // §19.2.4, said out loud rather than only enforced by the absence
                // of a gesture: the end date is a result, so there is nothing here
                // to drag. Wanting it sooner means changing what it depends on.
                Text("แถบพวกนี้ลากไม่ได้โดยตั้งใจ — วันจบเป็นผลของลำดับงานกับความเร็วจริง ไม่ใช่ค่าที่ตั้ง · อยากให้จบเร็วขึ้นให้แก้สิ่งที่มันขึ้นกับ: ตัดขอบเขต ลดเส้นพึ่งพา หรือเปลี่ยน tier ของโมเดล")
                    .font(.caption2).foregroundStyle(.secondary)
                if ordered.isEmpty {
                    Text("ยังไม่มีใบงาน").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(ordered.enumerated()), id: \.element.id) { index, package in
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(.system(.caption, design: .monospaced))
                                .frame(width: 22, alignment: .trailing)
                                .foregroundStyle(.secondary)
                            // The bar is position in the order, not duration.
                            // Drawing a length here would be drawing a number
                            // nobody measured.
                            RoundedRectangle(cornerRadius: Radius.control)
                                .fill(critical.contains(package.id)
                                      ? Color.accentColor : Color.secondary.opacity(0.35))
                                .frame(width: 26, height: 12)
                                .padding(.leading, CGFloat(index) * 14)
                            Text(package.title).font(.callout)
                            if let seconds = model.elapsed[package.id], seconds > 0 {
                                // Measured, not estimated — this is time that
                                // actually happened against this leaf.
                                Text(formatDuration(seconds))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            if critical.contains(package.id) {
                                Text("เส้นทางวิกฤต").font(.caption2)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                            }
                            if ready.contains(package.id) {
                                Text("เริ่มได้แล้ว").font(.caption2).foregroundStyle(.green)
                            }
                            Spacer()
                            dependencyPicker(package)
                        }
                    }
                    if paths.isEmpty {
                        Text("ยังไม่มีเส้นพึ่งพา — ทุกใบเริ่มพร้อมกันได้ จึงยังไม่มีเส้นทางไหนเป็นตัวตัดสิน")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else if paths.count > 1 {
                        Text("มี \(paths.count) เส้นทางที่ยาวเท่ากัน — ช้าเส้นไหนก็ช้าทั้งโครงการ")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("แกนนอนตรงนี้คือลำดับ ไม่ใช่เวลา — แกนเวลาจริงอยู่ในกล่องถัดไป")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Where the work that has not started would land (§19.7, P10.9's third
    /// axis).
    ///
    /// Kept out of the calendar chart above rather than drawn onto it, and
    /// that is the point: what happened and what might happen are different
    /// kinds of claim, and a picture that puts them on one axis in one style
    /// invites somebody to read a forecast as a record. Every row here is a
    /// range, never a date.
    @ViewBuilder
    private func projectionBox() -> some View {
        if let projection = model.projection,
           !(projection.leaves.isEmpty && projection.unforecastable.isEmpty) {
            GroupBox("งานที่ยังไม่เริ่ม — ถ้าเริ่มตอนนี้") {
                VStack(alignment: .leading, spacing: Space.row) {
                    Text("ช่วง p50–p90 จากงานจริงที่เคยเสร็จในระบบนี้ ไม่ใช่วันที่ตั้งไว้ · "
                         + "งานที่เริ่มไปแล้วไม่อยู่ในนี้ เพราะของจริงวัดได้แล้วจากแกนเวลาด้านบน")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(projection.leaves) { row in
                        HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                            Text(row.title).font(.callout).lineLimit(1)
                            Spacer(minLength: Space.row)
                            Text(dayRange(row.p50Finish, row.p90Finish))
                                .font(.system(.caption, design: .monospaced))
                            Text("จาก \(row.sampleCount) งาน")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(row.title) น่าจะเสร็จระหว่าง "
                                            + dayRange(row.p50Finish, row.p90Finish))
                    }

                    if let finish = projection.p90Finish, !projection.leaves.isEmpty {
                        Text("ถ้าทุกอย่างเดินตามลำดับนี้ งานที่ประมาณได้จะจบราว "
                             + finish.formatted(date: .abbreviated, time: .omitted)
                             + " (ขอบบน p90)")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    // Named, not omitted: a list that quietly drops what it
                    // cannot forecast reads as a list of all the work.
                    ForEach(projection.unforecastable, id: \.packageID) { row in
                        Label("\(row.title) — \(row.reason)", systemImage: "questionmark.circle")
                            .font(.caption2).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func dayRange(_ p50: Date, _ p90: Date) -> String {
        let format = Date.FormatStyle(date: .abbreviated, time: .shortened)
        return "\(p50.formatted(format)) – \(p90.formatted(format))"
    }

    /// The schedule on a calendar axis (§19.7, P10.9) — the thing four plan
    /// items said could not be drawn honestly.
    ///
    /// A row is one mark per piece of work, and **a gap stays a gap**. The
    /// obvious drawing — one bar per leaf from first touch to last — reads as
    /// four days of work when a leaf was touched on Monday and again on
    /// Thursday, and shading it to show that only forty minutes was real does
    /// not help: the eye reads the rectangle, not the fill.
    @ViewBuilder
    private func timelineBox() -> some View {
        if let timeline = model.timeline {
            GroupBox("แกนเวลาจริง — งานที่เกิดขึ้นจริงบนปฏิทิน") {
                VStack(alignment: .leading, spacing: 6) {
                    if timeline.isEmpty {
                        Text("ยังไม่มีงานที่บันทึกเวลาไว้ในโปรเจกต์นี้ — แถบจะขึ้นเองเมื่อมีงานจบ")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("ช่วง \(axisLabel(timeline)) · แต่ละขีดคือหนึ่งงานที่เกิดขึ้นจริง **ช่องว่างระหว่างขีดคือช่วงที่ไม่มีใครทำงานนี้** ไม่ใช่งานที่ยืดยาว")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(timeline.rows) { row in
                            timelineRow(row)
                        }
                        if model.timelineBeyondLimit > 0 {
                            Text("ยังมีอีก \(model.timelineBeyondLimit) ชิ้นที่เก่ากว่านี้และไม่ได้วาด — "
                                 + "ภาพนี้จึงไม่ใช่ทั้งหมดของประวัติ")
                                .font(.caption2).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("แถบสีจางคืองานที่ไม่ผ่านหรือถูกยกเลิก — มันใช้เวลาไปจริง จึงยังอยู่บนแกน")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func timelineRow(_ row: ScheduleTimeline.Row) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(.callout).lineLimit(1)
                if row.hasStarted {
                    Text("ทำจริง \(formatDuration(row.workedSeconds))")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Text("ยังไม่เริ่ม").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 200, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.08)).frame(height: 12)
                    ForEach(row.segments) { segment in
                        // The clamp that keeps a forty-second job visible lives
                        // here and not in `ScheduleTimeline`: it is a fact about
                        // pixels, and in the model every number computed
                        // downstream would inherit it.
                        let width = max(3, (segment.to - segment.from) * geometry.size.width)
                        RoundedRectangle(cornerRadius: Radius.control)
                            .fill(segment.succeeded
                                  ? Color.accentColor
                                  : Color.secondary.opacity(0.45))
                            .frame(width: width, height: 12)
                            .offset(x: segment.from * geometry.size.width)
                    }
                }
                .frame(height: 16)
            }
            .frame(height: 16)
            .accessibilityElement()
            .accessibilityLabel(rowSpokenLabel(row))
        }
        .padding(.vertical, 1)
        .overlay(alignment: .bottomLeading) {
            if let note = row.gapNote {
                Text(note).font(.caption2).foregroundStyle(.orange)
                    .offset(y: 10)
            }
        }
        .padding(.bottom, row.gapNote == nil ? 0 : 12)
    }

    /// A chart is not readable by a screen reader, so the row says in words what
    /// the marks say in pixels — including the gap, which is the whole point.
    private func rowSpokenLabel(_ row: ScheduleTimeline.Row) -> String {
        guard row.hasStarted else { return "\(row.title) — ยังไม่เริ่ม" }
        let base = "\(row.title) — \(row.segments.count) ช่วงงาน "
            + "รวมเวลาที่ทำจริง \(formatDuration(row.workedSeconds))"
        guard let note = row.gapNote else { return base }
        return base + " · " + note
    }

    private func axisLabel(_ timeline: ScheduleTimeline) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        return "\(formatter.string(from: timeline.start)) – \(formatter.string(from: timeline.end))"
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        seconds < 90 ? "\(Int(seconds)) วิ" : "\(Int(seconds / 60)) นาที"
    }

    private func dependencyPicker(_ package: WorkPackage) -> some View {
        Menu {
            ForEach(model.wbs.leaves.filter { $0.id != package.id }) { other in
                Button {
                    var next = package
                    if let index = next.dependsOn.firstIndex(of: other.id) {
                        next.dependsOn.remove(at: index)
                    } else {
                        next.dependsOn.append(other.id)
                    }
                    Task { await model.update(next) }
                } label: {
                    Label(other.title,
                          systemImage: package.dependsOn.contains(other.id) ? "checkmark" : "")
                }
            }
        } label: {
            Text(package.dependsOn.isEmpty ? "รอ: —" : "รอ \(package.dependsOn.count) ใบ")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("เลือกใบงานที่ \(package.title) ต้องรอ")
    }

    /// §19.8 — the columns are the ledger's statuses, and the WIP limit is the
    /// fan-out cap that already exists in config rather than a second number.
    @ViewBuilder
    private func kanbanBox() -> some View {
        GroupBox("กระดานงาน") {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(WorkPackageStatus.allCases, id: \.self) { status in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(status.label).font(.caption).bold()
                                Spacer()
                                Text("\(model.wbs.leaves.count { $0.status == status })")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            ForEach(model.wbs.leaves.filter { $0.status == status }) { package in
                                cardView(package)
                                    // The id travels, not the card: a drop has
                                    // to go through `move`, which is where the
                                    // evidence rule lives (§19.15 invariant 4).
                                    .draggable(package.id)
                            }
                            // The whole column is the target, including the
                            // empty space under the last card — a column you
                            // can only drop *onto a card* is a column you
                            // cannot move the first card into.
                            Color.clear.frame(height: 24)
                        }
                        .frame(width: 190, alignment: .leading)
                        .contentShape(Rectangle())
                        .dropDestination(for: String.self) { ids, _ in
                            guard let id = ids.first,
                                  let package = model.wbs.leaves.first(where: { $0.id == id })
                            else { return false }
                            // Same call the menu makes. A drop that took a
                            // shortcut past it would be a way to mark work done
                            // without the evidence, which is the one thing this
                            // board must not become.
                            move(package, to: status)
                            return true
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func cardView(_ package: WorkPackage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(package.title).font(.caption)
            HStack(spacing: 4) {
                if let role = package.role {
                    Text(role.rawValue).font(.caption2)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                if !package.evidence.isEmpty {
                    Text("หลักฐาน \(package.evidence.count)").font(.caption2)
                        .foregroundStyle(.green)
                }
            }
            Menu("ย้าย") {
                ForEach(WorkPackageStatus.allCases, id: \.self) { target in
                    Button(target.label) { move(package, to: target) }
                }
            }
            .menuStyle(.borderlessButton)
            .font(.caption2)
            .accessibilityLabel("ย้ายใบงาน \(package.title)")
        }
        .padding(Space.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: Radius.box))
        .overlay(RoundedRectangle(cornerRadius: Radius.box).stroke(.quaternary))
    }

    /// Moving a card is not a way around the evidence rule (§19.15 invariant
    /// 4): "เสร็จ" goes through the same refusal an agent gets.
    private func move(_ package: WorkPackage, to status: WorkPackageStatus) {
        guard status == .done else {
            var next = package
            next.status = status
            Task { await model.update(next) }
            return
        }
        Task { await model.complete(package.id, evidence: package.evidence) }
    }

    /// The RACI as a table (§19.9, P10.9).
    ///
    /// The editor above is per package, and the questions this table exists
    /// for are questions across rows: who is responsible for everything, who is
    /// on the project and carries nothing, which package is accountable to
    /// somebody and assigned to nobody. None of them can be seen one package
    /// at a time.
    @ViewBuilder
    private func raciTableBox() -> some View {
        let matrix = RACIMatrix.build(model.wbs)
        if !matrix.rows.isEmpty && !matrix.actors.isEmpty {
            GroupBox("ตาราง RACI ทั้งโครงการ") {
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: Space.box,
                         verticalSpacing: Space.tight) {
                        GridRow {
                            Text("ใบงาน").font(.caption.weight(.semibold))
                            ForEach(Array(matrix.actors.enumerated()), id: \.offset) { _, actor in
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(actor.label).font(.caption.weight(.semibold))
                                    // The bottleneck, counted rather than
                                    // squinted at down a column.
                                    Text("R×\(matrix.responsibleCount(for: actor))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Divider()
                        ForEach(matrix.rows) { row in
                            GridRow {
                                HStack(spacing: Space.tight) {
                                    Text(row.title).font(.callout).lineLimit(1)
                                    if row.isUnassigned {
                                        Text("ไม่มีคนทำ").font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }
                                ForEach(Array(row.cells.enumerated()), id: \.offset) { _, letters in
                                    // Every letter that applies, not the
                                    // strongest one: somebody who is both A
                                    // and C on a package is what a reader of
                                    // this table is looking for.
                                    Text(letters.map(\.rawValue).joined(separator: ""))
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(letters.contains(.accountable)
                                                         ? Color.primary : .secondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(spokenRow(row, actors: matrix.actors))
                        }
                    }
                    .padding(.vertical, Space.tight)
                }
                if !matrix.uninvolved.isEmpty {
                    Text("อยู่ในโครงการแต่ไม่ได้ถือตัวอักษรไหนเลย: "
                         + matrix.uninvolved.map(\.label).joined(separator: ", "))
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// A grid read left to right by a screen reader is a list of letters, so
    /// the row is spoken as sentences instead.
    private func spokenRow(_ row: RACIMatrix.Row, actors: [RACIActor]) -> String {
        let parts = zip(actors, row.cells).compactMap { actor, letters -> String? in
            letters.isEmpty ? nil : "\(actor.label) \(letters.map(\.rawValue).joined(separator: " "))"
        }
        return "\(row.title): " + (parts.isEmpty ? "ยังไม่ได้กำหนดใคร" : parts.joined(separator: " · "))
    }

    /// §19.9 — one accountable per package, and the screen cannot express two.
    @ViewBuilder
    private func raciBox(_ project: Project) -> some View {
        GroupBox("ทีม & RACI") {
            VStack(alignment: .leading, spacing: 8) {
                proficiencyPanel
                if model.wbs.leaves.isEmpty {
                    Text("ยังไม่มีใบงานให้มอบหมาย").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.wbs.leaves) { package in
                    HStack(spacing: 8) {
                        Text(package.title).font(.callout).frame(width: 220, alignment: .leading)
                        Picker("A", selection: accountableBinding(package, project: project)) {
                            Text("— ยังไม่มี —").tag(Accountable?.none)
                            Text("หัวหน้าทีม").tag(Accountable?.some(.teamLead))
                            if let person = project.executive?.person, !person.isEmpty {
                                Text(person).tag(Accountable?.some(.human(person)))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                        .accessibilityLabel("ผู้รับผิดชอบผลของ \(package.title)")
                        if package.riskClass >= .high, package.raci?.accountable.isHuman != true {
                            Text("งานเสี่ยงสูงต้องให้คนรับผิดชอบ")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                        Spacer()
                    }
                }
                Divider()
                // R/C/I, which P10.5 left for later. Toggles rather than text:
                // the set of people and agents a project has is known, and a
                // free-text field here is how "อนาลิสต์" and "analyst" end up
                // being two different people in the same table.
                ForEach(model.wbs.leaves) { package in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(package.title).font(.caption).foregroundStyle(.secondary)
                        ForEach(RACILetter.allCases, id: \.self) { letter in
                            HStack(spacing: 4) {
                                Text(letter.label)
                                    .font(.caption2).frame(width: 96, alignment: .leading)
                                ForEach(raciCandidates(project), id: \.self) { actor in
                                    Toggle(actor.label, isOn: raciBinding(package, letter: letter,
                                                                         actor: actor))
                                        .toggleStyle(.button)
                                        .controlSize(.mini)
                                }
                                Spacer()
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }

                Text("A มีได้คนเดียวต่อใบงาน — ตัวเลือกนี้จึงเป็นค่าเดียว ไม่ใช่รายการติ๊กถูก · R/C/I เป็นรายการได้")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func accountableBinding(_ package: WorkPackage,
                                    project: Project) -> Binding<Accountable?> {
        Binding(get: { package.raci?.accountable },
                set: { chosen in
                    var next = package
                    if let chosen {
                        var raci = next.raci ?? RACI(accountable: chosen)
                        raci.accountable = chosen
                        if let role = next.role, raci.responsible.isEmpty {
                            raci.responsible = [.agent(role)]
                        }
                        next.raci = raci
                    } else {
                        next.raci = nil
                    }
                    Task { await model.update(next) }
                })
    }

    /// The three letters that are lists. `A` is not here on purpose — it is a
    /// single value in the type system (§19.9), and offering it as a toggle row
    /// would be offering a state that cannot be saved.
    enum RACILetter: String, CaseIterable {
        case responsible, consulted, informed
        var label: String {
            switch self {
            case .responsible: "R ทำ"
            case .consulted: "C ปรึกษา"
            case .informed: "I แจ้งให้ทราบ"
            }
        }
    }

    /// Who can appear in an R/C/I cell: every role the team has, plus the people
    /// who already hold a seat. Not a text field — see the comment at the call site.
    private func raciCandidates(_ project: Project) -> [RACIActor] {
        Role.allCases.map { RACIActor.agent($0) }
            + project.board.map(\.person)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { RACIActor.human($0) }
    }

    private func raciBinding(_ package: WorkPackage, letter: RACILetter,
                             actor: RACIActor) -> Binding<Bool> {
        func list(_ raci: RACI?) -> [RACIActor] {
            switch letter {
            case .responsible: raci?.responsible ?? []
            case .consulted: raci?.consulted ?? []
            case .informed: raci?.informed ?? []
            }
        }
        return Binding(
            get: { list(package.raci).contains(actor) },
            set: { on in
                // A leaf with no A yet cannot carry an R either, because `RACI`
                // has no state without an accountable — so the row says what is
                // missing instead of dropping the tap.
                guard var raci = package.raci else { return }
                var current = list(raci)
                if on {
                    guard !current.contains(actor) else { return }
                    current.append(actor)
                } else {
                    current.removeAll { $0 == actor }
                }
                switch letter {
                case .responsible: raci.responsible = current
                case .consulted: raci.consulted = current
                case .informed: raci.informed = current
                }
                var next = package
                next.raci = raci
                Task { await model.update(next) }
            })
    }

    // MARK: - registers and baselines (§19.11)

    @ViewBuilder
    private func registerBox() -> some View {
        GroupBox("ทะเบียน") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.registers) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(entry.kind.label)
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                            Text(entry.title).font(.callout)
                            Spacer()
                            Text(entry.status.label).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("เสนอโดย \(entry.origin.label)"
                             + (entry.decidedBy.map { " · ตัดสินโดย \($0)" } ?? ""))
                            .font(.caption2).foregroundStyle(.secondary)

                        // Only a change is decided, and only by a person.
                        if entry.kind == .change, entry.status == .proposed {
                            HStack {
                                TextField("ชื่อผู้ตัดสิน", text: $decider)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 160)
                                Button("อนุมัติ") { decide(entry, approve: true) }
                                Button("ปฏิเสธ") { decide(entry, approve: false) }
                            }
                            .controlSize(.small)
                            .disabled(decider.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                if model.registers.isEmpty {
                    Text("ยังไม่มีรายการ").font(.callout).foregroundStyle(.secondary)
                }

                HStack {
                    TextField("บันทึกรายการใหม่", text: $registerTitle)
                        .textFieldStyle(.roundedBorder)
                    Picker("ชนิด", selection: $registerKind) {
                        ForEach(RegisterKind.allCases, id: \.self) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("ชนิดของรายการที่จะบันทึก")
                    Button("บันทึก") { addRegister() }
                        .disabled(registerTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func baselineBox() -> some View {
        if !model.baselines.isEmpty {
            GroupBox("แผนที่ตกลงไว้ (baseline)") {
                VStack(alignment: .leading, spacing: 5) {
                    if let drift = model.drift {
                        Text("ตอนนี้เทียบกับ v\(model.baselines.first?.version ?? 1): \(drift.summary)")
                            .font(.callout)
                            .foregroundStyle(drift.isEmpty ? Color.secondary : Color.orange)
                    }
                    ForEach(model.baselines) { baseline in
                        Text("v\(baseline.version) · \(baseline.reason) · \(baseline.packages.count) ใบงาน")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("เวอร์ชันเก่ายังอ่านได้เสมอ — จำนวนเวอร์ชันคือคำตอบของ “แผนเปลี่ยนไปกี่ครั้ง”")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func addRegister() {
        let title = registerTitle
        registerTitle = ""
        let detail: RegisterDetail = switch registerKind {
        case .risk: .risk(probability: 3, impact: 3, response: .reduce)
        case .issue: .issue(severity: 3, kind: .problem)
        case .change: .change(scopeImpact: "—", timeImpact: "—", costImpact: "—")
        case .decision: .decision(options: [], reversible: true)
        case .lesson: .lesson(cause: "", doDifferently: "", appliesTo: "")
        }
        Task { await model.record(detail, title: title) }
    }

    private func decide(_ entry: RegisterEntry, approve: Bool) {
        let person = decider
        Task { await model.decide(entry, approve: approve, by: person) }
    }

    // MARK: - tolerance (§19.10)

    @ViewBuilder
    private func toleranceBox() -> some View {
        GroupBox("กรอบที่ทีมเดินเองได้") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.tolerances) { status in
                    let measured = model.measured.contains(status.dimension)
                    let noTarget = status.dimension == .benefit && status.limit == 0
                    HStack(spacing: 8) {
                        Text(status.dimension.label)
                            .font(.callout)
                            .frame(width: 84, alignment: .leading)
                        // The frame as numbers, which is the whole point: a
                        // slider labelled "balanced" says nothing a person can
                        // check against what is happening. But a number the
                        // app is not actually reading is worse than no number,
                        // so an unwired dimension says that instead.
                        // The limit is typed; the current value is not (§19.2.4).
                        // One text field and one read-only number, side by side,
                        // is the clearest statement of that line this screen can
                        // make.
                        TextField("กรอบ", text: Binding(
                            get: { limitDrafts[status.dimension.rawValue] ?? format(status.limit) },
                            set: { limitDrafts[status.dimension.rawValue] = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 70)
                            .accessibilityLabel("กรอบของ\(status.dimension.label) ตั้งได้")
                            .onSubmit { commitLimit(status.dimension) }

                        if noTarget {
                            Text("ยังไม่ได้ตั้งเป้า")
                                .font(.callout).foregroundStyle(.secondary)
                        } else if measured {
                            Text("\(format(status.current)) / \(format(status.limit))")
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(status.breached ? Color.red : Color.primary)
                            ProgressView(value: min(status.fraction, 1))
                                .frame(maxWidth: 120)
                        } else {
                            Text("กรอบ \(format(status.limit)) · ยังไม่ได้วัด")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Text(status.dimension.unit)
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel({
                        if noTarget { "กรอบประโยชน์ ยังไม่ได้ตั้งเป้า" }
                        else if measured {
                            "กรอบ\(status.dimension.label) ตอนนี้ \(format(status.current)) จาก \(format(status.limit))"
                                + (status.breached ? " — ทะลุแล้ว" : "")
                        } else {
                            "กรอบ\(status.dimension.label) ตั้งไว้ \(format(status.limit)) แต่ระบบยังไม่ได้วัดค่านี้"
                        }
                    }())
                }

                Text("แกนที่ขึ้นว่า “ยังไม่ได้วัด” มีกรอบและบังคับอยู่จริง แต่ยังไม่มีข้อมูลต้นทาง — ประโยชน์จะวัดได้เมื่อมีคนบันทึกผลในแท็บ “ประโยชน์ & ปิดงาน”")
                    .font(.caption2).foregroundStyle(.secondary)

                HStack {
                    Text("ตั้งกรอบทั้งชุด").font(.caption).foregroundStyle(.secondary)
                    Button("ขออนุมัติทุกขั้น") { Task { await model.setTolerances(.approvalRequired) } }
                    Button("สมดุล") { Task { await model.setTolerances(.balanced) } }
                    Button("ทำงานเองทั้งหมด") { Task { await model.setTolerances(.fullAutonomous) } }
                    Spacer()
                    Button("ตรวจกรอบตอนนี้") { checkTolerances() }
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        ForEach(model.openExceptions) { report in
            GroupBox("ทะลุกรอบ\(report.dimension.label) — โครงการหยุดรอคุณ") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(report.message)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        TextField("คำตัดสินของคุณ", text: $decision)
                            .textFieldStyle(.roundedBorder)
                        Button("ปิดข้อยกเว้น") {
                            let text = decision
                            decision = ""
                            Task { await model.resolve(report, decision: text) }
                        }
                        .disabled(decision.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    private func commitLimit(_ dimension: ToleranceDimension) {
        guard let text = limitDrafts[dimension.rawValue] else { return }
        limitDrafts[dimension.rawValue] = nil
        // A field that will not parse leaves the frame alone. Silently reading it
        // as zero would set the strictest possible limit on the axis somebody was
        // trying to loosen.
        guard let limit = Double(text.trimmingCharacters(in: .whitespaces)) else {
            return
        }
        Task { await model.setTolerance(dimension, to: limit) }
    }

    private func checkTolerances() {
        Task {
            let messages = await model.checkTolerances()
            // Every channel, because an exception's whole purpose is to reach
            // the person wherever they are (§19.10).
            for message in messages { await announce(message) }
        }
    }

    // MARK: - work breakdown

    @ViewBuilder
    private func wbsBox(_ project: Project) -> some View {
        GroupBox("แผนงาน (WBS) — ใบสุดท้ายคือสิ่งที่ส่งมอบได้") {
            VStack(alignment: .leading, spacing: 8) {
                if model.wbs.isEmpty {
                    Text("ยังไม่มีใบงาน — G2 ต้องการอย่างน้อย 1 ใบ")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(model.wbs.ordered) { package in
                        packageRow(package, project: project)
                            // P10.11 — order is the order somebody reads the
                            // plan in, and it could only be changed by
                            // deleting a package and adding it again at the
                            // end. Dropping onto a package with a different
                            // parent is refused in the model, not here: a drop
                            // that re-parented by accident would change what
                            // the plan says rather than the order it says it.
                            .draggable(package.id)
                            .dropDestination(for: String.self) { ids, _ in
                                guard let moved = ids.first else { return false }
                                Task { await model.reorder(moved, toPositionOf: package.id) }
                                return true
                            }
                    }
                }

                HStack {
                    TextField("เพิ่มงานที่ส่งมอบได้", text: $newPackageTitle)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addPackage(under: selectedParent) }
                    Picker("อยู่ใต้", selection: $selectedParent) {
                        Text("บนสุด").tag(String?.none)
                        ForEach(model.wbs.ordered) { package in
                            Text(package.title).tag(String?.some(package.id))
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("เลือกงานแม่ของใบงานใหม่")
                    Button("เพิ่ม") { addPackage(under: selectedParent) }
                        .disabled(newPackageTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if !model.problems.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(model.problems) { problem in
                            Text("• " + problem.text)
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func packageRow(_ package: WorkPackage, project: Project) -> some View {
        let leaf = model.wbs.isLeaf(package)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(String(repeating: "   ", count: model.wbs.depth(of: package)))
                // The title is edited where it is read (§19.2.4). Buffered like
                // every other field on this screen, because a write per keystroke
                // is what ate Thai characters here before.
                TextField("ชื่อสิ่งที่ส่งมอบ", text: Binding(
                    get: { titleDrafts[package.id] ?? package.title },
                    set: { titleDrafts[package.id] = $0 }))
                    .textFieldStyle(.plain)
                    .font(leaf ? .callout : .callout.bold())
                    .accessibilityLabel("ชื่อใบงาน \(package.title)")
                    .onSubmit { commitTitle(for: package) }
                Spacer()
                if leaf {
                    Text(package.status.label)
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                if leaf, let startWork {
                    // P10.4's missing half: the leaf could describe itself as
                    // an assignment and nothing could start one, so the plan
                    // and the team were joined by a field nobody could act on.
                    Button("เปิดงานใบนี้") { _ = startWork(package) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .disabled(package.acceptanceCriteria.isEmpty)
                        .help(package.acceptanceCriteria.isEmpty
                              ? "ใบที่ไม่มีเกณฑ์ตรวจรับ ส่งให้ใครทำไม่ได้ — ไม่มีอะไรให้ตรวจว่าเสร็จ"
                              : "เอาใบนี้ไปเป็นงานของทีม แล้วตรวจเกณฑ์ก่อนสั่งเริ่ม")
                        .accessibilityLabel("เปิดงาน \(package.title) กับทีม")
                }
                Button {
                    Task { await model.removePackage(package.id) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("ลบใบงาน \(package.title) และทุกใบที่อยู่ข้างใน")
            }

            if leaf {
                HStack(spacing: 8) {
                    // What is handed over, and how much is at stake — both are
                    // things a person sets, and `riskClass` decides whether a
                    // human has to be accountable (§19.9), so it cannot stay a
                    // field only the tests can reach.
                    TextField("ส่งมอบเป็นอะไร", text: Binding(
                        get: { package.deliverableType },
                        set: { value in
                            var next = package; next.deliverableType = value
                            Task { await model.update(next) }
                        }))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .frame(maxWidth: 160)
                        .accessibilityLabel("ชนิดของสิ่งที่ส่งมอบสำหรับ \(package.title)")

                    Picker("ความเสี่ยง", selection: Binding(
                        get: { package.riskClass },
                        set: { level in
                            var next = package; next.riskClass = level
                            Task { await model.update(next) }
                        })) {
                        ForEach(RiskLevel.allCases, id: \.self) { level in
                            Text(riskLabel(level)).tag(level)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 110)
                    .accessibilityLabel("ระดับความเสี่ยงของ \(package.title)")

                    Picker("ผูกกับขอบเขต", selection: Binding(
                        get: { package.scopeRef },
                        set: { ref in
                            var next = package; next.scopeRef = ref
                            Task { await model.update(next) }
                        })) {
                        Text("— ยังไม่ผูก —").tag(String?.none)
                        ForEach(project.statement.inScope, id: \.self) { line in
                            Text(line).tag(String?.some(line))
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("ผูกใบงาน \(package.title) กับข้อในขอบเขต")

                    Picker("บทบาท", selection: Binding(
                        get: { package.role },
                        set: { role in
                            var next = package; next.role = role
                            Task { await model.update(next) }
                        })) {
                        Text("— ยังไม่มอบหมาย —").tag(Role?.none)
                        ForEach(Role.allCases, id: \.self) { role in
                            Text(role.rawValue).tag(Role?.some(role))
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("มอบหมายใบงาน \(package.title)")
                }

                // Same buffer-and-commit as the project fields: writing on
                // every keystroke is what ate characters here too.
                TextField("เสร็จแปลว่าอะไร — คั่นด้วย ·",
                          text: Binding(
                            get: {
                                criteriaDrafts[package.id]
                                    ?? package.acceptanceCriteria.map(\.text).joined(separator: " · ")
                            },
                            set: { criteriaDrafts[package.id] = $0 }),
                          axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .accessibilityLabel("เกณฑ์เสร็จของใบงาน \(package.title)")
                    .onSubmit { commitCriteria(for: package) }

                // Dependencies, edited as "which of these must finish first"
                // rather than by dragging a line: §19.7 keeps only
                // finish-to-start, so there is nothing a line could express that
                // a toggle cannot — and the critical path below is computed from
                // exactly this list.
                let candidates = model.wbs.leaves.filter { $0.id != package.id }
                if !candidates.isEmpty {
                    HStack(spacing: 4) {
                        Text("ต้องเสร็จก่อน")
                            .font(.caption2).foregroundStyle(.secondary)
                        ForEach(candidates) { other in
                            Toggle(other.title, isOn: Binding(
                                get: { package.dependsOn.contains(other.id) },
                                set: { on in
                                    var next = package
                                    if on {
                                        guard !next.dependsOn.contains(other.id) else { return }
                                        next.dependsOn.append(other.id)
                                    } else {
                                        next.dependsOn.removeAll { $0 == other.id }
                                    }
                                    Task { await model.update(next) }
                                }))
                                .toggleStyle(.button)
                                .controlSize(.mini)
                                .accessibilityLabel("\(other.title) ต้องเสร็จก่อน \(package.title)")
                        }
                        Spacer()
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func addPackage(under parent: String?) {
        let title = newPackageTitle
        newPackageTitle = ""
        Task { await model.addPackage(title: title, parent: parent) }
    }

    /// Thai for the three levels. `RiskLevel.description` is the English the
    /// hook chain logs; this screen is read by a person.
    private func riskLabel(_ level: RiskLevel) -> String {
        switch level {
        case .low: "เสี่ยงต่ำ"
        case .medium: "เสี่ยงกลาง"
        case .high: "เสี่ยงสูง"
        }
    }

    private func commitTitle(for package: WorkPackage) {
        guard let draft = titleDrafts[package.id] else { return }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        titleDrafts[package.id] = nil
        // An empty title is not a rename, it is a deleted name — and a leaf with
        // no title cannot be reviewed against anything.
        guard !trimmed.isEmpty, trimmed != package.title else { return }
        var next = package
        next.title = trimmed
        Task { await model.update(next) }
    }

    private func stageStrip(_ current: ProjectStage) -> some View {
        HStack(spacing: 4) {
            ForEach(ProjectStage.allCases, id: \.self) { stage in
                Text(stage.label)
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                    .background(stage == current ? Color.accentColor.opacity(0.18) : Color.clear,
                                in: RoundedRectangle(cornerRadius: Radius.control))
                    .foregroundStyle(stage <= current ? Color.primary : Color.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("ขั้นของโครงการ ตอนนี้อยู่ขั้น\(current.label)")
    }

    private func gateBox(_ gate: GateEvaluation) -> some View {
        GroupBox("\(gate.gate) → ขั้น\(gate.to.label)") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(gate.conditions.enumerated()), id: \.offset) { _, condition in
                    Label {
                        HStack(spacing: 6) {
                            Text(condition.text)
                            if condition.vacuous {
                                Text("ยังไม่มีอะไรให้ตรวจ")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        // A tick that means "nothing was checked" must not look
                        // like one that means "checked and fine".
                        Image(systemName: condition.vacuous ? "minus.circle"
                              : (condition.satisfied ? "checkmark.circle" : "circle"))
                            .foregroundStyle(condition.vacuous ? Color.secondary
                                             : (condition.satisfied ? Color.green : Color.secondary))
                    }
                    .font(.callout)
                }

                HStack {
                    Button("ผ่านขั้นนี้") { Task { await model.advance() } }
                        .disabled(!gate.passed)
                        .keyboardShortcut(.return, modifiers: [.command])
                    Button("ยุติโครงการ") { Task { await model.terminate(reason: "ผู้ใช้สั่งยุติ") } }
                    Spacer()
                }
                if !gate.passed {
                    Text("ขั้นนี้ยังใช้เครื่องมือที่\(allowedText(gate.from))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func allowedText(_ stage: ProjectStage) -> String {
        switch stage {
        case .initiation: "อ่านอย่างเดียว"
        case .planning: "อ่านและร่างเอกสารได้ แต่ยังเปลี่ยนข้อมูลไม่ได้"
        case .execution: "ทำได้ทุกอย่างตามระดับความเสี่ยง"
        case .closing: "เขียนรายงานได้ แต่ตัวเลขต้องไม่ขยับแล้ว"
        case .closed: "อ่านอย่างเดียว"
        }
    }

    // MARK: - editing helpers

    // MARK: - editing without fighting the database
    //
    // Driving this screen by hand found the bug this replaces. Every keystroke
    // used to write to SurrealDB and reload the project, and the reload landed
    // with text older than what had been typed since — so typing a Thai
    // sentence dropped characters, one per round-trip. Nothing in the unit
    // tests could see it: the view model saved correctly, the store stored
    // correctly, and only the two together ate the input.
    //
    // Now the fields edit a local copy and commit after a pause. The database
    // is the source of truth, not the keyboard's opponent.

    struct Draft: Equatable {
        var projectID: String = ""
        var brief: String = ""
        var inScope: String = ""
        var outOfScope: String = ""
        var acceptance: String = ""
        var executive: String = ""
        var seniorUser: String = ""

        init() {}

        init(_ project: Project) {
            projectID = project.id.rawValue
            brief = project.brief
            inScope = project.statement.inScope.joined(separator: "\n")
            outOfScope = project.statement.outOfScope.joined(separator: "\n")
            acceptance = project.statement.acceptanceCriteria.joined(separator: "\n")
            executive = project.board.first { $0.seat == .executive }?.person ?? ""
            seniorUser = project.board.first { $0.seat == .seniorUser }?.person ?? ""
        }

        func applied(to project: Project) -> Project {
            var next = project
            next.brief = brief
            next.statement.inScope = Draft.lines(inScope)
            next.statement.outOfScope = Draft.lines(outOfScope)
            next.statement.acceptanceCriteria = Draft.lines(acceptance)
            // Rebuilt rather than patched: a seat cleared in the field is a
            // seat nobody holds, and leaving the old name behind would make
            // G1 pass on a person who is no longer there.
            var board: [BoardRole] = []
            let exec = executive.trimmingCharacters(in: .whitespacesAndNewlines)
            if !exec.isEmpty { board.append(BoardRole(seat: .executive, person: exec)) }
            let senior = seniorUser.trimmingCharacters(in: .whitespacesAndNewlines)
            if !senior.isEmpty { board.append(BoardRole(seat: .seniorUser, person: senior)) }
            next.board = board
            return next
        }

        /// Splitting happens at commit time, never while typing: trimming and
        /// dropping empty lines on every keystroke is what made it impossible
        /// to press Return and start a second bullet.
        static func lines(_ text: String) -> [String] {
            text.split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }

    @ViewBuilder
    private var savedHint: some View {
        Text(saving ? "กำลังบันทึก…" : "บันทึกเองหลังหยุดพิมพ์")
            .font(.caption2).foregroundStyle(.secondary)
    }

    private func lineEditor(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: text)
                .frame(minHeight: 52)
                .accessibilityLabel("รายการ\(title) หนึ่งบรรทัดต่อหนึ่งข้อ")
        }
    }

    /// Seeds the buffer when the selected project changes, and only then —
    /// reseeding while somebody is typing is the same bug in a different shape.
    private func seedDraftIfNeeded(_ project: Project?) {
        guard let project else { draft = Draft(); return }
        guard draft.projectID != project.id.rawValue else { return }
        draft = Draft(project)
    }

    /// Turns the buffer into criteria and saves, once. `·` is the separator
    /// because a leaf's criteria are a short list and a multi-line editor per
    /// leaf would bury the tree it belongs to.
    private func commitCriteria(for package: WorkPackage) {
        guard let text = criteriaDrafts[package.id] else { return }
        let criteria = text.split(separator: "·", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { Criterion(text: $0, evidenceRequired: "หลักฐานที่ตรวจได้") }
        guard criteria != package.acceptanceCriteria else {
            criteriaDrafts.removeValue(forKey: package.id)
            return
        }
        var next = package
        next.acceptanceCriteria = criteria
        criteriaDrafts.removeValue(forKey: package.id)
        Task { await model.update(next) }
    }

    private func commitDraft() async {
        guard let project = model.selected, draft.projectID == project.id.rawValue else { return }
        let edited = draft.applied(to: project)
        guard edited != project else { return }
        saving = true
        // Two writes, because the baseline holds one of these and not the other
        // (§19.11): the scope statement is part of the agreement and goes through
        // change control, while the brief and the board seats are not — asking
        // for a change request to fix a typo in the brief would teach people to
        // click through the bar that asks (§19.2.4).
        if edited.statement != project.statement {
            await model.updateScope(edited.statement)
        }
        var withoutScope = edited
        withoutScope.statement = project.statement
        if withoutScope != project { await model.update(withoutScope) }
        saving = false
    }
}
