import Testing
import Foundation
import AgentKit
@testable import Observability

@Suite("Span recording")
struct SpanTests {
    @Test("a successful run records start and success")
    func recordsSuccess() async throws {
        let sink = InMemorySpanSink()
        let recorder = SpanRecorder(sink: sink)

        let value = try await recorder.run("kb_search", role: .researcher) { 42 }
        #expect(value == 42)

        let spans = await sink.spans
        #expect(spans.count == 2)
        #expect(spans.first?.status == .running)
        #expect(spans.last?.status == .succeeded)
        #expect(spans.last?.endedAt != nil)
        #expect(spans.last?.role == .researcher)
    }

    /// A span that never closes makes the monitor lie about what is running.
    @Test("a throwing body still closes its span")
    func recordsFailure() async {
        struct Boom: Error {}
        let sink = InMemorySpanSink()
        let recorder = SpanRecorder(sink: sink)

        await #expect(throws: Boom.self) {
            try await recorder.run("run_shell") { throw Boom() }
        }

        let spans = await sink.spans
        #expect(spans.last?.status == .failed)
        #expect(spans.last?.endedAt != nil)
        #expect(spans.last?.detail?.contains("Boom") == true)
    }

    @Test("cancellation is distinguished from failure")
    func recordsCancellation() async {
        let sink = InMemorySpanSink()
        let recorder = SpanRecorder(sink: sink)

        await #expect(throws: CancellationError.self) {
            try await recorder.run("long_task") { throw CancellationError() }
        }
        let spans = await sink.spans
        #expect(spans.last?.status == .cancelled)
    }

    @Test("parent links survive so nested work can be reassembled")
    func keepsParentLink() async throws {
        let sink = InMemorySpanSink()
        let recorder = SpanRecorder(sink: sink)
        let parent = SpanID()

        _ = try await recorder.run("child", parent: parent) { true }
        let spans = await sink.spans
        #expect(spans.allSatisfy { $0.parent == parent })
    }

    @Test("duration is measured")
    func measuresDuration() async throws {
        let sink = InMemorySpanSink()
        let recorder = SpanRecorder(sink: sink)

        _ = try await recorder.run("slow") { try? await Task.sleep(for: .milliseconds(50)) }
        let last = try #require(await sink.spans.last)
        let duration = try #require(last.duration)
        #expect(duration >= 0.04)
    }

    @Test("spans are Codable so the SurrealDB sink can persist them in P1.6")
    func codable() throws {
        let span = Span(name: "web_search", role: .researcher, scope: .central,
                        promptTokens: 10, completionTokens: 20)
        let data = try JSONEncoder().encode(span)
        let restored = try JSONDecoder().decode(Span.self, from: data)
        #expect(restored.name == span.name)
        #expect(restored.scope == .central)
        #expect(restored.completionTokens == 20)
    }
}
