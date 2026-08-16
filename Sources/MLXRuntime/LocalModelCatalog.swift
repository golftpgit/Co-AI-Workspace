import Foundation
import MLXLLM
import MLXVLM
import MLXLMCommon

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
    ///
    /// Asynchronous because the last question — "can this runtime build that
    /// architecture?" — is one only the library's own registry can answer, and
    /// the registry is an actor.
    public func installed() async -> [LocalModel] {
        var found: [LocalModel] = []
        var seen: Set<String> = []
        for root in searchPaths {
            for directory in await chatModelDirectories(under: root) {
                let path = directory.standardizedFileURL.path(percentEncoded: false)
                guard seen.insert(path).inserted else { continue }
                if let model = describe(directory, relativeTo: root) { found.append(model) }
            }
        }
        return found
    }

    /// A named model, matched on the full name or the directory's own name so
    /// both `mlx-community/Qwen3-8B-4bit` and `Qwen3-8B-4bit` resolve.
    public func model(named name: String) async -> LocalModel? {
        await installed().first { $0.name == name || $0.directory.lastPathComponent == name }
    }

    /// What the runtime should load when nobody has chosen: the largest model
    /// that fits in what is free right now (P5.3).
    ///
    /// Biggest-that-fits rather than simply biggest — within a size class the
    /// larger model is the better one, but a model over the line does not
    /// answer worse, it takes the machine down. When nothing fits, the
    /// *smallest* is returned rather than nothing: the tier then has a
    /// candidate to name, reports itself unavailable while memory is short,
    /// and starts working the moment it is not.
    public func preferred(memory: MachineMemory = .current()) async -> LocalModel? {
        let all = await installed()
        let fitting = all.filter { !AdmissionControl.admit($0, memory: memory).isBlocking }
        return fitting.max { $0.sizeOnDisk < $1.sizeOnDisk }
            ?? all.min { $0.sizeOnDisk < $1.sizeOnDisk }
    }

    // MARK: - what counts as a chat model

    /// A directory holding weights and a chat template, for an architecture
    /// this runtime can actually build.
    ///
    /// Both halves are there because both have bitten:
    ///
    ///  • The chat template keeps embedding models out. `bge-m3` sits in the
    ///    same cache with config.json, safetensors and a tokenizer; loaded as a
    ///    chat model it fails deep inside generation. An embedding model has no
    ///    chat template (see `MLXEmbedder`'s bridge, which throws for exactly
    ///    this reason).
    ///  • The type registry keeps unbuildable architectures out. LM Studio's
    ///    `Qwen3-VL-4B-Instruct` has every file a chat model has and fails at
    ///    load with `unsupportedModelType("qwen3_vl")` — offering it means the
    ///    router picks a tier that cannot answer, and on a machine where it is
    ///    the largest model, that is Tier 0.5 gone.
    func isChatModel(_ directory: URL) async -> Bool {
        guard hasChatModelFiles(directory) else { return false }
        return await Self.runtimeCanBuild(Self.modelType(in: directory))
    }

    /// The half that is only about files: weights, all of them, and a chat
    /// template.
    ///
    /// "All of them" is the part a cancelled download makes necessary. The
    /// small files arrive first, so an interrupted 17 GB model can sit there
    /// with its config, its template and one shard of six — and without the
    /// shard list it reads as installed, right up until it fails at load.
    func hasChatModelFiles(_ directory: URL) -> Bool {
        let files = Set((try? fileManager.contentsOfDirectory(
            atPath: directory.path(percentEncoded: false))) ?? [])
        guard files.contains("config.json"),
              files.contains(where: { $0.hasSuffix(".safetensors") }),
              chatTemplate(in: directory) != nil else { return false }
        // A single `model.safetensors` is the whole model, index or no index:
        // LM Studio's Qwen3-VL ships one merged file *and* the shard index it
        // was built from, and reading the index as a requirement rejected a
        // model that was perfectly complete.
        if files.contains("model.safetensors") { return true }
        return Self.shards(in: directory).isSubset(of: files)
    }

    /// The shards `model.safetensors.index.json` says this model is made of.
    /// Empty for a single-file model, which then has nothing to check.
    static func shards(in directory: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: directory.appending(path: "model.safetensors.index.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let map = object["weight_map"] as? [String: String] else { return [] }
        return Set(map.values)
    }

    /// The architecture name from config.json — what the factory dispatches on.
    static func modelType(in directory: URL) -> String? {
        guard let data = try? Data(contentsOf: directory.appending(path: "config.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["model_type"] as? String
    }

    /// Asked of the library rather than guessed from a list we would have to
    /// keep in step with it — of *both* registries, because a vision-language
    /// checkpoint is built by a different factory and is still a chat model
    /// (`qwen3_vl` lives in the VLM registry, and on a machine whose only local
    /// model is a VL one, refusing it means no Tier 0.5 at all).
    static func runtimeCanBuild(_ modelType: String?) async -> Bool {
        guard let modelType else { return false }
        if await LLMModelFactory.shared.typeRegistry.contains(modelType) { return true }
        return await VLMModelFactory.shared.typeRegistry.contains(modelType)
    }

    /// Which factory can build this architecture. Nil when neither can.
    static func factory(
        for modelType: String?
    ) async -> (any GenericModelFactory<ModelContext, ModelContainer>)? {
        guard let modelType else { return nil }
        if await LLMModelFactory.shared.typeRegistry.contains(modelType) {
            return LLMModelFactory.shared
        }
        if await VLMModelFactory.shared.typeRegistry.contains(modelType) {
            return VLMModelFactory.shared
        }
        return nil
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

    private func chatModelDirectories(under root: URL) async -> [URL] {
        guard fileManager.fileExists(atPath: root.path(percentEncoded: false)) else { return [] }
        var results: [URL] = []
        var frontier = [(url: root, depth: 0)]
        // The Hugging Face cache buries snapshots three levels down
        // (`models--org--name/snapshots/<sha>/`), LM Studio uses two
        // (`publisher/model/`); four is enough for both with room to spare.
        let maximumDepth = 4

        while let entry = frontier.popLast() {
            if hasChatModelFiles(entry.url) {
                // A directory of weights holds no other model, whether or not
                // this runtime can build it — so stop descending either way,
                // and only offer it if it can.
                if await Self.runtimeCanBuild(Self.modelType(in: entry.url)) {
                    results.append(entry.url)
                }
                continue
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

    /// How much key/value cache one token of context costs, from the model's
    /// own shape. Nil when config.json does not give enough to compute it.
    ///
    /// `2 × layers × kv-heads × head-dim × 2 bytes` — the 2s being key-and-value
    /// and fp16. On qwen3.5-9B (32 layers, 4 kv heads, head dim 256) that is
    /// ~128 KB per token, which is the difference between a model that fits in
    /// what is free and one that puts the machine on the swap line.
    static func kvCacheBytesPerToken(in directory: URL) -> Int64? {
        guard let data = try? Data(contentsOf: directory.appending(path: "config.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // A multimodal checkpoint keeps the language model's shape one level in.
        let config = (root["text_config"] as? [String: Any]) ?? root

        guard let layers = config["num_hidden_layers"] as? Int, layers > 0 else { return nil }
        let attentionHeads = config["num_attention_heads"] as? Int
        guard let kvHeads = (config["num_key_value_heads"] as? Int) ?? attentionHeads,
              kvHeads > 0 else { return nil }

        let headDimension: Int
        if let declared = config["head_dim"] as? Int, declared > 0 {
            headDimension = declared
        } else if let hidden = config["hidden_size"] as? Int,
                  let heads = attentionHeads, heads > 0 {
            headDimension = hidden / heads
        } else {
            return nil
        }
        return Int64(2 * layers * kvHeads * headDimension * 2)
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
            // Followed, not measured as links: a Hugging Face cache snapshot is
            // a directory of symlinks into `blobs/`, and reading the link
            // itself reports 76 bytes for a 335 MB model — which then loses
            // `preferred()` to any real file on disk.
            let resolved = file.resolvingSymlinksInPath()
            let size = (try? resolved.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + Int64(size)
        }
    }
}

// ─────────────────────────────────────────────────────────────
// Downloads that stopped halfway (§9.4, P5.2).
//
// `installed()` only lists models that are complete, which is right — a
// half-downloaded 17 GB checkpoint that reads as ready is a crash at load
// time, and P5.2 already fixed that. But the files are still on the disk. They
// count against the quota the screen shows and appear in no list, so the only
// way to get rid of them is a terminal, which is the thing this app exists not
// to need.
//
// Two rules, both about not deleting somebody's work:
//
//  • **A leftover is only a leftover if it is plainly a model download.** A
//    directory with `config.json` or a `.safetensors` in it, and no chat
//    template or missing shards. Anything else is a folder that happens to be
//    in the search path.
//  • **Only what this app downloaded may be deleted.** Leftovers inside LM
//    Studio's library or the Hugging Face cache are listed with their path and
//    no delete button: those are managed by another program, and a tidy-up
//    that reaches into them is a tidy-up that eventually removes something
//    somebody else was using.
// ─────────────────────────────────────────────────────────────

/// A directory that looks like a model download and cannot be loaded.
public struct IncompleteDownload: Sendable, Equatable, Identifiable {
    public let directory: URL
    public let bytes: Int64
    /// What it is short of, in words — "ไม่มี chat template", "ขาด 3 shard".
    public let missing: String
    /// Whether it is inside the directory this app downloads into. Only those
    /// are offered for deletion.
    public let isOurs: Bool

    public var id: String { directory.path(percentEncoded: false) }
}

extension LocalModelCatalog {

    /// Half-finished downloads under the search paths.
    ///
    /// - Parameter ownRoot: the directory this app downloads into. Leftovers
    ///   outside it are reported and not offered for deletion.
    public func incompleteDownloads(ownRoot: URL?) -> [IncompleteDownload] {
        var found: [IncompleteDownload] = []
        var seen: Set<String> = []

        for root in searchPaths {
            for directory in partialDirectories(under: root) {
                let path = directory.standardizedFileURL.path(percentEncoded: false)
                guard seen.insert(path).inserted else { continue }
                let ourRoot = ownRoot?.standardizedFileURL.path(percentEncoded: false)
                found.append(IncompleteDownload(
                    directory: directory,
                    bytes: Self.size(of: directory),
                    missing: missingParts(in: directory),
                    isOurs: ourRoot.map { path.hasPrefix($0) } ?? false))
            }
        }
        return found.sorted { $0.bytes > $1.bytes }
    }

    /// Removes one. Refuses anything this app did not download — the guard is
    /// here rather than only in the view, because a screen is not the place a
    /// deletion rule should live.
    public func remove(_ leftover: IncompleteDownload) throws {
        guard leftover.isOurs else {
            throw IncompleteDownloadError.notOurs(leftover.directory.lastPathComponent)
        }
        try FileManager.default.removeItem(at: leftover.directory)
    }

    /// Directories that hold model files and are not loadable models.
    private func partialDirectories(under root: URL) -> [URL] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path(percentEncoded: false)) else { return [] }
        var results: [URL] = []
        var frontier = [(url: root, depth: 0)]

        while let entry = frontier.popLast() {
            let files = Set((try? manager.contentsOfDirectory(atPath: entry.url.path(percentEncoded: false))) ?? [])
            let looksLikeAModel = files.contains("config.json")
                || files.contains { $0.hasSuffix(".safetensors") }
            if looksLikeAModel {
                // `hasChatModelFiles` is the same completeness check
                // `installed()` uses, so this list and that one can never both
                // contain the same directory.
                if !hasChatModelFiles(entry.url) { results.append(entry.url) }
                continue
            }
            guard entry.depth < 4 else { continue }
            let children = (try? manager.contentsOfDirectory(
                at: entry.url, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
            for child in children
            where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                frontier.append((child, entry.depth + 1))
            }
        }
        return results
    }

    func missingParts(in directory: URL) -> String {
        let files = Set((try? FileManager.default.contentsOfDirectory(
            atPath: directory.path(percentEncoded: false))) ?? [])
        if !files.contains("config.json") { return "ไม่มี config.json" }
        if chatTemplate(in: directory) == nil { return "ไม่มี chat template" }
        let missingShards = Self.shards(in: directory).subtracting(files)
        if !missingShards.isEmpty { return "ขาดไฟล์น้ำหนัก \(missingShards.count) ชิ้น" }
        if !files.contains(where: { $0.hasSuffix(".safetensors") }) { return "ไม่มีไฟล์น้ำหนักเลย" }
        return "ยังโหลดไม่ได้"
    }

    static func size(of directory: URL) -> Int64 {
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: directory,
                                              includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in walker {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

public enum IncompleteDownloadError: Error, CustomStringConvertible, Equatable {
    case notOurs(String)

    public var description: String {
        switch self {
        case .notOurs(let name):
            "'\(name)' อยู่ในคลังของโปรแกรมอื่น (เช่น LM Studio หรือ Hugging Face cache) — "
                + "แอปนี้ไม่ลบให้ เพราะของที่โปรแกรมอื่นดูแลอยู่ อาจมีอย่างอื่นใช้อยู่"
        }
    }
}
