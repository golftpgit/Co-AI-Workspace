import Foundation
import PDFKit
import CoreGraphics
import ImageIO

// ─────────────────────────────────────────────────────────────
// Getting text out of what people actually have (ARCHITECTURE §11.4, P2.3):
// PDFs that are text, PDFs that are photographs of text, images, Office files.
//
// The interesting case is the third kind of PDF — the one with a text layer so
// thin it looks like a successful read and is really a page number and a
// header. Trusting it is how a scanned document ends up indexed as four words.
// ─────────────────────────────────────────────────────────────

public struct ReadDocument: Sendable {
    public let text: String
    /// Per page, in order — kept so provenance can cite a page (§11.3).
    public let pages: [String]
    /// True when any part of this document came from OCR rather than a text
    /// layer. Worth knowing: OCR text is a guess, and a citation should be
    /// able to say so.
    public let usedOCR: Bool
}

public enum DocumentReadError: Error, CustomStringConvertible, Equatable {
    case unreadable(String)
    case unsupported(String)
    case empty(String)

    public var description: String {
        switch self {
        case .unreadable(let m): return "cannot read: \(m)"
        case .unsupported(let m): return "unsupported document type: \(m)"
        case .empty(let m): return "no text found in \(m)"
        }
    }
}

public struct DocumentReader: Sendable {
    private let recognizer: TextRecognizer
    /// A page whose text layer is shorter than this is treated as scanned and
    /// sent to OCR anyway. Tuned to catch the "header and page number only"
    /// case without re-OCRing genuinely sparse pages like a title page.
    private let thinTextLayerThreshold: Int

    public init(recognizer: TextRecognizer = TextRecognizer(),
                thinTextLayerThreshold: Int = 24) {
        self.recognizer = recognizer
        self.thinTextLayerThreshold = thinTextLayerThreshold
    }

    public func read(_ url: URL) throws -> ReadDocument {
        switch url.pathExtension.lowercased() {
        case "pdf": return try readPDF(url)
        case "png", "jpg", "jpeg", "heic", "tiff", "gif", "bmp": return try readImage(url)
        case "docx", "pptx": return try readOfficeXML(url)
        case "txt", "md", "markdown", "csv", "json", "yaml", "yml": return try readPlainText(url)
        default: throw DocumentReadError.unsupported(url.lastPathComponent)
        }
    }

    // MARK: - plain text

    private func readPlainText(_ url: URL) throws -> ReadDocument {
        guard let data = try? Data(contentsOf: url) else {
            throw DocumentReadError.unreadable(url.lastPathComponent)
        }
        let text = String(decoding: data, as: UTF8.self)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocumentReadError.empty(url.lastPathComponent)
        }
        return ReadDocument(text: text, pages: [text], usedOCR: false)
    }

    // MARK: - PDF

    private func readPDF(_ url: URL) throws -> ReadDocument {
        guard let document = PDFDocument(url: url) else {
            throw DocumentReadError.unreadable(url.lastPathComponent)
        }

        var pages: [String] = []
        var usedOCR = false

        for number in 0..<document.pageCount {
            guard let page = document.page(at: number) else { continue }
            let layer = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            if layer.count >= thinTextLayerThreshold {
                pages.append(layer)
                continue
            }
            // Scanned, or as good as: rasterise and read it.
            if let image = render(page), let text = try? recognizer.recognize(image),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                usedOCR = true
                // Keep whichever is longer: OCR sometimes loses a header that
                // the thin layer had, and a page is cheap to over-index.
                pages.append(text.count >= layer.count ? text : layer)
            } else {
                pages.append(layer)
            }
        }

        let text = pages.joined(separator: "\n\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocumentReadError.empty(url.lastPathComponent)
        }
        return ReadDocument(text: text, pages: pages, usedOCR: usedOCR)
    }

    /// 2× so small type survives rasterisation — OCR accuracy falls off a
    /// cliff below roughly 20 pixels of cap height.
    private func render(_ page: PDFPage, scale: CGFloat = 2) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    // MARK: - images

    private func readImage(_ url: URL) throws -> ReadDocument {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw DocumentReadError.unreadable(url.lastPathComponent)
        }
        let text = try recognizer.recognize(image)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocumentReadError.empty(url.lastPathComponent)
        }
        return ReadDocument(text: text, pages: [text], usedOCR: true)
    }

    // MARK: - Office

    /// `.docx` and `.pptx` are zip archives of XML. Unzipped with the system
    /// tool rather than a dependency: it is already on every Mac, and the
    /// alternative is a third-party archive library for two file formats.
    private func readOfficeXML(_ url: URL) throws -> ReadDocument {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("coai-office-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-qq", url.path, "-d", directory.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        do {
            try unzip.run()
            unzip.waitUntilExit()
        } catch {
            throw DocumentReadError.unreadable("\(url.lastPathComponent): \(error)")
        }
        guard unzip.terminationStatus == 0 else {
            throw DocumentReadError.unreadable("\(url.lastPathComponent): not a valid archive")
        }

        // Word keeps the body in one part; PowerPoint keeps one part per slide,
        // and slide order is the numeric order of those file names.
        let parts: [URL]
        if url.pathExtension.lowercased() == "docx" {
            parts = [directory.appendingPathComponent("word/document.xml")]
        } else {
            let slides = directory.appendingPathComponent("ppt/slides")
            parts = ((try? FileManager.default.contentsOfDirectory(at: slides,
                                                                   includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.lowercased() == "xml" }
                .sorted { slideNumber($0) < slideNumber($1) }
        }

        let pages = parts.compactMap { part -> String? in
            guard let data = try? Data(contentsOf: part) else { return nil }
            let text = OfficeTextExtractor().text(fromXML: data)
            return text.isEmpty ? nil : text
        }

        let text = pages.joined(separator: "\n\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocumentReadError.empty(url.lastPathComponent)
        }
        return ReadDocument(text: text, pages: pages, usedOCR: false)
    }

    private func slideNumber(_ url: URL) -> Int {
        Int(url.deletingPathExtension().lastPathComponent
            .filter(\.isNumber)) ?? 0
    }
}

/// Pulls the runs of text out of an OOXML part. `<w:t>` is Word's text run and
/// `<a:t>` is the shared drawing one PowerPoint uses; everything else in the
/// file is formatting.
private final class OfficeTextExtractor: NSObject, XMLParserDelegate {
    private var pieces: [String] = []
    private var capturing = false
    private var isParagraphBoundary = false

    func text(fromXML data: Data) -> String {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return pieces.joined()
            .replacingOccurrences(of: "\n ", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        switch element {
        case "t": capturing = true
        case "p": isParagraphBoundary = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard capturing else { return }
        if isParagraphBoundary, !pieces.isEmpty { pieces.append("\n") }
        isParagraphBoundary = false
        pieces.append(string)
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        if element == "t" { capturing = false }
    }
}
