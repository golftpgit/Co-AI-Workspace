import Foundation
import MLXLMCommon
import Hub
import Tokenizers

// ─────────────────────────────────────────────────────────────
// The two protocols mlx-swift-lm leaves to the host, in their chat form.
//
// `EmbeddingRuntime` implements the same pair for embeddings and deliberately
// throws from `applyChatTemplate` — an embedding model has no chat template.
// Here the chat template is the whole point: it is what turns our message list
// into the exact prompt the model was trained on, including the tool-calling
// markup, and it is also what tells us whether the model will start its answer
// already inside a `<think>` block.
// ─────────────────────────────────────────────────────────────

struct ChatHubDownloader: MLXLMCommon.Downloader {
    private let hub = HubApi()

    func download(id: String, revision: String?, matching patterns: [String],
                  useLatest: Bool,
                  progressHandler: @Sendable @escaping (Progress) -> Void) async throws -> URL {
        try await hub.snapshot(from: id, revision: revision ?? "main",
                               matching: patterns, progressHandler: progressHandler)
    }
}

struct ChatTokenizer: MLXLMCommon.Tokenizer {
    let inner: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        inner.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        inner.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { inner.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { inner.convertIdToToken(id) }

    var bosToken: String? { inner.bosToken }
    var eosToken: String? { inner.eosToken }
    var unknownToken: String? { inner.unknownToken }

    func applyChatTemplate(messages: [[String: any Sendable]],
                           tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        try inner.applyChatTemplate(messages: messages, tools: tools,
                                    additionalContext: additionalContext)
    }
}

struct ChatTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        ChatTokenizer(inner: try await AutoTokenizer.from(modelFolder: directory))
    }
}

// MARK: - what the template does before the model says anything

enum ChatTemplate {
    /// Whether this model's template hands the model a `<think>` block that is
    /// already open.
    ///
    /// Qwen-style templates end the generation prompt with `<think>\n`, so the
    /// model's first token is the first token of its reasoning and there is no
    /// opening tag anywhere in the output — only a `</think>` some hundreds of
    /// tokens later. A splitter that waits for `<think>` therefore reports the
    /// entire chain of thought as the answer, which is the same corruption
    /// E.9 case 8c describes on the hosted side, arriving by a different route.
    ///
    /// Asking the template is deterministic and costs one render. Guessing from
    /// the output is not: by the time `</think>` proves the model was thinking,
    /// the thinking has already been streamed to the caller as the answer.
    static func opensReasoningBlock(_ tokenizer: any MLXLMCommon.Tokenizer,
                                    additionalContext: [String: any Sendable]? = nil) -> Bool {
        let probe: [[String: any Sendable]] = [["role": "user", "content": "hi"]]
        guard let tokens = try? tokenizer.applyChatTemplate(
            messages: probe, tools: nil, additionalContext: additionalContext) else { return false }
        let rendered = tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false)
        guard let opened = rendered.range(of: ReasoningSplitter.openTag, options: .backwards)
        else { return false }
        guard let closed = rendered.range(of: ReasoningSplitter.closeTag, options: .backwards)
        else { return true }
        return opened.lowerBound > closed.lowerBound
    }
}
