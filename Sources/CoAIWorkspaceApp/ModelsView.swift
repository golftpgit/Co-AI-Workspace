import SwiftUI
import MLXRuntime

// ─────────────────────────────────────────────────────────────
// The model manager (ARCHITECTURE §9.4, P5.2).
//
// Two lists and one number: what is on this machine, what can be fetched, and
// how much space that leaves. The number is not decoration — one 30B
// checkpoint is 17 GB, and the app is the only thing here that can fill a
// disk.
// ─────────────────────────────────────────────────────────────

struct ModelsView: View {
    @Bindable var model: ModelsViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    installedSection
                    recommendedSection
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.refresh() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("โมเดลบนเครื่อง (Tier 0.5)").font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                if let storage = model.storage {
                    Text("ใช้ไป \(bytes(storage.usedBytes)) จากโควตา \(bytes(storage.quotaBytes)) · "
                         + "ดิสก์ว่าง \(bytes(storage.freeDiskBytes))")
                }
                // §9.4's RAM→size→work table, for this machine specifically.
                Text("RAM \(bytes(model.memory.totalBytes)) (ว่าง \(bytes(model.memory.availableBytes))) "
                     + "→ แนะนำ \(model.sizeClass.recommendedSize) · \(model.sizeClass.trustedWith)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
            if let status = model.status {
                Text(status.message)
                    .font(.caption)
                    .foregroundStyle(status.isError ? .red : .secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 380, alignment: .trailing)
            }
        }
        .padding(12)
    }

    // MARK: - installed

    @ViewBuilder
    private var installedSection: some View {
        Text("ติดตั้งแล้ว").font(.subheadline).bold()
        if model.installed.isEmpty {
            // Says what the absence means, not just that the list is empty:
            // with no model here the guaranteed floor (§9.2 ข้อ 4) is missing.
            ContentUnavailableView(
                "ยังไม่มีโมเดลบนเครื่องนี้",
                systemImage: "cpu",
                description: Text("Tier 0.5 คือพื้นรับประกัน — ถ้า endpoint ล่มหรือออฟไลน์ "
                                  + "งานที่ต้องความแม่นสูงจะไม่มีที่รัน เลือกโหลดสักตัวจากรายการข้างล่าง"))
                .frame(height: 160)
        } else {
            ForEach(model.installed, id: \.name) { installed in
                InstalledRow(model: model, installed: installed)
            }
        }
    }

    // MARK: - recommended

    @ViewBuilder
    private var recommendedSection: some View {
        Text("โหลดเพิ่ม").font(.subheadline).bold()
        Text("รายการนี้คือโมเดลที่ runtime ของเราโหลดได้จริง — ไม่ใช่ทุกอย่างที่มีบน Hugging Face")
            .font(.caption).foregroundStyle(.secondary)
        ForEach(model.recommended) { entry in
            CatalogRow(model: model, entry: entry)
        }
    }

    private func bytes(_ value: Int64) -> String { ModelsView.format(value) }

    static func format(_ value: Int64) -> String {
        let gb = Double(value) / 1_073_741_824
        return gb >= 1 ? String(format: "%.1f GB", gb)
                       : String(format: "%.0f MB", Double(value) / 1_048_576)
    }
}

private struct InstalledRow: View {
    @Bindable var model: ModelsViewModel
    let installed: LocalModel
    @State private var removable = false
    @State private var confirmingDelete = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(installed.name).font(.body).bold()
                    if model.isSelected(installed) {
                        Text("ใช้อยู่")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.tint.opacity(0.15), in: Capsule())
                    }
                }
                Text("\(ModelsView.format(installed.sizeOnDisk)) · context \(installed.contextWindow) "
                     + "· \(installed.supportsTools ? "เรียกทูลได้" : "เรียกทูลไม่ได้")")
                    .font(.caption).foregroundStyle(.secondary)
                // The estimate the selection is allowed or refused on, shown
                // with its numbers rather than as a verdict the user has to
                // take on trust.
                let admission = model.admission(for: installed)
                Text(admission.reason)
                    .font(.caption2)
                    .foregroundStyle(admission.isBlocking ? Color.red
                                     : admission.verdict == .tight ? Color.orange : Color.secondary)
                if !removable {
                    // Explains why Delete is missing: the catalogue also finds
                    // models owned by LM Studio, and this app does not delete
                    // other applications' files.
                    Text("อยู่นอกโฟลเดอร์ของแอป — ลบจากที่นี่ไม่ได้")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if !model.isSelected(installed) {
                Button("ใช้ตัวนี้") { model.select(installed) }
                    // Blocked rather than warned: §9.4 is explicit that a
                    // model over the line must not become the default.
                    .disabled(model.admission(for: installed).isBlocking)
            }
            if removable {
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label("ลบ", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .task { removable = await model.isRemovable(installed) }
        .confirmationDialog("ลบ \(installed.name)?",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("ลบ", role: .destructive) { Task { await model.delete(installed) } }
            Button("ยกเลิก", role: .cancel) {}
        } message: {
            Text("คืนพื้นที่ \(ModelsView.format(installed.sizeOnDisk)) — โหลดใหม่ได้ทีหลัง")
        }
    }
}

private struct CatalogRow: View {
    @Bindable var model: ModelsViewModel
    let entry: ModelCatalogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(entry.displayName) · \(entry.quantization)").font(.body).bold()
                Text(entry.summary).font(.caption).foregroundStyle(.secondary)
                Text("ดาวน์โหลด \(ModelsView.format(entry.downloadBytes)) · "
                     + "แนะนำ RAM \(ModelsView.format(entry.minimumRAMBytes)) ขึ้นไป")
                    .font(.caption2).foregroundStyle(.tertiary)
                let admission = model.admission(for: entry)
                if admission.isBlocking {
                    // Downloading is still allowed — the machine may have
                    // memory free later, and the user may be about to close
                    // everything else — but it says plainly that it cannot be
                    // made the default as things stand.
                    Label("\(admission.reason)", systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange)
                }
                if let download = model.downloads[entry.repository] {
                    ProgressView(value: download.fraction)
                        .frame(maxWidth: 320)
                    // "≈" because the Hub reports progress per file, not per
                    // byte; the figure is that fraction of the recorded size.
                    Text("≈ \(ModelsView.format(download.completedBytes)) / \(ModelsView.format(download.totalBytes))")
                        .font(.caption2).foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer()
            if model.isDownloading(entry) {
                Button("ยกเลิก") { model.cancel(entry) }
            } else {
                Button("โหลด") { model.download(entry) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}
