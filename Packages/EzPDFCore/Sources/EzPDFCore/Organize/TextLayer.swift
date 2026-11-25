import Foundation
import PDFKit
import CoreText

/// Gives scanned pages a text layer: each page with no real text is read on this Mac
/// (`PageText.ocrFragments`, Vision) and redrawn with the words as invisible text over where they
/// appear, so the page can be searched, selected and copied. The page's own content is drawn as is
/// (vector, not rasterized); its annotations, links and rotation carry over.
///
/// PDFKit's `saveTextFromOCROption` was used before and writes no text at all, so this does it
/// itself.
public enum TextLayer {
    /// A page "has text" once its text layer holds this many words.
    static let minWords = 5

    /// Adds a text layer to the pages in `pages` (all when nil) that have none. Returns how many
    /// pages got one; `doc` is changed in place.
    @discardableResult
    public static func addToScannedPages(_ doc: PDFDocument, pages only: Set<Int>? = nil) async -> Int {
        var done = 0
        for i in 0..<doc.pageCount {
            if let only, !only.contains(i) { continue }
            guard let page = doc.page(at: i), PageText.words(page: page, index: i).count < minWords else { continue }
            let words = await PageText.ocrFragments(page: page, index: i)
            guard !words.isEmpty, let newPage = redraw(page, adding: words) else { continue }
            let crop = page.bounds(for: .cropBox)
            // The new page's space starts at (0, 0); the old crop box's origin may not.
            EditOps.replacePage(doc, at: i, old: page, with: newPage) { $0.bounds.offsetBy(dx: -crop.minX, dy: -crop.minY) }
            done += 1
        }
        return done
    }

    /// The page drawn into a new one-page PDF (crop box, unrotated, the rotation set back on the
    /// page) with `words` (top-left shown points) as invisible text on top.
    static func redraw(_ page: PDFPage, adding words: [TextFragment]) -> PDFPage? {
        let crop = page.bounds(for: .cropBox)
        let space = EditOps.PageSpace(page)
        let rotation = page.rotation
        // Annotations move to the new page as annotations; keep them out of the drawing so they
        // aren't doubled.
        let annotations = page.annotations
        for a in annotations { page.removeAnnotation(a) }
        defer { for a in annotations { page.addAnnotation(a) } }

        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: crop.size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        ctx.beginPDFPage(nil)
        page.rotation = 0
        ctx.saveGState()
        page.draw(with: .cropBox, to: ctx)       // puts the crop box's origin at (0, 0)
        ctx.restoreGState()
        page.rotation = rotation
        // Shown space (bottom-left origin) → the new page's space: back to the old page's space,
        // then less the crop origin. Words then run the way they read, whatever the rotation.
        ctx.concatenate(space.toPage.concatenating(CGAffineTransform(translationX: -crop.minX, y: -crop.minY)))
        ctx.setTextDrawingMode(.invisible)
        for w in words { draw(w.text, in: space.shownRect(w.rect), ctx) }
        ctx.endPDFPage()
        ctx.closePDF()
        guard let out = PDFDocument(data: data as Data), let newPage = out.page(at: 0) else { return nil }
        newPage.rotation = rotation
        return newPage
    }

    /// One word or line, sized to its box: the font from the box height, stretched to its width so
    /// selections line up with the ink.
    static func draw(_ text: String, in r: CGRect, _ ctx: CGContext) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, r.width > 0.5, r.height > 0.5, r.width.isFinite, r.height.isFinite else { return }
        let font = CTFontCreateWithName("Helvetica" as CFString, r.height * 0.8, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        guard width > 0 else { return }
        ctx.textMatrix = CGAffineTransform(scaleX: r.width / width, y: 1)
        ctx.textPosition = CGPoint(x: r.minX, y: r.minY + CTFontGetDescent(font))
        CTLineDraw(line, ctx)
    }
}
