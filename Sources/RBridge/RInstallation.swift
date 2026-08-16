import Foundation
import Execution

// ─────────────────────────────────────────────────────────────
// Is R on this machine, and can it run the bridge? (ARCHITECTURE §12.7, P14.1)
//
// The Done-when names two machines and the second one is the harder promise:
// on a machine **without** R, the screen says what to install — it does not
// hand somebody an error to interpret. "connection refused" and "command not
// found" are both technically accurate and both useless: they describe what
// the code experienced rather than what the person has to do.
//
// So this reports one of a small number of states, each with the next step
// already written, and it never guesses. In particular, **failing to find R is
// not the same as finding an R that cannot serve the bridge** — one is an
// install, the other is two packages — and collapsing them would send somebody
// to reinstall a working R.
//
// What this deliberately does not do is install anything. §12.7 and P14.4 are
// agreed on that: installing packages is a decision with somebody's name on
// it, and a setup helper that quietly runs `install.packages` is a helper that
// modifies the machine to make its own status green.
// ─────────────────────────────────────────────────────────────

/// The packages the generated bridge needs. Both ship as ordinary CRAN
/// packages; `plumber` is the usual suggestion for this job and is
/// deliberately not used — see `BridgeScript`.
public let requiredRPackages = ["httpuv", "jsonlite"]

public enum RSetupStatus: Sendable, Equatable {
    /// R is installed and has everything the bridge needs.
    case ready(version: String, path: String)
    /// R is installed; these packages are missing.
    case missingPackages(version: String, path: String, missing: [String])
    /// No R on this machine.
    case notInstalled(searched: [String])
    /// R is there and would not answer — a broken install, a half-finished
    /// upgrade. Reported separately because "install R" is the wrong advice
    /// for a machine that already has one.
    case unusable(path: String, detail: String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// What to do next, in words, always. A status with no next step is the
    /// error this type exists to replace.
    public var nextStep: String {
        switch self {
        case .ready(let version, let path):
            "R \(version) ที่ \(path) พร้อมใช้ — เหลือแค่สั่งให้สะพานขึ้น"
        case .missingPackages(_, _, let missing):
            "R มีอยู่แล้ว แต่ยังขาดแพ็กเกจ \(missing.joined(separator: ", ")) — "
                + "เปิด R แล้วสั่ง install.packages(c(\(missing.map { "\"\($0)\"" }.joined(separator: ", ")))) "
                + "· ระบบไม่ติดตั้งให้เอง เพราะการติดตั้งแพ็กเกจเป็นการเปลี่ยนเครื่องของคุณ"
        case .notInstalled:
            "เครื่องนี้ยังไม่มี R — ติดตั้งจาก https://cran.r-project.org (แพ็กเกจ .pkg ของ macOS) "
                + "หรือ brew install --cask r แล้วกดตรวจอีกครั้ง"
        case .unusable(let path, let detail):
            "พบ R ที่ \(path) แต่เรียกใช้ไม่ได้ (\(detail)) — น่าจะติดตั้งค้างไว้ "
                + "ลองติดตั้งทับอีกครั้งก่อน ไม่ใช่ลบทิ้ง"
        }
    }
}

/// Runs a command and returns its standard output, or nil if it could not run.
/// Injected so the probe is testable without an R on the machine.
public typealias CommandRunner = @Sendable (_ launchPath: String, _ arguments: [String]) async -> String?

public struct RProbe: Sendable {
    private let run: CommandRunner
    private let locate: @Sendable (String) -> String?

    public init(locate: @escaping @Sendable (String) -> String? = RProbe.findOnDisk,
                run: @escaping CommandRunner = RProbe.runCommand) {
        self.locate = locate
        self.run = run
    }

    public func status() async -> RSetupStatus {
        guard let path = locate("Rscript") else {
            return .notInstalled(searched: ExecutableSearch.toolchainDirectories)
        }
        guard let version = await run(path, ["-e", "cat(as.character(getRversion()))"]),
              !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unusable(path: path, detail: "เรียก Rscript แล้วไม่ได้เวอร์ชันกลับมา")
        }
        let clean = version.trimmingCharacters(in: .whitespacesAndNewlines)

        // One call, not one per package: asking R to start four times to
        // answer four yes/no questions is most of a second for nothing.
        let query = "cat(paste(rownames(installed.packages()), collapse=' '))"
        let installed = Set((await run(path, ["-e", query]) ?? "")
            .split(whereSeparator: \.isWhitespace).map(String.init))
        let missing = requiredRPackages.filter { !installed.contains($0) }

        return missing.isEmpty
            ? .ready(version: clean, path: path)
            : .missingPackages(version: clean, path: path, missing: missing)
    }

    // MARK: - the real implementations

    /// R installs into `/usr/local/bin` on macOS (the CRAN package) or
    /// Homebrew's prefix. `ExecutableSearch` already knows where real tools
    /// live and why `PATH` is not enough inside a sandbox.
    public static let findOnDisk: @Sendable (String) -> String? = { command in
        try? ExecutableSearch.resolve(command)
    }

    public static let runCommand: CommandRunner = { launchPath, arguments in
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(filePath: launchPath)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            continuation.resume(returning: String(data: data, encoding: .utf8))
        }
    }
}
