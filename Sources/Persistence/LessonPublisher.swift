import Foundation
import AgentKit
import ProjectKit
import Knowledge

// ─────────────────────────────────────────────────────────────
// Lessons into the central knowledge base (ARCHITECTURE §19.11, §19.12).
//
// Written as ordinary chunks, in `central`, with system-authored provenance —
// so the next project finds them through the same hybrid search as everything
// else rather than through a special case. `Provenance.authored` is exactly
// right here: a lesson has no external credibility to claim, and what it does
// have is the project that produced it.
// ─────────────────────────────────────────────────────────────

public struct LessonPublisher: LessonPublishing {
    private let knowledge: KnowledgeStore

    public init(knowledge: KnowledgeStore) {
        self.knowledge = knowledge
    }

    public func publish(_ lessons: [RegisterEntry], from project: Project) async throws {
        let chunks = lessons.compactMap { entry -> IndexedChunk? in
            guard case .lesson(let cause, let doDifferently, let appliesTo) = entry.detail else {
                return nil
            }
            let text = """
            บทเรียนจากโปรเจกต์ “\(project.name)”: \(entry.title)
            สาเหตุ: \(cause)
            ครั้งหน้าจะทำต่างไป: \(doDifferently)
            ใช้กับ: \(appliesTo)
            """
            return IndexedChunk(
                id: entry.id,
                text: text,
                // Central, not the project's own scope — a lesson filed where
                // only the finished project can see it has taught nobody.
                scope: .central,
                provenance: .authored(documentID: "lessons/\(project.id.rawValue)",
                                      title: "บทเรียน — \(project.name)",
                                      runID: entry.id))
        }
        guard !chunks.isEmpty else { return }
        try await knowledge.save(chunks)
    }
}
