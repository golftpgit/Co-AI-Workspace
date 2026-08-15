import SwiftUI
import AgentKit
import MCPBridge

// ─────────────────────────────────────────────────────────────
// Adding an MCP server by naming what it runs (ARCHITECTURE §6.2, §15).
//
// `MCPServerStore` has been on the engine since P8.3 and no screen read it —
// found by the `check.sh` rule written for the channels, on the day it was
// written. A packaged plugin could be installed (P8.4); a server pointed at by
// command still meant editing JSON beside the database.
//
// The screen shows two things a person cannot see in the JSON: **the prefix
// every tool from this server will actually carry**, which is derived from the
// name and drops everything non-ASCII, and **why a server will not launch** —
// which since P9.3 distinguishes a token nobody entered from a Keychain that
// would not open.
//
// Like the channels: what is saved here takes effect at the next launch,
// because servers are connected once during boot. Said out loud rather than
// implied.
// ─────────────────────────────────────────────────────────────

@MainActor
@Observable
final class MCPServersViewModel {
    private(set) var servers: [MCPServerConfig] = []
    /// The draft is always a value and the sheet is opened by a separate flag.
    ///
    /// The obvious shape — an optional draft, `.sheet(isPresented:)` derived
    /// from it, and `Binding($model.editing)` inside — **crashes**, and it
    /// crashed on this screen and on the channels screen in front of me:
    /// saving sets the optional to nil, SwiftUI re-evaluates the sheet's body
    /// once more before it finishes dismissing, and the force-unwrapping
    /// binding traps in `BindingOperations.ForceUnwrapping.get`. Found by
    /// pressing the button, not by any test (U33-1).
    var draft = MCPServerDraft()
    var isEditing = false
    private(set) var editingID: String?
    private(set) var problem: String?

    private var store: MCPServerStore?

    func attach(store: MCPServerStore) {
        self.store = store
        reload()
    }

    func reload() {
        servers = store?.load() ?? []
    }

    func startNew() {
        editingID = nil
        draft = MCPServerDraft()
        isEditing = true
    }

    func edit(_ server: MCPServerConfig) {
        editingID = server.id
        draft = MCPServerDraft(server)
        isEditing = true
    }

    func save() {
        guard let store, draft.canSave else { return }
        var all = servers
        let config = draft.config(id: editingID)
        if let index = all.firstIndex(where: { $0.id == config.id }) {
            all[index] = config
        } else {
            all.append(config)
        }
        write(all) { self.isEditing = false; self.editingID = nil }
    }

    func remove(_ server: MCPServerConfig) {
        write(servers.filter { $0.id != server.id })
    }

    private func write(_ all: [MCPServerConfig], then finish: () -> Void = {}) {
        guard let store else { return }
        do {
            try store.save(all)
            problem = nil
            finish()
            reload()
        } catch {
            problem = ReadableFailure.message(for: error, doing: "บันทึกรายการ MCP server")
        }
    }
}

struct MCPServersView: View {
    @Bindable var model: MCPServersViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MCP server").font(.headline)
                    Text("เครื่องมือของคนอื่นที่รันบนเครื่องนี้ — ทุกทูลที่ได้มาเดินผ่าน hook chain เดียวกับทูลในตัว (§6.2)")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("เพิ่มเซิร์ฟเวอร์") { model.startNew() }
            }

            if model.servers.isEmpty {
                Text("ยังไม่มีเซิร์ฟเวอร์ที่ตั้งไว้เอง — ปลั๊กอินที่ติดตั้งด้านล่างเป็นคนละรายการ")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.servers) { server in
                row(server)
            }
            if let problem = model.problem {
                Text(problem).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Text("เพิ่มหรือแก้ที่นี่แล้วมีผลตอนเปิดแอปครั้งถัดไป — เซิร์ฟเวอร์ถูกต่อครั้งเดียวตอนบูต")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $model.isEditing) { MCPServerEditor(model: model) }
    }

    private func row(_ server: MCPServerConfig) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Circle().fill(server.isReady ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(server.name).fontWeight(.medium)
                // The thing the JSON never shows: what the tools are called.
                Text("mcp__\(server.namespace)__…")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button("แก้") { model.edit(server) }
                    .buttonStyle(.borderless).font(.caption)
                Button("ลบ", role: .destructive) { model.remove(server) }
                    .buttonStyle(.borderless).font(.caption)
            }
            Text(([server.command] + server.arguments).joined(separator: " "))
                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(server.blockers, id: \.self) { blocker in
                Text("• \(blocker)").font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(server.name) · ทูลขึ้นต้นด้วย mcp \(server.namespace) · "
                            + (server.isReady ? "พร้อมต่อ" : "ยังไม่พร้อม"))
    }
}

// ─────────────────────────────────────────────────────────────

private struct MCPServerEditor: View {
    @Bindable var model: MCPServersViewModel

    var body: some View {
        @Bindable var model = model
        let draft = $model.draft
        return VStack(alignment: .leading, spacing: 12) {
                Text(draft.wrappedValue.name.isEmpty ? "เพิ่ม MCP server"
                                                     : "แก้ \(draft.wrappedValue.name)")
                    .font(.headline)

                LabeledContent("ชื่อ") { TextField("weather", text: draft.name) }
                Text("ทูลจากเซิร์ฟเวอร์นี้จะชื่อขึ้นต้นว่า `mcp__\(draft.wrappedValue.namespace)__`")
                    .font(.caption2).foregroundStyle(.secondary)

                LabeledContent("คำสั่ง") { TextField("npx", text: draft.command) }
                LabeledContent("อาร์กิวเมนต์") {
                    TextField("-y weather-mcp", text: draft.argumentsText)
                }
                Text("เว้นวรรคคั่น · ถ้ามีช่องว่างในค่าให้ใส่เครื่องหมายคำพูดครอบ "
                     + "อ่านได้ \(draft.wrappedValue.arguments.count) ตัว")
                    .font(.caption2).foregroundStyle(.secondary)

                LabeledContent("โฟลเดอร์ที่รัน (ว่างได้)") {
                    TextField("/Users/…/project", text: draft.workingDirectory)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("ตัวแปรที่เซิร์ฟเวอร์ต้องการ").font(.callout)
                    TextEditor(text: draft.environmentText)
                        .font(.caption.monospaced())
                        .frame(height: 60)
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3)))
                        .accessibilityLabel("ตัวแปรที่เซิร์ฟเวอร์ต้องการ")
                    Text("บรรทัดละหนึ่งคู่ `WEATHER_API_KEY = ชื่อที่เก็บไว้` — "
                         + "ไฟล์เก็บแค่ชื่อ ค่าอยู่ใน Keychain (ตั้งค่าได้ที่หน้า endpoint) · "
                         + "อ่านได้ \(draft.wrappedValue.environmentVariables.count) คู่")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle("เปิดใช้งาน", isOn: draft.isEnabled)

                ForEach(draft.wrappedValue.problems, id: \.self) { problem in
                    Text("• \(problem)").font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(draft.wrappedValue.warnings, id: \.self) { warning in
                    Text(.init("• \(warning)")).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Spacer()
                    Button("ปิด") { model.isEditing = false }
                    Button("บันทึก") { model.save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!draft.wrappedValue.canSave)
                }
            }
            .padding(20)
            .frame(width: 560)
    }
}
