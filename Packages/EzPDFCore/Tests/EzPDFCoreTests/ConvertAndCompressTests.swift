import Testing
import Foundation
import PDFKit
import AppKit
import ImageIO
@testable import EzPDFCore

@Suite struct CompressTests {
    /// A noisy photo-like image, `size` pixels square (noise so it doesn't compress away on its own).
    static func photo(_ size: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        var rng = SystemRandomNumberGenerator()
        let buf = ctx.data!.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * size)
        for y in 0..<size {
            for x in 0..<size {
                let o = y * ctx.bytesPerRow + x * 4
                buf[o] = UInt8((x * 255) / size); buf[o + 1] = UInt8((y * 255) / size)
                buf[o + 2] = UInt8.random(in: 0...255, using: &rng); buf[o + 3] = 255
            }
        }
        return ctx.makeImage()!
    }

    /// Two pages: a big image drawn small with text beside it, then plain text. Page 1 gets a link
    /// and a filled-in text field, and the document an outline entry.
    static func document() throws -> PDFDocument {
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(consumer: consumer, mediaBox: &media, nil)!
        let image = photo(1600)
        for page in 0..<2 {
            ctx.beginPDFPage(nil)
            if page == 0 { ctx.draw(image, in: CGRect(x: 72, y: 400, width: 288, height: 288)) }
            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
            ("Quarterly report page \(page + 1)" as NSString).draw(at: NSPoint(x: 72, y: 300),
                                                                   withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        let doc = try #require(PDFDocument(data: data as Data))
        let first = try #require(doc.page(at: 0)), second = try #require(doc.page(at: 1))
        let link = PDFAnnotation(bounds: CGRect(x: 72, y: 290, width: 200, height: 20), forType: .link, withProperties: nil)
        link.destination = PDFDestination(page: second, at: CGPoint(x: 0, y: 792))
        first.addAnnotation(link)
        let field = PDFAnnotation(bounds: CGRect(x: 72, y: 200, width: 200, height: 24), forType: .widget, withProperties: nil)
        field.widgetFieldType = .text
        field.fieldName = "customer"
        field.widgetStringValue = "Ada Lovelace"
        first.addAnnotation(field)
        let root = PDFOutline()
        let entry = PDFOutline()
        entry.label = "Second page"
        entry.destination = PDFDestination(page: second, at: CGPoint(x: 0, y: 792))
        root.insertChild(entry, at: 0)
        doc.outlineRoot = root
        // Saved and read back, as the library holds it.
        let saved = try #require(doc.dataRepresentation())
        return try #require(PDFDocument(data: saved))
    }

    @Test func imagesShrinkAndEverythingElseStays() throws {
        let doc = try Self.document()
        let before = try #require(doc.dataRepresentation()).count
        let r = try #require(ImageCompressor.compress(doc, settings: .init(maxDPI: 100, quality: 0.6)))
        #expect(r.images == 1)
        #expect(r.data.count < before / 3)

        let out = try #require(PDFDocument(data: r.data))
        #expect(out.pageCount == 2)
        #expect(out.page(at: 0)?.string?.contains("Quarterly report page 1") == true)
        #expect(out.page(at: 1)?.string?.contains("Quarterly report page 2") == true)
        let annots = out.page(at: 0)?.annotations ?? []
        let field = try #require(annots.first { $0.type == "Widget" })
        #expect(field.fieldName == "customer")
        #expect(field.widgetStringValue == "Ada Lovelace")
        let link = try #require(annots.first { $0.type == "Link" })
        #expect((link.destination?.page).map { out.index(for: $0) } == 1)
        #expect(out.outlineRoot?.child(at: 0)?.label == "Second page")
        #expect(out.outlineRoot?.child(at: 0)?.destination?.page.map { out.index(for: $0) } == 1)

        // The image is now sized for 4 inches at 100 ppi (it was 1600 px), as JPEG.
        let page = try #require(out.page(at: 0)?.pageRef)
        let draws = TextEraser.imageDraws(page)
        #expect(draws.count == 1)
        let dict = try #require(draws.first.flatMap { CGPDFStreamGetDictionary($0.0) })
        var w: CGPDFInteger = 0
        #expect(CGPDFDictionaryGetInteger(dict, "Width", &w))
        #expect(w == 400)
        var format = CGPDFDataFormat.raw
        _ = CGPDFStreamCopyData(draws[0].0, &format)
        #expect(format == .jpegEncoded)
    }

    @Test func textOnlyDocumentsAreLeftAlone() throws {
        let doc = PDFDocument()
        doc.insert(PDFPage(), at: 0)
        #expect(ImageCompressor.compress(doc, settings: .small) == nil)
    }

    @Test func adobeMarkerIsFound() {
        // SOI, APP14 "Adobe", then SOS.
        let adobe = Data([0xFF, 0xD8, 0xFF, 0xEE, 0x00, 0x0E] + Array("Adobe".utf8) + [0, 100, 0, 0, 0, 0, 1, 0xFF, 0xDA])
        let plain = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0, 0, 0xFF, 0xDA])
        #expect(ImageCompressor.hasAdobeMarker(adobe))
        #expect(!ImageCompressor.hasAdobeMarker(plain))
    }
}

@Suite struct ConvertTests {
    /// A text document: a big bold title, two paragraphs that wrap over lines, a bulleted list, and a
    /// page number at the bottom of each of three pages.
    static func document() throws -> Data {
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(consumer: consumer, mediaBox: &media, nil)!
        let body = NSFont(name: "Times New Roman", size: 12) ?? NSFont.systemFont(ofSize: 12)
        let title = NSFont(name: "Times New Roman Bold", size: 24) ?? NSFont.boldSystemFont(ofSize: 24)
        let para = NSMutableParagraphStyle(); para.paragraphSpacing = 12
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "Annual Garden Report\n", attributes: [.font: title, .paragraphStyle: para]))
        text.append(NSAttributedString(string: "The tomatoes grew well this year because the summer was long and warm, and the soil had been improved with compost over the winter months before planting began.\n",
                                       attributes: [.font: body, .paragraphStyle: para]))
        text.append(NSAttributedString(string: "• Water in the morning\n• Mulch the beds\n", attributes: [.font: body]))
        text.append(NSAttributedString(string: "Next year we will try beans along the fence, and keep notes on how each variety does through the season.\n",
                                       attributes: [.font: body, .paragraphStyle: para]))
        for page in 0..<3 {
            ctx.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(text), CFRange(),
                                                 CGPath(rect: CGRect(x: 72, y: 300, width: 300, height: 420), transform: nil), nil)
            CTFrameDraw(frame, ctx)
            let number = CTLineCreateWithAttributedString(NSAttributedString(string: "\(page + 1)", attributes: [.font: body]))
            ctx.textPosition = CGPoint(x: 300, y: 40)
            CTLineDraw(number, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    @Test func structureIsRead() async throws {
        let doc = try #require(PDFDocument(data: try Self.document()))
        let s = await StructuredText.read(doc, pages: [0], options: .init(tables: false, figures: false))
        guard case .heading(let level, let title)? = s.blocks.first else { Issue.record("no heading first: \(s.blocks)"); return }
        #expect(level == 1)
        #expect(title == "Annual Garden Report")
        let paragraphs = s.blocks.compactMap { if case .paragraph(let r) = $0 { return r.map(\.text).joined() } else { return nil } }
        #expect(paragraphs.count == 2)
        #expect(paragraphs.first?.hasPrefix("The tomatoes grew well") == true)
        #expect(paragraphs.first?.hasSuffix("before planting began.") == true)
        let items = s.blocks.compactMap { if case .listItem(.bullet, let r) = $0 { return r.map(\.text).joined() } else { return nil } }
        #expect(items == ["Water in the morning", "Mulch the beds"])
    }

    @Test func pageNumbersAreLeftOut() async throws {
        let doc = try #require(PDFDocument(data: try Self.document()))
        let s = await StructuredText.read(doc, options: .init(tables: false, figures: false))
        let text = DocumentWriters.plainText(s)
        #expect(!text.split(separator: "\n").contains { ["1", "2", "3"].contains($0.trimmingCharacters(in: .whitespaces)) })
        #expect(text.components(separatedBy: "Annual Garden Report").count == 4)
    }

    @Test func wordFileIsWellFormed() async throws {
        let out = try await PDFConverter.convert(try Self.document(), title: "Garden", format: .docx, options: .init(pages: "1"))
        #expect(out.files.map(\.path) == ["Garden.docx"])
        let docx = out.files[0].data
        #expect(docx.prefix(2) == Data("PK".utf8))
        // Unzip document.xml with the system's unzip and parse it.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("g.docx")
        try docx.write(to: file)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-q", file.path, "-d", dir.appendingPathComponent("x").path]
        try p.run(); p.waitUntilExit()
        for part in ["word/document.xml", "word/styles.xml", "word/numbering.xml", "[Content_Types].xml", "word/_rels/document.xml.rels"] {
            let xml = try Data(contentsOf: dir.appendingPathComponent("x").appendingPathComponent(part))
            #expect(XMLParser(data: xml).parse(), "\(part) isn't well-formed")
        }
        let body = try String(contentsOf: dir.appendingPathComponent("x/word/document.xml"), encoding: .utf8)
        #expect(body.contains("<w:pStyle w:val=\"Heading1\"/>"))
        #expect(body.contains("Annual Garden Report"))
        #expect(body.contains("<w:numId w:val=\"1\"/>"))      // the bullets
    }

    @Test func markdownAndText() async throws {
        let md = try await PDFConverter.convert(try Self.document(), title: "Garden", format: .md, options: .init(pages: "1"))
        let text = String(decoding: md.files[0].data, as: UTF8.self)
        #expect(text.hasPrefix("# Annual Garden Report\n\nThe tomatoes"))
        #expect(text.contains("- Water in the morning\n- Mulch the beds"))
        let txt = try await PDFConverter.convert(try Self.document(), title: "Garden", format: .txt, options: .init(pages: "2"))
        #expect(String(decoding: txt.files[0].data, as: UTF8.self).contains("• Mulch the beds"))
    }

    @Test func pageImages() async throws {
        let one = try await PDFConverter.convert(try Self.document(), title: "Garden", format: .png, options: .init(pages: "2", dpi: 144))
        #expect(one.files.map(\.path) == ["Garden page 2.png"])
        let src = try #require(CGImageSourceCreateWithData(one.files[0].data as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 1224)      // 8.5 in × 144
        let all = try await PDFConverter.convert(try Self.document(), title: "Garden", format: .jpg, options: .init(dpi: 50))
        #expect(all.files.map(\.path) == ["Garden images/Garden page 1.jpg", "Garden images/Garden page 2.jpg", "Garden images/Garden page 3.jpg"])
    }

    @Test func markdownEscapesAndStyles() {
        let runs = [StructuredText.Run(text: "Use "), StructuredText.Run(text: "bold ", bold: true),
                    StructuredText.Run(text: "and a_b * c", italic: true)]
        #expect(DocumentWriters.inline(runs) == "Use **bold** *and a\\_b \\* c*")
        #expect(DocumentWriters.xml("a<b & \u{0001}c") == "a&lt;b &amp; c")
    }

    @Test func dehyphenation() {
        #expect(StructuredText.joinLines(["The infor-", "mation is here", "and well-", "Known"]) == "The information is here and well- Known")
    }
}

/// Serialized: these swap the export folder setting.
@MainActor @Suite(.serialized) struct ConvertOperationTests {
    /// A library and export folder of its own (the export folder setting is restored afterwards).
    func withOps(_ body: (EzPDF, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ezpdf-lib-\(UUID())", isDirectory: true)
        let exports = root.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let ops = EzPDF(library: Library(root: root))
        let saved = UserDefaults.standard.string(forKey: "ezpdf.exportFolder")
        ops.exportFolder = exports
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "ezpdf.exportFolder") } else { UserDefaults.standard.removeObject(forKey: "ezpdf.exportFolder") }
            try? FileManager.default.removeItem(at: root)
        }
        try await body(ops, exports)
    }

    @Test func compressThroughOperationsCanBeUndone() async throws {
        try await withOps { ops, _ in
            let pdf = try #require(try CompressTests.document().dataRepresentation())
            let rec = try ops.library.add(DocumentRecord(title: "Photo", kind: .file), pdfData: pdf)
            let r = try await ops.optimize(rec.id, .compress_strong)
            #expect(r.after < r.before / 3)
            #expect(try Data(contentsOf: ops.library.pdfURL(for: rec.id)).count == r.after)
            _ = try ops.undo(rec.id)
            #expect(try Data(contentsOf: ops.library.pdfURL(for: rec.id)).count == r.before)
            // Compressing what's already compressed changes nothing, and leaves the file alone.
            let once = try await ops.optimize(rec.id, .compress_strong)
            let again = try await ops.optimize(rec.id, .compress_strong)
            #expect(once.after < once.before)
            #expect(again.after == again.before)
            #expect(again.record.modifiedAt == once.record.modifiedAt)
        }
    }

    @Test func savedFilesGetFreeNames() async throws {
        try await withOps { ops, exports in
            let rec = try ops.library.add(DocumentRecord(title: "Garden", kind: .file), pdfData: try ConvertTests.document())
            let first = try await ops.exportConverted(rec.id, format: .docx)
            let second = try await ops.exportConverted(rec.id, format: .docx)
            #expect(first.url.lastPathComponent == "Garden.docx")
            #expect(second.url.lastPathComponent == "Garden 2.docx")
            let images = try await ops.exportConverted(rec.id, format: .png, dpi: 40)
            #expect(images.files == 3)
            #expect(images.url == exports.appendingPathComponent("Garden images", isDirectory: true).standardizedFileURL
                    || images.url.lastPathComponent == "Garden images")
            // Markdown keeps its figures in "<name> images", which the page images now use.
            let md = try await ops.exportConverted(rec.id, format: .md, pages: "1")
            #expect(md.url.lastPathComponent == "Garden 2.md")
            let txt = try await ops.exportConverted(rec.id, format: .txt)
            #expect(txt.url.lastPathComponent == "Garden.txt")
        }
    }

    @Test func toolsOfferTheNewFormats() throws {
        let tools = MCPTools.all(EzPDF(library: Library(root: FileManager.default.temporaryDirectory.appendingPathComponent("ezpdf-lib-\(UUID())"))))
        let export = try #require(tools.first { $0.name == "export_file" })
        let props = try #require(export.schema["properties"] as? [String: [String: Any]])
        let formats = try #require(props["format"]?["enum"] as? [String])
        #expect(Set(["docx", "md", "txt", "png", "jpg"]).isSubset(of: Set(formats)))
        #expect(props["dpi"] != nil && props["pages"] != nil)
        let improve = try #require(tools.first { $0.name == "improve_pdf" })
        let iprops = try #require(improve.schema["properties"] as? [String: [String: Any]])
        #expect(iprops["dpi"]?["type"] as? String == "integer")
        #expect(iprops["quality"]?["type"] as? String == "number")
    }
}

@Suite struct ConvertFixTests {
    @Test func markdownParagraphStartsAreEscaped() {
        #expect(DocumentWriters.escapeBlockStart("12. That year") == "12\\. That year")
        #expect(DocumentWriters.escapeBlockStart("3) Then") == "3\\) Then")
        #expect(DocumentWriters.escapeBlockStart("- dash") == "\\- dash")
        #expect(DocumentWriters.escapeBlockStart("# tag") == "\\# tag")
        #expect(DocumentWriters.escapeBlockStart("2026 was good") == "2026 was good")
        #expect(DocumentWriters.escapeBlockStart("-5 degrees") == "-5 degrees")
    }

    @Test func imagesAreHandedOverOneByOne() async throws {
        var paths: [String] = []
        let notes = try await PDFConverter.convert(try ConvertTests.document(), title: "G", format: .png, options: .init(dpi: 36)) { paths.append($0.path) }
        #expect(notes.isEmpty)
        #expect(paths == ["G images/G page 1.png", "G images/G page 2.png", "G images/G page 3.png"])
    }
}

extension ConvertOperationTests {
    @Test func lockedDocumentsSaySo() async throws {
        try await withOps { ops, _ in
            let doc = try CompressTests.document()
            let locked = try #require(PageOps.protect(doc, password: "pw", ownerPassword: nil, allowPrinting: true, allowCopying: false))
            let rec = try ops.library.add(DocumentRecord(title: "Locked", kind: .file), pdfData: locked)
            await #expect(throws: EzPDFError.self) { _ = try await ops.optimize(rec.id, .compress) }
        }
    }

    @Test func badPageRangeWritesNothing() async throws {
        try await withOps { ops, exports in
            let rec = try ops.library.add(DocumentRecord(title: "Garden", kind: .file), pdfData: try ConvertTests.document())
            await #expect(throws: EzPDFError.self) { _ = try await ops.exportConverted(rec.id, format: .png, pages: "9") }
            #expect((try FileManager.default.contentsOfDirectory(atPath: exports.path)).isEmpty)
        }
    }
}

@Suite struct CompressReachTests {
    /// A one-page PDF written by hand: a 1000 px noise image drawn 1 inch wide on the page, plus
    /// `extra` objects (5 is the image, 6 onward are free) and page entries.
    static func pdf(content: String, resources: String, pageExtra: String = "", extra: [String] = []) -> Data {
        var rng = SystemRandomNumberGenerator()
        let side = 1000
        var pixels = Data(count: side * side * 3)
        pixels.withUnsafeMutableBytes { p in for k in 0..<p.count { p[k] = UInt8.random(in: 0...255, using: &rng) } }
        var objects: [Data] = []
        objects.append(Data("<< /Type /Catalog /Pages 2 0 R >>".utf8))
        objects.append(Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8))
        objects.append(Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources \(resources) /Contents 4 0 R \(pageExtra) >>".utf8))
        objects.append(Data("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream".utf8))
        var image = Data("<< /Type /XObject /Subtype /Image /Width \(side) /Height \(side) /ColorSpace /DeviceRGB /BitsPerComponent 8 /Length \(pixels.count) >>\nstream\n".utf8)
        image.append(pixels); image.append(Data("\nendstream".utf8))
        objects.append(image)
        objects += extra.map { Data($0.utf8) }
        var out = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (k, o) in objects.enumerated() {
            offsets.append(out.count)
            out.append(Data("\(k + 1) 0 obj\n".utf8)); out.append(o); out.append(Data("\nendobj\n".utf8))
        }
        let xref = out.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { table += String(format: "%010d 00000 n \n", o) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        out.append(Data(table.utf8))
        return out
    }

    static func imageWidth(_ data: Data) throws -> Int {
        let doc = try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        let page = try #require(doc.page(at: 1))
        var res: CGPDFDictionaryRef?, xo: CGPDFDictionaryRef?, im: CGPDFStreamRef?
        #expect(CGPDFDictionaryGetDictionary(page.dictionary!, "Resources", &res))
        #expect(CGPDFDictionaryGetDictionary(res!, "XObject", &xo))
        #expect(CGPDFDictionaryGetStream(xo!, "Im", &im))
        var w: CGPDFInteger = 0
        _ = CGPDFDictionaryGetInteger(CGPDFStreamGetDictionary(im!)!, "Width", &w)
        return Int(w)
    }

    @Test func imagesInAnnotationsAreSizedForTheirLargestUse() throws {
        // On the page 1 inch wide; in a stamp's appearance, 7 inches (BBox 100 mapped onto a 504 pt rect).
        let ap = "q 100 0 0 100 0 0 cm /Im Do Q"
        let data = Self.pdf(content: "q 72 0 0 72 0 0 cm /Im Do Q", resources: "<< /XObject << /Im 5 0 R >> >>",
                            pageExtra: "/Annots [6 0 R]",
                            extra: ["<< /Type /Annot /Subtype /Stamp /Rect [50 50 554 554] /AP << /N 7 0 R >> >>",
                                    "<< /Type /XObject /Subtype /Form /BBox [0 0 100 100] /Resources << /XObject << /Im 5 0 R >> >> /Length \(ap.utf8.count) >>\nstream\n\(ap)\nendstream"])
        let doc = try #require(PDFDocument(data: data))
        let r = try #require(ImageCompressor.compress(doc, settings: .init(maxDPI: 100, quality: 0.6)))
        // 7 in × 100 ppi = 700 px (the page alone would have allowed 100).
        #expect(try Self.imageWidth(r.data) == 700)
    }

    @Test func imagesInPatternsAreKept() throws {
        let cell = "q 100 0 0 100 0 0 cm /Im Do Q"
        let data = Self.pdf(content: "q 72 0 0 72 0 0 cm /Im Do Q /Pattern cs /P1 scn 100 100 400 400 re f",
                            resources: "<< /XObject << /Im 5 0 R >> /Pattern << /P1 6 0 R >> >>",
                            extra: ["<< /Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 100 100] /XStep 100 /YStep 100 /Resources << /XObject << /Im 5 0 R >> >> /Length \(cell.utf8.count) >>\nstream\n\(cell)\nendstream"])
        let doc = try #require(PDFDocument(data: data))
        #expect(ImageCompressor.compress(doc, settings: .init(maxDPI: 100, quality: 0.6)) == nil)
    }
}

@Suite struct ListTests {
    @Test func markers() {
        #expect(StructuredText.listMarker("a. Apples")?.marker == .letter(1))
        #expect(StructuredText.listMarker("(c) Cherries")?.marker == .letter(3))
        #expect(StructuredText.listMarker("12) Twelve")?.marker == .number(12))
        #expect(StructuredText.listMarker("• Dot")?.marker == .bullet)
    }

    @Test func letteredListsStayLettered() throws {
        let doc = StructuredText.Document(blocks: [
            .listItem(.letter(1), runs: [.init(text: "Apples")]), .listItem(.letter(2), runs: [.init(text: "Pears")]),
            .paragraph([.init(text: "Then")]),
            .listItem(.number(1), runs: [.init(text: "One")]),
        ], pageSize: CGSize(width: 612, height: 792), title: nil, scannedPages: 0)
        let md = DocumentWriters.markdown(doc) { "\($0)" }
        #expect(md.contains("a. Apples\n\nb. Pears"))
        #expect(md.contains("1. One"))
        #expect(DocumentWriters.plainText(doc).contains("a. Apples\nb. Pears"))
        let numbering = DocumentWriters.numberingXML(starts: [(2, 1), (1, 1)])
        #expect(numbering.contains("<w:numFmt w:val=\"lowerLetter\"/>"))
        #expect(numbering.contains("<w:num w:numId=\"2\"><w:abstractNumId w:val=\"2\"/>"))
        #expect(numbering.contains("<w:num w:numId=\"3\"><w:abstractNumId w:val=\"1\"/>"))
        #expect(XMLParser(data: Data(numbering.utf8)).parse())
        #expect(DocumentWriters.letter(1) == "a" && DocumentWriters.letter(26) == "z" && DocumentWriters.letter(27) == "aa")
    }

    /// A paragraph whose sentence wraps onto a line starting "100. ": still one paragraph.
    @Test func wrappedNumberIsNotAList() async throws {
        let data = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &media, nil)!
        ctx.beginPDFPage(nil)
        let font = NSFont(name: "Times New Roman", size: 12) ?? NSFont.systemFont(ofSize: 12)
        for (k, line) in ["Over the decade the orchard harvest grew from twelve crates to", "100. The next year it doubled again, which nobody expected."].enumerated() {
            ctx.textPosition = CGPoint(x: 72, y: 700 - CGFloat(k) * 14)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [.font: font])), ctx)
        }
        ctx.endPDFPage(); ctx.closePDF()
        let doc = try #require(PDFDocument(data: data as Data))
        let s = await StructuredText.read(doc, options: .init(tables: false, figures: false))
        #expect(s.blocks.count == 1)
        if case .paragraph(let runs)? = s.blocks.first { #expect(runs.map(\.text).joined().contains("crates to 100. The next")) }
        else { Issue.record("expected one paragraph: \(s.blocks)") }
    }
}

extension ConvertOperationTests {
    @Test func exportsAtTheSameTimeGetTheirOwnNames() async throws {
        try await withOps { ops, _ in
            let rec = try ops.library.add(DocumentRecord(title: "Garden", kind: .file), pdfData: try ConvertTests.document())
            async let a = ops.exportConverted(rec.id, format: .docx)
            async let b = ops.exportConverted(rec.id, format: .docx)
            let names = Set(try await [a.url.lastPathComponent, b.url.lastPathComponent])
            #expect(names == ["Garden.docx", "Garden 2.docx"])
        }
    }
}
