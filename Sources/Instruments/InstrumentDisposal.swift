import Foundation

// ─────────────────────────────────────────────────────────────
// Throwing away an instrument (ARCHITECTURE §20.6).
//
// A draft nobody used is clutter, and a screen with no way to remove clutter
// accumulates it — the round that drove P11.3 left two abandoned instruments in
// a real project because there was no way to take them back out.
//
// But "delete the questionnaire" is not a tidying action in a research project.
// Three things make an instrument something other than a draft, and each of them
// is a reason it has to stay:
//
//  • **It passed the gate.** §20.6's first invariant is that an approved version
//    is fixed — it is the record of what was asked. Deleting it deletes the
//    answer to "what exactly did the respondents see", which is the question a
//    thesis committee asks when a result looks surprising.
//  • **Answers exist.** They are append-only by design (§19.17 invariant 2), and
//    an instrument that is gone leaves a table of numbers whose questions nobody
//    can name.
//  • **A round was opened.** Even one that collected nothing: it says fieldwork
//    was opened on this date, and attrition is the difference between who was
//    asked and who replied.
//
// The rule is carried by the types rather than by a check somebody remembers.
// `InstrumentStore.delete` takes a `DiscardableInstrument`, and the only way to
// obtain one is to ask — the same shape as `PublishedInstrument`, for the same
// reason and in the opposite direction.
// ─────────────────────────────────────────────────────────────

/// What an instrument has behind it, as the numbers the caller can supply
/// without this module needing to reach a database.
public struct InstrumentFootprint: Sendable, Equatable {
    public let isApproved: Bool
    public let responses: Int
    public let rounds: Int

    public init(isApproved: Bool, responses: Int, rounds: Int) {
        self.isApproved = isApproved
        self.responses = responses
        self.rounds = rounds
    }

    public static let untouched = InstrumentFootprint(isApproved: false, responses: 0, rounds: 0)
}

public enum DisposalRefusal: Error, CustomStringConvertible, Equatable {
    case approved
    case hasResponses(Int)
    case hasRounds(Int)

    public var description: String {
        switch self {
        case .approved:
            localised("this version has been through the gate and cannot be deleted — a gated instrument is the evidence of what respondents were shown ", "Why an instrument cannot be deleted.")
                + localised("to retire it, make a new version and stop opening this one (§20.6)", "Ends the reason an instrument cannot be deleted.")
        case .hasResponses(let count):
            localised("\(count) sets of answers are tied to this instrument — delete it and what is left is a table of numbers nobody can match to a question", "Why an instrument cannot be deleted. Placeholder: how many response sets exist.")
        case .hasRounds(let count):
            localised("\(count) collection rounds have been opened with this instrument — an opened round is the record of when fieldwork happened ", "Why an instrument cannot be deleted. Placeholder: how many rounds were opened.")
                + localised("even if nobody answered", "Ends the reason an instrument cannot be deleted.")
        }
    }
}

/// An instrument that may be thrown away.
///
/// No public initializer: `InstrumentDisposal.check(_:footprint:)` is the only
/// producer, so a call site that deletes has necessarily asked first.
public struct DiscardableInstrument: Sendable, Equatable {
    public let instrument: Instrument
    /// What was true when the check ran, kept so a caller can say in the log
    /// what it was allowed to delete rather than only that it deleted.
    public let footprint: InstrumentFootprint

    fileprivate init(instrument: Instrument, footprint: InstrumentFootprint) {
        self.instrument = instrument
        self.footprint = footprint
    }
}

public enum InstrumentDisposal {

    /// Every reason this instrument has to stay. Empty means it is a draft that
    /// nothing depends on.
    ///
    /// All of them, not the first one: a screen that reveals objections one at a
    /// time makes somebody delete three things before finding out they cannot
    /// delete the fourth.
    public static func refusals(_ footprint: InstrumentFootprint) -> [DisposalRefusal] {
        var found: [DisposalRefusal] = []
        if footprint.isApproved { found.append(.approved) }
        if footprint.responses > 0 { found.append(.hasResponses(footprint.responses)) }
        if footprint.rounds > 0 { found.append(.hasRounds(footprint.rounds)) }
        return found
    }

    /// The only producer of `DiscardableInstrument`.
    public static func check(_ instrument: Instrument,
                             footprint: InstrumentFootprint) throws -> DiscardableInstrument {
        if let first = refusals(footprint).first { throw first }
        return DiscardableInstrument(instrument: instrument, footprint: footprint)
    }
}
