import Foundation

// ─────────────────────────────────────────────────────────────
// Shelving the library (ARCHITECTURE §11.9, P18.4).
//
// A graph with thousands of nodes is a picture nobody can look at, and a
// document list in the order things were added is a shelf sorted by purchase
// date. Libraries solved this a century ago, so the scheme is borrowed rather
// than invented: Library of Congress, 21 single-letter classes, each with
// two-letter subclasses.
//
// Four decisions from §11.9, and each one is a refusal of something easier:
//
//  • **Subclass and no further.** `RA`, `RC`, `QA` — not a full call number.
//    Cutter numbers exist to put a book in one place on one shelf, which means
//    nothing here; what is wanted is a division somebody can read.
//  • **A document may sit in several.** Public-health work that uses statistics
//    really is `RA` and `QA`, and forcing a choice throws away the fact that
//    made it interesting.
//  • **A guess says it is a guess.** Filed in the wrong place and invisible is
//    knowledge that may as well not be there, and it looks identical to having
//    none — so every assignment carries who made it, and a person can change it.
//  • **"Cannot classify" is an answer.** Better than sweeping everything into A
//    (general works), which empties the whole scheme of meaning while looking
//    tidy.
// ─────────────────────────────────────────────────────────────

/// The 21 classes LC actually uses. I, O, W, X and Y are unassigned in the
/// scheme itself and so are absent here rather than reserved: a case nothing
/// can ever be is a case somebody eventually puts something in.
public enum LCClass: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case a = "A", b = "B", c = "C", d = "D", e = "E", f = "F", g = "G"
    case h = "H", j = "J", k = "K", l = "L", m = "M", n = "N", p = "P"
    case q = "Q", r = "R", s = "S", t = "T", u = "U", v = "V", z = "Z"

    public var label: String {
        switch self {
        case .a: localised("General works", "Library of Congress class A.")
        case .b: localised("Philosophy, psychology, religion", "Library of Congress class B.")
        case .c: localised("Auxiliary sciences of history", "Library of Congress class C.")
        case .d: localised("World history", "Library of Congress class D.")
        case .e: localised("History of the Americas", "Library of Congress class E.")
        case .f: localised("History of the Americas (local)", "Library of Congress class F.")
        case .g: localised("Geography, anthropology", "Library of Congress class G.")
        case .h: localised("Social sciences", "Library of Congress class H.")
        case .j: localised("Political science", "Library of Congress class J.")
        case .k: localised("Law", "Library of Congress class K.")
        case .l: localised("Education", "Library of Congress class L.")
        case .m: localised("Music", "Library of Congress class M.")
        case .n: localised("Fine arts", "Library of Congress class N.")
        case .p: localised("Language and literature", "Library of Congress class P.")
        case .q: localised("Science", "Library of Congress class Q.")
        case .r: localised("Medicine", "Library of Congress class R.")
        case .s: localised("Agriculture", "Library of Congress class S.")
        case .t: localised("Technology", "Library of Congress class T.")
        case .u: localised("Military science", "Library of Congress class U.")
        case .v: localised("Naval science", "Library of Congress class V.")
        case .z: localised("Library science", "Library of Congress class Z.")
        }
    }
}

/// A class and, where it is known, the subclass inside it.
public struct LCSubject: Sendable, Equatable, Hashable, Codable {
    public let `class`: LCClass
    /// The second letter, when the classifier could place it that precisely.
    /// `nil` is a real state — "medicine, and no more than that" is more useful
    /// than a subclass somebody invented.
    ///
    /// A `String` rather than a `Character` only so this whole type can be
    /// `Codable` without a hand-written coder for one letter; everything that
    /// reads it treats it as the letter it is.
    public let subclass: String?

    public var code: String {
        subclass.map { "\(`class`.rawValue)\($0)" } ?? `class`.rawValue
    }

    public init?(code: String) {
        let letters = code.uppercased().filter(\.isLetter)
        guard let first = letters.first,
              let mainClass = LCClass(rawValue: String(first)) else { return nil }
        self.class = mainClass
        // Only one extra letter is kept: `RA` is a subclass, `RA1234` is a
        // shelf position, and shelf positions mean nothing here.
        let second = letters.dropFirst().first
        self.subclass = second.map { String($0).uppercased() }
    }

    public init(_ mainClass: LCClass, _ subclass: String? = nil) {
        self.class = mainClass
        self.subclass = subclass?.uppercased()
    }

    /// The subclasses this library actually uses often enough to name. Not the
    /// whole scheme: LC has hundreds, and a list nobody maintains is a list
    /// that lies about coverage.
    public var label: String {
        switch code {
        case "RA": localised("Public health", "Library of Congress subclass RA.")
        case "RC": localised("Internal medicine", "Library of Congress subclass RC.")
        case "RT": localised("Nursing", "Library of Congress subclass RT.")
        case "RJ": localised("Paediatrics", "Library of Congress subclass RJ.")
        case "RM": localised("Pharmacotherapy", "Library of Congress subclass RM.")
        case "QA": localised("Mathematics and computing", "Library of Congress subclass QA.")
        case "QH": localised("Biology", "Library of Congress subclass QH.")
        case "QP": localised("Physiology", "Library of Congress subclass QP.")
        case "HA": localised("Statistics", "Library of Congress subclass HA.")
        case "HM": localised("Sociology", "Library of Congress subclass HM.")
        case "LB": localised("Theory and practice of education", "Library of Congress subclass LB.")
        case "TK": localised("Electrical and computer engineering", "Library of Congress subclass TK.")
        default: `class`.label
        }
    }
}

public struct Classification: Sendable, Equatable, Codable {
    public enum Assigner: String, Sendable, Equatable, Codable {
        case system, user
    }

    public let subjects: [LCSubject]
    public let assignedBy: Assigner
    /// Why the system chose these, when it did. Empty for a person's own
    /// assignment — they do not owe the machine an explanation.
    public let reason: String

    /// **Unclassified is a value, not an absence.** A document with no subjects
    /// shows as "ยังจัดหมวดไม่ได้" on the shelf rather than disappearing into A.
    public var isClassified: Bool { !subjects.isEmpty }

    public init(subjects: [LCSubject], assignedBy: Assigner, reason: String = "") {
        self.subjects = subjects
        self.assignedBy = assignedBy
        self.reason = reason
    }

    public static let unclassified = Classification(subjects: [], assignedBy: .system,
                                                    reason: localised("no word in it said clearly enough what it is about", "Why a document was left unclassified."))
}

public enum Classifier {
    /// Words that place a document, per subclass.
    ///
    /// **Not translatable, and not just untranslated.** These are the words
    /// looked for *in the document*, so they must stay in the language the
    /// document is written in — several of them are also class labels, and the
    /// literal-level replacer duly rewrote eight of them into `t(…)` calls,
    /// which would have made a Thai document stop classifying the moment the
    /// interface was English (2026-08-18). Adding a language here means adding
    /// its words, never swapping the existing ones out.
    ///
    /// Keywords rather than a model, and that is a decision with a reason: a
    /// classifier that cannot say *why* it filed something under `RA` gives a
    /// person nothing to disagree with, and §11.9's whole point is that a wrong
    /// class must be correctable. A matched word is an argument; a logit is not.
    /// It is also free, which matters for something that runs on every ingest.
    /// LOCALISATION: matching data — see RULES.md U24.
    static let vocabulary: [(code: String, words: [String])] = [
        ("RA", ["สาธารณสุข", "ระบาดวิทยา", "อนามัย", "public health", "epidemiolog",
                "prevention", "screening", "vaccination", "วัคซีน", "คัดกรอง"]),
        ("RC", ["อายุรศาสตร์", "โรคเบาหวาน", "ความดันโลหิต", "มะเร็ง", "diabetes",
                "hypertension", "cancer", "cardiovascular", "diagnosis", "วินิจฉัย"]),
        ("RT", ["พยาบาล", "การพยาบาล", "nursing", "nurse", "ward", "เวรดึก"]),
        ("RJ", ["กุมารเวช", "เด็กแรกเกิด", "paediatric", "pediatric", "neonat"]),
        ("RM", ["เภสัช", "ขนาดยา", "pharmacother", "dosage", "drug therapy"]),
        ("QA", ["คณิตศาสตร์", "อัลกอริทึม", "โปรแกรม", "mathematic", "algorithm",
                "software", "computer", "machine learning"]),
        ("QH", ["ชีววิทยา", "พันธุกรรม", "biolog", "genetic", "cell"]),
        ("QP", ["สรีรวิทยา", "physiolog", "metabolis"]),
        ("HA", ["สถิติ", "การถดถอย", "ค่าเฉลี่ย", "statistic", "regression",
                "confidence interval", "p-value", "sample size"]),
        ("HM", ["สังคมวิทยา", "ชุมชน", "sociolog", "social determinant"]),
        ("LB", ["การศึกษา", "หลักสูตร", "การเรียนการสอน", "education", "curriculum",
                "teaching", "learner"]),
        ("TK", ["วิศวกรรมไฟฟ้า", "เครือข่าย", "electrical engineering", "network",
                "embedded"]),
    ]

    /// Classifies a document from its text.
    ///
    /// Every subclass whose words appear is included — §11.9's "one document,
    /// several classes" — and a document nothing matches comes back
    /// `unclassified` rather than being swept into A.
    public static func classify(_ text: String, title: String = "") -> Classification {
        let haystack = (title + " " + text).lowercased()
        var matched: [(LCSubject, [String])] = []

        for entry in vocabulary {
            let hits = entry.words.filter { haystack.contains($0.lowercased()) }
            guard !hits.isEmpty, let subject = LCSubject(code: entry.code) else { continue }
            matched.append((subject, hits))
        }
        guard !matched.isEmpty else { return .unclassified }

        // Most evidence first, so a screen showing one class shows the one the
        // document is most about.
        matched.sort { $0.1.count > $1.1.count }
        let reason = matched
            .map { "\($0.0.code): " + $0.1.prefix(3).joined(separator: ", ") }
            .joined(separator: " · ")
        return Classification(subjects: matched.map(\.0), assignedBy: .system,
                              reason: localised("the words that placed it — ", "Introduces the matched words that decided a classification.") + reason)
    }

    /// The subclasses offered on screen when somebody corrects a class.
    ///
    /// The ones this library actually uses, not all several hundred: a menu
    /// nobody can read is a menu nobody uses, and the vocabulary above is the
    /// same list, which keeps the two from drifting.
    public static var commonSubjects: [String] { vocabulary.map(\.code) }

    /// What a person decided, which the system never overwrites.
    public static func assign(_ subjects: [LCSubject]) -> Classification {
        Classification(subjects: subjects, assignedBy: .user)
    }

    /// How the shelf divides up, for the screen.
    ///
    /// Unclassified documents are counted and returned like any other bucket —
    /// leaving them out would make the proportions add up while describing a
    /// smaller library than the one that exists.
    public static func breakdown(_ classifications: [Classification])
        -> (byCode: [(code: String, label: String, count: Int)], unclassified: Int) {
        var counts: [String: (label: String, count: Int)] = [:]
        var unclassified = 0

        for classification in classifications {
            guard classification.isClassified else { unclassified += 1; continue }
            // A document in two classes counts in both: the proportions are of
            // *subjects covered*, not a partition, and a screen saying so is
            // more honest than one that divides a paper in half.
            for subject in classification.subjects {
                var entry = counts[subject.code] ?? (subject.label, 0)
                entry.count += 1
                counts[subject.code] = entry
            }
        }
        let byCode = counts
            .map { (code: $0.key, label: $0.value.label, count: $0.value.count) }
            .sorted { ($0.count, $1.code) > ($1.count, $0.code) }
        return (byCode, unclassified)
    }

    /// Whether an edge in the graph crosses a class boundary (§11.9, P18.5).
    ///
    /// The interesting finding in interdisciplinary work is the line from `RA`
    /// to `QA`, not the ones inside `RA` — so the graph has to be able to tell
    /// them apart before it can draw them differently.
    public static func crossesClasses(_ a: Classification, _ b: Classification) -> Bool {
        guard a.isClassified, b.isClassified else { return false }
        let left = Set(a.subjects.map(\.class))
        let right = Set(b.subjects.map(\.class))
        return left.intersection(right).isEmpty
    }
}
