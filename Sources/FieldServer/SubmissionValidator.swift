import Foundation
import CryptoKit
import Instruments
import OLTP

// ─────────────────────────────────────────────────────────────
// Checking a submission against the instrument (ARCHITECTURE §20.7 invariant 2).
//
// The page validates too. That is a courtesy to the person filling it in and it
// is worth nothing here: the browser is the sender's, the JavaScript is the
// sender's, and `curl` does not run either. **Every rule is checked again on
// this side**, and this file is the side that decides.
//
// The rule that reads as pedantic and is not: a field that the instrument does
// not define is dropped and the drop is written down. Keeping it "in case it is
// useful" means a submission that was tampered with looks the same as one that
// was not, and it means a column in the analysis that no question produced.
// ─────────────────────────────────────────────────────────────

public struct ValidatedSubmission: Sendable, Equatable {
    public let answers: [StoredAnswer]
    public let droppedFields: [String]
    public let consentDigest: String
}

public enum SubmissionProblem: Error, CustomStringConvertible, Equatable {
    case consentNotGiven
    case missingRequired(prompts: [String])
    case notANumber(prompt: String)
    case notAnOption(prompt: String)
    case outOfRange(prompt: String)
    case tooLong(prompt: String)
    /// A grid answered for some rows and not others (§20.3). Named rows,
    /// because "the matrix is incomplete" leaves somebody scrolling.
    case matrixIncomplete(prompt: String, rows: [String])
    /// A ranking that is not a permutation of the options — a repeated place,
    /// a gap, or a number outside 1…n.
    case rankingNotAPermutation(prompt: String, detail: String)

    public var description: String {
        switch self {
        case .consentNotGiven:
            "ต้องยินยอมเข้าร่วมก่อนจึงจะส่งคำตอบได้"
        case .missingRequired(let prompts):
            "ยังไม่ได้ตอบข้อที่จำเป็น: " + prompts.joined(separator: " · ")
        case .notANumber(let prompt):
            "ข้อ “\(prompt)” ต้องเป็นตัวเลข"
        case .notAnOption(let prompt):
            "ข้อ “\(prompt)” มีคำตอบที่ไม่ได้อยู่ในตัวเลือก"
        case .outOfRange(let prompt):
            "ข้อ “\(prompt)” อยู่นอกช่วงที่กำหนด"
        case .matrixIncomplete(let prompt, let rows):
            "ข้อ “\(prompt)” ยังตอบไม่ครบทุกแถว: " + rows.joined(separator: " · ")
        case .rankingNotAPermutation(let prompt, let detail):
            "ข้อ “\(prompt)” จัดอันดับไม่ครบถ้วน — \(detail) "
                + "· ต้องให้อันดับ 1 ถึงจำนวนตัวเลือก ไม่ซ้ำและไม่ข้าม"
        case .tooLong(let prompt):
            "ข้อ “\(prompt)” ยาวเกินที่กำหนด"
        }
    }
}

public enum SubmissionValidator {
    /// Field names the runtime itself owns. Everything else that is not an item
    /// id is a foreign field.
    static let reservedNames: Set<String> = ["__consent", "__instrument", "__version",
                                            "__wave", "__code", "__resume"]

    public static func validate(_ fields: [String: [String]],
                                against published: PublishedInstrument) throws -> ValidatedSubmission {
        let instrument = published.instrument
        guard fields["__consent"]?.first == "yes" else {
            // Checked here and not only by `required` on the checkbox: the
            // checkbox is in the sender's browser.
            throw SubmissionProblem.consentNotGiven
        }

        let byID = Dictionary(uniqueKeysWithValues: instrument.items.map { ($0.id, $0) })
        var answers: [StoredAnswer] = []
        var missing: [String] = []

        for item in instrument.ordered {
            let values = (fields[item.id] ?? []).filter { !$0.isEmpty }
            // A question whose skip condition is not met is not missing — it was
            // not asked. Evaluated from the answers that arrived, so the browser's
            // opinion about what to hide is not what decides.
            let asked = wasAsked(item, fields: fields, items: byID)
            guard asked else { continue }

            // §20.3 / P11.6 — a grid and a ranking arrive as one field per row
            // or per option, so `fields[item.id]` is empty for both and the
            // ordinary "did they answer" test would call a filled-in matrix
            // unanswered.
            switch item.kind {
            case .matrix(let rows, _):
                let parts = Self.parts(of: item, in: fields)
                if parts.isEmpty {
                    if item.required { missing.append(item.prompt.thai) }
                    continue
                }
                answers.append(contentsOf: try Self.matrixAnswers(item, rows: rows, parts: parts))
                continue
            case .ranking(let options):
                let parts = Self.parts(of: item, in: fields)
                if parts.isEmpty {
                    if item.required { missing.append(item.prompt.thai) }
                    continue
                }
                answers.append(contentsOf: try Self.rankingAnswers(item, options: options,
                                                                   parts: parts))
                continue
            default:
                break
            }

            if values.isEmpty {
                if item.required { missing.append(item.prompt.thai) }
                continue
            }
            answers.append(contentsOf: try check(item, values: values))
        }

        guard missing.isEmpty else { throw SubmissionProblem.missingRequired(prompts: missing) }

        let dropped = fields.keys
            .filter { !Self.reservedNames.contains($0) && byID[$0] == nil }
            .sorted()

        return ValidatedSubmission(answers: answers, droppedFields: dropped,
                                   consentDigest: consentDigest(instrument))
    }

    /// Whether the skip condition on an item is satisfied by what arrived.
    static func wasAsked(_ item: Item, fields: [String: [String]],
                         items: [String: Item]) -> Bool {
        guard let skip = item.skip, items[skip.itemID] != nil else { return true }
        guard let answer = fields[skip.itemID]?.first(where: { !$0.isEmpty }) else { return false }
        switch skip.test {
        case .equals: return answer == skip.value
        case .notEquals: return answer != skip.value
        case .atLeast:
            guard let left = Double(answer), let right = Double(skip.value) else { return false }
            return left >= right
        case .atMost:
            guard let left = Double(answer), let right = Double(skip.value) else { return false }
            return left <= right
        }
    }

    /// The sub-fields of a grid or a ranking, by index. The name is
    /// `<item id>#<index>`, which is also what the renderer writes — one place
    /// decides the shape, or a form posts names the validator throws away as
    /// unknown.
    static func parts(of item: Item, in fields: [String: [String]]) -> [Int: String] {
        var parts: [Int: String] = [:]
        for (name, values) in fields where name.hasPrefix(item.id + "#") {
            guard let index = Int(name.dropFirst(item.id.count + 1)),
                  let value = values.first(where: { !$0.isEmpty }) else { continue }
            parts[index] = value
        }
        return parts
    }

    /// One answer per row, and a row left blank is a missing answer rather
    /// than a row that means nothing (§20.3): a half-filled grid analysed as
    /// though the blanks were "no" is the quiet version of making data up.
    static func matrixAnswers(_ item: Item, rows: [Bilingual],
                              parts: [Int: String]) throws -> [StoredAnswer] {
        var answers: [StoredAnswer] = []
        var unanswered: [String] = []

        for (index, row) in rows.enumerated() {
            guard let value = parts[index] else {
                unanswered.append(row.thai)
                continue
            }
            guard case .matrix(_, let columns) = item.kind,
                  let column = Int(value), columns.indices.contains(column) else {
                throw SubmissionProblem.notAnOption(prompt: item.prompt.thai)
            }
            guard case .matrix(_, let allColumns) = item.kind else { continue }
            // The row is part of the id because a matrix is several questions
            // wearing one prompt, and an analysis that cannot tell them apart
            // has one variable where it needs five.
            answers.append(StoredAnswer(itemID: "\(item.id)#\(index)",
                                        text: allColumns[column].thai,
                                        number: Double(column)))
        }

        if item.required && !unanswered.isEmpty {
            throw SubmissionProblem.matrixIncomplete(prompt: item.prompt.thai, rows: unanswered)
        }
        return answers
    }

    /// A ranking is a permutation or it is not a ranking. Two options sharing
    /// third place is not a partial answer to fix up later — it is a different
    /// claim about preference, and accepting it silently would put a number in
    /// the data that nobody chose.
    static func rankingAnswers(_ item: Item, options: [Bilingual],
                               parts: [Int: String]) throws -> [StoredAnswer] {
        var places: [Int: Int] = [:]
        for (index, value) in parts {
            guard options.indices.contains(index), let place = Int(value) else {
                throw SubmissionProblem.notAnOption(prompt: item.prompt.thai)
            }
            places[index] = place
        }
        guard places.count == options.count else {
            throw SubmissionProblem.rankingNotAPermutation(
                prompt: item.prompt.thai,
                detail: "ให้อันดับมา \(places.count) จาก \(options.count) ตัวเลือก")
        }
        let given = places.values.sorted()
        guard given == Array(1...options.count) else {
            let repeated = Set(given.filter { place in given.count(where: { $0 == place }) > 1 })
            throw SubmissionProblem.rankingNotAPermutation(
                prompt: item.prompt.thai,
                detail: repeated.isEmpty
                    ? "มีอันดับที่ข้ามไป"
                    : "อันดับ \(repeated.sorted().map(String.init).joined(separator: ", ")) ซ้ำกัน")
        }
        return options.enumerated().map { index, option in
            StoredAnswer(itemID: "\(item.id)#\(index)", text: option.thai,
                         number: Double(places[index] ?? 0))
        }
    }

    private static func check(_ item: Item, values: [String]) throws -> [StoredAnswer] {
        let prompt = item.prompt.thai
        switch item.kind {
        case .likert(let levels):
            guard let value = values.first, let ordinal = Int(value),
                  ordinal >= 1, ordinal <= levels.count else {
                throw SubmissionProblem.notAnOption(prompt: prompt)
            }
            return [StoredAnswer(itemID: item.id, text: value, number: Double(ordinal))]

        case .single(let options):
            guard let value = values.first, options.contains(where: { $0.thai == value }) else {
                throw SubmissionProblem.notAnOption(prompt: prompt)
            }
            return [StoredAnswer(itemID: item.id, text: value)]

        case .multiple(let options, let maximum):
            let allowed = Set(options.map(\.thai))
            guard values.allSatisfy({ allowed.contains($0) }) else {
                throw SubmissionProblem.notAnOption(prompt: prompt)
            }
            if let maximum, values.count > maximum {
                throw SubmissionProblem.outOfRange(prompt: prompt)
            }
            // Stored as one row with a separator rather than several rows: the
            // answer to "which of these apply" is one answer.
            return [StoredAnswer(itemID: item.id, text: values.joined(separator: " | "))]

        case .openText(let maximum):
            guard let value = values.first else { return [] }
            if let maximum, value.count > maximum {
                throw SubmissionProblem.tooLong(prompt: prompt)
            }
            return [StoredAnswer(itemID: item.id, text: value)]

        case .number(let minimum, let maximum):
            guard let value = values.first, let number = Double(value) else {
                throw SubmissionProblem.notANumber(prompt: prompt)
            }
            if let minimum, number < minimum { throw SubmissionProblem.outOfRange(prompt: prompt) }
            if let maximum, number > maximum { throw SubmissionProblem.outOfRange(prompt: prompt) }
            return [StoredAnswer(itemID: item.id, text: value, number: number)]

        case .date:
            guard let value = values.first, Self.isISODate(value) else {
                throw SubmissionProblem.notAnOption(prompt: prompt)
            }
            return [StoredAnswer(itemID: item.id, text: value)]

        case .matrix, .ranking:
            // Handled before this point, where the sub-fields are visible.
            // Reaching here means a value arrived under the bare item id for a
            // question that does not have one.
            throw SubmissionProblem.notAnOption(prompt: prompt)

        case .fileUpload:
            // Still not drawn, and deliberately: an upload is a multipart body,
            // a file on disk with somebody's data in it, and a retention rule
            // of its own (§20.5). Half of it — a control that accepts a file
            // and drops it — would be worse than the honest gap the renderer
            // shows.
            throw SubmissionProblem.notAnOption(prompt: prompt)
        }
    }

    static func isISODate(_ text: String) -> Bool {
        let parts = text.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              year > 0, (1...12).contains(month), (1...31).contains(day) else { return false }
        return true
    }

    /// A digest of the consent wording this instrument shows, so a stored
    /// submission names the words its respondent actually read (§20.7). A hash
    /// rather than a copy: the text itself is already kept with the instrument
    /// version, and copying it onto every row would be a second place for it to
    /// drift.
    public static func consentDigest(_ instrument: Instrument) -> String {
        guard let consent = instrument.consent else { return "none" }
        let joined = [consent.purpose.thai, consent.whatIsCollected.thai,
                      consent.voluntary.thai, consent.contact].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}
