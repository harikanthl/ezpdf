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
    @Test func ocrCommaForDecimalPoint() {
        #expect(Money.parse("4,804,68")?.value == 4804.68)
        #expect(Money.parse("$1,234,567,89")?.value == 1234567.89)
        #expect(Money.parse("1,234.56")?.value == 1234.56)
        #expect(Money.parse("1.234,56")?.value == 1234.56)
        #expect(Money.parse("12,34") == nil || Money.parse("12,34")?.value == 12.34)
    }

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

@Suite struct RegressionTests {
    @Test func hugeRangesFailFastWithoutAllocating() throws {
        #expect(throws: EzPDFError.self) { try PageOps.pages("1-99999999999", count: 10) }
        #expect(throws: EzPDFError.self) { try PageOps.pages("0-3", count: 10) }
        #expect(try PageOps.pages("-3", count: 10) == [0, 1, 2])          // "-3" means pages 1 to 3
        #expect(throws: EzPDFError.self) { try PageOps.pages("99999999999-", count: 10) }
    }

    @Test func datesAreValidated() {
        #expect(DateToken.parse("3.14", dayFirst: false) == nil)            // an amount, not March 14
        #expect(DateToken.parse("02/31/2026", dayFirst: false) == nil)      // no Feb 31
        #expect(DateToken.parse("12/31/99", dayFirst: false)?.year == 1999)
        #expect(DateToken.parse("14.03.2026", dayFirst: true)?.month == 3)
    }

    @Test(arguments: ["http://0177.0.0.1/", "http://127.1/", "http://0x7f.0.0.1/", "http://[::127.0.0.1]/",
                      "http://[64:ff9b::7f00:1]/", "http://010.0.0.1/"])
    func numericHostsBlocked(_ s: String) { #expect(!URLGuard.isAllowed(URL(string: s)!)) }

    @Test func localNamesResolveToPrivate() async {
        #expect(await URLGuard.resolvesPublic(URL(string: "http://localtest.me/")!) == false)
    }

    @Test func requestParsingRejectsBadLengths() {
        #expect(parse("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: -1\r\n\r\n") == 400)
        #expect(parse("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nTransfer-Encoding: chunked\r\n\r\n") == 411)
        #expect(parse("POST /mcp HTTP/1.1\r\nHost: a\r\nHost: b\r\nContent-Length: 0\r\n\r\n") == 400)
        #expect(parse("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 999999999999\r\n\r\n") == 413)
        #expect(parse("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 2\r\n\r\n{}") == 0)
    }

    @Test func csvQuotesCarriageReturns() {
        let s = String(decoding: Spreadsheet.csv([["a\rb", "\t=1+1"]]), as: UTF8.self)
        #expect(s.contains("\"a\rb\""))
        #expect(s.contains("'\t=1+1"))
    }

    /// Runs RequestReader's parser over a buffer; 0 means a request was accepted.
    func parse(_ raw: String) -> Int {
        let r = RequestReader.testParse(Data(raw.utf8))
        switch r {
        case .request?: return 0
        case .reject(let code, _)?: return code
        case nil: return -1
        }
    }
}

@Suite struct ObjectFitTests {
    @Test func signatureNeverClipped() {
        let crop = CGRect(x: 0, y: 0, width: 612, height: 792)
        for size in [18.0, 28.0, 40.0] {
            let font = Objects.signatureFont(size: size)
            let r = Objects.fitted(CGRect(x: 300, y: 100, width: 120, height: 24), text: "Harikanth Lingutla", font: font, page: crop)
            let line = ("Harikanth Lingutla" as NSString).size(withAttributes: [.font: font])
            #expect(r.height >= ceil(font.ascender - font.descender) + 8)   // room below the baseline for swashes
            #expect(r.width >= line.width + 8)                              // one line, no wrapping
            #expect(r.minY == 100)                                          // top edge stays put (top-left points)
        }
    }
}

@Suite struct ExtractionCheckTests {
    func invoice(sub: Double?, tax: Double?, total: Double?, items: [(Double?, Double?, Double?)], issued: String? = "2026-10-14", due: String? = "2026-11-13") -> InvoiceResult {
        InvoiceResult(vendor: "V", vendorAddress: nil, billTo: nil, invoiceNumber: "1", invoiceDate: issued, dueDate: due, poNumber: nil,
                      currency: "USD", subtotal: sub, tax: tax, total: total, amountDue: nil,
                      lineItems: items.enumerated().map { InvoiceLineItem(description: "Item \($0.offset)", quantity: $0.element.0, unitPrice: $0.element.1, amount: $0.element.2) },
                      method: "test", warnings: [])
    }

    @Test func consistentInvoiceHasNoProblems() {
        #expect(ExtractionCheck.problems(invoice(sub: 109, tax: 8.72, total: 117.72, items: [(2, 4.5, 9), (1, 100, 100)])).isEmpty)
    }

    @Test func findsWhatDoesntAddUp() {
        let p = ExtractionCheck.problems(invoice(sub: 120, tax: 8, total: 130, items: [(2, 4.5, 9.5), (1, 100, 100)], due: "2026-09-01"))
        #expect(p.contains { $0.contains("2 × 4.50 is 9.00, not 9.50") })
        #expect(p.contains { $0.contains("add up to 109.50, but the subtotal is 120.00") })
        #expect(p.contains { $0.contains("plus tax 8.00 is 128.00, but the total is 130.00") })
        #expect(p.contains { $0.contains("before the invoice date") })
    }

    @Test func checksRunningBalances() {
        let t = [Transaction(date: "2026-10-02", description: "A", amount: -10, balance: 90, page: 1, reconciled: false),
                 Transaction(date: "2026-10-03", description: "B", amount: 5, balance: 96, page: 1, reconciled: false)]
        let p = ExtractionCheck.problems(t, opening: 100)
        #expect(p.count == 1 && p[0].contains("90.00 + 5.00 is 95.00, but the balance shows 96.00"))
    }
}
