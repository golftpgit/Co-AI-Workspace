import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// What moves to the central library when a project closes
// (ARCHITECTURE §19.1.1, §19.12 · P21.4).
//
// Closing a project is not a label — it is the moment its knowledge either
// becomes available to the next project or is lost with it. §19.1.1 says which
// is which, and the line is not about storage. It is about what the next
// project has any right to see:
//
//     moves up                          stays
//     ────────────────────────────────  ─────────────────────────────────────
//     lessons already written           **participants, and anything that
//     conflict decisions declared         could identify one (M16)**
//       central precedent               decisions scoped to this project
//     external references, with tier    working drafts, rejected hypotheses
//
// **The participant rule is ethical, not technical.** People answered a
// questionnaire for one study, under one consent form, from one committee's
// approval. A transcript that follows the project into a shared library has
// been re-purposed without anybody asking them, and the fact that it is
// convenient to search is exactly what makes it worth refusing. `Origin` marks
// fieldwork as itself, so this is decidable here rather than by remembering.
//
// This file is the *rule*; the moving is in Persistence, where the stores are.
// The split is deliberate — the rule is worth reading on its own, and it is
// the half that has to be testable without a database.
// ─────────────────────────────────────────────────────────────

public enum HandoverVerdict: Sendable, Equatable {
    /// Copied into `central`, where the next project will find it.
    case movesUp(reason: String)
    /// Stays with the archived project. Readable there for anybody who opens
    /// it; simply not published to everybody.
    case stays(reason: String)

    public var isMovingUp: Bool { if case .movesUp = self { return true }; return false }
}

public enum ClosingHandoverPolicy {

    /// Whether one chunk of a closing project's knowledge belongs in the
    /// central library.
    ///
    /// Written as one function over `Origin` with no default arm, so a new kind
    /// of source cannot be added without somebody deciding this question about
    /// it. That is the same reason `Origin` has no `other` case.
    public static func verdict(for chunk: IndexedChunk) -> HandoverVerdict {
        switch chunk.provenance.origin {
        case .fieldwork:
            // §20.7 and M16. Not "because it is unstructured" and not "because
            // it is large" — because the people in it agreed to one study.
            return .stays(reason: localised("participant data — the people in it consented to this study, and only this one", "Why fieldwork data does not move to the central knowledge base."))

        case .database:
            // A pulled table may be anything, including a patient extract, and
            // the system cannot tell from here. Refusing is the answer that is
            // wrong in the recoverable direction.
            return .stays(reason: localised("a table pulled from a database — the system cannot tell whether it holds personal data", "Why a pulled table does not move to the central knowledge base."))

        case .userAuthored:
            // §19.1.1's "working drafts, rejected hypotheses". A lesson is
            // authored too, and lessons reach central by their own path
            // (`LessonPublishing`) precisely because *being a lesson* is a
            // decision somebody made, not a property of the text.
            return .stays(reason: localised("the project's drafts and working notes — lessons go up by their own path", "Why authored material does not move to the central knowledge base."))

        case .upload, .web:
            // An external reference: a paper, a guideline, a page. It was
            // already published to the world, and its tier goes with it — a
            // document that arrives centrally without the credibility it was
            // ranked by would be re-ranked as if nobody had ever assessed it.
            guard chunk.provenance.tier != nil else {
                return .stays(reason: localised("an outside document with no tier — sent up it would be re-ranked as if nobody had ever assessed it", "Why an untiered outside document does not move to the central knowledge base."))
            }
            return .movesUp(reason: localised("an outside reference, with the tier it already had", "Why a tiered outside document moves to the central knowledge base."))
        }
    }

    /// The chunks that move, rewritten into `central`.
    ///
    /// Identity is deliberately *not* preserved: a chunk keeps its id and gains
    /// a scope, so re-closing a project — or closing two projects that cite the
    /// same paper — writes the same row twice rather than two rows. The store
    /// upserts by id, which is what makes this idempotent instead of a slow
    /// duplication of the library.
    public static func promoted(_ chunks: [IndexedChunk]) -> [IndexedChunk] {
        chunks.filter { verdict(for: $0).isMovingUp }
            .map { chunk in
                IndexedChunk(id: chunk.id,
                             text: chunk.text,
                             scope: .central,
                             provenance: chunk.provenance,
                             embedding: chunk.embedding,
                             embeddingProfileID: chunk.embeddingProfileID,
                             entities: chunk.entities)
            }
    }

    /// Whether a decided conflict is a precedent for everybody or a call this
    /// project made for itself (§11.6).
    ///
    /// The user chose when they decided it, and closing the project does not
    /// get to revisit that: a decision taken "for this study, given how we
    /// defined the outcome" is not a rule for the next study, and promoting it
    /// silently would put words in somebody's mouth.
    public static func isCentralPrecedent(_ decision: ConflictDecision) -> Bool {
        decision.scope == .central && decision.decidedByHuman
    }
}
