import Foundation
import AgentKit
import Knowledge

// ─────────────────────────────────────────────────────────────
// Transcripts, and quoting them (ARCHITECTURE §20.3, P11.8 second half).
//
// P11.8's Done-when is "a transcript goes into the knowledge base with
// provenance, and a citation in the manuscript points back to the real
// passage". The second clause is the hard one, because it is a promise about
// something that happens months later: somebody reads chapter 4, wants to check
// a quotation, and has to arrive at the same words in the same interview.
//
// A comment cannot keep that promise. What keeps it is that the quoted text is
// **produced by slicing the transcript**, and the offsets it was sliced at
// travel with it into the citation. A quotation and its locator cannot disagree
// because they are made in the same operation out of the same string —
// `TranscriptQuotation` has no public initialiser, so there is no way to write
// down a quotation that was typed instead of taken.
//
// The other rule this file carries is §20.7's: a transcript knows a participant
// *code* and never a name. Not because the code is secret — it is not — but
// because a transcript is the thing that gets chunked, indexed, embedded,
// exported and quoted, and an identity that entered here would come out in all
// five places.
// ─────────────────────────────────────────────────────────────

public struct Transcript: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let projectID: ProjectID
    /// What to call it in a citation: "INT-01", "สัมภาษณ์พยาบาลเวรดึก คนที่ 3".
    public var title: String
    /// The code that stands for the person (§20.7). Never a name — the type has
    /// nowhere to put one, which is the enforcement.
    public var participantCode: String?
    public var collectedAt: Date
    /// Who produced the text from the recording. Kept because a transcript is an
    /// interpretation — where the punctuation went is a decision — and a
    /// methods section that says "transcribed verbatim" should be able to say
    /// by whom.
    public var transcribedBy: String
    public var text: String

    public init(id: String = OpaqueID.make(OpaqueID.transcript),
                projectID: ProjectID,
                title: String,
                participantCode: String? = nil,
                collectedAt: Date = Date(),
                transcribedBy: String = "",
                text: String = "") {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.participantCode = participantCode
        self.collectedAt = collectedAt
        self.transcribedBy = transcribedBy
        self.text = text
    }

    /// The provenance every chunk and every quotation of this transcript carries.
    public var provenance: Provenance {
        Provenance.fieldwork(documentID: id, title: title,
                             participantCode: participantCode,
                             collectedAt: collectedAt)
    }

    /// Paragraph breaks, as spans into this transcript.
    ///
    /// The natural unit to offer as a starting point for coding: a paragraph in
    /// a transcript is usually one turn in the conversation. Offered rather than
    /// imposed — `CodingUnit` takes any range, and a researcher who wants finer
    /// units has them.
    public var paragraphs: [TextSpan] {
        let characters = Array(text)
        var spans: [TextSpan] = []
        var start: Int?
        for (index, character) in characters.enumerated() {
            if character.isNewline {
                if let began = start { spans.append(TextSpan(start: began, end: index)) }
                start = nil
            } else if start == nil, !character.isWhitespace {
                start = index
            }
        }
        if let began = start { spans.append(TextSpan(start: began, end: characters.count)) }
        return spans
    }
}

/// A quotation that is provably a span of a transcript.
///
/// No public initialiser: `TranscriptQuotation.of(_:at:)` slices the text, so
/// the words and the offsets are two views of one operation. A quotation typed
/// by hand — the way a quotation drifts from its source between the analysis and
/// the writing — is not a value this type can hold.
public struct TranscriptQuotation: Sendable, Equatable, Identifiable {
    public let transcriptID: String
    public let span: TextSpan
    /// Sliced out of the transcript, never supplied.
    public let text: String
    public let provenance: Provenance

    public var id: String { "\(transcriptID)@\(span.start)-\(span.end)" }

    fileprivate init(transcriptID: String, span: TextSpan, text: String,
                     provenance: Provenance) {
        self.transcriptID = transcriptID
        self.span = span
        self.text = text
        self.provenance = provenance
    }

    /// The only producer.
    ///
    /// `nil` when the span does not fit the transcript — which is the answer
    /// that matters. A transcript that was corrected after coding has moved its
    /// own offsets, and the right behaviour then is to refuse the quotation
    /// rather than return whatever characters now sit at those numbers.
    public static func of(_ transcript: Transcript, at span: TextSpan)
        -> TranscriptQuotation? {
        guard let text = span.slice(of: transcript.text) else { return nil }
        return TranscriptQuotation(transcriptID: transcript.id, span: span, text: text,
                                   provenance: transcript.provenance.citing(span))
    }

    /// The quotation behind one coded passage — the join P11.8 is about.
    public static func of(_ transcript: Transcript, unit: CodingUnit)
        -> TranscriptQuotation? {
        guard unit.documentID == transcript.id else { return nil }
        return of(transcript, at: TextSpan(unit.range))
    }
}

// ─────────────────────────────────────────────────────────────
// Into the knowledge base
// ─────────────────────────────────────────────────────────────

public enum TranscriptIngest {

    /// The chunks to index, each carrying the span it was sliced from.
    ///
    /// The spans are what makes a retrieved chunk citable back to the passage
    /// rather than to the whole interview — a two-hour interview cited as one
    /// document is a citation nobody can check.
    ///
    /// Chunking is M7's, not a second splitter: the index and the retriever
    /// already agree about what a chunk is, and a transcript that were split
    /// differently would retrieve differently from everything else in the
    /// project (§11, and the reason `Chunker.version` exists).
    public static func chunks(of transcript: Transcript,
                              chunker: Chunker = Chunker()) -> [(Chunk, Provenance)] {
        let characters = Array(transcript.text)
        var searchFrom = 0
        return chunker.chunks(of: transcript.text).map { chunk in
            let span = locate(Array(chunk.text), in: characters, from: searchFrom)
            if let span { searchFrom = span.start + 1 }
            let provenance = span.map { transcript.provenance.citing($0) }
                ?? transcript.provenance
            return (chunk, provenance)
        }
    }

    /// Where a chunk's text sits in the transcript.
    ///
    /// The chunker slices its bodies out of the source (`Chunker.version` 2), so
    /// this is a search for an exact run rather than a reconstruction — and when
    /// it does not find one, the chunk keeps the whole-document provenance
    /// instead of a span that would be a guess.
    private static func locate(_ needle: [Character], in haystack: [Character],
                               from start: Int) -> TextSpan? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        let last = haystack.count - needle.count
        guard start <= last else { return nil }
        for offset in start...last {
            var matched = true
            for index in needle.indices where haystack[offset + index] != needle[index] {
                matched = false
                break
            }
            if matched { return TextSpan(start: offset, end: offset + needle.count) }
        }
        return nil
    }
}
