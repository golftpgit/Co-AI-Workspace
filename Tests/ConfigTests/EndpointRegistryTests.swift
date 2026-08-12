import Testing
import Foundation
@testable import Config

// ─────────────────────────────────────────────────────────────
// The endpoint registry (ARCHITECTURE §9.3, P5.5).
// ─────────────────────────────────────────────────────────────

@Suite("Endpoint registry")
struct EndpointRegistryTests {

    @Test("the first endpoint added becomes the default, so there is always one")
    func firstBecomesDefault() {
        var registry = EndpointRegistry()
        registry.upsert(InferenceEndpoint(id: "a", name: "GX10",
                                          baseURL: "http://gx10:8000/v1", model: "qwen"))
        #expect(registry.defaultEndpointID == "a")

        registry.upsert(InferenceEndpoint(id: "b", name: "Laptop",
                                          baseURL: "http://mac:1234/v1", model: "qwen-small"))
        // Adding a second one does not quietly move the default.
        #expect(registry.defaultEndpointID == "a")
    }

    @Test("a role uses its override, then the default, then whatever exists")
    func rolesResolveInOrder() {
        var registry = EndpointRegistry()
        registry.upsert(InferenceEndpoint(id: "big", name: "GX10",
                                          baseURL: "http://gx10:8000/v1", model: "qwen-27b"))
        registry.upsert(InferenceEndpoint(id: "small", name: "Laptop",
                                          baseURL: "http://mac:1234/v1", model: "qwen-4b"))
        registry.overrides["engineer"] = "small"

        #expect(registry.endpoint(forRole: "engineer")?.id == "small")
        #expect(registry.endpoint(forRole: "writer")?.id == "big")
    }

    /// Removing the default has to leave a working registry, not a dangling id
    /// that resolves to nothing on the next launch.
    @Test("removing an endpoint takes its overrides and its default with it")
    func removalCleansUp() {
        var registry = EndpointRegistry()
        registry.upsert(InferenceEndpoint(id: "a", name: "A", baseURL: "http://a/v1", model: "m"))
        registry.upsert(InferenceEndpoint(id: "b", name: "B", baseURL: "http://b/v1", model: "m"))
        registry.overrides["analyst"] = "a"

        registry.remove(id: "a")

        #expect(registry.defaultEndpointID == "b")
        #expect(registry.overrides["analyst"] == nil)
        #expect(registry.endpoints.count == 1)
    }

    /// A bootstrap.plist written before P5.5 has the single pair and no
    /// registry. Dropping it would look exactly like the app forgetting the
    /// endpoint someone configured.
    @Test("an older config's single endpoint migrates itself into the registry")
    func migratesTheOldPair() {
        var config = BootstrapConfig.default
        config.selfHostedEndpoint = "http://127.0.0.1:1234/v1"
        config.selfHostedModel = "qwen3.5-9b"

        let registry = config.effectiveEndpoints
        #expect(registry.endpoints.count == 1)
        #expect(registry.endpoints.first?.model == "qwen3.5-9b")
        #expect(registry.endpoints.first?.kind == .selfHosted)
        #expect(registry.defaultEndpointID == registry.endpoints.first?.id)
    }

    @Test("a registry that exists is not overwritten by the old pair")
    func registryWins() {
        var config = BootstrapConfig.default
        config.selfHostedEndpoint = "http://127.0.0.1:1234/v1"
        config.selfHostedModel = "old"
        config.endpointRegistry = EndpointRegistry(endpoints: [
            InferenceEndpoint(id: "new", name: "GX10", baseURL: "http://gx10:8000/v1",
                              model: "qwen-27b"),
        ], defaultEndpointID: "new")

        #expect(config.effectiveEndpoints.endpoints.map(\.model) == ["qwen-27b"])
    }

    @Test("an endpoint with an unusable URL is refused when the config is saved")
    func validationRejectsNonsense() {
        var config = BootstrapConfig.default
        config.endpointRegistry = EndpointRegistry(endpoints: [
            InferenceEndpoint(name: "broken", baseURL: "not a url", model: "m"),
        ])
        #expect(throws: BootstrapError.self) { try config.validate() }
    }

    /// The key never goes in the file; the *name* of the variable does. A key
    /// in Application Support is a key on disk (Keychain is P9.2).
    @Test("a paid endpoint reads its key from the environment, not from the file")
    func keyComesFromTheEnvironment() throws {
        let endpoint = InferenceEndpoint(name: "hosted", baseURL: "https://api.example/v1",
                                         model: "big", kind: .paid,
                                         apiKeyEnvironmentVariable: "COAI_TEST_KEY_ABSENT")
        #expect(endpoint.apiKey == nil)

        let encoded = try JSONEncoder().encode(endpoint)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(text.contains("COAI_TEST_KEY_ABSENT"))
        #expect(!text.contains("sk-"))
    }
}

@Suite("Reading what an endpoint serves")
struct EndpointProbeTests {

    /// The case that makes this check necessary: an OpenAI-compatible server
    /// answers a request for a model it does not have, and the mistake only
    /// shows up much later (ARCHITECTURE E.9, case 8a).
    @Test("the model list is parsed out of the catalogue response")
    func parsesModelNames() {
        let payload = Data(#"{"data":[{"id":"qwen-27b"},{"id":"bge-m3"}]}"#.utf8)
        #expect(EndpointProbe.modelNames(in: payload) == ["qwen-27b", "bge-m3"])
    }

    @Test("a response that is not a catalogue yields no models rather than a crash")
    func toleratesRubbish() {
        #expect(EndpointProbe.modelNames(in: Data("<html>nope</html>".utf8)).isEmpty)
    }

    @Test("an unreachable endpoint is reported, not thrown")
    func unreachableIsAVerdict() async {
        let probe = EndpointProbe()
        let check = await probe.check(InferenceEndpoint(name: "dead",
                                                        baseURL: "http://127.0.0.1:9/v1",
                                                        model: "m"), timeout: 2)
        #expect(!check.isUsable)
        #expect(check.message.contains("ต่อไม่ได้"))
    }

    @Test("a paid endpoint with no key says so before anything is sent")
    func missingKeyIsCaughtFirst() async {
        let probe = EndpointProbe()
        let check = await probe.check(
            InferenceEndpoint(name: "hosted", baseURL: "https://api.example/v1", model: "big",
                              kind: .paid, apiKeyEnvironmentVariable: "COAI_TEST_KEY_ABSENT"))
        #expect(check.verdict == .missingKey("COAI_TEST_KEY_ABSENT"))
    }
}
