import Foundation

// ─────────────────────────────────────────────────────────────
// The list the user picks from (ARCHITECTURE §9.4, "โหลดจาก Hugging Face").
//
// "Recommended" here means one thing only: mlx-swift-lm's own registry has an
// implementation for this architecture, so the runtime can actually load it.
// A model that looks good on the Hub and fails at load is worse than no
// suggestion at all — the user has already spent the download by the time they
// find out.
//
// Sizes are the real totals from the Hub, recorded so the list is honest
// before anything is downloaded and still honest with no network. The
// installer reports the live figure while it runs.
// ─────────────────────────────────────────────────────────────

public struct ModelCatalogEntry: Sendable, Equatable, Identifiable {
    /// Hugging Face repository — also the identity used everywhere else.
    public let repository: String
    public let displayName: String
    /// Parameter count as advertised, and the quantisation that makes the
    /// number on disk different from the number in the name.
    public let parameters: String
    public let quantization: String
    public let downloadBytes: Int64
    /// From the RAM→size table in §9.4. Advisory here: refusing to set an
    /// oversized model as the default is admission control, which is P5.3.
    public let minimumRAMBytes: Int64
    /// What this size class can be trusted with, in the plan's own terms.
    public let summary: String

    public var id: String { repository }

    public init(repository: String, displayName: String, parameters: String,
                quantization: String, downloadBytes: Int64,
                minimumRAMBytes: Int64, summary: String) {
        self.repository = repository
        self.displayName = displayName
        self.parameters = parameters
        self.quantization = quantization
        self.downloadBytes = downloadBytes
        self.minimumRAMBytes = minimumRAMBytes
        self.summary = summary
    }
}

public enum RecommendedModels {
    private static let gigabyte: Int64 = 1_073_741_824

    /// Ordered smallest first, so the list reads as a ladder and the machine's
    /// own RAM decides where the user should stop.
    public static let all: [ModelCatalogEntry] = [
        ModelCatalogEntry(
            repository: "mlx-community/Qwen3-0.6B-4bit",
            displayName: "Qwen3 0.6B",
            parameters: "0.6B", quantization: "4-bit",
            downloadBytes: 350_000_000,
            minimumRAMBytes: 4 * gigabyte,
            summary: "เล็กที่สุด — ไว้ตรวจว่าเส้นทางโหลด/รันทำงาน ไม่ใช่ไว้ทำงานจริง"),
        ModelCatalogEntry(
            repository: "mlx-community/Qwen3-4B-4bit",
            displayName: "Qwen3 4B",
            parameters: "4B", quantization: "4-bit",
            downloadBytes: 2_280_000_000,
            minimumRAMBytes: 8 * gigabyte,
            summary: "เทียบเท่า Tier 0 — ใช้เป็น fallback ตอนโมเดล on-device ปฏิเสธงาน"),
        ModelCatalogEntry(
            repository: "mlx-community/Qwen3-8B-4bit",
            displayName: "Qwen3 8B",
            parameters: "8B", quantization: "4-bit",
            downloadBytes: 4_620_000_000,
            minimumRAMBytes: 16 * gigabyte,
            summary: "routing, extraction, สรุป, งานเขียนสั้น"),
        ModelCatalogEntry(
            repository: "mlx-community/Qwen3-30B-A3B-4bit",
            displayName: "Qwen3 30B A3B (MoE)",
            parameters: "30B (active 3B)", quantization: "4-bit",
            downloadBytes: 17_190_000_000,
            minimumRAMBytes: 32 * gigabyte,
            summary: "เกือบทุกอย่างยกเว้นงานที่ต้องการคุณภาพสูงสุด — MoE จึงเร็วกว่าขนาดของมัน"),
        ModelCatalogEntry(
            repository: "mlx-community/Qwen3.6-27B-4bit",
            displayName: "Qwen3.6 27B",
            parameters: "27B", quantization: "4-bit",
            downloadBytes: 16_080_000_000,
            minimumRAMBytes: 64 * gigabyte,
            summary: "ทดแทน Tier 1a ได้จริงเมื่อ endpoint ไม่ว่าง"),
    ]

    /// The machine's own RAM, for the "this will not fit" line in the list.
    public static var physicalMemory: Int64 {
        Int64(ProcessInfo.processInfo.physicalMemory)
    }

    public static func fits(_ entry: ModelCatalogEntry) -> Bool {
        entry.minimumRAMBytes <= physicalMemory
    }
}
