import Testing
import Foundation
import AgentKit
@testable import Instruments

// Throwing away an instrument is the one destructive action on this screen, and
// three states make it wrong. Each of them is checked here, and so is the thing
// that makes the rule stick: the store's argument cannot be produced without
// asking.

private func draft() -> Instrument {
    Instrument(projectID: ProjectID("pj_1"), title: Bilingual("ร่างที่ยังไม่ได้ใช้"))
}

@Suite("discarding an instrument")
struct InstrumentDisposalTests {

    @Test("a draft nothing depends on can be thrown away")
    func untouchedDraftGoes() throws {
        #expect(InstrumentDisposal.refusals(.untouched).isEmpty)
        let discardable = try InstrumentDisposal.check(draft(), footprint: .untouched)
        #expect(discardable.instrument.title.thai == "ร่างที่ยังไม่ได้ใช้")
        #expect(discardable.footprint == .untouched)
    }

    @Test("an approved version stays, because it is the record of what was asked")
    func approvedStays() {
        let footprint = InstrumentFootprint(isApproved: true, responses: 0, rounds: 0)
        #expect(InstrumentDisposal.refusals(footprint) == [.approved])
        #expect(throws: DisposalRefusal.approved) {
            try InstrumentDisposal.check(draft(), footprint: footprint)
        }
    }

    @Test("answers keep their questions")
    func responsesStay() {
        let footprint = InstrumentFootprint(isApproved: false, responses: 40, rounds: 1)
        #expect(throws: DisposalRefusal.self) {
            try InstrumentDisposal.check(draft(), footprint: footprint)
        }
        #expect(InstrumentDisposal.refusals(footprint).contains(.hasResponses(40)))
    }

    @Test("a round that collected nothing is still a record that fieldwork opened")
    func emptyRoundStays() {
        let footprint = InstrumentFootprint(isApproved: false, responses: 0, rounds: 1)
        #expect(InstrumentDisposal.refusals(footprint) == [.hasRounds(1)])
    }

    @Test("every reason is reported at once, not one at a time")
    func allReasonsTogether() {
        let footprint = InstrumentFootprint(isApproved: true, responses: 12, rounds: 2)
        let refusals = InstrumentDisposal.refusals(footprint)
        #expect(refusals.count == 3)
        // And each says which number it is talking about, so the sentence on
        // screen is about this instrument rather than about the rule.
        #expect(refusals.contains { $0.description.contains("12") })
        #expect(refusals.contains { $0.description.contains("2") })
    }

    @Test("DiscardableInstrument has exactly one producer and no public initializer")
    func discardableIsUnforgeable() throws {
        // Same shape as `PublishedInstrument`, in the other direction: the store
        // takes this type, so a delete path that skipped the rule would have to
        // construct one — and cannot.
        let source = try String(contentsOfFile: #filePath
            .replacingOccurrences(of: "Tests/InstrumentsTests/InstrumentDisposalTests.swift",
                                  with: "Sources/Instruments/InstrumentDisposal.swift"),
                                encoding: .utf8)
        let block = source[source.range(of: "public struct DiscardableInstrument")!.lowerBound...]
        let declaration = block[..<block.range(of: "public enum InstrumentDisposal")!.lowerBound]
        #expect(declaration.contains("fileprivate init("))
        #expect(!declaration.contains("public init("))
        #expect(source.components(separatedBy: "DiscardableInstrument(instrument:").count - 1 == 1)
    }
}
