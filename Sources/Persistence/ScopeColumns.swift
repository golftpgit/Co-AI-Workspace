import Foundation
import AgentKit

/// Maps `Scope` onto two primitive columns instead of one composite string.
///
/// Two reasons, both learned the hard way (ARCHITECTURE App. C.0):
///
///  1. SurrealDB v3 re-types *bound* strings by shape — `"a:b"` becomes a
///     record link and a UUID-shaped string becomes a UUID — so a composite
///     key can stop matching its own column type without warning.
///  2. Primitive columns index and filter cleanly (`scope_kind`, `project_id`),
///     which a packed string never does.
///
/// A third symptom that first pointed here — bound strings containing `/`
/// hanging the RPC — turned out to be our own bug (Foundation escaping `/`
/// as `\/`), fixed in SurrealClient. Slashes are safe now; this split is
/// kept because points 1 and 2 stand on their own.
enum ScopeColumns {
    static func kind(_ scope: Scope) -> String {
        switch scope {
        case .central: return "central"
        case .policy: return "policy"
        case .project: return "project"
        }
    }

    static func projectID(_ scope: Scope) -> String? {
        if case .project(let id) = scope { return id.rawValue }
        return nil
    }

    static func scope(kind: String?, projectID: String?) -> Scope? {
        switch kind {
        case "central": return .central
        case "policy": return .policy
        case "project":
            guard let projectID, !projectID.isEmpty else { return nil }
            return .project(ProjectID(projectID))
        default: return nil
        }
    }
}
