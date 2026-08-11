import Foundation
import Vision
import CoreGraphics

// ─────────────────────────────────────────────────────────────
// OCR for the scanned half of a knowledge base (ARCHITECTURE §11, P2.3).
//
// Verified on this machine: Vision recognises Thai (`th-TH`) at
// `.accurate` only — the `.fast` path supports six Latin-script languages and
// nothing else. For a Thai research library that makes `.accurate` the only
// usable setting, not a quality preference.
// ─────────────────────────────────────────────────────────────

public struct TextRecognizer: Sendable {
    /// Order matters to Vision: it biases towards the earlier languages.
    public let languages: [String]

    public init(languages: [String] = ["th-TH", "en-US"]) {
        self.languages = languages
    }

    /// Languages this machine can actually recognise, so a caller can say
    /// "Thai OCR is unavailable here" instead of returning empty pages.
    public static var supportedLanguages: [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages()) ?? []
    }

    public func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages

        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        let observations = request.results ?? []
        // Reading order: top to bottom. Vision's origin is bottom-left, so the
        // sort is descending — getting this backwards silently reverses every
        // scanned page.
        return observations
            .sorted { $0.boundingBox.origin.y > $1.boundingBox.origin.y }
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
