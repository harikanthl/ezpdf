import Foundation
import PDFKit

/// Removes glyphs from a page's content stream. PDFKit has no API for this; the implementation is
/// chosen after the open-source survey (content-stream rewriting). Until then it reports that it
/// can't, and callers keep the visual edit.
enum ContentEditor {
    static func removeText(from page: PDFPage, in doc: PDFDocument, pageIndex: Int, rects: [CGRect]) throws {
        throw EzPDFError.unavailable("Removing the original text isn't available yet.")
    }
}
