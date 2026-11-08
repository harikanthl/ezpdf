import Testing
import Foundation
import PDFKit
import CoreText
@testable import EzPDFCore

/// Builds a test PDF: each page gets lines of text drawn with CoreText in the given fonts.
func makePDF(pages: Int, size: CGSize = CGSize(width: 612, height: 792), fonts: [String] = ["Helvetica"],
             lines: (Int) -> [String] = { ["Page \($0 + 1) sample text"] }) -> Data {
    let data = NSMutableData()
    var box = CGRect(origin: .zero, size: size)
    let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
    for p in 0..<pages {
        ctx.beginPDFPage(nil)
        for (i, line) in lines(p).enumerated() {
            let font = NSFont(name: fonts[i % fonts.count], size: 14) ?? .systemFont(ofSize: 14)
            let ct = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [.font: font]))
            ctx.textPosition = CGPoint(x: 72, y: size.height - 100 - CGFloat(i) * 24)
            CTLineDraw(ct, ctx)
        }
        ctx.endPDFPage()
    }
    ctx.closePDF()
    return data as Data
}

func pngData(width: Int = 40, height: Int = 20) -> Data {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(NSColor.systemOrange.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return PDFRaster.encode(ctx.makeImage()!, type: .png)!
}

func reload(_ doc: PDFDocument) -> PDFDocument { PDFDocument(data: doc.dataRepresentation()!)! }

@Suite struct PageSpaceTests {
    @Test(arguments: [0, 90, 180, 270])
    func roundTripsOnCroppedRotatedPages(_ rotation: Int) {
        let doc = PDFDocument(data: makePDF(pages: 1, size: CGSize(width: 600, height: 800)))!
        let page = doc.page(at: 0)!
        page.setBounds(CGRect(x: 100, y: 100, width: 400, height: 600), for: .cropBox)
        page.rotation = rotation
        let space = EditOps.PageSpace(page)
        let r = CGRect(x: 10, y: 20, width: 30, height: 40)
        #expect(space.topLeft(space.pageRect(r)) == r)
        #expect(space.size == (rotation % 180 == 0 ? CGSize(width: 400, height: 600) : CGSize(width: 600, height: 400)))
        // The shown top-left corner is a corner of the crop box.
        let corner = space.pagePoint(.zero)
        #expect([100, 500].contains(corner.x) && [100, 700].contains(corner.y))
        // Every shown rect lands inside the crop box.
        #expect(page.bounds(for: .cropBox).contains(space.pageRect(CGRect(x: 1, y: 1, width: 5, height: 5))))
    }
}

@Suite struct ComposeTests {
    @Test func keepsCropRotationOutlineAndLinks() throws {
        let doc = PDFDocument(data: makePDF(pages: 3))!
        let target = doc.page(at: 1)!
        target.setBounds(CGRect(x: 50, y: 60, width: 500, height: 700), for: .cropBox)
        target.rotation = 90
        let root = PDFOutline()
        let item = PDFOutline(); item.label = "Chapter"; item.destination = PDFDestination(page: target, at: CGPoint(x: 0, y: 700))
        root.insertChild(item, at: 0); doc.outlineRoot = root
        let link = PDFAnnotation(bounds: CGRect(x: 72, y: 72, width: 100, height: 20), forType: .link, withProperties: nil)
        link.destination = PDFDestination(page: target, at: CGPoint(x: 0, y: 700))
        doc.page(at: 0)!.addAnnotation(link)

        try EditOps.compose(doc, page: 1, overlays: [.fill(CGRect(x: 10, y: 10, width: 50, height: 50), .red)])
        let out = reload(doc)
        let page = out.page(at: 1)!
        #expect(page.bounds(for: .cropBox) == CGRect(x: 50, y: 60, width: 500, height: 700))
        #expect(page.rotation == 90)
        let dest = try #require(out.outlineRoot?.child(at: 0)?.destination?.page)
        #expect(out.index(for: dest) == 1)
        let l = try #require(out.page(at: 0)!.annotations.first { $0.type == "Link" })
        #expect(out.index(for: try #require(l.destination?.page)) == 1)
    }

    @Test(arguments: [0, 90, 180, 270])
    func textComesOutUprightWhereItWasPut(_ rotation: Int) throws {
        let doc = PDFDocument(data: makePDF(pages: 1, lines: { _ in [] }))!
        doc.page(at: 0)!.rotation = rotation
        try EditOps.compose(doc, page: 0, overlays: [.text("UPRIGHT", rect: CGRect(x: 40, y: 40, width: 200, height: 30),
                                                           font: .systemFont(ofSize: 16), color: .black, alignment: .left)])
        let page = reload(doc).page(at: 0)!
        let word = try #require(PageText.words(page: page, index: 0).first { $0.text == "UPRIGHT" })
        #expect(word.rect.width > word.rect.height * 2)          // reads left to right as shown
        #expect(abs(word.rect.minX - 40) < 6)
        #expect(abs(word.rect.minY - 40) < 12)
    }

    @Test func replacingASelectionOverTwoLinesCoversOnlyThoseLines() throws {
        let doc = PDFDocument(data: makePDF(pages: 1, lines: { _ in ["alpha beta gamma delta", "epsilon zeta keep this"] }))!
        let page = doc.page(at: 0)!
        let words = PageText.words(page: page, index: 0)
        let delta = try #require(words.first { $0.text == "delta" }), epsilon = try #require(words.first { $0.text == "epsilon" })
        let alpha = try #require(words.first { $0.text == "alpha" }), zeta = try #require(words.first { $0.text == "zeta" })
        let space = EditOps.PageSpace(page)
        // From the start of "delta" to the end of "epsilon": the end of line 1 and the start of line 2.
        let sel = try #require(page.selection(from: space.pagePoint(CGPoint(x: delta.rect.minX + 1, y: delta.rect.midY)),
                                              to: space.pagePoint(CGPoint(x: epsilon.rect.maxX - 1, y: epsilon.rect.midY))))
        let info = try #require(EditOps.selectionInfo(sel, in: doc))
        #expect(info.lines.count == 2)
        // Taking out the end of line 1 and the start of line 2: the rest of line 2 moves up after
        // the new word, as in a word processor; line 1's start stays where it was.
        let plan = try EditCheck.plan(sel, on: page, replacement: "X", words: words)
        let written = plan.overlays.compactMap { if case .text(let s, _, _, _, _) = $0 { return s } else { return nil } }
        #expect(written.first == "X zeta keep this", "\(written)")
        try EditOps.replaceRegion(doc, page: 0, lines: info.lines, text: "X", font: .systemFont(ofSize: 14), color: .black)
        let img = PDFRaster.cgImage(doc.page(at: 0)!, scale: 1)!
        let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        func inked(_ r: CGRect) -> Bool {
            for y in Int(r.minY)..<Int(r.maxY) { for x in Int(r.minX)..<Int(r.maxX) where px[(y * img.width + x) * 4] < 100 { return true } }
            return false
        }
        #expect(inked(alpha.rect))                      // before the selection: untouched
        #expect(!inked(zeta.rect.insetBy(dx: 1, dy: 1)))  // "zeta keep this" moved up, its old place is blank
        #expect(!inked(epsilon.rect.insetBy(dx: 1, dy: 1)))
    }
}

@Suite struct WholeWordTests {
    @Test func repeatedLettersAreJudgedPerSide() throws {
        let doc = PDFDocument(data: makePDF(pages: 1, lines: { _ in ["lll ll all"] }))!
        let page = doc.page(at: 0)!
        let hits = doc.findString("ll", withOptions: []).filter { EditOps.isWholeWord($0, in: page) }
        #expect(hits.count == 1)
        // It's the standalone "ll" (the second word), not one inside "lll" or "all".
        let word = try #require(PageText.words(page: page, index: 0).first { $0.text == "ll" })
        let hit = EditOps.PageSpace(page).topLeft(try #require(hits.first).bounds(for: page))
        #expect(abs(hit.minX - word.rect.minX) < 1)
    }
}

@Suite struct DeliverableTests {
    @Test func keepsLinksAndFormsAndDrawsObjects() throws {
        let doc = PDFDocument(data: makePDF(pages: 1))!
        let page = doc.page(at: 0)!
        let link = PDFAnnotation(bounds: CGRect(x: 72, y: 600, width: 100, height: 20), forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.com")
        page.addAnnotation(link)
        let field = PDFAnnotation(bounds: CGRect(x: 72, y: 500, width: 200, height: 22), forType: .widget, withProperties: nil)
        field.widgetFieldType = .text; field.fieldName = "Name"; field.widgetStringValue = "Jane"
        page.addAnnotation(field)
        try Objects.addText(doc, page: 0, rect: CGRect(x: 300, y: 300, width: 150, height: 24), text: "PLACED WORDS",
                            font: .systemFont(ofSize: 14), color: .black)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ezpdf-test-\(UUID())")
        // As deliverableData does it: from the saved file.
        let out = PDFDocument(data: try Objects.deliverable(reload(doc), folder: folder))!
        let annots = out.page(at: 0)!.annotations
        #expect(annots.contains { $0.type == "Link" && $0.url?.host == "example.com" })
        #expect(annots.contains { $0.type == "Widget" && $0.fieldName == "Name" && $0.widgetStringValue == "Jane" })
        #expect(!annots.contains { Objects.objectID($0) != nil })
        #expect(out.page(at: 0)!.string?.contains("PLACED WORDS") == true)
    }

    @Test func svgImagesArePlacedSharp() throws {
        let svg = ##"<svg xmlns="http://www.w3.org/2000/svg" width="120" height="60"><rect width="120" height="60" fill="#ff8800"/></svg>"##
        let cg = try #require(PDFRaster.decodeImage(Data(svg.utf8)))
        #expect(cg.width >= 2000 && cg.width == cg.height * 2)
        let doc = PDFDocument(data: makePDF(pages: 1))!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ezpdf-test-\(UUID())")
        _ = try Objects.addImage(doc, page: 0, rect: CGRect(x: 50, y: 50, width: 120, height: 60), imageData: Data(svg.utf8), folder: folder)
    }

    @Test func missingImageFileIsAnErrorNotASilentDrop() throws {
        let doc = PDFDocument(data: makePDF(pages: 1))!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ezpdf-test-\(UUID())")
        let id = try Objects.addImage(doc, page: 0, rect: CGRect(x: 50, y: 50, width: 80, height: 40), imageData: pngData(), folder: folder)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("objects/\(id).png"))
        #expect(throws: EzPDFError.self) { try Objects.deliverable(reload(doc), folder: folder) }
    }
}

@Suite struct StampTests {
    @Test func pageNumbersDoNotBloatTheFile() throws {
        let data = makePDF(pages: 40, fonts: ["Helvetica", "Times-Roman", "Courier", "Georgia"],
                           lines: { p in (0..<12).map { "Line \($0) on page \(p + 1) with some words" } })
        let doc = PDFDocument(data: data)!
        let before = doc.dataRepresentation()!.count
        var c = Stamps.Config(); c.footerCenter = "Page @page of @total"
        #expect(try Stamps.apply(doc, c, fileName: "t.pdf") == 40)
        let after = doc.dataRepresentation()!.count
        #expect(Double(after) < Double(before) * 1.5, "grew from \(before) to \(after) bytes")
        #expect(reload(doc).page(at: 39)!.string?.contains("Page 40 of 40") == true)
    }

    @Test func tokensAreWholeWordsInOnePass() {
        let e = { (s: String) in Stamps.expand(s, page: 3, total: 9, title: "T", author: "A", fileName: "report@page.pdf", bates: "B1") }
        #expect(e("@page of @total") == "3 of 9")
        #expect(e("@filename") == "report@page.pdf")
        #expect(e("mail me@pagesmith.com") == "mail me@pagesmith.com")
        #expect(e("@@page") == "@page")
        #expect(e("@pages") == "@pages")
    }

    @Test func unreadableLogoIsReported() {
        let doc = PDFDocument(data: makePDF(pages: 1))!
        var c = Stamps.Config(); c.logo = Data("not an image".utf8)
        #expect(throws: EzPDFError.self) { try Stamps.apply(doc, c, fileName: "t.pdf") }
    }
}

@MainActor @Suite struct ObjectLifecycleTests {
    func makeOps() throws -> (EzPDF, DocumentRecord) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ezpdf-lib-\(UUID())", isDirectory: true)
        let ops = EzPDF(library: Library(root: root))
        let rec = try ops.library.add(DocumentRecord(title: "Test", kind: .file), pdfData: makePDF(pages: 2))
        return (ops, rec)
    }

    @Test func duplicatedPagesGetTheirOwnObjects() throws {
        let (ops, rec) = try makeOps()
        try ops.addContent(rec.id, .init(kind: .image, page: 1, rect: CGRect(x: 50, y: 50, width: 80, height: 40), imageData: pngData()))
        try ops.addContent(rec.id, .init(kind: .text, page: 1, rect: CGRect(x: 50, y: 150, width: 120, height: 24), text: "Hello"))
        _ = try ops.pages(rec.id, action: .duplicate, pages: "1")
        let doc = PDFDocument(url: ops.library.pdfURL(for: rec.id))!
        let objects = Objects.list(doc)
        #expect(objects.count == 4)
        #expect(Set(objects.map(\.id)).count == 4)
        for o in objects where o.kind == .image {
            #expect(FileManager.default.fileExists(atPath: ops.library.folder(for: rec.id).appendingPathComponent("objects/\(o.id).png").path))
        }
        // Moving the copy leaves the original where it was.
        let copy = try #require(objects.first { $0.page == 2 && $0.kind == .text })
        try ops.updateObject(rec.id, object: copy.id, onPage: 2, .init(rect: CGRect(x: 300, y: 300, width: 120, height: 24)))
        let after = Objects.list(PDFDocument(url: ops.library.pdfURL(for: rec.id))!)
        #expect(after.contains { $0.page == 1 && $0.kind == .text && $0.rect[1] < 200 })
    }

    @Test func deletingAnImageCanBeUndone() throws {
        let (ops, rec) = try makeOps()
        try ops.addContent(rec.id, .init(kind: .image, page: 1, rect: CGRect(x: 50, y: 50, width: 80, height: 40), imageData: pngData()))
        let id = try #require(Objects.list(PDFDocument(url: ops.library.pdfURL(for: rec.id))!).first?.id)
        try ops.deleteObject(rec.id, object: id)
        try ops.undo(rec.id)
        #expect(Objects.list(PDFDocument(url: ops.library.pdfURL(for: rec.id))!).contains { $0.id == id })
        // The delivered PDF still has the image drawn in (no missing-file error).
        _ = try ops.deliverableData(rec.id)
    }

    @Test func flattenKeepsPlacedImages() throws {
        let (ops, rec) = try makeOps()
        try ops.addContent(rec.id, .init(kind: .image, page: 1, rect: CGRect(x: 100, y: 400, width: 80, height: 40), imageData: pngData()))
        try ops.flatten(rec.id)
        let page = PDFDocument(url: ops.library.pdfURL(for: rec.id))!.page(at: 0)!
        #expect(page.annotations.isEmpty)
        let img = PDFRaster.cgImage(page, scale: 1)!
        let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let i = (420 * img.width + 140) * 4                       // middle of the image, rows top to bottom
        #expect(px[i] > 200 && px[i + 1] > 80 && px[i + 1] < 200 && px[i + 2] < 80)   // orange
    }

    @Test func extractCarriesImages() throws {
        let (ops, rec) = try makeOps()
        try ops.addContent(rec.id, .init(kind: .image, page: 2, rect: CGRect(x: 50, y: 50, width: 80, height: 40), imageData: pngData()))
        let result = try ops.pages(rec.id, action: .extract, pages: "2")
        let new = try #require(result.created.first)
        let obj = try #require(Objects.list(PDFDocument(url: ops.library.pdfURL(for: new.id))!).first)
        #expect(FileManager.default.fileExists(atPath: ops.library.folder(for: new.id).appendingPathComponent("objects/\(obj.id).png").path))
        _ = try ops.deliverableData(new.id)
    }

    @Test(arguments: [0, 90])
    func signatureBoxIsWhereItWasAskedOnRotatedPages(_ rotation: Int) throws {
        let (ops, rec) = try makeOps()
        if rotation != 0 { _ = try ops.pages(rec.id, action: .rotate, pages: "1", degrees: rotation) }
        // Clear of the page's own sample line, so text extraction can't merge the two.
        try ops.addContent(rec.id, .init(kind: .text, page: 1, rect: CGRect(x: 60, y: 300, width: 200, height: 30), text: "Shown here"))
        let o = try #require(Objects.list(PDFDocument(url: ops.library.pdfURL(for: rec.id))!).first)
        #expect(abs(o.rect[0] - 60) < 0.5 && abs(o.rect[1] - 300) < 0.5)
        #expect(o.rect[2] >= 200)          // as wide as asked (text runs along the shown page)
        let out = PDFDocument(data: try ops.deliverableData(rec.id))!
        let word = try #require(PageText.words(page: out.page(at: 0)!, index: 0).first { $0.text == "Shown" })
        #expect(word.rect.width > word.rect.height)
        #expect(abs(word.rect.minX - 64) < 6)
    }
}

@Suite struct RedactTests {
    @Test(arguments: [0, 90])
    func blacksOutTheRightSpotOnCroppedPages(_ rotation: Int) throws {
        let doc = PDFDocument(data: makePDF(pages: 1, lines: { _ in ["Secret 4111 1111 here"] }))!
        let page = doc.page(at: 0)!
        page.setBounds(CGRect(x: 40, y: 40, width: 540, height: 720), for: .cropBox)
        page.rotation = rotation
        let rects = try #require(EditOps.rects(of: "4111 1111", in: doc, pages: nil)[0])
        try EditOps.redact(doc, page: 0, rects: rects, scale: 2)
        let out = doc.page(at: 0)!
        #expect(out.rotation == rotation)
        #expect(EditOps.PageSpace(out).size == EditOps.PageSpace(page).size)
        // The box's middle, as shown, is black in the new page's render.
        let img = PDFRaster.cgImage(out, scale: 1)!
        let r = rects[0]
        let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let x = Int(r.midX), yFromTop = Int(r.midY)
        let i = (yFromTop * img.width + x) * 4      // bitmap memory rows run top to bottom
        #expect(px[i] < 40 && px[i + 1] < 40 && px[i + 2] < 40)
        #expect(out.string?.contains("4111") != true)
    }
}

@MainActor @Suite struct TemplateLayoutTests {
    /// Every field lands whole on one page, inside the margins (none cut by a page break).
    @Test func fieldsNeverStraddlePages() async throws {
        for t in DocTemplate.all {
            let doc = try #require(PDFDocument(data: try await TemplateRenderer.render(t, values: [:])))
            for p in 0..<doc.pageCount {
                let page = try #require(doc.page(at: p))
                let inner = page.bounds(for: .cropBox).insetBy(dx: 20, dy: 20)
                for a in page.annotations where a.type == "Widget" {
                    #expect(inner.contains(a.bounds), "\(t.id): field \(a.fieldName ?? "?") on page \(p + 1) at \(a.bounds)")
                }
            }
        }
    }
}

@MainActor @Suite(.serialized) struct AgentApprovalTests {
    func call(_ handler: MCPHandler, _ tool: String, _ args: [String: Any], remote: Bool) async -> String {
        let body = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                                "params": ["name": tool, "arguments": args]])
        let r = await handler.handle(HTTPRequest(method: "POST", path: "/mcp", query: [:], headers: [:], body: body),
                                     context: CallContext(isRemote: remote, client: "Test agent"))
        return String(decoding: r.body, as: UTF8.self)
    }

    @Test func changesAskFirstAndReadsDont() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ezpdf-lib-\(UUID())", isDirectory: true)
        let ops = EzPDF(library: Library(root: root))
        let rec = try ops.library.add(DocumentRecord(title: "Doc", kind: .file), pdfData: makePDF(pages: 1, lines: { _ in ["Secret 4111"] }))
        let handler = MCPHandler(ops: ops)
        let saved = AgentApproval.handler
        let savedPolicy = UserDefaults.standard.string(forKey: AgentApproval.policyKey)
        defer { AgentApproval.handler = saved; UserDefaults.standard.set(savedPolicy, forKey: AgentApproval.policyKey) }
        UserDefaults.standard.set(AgentApproval.Policy.ask.rawValue, forKey: AgentApproval.policyKey)

        var asked: [AgentApproval.Request] = []
        AgentApproval.handler = { asked.append($0); return false }
        // Reading never asks.
        _ = await call(handler, "get_text", ["id": rec.id], remote: false)
        #expect(asked.isEmpty)
        // Redacting asks; refused means unchanged.
        let refused = await call(handler, "redact", ["id": rec.id, "text": "4111"], remote: false)
        #expect(asked.count == 1 && asked[0].tool.lowercased().contains("redact") && asked[0].detail.contains("4111"))
        #expect(refused.contains("didn't allow"))
        #expect(PDFDocument(url: ops.library.pdfURL(for: rec.id))!.page(at: 0)!.string?.contains("4111") == true)
        // Remote callers ask for any change, even with "allow" on.
        UserDefaults.standard.set(AgentApproval.Policy.allow.rawValue, forKey: AgentApproval.policyKey)
        _ = await call(handler, "annotate", ["id": rec.id, "action": "highlight", "text": "Secret"], remote: true)
        #expect(asked.count == 2 && asked[1].remote)
        // Local with "allow": no question.
        _ = await call(handler, "annotate", ["id": rec.id, "action": "highlight", "text": "Secret"], remote: false)
        #expect(asked.count == 2)
        // No app to ask: changes are refused.
        AgentApproval.handler = nil
        UserDefaults.standard.set(AgentApproval.Policy.ask.rawValue, forKey: AgentApproval.policyKey)
        #expect(await call(handler, "redact", ["id": rec.id, "text": "4111"], remote: false).contains("didn't allow"))
    }
}

@MainActor @Suite struct UndoRedoTests {
    func texts(_ ops: EzPDF, _ id: String) -> [String] {
        Objects.list(PDFDocument(url: ops.library.pdfURL(for: id))!).compactMap(\.text)
    }

    @Test func manyStepsBackAndForward() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ezpdf-lib-\(UUID())", isDirectory: true)
        let ops = EzPDF(library: Library(root: root))
        let rec = try ops.library.add(DocumentRecord(title: "Doc", kind: .file), pdfData: makePDF(pages: 1))
        #expect(!ops.canUndo(rec.id) && !ops.canRedo(rec.id))
        for word in ["one", "two", "three"] {
            try ops.addContent(rec.id, .init(kind: .text, page: 1, rect: CGRect(x: 50, y: 300, width: 100, height: 20), text: word))
        }
        #expect(texts(ops, rec.id).sorted() == ["one", "three", "two"])
        try ops.undo(rec.id); try ops.undo(rec.id)
        #expect(texts(ops, rec.id) == ["one"])
        #expect(ops.canRedo(rec.id))
        try ops.redo(rec.id)
        #expect(texts(ops, rec.id).sorted() == ["one", "two"])
        // A new change clears what could be redone.
        try ops.addContent(rec.id, .init(kind: .text, page: 1, rect: CGRect(x: 50, y: 400, width: 100, height: 20), text: "four"))
        #expect(!ops.canRedo(rec.id))
        #expect(throws: EzPDFError.self) { try ops.redo(rec.id) }
        try ops.undo(rec.id); try ops.undo(rec.id); try ops.undo(rec.id)
        #expect(texts(ops, rec.id).isEmpty)
        #expect(throws: EzPDFError.self) { try ops.undo(rec.id) }
    }

    @Test func undoAndRedoKeepPlacedImages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ezpdf-lib-\(UUID())", isDirectory: true)
        let ops = EzPDF(library: Library(root: root))
        let rec = try ops.library.add(DocumentRecord(title: "Doc", kind: .file), pdfData: makePDF(pages: 1))
        try ops.addContent(rec.id, .init(kind: .image, page: 1, rect: CGRect(x: 50, y: 50, width: 80, height: 40), imageData: pngData()))
        let id = try #require(Objects.list(PDFDocument(url: ops.library.pdfURL(for: rec.id))!).first?.id)
        try ops.deleteObject(rec.id, object: id)
        for i in 0..<5 { try ops.addContent(rec.id, .init(kind: .text, page: 1, rect: CGRect(x: 50, y: 200 + CGFloat(i) * 30, width: 100, height: 20), text: "t\(i)")) }
        for _ in 0..<6 { try ops.undo(rec.id) }
        #expect(Objects.list(PDFDocument(url: ops.library.pdfURL(for: rec.id))!).contains { $0.id == id })
        _ = try ops.deliverableData(rec.id)
        for _ in 0..<6 { try ops.redo(rec.id) }
        #expect(!Objects.list(PDFDocument(url: ops.library.pdfURL(for: rec.id))!).contains { $0.id == id })
    }

    @Test func takesInTheOldSingleUndoFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ezpdf-lib-\(UUID())", isDirectory: true)
        let ops = EzPDF(library: Library(root: root))
        let rec = try ops.library.add(DocumentRecord(title: "Doc", kind: .file), pdfData: makePDF(pages: 2))
        try makePDF(pages: 1).write(to: ops.library.folder(for: rec.id).appendingPathComponent("document.prev.pdf"))
        #expect(ops.canUndo(rec.id))
        try ops.undo(rec.id)
        #expect(PDFDocument(url: ops.library.pdfURL(for: rec.id))!.pageCount == 1)
        try ops.redo(rec.id)
        #expect(PDFDocument(url: ops.library.pdfURL(for: rec.id))!.pageCount == 2)
    }
}

@Suite struct TextEditCheckTests {
    /// The text overlays a plan writes: (string, font size, box).
    func written(_ plan: EditCheck.Plan) -> [(String, CGFloat, CGRect)] {
        plan.overlays.compactMap { if case .text(let s, let r, let f, _, _) = $0 { return (s, f.pointSize, r) } else { return nil } }
    }

    func plan(_ lines: [String], find: String, with new: String) throws -> (EditCheck.Plan, PDFPage) {
        let doc = PDFDocument(data: makePDF(pages: 1, lines: { _ in lines }))!
        let page = doc.page(at: 0)!
        let sel = try #require(doc.findString(find, withOptions: []).first)
        return (try EditCheck.plan(sel, on: page, replacement: new, words: PageText.words(page: page, index: 0)), page)
    }

    @Test func longerWordsKeepTheTypeAndMoveTheRestOfTheLine() throws {
        let (p, _) = try plan(["Meeting on Oct 14 at noon in Room 5."], find: "Oct 14", with: "October 14")
        let w = written(p)
        #expect(w.count == 1)
        #expect(w[0].0 == "October 14 at noon in Room 5.")
        #expect(w.allSatisfy { $0.1 == 14 })                   // same size as the document, not shrunk
        #expect(p.notes.contains { $0.contains("same type") })
    }

    @Test func doesntDoubleTheSurroundingMarks() throws {
        let (p, _) = try plan(["Total due: $3,900. Thank you."], find: "3,900", with: "$4,100.")
        #expect(p.newWords == "4,100")
        #expect(written(p).first?.0.hasPrefix("4,100. Thank you.") == true)
    }

    @Test func overflowCarriesDownTheParagraph() throws {
        let para = ["The quick brown fox jumps over the lazy dog near the riverbank today",
                    "while the farmer watches from the old wooden fence by the barn door",
                    "and the sun sets slowly behind the hills."]
        let (p, _) = try plan(para, find: "fox", with: "fox, who had been running all morning,")
        let w = written(p)
        #expect(w.count >= 2)
        #expect(w.allSatisfy { $0.1 == 14 })
        // Every word of the paragraph from the change on is still there, in order.
        let after = w.map(\.0).joined(separator: " ")
        #expect(after.hasPrefix("fox, who had been running all morning, jumps over"))
        #expect(after.contains("by the barn door"))
        // Nothing runs past the paragraph's right edge.
        let right = PageText.words(page: PDFDocument(data: makePDF(pages: 1, lines: { _ in para }))!.page(at: 0)!, index: 0).map(\.rect.maxX).max()!
        for (s, _, box) in w { #expect(box.minX + EditCheck.width(s, NSFont(name: "Helvetica", size: 14)!) <= right + 1) }
    }

    @Test func refusesWhenTheParagraphHasNoRoom() throws {
        // Text right below, so the paragraph can't grow.
        let lines = ["Name: Jane Doe"] + (1...30).map { "Line \($0) of other text below the field" }
        #expect(throws: EditCheck.TooLong.self) {
            _ = try plan(lines, find: "Jane Doe", with: "Jane Alexandra Montgomery-Doe the Third, of the North Riding, with a long title that goes on and on " + String(repeating: "and on ", count: 30))
        }
    }

    @Test func editTextReportsAndLeavesThePageWhenItDoesntFit() throws {
        let doc = PDFDocument(data: makePDF(pages: 1, lines: { _ in ["Name: Jane Doe"] + (1...30).map { "Row \($0) here" } }))!
        let before = doc.dataRepresentation()!
        #expect(throws: EzPDFError.self) {
            try EditOps.replaceText(doc, find: "Jane Doe", with: String(repeating: "Very long replacement text ", count: 20))
        }
        #expect(doc.dataRepresentation()! == before || doc.page(at: 0)!.string == PDFDocument(data: before)!.page(at: 0)!.string)
    }
}

@Suite struct FontNameTests {
    @Test func namesFromPDFs() {
        #expect(Fonts.baseName("ABCDEF+Helvetica-Bold") == "Helvetica-Bold")
        #expect(Fonts.baseName("Helvetica+Bold") == "Helvetica+Bold")      // not a subset prefix
        let t = Fonts.parts("ABCDEF+TimesNewRomanPS-BoldMT")
        #expect(t.family == "Times New Roman" && t.weight == 9 && !t.italic)
        let o = Fonts.parts("OpenSans-SemiBoldItalic")
        #expect(o.family == "Open Sans" && o.weight == 8 && o.italic)
        #expect(Fonts.parts("CalibriLight").family == "Calibri")
    }

    @Test func findsInstalledFontsBehindSubsetNames() throws {
        let f = try #require(Fonts.installed("XYZABC+TimesNewRomanPS-BoldMT", size: 12))
        #expect(f.fontName.contains("Times") && f.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(Fonts.installed("ABCDEF+Helvetica", size: 11)?.pointSize == 11)
    }
}

@MainActor @Suite struct CommandRouterTests {
    typealias A = DecisionClient.Answer
    func router(_ answers: [String: A], seen: ((([String: DecisionClient.Question])) -> Void)? = nil) -> CommandRouter {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ezpdf-lib-\(UUID())", isDirectory: true)
        return CommandRouter(toolbox: AssistantToolbox(ops: EzPDF(library: Library(root: root)))) { _, q in seen?(q); return answers }
    }
    func choice(_ c: String, _ p: Double) -> A { A(value: p, choice: c, confidence: p, probabilities: [c: p]) }
    func noul(_ p: Double) -> A { A(value: p, confidence: nil, probabilities: ["true": p]) }

    @Test func routesAnInstantCommandWithItsSetting() async throws {
        let r = try #require(await router(["__tool__": choice("improve_pdf", 0.95),
                                           "improve_pdf.action?": noul(0.97), "improve_pdf.action": choice("compress", 0.9)]).route("make it smaller"))
        #expect(r.tool == "improve_pdf" && r.argumentsJSON == #"{"action":"compress"}"#)
    }

    @Test func neverOffersDeletingOrFreeText() async {
        var asked: [String: DecisionClient.Question] = [:]
        _ = await router(["__tool__": choice("other", 0.9)], seen: { asked = $0 }).route("delete it")
        guard case .choice(_, let options)? = asked["manage_document.action"] else { Issue.record("no action question"); return }
        #expect(options.map(\.0).sorted() == ["redo_last_edit", "undo_last_edit"])
        #expect(asked["improve_pdf.password"] == nil && asked["improve_pdf.text"] == nil)
    }

    @Test func handsBackWhenUnsureOrIncomplete() async {
        // Something else, a doubtful pick, and a required setting nobody stated: the language model takes it.
        #expect(await router(["__tool__": choice("other", 0.99)]).route("what's on page 3?") == nil)
        #expect(await router(["__tool__": choice("improve_pdf", 0.6), "improve_pdf.action?": noul(0.9), "improve_pdf.action": choice("compress", 0.9)]).route("hmm") == nil)
        #expect(await router(["__tool__": choice("improve_pdf", 0.95), "improve_pdf.action?": noul(0.1), "improve_pdf.action": choice("compress", 0.5)]).route("improve it") == nil)
        // A tool with no required settings goes straight through.
        #expect(await router(["__tool__": choice("make_fillable", 0.93)]).route("make this form fillable")?.tool == "make_fillable")
    }
}

@MainActor @Suite(.serialized) struct MemoryAndHistoryTests {
    func makeOps() throws -> (EzPDF, DocumentRecord) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ezpdf-lib-\(UUID())", isDirectory: true)
        let ops = EzPDF(library: Library(root: root))
        return (ops, try ops.library.add(DocumentRecord(title: "Doc", kind: .file), pdfData: makePDF(pages: 1)))
    }

    @Test func remembersAndForgets() throws {
        let (ops, _) = try makeOps()
        try ops.remember("Sign as Hari L.", source: "you")
        try ops.remember("sign as hari l.", source: "assistant")        // the same note once
        try ops.remember("Dates as DD/MM/YYYY", source: "assistant")
        #expect(ops.memory().count == 2)
        #expect(ops.memorySummary().contains("Dates as DD/MM/YYYY"))
        #expect(ops.memorySummary(limit: 30).count <= 120)               // a short summary stays short
        try ops.forget(matching: "dates")
        #expect(ops.memory().map(\.text) == ["Sign as Hari L."])
        #expect(throws: EzPDFError.self) { try ops.forget(matching: "nothing like this") }
        #expect(throws: EzPDFError.self) { try ops.remember(String(repeating: "x", count: 400), source: "you") }
    }

    @Test func logsWhoChangedWhat() async throws {
        let (ops, rec) = try makeOps()
        try ops.addContent(rec.id, .init(kind: .text, page: 1, rect: CGRect(x: 50, y: 300, width: 100, height: 20), text: "Hi"))
        try await EzPDF.$actor.withValue(EzPDF.Actor(by: "Claude", action: "Change text", detail: "find: Hi")) {
            _ = try ops.replaceText(rec.id, find: "Page 1", with: "Page one")
        }
        try ops.undo(rec.id)
        // A failed change through the agent tools is logged as failed.
        let handler = MCPHandler(ops: ops)
        let saved = AgentApproval.handler
        defer { AgentApproval.handler = saved }
        AgentApproval.handler = { _ in true }
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                               "params": ["name": "edit_text", "arguments": ["id": rec.id, "find": "not on the page", "replace": "x"]]])
        _ = await handler.handle(HTTPRequest(method: "POST", path: "/mcp", query: [:], headers: [:], body: body), context: CallContext(isRemote: false, client: "Grok"))
        let events = try ops.history(rec.id)
        try #require(events.map(\.action) == ["Change text", "Undo", "Change text", "Add content"], "\(events.map(\.action))")
        #expect(events[0].by == "Grok" && !events[0].ok)
        #expect(events[2].by == "Claude" && events[2].ok && events[2].detail == "find: Hi")
        #expect(events[3].by == "You")
    }
}

@MainActor @Suite struct SearchIndexTests {
    @Test func findsRanksAndKeepsUp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ezpdf-lib-\(UUID())", isDirectory: true)
        let ops = EzPDF(library: Library(root: root))
        let a = try ops.library.add(DocumentRecord(title: "Invoice March", kind: .file), pdfData: makePDF(pages: 2, lines: { p in ["Invoice from Northwind Café", "Page \(p + 1) totals"] }))
        let b = try ops.library.add(DocumentRecord(title: "Letter", kind: .file), pdfData: makePDF(pages: 1, lines: { _ in ["Dear Jordan, thanks for the invoice."] }))
        var hits = try await ops.search("northwind cafe")                 // accents and case don't matter
        #expect(Set(hits.map(\.id)) == [a.id])
        #expect(hits.first?.snippet.contains("«Northwind»") == true)
        hits = try await ops.search("invo")                                // prefix of the last word
        #expect(Set(hits.map(\.id)) == [a.id, b.id])
        // An edit is picked up on the next search.
        _ = try ops.replaceText(b.id, find: "Jordan", with: "Morgan")
        #expect(try await ops.search("Morgan").map(\.id) == [b.id])
        // A deleted document drops out.
        _ = try ops.delete(a.id)
        #expect(try await ops.search("Northwind").isEmpty)
        #expect(SearchIndex.ftsQuery("say \"hi\" (now)") == #""say" "hi" "(now)"*"#)
    }
}
