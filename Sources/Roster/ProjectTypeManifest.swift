import Foundation
import AgentKit
import ProjectKit

// ─────────────────────────────────────────────────────────────
// Project types, as files (ARCHITECTURE §20.2, P11.1).
//
// `ProjectKind` has said since it was written that it is "a declared shape, not
// behaviour: what each one implies lives in its manifest". This is the manifest,
// and it is read by **the same parser as agents and skills** — the frontmatter
// reader in `Manifest.swift`, not a second one. Two readers would drift, and the
// first thing to drift would be the thing that decides what a project starts
// with.
//
// §20.2 illustrates the format with nested YAML. This uses the flat frontmatter
// §7.2 already chose, with a repeated key where the illustration had a list of
// dictionaries: `gate:` three times rather than a `gates:` block. That is a
// deliberate departure from the picture in order to keep the rule underneath it
// — one parser — which is what the Done-when actually asks for.
//
// The one thing a manifest **cannot** do is tailor a practice out. §19.15 makes
// that a governance decision with a person's name on it, and `TailoringRecord`
// refuses to exist without one. So a manifest *suggests*, with the reason
// pre-written, and a person still has to put their name to it. A file that could
// remove an assurance practice on its own would be a file that could remove the
// reason anybody trusts the record.
// ─────────────────────────────────────────────────────────────

// `ProjectTypeGate` is declared in ProjectKit rather than here. The file is read
// in this module and enforced in that one (`TypeGateConditions`), and putting the
// type where the stage machine lives is what lets the gate be *checked* without
// the stage machine depending on the thing that reads files.

/// A practice the type's author thinks will not apply, with the reason already
/// written. **Not a decision** — see the note at the top of this file.
public struct TailoringSuggestion: Sendable, Equatable, Identifiable {
    public let practice: Practice
    public let reason: String
    public var id: String { practice.rawValue }
}

public struct ProjectTypeManifest: Sendable, Equatable, Identifiable {
    /// The full name from the file: `research.quantitative`.
    public let type: String
    /// The coarse kind it belongs to, which is what a `Project` stores.
    public let kind: ProjectKind
    public let label: String
    public let description: String
    public let roles: [Role]
    public let stages: [ProjectStage]
    /// Which starting work breakdown to lay down. `nil` means an empty plan,
    /// which is a legitimate answer for `blank`.
    public let wbsTemplate: String?
    public let gates: [ProjectTypeGate]
    public let suggestedTailoring: [TailoringSuggestion]
    /// What "done" means for a role in this kind of project (§7.2's
    /// `definition_of_done`, per role).
    public let definitionOfDone: [Role: String]
    public let source: URL?

    public var id: String { type }
}

public enum ProjectTypeError: Error, CustomStringConvertible, Equatable {
    case unknownRole(String, file: String)
    case unknownStage(String, file: String)
    case unknownPractice(String, file: String)
    case unknownKind(String, file: String)
    case malformedGate(String, file: String)
    case duplicateType(String, files: [String])

    public var description: String {
        switch self {
        case .unknownRole(let name, let file):
            "\(file): ไม่รู้จัก role '\(name)' — ที่มีคือ \(Role.allCases.map(\.rawValue).joined(separator: ", "))"
        case .unknownStage(let name, let file):
            "\(file): ไม่รู้จักขั้น '\(name)' — ที่มีคือ \(ProjectStage.allCases.map(\.rawValue).joined(separator: ", "))"
        case .unknownPractice(let name, let file):
            "\(file): ไม่รู้จัก practice '\(name)' — ที่มีคือ \(Practice.allCases.map(\.rawValue).joined(separator: ", "))"
        case .unknownKind(let name, let file):
            "\(file): type '\(name)' ไม่ตรงกับชนิดโปรเจกต์ที่มี "
                + "(\(ProjectKind.allCases.map(\.rawValue).joined(separator: ", "))) — "
                + "ชื่อ type ต้องขึ้นต้นด้วยชนิดใดชนิดหนึ่ง เช่น 'research.quantitative'"
        case .malformedGate(let line, let file):
            "\(file): บรรทัด gate อ่านไม่ออก: '\(line)' — รูปแบบคือ "
                + "'gate: <id> | after=<milestone> | requires=<a>, <b>'"
        case .duplicateType(let type, let files):
            "มี type '\(type)' ซ้ำกันในหลายไฟล์: \(files.joined(separator: ", "))"
        }
    }
}

extension ManifestParser {

    /// Reads one project-type file with the same frontmatter reader as everything
    /// else in this module.
    ///
    /// Every name is checked here rather than where it is used, which is this
    /// project's rule for configuration everywhere: a role that does not exist is
    /// a rejected file with the name in the message, not a project that quietly
    /// starts with four agents instead of five.
    public func parseProjectType(_ text: String, source: URL? = nil) throws -> ProjectTypeManifest {
        let file = source?.lastPathComponent ?? "(ข้อความ)"
        guard let (frontmatter, _) = Self.split(text) else {
            throw ManifestError.noFrontmatter(file: file)
        }
        let all = Self.allFields(in: frontmatter)
        let fields = all.compactMapValues(\.last)

        // The same rule as agents and skills: a file does not grade its own
        // danger, and a project type could otherwise arrive claiming its work is
        // low risk.
        if let field = Set(fields.keys).intersection(Self.forbiddenFields).sorted().first {
            throw ManifestError.riskIsNotDeclarable(field: field, file: file)
        }

        guard let type = fields["type"], !type.isEmpty else {
            throw ManifestError.missingField("type", file: file)
        }
        guard let description = fields["description"], !description.isEmpty else {
            throw ManifestError.missingField("description", file: file)
        }
        // `research.quantitative` belongs to `research`: the part before the dot
        // is what a `Project` stores, and the whole string is what the manifest
        // is keyed by. A type whose head is not a kind this build knows would be
        // a project nothing could open.
        let head = type.split(separator: ".").first.map(String.init) ?? type
        guard let kind = ProjectKind(rawValue: head) else {
            throw ProjectTypeError.unknownKind(type, file: file)
        }

        var roles: [Role] = []
        for name in Self.list(fields["roles"]) {
            guard let role = Role(rawValue: name) else {
                throw ProjectTypeError.unknownRole(name, file: file)
            }
            if !roles.contains(role) { roles.append(role) }
        }

        var stages: [ProjectStage] = []
        for name in Self.list(fields["stages"]) {
            guard let stage = ProjectStage(rawValue: name) else {
                throw ProjectTypeError.unknownStage(name, file: file)
            }
            if !stages.contains(stage) { stages.append(stage) }
        }

        let gates = try (all["gate"] ?? []).map { line -> ProjectTypeGate in
            try Self.gate(from: line, file: file)
        }

        var suggestions: [TailoringSuggestion] = []
        for line in all["suggest_tailoring_out"] ?? [] {
            let parts = line.split(separator: "|", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, !parts[1].isEmpty else {
                throw ProjectTypeError.malformedGate(line, file: file)
            }
            guard let practice = Practice(rawValue: parts[0]) else {
                throw ProjectTypeError.unknownPractice(parts[0], file: file)
            }
            suggestions.append(TailoringSuggestion(practice: practice, reason: parts[1]))
        }

        var definitionOfDone: [Role: String] = [:]
        for line in all["dod_override"] ?? [] {
            let parts = line.split(separator: "|", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, !parts[1].isEmpty else {
                throw ProjectTypeError.malformedGate(line, file: file)
            }
            guard let role = Role(rawValue: parts[0]) else {
                throw ProjectTypeError.unknownRole(parts[0], file: file)
            }
            definitionOfDone[role] = parts[1]
        }

        return ProjectTypeManifest(
            type: type,
            kind: kind,
            label: fields["label"] ?? type,
            description: description,
            roles: roles,
            stages: stages.isEmpty ? ProjectStage.allCases : stages,
            wbsTemplate: fields["wbs_template"],
            gates: gates,
            suggestedTailoring: suggestions,
            definitionOfDone: definitionOfDone,
            source: source)
    }

    /// Loads every project type in a directory, refusing duplicates.
    public func loadProjectTypes(directory: URL)
        -> (types: [ProjectTypeManifest], errors: [any Error]) {
        var types: [ProjectTypeManifest] = []
        var errors: [any Error] = []
        var seen: [String: [String]] = [:]

        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.pathExtension == "md" {
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let manifest = try parseProjectType(text, source: url)
                seen[manifest.type, default: []].append(url.lastPathComponent)
                types.append(manifest)
            } catch {
                errors.append(error)
            }
        }
        for (type, files) in seen where files.count > 1 {
            errors.append(ProjectTypeError.duplicateType(type, files: files.sorted()))
            types.removeAll { $0.type == type }
        }
        return (types, errors)
    }

    /// `<id> | after=<milestone> | requires=<a>, <b>`
    static func gate(from line: String, file: String) throws -> ProjectTypeGate {
        let parts = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let id = parts.first, !id.isEmpty else {
            throw ProjectTypeError.malformedGate(line, file: file)
        }
        var after = ""
        var requires: [String] = []
        for part in parts.dropFirst() {
            if part.hasPrefix("after=") {
                after = String(part.dropFirst("after=".count))
            } else if part.hasPrefix("requires=") {
                requires = list(String(part.dropFirst("requires=".count)))
            }
        }
        guard !after.isEmpty, !requires.isEmpty else {
            throw ProjectTypeError.malformedGate(line, file: file)
        }
        return ProjectTypeGate(id: id, after: after, requires: requires)
    }

    private static func list(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
