import Foundation
import PDFKit
import Vision

/// A run of text with its position on the page (points, origin top-left).
public struct TextFragment: Sendable, Hashable {
    public var text: String
    public var rect: CGRect
    public var page: Int
}

/// One visual line: fragments merged into cells wherever the gap is word-sized, split where it's
/// column-sized. This is the shared input for statements, invoices and tables.
public struct TextLine: Sendable {
    public var page: Int
    public var y: CGFloat
    public var height: CGFloat
    public var cells: [TextFragment]
    public var text: String { cells.map(\.text).joined(separator: " ") }
}

public enum PageText {
    /// Lines for the whole document. Pages with no text layer are read with on-device OCR.
    public static func lines(_ doc: PDFDocument, maxPages: Int = 200, ocr: Bool = true) async -> [TextLine] {
        var out: [TextLine] = []
        for i in 0..<min(doc.pageCount, maxPages) {
            guard let page = doc.page(at: i) else { continue }
            var frags = words(page: page, index: i)
            if frags.count < 5, ocr { frags = await ocrFragments(page: page, index: i) }
            out.append(contentsOf: group(frags))
        }
        return out
    }

    /// Words from the PDF's text layer. Uses a selection per word: `characterBounds(at:)` can drift
    /// by a character or two from `page.string` indices, while `selection(for:)` stays exact.
    static let wordPattern = try! NSRegularExpression(pattern: #"\S+"#)

    static func words(page: PDFPage, index: Int) -> [TextFragment] {
        guard let str = page.string, !str.isEmpty else { return [] }
        let ns = str as NSString
        let box = page.bounds(for: .cropBox)
        var out: [TextFragment] = []
        for m in wordPattern.matches(in: str, range: NSRange(location: 0, length: ns.length)) {
            guard let sel = page.selection(for: m.range) else { continue }
            let r = sel.bounds(for: page)
            guard !r.isEmpty, r.width.isFinite else { continue }
            let flipped = CGRect(x: r.minX - box.minX, y: box.maxY - r.maxY, width: r.width, height: r.height)
            out.append(TextFragment(text: ns.substring(with: m.range), rect: flipped, page: index))
        }
        return out
    }

    /// On-device OCR (Vision) for scanned pages. Each recognized text run becomes a fragment.
    static func ocrFragments(page: PDFPage, index: Int) async -> [TextFragment] {
        let bounds = page.bounds(for: .cropBox)
        let scale: CGFloat = 2.5
        guard let image = PDFRaster.cgImage(page, scale: scale) else { return [] }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        guard let observations = try? await request.perform(on: image) else { return [] }
        let w = bounds.width, h = bounds.height
        return observations.compactMap { obs in
            guard let text = obs.topCandidates(1).first?.string, !text.isEmpty else { return nil }
            let n = obs.boundingBox.cgRect      // normalized, origin lower-left
            let r = CGRect(x: n.minX * w, y: (1 - n.maxY) * h, width: n.width * w, height: n.height * h)
            return TextFragment(text: text, rect: r, page: index)
        }
    }

    /// Groups fragments into lines (by vertical overlap) and merges word-gap neighbours into cells.
    static func group(_ frags: [TextFragment]) -> [TextLine] {
        let sorted = frags.sorted { $0.rect.midY < $1.rect.midY }
        var lines: [[TextFragment]] = []
        for f in sorted {
            if let last = lines.last, let ref = last.first {
                let h = max(ref.rect.height, f.rect.height)
                let lineMid = last.map(\.rect.midY).reduce(0, +) / CGFloat(last.count)
                if abs(f.rect.midY - lineMid) < h * 0.45 { lines[lines.count - 1].append(f); continue }
            }
            lines.append([f])
        }
        return lines.map { raw in
            let byX = raw.sorted { $0.rect.minX < $1.rect.minX }
            let h = byX.map(\.rect.height).sorted()[byX.count / 2]
            var cells: [TextFragment] = []
            for f in byX {
                if var last = cells.last, f.rect.minX - last.rect.maxX < h * 0.6 {
                    last.text += " " + f.text
                    last.rect = last.rect.union(f.rect)
                    cells[cells.count - 1] = last
                } else {
                    cells.append(f)
                }
            }
            let y = byX.map(\.rect.minY).min() ?? 0
            return TextLine(page: raw[0].page, y: y, height: h, cells: cells)
        }
    }
}
