import Foundation
import FoundationModels

/// On-device Apple Intelligence extraction (no network, free). Used to read invoices whose layout
/// the label rules miss, and as a fallback for statements the layout parser can't read.
enum AIExtractor {
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    @Generable
    struct AIInvoice {
        @Guide(description: "Name of the company or person who issued the invoice")
        var vendor: String
        @Guide(description: "Invoice number exactly as printed, or empty")
        var invoiceNumber: String
        @Guide(description: "Invoice date as YYYY-MM-DD, or empty")
        var invoiceDate: String
        @Guide(description: "Due date as YYYY-MM-DD, or empty")
        var dueDate: String
        @Guide(description: "Who the invoice is billed to, one line, or empty")
        var billTo: String
        @Guide(description: "ISO currency code such as USD, EUR, INR, or empty")
        var currency: String
        @Guide(description: "Subtotal before tax, or 0 if not shown")
        var subtotal: Double
        @Guide(description: "Total tax, or 0 if not shown")
        var tax: Double
        @Guide(description: "Grand total, or 0 if not shown")
        var total: Double
        @Guide(description: "Line items in order")
        var lineItems: [AILineItem]
    }

    @Generable
    struct AILineItem {
        var description: String
        @Guide(description: "Quantity, or 0 if not shown")
        var quantity: Double
        @Guide(description: "Unit price, or 0 if not shown")
        var unitPrice: Double
        @Guide(description: "Line total")
        var amount: Double
    }

    @Generable
    struct AITransactions {
        @Guide(description: "Every transaction row on this page, in order. Skip balance and total lines.")
        var transactions: [AITransaction]
    }

    @Generable
    struct AITransaction {
        @Guide(description: "Date as YYYY-MM-DD")
        var date: String
        var description: String
        @Guide(description: "Amount: negative for money out (debits, withdrawals, purchases), positive for money in")
        var amount: Double
        @Guide(description: "Running balance after this row, or 0 if not shown")
        var balance: Double
    }

    /// Map-reduce summary that fits the on-device model's small context: summarize chunks,
    /// then summarize the summaries.
    static func summarize(_ text: String, chunkChars: Int = 6000, maxChunks: Int = 10) async throws -> String {
        let chunks = stride(from: 0, to: min(text.count, chunkChars * maxChunks), by: chunkChars).map { start -> String in
            let a = text.index(text.startIndex, offsetBy: start)
            let b = text.index(a, offsetBy: min(chunkChars, text.distance(from: a, to: text.endIndex)))
            return String(text[a..<b])
        }
        guard !chunks.isEmpty else { return "" }
        if chunks.count == 1 {
            let s = LanguageModelSession(instructions: "Summarize documents faithfully in plain English. Use short bullet points. No preamble.")
            return try await s.respond(to: "Summarize in 5 to 8 bullets:\n\n\(chunks[0])").content
        }
        var notes: [String] = []
        for c in chunks {
            let s = LanguageModelSession(instructions: "Extract the key points of a document section. 3 short bullets. No preamble.")
            notes.append(try await s.respond(to: c).content)
        }
        let s = LanguageModelSession(instructions: "Combine section notes into one faithful summary. Use 6 to 10 short bullets, most important first. No preamble.")
        return try await s.respond(to: notes.joined(separator: "\n")).content
    }

    @Generable
    struct AIMarkIntent {
        @Guide(description: "replace: the request changes what the marked words say. delete: the request removes them. other: anything else, such as signing, adding something next to them, formatting, or questions.")
        var action: String
        @Guide(description: "For replace: the marked words with only what the request names changed; every other word, number and punctuation mark stays exactly as printed. Dates: 'the 12th' or 'the twelfth' is the day of the month, so 'October 14, 2026,' becomes 'October 12, 2026,' (never December). Keep labels like 'Due Date:' if they were marked. Empty otherwise.")
        var replacement: String
    }

    /// What a pen mark plus a short spoken request means, as a structured answer the small model
    /// fills reliably: replace or delete the marked words, or "other" for the full assistant.
    static func markIntent(marked: String, request: String) async throws -> (action: String, replacement: String) {
        let session = LanguageModelSession(instructions: "You turn a request about some marked words into an edit. Change only the part the request names and copy the rest exactly. Examples: marked \"October 14, 2026,\" + \"make this the 12th\" → \"October 12, 2026,\". Marked \"$2,400.00\" + \"make it 2,600\" → \"$2,600.00\". Marked \"Jane Doe\" + \"spell it Jayne\" → \"Jayne Doe\". Answer only with the fields asked for.")
        let r = try await session.respond(to: "Marked words: \"\(marked.prefix(400))\"\nRequest: \"\(request.prefix(400))\"", generating: AIMarkIntent.self).content
        return (r.action.lowercased().trimmingCharacters(in: .whitespaces), r.replacement)
    }

    /// `problems`: what was wrong with an earlier reading, to read the text again with.
    static func invoice(text: String, problems: [String] = []) async throws -> InvoiceResult {
        let session = LanguageModelSession(instructions: "You read invoices and receipts and copy their fields exactly. Never invent values; use empty strings or 0 when a field is missing.")
        let again = problems.isEmpty ? "" : "\n\nAn earlier reading had these problems. Read the text again carefully and correct any misread values; never change a number just to make it add up:\n- " + problems.joined(separator: "\n- ")
        let r = try await session.respond(to: "Invoice text:\n\n\(text.prefix(9000))" + again, generating: AIInvoice.self).content
        func s(_ v: String) -> String? { v.trimmingCharacters(in: .whitespaces).isEmpty ? nil : v }
        func d(_ v: Double) -> Double? { v == 0 ? nil : v }
        return InvoiceResult(vendor: s(r.vendor), vendorAddress: nil, billTo: s(r.billTo), invoiceNumber: s(r.invoiceNumber),
                             invoiceDate: s(r.invoiceDate), dueDate: s(r.dueDate), poNumber: nil, currency: s(r.currency),
                             subtotal: d(r.subtotal), tax: d(r.tax), total: d(r.total), amountDue: nil,
                             lineItems: r.lineItems.map { InvoiceLineItem(description: $0.description, quantity: d($0.quantity), unitPrice: d($0.unitPrice), amount: $0.amount) },
                             method: "apple-intelligence", warnings: [])
    }

    static func transactions(pages: [(page: Int, text: String)], problems: [String] = []) async throws -> [Transaction] {
        var out: [Transaction] = []
        let again = problems.isEmpty ? "" : "\n\nAn earlier reading had these problems. Read the rows again carefully (signs, amounts, balances); never change a number just to make it add up:\n- " + problems.joined(separator: "\n- ")
        for p in pages where !p.text.isEmpty {
            let session = LanguageModelSession(instructions: "You copy bank statement transactions exactly as printed. Never invent rows.")
            let r = try await session.respond(to: "Statement page \(p.page):\n\n\(p.text.prefix(7000))" + again, generating: AITransactions.self).content
            out += r.transactions.map {
                Transaction(date: $0.date, description: $0.description, amount: $0.amount,
                            balance: $0.balance == 0 ? nil : $0.balance, page: p.page, reconciled: false)
            }
        }
        return out
    }
}
