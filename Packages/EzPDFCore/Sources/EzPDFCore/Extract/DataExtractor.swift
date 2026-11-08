import Foundation
import PDFKit

public enum ExtractKind: String, Codable, Sendable, CaseIterable {
    case auto, statement, invoice, tables

    public static func parse(_ s: String?) -> ExtractKind {
        switch s?.lowercased() {
        case "statement", "bank", "bank_statement", "transactions", "credit_card": return .statement
        case "invoice", "receipt", "bill": return .invoice
        case "tables", "table": return .tables
        default: return .auto
        }
    }
}

public struct ExtractionResult: Codable, Sendable {
    public var kind: ExtractKind
    public var statement: StatementResult?
    public var invoice: InvoiceResult?
    public var tables: [ExtractedTable]?

    /// Sheets for XLSX export.
    public var sheets: [Spreadsheet.Sheet] {
        switch kind {
        case .statement:
            return [Spreadsheet.Sheet(name: "Transactions", rows: [StatementResult.csvHeader] + (statement?.rows ?? []))]
        case .invoice:
            guard let inv = invoice else { return [] }
            return [Spreadsheet.Sheet(name: "Invoice", rows: inv.fieldRows),
                    Spreadsheet.Sheet(name: "Line items", rows: [InvoiceResult.itemHeader] + inv.itemRows)]
        default:
            return (tables ?? []).enumerated().map { Spreadsheet.Sheet(name: "Table \($0.offset + 1) (p\($0.element.page))", rows: $0.element.rows) }
        }
    }

    /// Rows for CSV export (CSV holds one table).
    public var csvRows: [[String]] {
        switch kind {
        case .statement: return [StatementResult.csvHeader] + (statement?.rows ?? [])
        case .invoice:
            guard let inv = invoice else { return [] }
            if inv.lineItems.isEmpty { return inv.fieldRows }
            return [InvoiceResult.itemHeader] + inv.itemRows
        default:
            var out: [[String]] = []
            for (i, t) in (tables ?? []).enumerated() {
                if i > 0 { out.append([]) }
                out.append(contentsOf: t.rows)
            }
            return out
        }
    }
}

/// Front door for statements, invoices and tables.
public enum DataExtractor {
    public static func extract(_ doc: PDFDocument, kind: ExtractKind = .auto, useAI: Bool = true) async -> ExtractionResult {
        let lines = await PageText.lines(doc)
        let k = kind == .auto ? detect(lines) : kind
        switch k {
        case .statement:
            var s = StatementParser.parse(lines)
            if s.transactions.isEmpty, useAI, AIExtractor.isAvailable {
                let pages = Dictionary(grouping: lines, by: \.page).sorted { $0.key < $1.key }
                    .map { (page: $0.key + 1, text: $0.value.map(\.text).joined(separator: "\n")) }
                // Read, check the balances, and read again with what didn't add up (at most twice).
                var best: (rows: [Transaction], problems: [String])?
                for _ in 0..<3 {
                    guard let t = try? await AIExtractor.transactions(pages: pages, problems: best?.problems ?? []), !t.isEmpty else { break }
                    let problems = ExtractionCheck.problems(t, opening: s.openingBalance)
                    if best == nil || problems.count < best!.problems.count { best = (t, problems) }
                    if problems.isEmpty { break }
                }
                if let best {
                    let t = best.rows
                    s.transactions = t
                    s.totalIn = t.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount }
                    s.totalOut = t.filter { $0.amount < 0 }.reduce(0) { $0 - $1.amount }
                    s.method = "apple-intelligence"
                    s.warnings = ["Read by Apple Intelligence because the layout wasn't recognized. Check the rows."] + best.problems
                }
            }
            return ExtractionResult(kind: .statement, statement: s)
        case .invoice:
            var inv = InvoiceParser.parse(lines)
            if useAI, AIExtractor.isAvailable {
                let text = lines.map(\.text).joined(separator: "\n")
                // Read, check the numbers against each other, and read again with what didn't add up (at most twice).
                var best: (inv: InvoiceResult, problems: [String])?
                for _ in 0..<3 {
                    guard let ai = try? await AIExtractor.invoice(text: text, problems: best?.problems ?? []) else { break }
                    let merged = merge(layout: inv, ai: ai)
                    let problems = ExtractionCheck.problems(merged)
                    if best == nil || problems.count < best!.problems.count { best = (merged, problems) }
                    if problems.isEmpty { break }
                }
                if let best { inv = best.inv }
            }
            // Whatever read it, say where the numbers don't agree.
            for p in ExtractionCheck.problems(inv) where !inv.warnings.contains(p) { inv.warnings.append(p) }
            return ExtractionResult(kind: .invoice, invoice: inv)
        default:
            let found = await documentTables(doc)
            return ExtractionResult(kind: .tables, tables: found.isEmpty ? TableExtractor.tables(lines) : found)
        }
    }

    /// Statement if many lines start with a date and end in money; invoice if invoice words appear.
    public static func detect(_ lines: [TextLine]) -> ExtractKind {
        let dayFirst = DateToken.detectDayFirst(lines.compactMap { $0.cells.first?.text })
        let txnLike = lines.filter { l in
            guard let first = l.cells.first?.text, DateToken.parse(first, dayFirst: dayFirst) != nil else { return false }
            return StatementParser.splitTrailingAmounts(l.cells).last.map { Money.isMoney($0.text) } ?? false
        }.count
        let text = lines.prefix(80).map(\.text).joined(separator: " ").lowercased()
        let statementWords = ["statement period", "account number", "opening balance", "closing balance", "beginning balance", "ending balance", "account summary", "statement date"]
        let invoiceWords = ["invoice", "bill to", "amount due", "due date", "receipt", "subtotal", "tax invoice"]
        let sScore = txnLike + statementWords.filter(text.contains).count * 3
        let iScore = invoiceWords.filter(text.contains).count * 3
        if sScore >= 6, sScore >= iScore { return .statement }
        if iScore >= 6 { return .invoice }
        return txnLike >= 4 ? .statement : .tables
    }

    /// AI reads structure better; layout rules read printed numbers more reliably. Prefer the
    /// layout value for each number when both exist and the AI's differs.
    static func merge(layout: InvoiceResult, ai: InvoiceResult) -> InvoiceResult {
        var r = ai
        r.vendor = ai.vendor ?? layout.vendor
        r.invoiceNumber = layout.invoiceNumber ?? ai.invoiceNumber
        r.invoiceDate = ai.invoiceDate ?? layout.invoiceDate
        r.dueDate = ai.dueDate ?? layout.dueDate
        r.billTo = ai.billTo ?? layout.billTo
        r.poNumber = layout.poNumber
        r.currency = ai.currency ?? layout.currency
        r.subtotal = layout.subtotal ?? ai.subtotal
        r.tax = layout.tax ?? ai.tax
        r.total = layout.total ?? ai.total
        r.amountDue = layout.amountDue
        if ai.lineItems.isEmpty { r.lineItems = layout.lineItems }
        r.method = "layout+apple-intelligence"
        r.warnings = layout.warnings
        return r
    }

    /// Tables as Apple's document reader sees them (drawn or not). On pages with a text layer, each
    /// cell's words come from the PDF itself, so nothing is misread; scans use the reader's text.
    static func documentTables(_ doc: PDFDocument, maxPages: Int = 50) async -> [ExtractedTable] {
        var out: [ExtractedTable] = []
        for i in 0..<min(doc.pageCount, maxPages) {
            guard let page = doc.page(at: i), let read = try? await DocumentReader.read(page: page, index: i) else { continue }
            let words = PageText.words(page: page, index: i)
            let exact = words.count >= 5
            for t in read.tables where t.rowCount >= 2 && t.columnCount >= 2 {
                var table = t
                if exact {
                    for k in table.cells.indices {
                        let r = table.cells[k].rect.insetBy(dx: -1, dy: -1)
                        let inside = words.filter { r.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }
                            .sorted { (($0.rect.midY / 4).rounded(), $0.rect.minX) < (($1.rect.midY / 4).rounded(), $1.rect.minX) }
                        if !inside.isEmpty { table.cells[k].text = inside.map(\.text).joined(separator: " ") }
                    }
                }
                // Rows and columns that came out empty are dropped.
                var rows = table.grid.map { $0.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
                rows = rows.filter { $0.contains { !$0.isEmpty } }
                let usedColumns = (0..<table.columnCount).filter { c in rows.contains { !$0[c].isEmpty } }
                rows = rows.map { r in usedColumns.map { r[$0] } }
                guard rows.count >= 2, usedColumns.count >= 2 else { continue }
                out.append(ExtractedTable(page: i + 1, rows: rows))
            }
        }
        return out
    }
}
