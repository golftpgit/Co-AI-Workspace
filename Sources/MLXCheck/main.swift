import Foundation
import LLMProviders
import ExecutorContract
import MLXRuntime

// ─────────────────────────────────────────────────────────────
// Tier 0.5 against the real weights (P5.1).
//
// The same `ExecutorContract` cases that `Tests/LLMProvidersTests` runs
// against Apple's on-device model and an OpenAI-compatible endpoint, run here
// against a model this process loads itself. An executable rather than a test
// because MLX resolves its Metal kernels through the main bundle, which under
// `swift test` is SwiftPM's helper (ARCHITECTURE E.13) — the same reason
// EmbeddingCheck exists.
//
// Run by scripts/check.sh. Skips loudly, and does not download anything: a
// machine with no chat model installed says so and exits 0, because P5.2 is
// what puts a model there.
// ─────────────────────────────────────────────────────────────

let catalog = LocalModelCatalog.standard()
let installed = await catalog.installed()

func gigabytes(_ bytes: Int64) -> String {
    String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
}

let machine = MachineMemory.current()
let sizeClass = MachineSizeClass.forMachine(totalBytes: machine.totalBytes)
print("   เครื่องนี้: RAM \(gigabytes(machine.totalBytes)) (ว่าง \(gigabytes(machine.availableBytes)))"
      + " → แนะนำ \(sizeClass.recommendedSize) · \(sizeClass.trustedWith)")
print("   โมเดลที่ติดตั้งอยู่: \(installed.count)")
for model in installed {
    print("     · \(model.name) — \(gigabytes(model.sizeOnDisk)), "
          + "context \(model.contextWindow)"
          + (model.declaredContextWindow > model.contextWindow
             ? " (ประกาศ \(model.declaredContextWindow), จำกัดไว้ตามที่เครื่องรับไหว)" : "")
          + (model.supportsTools ? ", tool calling" : ", ไม่มี tool calling"))
    let admission = AdmissionControl.admit(model, memory: machine)
    print("       \(admission.isBlocking ? "✗" : admission.verdict == .tight ? "!" : "·") "
          + admission.reason)
}

/// `COAI_MLX_MODEL` picks one when a machine has several, the same shape as
/// `COAI_TEST_MODEL` for the endpoint tests.
let chosen: LocalModel? = await {
    if let name = ProcessInfo.processInfo.environment["COAI_MLX_MODEL"], !name.isEmpty {
        return await catalog.model(named: name)
    }
    return await catalog.preferred()
}()

guard let model = chosen else {
    print("   ⊘ ข้าม: ไม่มีโมเดลสนทนา MLX บนเครื่องนี้ "
          + "(ค้นหาใน \(catalog.searchPaths.map(\.lastPathComponent).joined(separator: ", ")))")
    exit(0)
}

print("   ใช้: \(model.name)")

// Short on purpose: the check should observe the unload, not wait ten minutes
// for it.
let executor = MLXExecutor(model: model, idleTimeout: .seconds(2))

/// Top-level code is main-actor isolated; the counter has to be too.
@MainActor final class Failures {
    static let shared = Failures()
    var count = 0
}

for outcome in await ExecutorContract.run(against: executor) {
    let seconds = Double(outcome.duration.components.seconds)
        + Double(outcome.duration.components.attoseconds) / 1e18
    switch outcome.status {
    case .passed:
        print(String(format: "   ✓ %@ (%.1fs) %@", outcome.name, seconds, outcome.detail))
    case .notApplicable:
        print("   – \(outcome.name) — \(outcome.detail)")
    case .skipped:
        print("   ⊘ \(outcome.name) — \(outcome.detail)")
    case .failed:
        print(String(format: "   ✗ %@ (%.1fs) %@", outcome.name, seconds, outcome.detail))
        Failures.shared.count += 1
    }
}

// Beyond the shared contract: the two things that are specific to running a
// model in our own process rather than talking to one over HTTP.

@MainActor
func check(_ name: String, _ body: () async throws -> String) async {
    let started = Date()
    do {
        let detail = try await body()
        print(String(format: "   ✓ %@ (%.1fs) %@", name, -started.timeIntervalSinceNow, detail))
    } catch {
        print(String(format: "   ✗ %@ (%.1fs) %@", name, -started.timeIntervalSinceNow, "\(error)"))
        Failures.shared.count += 1
    }
}

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// Residency only means anything once something has been generated — and on a
// machine with no room, admission (P5.3) is *supposed* to keep the model out,
// so these are skipped loudly rather than failed.
// Asked in the same order `isAvailable()` asks it: a model already in memory
// has already spent it, and refusing to check it for want of the memory it is
// holding would be circular.
let residencyAdmission = AdmissionControl.admit(model, memory: MachineMemory.current())
if residencyAdmission.isBlocking, await !executor.isResident {
    print("   ⊘ ข้ามเช็ค residency — \(residencyAdmission.reason)")
} else {
    await check("the weights stay resident between requests") {
        var request = LLMRequest(messages: [.init(.user, "Reply with: ok")])
        request.maxTokens = 512
        _ = try await executor.complete(request)
        guard await executor.isResident else {
            throw CheckFailure("answered but nothing is loaded")
        }
        return "resident"
    }

    await check("and are given back when the model goes idle") {
        // §9.4: the RAM a chat model holds is the RAM analysis and the
        // embedding model need. On 16 GB this is not housekeeping, it is the
        // difference between the next task running and the machine swapping.
        let deadline = Date().addingTimeInterval(30)
        while await executor.isResident, Date() < deadline {
            try await Task.sleep(for: .milliseconds(500))
        }
        guard await !executor.isResident else {
            throw CheckFailure("still resident 30s after an idle timeout of 2s")
        }
        return "unloaded"
    }

    await check("and load again on the next request") {
        var request = LLMRequest(messages: [.init(.user, "ตอบว่า พร้อม")])
        request.maxTokens = 512
        let completion = try await executor.complete(request)
        guard await executor.isResident else { throw CheckFailure("answered without loading?") }
        guard !completion.structuredText.isEmpty else { throw CheckFailure("empty answer") }
        return "\(completion.usage?.total ?? 0) tokens"
    }
}

// ── P5.4: the floor, with the network gone ──
print("")
print("   — Tier 0.5 เป็นพื้นรับประกัน (P5.4) —")

await check("endpoint ที่ตั้งไว้ต่อไม่ได้จริง") {
    try await OfflineFloor.endpointIsDown()
}

// The floor cannot be demonstrated with a model that will not fit — and on a
// 16 GB machine that happens for an honest reason: the *app* is holding the
// same weights. Skipped loudly rather than failed, exactly as elsewhere.
let floorAdmission = AdmissionControl.admit(model, memory: MachineMemory.current())
if floorAdmission.isBlocking {
    print("   ⊘ ข้ามเช็คพื้นรับประกัน — \(floorAdmission.reason)")
} else {
    await check("งาน high-impact ยังทำงานได้ ตกลงมาที่โมเดลบนเครื่อง") {
        try await OfflineFloor.routesConsequentialWork(model)
    }

    await check("ตรวจข้อขัดแย้งได้โดยไม่มีเน็ต — ไม่ใช่เงียบว่าไม่มีข้อขัดแย้ง") {
        try await OfflineFloor.detectsConflictsOffline(model)
    }
}

// The download path, against the Hub, with the smallest model on the list
// (~350 MB). Off by default: a check that pulls hundreds of megabytes every
// run is a check people start skipping. `COAI_CHECK_DOWNLOAD=1` turns it on.
if let wanted = ProcessInfo.processInfo.environment["COAI_CHECK_DOWNLOAD"], !wanted.isEmpty {
    let scratch = FileManager.default.temporaryDirectory
        .appending(path: "coai-model-download-check")
    let installer = ModelInstaller(destination: scratch, quotaGigabytes: 30)
    // `COAI_CHECK_DOWNLOAD=1` uses the smallest entry; anything else is read
    // as a repository name, so a specific model can be checked by hand.
    let entry = wanted == "1"
        ? RecommendedModels.all[0]
        : (RecommendedModels.all.first { $0.repository.contains(wanted) }
           ?? RecommendedModels.all[0])

    /// The installer reports from its own actor, so the tally it writes into
    /// needs a lock rather than a captured `var`.
    final class ProgressTally: @unchecked Sendable {
        private let lock = NSLock()
        private var fractions: [Double] = []
        func record(_ value: Double) { lock.lock(); fractions.append(value); lock.unlock() }
        var partial: Int { lock.lock(); defer { lock.unlock() }
            return fractions.count { $0 > 0 && $0 < 1 } }
        var count: Int { lock.lock(); defer { lock.unlock() }; return fractions.count }
    }

    await check("โหลด \(entry.displayName) จาก Hugging Face เข้ามาในโฟลเดอร์ของแอป") {
        let tally = ProgressTally()
        let downloaded = try await installer.install(entry) { progress in
            tally.record(progress.fraction)
        }
        // Progress that only ever reports 0 and 1 is a progress bar that lies
        // for ten minutes and then jumps.
        guard tally.partial > 0 else {
            throw CheckFailure("ไม่มีความคืบหน้าระหว่างทาง (\(tally.count) ครั้ง)")
        }
        // Downloaded is not the same as loadable: the check is that the
        // catalogue reads it back as a chat model with a real context window.
        guard downloaded.contextWindow > 0, downloaded.sizeOnDisk > 0 else {
            throw CheckFailure("อ่านค่าโมเดลที่โหลดมาไม่ได้")
        }
        return "\(downloaded.name) — \(gigabytes(downloaded.sizeOnDisk)), "
            + "context \(downloaded.contextWindow)"
    }

    await check("โหลดซ้ำแล้วไม่ดึงไฟล์เดิมลงมาอีก") {
        // What "resume" means here: files that finished are never fetched
        // twice. The Hub client resumes per file, not per byte.
        let started = Date()
        _ = try await installer.install(entry) { _ in }
        let elapsed = -started.timeIntervalSinceNow
        guard elapsed < 30 else { throw CheckFailure("ใช้เวลา \(Int(elapsed)) วิ เหมือนโหลดใหม่ทั้งหมด") }
        return String(format: "%.1fs", elapsed)
    }

    await check("รันได้จริงหลังโหลดเสร็จ") {
        guard let model = await LocalModelCatalog(searchPaths: [scratch]).installed().first else {
            throw CheckFailure("โหลดมาแล้วแต่หาไม่เจอ")
        }
        var request = LLMRequest(messages: [.init(.user, "Reply with the word: ready")])
        request.maxTokens = 512
        let completion = try await MLXExecutor(model: model).complete(request)
        guard !completion.structuredText.isEmpty else { throw CheckFailure("ตอบว่าง") }
        return String(completion.structuredText.prefix(40))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    await check("ลบแล้วคืนพื้นที่") {
        guard let model = await LocalModelCatalog(searchPaths: [scratch]).installed().first else {
            throw CheckFailure("ไม่มีอะไรให้ลบ")
        }
        try await installer.delete(model)
        let after = await installer.storage()
        guard await LocalModelCatalog(searchPaths: [scratch]).installed().isEmpty else {
            throw CheckFailure("ลบแล้วยังเจออยู่")
        }
        return "เหลือใช้ \(gigabytes(after.usedBytes))"
    }
    try? FileManager.default.removeItem(at: scratch)
}

exit(Failures.shared.count == 0 ? 0 : 1)
