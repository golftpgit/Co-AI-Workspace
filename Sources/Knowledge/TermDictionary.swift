import Foundation

// ─────────────────────────────────────────────────────────────
// The merge layer's vocabulary (ARCHITECTURE E.3).
//
// `NLTokenizer` segments native Thai well but shatters transliterated
// loanwords — `โลจิสติก` becomes `โล|จิ|สติ|ก`, `โควิด` becomes `โค|วิด`.
// Those fragments are ordinary Thai words in their own right, so BM25 starts
// matching "สติ" (mindfulness) against a logistic-regression paper.
//
// The fix is a dictionary of terms that must survive tokenisation whole. It is
// deliberately a plain list rather than a model: it is inspectable, a user can
// extend it for their own field (P2.7), and a wrong entry is one line to
// delete.
// ─────────────────────────────────────────────────────────────

public struct TermDictionary: Sendable {
    /// Longest first, so max-match finds `ไวรัสโคโรนา` before `ไวรัส`.
    private let terms: [String]

    public init(_ terms: [String]) {
        self.terms = Array(Set(terms)).sorted { a, b in
            a.count == b.count ? a < b : a.count > b.count
        }
    }

    public func adding(_ extra: [String]) -> TermDictionary {
        TermDictionary(terms + extra)
    }

    public var count: Int { terms.count }

    /// Every dictionary term in `text`, longest match first and never
    /// overlapping: scanning left to right, the longest term starting at a
    /// position wins and the scan resumes after it.
    func matches(in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var cursor = text.startIndex

        while cursor < text.endIndex {
            var matched: Range<String.Index>?
            for term in terms {
                guard let end = text.index(cursor, offsetBy: term.count, limitedBy: text.endIndex)
                else { continue }
                if text[cursor..<end].compare(term, options: .caseInsensitive) == .orderedSame {
                    matched = cursor..<end
                    break   // terms are longest-first, so this is the longest
                }
            }
            if let matched {
                found.append(matched)
                cursor = matched.upperBound
            } else {
                cursor = text.index(after: cursor)
            }
        }
        return found
    }
}

extension TermDictionary {
    /// Seeded from the vocabulary of the work this system is for — medical and
    /// public-health research, statistics, and computing. Every entry here is
    /// a word `NLTokenizer` splits; entries it handles correctly are left out
    /// rather than listed for completeness, because each one is a chance to
    /// merge something that should have stayed apart.
    public static let seed = TermDictionary([
        // statistics / method
        "โลจิสติก", "รีเกรสชัน", "พารามิเตอร์", "โมเดล", "แบบจำลอง",
        "คอร์รีเลชัน", "ไคสแควร์", "แซมเปิล", "ไบแอส",
        // epidemiology / disease
        "โควิด", "ไวรัสโคโรนา", "ไวรัส", "แบคทีเรีย", "วัคซีน",
        "ไข้หวัดใหญ่", "อินฟลูเอนซา", "เอชไอวี", "วัณโรค",
        // clinical
        "อินซูลิน", "ฮอร์โมน", "โปรตีน", "เอนไซม์", "แอนติบอดี",
        "คอเลสเตอรอล", "เมตาบอลิซึม", "ไกลโคเจน", "เบต้า",
        "ซีรัม", "พลาสมา", "เซลล์",
        // computing
        "คอมพิวเตอร์", "อัลกอริทึม", "ซอฟต์แวร์", "ฮาร์ดแวร์",
        "ดาต้าเบส", "เซิร์ฟเวอร์", "เน็ตเวิร์ก", "อินเทอร์เน็ต",
    ])
}
