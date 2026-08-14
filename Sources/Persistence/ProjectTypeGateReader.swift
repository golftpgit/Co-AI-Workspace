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

    public init(gatesByType: [String: [ProjectTypeGate]], instruments: InstrumentStore) {
        self.gatesByType = gatesByType
        self.instruments = instruments
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
        guard let all = try? await instruments.all(project: project), !all.isEmpty else {
            return TypeGateFacts(known: ["content_validity_passed": false,
                                         "consent_approved": false,
                                         "ethics_recorded": false])
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
        return TypeGateFacts(known: [
            // An approval exists only because `InstrumentGate.approve` was
            // satisfied, and content validity is one of the four things it
            // checks — so an approved version is the record that this passed.
            "content_validity_passed": anyApproved,
            "consent_approved": all.allSatisfy { $0.consent?.isComplete == true },
            "ethics_recorded": all.allSatisfy { $0.ethics?.isComplete == true },
        ])
    }
}
