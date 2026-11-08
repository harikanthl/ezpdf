import Testing
import Foundation
import PDFKit
@testable import EzPDFCore

/// Renders a page to RGBA at 2× for comparing what it looks like.
private func pixels(_ page: CGPDFPage, _ box: CGRect) -> [UInt8] {
    let w = Int(box.width * 2), h = Int(box.height * 2)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.scaleBy(x: 2, y: 2); ctx.translateBy(x: -box.minX, y: -box.minY)
    ctx.drawPDFPage(page)
    return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: w * h * 4))
}

/// Pixels that differ, inside and outside `area` (page space).
private func changedPixels(_ a: CGPDFPage, _ b: CGPDFPage, box: CGRect, area: CGRect) -> (inside: Int, outside: Int) {
    let pa = pixels(a, box), pb = pixels(b, box)
    let w = Int(box.width * 2), h = Int(box.height * 2)
    var inside = 0, outside = 0
    for k in stride(from: 0, to: pa.count, by: 4) where abs(Int(pa[k]) - Int(pb[k])) > 40 || abs(Int(pa[k + 2]) - Int(pb[k + 2])) > 40 {
        let x = box.minX + CGFloat((k / 4) % w) / 2, y = box.minY + CGFloat(h - 1 - (k / 4) / w) / 2
        if area.insetBy(dx: -2, dy: -2).contains(CGPoint(x: x, y: y)) { inside += 1 } else { outside += 1 }
    }
    return (inside, outside)
}

@Suite struct TextEraserTests {
    @Test func takesOutOnlyTheWordAndMovesNothing() throws {
        let doc = PDFDocument(data: makePDF(pages: 1, fonts: ["Helvetica", "Times-Roman"],
                                            lines: { _ in ["Due date: October 14, 2026, by bank transfer.", "Thank you for your business."] }))!
        let page = doc.page(at: 0)!
        let word = try #require(doc.findString("October 14", withOptions: []).first)
        let area = word.bounds(for: page).insetBy(dx: -1, dy: -1)
        let r = try #require(TextEraser.erase(page.pageRef!, rects: [area]))
        #expect(r.removed == 10)
        let out = try #require(PDFDocument(data: r.data)?.page(at: 0))
        let text = out.string ?? ""
        #expect(!text.contains("October 14"))
        #expect(text.contains("Due date:"))
        #expect(text.contains("2026, by bank transfer."))
        #expect(text.contains("Thank you for your business."))
        let diff = changedPixels(page.pageRef!, out.pageRef!, box: page.bounds(for: .mediaBox), area: area)
        #expect(diff.inside > 0)
        #expect(diff.outside == 0)
    }

    /// After one edit the page's old content sits inside a form XObject; a second edit must reach into it.
    @Test func reachesIntoFormsFromEarlierEdits() throws {
        let doc = PDFDocument(data: makePDF(pages: 1, lines: { _ in ["Alpha beta gamma delta"] }))!
        try EditOps.compose(doc, page: 0, overlays: [.text("Note", rect: CGRect(x: 400, y: 600, width: 80, height: 20), font: .systemFont(ofSize: 10), color: .black, alignment: .left)])
        let page = doc.page(at: 0)!
        let word = try #require(doc.findString("gamma", withOptions: []).first)
        let r = try #require(TextEraser.erase(page.pageRef!, rects: [word.bounds(for: page)]))
        #expect(r.removed == 5)
        let text = PDFDocument(data: r.data)?.page(at: 0)?.string ?? ""
        #expect(!text.contains("gamma"))
        #expect(text.contains("Alpha beta"))
        #expect(text.contains("delta"))
        #expect(text.contains("Note"))
    }

    /// Replacement text for accessibility (/ActualText) would still read as the removed words.
    @Test func dropsActualTextOverRemovedGlyphs() throws {
        let content = "BT /F1 18 Tf 72 700 Td /Span <</ActualText (Secret)>> BDC (Secret) Tj EMC ( stays) Tj ET"
        let pdf = rawPDF(content: content)
        let doc = try #require(PDFDocument(data: pdf))
        let page = doc.page(at: 0)!
        #expect((page.string ?? "").contains("Secret"))
        let word = try #require(doc.findString("Secret", withOptions: []).first)
        let r = try #require(TextEraser.erase(page.pageRef!, rects: [word.bounds(for: page).insetBy(dx: -1, dy: -1)]))
        let text = PDFDocument(data: r.data)?.page(at: 0)?.string ?? ""
        #expect(!text.contains("Secret"))
        #expect(text.contains("stays"))
    }

    /// Text used as a clipping path can't be taken out without changing what the clip shows.
    @Test func leavesClippingTextAlone() throws {
        let pdf = rawPDF(content: "BT /F1 18 Tf 7 Tr 72 700 Td (Clip) Tj ET 0 0 612 792 re f")
        let doc = try #require(PDFDocument(data: pdf))
        let page = doc.page(at: 0)!
        #expect(TextEraser.erase(page.pageRef!, rects: [CGRect(x: 60, y: 690, width: 100, height: 30)]) == nil)
    }

    /// A one-page PDF with Helvetica (no Widths: measured with the Mac's copy) and the given content.
    private func rawPDF(content: String) -> Data {
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]
        objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
        var out = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (i, o) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(i + 1) 0 obj\n\(o)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n" + offsets.map { String(format: "%010d 00000 n \n", $0) }.joined()
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(out.utf8)
    }
}

@Suite struct CleanEditTests {
    /// Changing the same words twice: the text layer holds only what the page shows.
    @Test func editingTwiceLeavesNoHiddenWords() throws {
        let doc = PDFDocument(data: makePDF(pages: 1, lines: { _ in ["\"MoE\" redirects here. For other uses, see Moe."] }))!
        try EditOps.replaceText(doc, find: "redirects", with: "redirect", wholeWord: true)
        try EditOps.replaceText(doc, find: "redirect", with: "redirected", wholeWord: true)
        let text = (reload(doc).page(at: 0)?.string ?? "").replacingOccurrences(of: "\n", with: " ")
        #expect(text.components(separatedBy: "redirect").count == 2, "one “redirect…” only: \(text)")
        #expect(text.contains("redirected"))
        #expect(!text.contains("redirects"))
        #expect(text.contains("For other uses"))
    }

    /// A longer word at the end of a full line starts the next line instead of failing.
    @Test func wordAtLineEndMovesToTheNextLine() throws {
        let lines = ["The quick brown fox jumps over the lazy dog and keeps running far away",
                     "into the hills where nobody can follow it any longer than this line goes",
                     "and the story ends here."]
        let doc = PDFDocument(data: makePDF(pages: 1, size: CGSize(width: 612, height: 792), lines: { _ in lines }))!
        let changes = try EditOps.replaceText(doc, find: "away", with: "awaaaaaaaay", wholeWord: true)
        #expect(changes.count == 1)
        #expect((reload(doc).page(at: 0)?.string ?? "").contains("awaaaaaaaay"))
    }
}

@Suite struct ArticleEditTests {
    @Test func changesTextNotTags() {
        let html = #"<p class="Moe">See <a href="https://x.org/Moe" title="Moe">Moe</a>. Moe again, and Moes.</p>"#
        let (out, n) = ArticleEdit.replace(in: html, find: "Moe", with: "Moe (disambiguation)")
        #expect(n == 2)
        #expect(out.contains(#"href="https://x.org/Moe""#))
        #expect(out.contains(#"class="Moe""#))
        #expect(out.contains(">Moe (disambiguation)</a>"))
        #expect(out.contains("Moe (disambiguation) again"))
        #expect(out.contains("Moes."))
    }

    @Test func contextPicksOnePlace() {
        let html = "<p>the cat sat. a cat ran. the cat sat again.</p>"
        let (out, n) = ArticleEdit.replace(in: html, find: "cat", with: "dog", context: .init(before: "a", after: "ran."))
        #expect(n == 1)
        #expect(out == "<p>the cat sat. a dog ran. the cat sat again.</p>")
    }

    @Test func escapesAndSpaces() {
        let html = "<p>Fish&nbsp;&amp; chips &lt;3</p>"
        let (out, n) = ArticleEdit.replace(in: html, find: "Fish & chips", with: "Tea & cake")
        #expect(n == 1)
        #expect(out == "<p>Tea &amp; cake &lt;3</p>")
    }
}

@MainActor @Suite struct ReflowTests {
    /// A change too long for its line, made in the article: the article is laid out again, and
    /// Undo/Redo keep the PDF and its article in step for the next reflow.
    @Test func reflowsAndStaysInStepWithUndo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ezpdf-reflow-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ops = EzPDF(library: Library(root: root))
        let body = "<p>\"MoE\" redirects here. For other uses, see Moe.</p><p>" + String(repeating: "Mixture of experts is a technique. ", count: 30) + "</p>"
        let source = URL(string: "https://example.org/moe")!
        let article = WebConverter.Article(title: "MoE", byline: nil, siteName: nil, excerpt: nil, publishedTime: nil, lang: "en",
                                           html: body, textLength: body.count, sourceURL: source)
        let first = try await WebConverter.renderArticle(article, preset: .kindle)
        let rec = try ops.library.add(DocumentRecord(title: "MoE", kind: .web, sourceURL: source.absoluteString, preset: "kindle"),
                                      pdfData: first.pdf, articleHTML: body)
        #expect(ops.canReflow(rec.id))
        #expect(try ops.pageChangesSinceLayout(rec.id).isEmpty)

        try await ops.reflowArticle(rec.id, find: "Moe", with: "Moe (disambiguation)")
        func text() -> String { (PDFDocument(url: ops.library.pdfURL(for: rec.id))?.page(at: 0)?.string ?? "").replacingOccurrences(of: "\n", with: " ") }
        #expect(text().contains("Moe (disambiguation)"))
        #expect(try ops.pageChangesSinceLayout(rec.id).isEmpty)

        try ops.undo(rec.id)
        #expect(!text().contains("disambiguation"))
        // From the undone version a reflow starts from the original article.
        try await ops.reflowArticle(rec.id, find: "redirects", with: "redirected")
        #expect(text().contains("redirected here"))
        #expect(!text().contains("disambiguation"))
        #expect(try ops.history(rec.id).first?.action == "Reflow article")
    }
}

@Suite struct HiddenTextTests {
    /// What earlier versions left: the old words painted over, the new ones drawn on top.
    private func legacyEdited() throws -> PDFDocument {
        let doc = PDFDocument(data: makePDF(pages: 1, lines: { _ in ["\"MoE\" redirects here. For other uses, see Moe."] }))!
        let page = doc.page(at: 0)!
        let old = try #require(doc.findString("redirects", withOptions: []).first)
        let space = EditOps.PageSpace(page)
        let r = space.topLeft(old.bounds(for: page))
        try EditOps.compose(doc, page: 0, overlays: [.fill(r.insetBy(dx: -1, dy: -1), .white),
                                                     .text("redirect", rect: r, font: NSFont(name: "Helvetica", size: 14)!, color: .black, alignment: .left)])
        return reload(doc)
    }

    @Test func takesOutOnlyWhatCantBeSeen() throws {
        let doc = try legacyEdited()
        let page = doc.page(at: 0)!
        #expect((page.string ?? "").contains("redirects"))
        let r = try #require(TextEraser.eraseHidden(page.pageRef!))
        #expect(r.removed == 9)
        let healed = try #require(PDFDocument(data: r.data)?.page(at: 0))
        let text = healed.string ?? ""
        #expect(!text.contains("redirects"))
        #expect(text.contains("redirect"))
        #expect(text.contains("\"MoE\""))
        #expect(text.contains("here. For other uses"))
        let diff = changedPixels(page.pageRef!, healed.pageRef!, box: page.bounds(for: .mediaBox), area: .zero)
        #expect(diff.outside == 0)
    }

    @Test func cleanPagesLoseNothing() throws {
        let doc = PDFDocument(data: makePDF(pages: 1, lines: { _ in ["Nothing here is hidden.", "Second line."] }))!
        try EditOps.compose(doc, page: 0, overlays: [.fill(CGRect(x: 300, y: 300, width: 50, height: 50), .white)])
        #expect(TextEraser.eraseHidden(doc.page(at: 0)!.pageRef!)?.removed == 0)
    }

    /// Changing the visible word on such a line works and leaves one copy: the hidden old word
    /// is taken out first, so it neither matches nor joins the line.
    @Test func editingALegacyLineWorks() throws {
        let doc = try legacyEdited()
        try EditOps.replaceText(doc, find: "redirect", with: "redirected", wholeWord: true)
        let text = (reload(doc).page(at: 0)?.string ?? "").replacingOccurrences(of: "\n", with: " ")
        #expect(text.contains("redirected"))
        #expect(!text.contains("redirects"))
        #expect(text.components(separatedBy: "redirect").count == 2, "\(text)")
    }
}
