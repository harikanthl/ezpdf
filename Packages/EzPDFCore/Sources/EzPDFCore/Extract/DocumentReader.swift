import Foundation
import PDFKit
import Vision

/// Apple's document reader (Vision `RecognizeDocumentsRequest`, macOS 26) on a page as shown: its
/// text in reading order (paragraphs), its words with positions, and its tables as rows and
/// columns, whether or not the table has drawn lines. Runs on this Mac.
///
/// Coordinates are top-left points of the page as shown (`EditOps.PageSpace`).
public enum DocumentReader {
    public struct Cell: Sendable, Hashable {
        public var rows: ClosedRange<Int>
        public var columns: ClosedRange<Int>
        public var rect: CGRect
        public var text: String
    }

    public struct Table: Sendable {
        public var rect: CGRect
        public var rowCount: Int
        public var columnCount: Int
        public var cells: [Cell]

        /// The table as a grid of strings (a spanning cell's text goes in its first row and column).
        public var grid: [[String]] {
            var g = Array(repeating: Array(repeating: "", count: columnCount), count: rowCount)
            for c in cells where c.rows.lowerBound < rowCount && c.columns.lowerBound < columnCount {
                g[c.rows.lowerBound][c.columns.lowerBound] = c.text
            }
            return g
        }
    }

    public struct Paragraph: Sendable {
        public var rect: CGRect
        public var text: String
    }

    public struct Page: Sendable {
        public var index: Int
        public var size: CGSize
        public var title: String?
        public var paragraphs: [Paragraph]
        public var tables: [Table]
        /// Every word with its box (for OCR'd pages).
        public var words: [TextFragment]

        /// The page's text in reading order, a blank line between paragraphs.
        public var text: String { paragraphs.map(\.text).joined(separator: "\n\n") }
    }

    /// Reads one page. `scale` is the render size per point (2.5 reads small print well).
    public static func read(page: PDFPage, index: Int, scale: CGFloat = 2.5) async throws -> Page {
        let size = EditOps.PageSpace(page).size
        guard let image = PDFRaster.cgImage(page, scale: scale) else { throw EzPDFError.failed("Couldn't render page \(index + 1).") }
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.useLanguageCorrection = false
        request.barcodeDetectionOptions.enabled = false
        let observations = try await request.perform(on: image, orientation: nil)
        func shown(_ n: NormalizedRect) -> CGRect {
            let r = n.cgRect                        // normalized, origin lower-left
            return CGRect(x: r.minX * size.width, y: (1 - r.maxY) * size.height, width: r.width * size.width, height: r.height * size.height)
        }
        var out = Page(index: index, size: size, title: nil, paragraphs: [], tables: [], words: [])
        for o in observations {
            let d = o.document
            if out.title == nil { out.title = d.title?.transcript }
            out.paragraphs += d.paragraphs.map { Paragraph(rect: shown($0.boundingRegion.boundingBox), text: $0.transcript) }
            out.tables += d.tables.map { t in
                Table(rect: shown(t.boundingRegion.boundingBox), rowCount: t.rows.count, columnCount: t.columns.count,
                      cells: t.rows.flatMap { $0 }.map { c in
                          Cell(rows: c.rowRange, columns: c.columnRange,
                               rect: shown(c.content.boundingRegion.boundingBox), text: c.content.text.transcript)
                      })
            }
            let pieces = d.text.words ?? d.text.lines
            out.words += pieces.compactMap { w in
                guard let s = w.topCandidates(1).first?.string, !s.isEmpty else { return nil }
                return TextFragment(text: s, rect: shown(w.boundingBox), page: index)
            }
        }
        // Each cell once (a spanning cell shows up in every row and column it covers).
        for i in out.tables.indices {
            var seen = Set<String>()
            out.tables[i].cells = out.tables[i].cells.filter { seen.insert("\($0.rows)|\($0.columns)").inserted }
        }
        return out
    }
}
