import Foundation
import Darwin

// ─────────────────────────────────────────────────────────────
// Why not Foundation's `Process` (ARCHITECTURE §13).
//
// The kill switch has to reach the whole process tree: a command that spawns
// children must not leave them running when the user presses Stop, and an
// agent must not be able to outlive its own signal. That means the child needs
// its *own process group*, so `kill(-pgid, …)` hits everything it started and
// nothing of ours.
//
// `Process` gives the child our process group, and `setpgid` from the parent
// races with the child's `exec`. `posix_spawn` sets the group atomically at
// spawn time, so the guarantee holds from the first instruction the child runs.
// ─────────────────────────────────────────────────────────────

struct SpawnedChild: Sendable {
    /// Also the process-group id: spawned with `POSIX_SPAWN_SETPGROUP` and
    /// group 0, which means "new group named after me".
    let pid: pid_t
    let stdinFD: Int32
    let stdoutFD: Int32
    let stderrFD: Int32
}

enum SpawnError: Error, CustomStringConvertible {
    case pipeFailed(Int32)
    case spawnFailed(code: Int32, executable: String)

    var description: String {
        switch self {
        case .pipeFailed(let code):
            return "pipe() failed: \(String(cString: strerror(code)))"
        case .spawnFailed(let code, let executable):
            return "spawn '\(executable)' failed: \(String(cString: strerror(code)))"
        }
    }
}

enum Spawn {
    static func launch(executable: String,
                       arguments: [String],
                       workingDirectory: String?,
                       environment: [String: String]) throws -> SpawnedChild {
        let stdinPipe = try makePipe()
        let stdoutPipe = try makePipe()
        let stderrPipe = try makePipe()

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdinPipe.read, 0)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe.write, 1)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe.write, 2)
        if let workingDirectory {
            posix_spawn_file_actions_addchdir(&actions, workingDirectory)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // SETPGROUP + group 0 is the whole point of this file; CLOEXEC_DEFAULT
        // keeps the child from inheriting our sockets and database handles.
        //
        // SETSIGDEF and SETSIGMASK are here because signal dispositions are
        // inherited across exec, and a child that inherits SIG_IGN for SIGINT
        // is a child the Stop button cannot reach. This is not hypothetical:
        // a process started from a non-interactive shell has SIGINT and SIGQUIT
        // ignored, and CPython does not install its own SIGINT handler when it
        // finds one already ignored — so a notebook cell spawned that way ran
        // `time.sleep(60)` straight through the interrupt (found by P6.4's
        // test, which is why it exists).
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        posix_spawnattr_setsigmask(&attributes, &unblocked)
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                  | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)

        var pid: pid_t = 0
        let status = withCStrings([executable] + arguments) { argv in
            withCStrings(environment.map { "\($0.key)=\($0.value)" }) { envp in
                posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
            }
        }

        // The child owns its ends now; holding them open in the parent would
        // mean stdout never reports EOF and the reader loop never finishes.
        close(stdinPipe.read); close(stdoutPipe.write); close(stderrPipe.write)

        guard status == 0 else {
            close(stdinPipe.write); close(stdoutPipe.read); close(stderrPipe.read)
            throw SpawnError.spawnFailed(code: status, executable: executable)
        }
        return SpawnedChild(pid: pid,
                            stdinFD: stdinPipe.write,
                            stdoutFD: stdoutPipe.read,
                            stderrFD: stderrPipe.read)
    }

    /// Signals the child's whole process group. Negative pid is the group form.
    static func signalGroup(_ pid: pid_t, _ signal: Int32) {
        kill(-pid, signal)
    }

    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [-1, -1]
        let result = fds.withUnsafeMutableBufferPointer { pipe($0.baseAddress!) }
        guard result == 0 else { throw SpawnError.pipeFailed(errno) }
        return (fds[0], fds[1])
    }

    private static func withCStrings<R>(_ strings: [String],
                                        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { for pointer in pointers { free(pointer) } }
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}
