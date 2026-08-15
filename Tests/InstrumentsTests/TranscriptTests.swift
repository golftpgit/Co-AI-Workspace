import Testing
import Foundation
import AgentKit
import Knowledge
@testable import Instruments

// P11.8's Done-when, in two halves: a transcript reaches the knowledge base
// carrying provenance, and a citation points back at the real passage.
//
// The second is the one worth being careful about, because the way it fails is
// months later and quietly: the quotation in chapter 4 is *nearly* what the
// participant said, and nobody can tell any more. So the check here is not that
// the numbers look plausible — it is that slicing the transcript at the cited
// offsets returns the quoted characters, which is the thing a reader will do.

private let interview = """
ผู้สัมภาษณ์: เล่าเรื่องเวรดึกให้ฟังหน่อยครับ
ผู้ให้ข้อมูล: เวรหนึ่งดูคนไข้สิบสองเตียง ทำไม่ทันจริง ๆ ค่ะ บางคืนไม่ได้นั่งเลย
ผู้สัมภาษณ์: แล้วเรื่องทีมล่ะครับ
ผู้ให้ข้อมูล: พี่ ๆ ในเวรช่วยกันดี ถ้าไม่มีพวกเขาคงไม่ไหว
"""

private func transcript() -> Transcript {
    Transcript(id: "ts_int01", projectID: ProjectID("pj_q"), title: "INT-01",
               participantCode: "P-7QK2", collectedAt: Date(timeIntervalSince1970: 1_770_000_000),
               transcribedBy: "ผู้ช่วยวิจัย ก", text: interview)
}

@Suite("quoting a transcript")
struct TranscriptQuotationTests {

    @Test("the citation's offsets, applied to the transcript, give back the quotation")
    func offsetsResolveToTheQuotation() throws {
        let source = transcript()
        let paragraphs = source.paragraphs
        #expect(paragraphs.count == 4)

        let quotation = try #require(TranscriptQuotation.of(source, at: paragraphs[1]))
        #expect(quotation.text.contains("สิบสองเตียง"))

        // This is the whole promise: a reader takes the numbers off the citation,
        // opens the transcript, and lands on the same characters.
        let span = try #require(quotation.provenance.passage)
        #expect(span.slice(of: source.text) == quotation.text)
        #expect(quotation.provenance.documentID == source.id)
    }

    @Test("a quotation cannot be written down, only taken")
    func quotationIsUnforgeable() throws {
        // Same shape as `PublishedInstrument` and `DiscardableInstrument`: what
        // is pinned is that the initialiser is not public and there is one
        // producer, because the line that must not compile cannot be a test.
        let source = try String(contentsOfFile: #filePath
            .replacingOccurrences(of: "Tests/InstrumentsTests/TranscriptTests.swift",
                                  with: "Sources/Instruments/Transcript.swift"),
                                encoding: .utf8)
        let block = source[source.range(of: "public struct TranscriptQuotation")!.lowerBound...]
        let declaration = block[..<block.range(of: "// ─")!.lowerBound]
        #expect(declaration.contains("fileprivate init("))
        #expect(!declaration.contains("public init("))
        #expect(source.components(separatedBy: "TranscriptQuotation(transcriptID:").count - 1 == 1)
    }

    @Test("a span past the end of a corrected transcript is refused, not trimmed")
    func spanThatNoLongerFits() {
        var shortened = transcript()
        shortened.text = "สั้นลงหลังแก้"
        // A transcript corrected after coding has moved its own offsets. Returning
        // whatever characters now sit at those numbers is how a quotation ends up
        // attributed to the wrong sentence.
        #expect(TranscriptQuotation.of(shortened, at: TextSpan(start: 40, end: 90)) == nil)
    }

    @Test("a coded passage quotes the transcript it was coded from, and no other")
    func unitMustMatchItsTranscript() throws {
        let source = transcript()
        let span = source.paragraphs[3]
        let unit = CodingUnit(documentID: source.id, range: span.range,
                              text: "ไม่ได้ใช้ข้อความนี้")
        let quotation = try #require(TranscriptQuotation.of(source, unit: unit))
        // The text comes from the transcript, not from the unit's own copy —
        // which is the point: the two can drift, and only one of them is
        // evidence.
        #expect(quotation.text.contains("พี่ ๆ ในเวรช่วยกัน"))
        #expect(quotation.text != unit.text)

        let elsewhere = CodingUnit(documentID: "ts_other", range: span.range, text: "…")
        #expect(TranscriptQuotation.of(source, unit: elsewhere) == nil)
    }

    @Test("offsets are in the same unit that produced them, which for Thai is not code points")
    func offsetsAreGraphemes() throws {
        // Driving the screen with a Thai transcript is what made this visible:
        // the first line shows 43 marks, is 44 code points, and is 32 Swift
        // Characters, because vowels and tone marks combine onto the consonant
        // they sit on. Which unit is chosen matters less than that one unit both
        // produces and resolves a span — a citation exported and re-resolved by
        // something counting code points would land in the wrong sentence.
        let line = "ผู้สัมภาษณ์: เล่าเรื่องเวรดึกให้ฟังหน่อยครับ"
        #expect(line.count == 32)
        #expect(line.unicodeScalars.count == 44)

        var source = transcript()
        source.text = line + "\n" + "บรรทัดที่สอง"
        let spans = source.paragraphs
        #expect(spans.first == TextSpan(start: 0, end: 32))
        let quotation = try #require(TranscriptQuotation.of(source, at: spans[0]))
        #expect(quotation.text == line)
        // And the second paragraph starts after the newline, in the same unit.
        #expect(TranscriptQuotation.of(source, at: spans[1])?.text == "บรรทัดที่สอง")
    }

    @Test("a transcript carries a code and has nowhere to put a name")
    func noIdentityInTheTranscript() throws {
        let source = transcript()
        guard case .fieldwork(let code) = source.provenance.origin else {
            Issue.record("fieldwork provenance expected")
            return
        }
        #expect(code == "P-7QK2")
        // No tier: primary data has no external review to point at, and putting
        // it on the scale built for published sources would make the
        // corroboration rule read an interview as though it were a journal.
        #expect(source.provenance.tier == nil)
        #expect(!source.provenance.isExternallySourced)
    }
}

@Suite("a transcript reaching the knowledge base")
struct TranscriptIngestTests {

    @Test("every chunk carries provenance, and its span resolves to its own text")
    func chunksCarrySpans() throws {
        let source = transcript()
        let chunks = TranscriptIngest.chunks(of: source, chunker: Chunker(maxTokens: 24,
                                                                          overlapTokens: 4))
        #expect(chunks.count > 1, "the fixture should split, or this proves nothing")
        for (chunk, provenance) in chunks {
            #expect(provenance.documentID == source.id)
            let span = try #require(provenance.passage,
                                    "a chunk sliced from the source can always be located")
            #expect(span.slice(of: source.text) == chunk.text)
        }
    }

    @Test("chunks are located in order, so a repeated sentence does not collapse onto one span")
    func repeatedTextGetsDistinctSpans() throws {
        var repetitive = transcript()
        repetitive.text = ["ทำไม่ทันค่ะ", "อย่างอื่นก็มี", "ทำไม่ทันค่ะ"].joined(separator: "\n")
        let chunks = TranscriptIngest.chunks(of: repetitive,
                                             chunker: Chunker(maxTokens: 6, overlapTokens: 1))
        let spans = chunks.compactMap { $0.1.passage?.start }
        #expect(spans == spans.sorted(), "each chunk is found after the one before it")
        #expect(Set(spans).count == spans.count, "two chunks must not share a start")
    }

    @Test("the same chunker as the rest of the index, not a second splitter")
    func usesTheSharedChunker() {
        let source = transcript()
        let chunker = Chunker(maxTokens: 24, overlapTokens: 4)
        let direct = chunker.chunks(of: source.text)
        let ingested = TranscriptIngest.chunks(of: source, chunker: chunker)
        // Identical bodies: a transcript split differently from everything else
        // in the project would retrieve differently, which is what
        // `Chunker.version` exists to prevent.
        #expect(direct.map(\.text) == ingested.map { $0.0.text })
    }
}

// ─────────────────────────────────────────────────────────────
// P11.8's remaining half: the transcript actually going in.
//
// `TranscriptIngest.chunks` and its three tests above were finished long
// before anything called them, so the promise "a retrieved chunk cites the
// passage" was true about a function and false about the app. These are about
// the path from that function into a real index.
// ─────────────────────────────────────────────────────────────

@Suite("a transcript indexed like everything else")
struct TranscriptIndexingTests {

    private func ingest(_ source: Transcript, into index: inout KnowledgeIndex) async throws
        -> IngestionReport {
        let chunks = TranscriptIngest.chunks(of: source, chunker: Chunker(maxTokens: 24,
                                                                          overlapTokens: 4))
            .map { (chunk: $0.0, provenance: $0.1) }
        return try await IngestionPipeline().ingest(chunks: chunks, into: &index,
                                                    scope: .project(ProjectID("pj_q")),
                                                    documentID: source.id)
    }

    // The claim P11.8 makes to a reader: a hit in the knowledge base can be
    // followed back to the characters the participant said, not to the
    // two-hour interview.
    @Test("an indexed chunk can be cited back to its own passage in the transcript")
    func indexedChunksStayCitable() async throws {
        let source = transcript()
        var index = KnowledgeIndex()
        let report = try await ingest(source, into: &index)

        #expect(report.chunksAdded > 1)
        for chunk in index.allChunks {
            let span = try #require(chunk.provenance.passage)
            #expect(span.slice(of: source.text) == chunk.text,
                    "a chunk in the index no longer resolves to the passage it came from")
        }
    }

    // A transcript keeps its id when it is corrected, so a second ingest is the
    // same interview said better. Keeping both would leave the library holding
    // a retracted sentence and the corrected one with nothing to choose
    // between them.
    @Test("re-ingesting a corrected transcript replaces it rather than keeping both versions")
    func correctionReplaces() async throws {
        var source = transcript()
        var index = KnowledgeIndex()
        _ = try await ingest(source, into: &index)

        source.text = source.text.replacingOccurrences(of: "สิบสองเตียง", with: "สิบสี่เตียง")
        let second = try await ingest(source, into: &index)

        #expect(second.chunksReplaced > 0, "the old version was left in the index")
        let texts = index.allChunks.map(\.text).joined()
        #expect(texts.contains("สิบสี่เตียง"))
        #expect(texts.contains("สิบสองเตียง") == false,
                "the retracted wording is still in the knowledge base")
    }

    // Every chunk of an interview is primary data. Reading it on the scale
    // built for published sources would let the corroboration rule treat it
    // like a journal article (§11.3's reason, unchanged here).
    @Test("indexed transcript chunks carry no source tier")
    func noTierOnPrimaryData() async throws {
        var index = KnowledgeIndex()
        _ = try await ingest(transcript(), into: &index)
        #expect(index.allChunks.allSatisfy { $0.provenance.tier == nil })
        #expect(index.allChunks.allSatisfy { $0.scope == .project(ProjectID("pj_q")) })
    }

    @Test("ingesting the identical transcript twice adds nothing the second time")
    func idempotentWithoutChanges() async throws {
        let source = transcript()
        var index = KnowledgeIndex()
        let first = try await ingest(source, into: &index)
        let second = try await ingest(source, into: &index)

        #expect(second.chunksAdded == first.chunksAdded,
                "a re-ingest with no change should rebuild the same chunks")
        #expect(index.allChunks.count == first.chunksAdded, "the index doubled")
    }
}
