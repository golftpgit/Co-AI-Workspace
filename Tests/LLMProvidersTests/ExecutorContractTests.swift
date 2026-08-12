import Testing
import Foundation
import AgentKit
import ExecutorContract
@testable import LLMProviders

// ─────────────────────────────────────────────────────────────
// One contract, checked against every real executor.
//
// Stubs prove the router's logic; these prove the executors actually speak to
// the models. Each suite skips loudly when its backend is absent, because a
// silent skip reads exactly like a pass.
//
// The cases themselves live in the `ExecutorContract` target rather than here.
// Tier 0.5 cannot run under `swift test` — MLX finds its Metal kernels through
// the main bundle, which is SwiftPM's helper here (ARCHITECTURE E.13) — so it
// runs the same cases from the `MLXCheck` executable. A second copy of the
// assertions would drift, and the weaker copy would be the one guarding the
// tier everything else falls back to (§9.2 rule 4).
// ─────────────────────────────────────────────────────────────

private let lmStudio = URL(string: "http://127.0.0.1:1234/v1")!

/// Which model to test against is a property of the machine, not of the repo —
/// the same per-machine setting as `selfHostedEndpoint` in `bootstrap.plist`.
/// A pinned name meant every clone needed one specific multi-GB download, and
/// because the server answers for models it does not serve (ARCHITECTURE E.9,
/// case 8a) the mismatch showed up only in `isAvailable`. So ask the endpoint
/// what it has; `COAI_TEST_MODEL` picks one when a machine serves several.
private func servedModel() async -> String? {
    if let pinned = ProcessInfo.processInfo.environment["COAI_TEST_MODEL"], !pinned.isEmpty {
        return pinned
    }
    var request = URLRequest(url: lmStudio.appending(path: "models"))
    request.timeoutInterval = 2
    guard let (data, response) = try? await URLSession.shared.data(for: request),
          (response as? HTTPURLResponse)?.statusCode == 200,
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let list = obj["data"] as? [[String: Any]] else { return nil }
    // The catalogue does not say which entries are chat models, and an
    // embedding model would fail every test below for the wrong reason.
    return list.compactMap { $0["id"] as? String }
        .first { !$0.lowercased().contains("embed") }
}

/// Says out loud what could not be checked, without failing the run.
///
/// A skip has to stay visible — a silent one reads exactly like a pass — but
/// it must not fail the build either, and that changed with P5.4: a machine
/// with no OpenAI-compatible endpoint is no longer a misconfigured machine,
/// it is the state this whole phase is working towards. `scripts/check.sh`
/// surfaces every `SKIPPED:` line, so these stay in front of a person while
/// the suite still goes green on a laptop running nothing but itself.
private func skipped(_ message: String) {
    print("SKIPPED: \(message)")
}

/// Runs the shared contract and reports each outcome as itself: a failure
/// fails, and a case that could not be checked is announced. A case that does
/// not apply is neither: an executor that declares no tool calling and has no
/// tool-call behaviour is the contract working, not a gap in the run.
private func runContract(against executor: any LLMExecutor) async {
    for outcome in await ExecutorContract.run(against: executor) {
        switch outcome.status {
        case .passed, .notApplicable:
            continue
        case .skipped:
            skipped("[\(executor.identifier)] \(outcome.name) — \(outcome.detail)")
        case .failed:
            Issue.record("\(executor.identifier) — \(outcome.name): \(outcome.detail)")
        }
    }
}

@Suite("On-device executor (Tier 0)", .serialized)
struct OnDeviceExecutorTests {
    @Test("keeps the executor contract", .timeLimit(.minutes(5)))
    func keepsTheContract() async {
        await runContract(against: OnDeviceExecutor())
    }

    @Test("declares what it cannot do rather than discovering it mid-turn")
    func declaresItsLimits() {
        let executor = OnDeviceExecutor()
        #expect(executor.tier == .onDevice)
        // Structured output is the dependable mode for a 3B model (E.6).
        #expect(executor.capabilities.supportsStructuredOutput)
        // Apple's `Tool` protocol wants compile-time `@Generable` types;
        // bridging our runtime registry onto it is P8.3 work.
        #expect(executor.capabilities.supportsTools == false)
    }
}

@Suite("OpenAI-compatible executor (Tier 1)", .serialized)
struct VLLMExecutorTests {
    private func executor(_ model: String) -> VLLMExecutor {
        VLLMExecutor(baseURL: lmStudio, model: model)
    }

    @Test("keeps the executor contract", .timeLimit(.minutes(10)))
    func keepsTheContract() async {
        guard let model = await servedModel() else {
            skipped("no OpenAI-compatible endpoint on :1234 — Tier 1 unchecked")
            return
        }
        await runContract(against: executor(model))
    }

    @Test("availability also validates the configured model name", .timeLimit(.minutes(1)))
    func availabilityChecksModel() async {
        guard let model = await servedModel() else {
            skipped("no OpenAI-compatible endpoint on :1234 — Tier 1 unchecked")
            return
        }
        #expect(await executor(model).isAvailable())

        // A server will answer for a model that does not exist, so the check
        // has to be ours (ARCHITECTURE E.9, case 8a).
        let typo = VLLMExecutor(baseURL: lmStudio, model: "no-such-model-xyz")
        #expect(await typo.isAvailable() == false)
    }

    @Test("a dead endpoint fails fast with a legible error", .timeLimit(.minutes(1)))
    func deadEndpoint() async {
        var request = LLMRequest(messages: [.init(.user, "hi")])
        request.timeout = 3
        let dead = VLLMExecutor(baseURL: URL(string: "http://127.0.0.1:9/v1")!, model: "x")
        await #expect(throws: LLMError.self) { _ = try await dead.complete(request) }
    }
}

@Suite("Router over real backends", .serialized)
struct LiveRoutingTests {
    /// The end-to-end shape of §9.2: cheap work locally, escalation upward
    /// when the local tier cannot or will not serve it.
    @Test("a live chain answers even when Tier 0 refuses", .timeLimit(.minutes(4)))
    func liveChain() async throws {
        guard let model = await servedModel() else {
            skipped("no OpenAI-compatible endpoint on :1234 — Tier 1 unchecked")
            return
        }
        let router = ModelRouter(executors: [
            OnDeviceExecutor(),
            VLLMExecutor(baseURL: lmStudio, model: model),
        ])

        var request = LLMRequest(messages: [
            .init(.system, "Route the request to a specialist in a research AI team."),
            .init(.user, "ช่วยหางานวิจัยเรื่องวัคซีน mRNA ในผู้สูงอายุ"),
        ])
        request.responseSchema = (name: "Routing", schemaJSON: ExecutorContract.routingSchema)
        // Room for a reasoning model on Tier 1 to think before the JSON.
        request.maxTokens = 512

        let completion = try await router.complete(request)
        #expect(!completion.text.isEmpty)
        #expect((try? JSONSerialization.jsonObject(with: Data(completion.text.utf8)) as? [String: Any]) != nil,
                "expected JSON from whichever tier answered: \(completion.text.prefix(120))")
    }
}
