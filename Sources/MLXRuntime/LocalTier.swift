import Foundation
import Synchronization
import AgentKit
import LLMProviders

// ─────────────────────────────────────────────────────────────
// Tier 0.5 as a slot rather than a fixed model (P5.2).
//
// The router is built once at boot, but the model behind this tier changes
// while the app runs: the user downloads their first one, or switches from the
// 4B to the 8B. Handing the router a concrete `MLXExecutor` would mean a
// restart after every such change — and the very first download, on a machine
// that had no model at all, is exactly when the user is watching to see
// whether it worked.
//
// So the router holds this, and this holds whichever model is selected. Its
// declared capabilities are the selected model's, because that is what the
// router plans with; with nothing selected it is simply unavailable, which the
// chain already knows how to walk past.
// ─────────────────────────────────────────────────────────────

public final class LocalTier: LLMExecutor {
    private struct Selection {
        let model: LocalModel
        let executor: MLXExecutor
    }

    private let selection = Mutex<Selection?>(nil)
    private let idleTimeout: Duration
    private let memory: @Sendable () -> MachineMemory

    public init(model: LocalModel? = nil, idleTimeout: Duration = .seconds(600),
                memory: @escaping @Sendable () -> MachineMemory = { .current() }) {
        self.idleTimeout = idleTimeout
        self.memory = memory
        if let model { select(model) }
    }

    /// Swaps the model. The one leaving is unloaded rather than left holding
    /// several gigabytes nobody is going to ask for again.
    public func select(_ model: LocalModel?) {
        let previous = selection.withLock { current -> MLXExecutor? in
            let leaving = current?.executor
            current = model.map {
                Selection(model: $0,
                          executor: MLXExecutor(model: $0, idleTimeout: idleTimeout,
                                                memory: memory))
            }
            return leaving
        }
        if let previous {
            Task { await previous.unload() }
        }
    }

    public var selected: LocalModel? {
        selection.withLock { $0?.model }
    }

    // MARK: - LLMExecutor

    public var identifier: String {
        selection.withLock { $0?.executor.identifier } ?? "mlx:ยังไม่ได้เลือกโมเดล"
    }

    public var tier: ModelTier { .localMLX }

    public var capabilities: LLMCapabilities {
        selection.withLock { $0?.executor.capabilities }
            // With no model there is nothing to describe. The window is the
            // catalogue's conservative default rather than zero, so the
            // declaration stays coherent for anything reading it before
            // `isAvailable()` rules this tier out.
            ?? LLMCapabilities(contextWindow: LocalModelCatalog.conservativeContextWindow,
                               supportsTools: false,
                               supportsStructuredOutput: true,
                               supportsStreaming: true,
                               supportsVision: false)
    }

    public func isAvailable() async -> Bool {
        guard let executor = selection.withLock({ $0?.executor }) else { return false }
        return await executor.isAvailable()
    }

    public func prewarm() async {
        guard let executor = selection.withLock({ $0?.executor }) else { return }
        await executor.prewarm()
    }

    public func respond(to request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        guard let executor = selection.withLock({ $0?.executor }) else {
            return AsyncThrowingStream {
                $0.finish(throwing: LLMError.unavailable("ยังไม่ได้เลือกโมเดลบนเครื่องสำหรับ Tier 0.5"))
            }
        }
        return executor.respond(to: request)
    }

    /// Whether the selected model's weights are in memory right now.
    ///
    /// The models screen shows this because it is the difference between a
    /// reply that starts in a second and one that starts in twenty — and
    /// because 4.5 GB held by a model nobody is talking to is 4.5 GB the rest
    /// of the machine wants back (§9.4).
    public var isResident: Bool {
        get async {
            guard let executor = selection.withLock({ $0?.executor }) else { return false }
            return await executor.isResident
        }
    }

    /// Frees the weights now — the model manager calls this before deleting
    /// the files a running executor still has open, and the eject button calls
    /// it because the user wants their memory back.
    public func unloadSelected() async {
        guard let executor = selection.withLock({ $0?.executor }) else { return }
        await executor.unload()
    }
}
