import Foundation

// ─────────────────────────────────────────────────────────────
// What is already on this machine (ARCHITECTURE §9.4, "ใช้โมเดลที่มีอยู่แล้ว").
//
// Tier 0.5 is the guaranteed floor (§9.2 rule 4), so the first question the
// runtime has to answer is "is there a model here at all?" — and it must
// answer it from the filesystem, in milliseconds, without downloading
// anything. `isAvailable()` is called on the router's hot path; a probe that
// could start a 6 GB download is not a probe.
//
// Downloading new models with progress and quota is P5.2; picking between them
// against free RAM is P5.3. This only finds what is already here.
// ─────────────────────────────────────────────────────────────

public struct LocalModel: Sendable, Equatable {
    /// Display name — the directory, or `org/name` for a Hugging Face cache
    /// entry. Also the executor's identifier, so spans and the UI say which
    /// model answered.
    public let name: String
    public let directory: URL
    /// From the model's own `config.json`, capped at what this machine can
    /// actually serve — see `LocalModelCatalog.servableContextWindow`.
    public let contextWindow: Int
    /// Declared context window before the cap, kept so the UI can explain the
    /// difference rather than looking like it misread the config.
    public let declaredContextWindow: Int
    public let sizeOnDisk: Int64
    /// Whether the model's chat template knows how to render tools. A template
    /// with no tool markup cannot produce a tool call however the request is
    /// phrased, so this is a capability, not a preference.
    public let supportsTools: Bool

    public init(name: String, directory: URL, contextWindow: Int,
                declaredContextWindow: Int, sizeOnDisk: Int64,
                supportsTools: Bool) {
        self.name = name
        self.directory = directory
        self.contextWindow = contextWindow
        self.declaredContextWindow = declaredContextWindow
        self.sizeOnDisk = sizeOnDisk
        self.supportsTools = supportsTools
    }
}

public struct LocalModelCatalog: Sendable {
    /// Where a model may already live. Order is preference order.
    public let searchPaths: [URL]

    public init(searchPaths: [URL]) {
        self.searchPaths = searchPaths
    }

    private var fileManager: FileManager { .default }

    /// The app's own model directory first, then everywhere a model may
    /// already be: what `HubApi` downloads into (`Documents/huggingface/models`
    /// — where `MLXEmbedder` puts bge-m3), the Hugging Face CLI cache, and LM
    /// Studio's library. Reusing those is the point — nobody should download
    /// the same 6 GB twice because two applications disagree about where
    /// models live.
    ///
    /// The last two are only reachable outside the sandbox: inside the app,
    /// `homeDirectoryForCurrentUser` is the container, so a model in
    /// `~/.lmstudio` is visible to `scripts/check.sh` and invisible to the
    /// running app. That is not a bug to route around here — reaching a
    /// user's own folder needs their consent through an open panel, which is
    /// P5.2's job. Keeping the paths in one list is what makes the difference
    /// findable when the app reports no model and the check reports two.
    public static func standard(appModelsDirectory: URL? = nil) -> LocalModelCatalog {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths: [URL] = []
        if let appModelsDirectory { paths.append(appModelsDirectory) }
        paths.append(home.appending(path: "Documents/huggingface/models"))
        paths.append(home.appending(path: ".cache/huggingface/hub"))
        paths.append(home.appending(path: ".lmstudio/models"))
        return LocalModelCatalog(searchPaths: paths)
    }

    /// Every chat model found, in search-path order.
    public func installed() -> [LocalModel] {
        var found: [LocalModel] = []
        var seen: Set<String> = []
        for root in searchPaths {
            for directory in chatModelDirectories(under: root) {
                let path = directory.standardizedFileURL.path(percentEncoded: false)
                guard seen.insert(path).inserted else { continue }
                if let model = describe(directory, relativeTo: root) { found.append(model) }
            }
        }
        return found
    }

    /// A named model, matched on the full name or the directory's own name so
    /// both `mlx-community/Qwen3-8B-4bit` and `Qwen3-8B-4bit` resolve.
    public func model(named name: String) -> LocalModel? {
        installed().first { $0.name == name || $0.directory.lastPathComponent == name }
    }

    /// What the runtime should load when nobody has chosen. Biggest wins:
    /// within a size class the larger model is the better one, and admission
    /// control against free RAM (P5.3) is what will stop this being naive.
    public func preferred() -> LocalModel? {
        installed().max { $0.sizeOnDisk < $1.sizeOnDisk }
    }

    // MARK: - what counts as a chat model

    /// A directory holding weights, a tokenizer *and* a chat template.
    ///
    /// The chat template is the discriminator that matters: `bge-m3` in the
    /// same cache has config.json, safetensors and a tokenizer too, and
    /// loading an embedding model as a chat model fails deep inside generation
    /// with an error about layer names. An embedding model has no chat
    /// template, so this check keeps it out (see `MLXEmbedder`'s bridge, which
    /// throws for exactly this reason).
    func isChatModel(_ directory: URL) -> Bool {
        let files = (try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false)))
            ?? []
        guard files.contains("config.json"),
              files.contains(where: { $0.hasSuffix(".safetensors") }) else { return false }
        return chatTemplate(in: directory) != nil
    }

    /// The template's text, wherever this export keeps it.
    func chatTemplate(in directory: URL) -> String? {
        if let jinja = try? String(contentsOf: directory.appending(path: "chat_template.jinja"),
                                   encoding: .utf8) {
            return jinja
        }
        // Older exports keep the template inside tokenizer_config.json.
        guard let data = try? Data(contentsOf: directory.appending(path: "tokenizer_config.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let template = object["chat_template"] as? String { return template }
        // Some exports carry several named templates.
        if let templates = object["chat_template"] as? [[String: Any]] {
            return templates.compactMap { $0["template"] as? String }.first
        }
        return nil
    }

    private func chatModelDirectories(under root: URL) -> [URL] {
        guard fileManager.fileExists(atPath: root.path(percentEncoded: false)) else { return [] }
        var results: [URL] = []
        var frontier = [(url: root, depth: 0)]
        // The Hugging Face cache buries snapshots three levels down
        // (`models--org--name/snapshots/<sha>/`), LM Studio uses two
        // (`publisher/model/`); four is enough for both with room to spare.
        let maximumDepth = 4

        while let entry = frontier.popLast() {
            if isChatModel(entry.url) {
                results.append(entry.url)
                continue      // weights do not contain other models
            }
            guard entry.depth < maximumDepth else { continue }
            let children = (try? fileManager.contentsOfDirectory(
                at: entry.url, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
            for child in children {
                // `blobs` holds the same weights again as content-addressed
                // files with no config.json beside them; walking it doubles the
                // scan for nothing.
                guard child.lastPathComponent != "blobs",
                      (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                else { continue }
                frontier.append((child, entry.depth + 1))
            }
        }
        return results.sorted { $0.path < $1.path }
    }

    // MARK: - reading the model's own configuration

    private func describe(_ directory: URL, relativeTo root: URL) -> LocalModel? {
        let declared = Self.declaredContextWindow(in: directory) ?? Self.conservativeContextWindow
        return LocalModel(
            name: Self.name(of: directory, relativeTo: root),
            directory: directory,
            contextWindow: Self.servableContextWindow(declared: declared),
            declaredContextWindow: declared,
            sizeOnDisk: weightBytes(in: directory),
            supportsTools: Self.templateRendersTools(chatTemplate(in: directory)))
    }

    /// A chat template that never mentions tool calls cannot produce one. The
    /// marker is the rendered *output* markup (`tool_call`) rather than the
    /// `tools` variable alone: several templates accept a tools argument and
    /// silently ignore it.
    static func templateRendersTools(_ template: String?) -> Bool {
        guard let template else { return false }
        return template.contains("tool_call")
    }

    /// `models--mlx-community--Qwen3-8B-4bit/snapshots/<sha>` reads back as
    /// `mlx-community/Qwen3-8B-4bit`; anything else keeps its path under the
    /// search root, which is what the user sees in Finder.
    static func name(of directory: URL, relativeTo root: URL) -> String {
        var components = directory.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        if components.count > rootComponents.count,
           Array(components.prefix(rootComponents.count)) == rootComponents {
            components = Array(components.dropFirst(rootComponents.count))
        }
        if let cacheEntry = components.first(where: { $0.hasPrefix("models--") }) {
            return cacheEntry.dropFirst("models--".count)
                .replacingOccurrences(of: "--", with: "/")
        }
        return components.suffix(2).joined(separator: "/")
    }

    /// `max_position_embeddings`, top level or inside `text_config` — a
    /// multimodal checkpoint puts the language model's settings there.
    static func declaredContextWindow(in directory: URL) -> Int? {
        guard let data = try? Data(contentsOf: directory.appending(path: "config.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let value = object["max_position_embeddings"] as? Int { return value }
        if let text = object["text_config"] as? [String: Any],
           let value = text["max_position_embeddings"] as? Int { return value }
        return nil
    }

    /// Used when config.json does not say. Small on purpose: the router
    /// filters candidates on the declared window, so guessing low means work
    /// goes elsewhere, and guessing high means it arrives here and fails.
    static let conservativeContextWindow = 4_096

    /// What the machine can serve, not what the checkpoint advertises.
    ///
    /// The Qwen3.5 config on this machine declares 262,144 tokens. Measured on
    /// 16 GB (the note in `Engine.swift`), a 7.6k-token prompt to a 9B model
    /// already cost ~7.4 GB of unified memory — a prompt anywhere near the
    /// declared window would take the machine down, and the router would send
    /// one here precisely because the number looked generous. P5.3 replaces
    /// this constant with a measurement against free RAM.
    static let servableContextWindowCap = 32_768

    static func servableContextWindow(declared: Int) -> Int {
        min(declared, servableContextWindowCap)
    }

    private func weightBytes(in directory: URL) -> Int64 {
        let files = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(Int64(0)) { total, file in
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + Int64(size)
        }
    }
}
