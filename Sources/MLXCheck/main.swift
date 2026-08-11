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
let installed = catalog.installed()

func gigabytes(_ bytes: Int64) -> String {
    String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
}

print("   โมเดลที่ติดตั้งอยู่: \(installed.count)")
for model in installed {
    print("     · \(model.name) — \(gigabytes(model.sizeOnDisk)), "
          + "context \(model.contextWindow)"
          + (model.declaredContextWindow > model.contextWindow
             ? " (ประกาศ \(model.declaredContextWindow), จำกัดไว้ตามที่เครื่องรับไหว)" : "")
          + (model.supportsTools ? ", tool calling" : ", ไม่มี tool calling"))
}

/// `COAI_MLX_MODEL` picks one when a machine has several, the same shape as
/// `COAI_TEST_MODEL` for the endpoint tests.
let chosen: LocalModel? = {
    if let name = ProcessInfo.processInfo.environment["COAI_MLX_MODEL"], !name.isEmpty {
        return catalog.model(named: name)
    }
    return catalog.preferred()
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

await check("the weights stay resident between requests") {
    guard await executor.isResident else {
        throw CheckFailure("nothing is loaded after a full contract run")
    }
    return "resident"
}

await check("and are given back when the model goes idle") {
    // §9.4: the RAM a chat model holds is the RAM analysis and the embedding
    // model need. On 16 GB this is not housekeeping, it is the difference
    // between the next task running and the machine swapping.
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

exit(Failures.shared.count == 0 ? 0 : 1)
