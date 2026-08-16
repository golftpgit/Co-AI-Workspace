import Foundation

// ─────────────────────────────────────────────────────────────
// What a conflict card is called (§11.6, U12).
//
// The headline was whatever came back in the model's `question` field, falling
// back to the search that surfaced the pair — which is the user's own prompt.
// So cards ended up titled "จงสรุปแนวทางการให้ยาปฏิชีวนะก่อนผ่าตัด": an
// instruction, not a question, and one that says nothing about what the two
// passages actually disagree on. A person scanning ten cards reads ten copies
// of what they typed.
//
// The rule here is not "write a better title" — nothing in this file writes
// prose. It is **a title has to be about the two passages**, and a candidate
// that is not is replaced by one built from them:
//
//  • An instruction is not a question. "จงสรุป…", "ช่วยเขียน…", "summarize…"
//    are things somebody asked for, not things two sources disagree about.
//  • A title must be grounded in what it titles. If a candidate shares no
//    content words with either passage, it is about something else — usually
//    the prompt.
//  • The fallback quotes both sides. It is plain and always available, and a
//    card headed by the two claims themselves is never wrong about what is on
//    it, which is more than can be said for a sentence a model wrote.
// ─────────────────────────────────────────────────────────────

public enum ConflictHeadline {

    /// Phrases that make a sentence a request rather than a question about the
    /// sources. Crude and deliberately so: the cost of rejecting a usable title
    /// is a plainer card, and the cost of keeping a bad one is every card in
    /// the list reading like the search box.
    static let instructionMarkers = [
        "จง", "ช่วย", "กรุณา", "ขอให้", "ให้ตอบ", "ตอบเป็น", "สรุปให้", "เขียนให้",
        "หน่อย", "ทีครับ", "ทีค่ะ",
        "summarize", "summarise", "write ", "explain ", "list ", "give me", "please ",
        "compare ", "provide ", "describe ",
    ]

    /// Picks the headline for a card.
    ///
    /// - Parameters:
    ///   - candidate: what the model called it, or the search that found the pair.
    ///   - a, b: the two passages, verbatim.
    public static func headline(candidate: String, a: String, b: String,
                                tokenizer: Tokenizer = Tokenizer()) -> String {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if isUsable(trimmed, a: a, b: b, tokenizer: tokenizer) { return trimmed }
        return derived(a: a, b: b)
    }

    /// Whether a candidate may be used as written.
    public static func isUsable(_ candidate: String, a: String, b: String,
                                tokenizer: Tokenizer = Tokenizer()) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return false }

        let lowered = trimmed.lowercased()
        if instructionMarkers.contains(where: { lowered.contains($0) }) { return false }

        // Grounded: shares content words with at least one of the passages.
        // Without this a card can be titled with something the sources never
        // mention, which is exactly how the prompt ends up as the title.
        let words = Set(tokenizer.tokens(trimmed).filter { $0.count > 1 })
        guard !words.isEmpty else { return false }
        let passage = Set(tokenizer.tokens(a) + tokenizer.tokens(b))
        return !words.isDisjoint(with: passage)
    }

    /// A title built from the two claims. Not clever on purpose: it quotes,
    /// and a quotation cannot be wrong about what the card contains.
    public static func derived(a: String, b: String, limit: Int = 60) -> String {
        "\(clip(a, limit)) ↔ \(clip(b, limit))"
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > limit else { return flat }
        return flat.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
    }
}
