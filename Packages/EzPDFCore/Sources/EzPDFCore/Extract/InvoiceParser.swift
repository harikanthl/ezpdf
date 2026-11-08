import Foundation

public struct InvoiceLineItem: Codable, Sendable, Hashable {
    public var description: String
    public var quantity: Double?
    public var unitPrice: Double?
    public var amount: Double?
}

public struct InvoiceResult: Codable, Sendable {
    public var vendor: String?
    public var vendorAddress: String?
    public var billTo: String?
    public var invoiceNumber: String?
    public var invoiceDate: String?
    public var dueDate: String?
    public var poNumber: String?
    public var currency: String?
    public var subtotal: Double?
    public var tax: Double?
    public var total: Double?
    public var amountDue: Double?
    public var lineItems: [InvoiceLineItem]
    public var method: String
    public var warnings: [String]

    public var fieldRows: [[String]] {
        [["Field", "Value"],
         ["Vendor", vendor ?? ""], ["Vendor address", vendorAddress ?? ""], ["Bill to", billTo ?? ""],
         ["Invoice number", invoiceNumber ?? ""], ["Invoice date", invoiceDate ?? ""], ["Due date", dueDate ?? ""],
         ["PO number", poNumber ?? ""], ["Currency", currency ?? ""], ["Subtotal", Money.format(subtotal)],
         ["Tax", Money.format(tax)], ["Total", Money.format(total)], ["Amount due", Money.format(amountDue)]]
    }

    public static let itemHeader = ["Description", "Quantity", "Unit price", "Amount"]
    public var itemRows: [[String]] {
        lineItems.map { [$0.description, $0.quantity.map { String(format: "%g", $0) } ?? "", Money.format($0.unitPrice), Money.format($0.amount)] }
    }
}

/// Invoice / receipt → fields and line items. Label-driven ("Invoice #", "Due date", "Total"),
/// with line items read from rows that end in amounts.
public enum InvoiceParser {
    public static func parse(_ lines: [TextLine]) -> InvoiceResult {
        let texts = lines.map(\.text)
        let all = texts.joined(separator: "\n")
        let dayFirst = DateToken.detectDayFirst(texts)

        func value(after pattern: String) -> String? {
            let re = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            for (i, line) in lines.enumerated() {
                let t = line.text
                guard let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
                      let r = Range(m.range, in: t) else { continue }
                var rest = String(t[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " :#.-\t"))
                // Value in the next cell, or on the line below when the label sits alone.
                if rest.isEmpty, i + 1 < lines.count { rest = lines[i + 1].cells.first?.text ?? "" }
                if !rest.isEmpty { return rest }
            }
            return nil
        }
        func date(after pattern: String) -> String? {
            guard let v = value(after: pattern), let d = DateToken.parse(v, dayFirst: dayFirst) else { return nil }
            return DateToken.iso(d, fallbackYear: Calendar.current.component(.year, from: Date()))
        }
        func amount(after pattern: String, last: Bool = true) -> Double? {
            let re = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            var found: Double?
            for line in lines {
                let t = line.text
                guard re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil else { continue }
                if let cell = line.cells.last(where: { Money.isMoney($0.text) }) ?? StatementParser.splitTrailingAmounts(line.cells).last(where: { Money.isMoney($0.text) }),
                   let p = Money.parse(cell.text) {
                    found = p.value
                    if !last { return found }
                }
            }
            return found
        }

        var r = InvoiceResult(lineItems: [], method: "layout", warnings: [])
        r.invoiceNumber = value(after: #"\b(invoice|inv|bill|receipt)\s*(no\.?|number|num|#)\s*"#).map { firstToken($0) }
        r.poNumber = value(after: #"\b(p\.?o\.?|purchase order)\s*(no\.?|number|#)?\s*[:#]"#).map { firstToken($0) }
        r.invoiceDate = date(after: #"\b(invoice date|date of issue|issue date|issued|bill date|date)\b"#)
        r.dueDate = date(after: #"\b(due date|payment due|due by|due on|due)\b"#)
        r.subtotal = amount(after: #"\bsub\s?-?total\b"#)
        r.tax = amount(after: #"\b(tax|vat|gst|hst|sales tax)\b"#, last: false)
        r.total = amount(after: #"\b(grand total|total amount|invoice total|total)\b(?!\s*(tax|vat|gst|hours|qty|quantity))"#)
        r.amountDue = amount(after: #"\b(amount due|balance due|total due|amount payable|please pay)\b"#)
        r.currency = Money.currency(in: all)
        r.billTo = block(after: #"^\s*(bill(ed)? to|invoice to|sold to|customer)\b"#, in: lines)
        r.vendor = vendorName(lines)
        r.lineItems = lineItems(lines)

        if r.total == nil { r.total = r.amountDue }
        if let sub = r.subtotal, let tot = r.total, let tax = r.tax, abs(sub + tax - tot) > 0.01 {
            r.warnings.append(String(format: "Subtotal %.2f + tax %.2f doesn't equal total %.2f.", sub, tax, tot))
        }
        let itemsSum = r.lineItems.compactMap(\.amount).reduce(0, +)
        if let sub = r.subtotal ?? r.total, !r.lineItems.isEmpty, abs(itemsSum - sub) > 0.01 {
            r.warnings.append(String(format: "Line items add up to %.2f, not %.2f.", itemsSum, sub))
        }
        if r.total == nil && r.invoiceNumber == nil { r.warnings.append("This doesn't look like an invoice.") }
        return r
    }

    static func firstToken(_ s: String) -> String {
        String(s.split(separator: " ").first ?? Substring(s))
    }

    static func vendorName(_ lines: [TextLine]) -> String? {
        // The largest text near the top of page 1 is almost always the seller's name or logo text.
        let top = lines.filter { $0.page == 0 }.prefix(12)
        let skip = try! NSRegularExpression(pattern: #"^(invoice|receipt|tax invoice|bill|statement|page \d|date)\b"#, options: .caseInsensitive)
        let candidates = top.filter { l in
            let t = l.text
            return t.count >= 2 && t.count < 60 && skip.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) == nil
                && !Money.isMoney(t) && t.rangeOfCharacter(from: .letters) != nil
        }
        return candidates.max { $0.height < $1.height }?.cells.first?.text
    }

    static func block(after pattern: String, in lines: [TextLine]) -> String? {
        let re = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        guard let i = lines.firstIndex(where: { re.firstMatch(in: $0.text, range: NSRange($0.text.startIndex..., in: $0.text)) != nil }) else { return nil }
        let labelCell = lines[i].cells.first { re.firstMatch(in: $0.text, range: NSRange($0.text.startIndex..., in: $0.text)) != nil }
        let x = labelCell?.rect.minX ?? 0
        var parts: [String] = []
        if let after = labelCell?.text.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: CharacterSet(charactersIn: " :")), !after.isEmpty { parts.append(after) }
        for line in lines[(i + 1)...].prefix(5) {
            let lower = line.text.lowercased()
            if line.cells.count >= 3 || lower.contains("description") || lower.contains("qty") || lower.contains("ship to") { break }
            if line.y - lines[i].y > lines[i].height * 7 { break }
            guard let c = line.cells.first(where: { abs($0.rect.minX - x) < 30 }), !Money.isMoney(c.text) else { break }
            if c.text.isEmpty || c.text.lowercased().contains("ship to") { break }
            parts.append(c.text)
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    static func lineItems(_ lines: [TextLine]) -> [InvoiceLineItem] {
        let stop = try! NSRegularExpression(pattern: #"\b(sub\s?-?total|total|tax|vat|gst|amount due|balance due|discount|shipping)\b"#, options: .caseInsensitive)
        var items: [InvoiceLineItem] = []
        var inTable = false
        for line in lines {
            let t = line.text.lowercased()
            if t.contains("description") || t.contains("item") && (t.contains("qty") || t.contains("quantity") || t.contains("amount") || t.contains("price")) {
                inTable = true; continue
            }
            guard inTable else { continue }
            if stop.firstMatch(in: line.text, range: NSRange(line.text.startIndex..., in: line.text)) != nil { inTable = false; continue }
            var cells = StatementParser.splitTrailingAmounts(line.cells)
            var nums: [Double] = []
            while let last = cells.last, let v = number(last.text) { nums.insert(v, at: 0); cells.removeLast() }
            let desc = cells.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !desc.isEmpty else { continue }
            if nums.isEmpty {
                // Wrapped description line.
                if let lastIndex = items.indices.last, desc.count < 100 { items[lastIndex].description += " " + desc }
                continue
            }
            var item = InvoiceLineItem(description: desc, quantity: nil, unitPrice: nil, amount: nums.last)
            if nums.count >= 3 { item.quantity = nums[nums.count - 3]; item.unitPrice = nums[nums.count - 2] }
            else if nums.count == 2 { item.quantity = nums[0]; item.unitPrice = nums[0] > 0 ? nums[1] / nums[0] : nil
                if let q = item.quantity, q != q.rounded() || q > 10_000 { item.quantity = nil; item.unitPrice = nums[0] }
            }
            items.append(item)
        }
        return items
    }

    static func number(_ s: String) -> Double? {
        if let m = Money.parse(s) { return m.value }
        let t = s.replacingOccurrences(of: ",", with: "")
        if t.range(of: #"^\d{1,5}(\.\d+)?$"#, options: .regularExpression) != nil { return Double(t) }
        return nil
    }
}
