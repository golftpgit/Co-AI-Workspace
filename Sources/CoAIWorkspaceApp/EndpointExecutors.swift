import Foundation
import AgentKit
import Config
import LLMProviders

// ─────────────────────────────────────────────────────────────
// One place that turns configured endpoints into executors (§9.3, AUDIT F-1).
//
// This lived in the middle of `Engine.build`, which runs once at boot — so an
// endpoint added on the settings screen was written to `bootstrap.plist` and
// then ignored until the app was restarted, with nothing on screen saying so.
// The switch in the composer offers `ModelRouter.offered`, so the GX10 somebody
// had just added was simply not in the list.
//
// Moving the construction here is what makes a second caller safe. Two copies of
// this loop would drift, and the first field to drift would be the context
// window — the one thing §17.1 insists must come from the server rather than
// from a constant (P15.3).
// ─────────────────────────────────────────────────────────────

enum EndpointExecutors {
    struct Result {
        var executors: [any LLMExecutor] = []
        var checks: [String: EndpointCheck] = [:]
        /// The window of the endpoint the app will normally talk to, as the
        /// server reports it. Nil when nothing answered — and nil stays nil
        /// rather than becoming a guessed number.
        var defaultWindow: Int?
    }

    /// Probes every configured endpoint and builds one executor per reachable
    /// entry, in registry order.
    ///
    /// Probing at build time is deliberate: the status dots are true when the
    /// screen opens, and a typo in a model name is visible before it is used
    /// (E.9 case 8a). The same reply says how big the window is and which model
    /// is really being served, so neither is guessed (P15.1/P15.3).
    static func build(from registry: EndpointRegistry,
                      probe: EndpointProbe = EndpointProbe()) async -> Result {
        var result = Result()
        for endpoint in registry.endpoints {
            guard let url = endpoint.url else { continue }
            let check = await probe.check(endpoint)
            result.checks[endpoint.id] = check
            if endpoint.id == registry.defaultEndpointID || result.defaultWindow == nil {
                result.defaultWindow = check.served?.maxModelLength ?? result.defaultWindow
            }
            result.executors.append(VLLMExecutor(
                identifier: endpoint.name,
                baseURL: url,
                // Whatever the config says, including nothing: an empty name
                // means "the model this server serves", and `VLLMExecutor`
                // asks. A pinned name that no longer exists takes the endpoint
                // out of the chain with nothing on screen saying why.
                model: endpoint.model,
                apiKey: endpoint.apiKey,
                tier: endpoint.kind == .paid ? .paid : .selfHosted,
                price: endpoint.inputPricePerMillion.flatMap { input in
                    endpoint.outputPricePerMillion.map {
                        TokenPrice(inputPerMillion: input, outputPerMillion: $0)
                    }
                },
                capabilities: .init(
                    // Declared by the server, not by this file. It read 32_768
                    // here for every endpoint, so raising `--max-model-len`
                    // changed nothing and lowering it made the app overflow a
                    // window it believed was bigger.
                    contextWindow: check.served?.maxModelLength ?? 32_768,
                    supportsTools: true,
                    supportsStructuredOutput: true,
                    supportsStreaming: true,
                    supportsVision: false)))
        }
        return result
    }
}
