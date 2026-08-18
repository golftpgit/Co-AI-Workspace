import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// What a role already learned (ARCHITECTURE §21.2's last paragraph, P12.7).
//
// `LessonPublisher` writes a closed project's lessons into `central` as
// ordinary chunks, so the next project can find them by searching. That makes
// them *findable*. It does not make them *arrive*, and a lesson somebody has to
// think to search for is a lesson that reaches the people who already knew it.
//
// So an assignment starts with the lessons its role should begin knowing. The
// rules below matter more than the matching, because both ways of getting them
// wrong are quiet:
//
//  • **A lesson that names no role applies to everyone.** Most lessons are
//    written as prose by somebody closing a project, and "ใช้กับ:" gets filled
//    in with whatever was on their mind. Treating an unlabelled lesson as
//    relevant to nobody would file the majority of them where they teach
//    nobody — which is the exact failure `LessonPublisher` was written to
//    avoid, moved one step later.
//  • **A lesson that names a *different* role is excluded.** Without this,
//    every role starts every assignment reading everybody else's lessons, and
//    the ones that matter are somewhere in the middle of it.
//
// Newest first among equals: a lesson about a tool that no longer exists is
// noise, and recency is the only signal available for that without asking
// somebody to maintain an expiry date they will not maintain.
// ─────────────────────────────────────────────────────────────

public struct RoleLesson: Sendable, Equatable {
    public let id: String
    public let text: String
    /// Which project produced it — a lesson with no origin is advice.
    public let source: String
    public let learnedAt: Date
    /// Whether it named this role, as opposed to naming nobody. Kept because
    /// "written for you" and "might apply to you" are different things to put
    /// in front of somebody starting work.
    public let namesThisRole: Bool

    /// The line that goes into the assignment.
    public var briefLine: String {
        (namesThisRole ? localised("a lesson for this role", "Labels a lesson that names the role it is for.") : localised("a general lesson", "Labels a lesson that names no particular role."))
            + " — \(source): \(text)"
    }
}

public enum RoleMemory {

    /// Thai and English words that mean each role, as somebody closing a
    /// project would actually write them. Deliberately not the raw enum case:
    /// nobody types `teamLead` into a lessons-learned field.
    /// LOCALISATION: matching data — see RULES.md U24.
    static func vocabulary(for role: Role) -> [String] {
        switch role {
        case .teamLead: ["team lead", "หัวหน้าทีม", "หัวหน้า", "ผู้จัดการโครงการ", "lead"]
        case .researcher: ["researcher", "นักวิจัย", "ทบทวนวรรณกรรม", "review of literature"]
        case .analyst: ["analyst", "นักวิเคราะห์", "วิเคราะห์ข้อมูล", "สถิติ", "statistic"]
        case .engineer: ["engineer", "วิศวกร", "โปรแกรมเมอร์", "เขียนโค้ด", "developer"]
        case .writer: ["writer", "คนเขียน", "ผู้เขียน", "เขียนรายงาน", "เรียบเรียง"]
        case .reviewer: ["reviewer", "ผู้ตรวจ", "qa", "ตรวจสอบคุณภาพ"]
        }
    }

    /// Everything in `chunks` that is a published lesson.
    ///
    /// Identified by provenance rather than by text: `LessonPublisher` writes
    /// them with a `lessons/<project>` document id and system-authored
    /// provenance, and matching on the id is what keeps an ordinary uploaded
    /// document that happens to contain the word "บทเรียน" out of this.
    static func isLesson(_ chunk: IndexedChunk) -> Bool {
        guard case .userAuthored = chunk.provenance.origin else { return false }
        return chunk.provenance.documentID.hasPrefix("lessons/")
    }

    /// The line that says who a lesson is for, in the words somebody writes it.
    ///
    /// LOCALISATION: matching data — see RULES.md U24. Read *out of* the lesson,
    /// so it must hold every language a lesson may be written in at once. Put
    /// briefly through `t()` during the migration, which made the whole chunk
    /// the fallback whenever the interface was English — and then every mention
    /// of a role read as an address to it (2026-08-18).
    static let appliesMarkers = ["ใช้กับ:", "applies to:"]

    /// Which roles a lesson names, if any.
    static func rolesNamed(in text: String) -> Set<Role> {
        let lower = text.lowercased()
        // Only the "ใช้กับ:" line, when there is one. A lesson whose *cause*
        // mentions the analyst is not a lesson addressed to the analyst, and
        // reading the whole chunk turns every mention into an address.
        let applies = lower.components(separatedBy: .newlines)
            .first(where: { line in appliesMarkers.contains { line.contains($0) } }) ?? lower
        return Set(Role.allCases.filter { role in
            vocabulary(for: role).contains { applies.contains($0.lowercased()) }
        })
    }

    /// The lessons a role should start an assignment knowing.
    ///
    /// - Parameter limit: how many to carry into the brief. A brief that opens
    ///   with twenty lessons is a brief nobody reads past.
    public static func lessons(for role: Role, in chunks: [IndexedChunk],
                               limit: Int = 5) -> [RoleLesson] {
        let candidates = chunks.filter(isLesson).compactMap { chunk -> RoleLesson? in
            let named = rolesNamed(in: chunk.text)
            // Named somebody else and not this role: not this role's lesson.
            if !named.isEmpty, !named.contains(role) { return nil }
            return RoleLesson(id: chunk.id, text: chunk.text,
                              source: chunk.provenance.title,
                              learnedAt: chunk.provenance.accessedAt,
                              namesThisRole: named.contains(role))
        }
        return candidates
            // Addressed to this role first, then most recent.
            .sorted {
                $0.namesThisRole == $1.namesThisRole
                    ? $0.learnedAt > $1.learnedAt
                    : $0.namesThisRole
            }
            .prefix(limit)
            .map { $0 }
    }

    /// The lines to put in front of a role at the start of an assignment, and
    /// an honest note when there were more than fit.
    public static func brief(for role: Role, in chunks: [IndexedChunk],
                             limit: Int = 5) -> [String] {
        let all = lessons(for: role, in: chunks, limit: Int.max)
        guard !all.isEmpty else { return [] }
        var lines = all.prefix(limit).map(\.briefLine)
        if all.count > limit {
            // No silent truncation: a brief that shows five of twelve without
            // saying so reads as "there were five".
            lines.append(localised("(\(all.count - limit) more relevant lessons are in the central store — ", "Says how many lessons were left out. Placeholder: the number not shown.")
                         + localised("search for them with kb_search)", "Ends the note about lessons left out."))
        }
        return lines
    }
}
