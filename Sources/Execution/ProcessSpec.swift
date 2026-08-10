import Foundation

// ─────────────────────────────────────────────────────────────
// What Execution runs, and what comes back (ARCHITECTURE §13).
// ─────────────────────────────────────────────────────────────

public struct ProcessSpec: Sendable {
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: URL?
    /// Merged over the app's own environment; nil values are not representable
    /// so a spec can add but never blank out PATH by accident.
    public var environmentOverrides: [String: String]
    public var stdin: String?
    public var timeout: Duration
    /// Seatbelt confinement. Nil means "inherit whatever confines us", which is
    /// the App Sandbox in the shipped app and nothing in a `swift test` run.
    public var sandbox: SandboxProfile?
    /// Per stream. Generous, because §13 requires compiler output to go back
    /// into the turn raw rather than summarised.
    public var outputLimit: Int

    public init(executable: String,
                arguments: [String] = [],
                workingDirectory: URL? = nil,
                environmentOverrides: [String: String] = [:],
                stdin: String? = nil,
                timeout: Duration = .seconds(120),
                sandbox: SandboxProfile? = nil,
                outputLimit: Int = 256 * 1024) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environmentOverrides = environmentOverrides
        self.stdin = stdin
        self.timeout = timeout
        self.sandbox = sandbox
        self.outputLimit = outputLimit
    }

    /// A shell command. `run_shell` is the one tool that takes a command line
    /// rather than argv — `install_package` deliberately does not, because a
    /// package name should never be able to become a second command (§10).
    public static func shell(_ command: String,
                             workingDirectory: URL? = nil,
                             timeout: Duration = .seconds(120),
                             sandbox: SandboxProfile? = nil) -> ProcessSpec {
        ProcessSpec(executable: "/bin/sh",
                    arguments: ["-c", command],
                    workingDirectory: workingDirectory,
                    timeout: timeout,
                    sandbox: sandbox)
    }
}

public enum TerminationReason: Sendable, Equatable {
    case exited
    case signal(Int32)
    case timedOut
    case stoppedByUser

    public var label: String {
        switch self {
        case .exited: return "จบตามปกติ"
        case .signal(let s): return "ถูกสัญญาณ \(s)"
        case .timedOut: return "หมดเวลา"
        case .stoppedByUser: return "ผู้ใช้สั่งหยุด"
        }
    }
}

public struct ProcessOutcome: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let reason: TerminationReason
    public let duration: TimeInterval
    /// False when the seatbelt profile could not be applied — reported rather
    /// than assumed, so nobody reads "sandboxed" off a spec that had one set.
    public let sandboxApplied: Bool
    public let outputTruncated: Bool

    public var succeeded: Bool { reason == .exited && exitCode == 0 }

    public init(exitCode: Int32, stdout: String, stderr: String,
                reason: TerminationReason, duration: TimeInterval,
                sandboxApplied: Bool, outputTruncated: Bool) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.reason = reason
        self.duration = duration
        self.sandboxApplied = sandboxApplied
        self.outputTruncated = outputTruncated
    }
}

public struct OutputChunk: Sendable {
    public enum Stream: String, Sendable { case stdout, stderr }
    public let stream: Stream
    public let text: String
}

public enum ProcessState: Sendable, Equatable {
    case running
    case paused
    case finished(TerminationReason, exitCode: Int32)

    public var isLive: Bool { self == .running || self == .paused }
}

public enum ExecutionError: Error, CustomStringConvertible, Equatable {
    case executableMissing(String)
    case launchFailed(String)
    case unknownProcess(String)
    case notLive(String)

    public var description: String {
        switch self {
        case .executableMissing(let p): return "ไม่พบโปรแกรมที่จะรัน: \(p)"
        case .launchFailed(let m): return "เริ่มโปรเซสไม่สำเร็จ: \(m)"
        case .unknownProcess(let id): return "ไม่รู้จักโปรเซส '\(id)'"
        case .notLive(let id): return "โปรเซส '\(id)' จบไปแล้ว"
        }
    }
}
