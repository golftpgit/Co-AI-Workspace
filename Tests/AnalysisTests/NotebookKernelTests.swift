import Testing
import Foundation
@testable import Analysis

// ─────────────────────────────────────────────────────────────
// The Python kernel against a real interpreter (ARCHITECTURE §12.5, P6.4).
//
// Nothing is faked: the two Done-when clauses — state survives across cells,
// and a killed kernel restarts — are only true of a process, so these tests
// talk to one. On a machine with no Python they skip loudly rather than pass
// quietly (`check.sh` surfaces every SKIPPED line).
// ─────────────────────────────────────────────────────────────

private func kernel() async throws -> NotebookKernel? {
    do {
        let kernel = try NotebookKernel()
        try await kernel.start()
        return kernel
    } catch let error as KernelError {
        print("SKIPPED: ไม่มี Python สำหรับเทสเคอร์เนล — \(error)")
        return nil
    }
}

@Suite("Notebook kernel")
struct NotebookKernelTests {

    /// The first half of the Done-when, and the only reason to run a kernel
    /// rather than `python3 -c` per cell.
    @Test("state survives from one cell to the next")
    func stateIsPersistent() async throws {
        guard let kernel = try await kernel() else { return }
        defer { Task { await kernel.stop() } }

        _ = try await kernel.execute("x = 41\nimport math")
        let answer = try await kernel.execute("x + 1")
        #expect(answer.value == "42")
        #expect(!answer.failed)
        // A module imported three cells ago is still imported.
        #expect(try await kernel.execute("math.floor(2.7)").value == "2")
    }

    @Test("what a cell prints comes back, Thai included")
    func capturesOutput() async throws {
        guard let kernel = try await kernel() else { return }
        defer { Task { await kernel.stop() } }

        let answer = try await kernel.execute("print('ผลการวิเคราะห์')\nprint('บรรทัดสอง')")
        #expect(answer.stdout == "ผลการวิเคราะห์\nบรรทัดสอง\n")
        // No trailing expression means no value — a cell that ends in an
        // assignment should not print the assignment.
        #expect(answer.value == nil)
    }

    /// A traceback is evidence. §13's rule about compiler output — raw, not
    /// summarised — is the same rule.
    @Test("an error is a result, not the end of the kernel")
    func errorsKeepTheKernel() async throws {
        guard let kernel = try await kernel() else { return }
        defer { Task { await kernel.stop() } }

        _ = try await kernel.execute("keep = 'me'")
        let failed = try await kernel.execute("1 / 0")
        #expect(failed.failed)
        #expect(failed.error?.contains("ZeroDivisionError") == true)
        // The state from before the error is still there.
        #expect(try await kernel.execute("keep").value == "'me'")
        #expect(await kernel.isRunning)
    }

    /// `exit()` in a cell is a mistake people make; it must not take twenty
    /// cells of state with it.
    @Test("exit() in a cell ends the cell, not the kernel")
    func systemExitIsCaught() async throws {
        guard let kernel = try await kernel() else { return }
        defer { Task { await kernel.stop() } }

        _ = try await kernel.execute("survivor = 1")
        let answer = try await kernel.execute("exit()")
        #expect(answer.failed)
        #expect(await kernel.isRunning)
        #expect(try await kernel.execute("survivor").value == "1")
    }

    /// The protocol is JSON lines over stdout. A cell that prints a JSON line
    /// of its own, or writes straight to file descriptor 1, must not be able to
    /// be read as a reply.
    @Test("output that looks like the protocol does not corrupt it")
    func outputCannotForgeAReply() async throws {
        guard let kernel = try await kernel() else { return }
        defer { Task { await kernel.stop() } }

        let answer = try await kernel.execute("""
        import os, sys
        print('{"ok": true, "value": "ปลอม"}')
        os.write(1, b'{"ok": true, "value": "forged"}\\n')
        7
        """)
        #expect(answer.error == nil)
        #expect(answer.value == "7")
        #expect(answer.stdout.contains("ปลอม"))
        // The next cell gets its own answer, not the leftovers of the last one.
        #expect(try await kernel.execute("8").value == "8")
    }

    /// The second half of the Done-when.
    @Test("a restart gives a clean kernel, and the old state is gone")
    func restartClearsState() async throws {
        guard let kernel = try await kernel() else { return }
        defer { Task { await kernel.stop() } }

        _ = try await kernel.execute("gone_after_restart = 1")
        try await kernel.restart()
        #expect(await kernel.isRunning)
        let answer = try await kernel.execute("gone_after_restart")
        #expect(answer.error?.contains("NameError") == true)
        // And it is a working kernel, not just a live process.
        #expect(try await kernel.execute("2 ** 8").value == "256")
    }

    /// A kernel killed from outside — a crashing native extension, a `kill` in
    /// Activity Monitor — has to read as dead rather than as a call that hangs.
    @Test("a kernel killed from outside is reported dead, and can be started again")
    func killedKernelRestarts() async throws {
        guard let kernel = try await kernel() else { return }
        defer { Task { await kernel.stop() } }

        _ = try await kernel.execute("1")
        await kernel.stop()
        #expect(await !kernel.isRunning)
        await #expect(throws: KernelError.self) { try await kernel.execute("1") }

        try await kernel.start()
        #expect(try await kernel.execute("1 + 1").value == "2")
    }

    /// A cell that runs too long is interrupted, and the interrupt is a
    /// result — the state stays. Restarting underneath the user would throw
    /// away everything the session built.
    @Test("a cell that runs too long is interrupted without losing the session")
    func longCellIsInterrupted() async throws {
        guard let kernel = try await kernel() else { return }
        defer { Task { await kernel.stop() } }

        _ = try await kernel.execute("precious = 'still here'")
        await kernel.setCellTimeout(.seconds(2))
        let answer = try await kernel.execute("import time\ntime.sleep(60)")
        #expect(answer.failed)
        #expect(answer.error?.contains("KeyboardInterrupt") == true)

        await kernel.setCellTimeout(.seconds(60))
        #expect(await kernel.isRunning)
        #expect(try await kernel.execute("precious").value == "'still here'")
    }

    @Test("the interpreter reports its own version, from the process that is running")
    func reportsVersion() async throws {
        guard let kernel = try await kernel() else { return }
        defer { Task { await kernel.stop() } }
        let version = await kernel.pythonVersion
        #expect(version?.hasPrefix("3.") == true)
    }

    @Test("a path that is not an interpreter fails at construction, not at the first cell")
    func missingInterpreter() {
        #expect(throws: KernelError.self) {
            _ = try NotebookKernel(interpreter: "/nowhere/python3")
        }
    }
}
