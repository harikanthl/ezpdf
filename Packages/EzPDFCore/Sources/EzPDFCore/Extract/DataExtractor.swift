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
                if let t = try? await AIExtractor.transactions(pages: pages), !t.isEmpty {
                    s.transactions = t
                    s.totalIn = t.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount }
                    s.totalOut = t.filter { $0.amount < 0 }.reduce(0) { $0 - $1.amount }
                    s.method = "apple-intelligence"
                    s.warnings = ["Read by Apple Intelligence because the layout wasn't recognized. Check the rows."]
                }
            }
            return ExtractionResult(kind: .statement, statement: s)
        case .invoice:
            var inv = InvoiceParser.parse(lines)
            if useAI, AIExtractor.isAvailable {
                let text = lines.map(\.text).joined(separator: "\n")
                if let ai = try? await AIExtractor.invoice(text: text) { inv = merge(layout: inv, ai: ai) }
            }
            return ExtractionResult(kind: .invoice, invoice: inv)
        default:
            return ExtractionResult(kind: .tables, tables: TableExtractor.tables(lines))
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
}
