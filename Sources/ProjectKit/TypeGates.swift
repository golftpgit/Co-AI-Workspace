import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// The gates a project type declares, made real (ARCHITECTURE §19.4 · §20.2).
//
// P11.1 landed the declaration: a project-type file can say
//
//     gate: G-instrument | after=instrument.draft | requires=content_validity_passed, …
//
// and the loader kept it as data. Data is where `Scope.project` sat for nine
// phases — a field that describes an intention nothing acts on — so this is the
// half that makes the line mean something.
//
// **Where it is enforced, and why not earlier.** These gates stand at milestones
// inside a stage, not at stage boundaries, and inventing a milestone machine to
// hold them would be building a second stage machine beside the one §19.4
// already has. The strongest honest place is the boundary out of execution: a
// project may not be wrapped up while a promise its own type made is unmet. For
// the research types this is a backstop rather than the first line — the real
// enforcement for `content_validity_passed` is that `InstrumentGate.approve` is
// the only producer of the value M16 will serve (§20.6), which stops fieldwork
// before it starts. A backstop that fires late is still worth having: it is what
// makes "this project type requires X" a sentence with a consequence.
//
// **What happens to a condition nobody can answer.** Three cases, and the
// difference between them is the whole design:
//
//  • **Answerable** — this build knows how to check it. It blocks when false.
//    That is the enforcement the task was about.
//  • **A named gap** — a condition a shipped type file asks for that no build
//    can answer yet, listed below with the phase that will close it. It does
//    *not* block, because blocking would make four of the six shipped project
//    types impossible to move out of execution, which is a bug dressed as
//    rigour. It is marked `vacuous` instead: §19.4 added that flag precisely so
//    that "nothing was checked" cannot render as a green tick.
//  • **Neither** — a name no table knows. It **blocks**. A file that could
//    invent a condition which quietly does nothing is a file whose gate line is
//    decorative again, which is the thing this change exists to end. In practice
//    it means a typo in a type file stops that type's projects and says which
//    word it did not recognise.
// ─────────────────────────────────────────────────────────────

/// A gate a project of this type has on top of the standard stage gates.
///
/// Declared in the type file, parsed by M3's one manifest parser, and enforced
/// here — the type lives in this module rather than in the loader so that the
/// stage machine can see it without depending on the thing that reads files.
public struct ProjectTypeGate: Sendable, Equatable, Identifiable {
    public let id: String
    /// The milestone it stands after — a name from the type's own vocabulary,
    /// e.g. `instrument.draft`.
    public let after: String
    /// What has to be true, by name. Strings rather than an enum: a type file can
    /// name a condition this build has never heard of, and refusing to load the
    /// whole file for that would make adding a type a code change.
    public let requires: [String]

    public init(id: String, after: String, requires: [String]) {
        self.id = id
        self.after = after
        self.requires = requires
    }
}

/// What the system can say about the conditions type files name.
public struct TypeGateFacts: Sendable, Equatable {
    /// Conditions this build can answer, keyed by the name the file uses.
    /// Absent means "nothing here can answer that" — which is not the same as
    /// `false`, and is not the same as fine.
    public var known: [String: Bool]

    public init(known: [String: Bool] = [:]) {
        self.known = known
    }
}

/// Where the declared gates and their answers come from.
///
/// A protocol rather than a stored value because both halves live outside this
/// module: the gates are in files M3 reads, and the facts are about instruments
/// M15 owns. ProjectKit may depend on neither — the same arrangement as
/// `ClosingLedgerReading`, and for the same reason.
public protocol ProjectTypeGateReading: Sendable {
    /// The gates the named type declares. Empty for a type with none, and empty
    /// for a name this build cannot find — which is a legitimate state for a
    /// project created before its type file existed.
    func declaredGates(forType typeName: String?) async -> [ProjectTypeGate]
    /// What can be said about the conditions those gates name, for one project.
    func gateFacts(for project: ProjectID) async -> TypeGateFacts
}

/// The conditions a type's declared gates contribute to a stage gate.
public enum TypeGateConditions {

    /// Condition names this build knows how to answer.
    ///
    /// Kept beside the ones it cannot (below) so that both lists are read
    /// together. The same arrangement as `RiskScorer.baseline` and its
    /// `notBuiltYet`, and for the same reason: a capability that is missing is
    /// only safe when it is missing *visibly*.
    public static let answerable: Set<String> = [
        "content_validity_passed", "consent_approved", "ethics_recorded",
        "intercoder_agreement",
    ]

    /// Named in a shipped type file, and nothing can answer it yet. Each one
    /// blocks the gate and says so; this table is what keeps the gap in front of
    /// a person instead of in a backlog.
    public static let notAnswerableYet: [String: String] = [
        "guide_reviewed": "P11.8 — แนวสัมภาษณ์ยังไม่มีที่เก็บและยังไม่มีขั้นตอนตรวจ",
        // `intercoder_agreement` moved to `answerable` with P11.8: the codings
        // have a store, so "did this study do the check" is a question the
        // database answers. Whether κ was *good* stays out of the gate — see
        // `ProjectTypeGateReader.hasIntercoderAgreement`.
        "saturation_reached": "P11.8 — เส้นโค้งความอิ่มตัวคำนวณและแสดงแล้ว แต่การ*ประกาศ*ว่าอิ่มตัวเป็นข้อสรุปของผู้วิจัย ไม่ใช่ของซอฟต์แวร์",
        "assumptions_checked": "P6.6 — StatGate ตรวจ assumption แล้ว แต่ยังไม่ได้ผูกผลกลับมาที่ประตูของโปรเจกต์",
        "source_recorded": "P6 — ยังไม่ได้ผูกที่มาของชุดข้อมูลกลับมาที่ประตู",
        "quantitative_done": "P11 — งานผสมวิธียังไม่มีตัวชี้ว่าฝั่งปริมาณจบแล้ว",
        "qualitative_done": "P11.8 — เช่นเดียวกันกับฝั่งคุณภาพ",
        "integration_stated": "P11.9 — ยังไม่มีที่ให้เขียนว่าสองฝั่งบรรจบกันตรงไหน",
        "tests_green": "P9 — ยังไม่ได้ผูกผลเทสของโปรเจกต์ปลายทางกลับมาที่ประตู",
        "reviewed_by_person": "P10 — QA รับงานรายใบแล้ว แต่ยังไม่มีข้อสรุประดับ increment",
    ]

    /// Turns the type's gates into gate conditions.
    ///
    /// One condition per requirement rather than one per gate: "G-instrument
    /// ยังไม่ผ่าน" sends somebody hunting for which of three things is missing,
    /// which is the same mistake the closing gate already learned not to make
    /// with the seventeen practices.
    public static func conditions(for gates: [ProjectTypeGate],
                                  facts: TypeGateFacts) -> [GateCondition] {
        gates.flatMap { gate in
            gate.requires.map { requirement in
                condition(gate: gate, requirement: requirement, facts: facts)
            }
        }
    }

    static func condition(gate: ProjectTypeGate, requirement: String,
                          facts: TypeGateFacts) -> GateCondition {
        let prefix = "\(gate.id) (หลัง \(gate.after)): \(requirement)"
        if let known = facts.known[requirement] {
            return GateCondition(text: known ? prefix : "\(prefix) — ยังไม่ผ่าน",
                                 satisfied: known)
        }
        if answerable.contains(requirement) {
            // The check exists and nothing ran it — the reader is not wired, or
            // it could not reach the store it needed. §19.12's rule again:
            // ไม่มีทางถาม ไม่เท่ากับอนุญาต. It blocks, and it says which of the
            // two situations this is, because "we cannot check" and "we do not
            // know that word" send somebody to different places.
            return GateCondition(text: "\(prefix) — ระบบตรวจข้อนี้ได้ แต่ยังไม่ได้ตรวจ "
                                 + "(ยังไม่ได้ต่อกับที่เก็บข้อมูลที่ต้องใช้)",
                                 satisfied: false)
        }
        if let gap = notAnswerableYet[requirement] {
            // Vacuous, not passed. It does not block — see the note at the top of
            // this file — but it renders as unchecked, so nobody reads the gate
            // as having confirmed something no build can confirm.
            return GateCondition(text: "\(prefix) — ระบบยังตรวจข้อนี้เองไม่ได้ (\(gap)) "
                                 + "· ต้องยืนยันด้วยตาคนก่อนปิดขั้น",
                                 satisfied: true, vacuous: true)
        }
        // A name no table knows. Blocking is the point: a condition that could be
        // invented and quietly do nothing would make the whole `gate:` line
        // decorative again.
        return GateCondition(
            text: "\(prefix) — ไม่รู้จักเงื่อนไขชื่อนี้ · สะกดผิดในไฟล์ชนิดโปรเจกต์ "
                + "หรือเป็นเงื่อนไขใหม่ที่ยังไม่ได้ขึ้นทะเบียนใน `TypeGateConditions`",
            satisfied: false)
    }
}
