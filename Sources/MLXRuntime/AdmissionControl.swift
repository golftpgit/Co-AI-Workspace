import Foundation
import Darwin

// ─────────────────────────────────────────────────────────────
// Will this model actually run here? (ARCHITECTURE §9.4, P5.3)
//
// The failure this prevents is not an error message — it is the machine
// stopping. A model whose weights do not fit in what is free does not fail
// fast; it swaps, and everything on the Mac becomes unusable for minutes while
// a chat reply is generated one token at a time. So the size question is asked
// before a model is made the default, and again before each request, because
// the answer changes with whatever else the machine is doing.
//
// Sizes are estimated, not measured, and the estimate is anchored to one real
// measurement on this hardware rather than to a rule of thumb — see
// `estimatedResidentBytes`.
// ─────────────────────────────────────────────────────────────

public struct MachineMemory: Sendable, Equatable {
    public let totalBytes: Int64
    /// What could be handed to a new allocation right now: free pages plus the
    /// ones the kernel can reclaim without swapping.
    public let availableBytes: Int64

    public init(totalBytes: Int64, availableBytes: Int64) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }

    public static func current() -> MachineMemory {
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            // Better to answer conservatively than to refuse everything: half
            // of physical memory is the assumption the rest of this file can
            // live with.
            return MachineMemory(totalBytes: total, availableBytes: total / 2)
        }
        let pageSize = Int64(sysconf(_SC_PAGESIZE))
        let reclaimable = Int64(stats.free_count) + Int64(stats.inactive_count)
            + Int64(stats.purgeable_count)
        return MachineMemory(totalBytes: total, availableBytes: reclaimable * pageSize)
    }
}

/// §9.4's RAM→size→work table, as something the UI can print and the code can
/// agree with.
public enum MachineSizeClass: Sendable, Equatable, CaseIterable {
    case under16, upTo32, upTo64, above64

    public static func forMachine(totalBytes: Int64) -> MachineSizeClass {
        let gigabytes = Double(totalBytes) / 1_073_741_824
        // 16 GB machines report slightly under 16 GiB; compare with a little
        // slack rather than declaring them "under 16".
        switch gigabytes {
        case ..<15.5: return .under16
        case ..<31.5: return .upTo32
        case ..<63.5: return .upTo64
        default: return .above64
        }
    }

    public var recommendedSize: String {
        switch self {
        case .under16: "3–4B (4-bit)"
        case .upTo32: "7–8B (4-bit)"
        case .upTo64: "14–32B (4-bit)"
        case .above64: "32–70B (4-bit)"
        }
    }

    /// What Tier 0.5 can be trusted with at this size, in the plan's own words.
    public var trustedWith: String {
        switch self {
        case .under16: "เทียบเท่า Tier 0 — ใช้เป็น fallback ตอน Tier 0 ปฏิเสธเท่านั้น"
        case .upTo32: "routing, extraction, สรุป, งานเขียนสั้น"
        case .upTo64: "เกือบทุกอย่างยกเว้นงานที่ต้องการคุณภาพสูงสุด"
        case .above64: "ทดแทน Tier 1a ได้จริงเมื่อ endpoint ไม่ว่าง"
        }
    }
}

public struct Admission: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        case fits
        /// Runnable, but with little room left on the machine — the user is
        /// told, and nothing is blocked.
        case tight
        /// Would not fit in what is free. Never made the default: this is the
        /// case that hangs the Mac rather than returning an error.
        case tooLarge
    }

    public let verdict: Verdict
    public let estimatedResidentBytes: Int64
    public let availableBytes: Int64
    /// One sentence with the numbers in it, for the screen.
    public let reason: String

    public var isBlocking: Bool { verdict == .tooLarge }
}

public enum AdmissionControl {
    /// Working context assumed when sizing the KV cache. Not the model's
    /// declared window: sizing for 32k on every model would refuse everything
    /// on a laptop, and a chat that reaches 8k tokens is already a long one
    /// (the transcript budget in `Engine` is 16k for all tiers together).
    public static let assumedContextTokens = 8_192

    /// Roughly what this model occupies once it is answering.
    ///
    /// Three parts, anchored to a measurement on this hardware rather than a
    /// rule of thumb: qwen3.5-9B-4bit is 5.6 GB on disk, and a 7.6k-token
    /// prompt to it took ~7.4 GB of unified memory (the note in `Engine`).
    ///
    ///  • the weights, which is what the file size already is
    ///  • the KV cache, computed from the model's own shape when config.json
    ///    gives it — for that model, ~128 KB per token, so ~1.0 GB at 7.6k
    ///  • activations and framework overhead, a flat 0.5 GB
    ///
    /// 5.6 + 1.0 + 0.5 ≈ 7.1 against 7.4 measured, which is close enough to
    /// keep a machine off the swap line and honest about being an estimate.
    public static func estimatedResidentBytes(
        _ model: LocalModel,
        contextTokens: Int = assumedContextTokens
    ) -> Int64 {
        let kv = LocalModelCatalog.kvCacheBytesPerToken(in: model.directory)
            .map { $0 * Int64(min(contextTokens, model.contextWindow)) }
            // No shape in config.json: fall back to a fifth of the weights,
            // which is the same order for the models in the recommended list.
            ?? model.sizeOnDisk / 5
        return model.sizeOnDisk + kv + 536_870_912
    }

    public static func admit(_ model: LocalModel,
                             memory: MachineMemory = .current()) -> Admission {
        verdict(estimated: estimatedResidentBytes(model), name: model.name, memory: memory)
    }

    /// Before a download: the recorded size stands in for the weights, since
    /// there is nothing on disk to measure yet.
    public static func admit(_ entry: ModelCatalogEntry,
                             memory: MachineMemory = .current()) -> Admission {
        let estimate = entry.downloadBytes + entry.downloadBytes / 5 + 536_870_912
        return verdict(estimated: estimate, name: entry.displayName, memory: memory)
    }

    private static func verdict(estimated: Int64, name: String,
                                memory: MachineMemory) -> Admission {
        let gb = { (bytes: Int64) in String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
        // Two thirds rather than all of it: the last of the free memory is
        // what everything else on the Mac is about to ask for, and a model
        // that only fits when nothing else runs does not fit.
        let comfortable = memory.availableBytes * 2 / 3

        if estimated <= comfortable {
            return Admission(verdict: .fits, estimatedResidentBytes: estimated,
                             availableBytes: memory.availableBytes,
                             reason: "\(name) ใช้ราว \(gb(estimated)) · ว่างอยู่ \(gb(memory.availableBytes))")
        }
        if estimated <= memory.availableBytes {
            return Admission(verdict: .tight, estimatedResidentBytes: estimated,
                             availableBytes: memory.availableBytes,
                             reason: "\(name) ใช้ราว \(gb(estimated)) จากที่ว่าง \(gb(memory.availableBytes)) "
                                   + "— พอรันได้แต่เครื่องจะไม่เหลือที่ให้งานอื่น")
        }
        return Admission(verdict: .tooLarge, estimatedResidentBytes: estimated,
                         availableBytes: memory.availableBytes,
                         reason: "\(name) ต้องการราว \(gb(estimated)) แต่ว่างอยู่ \(gb(memory.availableBytes)) "
                               + "— ตั้งเป็นตัวหลักไม่ได้ เพราะจะทำให้เครื่องค้าง ไม่ใช่แค่ตอบช้า")
    }
}
