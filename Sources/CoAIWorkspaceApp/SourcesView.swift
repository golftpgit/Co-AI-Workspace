import SwiftUI
import AgentKit
import Knowledge

// ─────────────────────────────────────────────────────────────
// The source registry, visible (ARCHITECTURE §1.4, §19.2, P10.12).
//
// The registry has decided every citation's tier since P3, and until now nobody
// could see it. That matters more here than for most tables: §14.1's rule is
// that a claim needs corroboration from a good enough tier, so a person reading
// "ยังไม่ผ่าน QA เพราะแหล่งอ่อน" had no way to find out what the system thinks
// is strong.
//
// Read-only for now, and it says so. Turning a source off is a setting that has
// to survive a relaunch, and the registry is still a value built at boot rather
// than a stored one (P13) — a toggle that forgets itself overnight is worse than
// a list that admits it cannot be edited yet.
// ─────────────────────────────────────────────────────────────

struct SourcesView: View {
    let registry: SourceRegistry
    @State private var discipline: Discipline?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("แหล่งและชั้นความน่าเชื่อถือ").font(.headline)
                Picker("สาขา", selection: $discipline) {
                    Text("ทุกสาขา").tag(Discipline?.none)
                    ForEach(Discipline.allCases, id: \.self) { subject in
                        Text(subject.label).tag(Discipline?.some(subject))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
                .accessibilityLabel("กรองแหล่งตามสาขา")
                Spacer()
                Text("\(shown.count) แหล่ง").font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()

            List {
                ForEach(SourceTier.allCases, id: \.self) { tier in
                    let sources = shown.filter { $0.tier == tier }
                    if !sources.isEmpty {
                        Section {
                            ForEach(sources) { source in
                                row(source)
                            }
                        } header: {
                            Text("\(tier.rawValue.uppercased()) — \(tierMeaning(tier))")
                        }
                    }
                }
            }

            Divider()
            Text("โดเมนที่ไม่อยู่ในทะเบียนนี้ถือเป็น T5 (เว็บทั่วไป) ไม่ใช่ \"ไม่รู้จัก\" — "
                 + "หน้าที่ไม่มีใครรับรองคือเว็บทั่วไป และการปล่อยให้มันไม่มี tier "
                 + "จะทำให้มันหลุดตัวกรองที่ตรวจ tier · แก้รายการยังทำไม่ได้ (P13)")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(10)
        }
    }

    private var shown: [Source] {
        guard let discipline else { return registry.sources }
        return registry.sources.filter {
            $0.disciplines.contains(discipline) || $0.disciplines.contains(.general)
        }
    }

    @ViewBuilder
    private func row(_ source: Source) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(source.name).font(.callout)
                Text(source.domain).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !source.isEnabled {
                    Text("ปิดอยู่").font(.caption2).foregroundStyle(.orange)
                }
            }
            Text(source.disciplines.map(\.label).joined(separator: " · ")
                 + " · เข้าถึงโดย \(accessLabel(source.access))")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(source.name) โดเมน \(source.domain) ชั้น \(source.tier.rawValue)")
    }

    private func tierMeaning(_ tier: SourceTier) -> String {
        switch tier {
        case .t1: "เอกสารทางการ · มาตรฐาน · กฎหมาย"
        case .t2: "ผ่าน peer review"
        case .t3: "preprint และรายงานกึ่งทางการ"
        case .t4: "ชุมชนที่ตรวจกันเอง"
        case .t5: "เว็บทั่วไป — ต้องมีแหล่งชั้นบนยืนยัน"
        }
    }

    private func accessLabel(_ access: AccessMethod) -> String {
        switch access {
        case .api(let name): "API ของ \(name)"
        case .siteQuery: "ค้นเฉพาะโดเมน"
        case .metaSearch: "meta-search แล้วอ่านหน้าจริง"
        }
    }
}
