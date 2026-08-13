import Testing
import Foundation
import AgentKit
@testable import Config

// ─────────────────────────────────────────────────────────────
// One folder per project (ARCHITECTURE §19.1, P10.1).
//
// The rows were partitioned by `Scope` from the start; the disk was not. Two
// projects shared one `analysis.duckdb` and one notebook folder, which meant
// "this project's data" was a claim nobody could check by looking.
// ─────────────────────────────────────────────────────────────

@Suite("Project folders")
struct ProjectPathsTests {

    private func sandbox() throws -> AppPaths {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "coai-paths-\(UUID().uuidString)")
        return AppPaths(root: root)
    }

    @Test("two projects get two folders, and neither is the app-wide one")
    func projectsDoNotShareADirectory() throws {
        let paths = try sandbox()
        let alpha = paths.project(ProjectID("pj_alpha"))
        let beta = paths.project(ProjectID("pj_beta"))

        #expect(alpha.root != beta.root)
        #expect(alpha.analysisDatabase != beta.analysisDatabase)
        #expect(alpha.notebooksDirectory != beta.notebooksDirectory)
        // The app-wide analysis directory stays where it was: General still
        // has somewhere to work that belongs to no project.
        #expect(alpha.analysisDirectory != paths.analysisDirectory)
        #expect(alpha.root.path().contains("projects"))
    }

    @Test("a project's directories are created on demand and creating twice is safe")
    func directoriesSelfHeal() throws {
        let paths = try sandbox()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let project = paths.project(ProjectID("pj_gamma"))

        let created = try project.createDirectories()
        #expect(created.count == project.managedDirectories.count)
        // Idempotent for the same reason the app-wide version is: a wiped
        // Application Support directory has to heal on the next launch, not
        // fail it.
        #expect(try project.createDirectories().isEmpty)

        for dir in project.managedDirectories {
            #expect(FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)))
        }
    }

    @Test("everything a project owns sits under that project's root")
    func nothingEscapesTheProjectFolder() throws {
        let paths = try sandbox()
        let project = paths.project(ProjectID("pj_delta"))
        let inside = project.root.path(percentEncoded: false)

        // The point of the folder: deleting it takes the project's files with
        // it and nothing else. A path that reached outside would make that
        // false without anybody noticing.
        for url in [project.analysisDatabase, project.connectorsFile,
                    project.notebooksDirectory, project.documentsDirectory,
                    project.filesDirectory] {
            #expect(url.path(percentEncoded: false).hasPrefix(inside))
        }
    }

    @Test("the projects root is created with the rest of the app's directories")
    func projectsRootIsManaged() throws {
        let paths = try sandbox()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        try paths.createDirectories()
        #expect(FileManager.default.fileExists(
            atPath: paths.projectsDirectory.path(percentEncoded: false)))
    }
}
