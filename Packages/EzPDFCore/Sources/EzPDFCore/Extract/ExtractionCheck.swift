import Foundation

/// Checks extracted numbers against each other, the way a careful person would before trusting them.
/// Each problem is a sentence a person (or a model asked to read again) can act on.
public enum ExtractionCheck {
    /// Equal to the cent, or within half a percent on large amounts.
    static func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= max(0.015, abs(b) * 0.005) }

    static func money(_ v: Double) -> String { String(format: "%.2f", v) }

    static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Problems with an invoice's numbers and dates.
    public static func problems(_ inv: InvoiceResult) -> [String] {
        var out: [String] = []
        if inv.total == nil && inv.amountDue == nil { out.append("No total was found.") }
        for item in inv.lineItems {
            if let q = item.quantity, let u = item.unitPrice, let a = item.amount, !close(q * u, a) {
                out.append("Line “\(item.description.prefix(40))”: \(String(format: "%g", q)) × \(money(u)) is \(money(q * u)), not \(money(a)).")
            }
        }
        let amounts = inv.lineItems.compactMap(\.amount)
        if amounts.count == inv.lineItems.count, !amounts.isEmpty {
            let sum = amounts.reduce(0, +)
            if let sub = inv.subtotal, !close(sum, sub) {
                out.append("The line items add up to \(money(sum)), but the subtotal is \(money(sub)).")
            } else if inv.subtotal == nil, inv.tax == nil, let total = inv.total, !close(sum, total) {
                out.append("The line items add up to \(money(sum)), but the total is \(money(total)).")
            }
        }
        if let sub = inv.subtotal, let tax = inv.tax, let total = inv.total, !close(sub + tax, total) {
            out.append("Subtotal \(money(sub)) plus tax \(money(tax)) is \(money(sub + tax)), but the total is \(money(total)) (fine if there's shipping or a discount).")
        }
        var issued: Date?
        for (label, value) in [("invoice date", inv.invoiceDate), ("due date", inv.dueDate)] {
            guard let value, !value.isEmpty else { continue }
            guard let d = isoDay.date(from: value) else { out.append("The \(label) “\(value)” isn't a real date."); continue }
            if label == "invoice date" { issued = d } else if let issued, d < issued { out.append("The due date \(value) is before the invoice date.") }
        }
        return out
    }

    /// Problems with transactions that carry a running balance: each balance should be the one before
    /// plus the transaction.
    public static func problems(_ transactions: [Transaction], opening: Double? = nil) -> [String] {
        var out: [String] = []
        var previous = opening
        for t in transactions {
            if let p = previous, let b = t.balance, !close(p + t.amount, b) {
                out.append("On \(t.date), “\(t.description.prefix(30))”: \(money(p)) \(t.amount < 0 ? "−" : "+") \(money(abs(t.amount))) is \(money(p + t.amount)), but the balance shows \(money(b)).")
                if out.count >= 8 { break }
            }
            previous = t.balance ?? previous.map { $0 + t.amount }
        }
        return out
    }
}
