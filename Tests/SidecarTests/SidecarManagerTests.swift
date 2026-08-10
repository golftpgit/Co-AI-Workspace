import Testing
import Foundation
@testable import Sidecar
@testable import Config

private func tempPaths() -> AppPaths {
    AppPaths(root: URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "coai-sidecar-\(UUID().uuidString)"))
}

/// A stand-in for a real sidecar: `sleep` runs until something kills it,
/// which is exactly the behaviour we need to test supervision against.
private func sleeperSpec(id: String = "sleeper",
                         seconds: Int = 600,
                         maxRestarts: Int = 5) -> SidecarSpec {
    SidecarSpec(id: id,
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["\(seconds)"],
                healthURL: nil,
                readinessTimeout: .seconds(3),
                maxRestarts: maxRestarts,
                restartWindow: .seconds(60))
}

private func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

private func pid(of status: SidecarStatus) -> Int32? {
    if case .running(let pid) = status { return pid }
    return nil
}

@Suite("SidecarManager lifecycle", .serialized)
struct SidecarLifecycleTests {
    @Test("starts a process and reports it running")
    func startsProcess() async throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let manager = SidecarManager(paths: paths)

        try await manager.start(sleeperSpec())
        let status = await manager.status(of: "sleeper")
        let livePID = try #require(pid(of: status))
        #expect(isAlive(livePID))

        await manager.stopAll()
    }

    /// Done-when for P0.4, half one: quitting must leave nothing behind.
    @Test("stopAll leaves no surviving process")
    func stopAllTerminates() async throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let manager = SidecarManager(paths: paths)

        try await manager.start(sleeperSpec())
        let livePID = try #require(pid(of: await manager.status(of: "sleeper")))

        await manager.stopAll()
        #expect(await manager.status(of: "sleeper") == .stopped)
        #expect(!isAlive(livePID))
    }

    /// Done-when for P0.4, half two: an externally killed sidecar comes back
    /// on its own within ~5s.
    @Test("an externally killed sidecar is restarted", .timeLimit(.minutes(1)))
    func restartsAfterExternalKill() async throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let manager = SidecarManager(paths: paths)

        try await manager.start(sleeperSpec())
        let firstPID = try #require(pid(of: await manager.status(of: "sleeper")))

        kill(firstPID, SIGKILL)   // simulate a crash / external kill

        var secondPID: Int32?
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if let p = pid(of: await manager.status(of: "sleeper")), p != firstPID {
                secondPID = p
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        let recovered = try #require(secondPID, "sidecar did not restart within 5s")
        #expect(isAlive(recovered))
        #expect(!isAlive(firstPID))

        await manager.stopAll()
    }

    @Test("an intentional stop is not undone by the supervisor", .timeLimit(.minutes(1)))
    func intentionalStopStaysStopped() async throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let manager = SidecarManager(paths: paths)

        try await manager.start(sleeperSpec())
        await manager.stop("sleeper")

        try await Task.sleep(for: .seconds(2))
        #expect(await manager.status(of: "sleeper") == .stopped)
    }

    /// A sidecar that cannot stay up must give up, not spawn forever.
    @Test("restart attempts are bounded", .timeLimit(.minutes(1)))
    func restartsAreBounded() async throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let manager = SidecarManager(paths: paths)

        // `true` exits immediately, so every restart fails again at once.
        let flaky = SidecarSpec(id: "flaky",
                                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                                arguments: [],
                                healthURL: nil,
                                readinessTimeout: .seconds(1),
                                maxRestarts: 2,
                                restartWindow: .seconds(60))
        try await manager.start(flaky)

        var finalStatus = await manager.status(of: "flaky")
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            finalStatus = await manager.status(of: "flaky")
            if case .failed = finalStatus { break }
            try? await Task.sleep(for: .milliseconds(200))
        }

        guard case .failed = finalStatus else {
            Issue.record("expected .failed after exhausting restarts, got \(finalStatus)")
            return
        }
        await manager.stopAll()
    }

    @Test("a missing executable fails loudly instead of silently doing nothing")
    func missingExecutable() async {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let manager = SidecarManager(paths: paths)

        let spec = SidecarSpec(id: "ghost",
                               executableURL: URL(fileURLWithPath: "/nonexistent/binary"))
        await #expect(throws: SidecarError.self) { try await manager.start(spec) }
    }

    @Test("readiness waits for the health probe", .timeLimit(.minutes(1)))
    func waitsForHealthProbe() async throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        // Probe answers only after a few polls — proves we actually wait.
        let counter = Counter()
        let manager = SidecarManager(paths: paths) { _ in await counter.bumpAndCheck(threshold: 3) }

        var spec = sleeperSpec(id: "probed")
        spec = SidecarSpec(id: spec.id,
                           executableURL: spec.executableURL,
                           arguments: spec.arguments,
                           healthURL: URL(string: "http://127.0.0.1:1/health"),
                           readinessTimeout: .seconds(5))
        try await manager.start(spec)

        #expect(pid(of: await manager.status(of: "probed")) != nil)
        #expect(await counter.value >= 3)
        await manager.stopAll()
    }

    @Test("readiness timeout is reported, not hidden", .timeLimit(.minutes(1)))
    func readinessTimeout() async throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let manager = SidecarManager(paths: paths) { _ in false }   // never ready

        let spec = SidecarSpec(id: "never",
                               executableURL: URL(fileURLWithPath: "/bin/sleep"),
                               arguments: ["600"],
                               healthURL: URL(string: "http://127.0.0.1:1/health"),
                               readinessTimeout: .seconds(1))
        await #expect(throws: SidecarError.self) { try await manager.start(spec) }
        await manager.stopAll()
    }

    /// Crash-orphan reaping: a live process recorded in a pid file from a
    /// previous run must be killed before a new one starts.
    @Test("an orphan from a previous run is reaped", .timeLimit(.minutes(1)))
    func reapsOrphan() async throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try paths.createDirectories()

        let orphan = Process()
        orphan.executableURL = URL(fileURLWithPath: "/bin/sleep")
        orphan.arguments = ["600"]
        try orphan.run()
        let orphanPID = orphan.processIdentifier
        try "\(orphanPID)".write(to: paths.logsDirectory.appending(path: "sleeper.pid"),
                                 atomically: true, encoding: .utf8)

        let manager = SidecarManager(paths: paths)
        try await manager.start(sleeperSpec())

        var reaped = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if !isAlive(orphanPID) { reaped = true; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        #expect(reaped, "orphaned process from a previous run was not reaped")

        await manager.stopAll()
    }
}

private actor Counter {
    private(set) var value = 0
    func bumpAndCheck(threshold: Int) -> Bool {
        value += 1
        return value >= threshold
    }
}
