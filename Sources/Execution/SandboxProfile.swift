import Foundation
import Darwin

// ─────────────────────────────────────────────────────────────
// Seatbelt profile for child processes (ARCHITECTURE §13).
//
// v1 tried to isolate commands in userspace — a deny-list of strings the agent
// could always phrase around. Here the kernel enforces it: the command runs
// under `sandbox-exec`, and a write outside the project root fails with
// EPERM no matter how the command spells the path.
//
// The app itself already runs in the App Sandbox. Inside a container the outer
// sandbox cannot be nested, so `isApplicable` reports false and the caller
// records that the OS-level profile was not applied instead of pretending it
// was. Either way the child is confined — by the app's own container, at least.
// ─────────────────────────────────────────────────────────────

public struct SandboxProfile: Sendable, Equatable {
    /// Anything outside these subpaths is read-only to the child.
    public var writableSubpaths: [String]
    public var allowNetwork: Bool

    public init(writableSubpaths: [String], allowNetwork: Bool = false) {
        self.writableSubpaths = writableSubpaths
        self.allowNetwork = allowNetwork
    }

    /// The default for a project command: read anything, write only inside the
    /// project and the temp directories a compiler needs, no network.
    public static func project(root: URL, allowNetwork: Bool = false) -> SandboxProfile {
        SandboxProfile(
            writableSubpaths: [root.path(percentEncoded: false),
                               "/private/tmp",
                               "/private/var/folders",
                               NSTemporaryDirectory()],
            allowNetwork: allowNetwork)
    }

    /// SBPL text passed to `sandbox-exec -p`.
    ///
    /// `allow default` then deny by category, rather than `deny default` then
    /// allow: a deny-by-default profile has to enumerate every dylib, sysctl
    /// and mach service a toolchain touches, and gets silently over-permissive
    /// the moment someone widens it to make a build work.
    public var profileText: String {
        var lines = ["(version 1)", "(allow default)"]
        if !allowNetwork {
            lines.append("(deny network*)")
        }
        lines.append("(deny file-write*)")
        var seen = Set<String>()
        let subpaths = writableSubpaths
            .flatMap(Self.pathForms)
            .filter { seen.insert($0).inserted }
            .map { "(subpath \(Self.quote($0)))" }
            .joined(separator: " ")
        if !subpaths.isEmpty {
            lines.append("(allow file-write* \(subpaths))")
        }
        // /dev/null and the tty are writes too, and every shell needs them.
        lines.append("(allow file-write* (literal \"/dev/null\") (literal \"/dev/dtracehelper\") (regex #\"^/dev/tty\"))")
        return lines.joined(separator: "\n")
    }

    public static let executable = "/usr/bin/sandbox-exec"

    /// False inside the App Sandbox (a container cannot host a nested profile)
    /// or where the tool is missing, so the caller can report the truth.
    public static var isApplicable: Bool {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return false }
        return ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil
    }

    /// Both the path as written and its real path.
    ///
    /// `/tmp` and `/var` are symlinks into `/private` on macOS and seatbelt
    /// matches the real path, so a profile listing only `/tmp` silently allows
    /// nothing. `URL.resolvingSymlinksInPath()` is no help — it deliberately
    /// *strips* a `/private` prefix, which is the wrong direction — so this
    /// goes to `realpath(3)`. Listing both forms means a path that does not
    /// exist yet still gets the entry it was asked for.
    private static func pathForms(_ path: String) -> [String] {
        var forms = [trimSlash(path)]
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            forms.append(trimSlash(String(cString: resolved)))
        }
        return forms
    }

    private static func trimSlash(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func quote(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\")
                   .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
