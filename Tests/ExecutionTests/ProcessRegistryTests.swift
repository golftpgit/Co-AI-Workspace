import Testing
import Foundation
import Darwin
import Observability
@testable import Execution

// ─────────────────────────────────────────────────────────────
// Done-when for P1.9: real commands run, Stop actually kills, and nothing is
// left behind. Every test here talks to the real kernel — a mocked process
// would prove nothing about signals or reaping.
// ─────────────────────────────────────────────────────────────

private func scratch() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "coai-exec-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// True while the pid exists *and* has not become a zombie. `kill(pid, 0)`
/// alone answers yes for an unreaped child, which is the bug we are testing for.
private func isAlive(_ pid: pid_t) -> Bool {
    guard kill(pid, 0) == 0 else { return false }
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.size
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == Int32(size) else { return false }
    return info.pbi_status != UInt32(SZOMB)
}

@Suite("Running real commands")
struct ProcessExecutionTests {
    @Test("a command runs and both streams come back with the exit code")
    func capturesOutputAndExitCode() async throws {
        let registry = ProcessRegistry()
        let outcome = try await registry.run(
            .shell("echo บนหน้าจอ; echo ผิดพลาด >&2; exit 3", workingDirectory: scratch()),
            label: "test")

        #expect(outcome.exitCode == 3)
        #expect(outcome.reason == .exited)
        #expect(outcome.stdout.contains("บนหน้าจอ"))
        #expect(outcome.stderr.contains("ผิดพลาด"))
        #expect(!outcome.succeeded)
    }

    @Test("output streams while the command is still running")
    func streamsIncrementally() async throws {
        let directory = scratch()
        let flag = directory.appending(path: "first-chunk-was-delivered")
            .path(percentEncoded: false)
        let registry = ProcessRegistry()

        // The command cannot reach its second write until the caller has
        // *received* the first, so streaming is what lets this finish at all.
        //
        // It used to echo twice around a sleep and count callbacks after the
        // fact, which measured machine load: under a busy CI or a full local
        // suite the two writes arrive coalesced and the count is 1. There is
        // nothing to tune here — either the first chunk came out mid-run or
        // the second write never happened.
        let outcome = try await registry.run(
            .shell("""
            echo หนึ่ง
            for _ in $(seq 1 200); do [ -f "\(flag)" ] && break; sleep 0.05; done
            [ -f "\(flag)" ] && echo สอง
            """, workingDirectory: directory),
            label: "stream",
            onOutput: { chunk in
                if chunk.text.contains("หนึ่ง") {
                    FileManager.default.createFile(atPath: flag, contents: nil)
                }
            })

        #expect(outcome.succeeded)
        #expect(outcome.stdout.contains("หนึ่ง"))
        #expect(outcome.stdout.contains("สอง"),
                "the second write never ran — the first chunk did not reach the caller until the process had already exited")
    }

    @Test("stdin is piped in, for the notebook kernel path")
    func pipesStdin() async throws {
        let registry = ProcessRegistry()
        var spec = ProcessSpec.shell("cat", workingDirectory: scratch())
        spec.stdin = "จากทาง stdin\n"
        let outcome = try await registry.run(spec, label: "stdin")
        #expect(outcome.stdout.contains("จากทาง stdin"))
    }

    @Test("a missing executable fails before anything is spawned")
    func missingExecutableFails() async {
        let registry = ProcessRegistry()
        await #expect(throws: ExecutionError.self) {
            _ = try await registry.run(ProcessSpec(executable: "/nope/not/here"), label: "missing")
        }
    }

    @Test("output past the limit is truncated and says so")
    func truncatesHugeOutput() async throws {
        let registry = ProcessRegistry()
        var spec = ProcessSpec.shell("for i in $(seq 1 5000); do echo 0123456789012345678901234567890123456789; done",
                                     workingDirectory: scratch())
        spec.outputLimit = 4096
        let outcome = try await registry.run(spec, label: "flood")
        #expect(outcome.outputTruncated)
        #expect(outcome.stdout.count <= 4096)
    }
}

@Suite("Stop actually stops")
struct ProcessControlTests {
    /// The kill switch has to reach children too — an agent that spawns a
    /// long-running grandchild must not be able to outlive Stop (§13).
    @Test("stopping kills the whole process group, not just the shell")
    func stopKillsTheGroup() async throws {
        let registry = ProcessRegistry()
        let marker = scratch().appending(path: "pid")

        let running = Task {
            try await registry.run(
                .shell("(sleep 30 & echo $! > \(marker.path(percentEncoded: false)); wait)",
                       workingDirectory: scratch(), timeout: .seconds(30)),
                label: "tree")
        }

        let entry = try await waitForValue { await registry.live().first }
        // Wait for the grandchild to exist before killing, or the test proves nothing.
        let grandchild = try await waitForValue { () -> pid_t? in
            guard let text = try? String(contentsOf: marker, encoding: .utf8) else { return nil }
            return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        #expect(isAlive(grandchild))

        await registry.stop(entry.id)
        let outcome = try await running.value
        #expect(outcome.reason == .stoppedByUser)

        try await waitUntil { !isAlive(grandchild) }
        #expect(!isAlive(grandchild), "the sleep the shell spawned survived Stop")
    }

    @Test("pause suspends the process and resume lets it finish")
    func pauseAndResume() async throws {
        let registry = ProcessRegistry()
        let done = scratch().appending(path: "done")
        let running = Task {
            try await registry.run(
                .shell("sleep 0.2; echo ok > \(done.path(percentEncoded: false))",
                       workingDirectory: scratch(), timeout: .seconds(20)),
                label: "pausable")
        }

        let entry = try await waitForValue { await registry.live().first }
        try await registry.pause(entry.id)
        #expect(await registry.live().first?.state == .paused)

        // Long past the 0.2s sleep: a suspended process makes no progress.
        try await Task.sleep(for: .milliseconds(500))
        #expect(!FileManager.default.fileExists(atPath: done.path(percentEncoded: false)))

        try await registry.resume(entry.id)
        let outcome = try await running.value
        #expect(outcome.succeeded)
    }

    /// SIGTERM to a suspended process is queued, not delivered. Stopping a
    /// paused process therefore has to continue it first, or "killed" processes
    /// linger forever.
    @Test("a paused process can still be stopped")
    func stopWorksWhilePaused() async throws {
        let registry = ProcessRegistry()
        let running = Task {
            try await registry.run(.shell("sleep 30", workingDirectory: scratch(), timeout: .seconds(30)),
                                   label: "paused-stop")
        }

        let entry = try await waitForValue { await registry.live().first }
        try await registry.pause(entry.id)
        await registry.stop(entry.id)

        let outcome = try await running.value
        #expect(outcome.reason == .stoppedByUser)
        #expect(!isAlive(entry.pid))
    }

    @Test("a command that overruns its timeout is stopped and reported as such")
    func timeoutStops() async throws {
        let registry = ProcessRegistry()
        let outcome = try await registry.run(
            .shell("sleep 30", workingDirectory: scratch(), timeout: .milliseconds(200)),
            label: "timeout")
        #expect(outcome.reason == .timedOut)
        #expect(outcome.exitCode >= 128)
    }

    /// No zombies: every child is reaped whether it exited, timed out or was
    /// killed, and the registry only lists what is actually alive.
    @Test("finished processes are reaped and leave the registry")
    func noZombiesOrGhostRows() async throws {
        let registry = ProcessRegistry()
        var pids: [pid_t] = []

        // Each finishes a different way — normally, by timeout, and by Stop —
        // because reaping is easy to get right for one of the three and wrong
        // for the others. The sleeps only exist so the pid can be observed.
        for (command, stop) in [("sleep 0.2; exit 7", false), ("sleep 30", false), ("sleep 30", true)] {
            let spec = ProcessSpec.shell(command, workingDirectory: scratch(),
                                         timeout: .milliseconds(600))
            let running = Task { try await registry.run(spec, label: command) }
            let entry = try await waitForValue { await registry.live().first }
            pids.append(entry.pid)
            if stop { await registry.stop(entry.id) }
            _ = try? await running.value
        }

        #expect(await registry.list().isEmpty, "a finished process is still listed as live")
        for pid in pids {
            #expect(!isAlive(pid), "pid \(pid) was never reaped")
        }
    }

    @Test("stopAll clears everything at shutdown")
    func stopAllClears() async throws {
        let registry = ProcessRegistry()
        let running = (0..<3).map { index in
            Task {
                try await registry.run(.shell("sleep 30", workingDirectory: scratch(),
                                              timeout: .seconds(30)),
                                       label: "bulk-\(index)")
            }
        }
        try await waitUntil { await registry.live().count == 3 }
        await registry.stopAll()
        for task in running {
            #expect(try await task.value.reason == .stoppedByUser)
        }
        #expect(await registry.live().isEmpty)
    }
}

@Suite("Sandbox confinement")
struct SandboxTests {
    @Test("a write outside the project root is refused by the kernel")
    func writesOutsideRootAreDenied() async throws {
        try #require(SandboxProfile.isApplicable, "sandbox-exec unavailable in this context")
        let root = scratch()
        // Somewhere the profile does not list — under the user's home rather
        // than a temp directory, which the profile allows on purpose.
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".coai-sandbox-probe-\(UUID().uuidString)")

        let registry = ProcessRegistry()
        let outcome = try await registry.run(
            .shell("echo inside > ok.txt; echo outside > \(home.path(percentEncoded: false))",
                   workingDirectory: root,
                   sandbox: .project(root: root)),
            label: "sandbox")

        #expect(outcome.sandboxApplied)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "ok.txt").path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: home.path(percentEncoded: false)))
        #expect(outcome.exitCode != 0)
    }

    @Test("network is off unless the profile allows it")
    func networkIsDeniedByDefault() async throws {
        try #require(SandboxProfile.isApplicable, "sandbox-exec unavailable in this context")
        let root = scratch()
        let registry = ProcessRegistry()
        let outcome = try await registry.run(
            .shell("curl -sS -m 5 https://example.com -o /dev/null", workingDirectory: root,
                   sandbox: .project(root: root)),
            label: "net")
        #expect(outcome.exitCode != 0)
    }

    /// The profile is written against resolved paths because seatbelt matches
    /// the real filesystem, not the /tmp and /var symlinks.
    @Test("the profile resolves symlinked paths")
    func profileUsesRealPaths() {
        let profile = SandboxProfile(writableSubpaths: ["/tmp"], allowNetwork: false)
        #expect(profile.profileText.contains("/private/tmp"))
        #expect(profile.profileText.contains("(deny network*)"))
    }

    @Test("allowing network removes only that denial")
    func networkCanBeAllowed() {
        let profile = SandboxProfile(writableSubpaths: ["/private/tmp"], allowNetwork: true)
        #expect(!profile.profileText.contains("(deny network*)"))
        #expect(profile.profileText.contains("(deny file-write*)"))
    }
}

private struct WaitTimedOut: Error {}

/// Polls until the condition holds. The registry is asynchronous by nature —
/// a fixed sleep here is either flaky or slow, and both hide real failures.
private func waitUntil(timeout: Duration = .seconds(5),
                       _ condition: @Sendable () async throws -> Bool) async throws {
    _ = try await waitForValue(timeout: timeout) { try await condition() ? true : nil }
}

private func waitForValue<T: Sendable>(timeout: Duration = .seconds(5),
                                       _ produce: @Sendable () async throws -> T?) async throws -> T {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if let value = try await produce() { return value }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw WaitTimedOut()
}
