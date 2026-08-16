import SwiftUI
import AppKit
import RBridge

// ─────────────────────────────────────────────────────────────
// The R bridge, on a screen (§12.7, P14.1).
//
// The Done-when names two machines, and this view is judged on the second:
// **on a machine without R, it says what to install** — the name of the thing,
// where it comes from, and what to do next. Not "connection refused", not a
// red light with no sentence beside it.
//
// It writes the script and hands over the command; it never starts R itself,
// and it never installs a package. Both of those are in the file that
// generates the bridge, with the reasons.
// ─────────────────────────────────────────────────────────────

@MainActor
@Observable
final class RBridgeViewModel {
    private(set) var status: RSetupStatus?
    /// What `health` said last time it was asked, as a sentence either way.
    private(set) var health: String?
    private(set) var isHealthy = false
    private(set) var scriptPath: String?
    private(set) var problem: String?

    private let directory: URL
    private let probe = RProbe()

    init(directory: URL) {
        self.directory = directory
    }

    var startCommand: String {
        BridgeScript.startCommand(scriptPath: scriptPath ?? directory
            .appending(path: BridgeScript.fileName).path(percentEncoded: false))
    }

    func refresh() async {
        status = await probe.status()
        switch await RBridgeClient(scriptPath: startCommand).health() {
        case .success(let version):
            isHealthy = true
            health = "สะพานตอบอยู่ — R \(version)"
        case .failure(let error):
            isHealthy = false
            health = error.description
        }
    }

    /// Writes `r-bridge.R` where the analysis files live. Existing edits are
    /// kept; the file belongs to whoever opened it last.
    func writeScript() {
        do {
            scriptPath = try BridgeScript.write(into: directory).path(percentEncoded: false)
            problem = nil
        } catch {
            problem = "เขียนไฟล์ไม่สำเร็จ: \(error)"
        }
    }

    func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(startCommand, forType: .string)
    }
}

struct RBridgeSection: View {
    @Bindable var model: RBridgeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.box) {
            SectionHeading(
                title: "สะพาน R",
                help: "รันโค้ด R ด้วย R ตัวเดียวกับที่คุณใช้ใน RStudio — แอปไม่ได้เปิดให้เอง "
                    + "คุณเป็นคนสั่งเปิด และปิดเมื่อไหร่ก็ได้ (§12.7)",
                action: (title: "ตรวจอีกครั้ง", run: { Task { await model.refresh() } }))

            if let status = model.status {
                Text(status.nextStep)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            HStack(spacing: Space.row) {
                // The light says a word as well as a colour: a red dot on its
                // own is a state, not information.
                Image(systemName: model.isHealthy ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(model.isHealthy ? .green : .secondary)
                    .accessibilityHidden(true)
                Text(model.health ?? "ยังไม่ได้ตรวจ")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(model.isHealthy ? "สะพานทำงานอยู่" : "สะพานยังไม่ทำงาน")

            HStack(spacing: Space.row) {
                Button("สร้างไฟล์ r-bridge.R") { model.writeScript() }
                    .accessibilityHint("เขียนสคริปต์สะพานไว้ในโฟลเดอร์วิเคราะห์ ไม่ทับไฟล์ที่คุณแก้เอง")
                Button("คัดลอกคำสั่งเปิด") { model.copyCommand() }
                    .accessibilityHint("คัดลอกคำสั่งไปวางในเทอร์มินัลเพื่อเปิดสะพาน")
            }

            Text(model.startCommand)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .contentBox()

            // P14.4's half that belongs on a screen: the bridge runs as you,
            // in your home directory, with your library paths. Somebody
            // deciding whether to open it needs that said plainly.
            Text("สะพานรันด้วยสิทธิ์ของคุณเอง เห็นไฟล์ทุกอย่างที่คุณเห็น และใช้ไลบรารี R ของคุณ — "
                 + "โค้ดที่ส่งเข้าไปจึงถูกจัดเป็นความเสี่ยงสูงเสมอ และหยุดถามก่อนรันเหมือน `run_shell` · "
                 + "ฟังเฉพาะ 127.0.0.1 เครื่องอื่นในวงเรียกไม่ได้")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let problem = model.problem {
                Text(problem).font(.callout).foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .task { await model.refresh() }
    }
}
