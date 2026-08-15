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
        case .board: return "board"
        }
    }

    /// The second column. Named for the case that fills it most, and shared
    /// with `board` deliberately: `scope_kind` already tells the two apart, and
    /// a third column would have to be added to every table and every query to
    /// hold one string that means "which one".
    static func projectID(_ scope: Scope) -> String? {
        switch scope {
        case .project(let id): return id.rawValue
        case .board(let runID): return runID
        case .central, .policy: return nil
        }
    }

    static func scope(kind: String?, projectID: String?) -> Scope? {
        switch kind {
        case "central": return .central
        case "policy": return .policy
        case "project":
            guard let projectID, !projectID.isEmpty else { return nil }
            return .project(ProjectID(projectID))
        case "board":
            guard let projectID, !projectID.isEmpty else { return nil }
            return .board(projectID)
        default: return nil
        }
    }
}
