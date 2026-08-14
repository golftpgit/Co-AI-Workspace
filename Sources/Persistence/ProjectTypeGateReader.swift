import Foundation
import AgentKit
import ProjectKit
import Instruments

// ─────────────────────────────────────────────────────────────
// Answering the conditions a project type declared (ARCHITECTURE §20.2 · §20.5).
//
// The declaration is read by M3, the conditions are checked by ProjectKit, and
// the facts are about instruments owned by M15 — three modules that do not
// depend on each other. This is the one place that can see all three, which is
// exactly the arrangement `ClosingLedger` has for the closing gate's conditions
// 4 and 5, and for the same reason.
//
// The gates arrive as a map rather than as manifests: this module has no
// business reading files, and the app already holds the loaded types.
// ─────────────────────────────────────────────────────────────

public struct ProjectTypeGateReader: ProjectTypeGateReading {
    private let gatesByType: [String: [ProjectTypeGate]]
    private let instruments: InstrumentStore
    private let codebooks: CodebookStore

    public init(gatesByType: [String: [ProjectTypeGate]],
                instruments: InstrumentStore,
                codebooks: CodebookStore) {
        self.gatesByType = gatesByType
        self.instruments = instruments
        self.codebooks = codebooks
    }

    public func declaredGates(forType typeName: String?) async -> [ProjectTypeGate] {
        guard let typeName else { return [] }
        return gatesByType[typeName] ?? []
    }

    /// What is true of this project's instruments, in the names §20.2's files use.
    ///
    /// A project with no instruments answers `false` to all three rather than
    /// leaving them unknown. That is the honest reading: a project whose type
    /// says "content validity before fieldwork" and which has no instrument at
    /// all did not do the thing — it skipped the part the type is about.
    public func gateFacts(for project: ProjectID) async -> TypeGateFacts {
        var known = ["intercoder_agreement": await hasIntercoderAgreement(project)]
        guard let all = try? await instruments.all(project: project), !all.isEmpty else {
            known["content_validity_passed"] = false
            known["consent_approved"] = false
            known["ethics_recorded"] = false
            return TypeGateFacts(known: known)
        }

        var anyApproved = false
        for instrument in all {
            if let approval = try? await instruments.approval(instrument: instrument.id),
               approval != nil {
                anyApproved = true
                break
            }
        }

        // Consent and ethics are per-instrument obligations under §20.5, so these
        // are `allSatisfy` rather than "at least one": a study with three
        // questionnaires and consent on two of them has collected data from
        // people who were not told what it was for.
        // An approval exists only because `InstrumentGate.approve` was
        // satisfied, and content validity is one of the four things it checks —
        // so an approved version is the record that this passed.
        known["content_validity_passed"] = anyApproved
        known["consent_approved"] = all.allSatisfy { $0.consent?.isComplete == true }
        known["ethics_recorded"] = all.allSatisfy { $0.ethics?.isComplete == true }
        return TypeGateFacts(known: known)
    }

    /// Whether intercoder reliability was actually done — **not** whether κ was
    /// good.
    ///
    /// The type file's condition is `intercoder_agreement`, which reads as "this
    /// study did the check", and that is what this answers. Demanding a κ above
    /// some line would be a gate on a *result*: low agreement is a finding, and
    /// the response to it is to sharpen the codebook and recode, which the
    /// researcher then writes up. A gate that blocks on the number would block
    /// the project that is in the middle of doing exactly the right thing.
    private func hasIntercoderAgreement(_ project: ProjectID) async -> Bool {
        guard let books = try? await codebooks.all(project: project) else { return false }
        for book in books {
            guard let units = try? await codebooks.units(codebook: book.id),
                  let assignments = try? await codebooks.assignments(codebook: book.id),
                  CodingAnalysis.reliability(units: units, assignments: assignments,
                                             codebook: book) != nil else { continue }
            return true
        }
        return false
    }
}
