import Foundation
import AgentKit
import Observability

// ─────────────────────────────────────────────────────────────
// M3 Roster — capabilities that come from files (ARCHITECTURE §7, P8.1/P8.2).
//
// One parser for agents and skills, because §7.2 chose one format for both:
// flat frontmatter, the same shape as `SKILL.md`. Two parsers would drift, and
// the first thing to drift would be `tools:` — the field that decides what a
// capability is allowed to touch.
//
// Two rules this module exists to enforce:
//
//  • **A tool name that does not exist is a rejected manifest**, at load time,
//    with the unknown name in the message. Not a warning, and not a silently
//    smaller tool list: an agent that quietly loses `run_shell` because of a
//    typo will look like a model that has stopped following instructions.
//    This is Config's philosophy applied to the roster — reject an invalid
//    value where it is written, not where it is used.
//  • **Risk is computed, never declared** (P8.2). A manifest says which tools
//    it wants; how dangerous that is follows from the tools themselves. A
//    `risk:` field a manifest could set would be a field that could be set to
//    `low`, and the whole gate (§5.3) rests on that not being possible.
// ─────────────────────────────────────────────────────────────

public enum ManifestKind: String, Sendable, Codable, CaseIterable {
    case agent
    case skill
}

public struct Manifest: Sendable, Equatable, Identifiable {
    public let kind: ManifestKind
    public let name: String
    public let description: String
    /// Resolved: `base:` has already been folded in, and every name here is a
    /// tool the system actually has.
    public let tools: [String]
    /// The role a manifest inherits its tool set from (§7.2).
    public let base: Role?
    /// §7.2's v2 field, fed to the QA agent (§2.5).
    public let definitionOfDone: String?
    /// §21.2's `knowledge_view:`, kept as the JSON it was written as.
    ///
    /// Text rather than a decoded `KnowledgeView`, for the reason P8.4 settled
    /// about packages: this module *describes*, and the thing described is
    /// turned into a capability where the capability lives. Roster depending on
    /// `Knowledge` would put `KnowledgeIndex` inside its reach, and the module
    /// graph is how this project enforces what a module cannot do (B2's fix).
    public let knowledgeViewJSON: String?
    /// Which tier the author wants. A preference, not a guarantee — the router
    /// still decides (§9.2).
    public let modelTier: Int?
    /// Everything after the frontmatter: the persona, or the skill's steps.
    public let body: String
    /// Where it was read from, so an error can name the file.
    public let source: URL?

    public var id: String { "\(kind.rawValue):\(name)" }

    public init(kind: ManifestKind, name: String, description: String,
                tools: [String] = [], base: Role? = nil, definitionOfDone: String? = nil,
                knowledgeViewJSON: String? = nil,
                modelTier: Int? = nil, body: String = "", source: URL? = nil) {
        self.kind = kind
        self.name = name
        self.description = description
        self.tools = tools
        self.base = base
        self.definitionOfDone = definitionOfDone
        self.knowledgeViewJSON = knowledgeViewJSON
        self.modelTier = modelTier
        self.body = body
        self.source = source
    }
}

public enum ManifestError: Error, CustomStringConvertible, Equatable {
    case noFrontmatter(file: String)
    case missingField(String, file: String)
    case unknownTools([String], file: String, known: [String])
    case unknownBase(String, file: String)
    case duplicateName(String, files: [String])
    /// P8.2 — the manifest tried to say how dangerous it is.
    case riskIsNotDeclarable(field: String, file: String)

    public var description: String {
        switch self {
        case .noFrontmatter(let file):
            "\(file): ไม่มีส่วนหัว frontmatter (--- … ---) ที่บรรทัดแรก"
        case .missingField(let field, let file):
            "\(file): ขาดฟิลด์ที่จำเป็น '\(field)'"
        case .unknownTools(let names, let file, let known):
            "\(file): ไม่รู้จักทูล \(names.joined(separator: ", ")) — "
                + "ทูลที่มีอยู่จริงคือ \(known.sorted().joined(separator: ", "))"
        case .unknownBase(let base, let file):
            "\(file): base '\(base)' ไม่ใช่ role ที่มีอยู่ (\(Role.allCases.map(\.rawValue).joined(separator: ", ")))"
        case .duplicateName(let name, let files):
            "มีชื่อ '\(name)' ซ้ำกันในหลายไฟล์: \(files.joined(separator: ", "))"
        case .riskIsNotDeclarable(let field, let file):
            "\(file): ฟิลด์ '\(field)' ตั้งเองไม่ได้ — ระดับความเสี่ยงคำนวณจากรายการทูลที่ขอใช้ "
                + "ไม่ใช่จากสิ่งที่ไฟล์ประกาศเกี่ยวกับตัวเอง (§5.3, P8.2)"
        }
    }
}

/// What a role is allowed to use, so `base:` means something. Mirrors the
/// specialists in CoreEngine, which this module cannot import — and the mirror
/// is checked by a test there rather than trusted here.
public enum RoleTools {
    public static func tools(for role: Role) -> [String] {
        switch role {
        // `raise_risk` on every working role (§19.11, P10.8): whoever notices
        // is whoever files it. A register only one role can write to is a
        // register that fills up after the fact.
        case .researcher: ["kb_search", "web_search", "fetch_page", "ingest_url", "raise_risk"]
        case .analyst: ["kb_search", "run_shell", "run_stat_test",
                        "analysis_query", "analysis_execute", "pull_db_table", "raise_risk"]
        case .engineer: ["run_shell", "kb_search", "raise_risk"]
        case .writer: ["kb_search", "save_document", "raise_risk"]
        case .reviewer, .teamLead: []
        }
    }
}

/// A loaded manifest together with what it is allowed to do — the part a
/// manifest does not get a say in (P8.2).
public struct RosterEntry: Sendable, Equatable, Identifiable {
    public let manifest: Manifest
    /// The highest risk carried by any tool this capability may use.
    /// **Computed from the tool list, never read from the file.**
    public let riskCeiling: RiskLevel

    public var id: String { manifest.id }

    /// Whether a turn using this capability can reach the approval gate at all.
    /// A capability whose tools are all read-only never will; one that can run
    /// a shell always can, whatever its file says about itself.
    public var isRiskSensitive: Bool { riskCeiling > .low }

    public init(manifest: Manifest, riskCeiling: RiskLevel) {
        self.manifest = manifest
        self.riskCeiling = riskCeiling
    }
}

public struct ManifestParser: Sendable {
    /// The tools the system actually has, as `ToolGateway` advertises them.
    /// Passed in rather than looked up: this module does not get to reach into
    /// the gateway, and a parser that knows the tool list by heart is a parser
    /// that is wrong the day a tool is added.
    public let knownTools: Set<String>
    /// Each tool's declared risk, from the same adverts. Used to compute a
    /// manifest's ceiling; a tool that is not listed counts as High, the same
    /// rule the hook chain uses for a tool it does not recognise (§5.3).
    public let toolRisks: [String: RiskLevel]

    /// Frontmatter keys that would amount to a capability grading its own
    /// danger. Rejected rather than ignored: a file that sets `risk: low` and
    /// loads without complaint has told its author something false.
    static let forbiddenFields: Set<String> = [
        "risk", "risk_level", "risklevel", "approval", "requires_approval",
        "autonomy", "bypass_gate", "skip_approval", "trusted",
    ]

    public init(knownTools: Set<String>, toolRisks: [String: RiskLevel] = [:]) {
        self.knownTools = knownTools
        self.toolRisks = toolRisks
    }

    /// The ceiling for a resolved tool list. Unknown tools score High — the
    /// same default §5.3 applies, and for the same reason.
    public func riskCeiling(for tools: [String]) -> RiskLevel {
        tools.reduce(RiskLevel.low) { highest, tool in
            max(highest, toolRisks[tool] ?? .high)
        }
    }

    public func entry(for manifest: Manifest) -> RosterEntry {
        RosterEntry(manifest: manifest, riskCeiling: riskCeiling(for: manifest.tools))
    }

    public func parse(_ text: String, kind: ManifestKind, source: URL? = nil) throws -> Manifest {
        let file = source?.lastPathComponent ?? "(ข้อความ)"
        guard let (frontmatter, body) = Self.split(text) else {
            throw ManifestError.noFrontmatter(file: file)
        }
        let fields = Self.fields(in: frontmatter)

        // P8.2: a capability does not get to grade its own danger.
        let declared = Set(fields.keys).intersection(Self.forbiddenFields)
        if let field = declared.sorted().first {
            throw ManifestError.riskIsNotDeclarable(field: field, file: file)
        }

        guard let name = fields["name"], !name.isEmpty else {
            throw ManifestError.missingField("name", file: file)
        }
        guard let description = fields["description"], !description.isEmpty else {
            // A description is what the router and the UI pick from; without
            // one a capability is invisible even when it loads.
            throw ManifestError.missingField("description", file: file)
        }

        var base: Role?
        if let raw = fields["base"], !raw.isEmpty {
            guard let role = Role(rawValue: raw) else {
                throw ManifestError.unknownBase(raw, file: file)
            }
            base = role
        }

        // `base:` first, then the manifest's own list on top — §7.2 calls this
        // inheritance, and a manifest that names a tool its base already has
        // should not end up with it twice.
        var tools = base.map { RoleTools.tools(for: $0) } ?? []
        for tool in Self.list(fields["tools"]) where !tools.contains(tool) {
            tools.append(tool)
        }

        let unknown = tools.filter { !knownTools.contains($0) }
        guard unknown.isEmpty else {
            throw ManifestError.unknownTools(unknown, file: file, known: Array(knownTools))
        }

        return Manifest(kind: kind,
                        name: name,
                        description: description,
                        tools: tools,
                        base: base,
                        definitionOfDone: fields["definition_of_done"],
                        knowledgeViewJSON: fields["knowledge_view"],
                        modelTier: fields["model_tier"].flatMap(Int.init),
                        body: body,
                        source: source)
    }

    /// Loads every `.md` in a directory. One bad file is an error about that
    /// file; the others still load, because a roster that disappears entirely
    /// because of one typo is a roster nobody will keep files in.
    public func load(directory: URL, kind: ManifestKind)
        -> (manifests: [Manifest], errors: [ManifestError]) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        var manifests: [Manifest] = []
        var errors: [ManifestError] = []
        var seen: [String: [String]] = [:]

        for file in files.filter({ $0.pathExtension == "md" }).sorted(by: { $0.path < $1.path }) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            do {
                let manifest = try parse(text, kind: kind, source: file)
                seen[manifest.name, default: []].append(file.lastPathComponent)
                manifests.append(manifest)
            } catch let error as ManifestError {
                errors.append(error)
            } catch {
                continue
            }
        }

        // Two files claiming the same name is ambiguous rather than harmless:
        // whichever wins depends on directory order, which is not a decision
        // anybody made.
        for (name, files) in seen where files.count > 1 {
            errors.append(.duplicateName(name, files: files))
            manifests.removeAll { $0.name == name }
        }
        return (manifests, errors)
    }

    // MARK: - writing one

    /// §7.2's format, produced rather than parsed (P8.5).
    ///
    /// It is here, next to the parser, for the reason the parser is shared
    /// between agents and skills: two places that know the format would drift,
    /// and the first thing to drift would be `tools:`. A writer in the tool
    /// layer would be that second place.
    ///
    /// Note what this cannot emit. There is no parameter for `risk` or
    /// `bypass_gate` — they are not fields a manifest may have (P8.2), so a
    /// skill an agent writes cannot contain one even by accident.
    public static func text(name: String,
                            description: String,
                            tools: [String] = [],
                            base: Role? = nil,
                            definitionOfDone: String? = nil,
                            modelTier: Int? = nil,
                            body: String) -> String {
        var lines = ["---", "name: \(name)", "description: \(description)"]
        if !tools.isEmpty { lines.append("tools: \(tools.joined(separator: ", "))") }
        if let base { lines.append("base: \(base.rawValue)") }
        if let modelTier { lines.append("model_tier: \(modelTier)") }
        if let definitionOfDone, !definitionOfDone.isEmpty {
            lines.append("definition_of_done: \(definitionOfDone)")
        }
        lines.append("---")
        lines.append("")
        lines.append(body.trimmingCharacters(in: .whitespacesAndNewlines))
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// A filename that is the skill's name and nothing else.
    ///
    /// Refused rather than repaired. Sanitising `../evil` into `---evil` is
    /// safe — it does not escape anywhere — but it saves a file under a name
    /// nobody asked for, and a writer that quietly renames things is a writer
    /// whose output cannot be predicted from its input. A name that cannot be
    /// a filename is a name to reject while there is still somebody to tell.
    public static func fileName(for name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Anything that would make this more than one path component, or that
        // names a directory rather than a file.
        guard !trimmed.contains("/"), !trimmed.contains("\\"), !trimmed.contains(":"),
              !trimmed.contains(where: \.isNewline),
              trimmed.contains(where: { $0 != "." }) else { return nil }
        return trimmed + ".md"
    }

    // MARK: - the format

    /// Splits `---\n…\n---\n` off the front. Returns nil when the first line is
    /// not a fence, which is the one thing §7.2's format requires.
    static func split(_ text: String) -> (frontmatter: String, body: String)? {
        let lines = text.components(separatedBy: .newlines)
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return nil
        }
        guard let end = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else { return nil }

        let frontmatter = lines[1..<end].joined(separator: "\n")
        let body = lines[(end + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (frontmatter, body)
    }

    /// `key: value` per line, keeping **every** value for a repeated key.
    ///
    /// Flat on purpose (§7.2) — nested YAML would mean carrying a YAML parser
    /// for a format that has never needed one. Repeating a key is how this
    /// format says "a list of things that each have parts", which is what
    /// project types need for their gates (§20.2) and what a second parser would
    /// otherwise have been written for.
    static func allFields(in frontmatter: String) -> [String: [String]] {
        var fields: [String: [String]] = [:]
        for line in frontmatter.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            var value = parts[1].trimmingCharacters(in: .whitespaces)
            // Quotes are optional in this format; a value that has them should
            // not keep them.
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            fields[key, default: []].append(value)
        }
        return fields
    }

    /// The last value for each key — what agent and skill manifests have always
    /// read, expressed as a view over the same reader rather than a second one.
    static func fields(in frontmatter: String) -> [String: String] {
        allFields(in: frontmatter).compactMapValues(\.last)
    }

    static func list(_ value: String?) -> [String] {
        (value ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
