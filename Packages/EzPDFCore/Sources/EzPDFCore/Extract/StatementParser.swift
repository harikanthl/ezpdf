import Foundation

public struct Transaction: Codable, Sendable, Hashable {
    public var date: String
    public var description: String
    /// Signed: money out is negative, money in is positive.
    public var amount: Double
    public var balance: Double?
    public var page: Int
    /// True when this row's amount plus the previous balance equals this row's balance.
    public var reconciled: Bool
}

public struct StatementResult: Codable, Sendable {
    public var transactions: [Transaction]
    public var openingBalance: Double?
    public var closingBalance: Double?
    public var totalIn: Double
    public var totalOut: Double
    public var currency: String?
    /// Share of rows whose balance checks out, 0…1. Nil when the statement has no running balance.
    public var reconciledShare: Double?
    public var method: String
    public var warnings: [String]

    public static let csvHeader = ["Date", "Description", "Amount", "Money out", "Money in", "Balance", "Page"]

    public var rows: [[String]] {
        transactions.map {
            [$0.date, $0.description, Money.format($0.amount),
             $0.amount < 0 ? Money.format(-$0.amount) : "", $0.amount > 0 ? Money.format($0.amount) : "",
             Money.format($0.balance), String($0.page)]
        }
    }
}

/// Bank / credit-card statement → transactions. Works from positioned lines so it can use column
/// headers (Debit, Credit, Balance) when present, and checks every row against the running balance.
public enum StatementParser {
    enum Column { case debit, credit, amount, balance }

    static let summaryWords = try! NSRegularExpression(pattern:
        #"\b(total|subtotal|balance forward|brought forward|carried forward|opening balance|closing balance|ending balance|beginning balance|previous balance|new balance|starting balance|statement balance|minimum payment|available balance|daily balance)\b"#,
        options: .caseInsensitive)
    static let openingWords = try! NSRegularExpression(pattern: #"\b(opening|beginning|previous|starting) balance|balance (brought )?forward|brought forward\b"#, options: .caseInsensitive)
    static let closingWords = try! NSRegularExpression(pattern: #"\b(closing|ending|new) balance|carried forward\b"#, options: .caseInsensitive)

    public static func parse(_ lines: [TextLine]) -> StatementResult {
        let allText = lines.map(\.text).joined(separator: "\n")
        let dayFirst = DateToken.detectDayFirst(lines.compactMap { $0.cells.first?.text })
        let baseYear = mostCommonYear(in: allText) ?? Calendar.current.component(.year, from: Date())
        var inferredYear = Set<Int>()   // indices of rows whose date had no year

        var headers: [Column: CGRect] = [:]
        var headerPage = -1
        var txns: [Transaction] = []
        var opening: Double?
        var closing: Double?
        var lastDate: DateToken.Parsed?
        var lastLine: TextLine?
        var lastWasTxn = false

        for line in lines {
            if let h = headerColumns(line) { headers = h; headerPage = line.page; lastWasTxn = false; continue }
            let cells = splitTrailingAmounts(line.cells)
            let text = cells.map(\.text).joined(separator: " ")
            // Peel amounts from the right.
            var amountCells: [TextFragment] = []
            var rest = cells
            while let last = rest.last, Money.isMoney(last.text) { amountCells.insert(last, at: 0); rest.removeLast() }

            let date = rest.first.flatMap { DateToken.parse($0.text, dayFirst: dayFirst) }
                ?? (rest.count > 1 ? DateToken.parse(rest[0].text + " " + rest[1].text, dayFirst: dayFirst) : nil)
            var desc = rest.map(\.text).joined(separator: " ")
            if let date { desc = String(desc.dropFirst(min(date.length, desc.count))) }
            // A second date column (posting date) right after the first.
            if date != nil, let second = DateToken.parse(desc.trimmingCharacters(in: .whitespaces), dayFirst: dayFirst) {
                desc = String(desc.trimmingCharacters(in: .whitespaces).dropFirst(second.length))
            }
            desc = desc.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters.subtracting(CharacterSet(charactersIn: "#&@"))))
            let range = NSRange(text.startIndex..., in: text)

            if summaryWords.firstMatch(in: text, range: range) != nil {
                let value = amountCells.last.flatMap { Money.parse($0.text) }?.value
                if openingWords.firstMatch(in: text, range: range) != nil, opening == nil { opening = value }
                if closingWords.firstMatch(in: text, range: range) != nil, let value { closing = value }
                lastWasTxn = false
                continue
            }

            if !amountCells.isEmpty, date != nil || (lastWasTxn && lastDate != nil && line.page == lastLine?.page) {
                guard let d = date ?? lastDate else { continue }
                var amount: Double?
                var balance: Double?
                var signKnown = false
                let assigned = assign(amountCells, headers: line.page >= headerPage ? headers : [:])
                for (col, cell) in assigned {
                    guard let p = Money.parse(cell.text) else { continue }
                    switch col {
                    case .debit: amount = -p.value; signKnown = true
                    case .credit: amount = p.value; signKnown = true
                    case .amount:
                        amount = p.explicitSign == -1 ? -p.value : p.value
                        signKnown = p.explicitSign != 0
                    case .balance: balance = p.explicitSign == -1 ? -p.value : p.value
                    }
                }
                guard var a = amount else { continue }
                // Fix the sign from the running balance when the layout didn't say.
                var reconciled = false
                let prev = txns.last?.balance ?? (txns.isEmpty ? opening : nil)
                if let prev, let balance {
                    if abs(prev + a - balance) < 0.005 { reconciled = true }
                    else if abs(prev - abs(a) - balance) < 0.005 { a = -abs(a); reconciled = true }
                    else if abs(prev + abs(a) - balance) < 0.005 { a = abs(a); reconciled = true }
                } else if !signKnown, headers.isEmpty {
                    a = guessSign(a, description: desc)
                }
                if d.year == nil { inferredYear.insert(txns.count) }
                txns.append(Transaction(date: DateToken.iso(d, fallbackYear: baseYear), description: desc,
                                        amount: a, balance: balance, page: line.page + 1, reconciled: reconciled))
                lastDate = d
                lastWasTxn = true
                lastLine = line
                continue
            }

            // Continuation of the previous description (wrapped merchant names, references).
            if lastWasTxn, amountCells.isEmpty, date == nil, let prevLine = lastLine, line.page == prevLine.page,
               line.y - prevLine.y < prevLine.height * 2.6, !desc.isEmpty, desc.count < 120,
               (line.cells.first?.rect.minX ?? 0) > (prevLine.cells.first?.rect.minX ?? 0) + 2 {
                txns[txns.count - 1].description += " " + desc
                lastLine = line
                continue
            }
            if !desc.isEmpty { lastWasTxn = false }
        }

        fixYearWrap(&txns, inferred: inferredYear, text: allText)
        let totalIn = txns.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount }
        let totalOut = txns.filter { $0.amount < 0 }.reduce(0) { $0 - $1.amount }
        let withBalance = txns.filter { $0.balance != nil }
        let share = withBalance.isEmpty ? nil : Double(withBalance.filter(\.reconciled).count) / Double(max(1, withBalance.count - 1))
        var warnings: [String] = []
        if txns.isEmpty { warnings.append("No transactions found. Is this a statement?") }
        if let share, share < 0.9, !txns.isEmpty {
            warnings.append("Only \(Int(min(share, 1) * 100))% of rows match the running balance. Check the signs before using totals.")
        }
        if let o = opening, let c = closing, !txns.isEmpty, abs(o + totalIn - totalOut - c) > 0.01 {
            warnings.append(String(format: "Opening %.2f + in %.2f − out %.2f doesn't equal closing %.2f.", o, totalIn, totalOut, c))
        }
        return StatementResult(transactions: txns, openingBalance: opening, closingBalance: closing,
                               totalIn: (totalIn * 100).rounded() / 100, totalOut: (totalOut * 100).rounded() / 100, currency: Money.currency(in: allText),
                               reconciledShare: share.map { min($0, 1) }, method: "layout", warnings: warnings)
    }

    static let headerPatterns: [(Column, String)] = [
        (.debit, #"\b(withdrawals?|debits?|paid out|money out|charges|payments? out)\b"#),
        (.credit, #"\b(deposits?|credits?|paid in|money in|payments? in)\b"#),
        (.balance, #"\bbalance\b"#),
        (.amount, #"\bamount\b"#),
    ]

    /// Column header row: at least two money headers, or date + description + one money header.
    /// OCR often merges a header row into one run ("Withdrawals Deposits Balance"); each word's
    /// position is then estimated from where it sits in the run.
    static func headerColumns(_ line: TextLine) -> [Column: CGRect]? {
        var found: [Column: CGRect] = [:]
        var hasDate = false, hasDesc = false
        if Money.isMoney(line.cells.last?.text ?? "") { return nil }
        for cell in line.cells {
            let t = cell.text.lowercased()
            if t.count > 60 { return nil }
            let ns = t as NSString
            for (col, pattern) in headerPatterns where found[col] == nil {
                guard let r = t.range(of: pattern, options: .regularExpression) else { continue }
                let nr = NSRange(r, in: t)
                let x0 = cell.rect.minX + cell.rect.width * CGFloat(nr.location) / CGFloat(max(1, ns.length))
                let w = cell.rect.width * CGFloat(nr.length) / CGFloat(max(1, ns.length))
                found[col] = CGRect(x: x0, y: cell.rect.minY, width: w, height: cell.rect.height)
            }
            if t.range(of: #"\bdate\b"#, options: .regularExpression) != nil { hasDate = true }
            if t.range(of: #"\b(description|details|transaction|particulars|narration|merchant|payee)\b"#, options: .regularExpression) != nil { hasDesc = true }
        }
        if found.count >= 2 || (hasDate && hasDesc && found.count >= 1) { return found }
        return nil
    }

    static func assign(_ cells: [TextFragment], headers: [Column: CGRect]) -> [(Column, TextFragment)] {
        if !headers.isEmpty {
            var used = Set<Column>()
            var out: [(Column, TextFragment)] = []
            for cell in cells {
                let best = headers.filter { !used.contains($0.key) }.min { a, b in
                    distance(cell.rect, a.value) < distance(cell.rect, b.value)
                }
                if let best { used.insert(best.key); out.append((best.key, cell)) }
            }
            if out.count == cells.count, out.contains(where: { $0.0 != .balance }) { return out }
        }
        switch cells.count {
        case 1: return [(.amount, cells[0])]
        case 2: return [(.amount, cells[0]), (.balance, cells[1])]
        default:
            // Debit and credit columns with one left empty usually leaves two; three means both.
            return [(.debit, cells[cells.count - 3]), (.credit, cells[cells.count - 2]), (.balance, cells[cells.count - 1])]
        }
    }

    static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        min(abs(a.maxX - b.maxX), abs(a.midX - b.midX), abs(a.minX - b.minX))
    }

    /// OCR and tight layouts sometimes glue an amount onto the description; split it off.
    static func splitTrailingAmounts(_ cells: [TextFragment]) -> [TextFragment] {
        var out: [TextFragment] = []
        for cell in cells {
            var tokens = cell.text.split(separator: " ").map(String.init)
            var tail: [String] = []
            while tokens.count > 1, let last = tokens.last, Money.isMoney(last) { tail.insert(last, at: 0); tokens.removeLast() }
            if tail.isEmpty || tokens.isEmpty { out.append(cell); continue }
            let total = CGFloat(cell.text.count)
            let headLen = CGFloat(tokens.joined(separator: " ").count)
            var head = cell
            head.text = tokens.joined(separator: " ")
            head.rect.size.width = cell.rect.width * headLen / total
            out.append(head)
            var x = head.rect.maxX
            for t in tail {
                let w = cell.rect.width * CGFloat(t.count + 1) / total
                out.append(TextFragment(text: t, rect: CGRect(x: x, y: cell.rect.minY, width: w, height: cell.rect.height), page: cell.page))
                x += w
            }
        }
        return out
    }

    static func guessSign(_ a: Double, description: String) -> Double {
        let d = description.lowercased()
        let incoming = ["deposit", "salary", "payroll", "refund", "interest paid", "transfer from", "credit", "direct dep", "zelle from", "received"]
        return incoming.contains(where: d.contains) ? abs(a) : -abs(a)
    }

    static func yearCounts(in text: String) -> [Int: Int] {
        let re = try! NSRegularExpression(pattern: #"\b(19[89]\d|20\d{2})\b"#)
        var counts: [Int: Int] = [:]
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let r = Range(m.range, in: text), let y = Int(text[r]) { counts[y, default: 0] += 1 }
        }
        return counts
    }

    /// The year mentioned most; ties go to the later year (the statement's end), deterministically.
    static func mostCommonYear(in text: String) -> Int? {
        yearCounts(in: text).max { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }?.key
    }

    /// Rows without a year on a statement that spans New Year (Dec and Jan rows, and both years
    /// mentioned): late-year months get the earlier year, early months the later one. Rows that
    /// printed their own year are never changed.
    static func fixYearWrap(_ txns: inout [Transaction], inferred: Set<Int>, text: String) {
        guard !inferred.isEmpty else { return }
        let months = Set(inferred.compactMap { i in Int(txns[i].date.dropFirst(5).prefix(2)) })
        guard months.contains(12), months.contains(1) else { return }
        let years = Set(yearCounts(in: text).keys)
        guard let early = years.filter({ years.contains($0 + 1) }).max() else { return }
        for i in inferred {
            let parts = txns[i].date.split(separator: "-")
            guard parts.count == 3, let m = Int(parts[1]) else { continue }
            let y = m >= 7 ? early : early + 1
            txns[i].date = String(format: "%04d-%@-%@", y, String(parts[1]), String(parts[2]))
        }
    }
}
