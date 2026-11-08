import Testing
import Foundation
import PDFKit
import CoreText
@testable import EzPDFCore

/// A flat (not fillable) application form drawn with lines, boxes and labels, like a printed form.
func flatForm() -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil)
    func y(_ top: CGFloat) -> CGFloat { 792 - top }
    func text(_ s: String, _ x: CGFloat, _ top: CGFloat, size: CGFloat = 11) {
        ctx.textPosition = CGPoint(x: x, y: y(top))
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: NSFont(name: "Helvetica", size: size)!])), ctx)
    }
    func line(_ x0: CGFloat, _ x1: CGFloat, _ top: CGFloat) { ctx.move(to: CGPoint(x: x0, y: y(top))); ctx.addLine(to: CGPoint(x: x1, y: y(top))); ctx.strokePath() }
    ctx.setLineWidth(0.8)
    text("Membership Application", 72, 60, size: 18)
    text("Full name:", 72, 110); line(140, 540, 112)
    text("Email:", 72, 140); line(140, 540, 142)
    text("Phone: ______________________", 72, 170)
    // A box with its label inside, at the top left.
    ctx.stroke(CGRect(x: 72, y: y(270), width: 468, height: 80))
    text("Mailing address", 76, 202, size: 8)
    // Checkboxes.
    ctx.stroke(CGRect(x: 72, y: y(302), width: 11, height: 11)); text("Student", 90, 300)
    ctx.stroke(CGRect(x: 172, y: y(302), width: 11, height: 11)); text("Senior", 190, 300)
    // A table: header row with labels, two empty rows.
    let cols: [CGFloat] = [72, 272, 402, 540], rows: [CGFloat] = [330, 350, 372, 394]
    for r in rows { line(cols.first!, cols.last!, r) }
    for c in cols { ctx.move(to: CGPoint(x: c, y: y(rows.first!))); ctx.addLine(to: CGPoint(x: c, y: y(rows.last!))); ctx.strokePath() }
    text("Item", 76, 344); text("Quantity", 276, 344); text("Price", 406, 344)
    // Signature line with its caption under it, and a date.
    line(72, 300, 460); text("Signature", 72, 474, size: 9)
    text("Date:", 340, 458); line(375, 540, 460)
    ctx.endPDFPage(); ctx.closePDF()
    return data as Data
}

@MainActor @Suite struct FormDetectorTests {
    @Test func templateFieldsKeepTheirNames() async throws {
        let t = try #require(DocTemplate.find("invoice"))
        let doc = try #require(PDFDocument(data: try await TemplateRenderer.render(t)))
        let names = Set(EditOps.formFields(doc).map(\.name))
        #expect(names == Set(t.fieldNames), "\(names.subtracting(t.fieldNames).prefix(5))")
        #expect(try EditOps.fillForm(doc, values: ["invoice_number": "INV-7"]) == ["invoice_number"])
    }

    func check(_ fields: [FormDetector.Field], scanned: Bool) {
        let byLabel = Dictionary(grouping: fields, by: { $0.label.lowercased() })
        func has(_ label: String, _ kind: FormDetector.Kind) -> Bool { byLabel[label]?.contains { $0.kind == kind } == true }
        #expect(has("full name", .text), "\(fields.map { "\($0.label)/\($0.kind)" })")
        #expect(has("email", .text))
        #expect(has("phone", .text))
        #expect(has("mailing address", .multiline))
        #expect(has("student", .checkbox))
        #expect(has("senior", .checkbox))
        #expect(has("signature", .signature))
        #expect(has("date", .date))
        // Table: the two empty rows under Item / Quantity / Price, and no field over the header labels.
        let cells = fields.filter { $0.rect.minY > 345 && $0.rect.maxY < 398 && $0.kind == .text }
        #expect(cells.count == 6, "\(cells.map { "\($0.label) \($0.rect)" })")
        #expect(cells.map(\.label).sorted() == ["Item", "Item", "Price", "Price", "Quantity", "Quantity"], "\(cells.map(\.label))")
        // Nothing on the title, and names are unique.
        #expect(!fields.contains { $0.rect.minY < 80 })
        #expect(Set(fields.map(\.name)).count == fields.count)
    }

    @Test func findsTheBlanksOnADigitalForm() async throws {
        let doc = PDFDocument(data: flatForm())!
        let fields = await FormDetector.detect(doc)
        check(fields, scanned: false)
        FormDetector.addFields(fields, to: doc)
        let saved = PDFDocument(data: doc.dataRepresentation()!)!
        let form = EditOps.formFields(saved)
        #expect(form.count == fields.count)
        #expect(form.contains { $0.name == "full_name" && $0.type == "text" })
        #expect(form.contains { $0.name == "student" && $0.type == "checkbox" })
        // Fillable afterwards with the usual tool.
        #expect(try EditOps.fillForm(saved, values: ["full_name": "Jane Doe", "student": "yes"]).count == 2)
    }

    @Test func findsTheBlanksOnAScan() async throws {
        // The same form as a picture (no text layer): lines from pixels, labels from OCR.
        let page = PDFDocument(data: flatForm())!.page(at: 0)!
        let img = PDFRaster.cgImage(page, scale: 2.5)!
        let data = NSMutableData(); var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil); ctx.draw(img, in: box); ctx.endPDFPage(); ctx.closePDF()
        let scan = PDFDocument(data: data as Data)!
        #expect((scan.page(at: 0)!.string ?? "").isEmpty)
        check(await FormDetector.detect(scan), scanned: true)
    }

    @Test func keepsExistingFieldsAndUprightsRotatedPages() async throws {
        let doc = PDFDocument(data: flatForm())!
        let page = doc.page(at: 0)!
        let existing = PDFAnnotation(bounds: CGRect(x: 140, y: 792 - 110, width: 400, height: 16), forType: .widget, withProperties: nil)
        existing.widgetFieldType = .text; existing.fieldName = "name_given"
        page.addAnnotation(existing)
        let saved = PDFDocument(data: doc.dataRepresentation()!)!
        let fields = await FormDetector.detect(saved)
        #expect(!fields.contains { $0.label.lowercased() == "full name" })

        let rotated = PDFDocument(data: flatForm())!
        rotated.page(at: 0)!.rotation = 90
        let (found, skipped) = try await FormDetector.makeFillable(rotated)
        #expect(skipped.isEmpty)
        #expect(rotated.page(at: 0)!.rotation == 0)
        #expect(EditOps.PageSpace(rotated.page(at: 0)!).size == CGSize(width: 792, height: 612))
        #expect(found.count >= 10)
    }
}

@MainActor @Suite struct FormTemplateTests {
    @Test func dropAFormSaveItAndReuseIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ezpdf-lib-\(UUID())", isDirectory: true)
        let ops = EzPDF(library: Library(root: root))
        let file = root.appendingPathComponent("Membership form.pdf")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try flatForm().write(to: file)

        let (result, template) = try await ops.importForm(file, templateName: "Membership")
        #expect(result.fields.count >= 15)
        let t = try #require(template)
        #expect(t.fields.contains("full_name") && t.fields.contains("student"))
        #expect(ops.userTemplates().map(\.id) == [t.id])
        #expect(ops.library.all().count == 1)

        let filled = try ops.create(userTemplate: "membership", values: ["full_name": "Jane Doe", "student": "yes"])
        let fields = EditOps.formFields(PDFDocument(url: ops.library.pdfURL(for: filled.id))!)
        #expect(fields.first { $0.name == "full_name" }?.value == "Jane Doe")
        #expect(fields.first { $0.name == "student" }?.value != "off")

        try ops.deleteUserTemplate(t.id)
        #expect(ops.userTemplates().isEmpty)
    }

    @Test func aPageWithNoBlanksIsNotKept() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ezpdf-lib-\(UUID())", isDirectory: true)
        let ops = EzPDF(library: Library(root: root))
        let file = root.appendingPathComponent("letter.pdf")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makePDF(pages: 1, lines: { _ in ["Dear reader,", "This page has only words on it."] }).write(to: file)
        await #expect(throws: EzPDFError.self) { _ = try await ops.importForm(file) }
        #expect(ops.library.all().isEmpty)
    }
}

@Suite struct DocumentTableTests {
    @Test func readsRuledTablesWithExactText() async throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        let cols: [CGFloat] = [72, 272, 402, 540], top: CGFloat = 120
        let cells = [["Item", "Quantity", "Price"], ["Paper A4", "12", "4.50"], ["Toner XL", "2", "89.00"], ["Staples", "40", "0.25"]]
        for (r, row) in cells.enumerated() {
            let y = 792 - top - CGFloat(r) * 22
            for (c, text) in row.enumerated() {
                ctx.textPosition = CGPoint(x: cols[c] + 6, y: y - 15)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont(name: "Helvetica", size: 11)!])), ctx)
            }
        }
        ctx.setLineWidth(0.8)
        for r in 0...cells.count { let y = 792 - top - CGFloat(r) * 22; ctx.move(to: CGPoint(x: 72, y: y)); ctx.addLine(to: CGPoint(x: 540, y: y)) }
        for c in cols { ctx.move(to: CGPoint(x: c, y: 792 - top)); ctx.addLine(to: CGPoint(x: c, y: 792 - top - CGFloat(cells.count) * 22)) }
        ctx.strokePath()
        ctx.endPDFPage(); ctx.closePDF()
        let tables = await DataExtractor.documentTables(PDFDocument(data: data as Data)!)
        let t = try #require(tables.first, "no table found")
        #expect(t.rows == cells, "\(t.rows)")
    }

    @Test func readsABorderlessTable() async throws {
        let lines = ["Region      Q1        Q2        Q3"] + (1...5).map { "North\($0)      1\($0).00     2\($0).50     3\($0).75" }
        let doc = PDFDocument(data: makePDF(pages: 1, fonts: ["Courier"], lines: { _ in lines }))!
        let r = await DataExtractor.extract(doc, kind: .tables, useAI: false)
        let t = try #require(r.tables?.first)
        #expect(t.rows.count >= 6 && t.rows[0].count == 4, "\(t.rows)")
        #expect(t.rows[1].contains("11.00"))
    }
}
