import SwiftUI
import Linkage

// ─────────────────────────────────────────────────────────────
// Who was asked, and who came back (ARCHITECTURE §20.7, P11.7b).
//
// This screen is where the anonymous code stops being an idea. Somebody is
// enrolled, gets a code, and is sent a link that ends in `?code=P-…`; their
// answers arrive against that code; and in wave 3 the same code is still theirs,
// which is what lets "did the people who were burning out in March improve by
// June" be asked without a name ever sitting beside an answer.
//
// The one thing this screen can do that no other part of the app can — turn a
// code back into a person — is deliberately awkward: it needs a reason and a
// name, it shows one identity at a time, and it forgets it as soon as the sheet
// closes. Every attempt is written to the audit trail, successful or not. That is
// §20.7 invariant 3 made into a shape a person experiences rather than a rule
// they are told about.
// ─────────────────────────────────────────────────────────────

struct ParticipantsBox: View {
    @Bindable var model: InstrumentsViewModel

    @State private var identity = ""
    @State private var revealing: String?
    @State private var reason = ""
    @State private var who = ""

    var body: some View {
        GroupBox("ผู้เข้าร่วม (รหัสนิรนาม สำหรับงานหลายรอบ)") {
            VStack(alignment: .leading, spacing: 8) {
                enrolRow
                if !model.attrition.isEmpty { attritionRows }
                if model.participants.isEmpty {
                    Text("ยังไม่มีผู้เข้าร่วมที่ลงทะเบียน — งานที่เก็บรอบเดียวแบบนิรนามไม่ต้องใช้ส่วนนี้")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    codes
                }
                Text(markdown: "ตัวตนของผู้เข้าร่วมถูกเข้ารหัสไว้ใน **ไฟล์คนละไฟล์กับคำตอบ** "
                     + "ด้วยคีย์ใน Keychain ของโปรเจกต์นี้ — สำเนาข้อมูลคำตอบจึงไม่มีตัวตนติดไปเลย · "
                     + "การเปิดดูว่ารหัสไหนเป็นใคร **ถูกบันทึกทุกครั้ง** พร้อมเหตุผลและชื่อคนที่เปิด (§20.7)")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var enrolRow: some View {
        HStack {
            TextField("อีเมลหรือชื่อผู้เข้าร่วม (เก็บแบบเข้ารหัส)", text: $identity)
                .textFieldStyle(.roundedBorder)
            Button("ลงทะเบียนและออกรหัส") {
                let value = identity
                identity = ""
                Task { await model.enrol(identity: value) }
            }
            .disabled(identity.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("เชิญทุกคนเข้ารอบนี้") { Task { await model.inviteAllToCurrentWave() } }
                .disabled(model.participants.isEmpty || !model.waveIsOpen)
        }
        .controlSize(.small)
    }

    private var attritionRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.attrition, id: \.waveID) { row in
                HStack(spacing: 6) {
                    Image(systemName: "person.2")
                        .foregroundStyle(.secondary)
                    // The number a longitudinal study has to report, and the one
                    // that decides whether its later waves mean anything.
                    Text("รอบนี้: เชิญ \(row.invited) คน · ตอบกลับ \(row.responded) คน "
                         + String(format: "(%.0f%%)", row.rate * 100))
                        .font(.caption)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var codes: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.participants) { participant in
                HStack(spacing: 8) {
                    Text(participant.code)
                        .font(.system(.caption, design: .monospaced))
                    Text(participant.enrolledAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("คัดลอกลิงก์") {
                        let base = model.serving?.urls.first ?? ""
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("\(base)?code=\(participant.code)",
                                                       forType: .string)
                    }
                    .disabled(model.serving == nil)
                    .accessibilityLabel("คัดลอกลิงก์แบบสอบถามของรหัส \(participant.code)")
                    Button("ดูว่าเป็นใคร") {
                        reason = ""
                        revealing = participant.code
                    }
                    .accessibilityLabel("เปิดดูตัวตนของรหัส \(participant.code) — จะถูกบันทึก")
                }
                .controlSize(.small)
            }
        }
        .sheet(isPresented: Binding(get: { revealing != nil },
                                    set: { if !$0 { revealing = nil; model.hideRevealed() } })) {
            revealSheet
        }
    }

    @ViewBuilder
    private var revealSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("เปิดดูตัวตนของรหัส \(revealing ?? "")").font(.headline)
            Text("การเปิดดูนี้จะถูกบันทึกไว้พร้อมเหตุผลและชื่อของคุณ ไม่ว่าจะพบรหัสนี้หรือไม่ — "
                 + "คำถามที่บันทึกตอบคือ “ใครเปิดดู” ไม่ใช่ “ใครเปิดดูสำเร็จ”")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("เหตุผลที่ต้องเปิดดู", text: $reason)
                .textFieldStyle(.roundedBorder)
            TextField("ชื่อคุณ", text: $who)
                .textFieldStyle(.roundedBorder)

            if let revealed = model.revealed, revealed.code == revealing {
                GroupBox {
                    Text(revealed.identity)
                        .font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack {
                Spacer()
                Button("ปิด") { revealing = nil; model.hideRevealed() }
                Button("เปิดดู") {
                    guard let code = revealing else { return }
                    Task { await model.reveal(code: code, reason: reason, by: who) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(reason.trimmingCharacters(in: .whitespaces).isEmpty
                          || who.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}
