import Foundation
import Instruments
import OLTP

// ─────────────────────────────────────────────────────────────
// The one step between the answers on screen and M15's arithmetic (P11.3).
//
// Everything with a decision in it — what becomes a number, who gets excluded,
// which items belong to which subscale — is in `Instruments`, where `swift test`
// can reach it. What is left here is the adaptation: `ResponseRow` holds an
// answer per item and `ScoredResponses.score` wants an item id → text map, and
// turning one into the other is the sort of code that is either obviously right
// or obviously wrong.
//
// The split is deliberate rather than tidy. The app target is an executable with
// no unit tests, so logic that lands in it is logic nothing checks — which is
// how this project got a conflict detector that passed seven tests while nothing
// ever constructed it.
// ─────────────────────────────────────────────────────────────

extension ScoredResponses {

    /// Scores the rows the screen already holds.
    ///
    /// `ResolvedAnswer.text` is the corrected value where a correction exists
    /// (§19.17), so an answer somebody fixed is analysed as fixed — with the
    /// original still on record beside it.
    static func of(instrument: Instrument,
                   rows: [InstrumentsViewModel.ResponseRow]) -> ScoredResponses {
        score(instrument: instrument,
              answers: rows.map { $0.answers.mapValues(\.text) })
    }
}
