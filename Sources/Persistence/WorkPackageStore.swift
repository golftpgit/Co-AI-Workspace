import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// The WBS, made durable (ARCHITECTURE §19.6, P10.4).
//
// Same shape as `ProjectStore`: the columns a query needs are primitive, and
// the package itself rides along as JSON. Acceptance criteria and evidence are
// only ever read and written with the package they belong to, and splitting
// them into rows would invite editing a criterion without the leaf that is
// judged by it.
// ─────────────────────────────────────────────────────────────

public actor WorkPackageStore: WorkPackagePersisting {
    private let client: SurrealClient

    public init(client: SurrealClient) {
        self.client = client
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func save(_ package: WorkPackage) async throws {
        let json = String(decoding: try Self.encoder.encode(package), as: UTF8.self)

        var content = ContentBuilder()
        content.setString("uid", package.id)
        content.setString("project_id", package.projectID.rawValue)
        content.setString("parent", package.parent)
        content.setString("title", package.title)
        content.setString("status", package.status.rawValue)
        content.setString("package", json)
        content.raw("updated_at", "time::now()")

        try await client.exec(
            "UPSERT work_package CONTENT \(content.content) WHERE uid = type::string($uid)",
            vars: content.vars)
    }

    public func save(_ packages: [WorkPackage]) async throws {
        for package in packages { try await save(package) }
    }

    public func all(project: ProjectID) async throws -> [WorkPackage] {
        try await client.query(
            "SELECT * FROM work_package WHERE project_id = type::string($pid)",
            vars: ["pid": project.rawValue])
            .first?.rows.compactMap(Self.decode) ?? []
    }

    /// Removes a package and everything under it. A subtree left behind when
    /// its parent goes is exactly the "missing parent" the WBS reports, and
    /// producing that state from the delete button would be this code's fault
    /// rather than the plan's.
    public func delete(_ id: String, project: ProjectID) async throws {
        let packages = try await all(project: project)
        var doomed: Set<String> = [id]
        var changed = true
        while changed {
            changed = false
            for package in packages {
                if let parent = package.parent, doomed.contains(parent),
                   !doomed.contains(package.id) {
                    doomed.insert(package.id)
                    changed = true
                }
            }
        }
        for victim in doomed {
            try await client.exec("DELETE work_package WHERE uid = type::string($uid)",
                                  vars: ["uid": victim])
        }
    }

    private static func decode(_ row: [String: SurrealValue]) -> WorkPackage? {
        guard let json = row["package"]?.stringValue,
              let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(WorkPackage.self, from: data)
    }
}
