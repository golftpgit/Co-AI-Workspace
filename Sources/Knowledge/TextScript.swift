import Foundation

// ─────────────────────────────────────────────────────────────
// Which language a passage is written in (ARCHITECTURE §11.7, P18.1/P18.2).
//
// **The symptom this exists for** (2026-08-15): the conflict cards the system
// raised were Thai and English versions of one sentence. A small model asked
// "do these contradict?" answers yes, confidently, because it cannot read one
// of the two sides — and a ledger full of cards like that gets the real cards
// dismissed unread, which is the damage §11.6 exists to prevent.
//
// **What P18.2 planned, and what the measurement said.** The plan was to filter
// those pairs out before the model: `bge-m3` embeds both languages in one space
// (E.10), so a pair that sits very close *and* is written in two scripts was to
// be treated as a suspected translation. Measured on the real model, that does
// not work and cannot be made to work by moving a number (E.25):
//
//     translations       0.401  0.644  0.710  0.760
//     real disagreements 0.322  0.541  0.630  0.770
//
// The groups overlap, and they overlap for a reason that is not going away: an
// embedding measures what a passage is *about*, and two statements that
// contradict each other are about exactly the same thing. "ผู้ใหญ่ควรนอนอย่างน้อย
// 7 ชั่วโมง" against "adults need no more than four hours of sleep" is the
// closest pair in the whole set — 0.770 — and it is the clearest contradiction
// in it.
//
// So there is no similarity filter here. What survives is the cheap half: which
// script a passage is in, decided from its characters with no model and no
// guess. `ConflictDetector` uses it to hold cross-language pairs to a stricter
// standard, which is a rule about *evidence*, not a shortcut around the model.
// ─────────────────────────────────────────────────────────────

/// Which writing system a passage is in. Script rather than language, because
/// that is what can be decided from the characters with no model and no guess:
/// Thai and English are the pair this system actually mixes (§11.8), and a
/// distinction that cannot be made reliably is worse than one that is coarse.
public enum TextScript: String, Sendable, Equatable {
    case thai
    case latin
    /// Substantially both — a Thai abstract with English terms in it, which is
    /// the ordinary shape of a Thai medical paper. Never counted as "a
    /// different language from" anything, because it is both.
    case mixed
    /// Neither, or too little text to say.
    case undetermined
}

public enum TextScriptReader {
    /// A passage is "in" a script when that script carries most of its letters.
    ///
    /// **60/40 rather than something tidier like 85/15**, and the number came
    /// from a real sentence: "ผู้ป่วยที่ได้รับ metformin มีระดับ HbA1c ลดลงอย่างมี
    /// นัยสำคัญ (p < 0.05)" is three-quarters Thai characters, and it is a
    /// perfectly ordinary Thai clinical sentence. A drug name, an assay and a
    /// p-value are Latin letters inside Thai prose; calling that `mixed` would
    /// take this rule off exactly the documents it is for.
    public static func script(of text: String) -> TextScript {
        var thai = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0E00...0x0E7F: thai += 1
            case 0x41...0x5A, 0x61...0x7A: latin += 1
            default: continue
            }
        }
        let total = thai + latin
        // Below this there is not enough writing to be sure of anything, and a
        // confident answer about "ok" or a bare number is a wrong answer.
        guard total >= 12 else { return .undetermined }
        let thaiShare = Double(thai) / Double(total)
        if thaiShare >= 0.60 { return .thai }
        if thaiShare <= 0.40 { return .latin }
        return .mixed
    }

    /// Whether these two are written in different languages, as far as this can
    /// be decided without a model. `mixed` and `undetermined` are never
    /// "different from" anything: nothing may be skipped or discounted on a
    /// guess about which language something is in.
    public static func differentLanguages(_ a: String, _ b: String) -> Bool {
        let first = script(of: a), second = script(of: b)
        guard first == .thai || first == .latin, second == .thai || second == .latin else {
            return false
        }
        return first != second
    }

    /// Cosine, for the calibration that keeps checking whether an embedding
    /// filter has become possible (E.25). Here rather than in the check itself
    /// so the measurement and any future filter cannot use two different
    /// measures.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Double = 0, normA: Double = 0, normB: Double = 0
        for index in a.indices {
            dot += Double(a[index]) * Double(b[index])
            normA += Double(a[index]) * Double(a[index])
            normB += Double(b[index]) * Double(b[index])
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }
}
