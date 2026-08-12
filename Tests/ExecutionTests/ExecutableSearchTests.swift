import Testing
import Foundation
@testable import Execution

// ─────────────────────────────────────────────────────────────
// Finding a program a sandboxed app can run (P9.6).
//
// The measurement behind this, taken with a signed sandboxed probe before the
// code was written:
//
//     /usr/bin/python3                                  → xcrun: error: cannot
//                                                          be used within an
//                                                          App Sandbox.
//     /Library/Developer/CommandLineTools/usr/bin/python3 → ok
//     /Applications/Xcode.app/…/usr/bin/python3           → ok
//
// and `/usr/bin/python3`, `/usr/bin/git` and `/usr/bin/swift` have identical
// SHA-256: one multiplexed shim. The tests below fix the consequence in place
// — the ordering, and the error when only the shim exists.
// ─────────────────────────────────────────────────────────────

/// A fake filesystem, so the rule can be tested on machines that have a
/// different set of interpreters than this one.
private final class FakeFileManager: FileManager, @unchecked Sendable {
    let executables: Set<String>
    init(executables: Set<String>) {
        self.executables = executables
        super.init()
    }
    override func isExecutableFile(atPath path: String) -> Bool { executables.contains(path) }
}

@Suite("Executable search")
struct ExecutableSearchTests {

    /// The whole point: the real one wins even though `/usr/bin` is on PATH
    /// and would be found by any ordinary search.
    @Test("a real interpreter is preferred over the one in /usr/bin")
    func realToolchainWins() throws {
        let files = FakeFileManager(executables: [
            "/usr/bin/python3",
            "/Library/Developer/CommandLineTools/usr/bin/python3",
        ])
        let resolved = try ExecutableSearch.resolve("python3",
                                                    environment: ["PATH": "/usr/bin:/bin"],
                                                    sandboxed: true,
                                                    fileManager: files)
        #expect(resolved == "/Library/Developer/CommandLineTools/usr/bin/python3")
    }

    @Test("a person's own install wins over the shipped toolchains")
    func homebrewWinsOverToolchain() throws {
        let files = FakeFileManager(executables: [
            "/opt/homebrew/bin/python3",
            "/Library/Developer/CommandLineTools/usr/bin/python3",
            "/usr/bin/python3",
        ])
        #expect(try ExecutableSearch.resolve("python3",
                                             environment: ["PATH": "/usr/bin"],
                                             sandboxed: true,
                                             fileManager: files)
                == "/opt/homebrew/bin/python3")
    }

    /// The failure that cost an afternoon of "installed but not connected".
    /// Inside a sandbox the shim is not a fallback — it is a program that
    /// cannot start — so it is an error with the reason in it, not a path.
    @Test("when only the shim exists, a sandboxed process is told why, not handed it")
    func shimOnlyIsAnErrorInsideTheSandbox() {
        let files = FakeFileManager(executables: ["/usr/bin/python3"])
        do {
            let path = try ExecutableSearch.resolve("python3",
                                                    environment: ["PATH": "/usr/bin:/bin"],
                                                    sandboxed: true,
                                                    fileManager: files)
            Issue.record("ควรปฏิเสธ แต่คืน \(path)")
        } catch let error as ExecutableSearchError {
            #expect(error == .onlyDeveloperShim("python3", path: "/usr/bin/python3"))
            #expect(error.description.contains("App Sandbox"))
            // Actionable: it names what to install.
            #expect(error.description.contains("xcode-select --install"))
        } catch {
            Issue.record("ชนิดข้อผิดพลาดผิด: \(error)")
        }
    }

    /// Outside a sandbox the shim works perfectly well, and refusing it would
    /// break every command-line use of this project.
    @Test("outside a sandbox the same shim is a perfectly good answer")
    func shimIsFineOutsideTheSandbox() throws {
        let files = FakeFileManager(executables: ["/usr/bin/python3"])
        #expect(try ExecutableSearch.resolve("python3",
                                             environment: ["PATH": "/usr/bin:/bin"],
                                             sandboxed: false,
                                             fileManager: files)
                == "/usr/bin/python3")
    }

    @Test("a command with a slash in it is taken as given")
    func explicitPathsAreNotSearched() throws {
        let files = FakeFileManager(executables: ["/somewhere/odd/server"])
        #expect(try ExecutableSearch.resolve("/somewhere/odd/server", fileManager: files)
                == "/somewhere/odd/server")
        #expect(throws: ExecutableSearchError.self) {
            try ExecutableSearch.resolve("/nope/missing", fileManager: files)
        }
    }

    @Test("nothing anywhere reports what was searched")
    func nothingFound() {
        let files = FakeFileManager(executables: [])
        do {
            _ = try ExecutableSearch.resolve("nodejs",
                                             environment: ["PATH": "/custom/bin"],
                                             sandboxed: false,
                                             fileManager: files)
            Issue.record("ควรปฏิเสธ")
        } catch let error as ExecutableSearchError {
            guard case .notFound(let name, let searched) = error else {
                Issue.record("ชนิดผิด: \(error)"); return
            }
            #expect(name == "nodejs")
            #expect(searched.contains("/custom/bin"))
            #expect(searched.contains("/opt/homebrew/bin"))
        } catch {
            Issue.record("ชนิดข้อผิดพลาดผิด: \(error)")
        }
    }

    /// On this machine, whatever it has: the resolved interpreter must be one
    /// that actually runs. A test that only checks the ordering would pass on
    /// a machine where the preferred directory holds something broken.
    @Test("the interpreter this machine resolves to really runs")
    func resolvedInterpreterWorks() throws {
        let resolved = try #require(try? ExecutableSearch.resolve("python3"),
                                    "เครื่องนี้ไม่มี python3 เลย")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolved)
        process.arguments = ["-c", "print('ok')"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0)
        #expect(output.contains("ok"))
    }
}
