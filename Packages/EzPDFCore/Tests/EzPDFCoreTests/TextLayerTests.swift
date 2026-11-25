import Testing
import Foundation
import PDFKit
import AppKit
@testable import EzPDFCore

@Suite struct TextLayerTests {
    /// A scanned-looking page: text drawn into a bitmap, no text layer. With `rotation` 90 the scan
    /// is stored sideways and the page's rotation turns it upright, as a scanner does.
    static func scannedDoc(rotation: Int = 0) -> PDFDocument {
        let upright = NSSize(width: 1240, height: 1754)
        let stored = rotation == 90 ? NSSize(width: upright.height, height: upright.width) : upright
        let img = NSImage(size: stored)
        img.lockFocus()
        NSColor.white.setFill(); NSRect(origin: .zero, size: stored).fill()
        if rotation == 90 {
            // Shown = stored turned 90° clockwise, so draw the upright page turned 90° counterclockwise.
            let t = NSAffineTransform()
            t.translateX(by: upright.height, yBy: 0)
            t.rotate(byDegrees: 90)
            t.concat()
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black]
        ("Invoice 4471 total due 1,284.50 USD\nPayment terms net thirty days\nFacture numéro 88 montant dû" as NSString)
            .draw(at: NSPoint(x: 100, y: 1400), withAttributes: attrs)
        img.unlockFocus()
        let doc = PDFDocument()
        let page = PDFPage(image: img)!
        page.rotation = rotation
        doc.insert(page, at: 0)
        return doc
    }

    @Test(arguments: [0, 90])
    func scannedPageBecomesSearchable(rotation: Int) async throws {
        let doc = Self.scannedDoc(rotation: rotation)
        #expect((doc.page(at: 0)?.string ?? "").isEmpty)
        let r = await PageOps.makeSearchable(doc)
        #expect(r.pages == 1)
        let data = try #require(r.data)
        let saved = try #require(PDFDocument(data: data))
        let page = try #require(saved.page(at: 0))
        #expect(page.rotation == rotation)
        let text = page.string ?? ""
        #expect(text.contains("Invoice"))
        #expect(text.contains("numéro"))
        // The words sit where the ink is: the hit is in the top part of the page as shown.
        let hit = try #require(saved.findString("Invoice", withOptions: .caseInsensitive).first)
        let shown = EditOps.PageSpace(page).topLeft(hit.bounds(for: page))
        #expect(shown.minY < EditOps.PageSpace(page).size.height * 0.4)
        #expect(shown.minX < 200)
    }

    @Test func pagesWithTextAreLeftAlone() async throws {
        let doc = Self.scannedDoc()
        _ = await PageOps.makeSearchable(doc)
        let again = await PageOps.makeSearchable(doc)
        #expect(again.pages == 0)
    }

    @Test func annotationsCarryOver() async throws {
        let doc = Self.scannedDoc()
        let page = try #require(doc.page(at: 0))
        page.addAnnotation(PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 50, height: 20), forType: .square, withProperties: nil))
        _ = await PageOps.makeSearchable(doc)
        #expect(doc.page(at: 0)?.annotations.count == 1)
    }

    @Test func redactedPageKeepsItsOtherText() async throws {
        let doc = Self.scannedDoc()
        _ = await PageOps.makeSearchable(doc)
        let boxes = try #require(EditOps.rects(of: "4471", in: doc, pages: nil)[0])
        try EditOps.redact(doc, page: 0, rects: boxes)
        #expect((doc.page(at: 0)?.string ?? "").isEmpty)      // redaction rasterizes the page
        let r = await PageOps.makeSearchable(doc, pages: [0])
        #expect(r.pages == 1)
        let text = doc.page(at: 0)?.string ?? ""
        #expect(text.contains("Invoice"))
        #expect(!text.contains("4471"))
    }
}
