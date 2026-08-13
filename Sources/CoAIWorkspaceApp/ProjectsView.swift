import SwiftUI
import AgentKit
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
    @State private var newName = ""
    @State private var newKind = ProjectKind.blank
    @State private var newPackageTitle = ""
    @State private var selectedParent: String?
    @State private var decision = ""
    @State private var decider = ""
    @State private var registerTitle = ""
    @State private var registerKind = RegisterKind.risk
    @State private var draft = Draft()
    @State private var saving = false
    /// Per-leaf editing buffers, keyed by package id. Same reason as `draft`.
    @State private var criteriaDrafts: [String: String] = [:]
    /// Sends an exception report out through every running channel. Passed in
    /// rather than reached for: this screen does not know what a channel is.
    let announce: (String) async -> Void

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
                        Task { await model.select(.general) }
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
                            Task { await model.select(.project(project.id)) }
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
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Picker("ชนิด", selection: $newKind) {
                        ForEach(ProjectKind.allCases, id: \.self) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .labelsHidden()
                    Button("สร้าง") {
                        Task {
                            await model.create(name: newName, kind: newKind)
                            newName = ""
                        }
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(12)
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
            .padding(16)
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

        wbsBox(project)

        toleranceBox()

        registerBox()

        baselineBox()

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

                Text("แกนที่ยังไม่ได้วัดมีกรอบและบังคับอยู่จริง แต่แอปยังไม่ได้ต่อค่าเข้ามา (P10.15)")
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
                Text(String(repeating: "   ", count: model.wbs.depth(of: package)) + package.title)
                    .font(leaf ? .callout : .callout.bold())
                Spacer()
                if leaf {
                    Text(package.status.label)
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
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
            }
        }
        .padding(.vertical, 2)
    }

    private func addPackage(under parent: String?) {
        let title = newPackageTitle
        newPackageTitle = ""
        Task { await model.addPackage(title: title, parent: parent) }
    }

    private func stageStrip(_ current: ProjectStage) -> some View {
        HStack(spacing: 4) {
            ForEach(ProjectStage.allCases, id: \.self) { stage in
                Text(stage.label)
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                    .background(stage == current ? Color.accentColor.opacity(0.18) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5))
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
                        Text(condition.text)
                    } icon: {
                        Image(systemName: condition.satisfied ? "checkmark.circle" : "circle")
                            .foregroundStyle(condition.satisfied ? Color.green : Color.secondary)
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
        await model.update(edited)
        saving = false
    }
}
