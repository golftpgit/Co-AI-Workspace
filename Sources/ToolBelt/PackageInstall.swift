import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// What may be installed, and what gets written down (ARCHITECTURE §10, P8.4).
//
// This is the only tool in the system that **downloads somebody else's code and
// runs it**. `RiskScorer` has classified it High and `.mutating` since P1 and
// recorded, in the table, that it was not built yet because "there has to be a
// network policy first". There is one now (P9.3/P9.4), so this is that tool —
// and the rules below are the reason it took a security pass to get here.
//
// **1. A package name is argv, never a command line.** `ProcessSpec.shell` is
// deliberately not used, so `pandas; rm -rf ~` is a package called
// `pandas; rm -rf ~` that does not exist, rather than two commands.
//
// **2. Argv is not enough on its own.** A name starting with `-` becomes a
// *flag*: `--target=/somewhere/else` as a "package" is not a shell injection
// and passing it as a separate argument does not help — pip reads it as an
// option and writes wherever it says. Passing argv protects the shell; this
// rule protects the command. `--` before the name would help and is not
// portable across the managers, so the name is checked instead.
//
// **3. Source distributions are refused by default.** A wheel is data that gets
// unpacked; an sdist runs its own `setup.py` **during installation**, before
// anybody has looked at anything. `--only-binary :all:` is the difference
// between "I downloaded some code" and "I ran some code", and the person asking
// for `pandas` did not ask for the second one. Overridable per call, so a
// package with no wheel is possible and is a decision somebody makes out loud.
//
// **4. It installs into the project, not into the machine.** A study that ran
// against a library installed system-wide is a study whose environment moved
// under it the next time anything else was installed. The target is a
// directory inside the project — which is also the only place the sandbox
// lets a child write.
//
// **5. What was resolved is recorded, not what was asked for.** `pandas` today
// and `pandas` in six months are different software. An installation this
// system cannot name a version for is one nobody can reproduce, so the record
// carries the resolved version and the tool says so when it could not read one.
// ─────────────────────────────────────────────────────────────

public enum PackageManager: String, Sendable, Codable, CaseIterable {
    case pip
    case npm

    public var label: String {
        switch self {
        case .pip: "Python (pip)"
        case .npm: "Node (npm)"
        }
    }

    /// Where this manager's packages go inside a project.
    public var directoryName: String {
        switch self {
        case .pip: "python-packages"
        case .npm: "node_modules"
        }
    }
}

public enum PackageInstallError: Error, CustomStringConvertible, Equatable {
    case emptyName
    case nameLooksLikeAFlag(String)
    case nameHasPathSeparator(String)
    case nameHasShellCharacters(String)
    case unknownManager(String)
    case sourceBuildRefused(String)

    public var description: String {
        switch self {
        case .emptyName:
            "ต้องบอกชื่อแพ็กเกจ"
        case .nameLooksLikeAFlag(let name):
            """
            “\(name)” ขึ้นต้นด้วยขีด ซึ่งตัวจัดการแพ็กเกจจะอ่านเป็น *ตัวเลือก* ไม่ใช่ชื่อแพ็กเกจ \
            — เช่น `--target=…` จะเปลี่ยนที่ติดตั้งไปเลย · ถ้าตั้งใจจะใส่ตัวเลือก ทูลนี้ไม่รับ
            """
        case .nameHasPathSeparator(let name):
            """
            “\(name)” มีเครื่องหมายพาธอยู่ข้างใน — ทูลนี้ติดตั้งจากรีจิสทรีเท่านั้น \
            ไม่ติดตั้งจากไฟล์หรือโฟลเดอร์ในเครื่อง เพราะที่มาของโค้ดต้องตามรอยได้
            """
        case .nameHasShellCharacters(let name):
            """
            “\(name)” มีอักขระที่ไม่ควรอยู่ในชื่อแพ็กเกจ — ชื่อถูกส่งเป็นอาร์กิวเมนต์เดี่ยวอยู่แล้ว \
            แต่ชื่อแบบนี้แปลว่ามีคนตั้งใจให้มันเป็นอย่างอื่น
            """
        case .unknownManager(let raw):
            "ยังไม่รองรับตัวจัดการแพ็กเกจ “\(raw)” — รองรับ "
                + PackageManager.allCases.map(\.rawValue).joined(separator: ", ")
        case .sourceBuildRefused(let name):
            """
            “\(name)” ไม่มีไฟล์สำเร็จรูป (wheel) ต้องคอมไพล์จากซอร์ส ซึ่งแปลว่า \
            **โค้ดของแพ็กเกจจะถูกรันตอนติดตั้ง** ก่อนที่ใครจะได้ดูมัน · \
            ถ้ายอมรับความเสี่ยงนี้ ให้เรียกอีกครั้งด้วย `allow_source_build: true`
            """
        }
    }
}

/// One package to install, after checking.
public struct PackageRequest: Sendable, Equatable {
    public let manager: PackageManager
    public let name: String
    /// Exactly as asked for; `nil` means "whatever is current", which is
    /// recorded as such rather than guessed at.
    public let version: String?
    public let allowSourceBuild: Bool

    /// The only producer. There is no way to build a request that skipped the
    /// checks — the same shape as every other gate in this system.
    public static func checked(manager rawManager: String, name rawName: String,
                               version: String? = nil,
                               allowSourceBuild: Bool = false) throws -> PackageRequest {
        guard let manager = PackageManager(rawValue: rawManager.lowercased()) else {
            throw PackageInstallError.unknownManager(rawManager)
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PackageInstallError.emptyName }
        // Rule 2. This is the one an argv-only defence misses.
        guard !name.hasPrefix("-") else { throw PackageInstallError.nameLooksLikeAFlag(name) }
        guard !name.contains("/"), !name.contains("\\"), !name.contains("..") else {
            throw PackageInstallError.nameHasPathSeparator(name)
        }
        let forbidden = CharacterSet(charactersIn: ";&|`$<>(){}[]!*?\"'\n\t ")
        guard name.rangeOfCharacter(from: forbidden) == nil else {
            throw PackageInstallError.nameHasShellCharacters(name)
        }
        let version = version?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PackageRequest(manager: manager, name: name,
                              version: (version?.isEmpty ?? true) ? nil : version,
                              allowSourceBuild: allowSourceBuild)
    }

    /// What the manager is asked for.
    public var specifier: String {
        guard let version else { return name }
        switch manager {
        case .pip: return "\(name)==\(version)"
        case .npm: return "\(name)@\(version)"
        }
    }

    /// The argv the child runs. Never a command line — see rule 1.
    public func arguments(into directory: URL) -> [String] {
        let path = directory.path(percentEncoded: false)
        switch manager {
        case .pip:
            var arguments = ["-m", "pip", "install", "--no-input", "--disable-pip-version-check",
                             "--target", path]
            // Rule 3.
            if !allowSourceBuild { arguments += ["--only-binary", ":all:"] }
            return arguments + [specifier]
        case .npm:
            return ["install", "--prefix", path, "--no-fund", "--no-audit", specifier]
        }
    }
}

/// What was actually installed, for the record (rule 5).
public struct InstalledPackage: Sendable, Equatable, Codable {
    public let manager: PackageManager
    public let name: String
    /// What the registry actually gave us. `nil` when the output did not say —
    /// reported as unknown rather than filled in with what was requested.
    public let resolvedVersion: String?
    public let installedAt: Date
    public let directory: String

    public init(manager: PackageManager, name: String, resolvedVersion: String?,
                installedAt: Date, directory: String) {
        self.manager = manager
        self.name = name
        self.resolvedVersion = resolvedVersion
        self.installedAt = installedAt
        self.directory = directory
    }

    public var summary: String {
        let version = resolvedVersion.map { "เวอร์ชัน \($0)" }
            ?? "**อ่านเวอร์ชันจากผลลัพธ์ไม่ได้** — งานที่ใช้แพ็กเกจนี้จึงยังทำซ้ำไม่ได้เต็มที่"
        return "\(manager.label) · \(name) \(version)"
    }
}

public enum PackageOutputReader {
    /// The version the manager says it installed.
    ///
    /// Read from the output rather than from the request, because a request
    /// with no version is the common case and is exactly the one where the
    /// answer matters.
    public static func resolvedVersion(of name: String, manager: PackageManager,
                                       in output: String) -> String? {
        switch manager {
        case .pip:
            // "Successfully installed pandas-2.2.1 numpy-1.26.4"
            guard let line = output.components(separatedBy: .newlines)
                .last(where: { $0.contains("Successfully installed") }) else { return nil }
            let lower = name.lowercased().replacingOccurrences(of: "_", with: "-")
            for token in line.split(separator: " ") {
                let piece = String(token)
                guard let dash = piece.lastIndex(of: "-") else { continue }
                let base = String(piece[piece.startIndex..<dash])
                    .lowercased().replacingOccurrences(of: "_", with: "-")
                if base == lower { return String(piece[piece.index(after: dash)...]) }
            }
            return nil
        case .npm:
            // "+ lodash@4.17.21" or "added 1 package"
            for line in output.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("+ ") || trimmed.hasPrefix("added ") else { continue }
                guard let at = trimmed.lastIndex(of: "@"), at > trimmed.startIndex else { continue }
                let base = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<at])
                if base == name { return String(trimmed[trimmed.index(after: at)...]) }
            }
            return nil
        }
    }

    /// Whether the failure was "there is no wheel for this", which is the one
    /// refusal the caller can do something about.
    public static func needsSourceBuild(_ output: String) -> Bool {
        let markers = ["Could not find a version that satisfies",
                       "No matching distribution",
                       "only-binary",
                       "no wheels found"]
        let lower = output.lowercased()
        return markers.contains { lower.contains($0.lowercased()) }
    }
}
