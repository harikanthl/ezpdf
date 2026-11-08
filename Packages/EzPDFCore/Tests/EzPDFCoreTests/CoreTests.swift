import Testing
import Foundation
import PDFKit
@testable import EzPDFCore

@Suite struct PaginatorTests {
    @Test func breaksAboveLineThatWouldBeCut() {
        // Lines every 20 pt, 14 pt tall; page 100 pt. The line at 90–104 straddles 100.
        let boxes = stride(from: 0.0, to: 300, by: 20).map { Paginator.Box(top: $0 + 10, bottom: $0 + 24, kind: .line) }
        let slices = Paginator.slices(contentHeight: 300, pageHeight: 100, boxes: boxes)
        #expect(slices.first == 0..<90)
        for s in slices {
            for b in boxes { #expect(!(b.top < s.upperBound && b.bottom > s.upperBound + 0.5 && s.upperBound < 300)) }
        }
        #expect(slices.last?.upperBound == 300)
    }

    @Test func hugeImageGetsHardCutInsteadOfLooping() {
        let slices = Paginator.slices(contentHeight: 500, pageHeight: 100, boxes: [.init(top: 5, bottom: 480, kind: .atomic)])
        #expect(slices.count == 5)
    }

    @Test func headingStaysWithFollowingText() {
        let boxes: [Paginator.Box] = [.init(top: 50, bottom: 60, kind: .line), .init(top: 92, bottom: 99, kind: .heading)]
        let slices = Paginator.slices(contentHeight: 200, pageHeight: 100, boxes: boxes)
        #expect(slices.first?.upperBound == 92)
    }
}

@Suite struct TokenTests {
    @Test(arguments: [("1,234.56", 1234.56, 0), ("(84.37)", 84.37, -1), ("-$12.00", 12.0, -1), ("600.00 DR", 600.0, -1),
                      ("58.20 CR", 58.2, 1), ("1.234,56", 1234.56, 0), ("$3,856.19", 3856.19, 0)])
    func money(_ s: String, _ v: Double, _ sign: Int) throws {
        let p = try #require(Money.parse(s))
        #expect(abs(p.value - v) < 0.001)
        #expect(p.explicitSign == sign)
    }

    @Test(arguments: ["2026", "12", "abc", "10/02", "#1043"])
    func notMoney(_ s: String) { #expect(!Money.isMoney(s)) }

    @Test func dates() {
        #expect(DateToken.parse("10/02", dayFirst: false) == .init(year: nil, month: 10, day: 2, length: 5))
        #expect(DateToken.parse("02/10/2026", dayFirst: true)?.month == 10)
        #expect(DateToken.parse("2026-11-07", dayFirst: false)?.day == 7)
        #expect(DateToken.parse("Oct 5, 2026", dayFirst: false) == .init(year: 2026, month: 10, day: 5, length: 11))
        #expect(DateToken.parse("5 Oct", dayFirst: true)?.month == 10)
        #expect(DateToken.parse("TRADER JOES", dayFirst: false) == nil)
    }
}

@Suite struct ParserTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")

    @Test func statementFixture() async throws {
        let doc = try #require(PDFDocument(url: Self.fixtures.appendingPathComponent("statement.pdf")))
        let r = await DataExtractor.extract(doc, kind: .auto, useAI: false)
        #expect(r.kind == .statement)
        let s = try #require(r.statement)
        #expect(s.transactions.count == 8)
        #expect(s.openingBalance == 2450.18)
        #expect(s.closingBalance == 4204.68)
        #expect(s.totalIn == 3871.76)
        #expect(s.totalOut == 2117.26)
        #expect(s.reconciledShare == 1)
        #expect(s.transactions.first?.amount == -84.37)
        #expect(s.transactions[1].amount == 3812.44)
        #expect(s.warnings.isEmpty)
    }

    @Test func invoiceFixture() async throws {
        let doc = try #require(PDFDocument(url: Self.fixtures.appendingPathComponent("invoice.pdf")))
        let r = await DataExtractor.extract(doc, kind: .auto, useAI: false)
        #expect(r.kind == .invoice)
        let i = try #require(r.invoice)
        #expect(i.invoiceNumber == "NW-2026-0187")
        #expect(i.vendor == "Northwind Design Studio")
        #expect(i.invoiceDate == "2026-10-14")
        #expect(i.dueDate == "2026-11-13")
        #expect(i.subtotal == 3550)
        #expect(i.tax == 306.19)
        #expect(i.total == 3856.19)
        #expect(i.lineItems.count == 3)
        #expect(i.lineItems[1].quantity == 6)
        #expect(i.billTo == "Harbor Robotics Inc., 77 Pier Ave, Oakland CA")
    }
}

@Suite struct OpsTests {
    @Test func pageRanges() throws {
        #expect(try PageOps.pages("1-3,5,8-", count: 10) == [0, 1, 2, 4, 7, 8, 9])
        #expect(try PageOps.pages(nil, count: 3) == [0, 1, 2])
        #expect(try PageOps.pages("last", count: 4) == [3])
        #expect(throws: EzPDFError.self) { try PageOps.pages("12", count: 10) }
        #expect(throws: EzPDFError.self) { try PageOps.pages("5-2", count: 10) }
    }

    @Test func moveKeepsOrder() {
        let doc = PDFDocument()
        for i in 0..<5 { let p = PDFPage(); p.setBounds(CGRect(x: 0, y: 0, width: 100 + i, height: 100), for: .mediaBox); doc.insert(p, at: i) }
        PageOps.move(doc, pages: [3, 4], to: 0)
        let widths = (0..<5).map { Int(doc.page(at: $0)!.bounds(for: .mediaBox).width) }
        #expect(widths == [103, 104, 100, 101, 102])
    }

    @Test(arguments: [("https://example.com/a", true), ("http://localhost:8080", false), ("http://127.0.0.1/", false),
                      ("http://192.168.1.1/", false), ("http://10.0.0.5/", false), ("http://[::1]/", false),
                      ("http://2130706433/", false), ("file:///etc/passwd", false), ("http://printer.local/", false),
                      ("https://huggingface.co/spaces/x/y", true), ("http://169.254.169.254/latest", false)])
    func urlGuard(_ s: String, _ allowed: Bool) {
        #expect(URLGuard.isAllowed(URL(string: s)!) == allowed)
    }
}

@Suite struct ExportTests {
    @Test func zipRoundTripIsReadable() throws {
        var z = ZipWriter()
        z.add("mimetype", "application/epub+zip", compress: false)
        z.add("big.txt", String(repeating: "hello ezpdf ", count: 500))
        let data = z.finish()
        #expect(data.starts(with: Data([0x50, 0x4b, 0x03, 0x04])))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ezpdf-test-\(UUID()).zip")
        try data.write(to: tmp)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-tq", tmp.path]
        p.standardOutput = Pipe()
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }

    @Test func csvEscapesAndNeutralizesFormulas() {
        let s = String(decoding: Spreadsheet.csv([["a,b", "say \"hi\"", "=SUM(A1)", "-12.50"]]), as: UTF8.self)
        #expect(s.contains("\"a,b\""))
        #expect(s.contains("\"say \"\"hi\"\"\""))
        #expect(s.contains("'=SUM(A1)"))
        #expect(s.contains(",-12.50"))
    }

    @Test func markdown() {
        let h = Markdown.html("# Title\n\nSome **bold** and `code`.\n\n- one\n- two\n\n```\nx < y\n```")
        #expect(h.contains("<h1>Title</h1>"))
        #expect(h.contains("<strong>bold</strong>"))
        #expect(h.contains("<code>code</code>"))
        #expect(h.contains("<ul><li>one</li><li>two</li></ul>"))
        #expect(h.contains("x &lt; y"))
    }
}
