import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// Bootstrap config (ARCHITECTURE §15) — the only settings kept in a flat
// file, because they must be readable *before* the database exists.
// Everything else lives in the `settings` table in SurrealDB.
// ─────────────────────────────────────────────────────────────

public struct BootstrapConfig: Codable, Sendable, Equatable {
    public enum LogLevel: String, Codable, Sendable, CaseIterable {
        case debug, info, warning, error
    }

    /// Schema version of this file. Bumped when the shape changes so
    /// migration can run at boot instead of silently losing settings (v1 D5).
    public var schemaVersion: Int
    public var surrealPort: Int
    public var searxngPort: Int
    public var logLevel: LogLevel
    /// Overrides `AppPaths.standard()` when set — used by tests and by users
    /// who keep their workspace on another volume.
    public var dataDirectoryOverride: String?
    /// One OpenAI-compatible endpoint for the tiers above on-device. Lives here
    /// rather than in the database because the router is built during boot,
    /// before a conversation exists. The full Endpoint Registry (§9.3) replaces
    /// this pair in P5; until then it is what makes tool calling possible at all.
    public var selfHostedEndpoint: String?
    public var selfHostedModel: String?
    /// Interpreter of the SearXNG virtualenv. Per-machine, because a Python
    /// venv cannot be moved — its scripts hold absolute paths — so it cannot
    /// simply be copied into the app bundle (packaging is P9.6). Nil means the
    /// meta-search sidecar is not started and T5 search is unavailable, which
    /// the boot screen says rather than failing silently.
    public var searxngPython: String?
    /// Which Tier 0.5 model to load (P5.2). Here rather than in the database
    /// for the same reason as the endpoint pair: the router is built during
    /// boot, before a conversation exists. Nil means "the largest installed",
    /// which is what a machine with exactly one model wants.
    public var localModel: String?
    /// Every model above Tier 0.5 (§9.3, P5.5). Replaces the single
    /// `selfHostedEndpoint`/`selfHostedModel` pair, which is kept for one more
    /// version so an existing bootstrap.plist migrates itself rather than
    /// losing the endpoint someone already configured.
    public var endpointRegistry: EndpointRegistry?
    /// The four ceilings (§9.5). Nil means the conservative default rather
    /// than "no limit": an unset budget on a metered endpoint is the one
    /// setting whose absence costs money.
    public var budget: BudgetLimits?
    /// Ceiling on what downloaded models may occupy, in gigabytes. Models are
    /// the only thing in this app that can fill a disk — one 30B checkpoint is
    /// 17 GB — so the limit is a setting, not a constant (ARCH §9.4).
    public var modelQuotaGigabytes: Int?

    public static let currentSchemaVersion = 1
    public static let defaultModelQuotaGigabytes = 60

    public static let `default` = BootstrapConfig(
        schemaVersion: currentSchemaVersion,
        surrealPort: 18_000,
        searxngPort: 18_080,
        logLevel: .info,
        dataDirectoryOverride: nil)

    public init(schemaVersion: Int = BootstrapConfig.currentSchemaVersion,
                surrealPort: Int,
                searxngPort: Int,
                logLevel: LogLevel,
                dataDirectoryOverride: String? = nil,
                selfHostedEndpoint: String? = nil,
                selfHostedModel: String? = nil,
                searxngPython: String? = nil,
                localModel: String? = nil,
                modelQuotaGigabytes: Int? = nil,
                endpointRegistry: EndpointRegistry? = nil,
                budget: BudgetLimits? = nil) {
        self.schemaVersion = schemaVersion
        self.surrealPort = surrealPort
        self.searxngPort = searxngPort
        self.logLevel = logLevel
        self.dataDirectoryOverride = dataDirectoryOverride
        self.selfHostedEndpoint = selfHostedEndpoint
        self.selfHostedModel = selfHostedModel
        self.searxngPython = searxngPython
        self.localModel = localModel
        self.modelQuotaGigabytes = modelQuotaGigabytes
        self.endpointRegistry = endpointRegistry
        self.budget = budget
    }
}

public enum BootstrapError: Error, CustomStringConvertible, Equatable {
    case invalidPort(name: String, value: Int)
    case duplicatePorts(Int)
    case unreadable(String)
    case invalidEndpoint(String)
    case invalidQuota(Int)

    public var description: String {
        switch self {
        case .invalidPort(let n, let v): return "invalid \(n) port: \(v) (must be 1024–65535)"
        case .duplicatePorts(let p): return "surreal and searxng cannot share port \(p)"
        case .unreadable(let m): return "cannot read bootstrap file: \(m)"
        case .invalidEndpoint(let e): return "invalid self-hosted endpoint: \(e)"
        case .invalidQuota(let q): return "model quota must be at least 1 GB, got \(q)"
        }
    }
}

extension BootstrapConfig {
    /// Rejects values that would fail later in a confusing way — same philosophy
    /// as v1's config crate: never let an invalid value reach the running system.
    public func validate() throws {
        for (name, port) in [("surreal", surrealPort), ("searxng", searxngPort)] {
            guard (1024...65_535).contains(port) else {
                throw BootstrapError.invalidPort(name: name, value: port)
            }
        }
        guard surrealPort != searxngPort else {
            throw BootstrapError.duplicatePorts(surrealPort)
        }
        if let endpoint = selfHostedEndpoint, !endpoint.isEmpty {
            guard let url = URL(string: endpoint), url.scheme != nil, url.host() != nil else {
                throw BootstrapError.invalidEndpoint(endpoint)
            }
        }
        for endpoint in endpointRegistry?.endpoints ?? [] {
            guard let url = URL(string: endpoint.baseURL),
                  url.scheme != nil, url.host() != nil else {
                throw BootstrapError.invalidEndpoint(endpoint.baseURL)
            }
        }
        if let quota = modelQuotaGigabytes {
            // Zero would mean "no models allowed", which reads as a typo
            // rather than an intention, and would disable Tier 0.5 silently.
            guard quota >= 1 else { throw BootstrapError.invalidQuota(quota) }
        }
    }
}

extension BootstrapConfig {
    /// The registry, with the old single pair folded in.
    ///
    /// Migration rather than a breaking change: a file written before P5.5 has
    /// `selfHostedEndpoint`/`selfHostedModel` and no registry, and silently
    /// dropping the endpoint someone configured would look exactly like the
    /// app forgetting its settings.
    public var effectiveEndpoints: EndpointRegistry {
        var registry = endpointRegistry ?? EndpointRegistry()
        if registry.isEmpty,
           let endpoint = selfHostedEndpoint, !endpoint.isEmpty,
           let model = selfHostedModel, !model.isEmpty {
            registry.upsert(InferenceEndpoint(
                id: "migrated-self-hosted", name: "Self-hosted", baseURL: endpoint,
                model: model, kind: .selfHosted))
        }
        return registry
    }
}

/// Loads/saves `bootstrap.plist`. Missing or corrupt file falls back to
/// defaults and rewrites it, so a broken file can never brick startup.
public struct BootstrapStore: Sendable {
    public enum LoadOutcome: Sendable, Equatable {
        case loaded
        case createdDefault
        case repairedInvalid(reason: String)
    }

    public let paths: AppPaths
    /// `FileManager` is not Sendable; each call site takes the shared instance
    /// rather than the store holding one across concurrency domains.
    private var fileManager: FileManager { .default }

    public init(paths: AppPaths) {
        self.paths = paths
    }

    public func load() throws -> (config: BootstrapConfig, outcome: LoadOutcome) {
        guard fileManager.fileExists(atPath: paths.bootstrapFile.path(percentEncoded: false)) else {
            try save(.default)
            return (.default, .createdDefault)
        }
        do {
            let data = try Data(contentsOf: paths.bootstrapFile)
            let config = try PropertyListDecoder().decode(BootstrapConfig.self, from: data)
            try config.validate()
            return (config, .loaded)
        } catch {
            // Corrupt or invalid: keep going with defaults rather than refusing to launch.
            try save(.default)
            return (.default, .repairedInvalid(reason: "\(error)"))
        }
    }

    public func save(_ config: BootstrapConfig) throws {
        try config.validate()
        try paths.createDirectories(fileManager: fileManager)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(config).write(to: paths.bootstrapFile, options: .atomic)
    }
}
