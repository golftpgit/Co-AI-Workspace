import Testing
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import AgentKit
@testable import Knowledge

// ─────────────────────────────────────────────────────────────
// P2.3's Done-when: ingest a genuinely scanned file and find it afterwards;
// ingest it again and add nothing.
//
// "Scanned" here is not a fixture with a hidden text layer — the PDF is built
// by drawing Thai text into a bitmap and putting *that* into the page, so the
// only way any of it reaches the index is Vision OCR.
// ─────────────────────────────────────────────────────────────

private let scannedLines = [
    "รายงานการศึกษาผู้ป่วยเบาหวาน",
    "การให้อินซูลินร่วมกับยากิน",
    "ผลการรักษาในผู้สูงอายุ",
]

/// Draws the lines into a bitmap, then wraps the bitmap in a PDF page.
private func makeScannedPDF(at url: URL) throws {
    let width = 1_200, height = 900
    guard let bitmap = CGContext(data: nil, width: width, height: height,
                                 bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw CocoaError(.fileWriteUnknown) }

    bitmap.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // Thonburi ships with macOS and covers Thai; the system default does not
    // render it at all, which would make this an OCR test of empty paper.
    let font = CTFontCreateWithName("Thonburi" as CFString, 64, nil)
    for (index, line) in scannedLines.enumerated() {
        let attributed = NSAttributedString(string: line, attributes: [
            .font: font,
            .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ])
        let ctLine = CTLineCreateWithAttributedString(attributed)
        bitmap.textPosition = CGPoint(x: 80, y: CGFloat(height - 180 - index * 140))
        CTLineDraw(ctLine, bitmap)
    }

    guard let image = bitmap.makeImage() else { throw CocoaError(.fileWriteUnknown) }

    var box = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
    guard let consumer = CGDataConsumer(url: url as CFURL),
          let pdf = CGContext(consumer: consumer, mediaBox: &box, nil)
    else { throw CocoaError(.fileWriteUnknown) }
    pdf.beginPDFPage(nil)
    pdf.draw(image, in: box)
    pdf.endPDFPage()
    pdf.closePDF()
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("coai-ingest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// bge-m3 at 1024 dimensions is what P2.1 locked; the tests use whatever this
/// machine serves under that name and skip loudly when it is absent.
private let bgeProfile = EmbeddingProfile(modelID: "text-embedding-bge-m3",
                                          revision: "gguf-q8_0", dimensions: 1_024)

private func bgeEmbedder() async -> RemoteEmbedder? {
    let endpoint = URL(string: "http://127.0.0.1:1234/v1")!
    let embedder = RemoteEmbedder(baseURL: endpoint, model: "text-embedding-bge-m3",
                                  profile: bgeProfile)
    return await embedder.isReachable() ? embedder : nil
}

private extension RemoteEmbedder {
    func isReachable() async -> Bool {
        (try? await embed("ping")) != nil
    }
}

@Suite("Ingestion", .serialized)
struct IngestionTests {
    @Test("a scanned page is read by OCR and can be found afterwards",
          .timeLimit(.minutes(3)))
    func scannedDocumentBecomesSearchable() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("scan.pdf")
        try makeScannedPDF(at: file)

        var index = KnowledgeIndex(profile: bgeProfile)
        let embedder = await bgeEmbedder()
        let report = try await IngestionPipeline().ingest(
            file, into: &index, scope: .central, tier: .t3, embedder: embedder)

        #expect(report.usedOCR, "the page had a text layer, so this proves nothing")
        #expect(report.chunksAdded > 0)

        // The Done-when: the words on the paper are findable.
        let hits = index.search("อินซูลิน", scope: .central)
        #expect(!hits.isEmpty, "indexed \(index.count) chunks but found none")
        #expect(hits.first?.provenance.tier == .t3)
        #expect(hits.first?.provenance.section == "OCR",
                "a citation of OCR text should say it is OCR text")

        // And findable through the vector half too, at the dimension P2.1
        // locked — otherwise this test passes on the lexical path alone and
        // says nothing about the embedder.
        guard let embedder else {
            Issue.record("skipped the vector half: no bge-m3 on :1234")
            return
        }
        let fused = try await index.search("การรักษาโรคเบาหวาน", scope: .central,
                                           embedder: embedder)
        #expect(!fused.isEmpty)
        #expect(fused.contains { $0.semanticRank != nil },
                "nothing ranked semantically, so the vectors were never used")
        #expect(fused.allSatisfy { ($0.chunk.embedding?.count ?? 0) == 1_024 })
    }

    @Test("ingesting the same document twice adds nothing", .timeLimit(.minutes(3)))
    func reingestionIsANoOp() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("scan.pdf")
        try makeScannedPDF(at: file)

        let embedder = await bgeEmbedder()
        var index = KnowledgeIndex(profile: bgeProfile)
        let pipeline = IngestionPipeline()

        let first = try await pipeline.ingest(file, into: &index, scope: .central,
                                              tier: .t3, embedder: embedder)
        let countAfterFirst = index.count
        let second = try await pipeline.ingest(file, into: &index, scope: .central,
                                               tier: .t3, embedder: embedder)

        #expect(first.chunksAdded > 0)
        #expect(second.chunksAdded == 0, "added \(second.chunksAdded) chunks on re-ingest")
        #expect(second.duplicatesSkipped == first.chunksAdded)
        #expect(index.count == countAfterFirst)
        // Same bytes, so the same document identity — not a second document
        // that happens to look alike.
        #expect(first.documentID == second.documentID)
    }

    @Test("a copy of the same file under another name is still one document")
    func contentAddressedIdentity() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("a.txt")
        let copy = directory.appendingPathComponent("b.txt")
        try "ผู้ป่วยเบาหวานชนิดที่ 2 ต้องปรับขนาดยา".write(to: original, atomically: true,
                                                            encoding: .utf8)
        try FileManager.default.copyItem(at: original, to: copy)

        #expect(IngestionPipeline.documentID(for: original)
                == IngestionPipeline.documentID(for: copy))
    }

    @Test("re-flowed text is recognised as the same content")
    func whitespaceIsNormalisedBeforeHashing() {
        let a = "ผู้ป่วยเบาหวาน   ต้องปรับขนาดยา"
        let b = "ผู้ป่วยเบาหวาน\nต้องปรับขนาดยา"
        #expect(IngestionPipeline.contentHash(a) == IngestionPipeline.contentHash(b))
        #expect(IngestionPipeline.contentHash(a) != IngestionPipeline.contentHash("อย่างอื่น"))
    }

    @Test("a plain text file keeps its provenance and scope")
    func plainTextIngestion() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("note.md")
        try "วัคซีนชนิด mRNA กระตุ้นภูมิคุ้มกันในผู้สูงอายุได้ดี".write(to: file, atomically: true,
                                                                        encoding: .utf8)

        var index = KnowledgeIndex(profile: bgeProfile)
        let report = try await IngestionPipeline().ingest(
            file, into: &index, scope: .project(ProjectID("vaccine")), tier: .t2)

        #expect(report.usedOCR == false)
        #expect(report.chunksAdded == 1)
        let hits = index.search("วัคซีน", scope: .project(ProjectID("vaccine")))
        #expect(hits.count == 1)
        #expect(hits.first?.provenance.tier == .t2)
        #expect(hits.first?.provenance.origin == .upload(filename: "note.md"))
        // Not visible from another scope.
        #expect(index.search("วัคซีน", scope: .central).isEmpty)
    }

    @Test("indexing is refused when the embedder cannot read the content")
    func refusesBlindEmbedder() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("note.txt")
        try "การให้อินซูลินในผู้ป่วยเบาหวาน".write(to: file, atomically: true, encoding: .utf8)

        var index = KnowledgeIndex(profile: bgeProfile)
        await #expect(throws: IngestionError.self) {
            _ = try await IngestionPipeline().ingest(file, into: &index, scope: .central,
                                                     tier: .t3, embedder: ThaiBlindStub())
        }
        #expect(index.count == 0, "chunks were indexed before the check ran")
    }

    @Test("an unreadable file fails with a legible error")
    func unsupportedType() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("thing.xyz")
        try Data("x".utf8).write(to: file)

        var index = KnowledgeIndex(profile: bgeProfile)
        await #expect(throws: IngestionError.self) {
            _ = try await IngestionPipeline().ingest(file, into: &index,
                                                     scope: .central, tier: .t3)
        }
    }
}

private struct ThaiBlindStub: Embedder {
    let identifier = "blind"
    let profile = EmbeddingProfile(modelID: "blind", revision: "test", dimensions: 4)
    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { text in
            text.unicodeScalars.contains { (0x0E00...0x0E7F).contains($0.value) }
                ? [0.5, 0.5, 0.5, 0.5]
                : [Float(text.count), 1, 0, 0]
        }
    }
}
