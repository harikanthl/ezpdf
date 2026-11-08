import Foundation
import PDFKit
import WebKit

/// Turns a laid-out web view into fixed-size PDF pages: measures every line/image/row,
/// picks safe page breaks (Paginator), captures each slice as vector PDF, places the slices
/// on pages with margins, and adds a clickable outline from the headings.
@MainActor
enum PageLayout {
    struct Metadata {
        var title: String
        var author: String?
        var subject: String?
    }

    struct Heading: Decodable { let top: Double; let level: Int; let text: String }
    private struct Measure: Decodable { let height: Double; let boxes: [[Double]]; let headings: [Heading] }

    static let measureJS = """
    const sy = window.scrollY || 0;
    const boxes = [];
    const add = (r, k) => { if (r.height > 0.5 && r.width > 0.5) boxes.push([r.top + sy - 1, r.bottom + sy + 1, k]); };
    document.querySelectorAll('img,svg,video,canvas,picture,math,tr,iframe,hr,.ez-atomic,[data-field]').forEach(e => {
      const tag = e.tagName.toLowerCase();
      if (tag !== 'svg' && e.closest('svg')) return;
      if (tag !== 'math' && e.closest('math')) return;
      add(e.getBoundingClientRect(), 0);
    });
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
    const range = document.createRange();
    let n, count = 0;
    while ((n = walker.nextNode()) && count < 80000) {
      if (!n.nodeValue || !n.nodeValue.trim()) continue;
      const p = n.parentElement;
      if (p && p.closest('math,svg')) continue;
      range.selectNodeContents(n);
      const rects = range.getClientRects();
      for (let i = 0; i < rects.length; i++) { add(rects[i], 1); count++; }
    }
    const headings = [];
    document.querySelectorAll('h1,h2,h3,h4').forEach(h => {
      const r = h.getBoundingClientRect();
      if (r.height < 1) return;
      const t = (h.innerText || '').trim().replace(/\\s+/g, ' ');
      if (!t) return;
      add(r, 2);
      if (h.classList.contains('ez-title')) return;
      headings.push({ top: r.top + sy, level: +h.tagName[1], text: t.slice(0, 160) });
    });
    const height = Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0);
    return JSON.stringify({ height, boxes, headings });
    """

    /// Longest document we'll paginate (about 250 Kindle pages); beyond this the rest is cut.
    static let maxContentHeight: Double = 150_000

    /// Renders the session's page into fixed-size PDF pages. Each slice is drawn into the output
    /// as soon as it's captured and then dropped, so memory stays flat on long documents.
    /// `truncated` is true when the content was longer than ezpdf keeps.
    static func renderPDF(session: WebSession, pageSize: CGSize, margin: CGFloat,
                          contentWidth: CGFloat, metadata: Metadata) async throws -> (pdf: Data, truncated: Bool, slices: [Range<Double>]) {
        let json = try await session.jsString(measureJS, timeout: 60)
        guard let measure = try? JSONDecoder().decode(Measure.self, from: Data(json.utf8)), measure.height.isFinite, measure.height > 0 else {
            throw EzPDFError.failed("Couldn't measure the page layout.")
        }
        let truncated = measure.height > maxContentHeight
        let contentHeight = min(measure.height, maxContentHeight)
        let boxes = measure.boxes.compactMap { b -> Paginator.Box? in
            guard b.count == 3, b[0].isFinite, b[1].isFinite, let kind = Paginator.Box.Kind(rawValue: Int(b[2])) else { return nil }
            return Paginator.Box(top: b[0], bottom: b[1], kind: kind)
        }
        let pageContentHeight = Double(pageSize.height - margin * 2)
        let slices = Paginator.slices(contentHeight: contentHeight, pageHeight: pageContentHeight, boxes: boxes)
        guard !slices.isEmpty else { throw EzPDFError.failed("The page has no content to print.") }

        let writer = try PageWriter(pageSize: pageSize, margin: margin)
        for s in slices {
            let rect = CGRect(x: 0, y: s.lowerBound, width: Double(contentWidth), height: s.upperBound - s.lowerBound)
            let slice = try await session.pdf(rect: rect)
            writer.draw(slice)
        }
        let composed = writer.finish()
        return (finish(composed, slices: slices, headings: measure.headings, pageSize: pageSize,
                       margin: margin, metadata: metadata), truncated, slices)
    }

    /// Streams slices onto pages of one PDF.
    final class PageWriter {
        let out = NSMutableData()
        let ctx: CGContext
        let pageSize: CGSize
        let margin: CGFloat

        init(pageSize: CGSize, margin: CGFloat) throws {
            self.pageSize = pageSize
            self.margin = margin
            var mediaBox = CGRect(origin: .zero, size: pageSize)
            guard let consumer = CGDataConsumer(data: out as CFMutableData),
                  let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
                throw EzPDFError.failed("Couldn't create the PDF.")
            }
            self.ctx = ctx
        }

        func draw(_ data: Data) {
            ctx.beginPDFPage(nil)
            if let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider), let page = doc.page(at: 1) {
                let r = page.getBoxRect(.mediaBox)
                let available = pageSize.width - margin * 2
                let scale = r.width > available ? available / r.width : 1
                ctx.saveGState()
                ctx.translateBy(x: margin, y: pageSize.height - margin - r.height * scale)
                ctx.scaleBy(x: scale, y: scale)
                ctx.translateBy(x: -r.minX, y: -r.minY)
                ctx.drawPDFPage(page)
                ctx.restoreGState()
            }
            ctx.endPDFPage()
        }

        func finish() -> Data {
            ctx.closePDF()
            return out as Data
        }
    }

    /// Draws each captured slice at the top of a fixed-size page. Vector content and
    /// selectable text survive because the slices are drawn as PDF, not rasterized.
    nonisolated static func compose(slices: [Data], pageSize: CGSize, margin: CGFloat) throws -> Data {
        let out = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw EzPDFError.failed("Couldn't create the PDF.")
        }
        let available = pageSize.width - margin * 2
        for data in slices {
            ctx.beginPDFPage(nil)
            if let provider = CGDataProvider(data: data as CFData),
               let doc = CGPDFDocument(provider), let page = doc.page(at: 1) {
                let r = page.getBoxRect(.mediaBox)
                let scale = r.width > available ? available / r.width : 1
                ctx.saveGState()
                ctx.translateBy(x: margin, y: pageSize.height - margin - r.height * scale)
                ctx.scaleBy(x: scale, y: scale)
                ctx.translateBy(x: -r.minX, y: -r.minY)
                ctx.drawPDFPage(page)
                ctx.restoreGState()
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return out as Data
    }

    /// Adds the heading outline (a clickable table of contents) and document info.
    static func finish(_ data: Data, slices: [Range<Double>], headings: [Heading], pageSize: CGSize,
                       margin: CGFloat, metadata: Metadata) -> Data {
        guard let doc = PDFDocument(data: data) else { return data }
        var attrs: [PDFDocumentAttribute: Any] = [
            .titleAttribute: metadata.title,
            .creatorAttribute: "ezpdf",
            .producerAttribute: "ezpdf",
        ]
        if let a = metadata.author, !a.isEmpty { attrs[.authorAttribute] = a }
        if let s = metadata.subject, !s.isEmpty { attrs[.subjectAttribute] = s }
        doc.documentAttributes = attrs

        if headings.count >= 2 {
            let root = PDFOutline()
            let minLevel = headings.map(\.level).min() ?? 1
            var stack: [(level: Int, node: PDFOutline)] = [(minLevel - 1, root)]
            for h in headings {
                guard let index = slices.firstIndex(where: { $0.contains(max(h.top, 0)) }),
                      let page = doc.page(at: index) else { continue }
                let y = h.top - slices[index].lowerBound
                let point = CGPoint(x: margin, y: pageSize.height - margin - CGFloat(y) + 4)
                let item = PDFOutline()
                item.label = h.text
                item.destination = PDFDestination(page: page, at: point)
                while let last = stack.last, last.level >= h.level, stack.count > 1 { stack.removeLast() }
                let parent = stack.last!.node
                parent.insertChild(item, at: parent.numberOfChildren)
                stack.append((h.level, item))
            }
            if root.numberOfChildren > 0 { doc.outlineRoot = root }
        }
        return doc.dataRepresentation() ?? data
    }
}
