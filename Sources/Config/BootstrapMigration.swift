import Foundation
import AgentKit
import Observability

// ─────────────────────────────────────────────────────────────
// Migrating the bootstrap file (ARCHITECTURE §15, P9.2 / v1 bug D5).
//
// The Done-when is "an old config loads without losing what was in it", and
// the reason it needs saying is that the easy implementation does the opposite.
// Before this file, a `bootstrap.plist` the decoder could not read — including
// one written by an *older* version, because `schemaVersion` was required —
// took the `repairedInvalid` path: defaults written straight over it. The
// person's endpoint, their model choice and their budget were gone, and what
// they saw was an app that had forgotten its settings, which is v1's D5
// exactly.
//
// Three rules, and each one is about what happens to somebody's settings:
//
//  • **A missing version is version 0, not corruption.** The first shipped file
//    had no `schemaVersion` key at all.
//  • **A file from a newer version is never overwritten.** Running with
//    defaults for one session is recoverable; rewriting the file means the
//    settings are gone from the version they downgraded *back to* as well.
//  • **Nothing is overwritten without a copy first.** A backup beside the file
//    costs a few hundred bytes and is the difference between "type your
//    endpoint in again" and "which endpoint was it?".
// ─────────────────────────────────────────────────────────────

public enum BootstrapMigration {

    /// One step, from the version before it to the version it names. Kept as
    /// data rather than a `switch` so the gap check below can prove there is no
    /// version between 0 and current that nothing handles.
    struct Step: Sendable {
        let to: Int
        let apply: @Sendable (inout BootstrapConfig) -> Void
    }

    /// Every step, in order.
    ///
    /// **v1** folded the single `selfHostedEndpoint`/`selfHostedModel` pair into
    /// the Endpoint Registry (§9.3, P5.5). It used to be done at every read by
    /// `effectiveEndpoints`, which meant the file kept the old shape forever and
    /// the migration had to keep being correct forever. Now it happens once.
    static let steps: [Step] = [
        Step(to: 1) { config in
            var registry = config.endpointRegistry ?? EndpointRegistry()
            if registry.isEmpty,
               let endpoint = config.selfHostedEndpoint, !endpoint.isEmpty,
               let model = config.selfHostedModel, !model.isEmpty {
                registry.upsert(InferenceEndpoint(
                    id: "migrated-self-hosted", name: "Self-hosted", baseURL: endpoint,
                    model: model, kind: .selfHosted))
            }
            config.endpointRegistry = registry.isEmpty ? nil : registry
        },
    ]

    /// Whether every version from 1 to `currentSchemaVersion` has a step. A
    /// bumped version with no migration is the mistake this catches: it looks
    /// fine until somebody upgrades.
    public static var missingSteps: [Int] {
        let covered = Set(steps.map(\.to))
        return (1...max(BootstrapConfig.currentSchemaVersion, 1)).filter { !covered.contains($0) }
    }

    /// Applies every step between the file's version and ours.
    public static func migrate(_ config: BootstrapConfig) -> (config: BootstrapConfig, applied: [Int]) {
        var migrated = config
        var applied: [Int] = []
        for step in steps.sorted(by: { $0.to < $1.to })
        where step.to > config.schemaVersion && step.to <= BootstrapConfig.currentSchemaVersion {
            step.apply(&migrated)
            applied.append(step.to)
        }
        migrated.schemaVersion = max(config.schemaVersion, BootstrapConfig.currentSchemaVersion)
        return (migrated, applied)
    }
}
