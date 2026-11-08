import Foundation

/// Money and date recognition shared by the statement and invoice parsers.
public enum Money {
    private static let patterns: [NSRegularExpression] = [
        // 1,234.56  (1,234.56)  -$1,234.56  1,234.56 CR  1234.56-
        #"^\(?[-−+]?\s?[$€£₹¥]?\s?[-−]?\d{1,3}(?:,\d{3})*\.\d{2}\)?(?:\s?(?:CR|DR|Cr|Dr|cr|dr|-|−))?$"#,
        #"^\(?[-−+]?\s?[$€£₹¥]?\s?[-−]?\d+\.\d{2}\)?(?:\s?(?:CR|DR|Cr|Dr|cr|dr|-|−))?$"#,
        // 1.234,56  1 234,56  (European)
        #"^[-−]?\s?[€£]?\s?\d{1,3}(?:[.\s]\d{3})*,\d{2}(?:\s?(?:CR|DR|-|−|€))?$"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    public static func isMoney(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        let r = NSRange(t.startIndex..., in: t)
        return patterns.contains { $0.firstMatch(in: t, range: r) != nil }
    }

    /// Parses an amount. `explicitSign` is -1/+1 when the text says so (minus, parentheses, DR/CR).
    public static func parse(_ s: String) -> (value: Double, explicitSign: Int)? {
        var t = s.trimmingCharacters(in: .whitespaces)
        guard isMoney(t) else { return nil }
        var sign = 0
        if t.hasPrefix("(") && t.hasSuffix(")") || t.contains("(") { sign = -1 }
        let upper = t.uppercased()
        if upper.hasSuffix("DR") { sign = -1 }
        if upper.hasSuffix("CR") { sign = 1 }
        if t.hasPrefix("-") || t.hasPrefix("−") || t.hasSuffix("-") || t.hasSuffix("−") || t.contains("$-") || t.contains("-$") { sign = -1 }
        if t.hasPrefix("+") { sign = 1 }
        let european = t.range(of: #"\d,\d{2}(\D*)$"#, options: .regularExpression) != nil && !t.contains(".") ||
                       t.range(of: #"\.\d{3},\d{2}"#, options: .regularExpression) != nil
        t = t.filter { $0.isNumber || $0 == "." || $0 == "," }
        if european {
            t = t.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        } else {
            t = t.replacingOccurrences(of: ",", with: "")
        }
        guard let v = Double(t) else { return nil }
        return (v, sign)
    }

    public static func format(_ v: Double?) -> String {
        guard let v else { return "" }
        return String(format: "%.2f", v)
    }

    public static func currency(in text: String) -> String? {
        if text.contains("€") || text.range(of: #"\bEUR\b"#, options: .regularExpression) != nil { return "EUR" }
        if text.contains("£") || text.range(of: #"\bGBP\b"#, options: .regularExpression) != nil { return "GBP" }
        if text.contains("₹") || text.range(of: #"\b(INR|Rs\.?)\b"#, options: .regularExpression) != nil { return "INR" }
        if text.contains("¥") { return "JPY" }
        if text.range(of: #"\bCAD\b"#, options: .regularExpression) != nil { return "CAD" }
        if text.range(of: #"\bAUD\b"#, options: .regularExpression) != nil { return "AUD" }
        if text.contains("$") || text.range(of: #"\bUSD\b"#, options: .regularExpression) != nil { return "USD" }
        return nil
    }
}

public enum DateToken {
    public struct Parsed: Equatable { public var year: Int?; public var month: Int; public var day: Int; public var length: Int }

    static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    // "." as a separator only with a year (03.14.2026), so amounts like "3.14" aren't dates.
    private static let numeric = try! NSRegularExpression(pattern: #"^(\d{1,2})(?:[/\-](\d{1,2})(?:[/\-](\d{2,4}))?|\.(\d{1,2})\.(\d{2,4}))\b"#)
    private static let iso = try! NSRegularExpression(pattern: #"^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})\b"#)
    private static let dayMonth = try! NSRegularExpression(pattern: #"^(\d{1,2})(?:st|nd|rd|th)?[\s\-]?(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?(?:[\s\-,]+(\d{2,4}))?\b"#, options: .caseInsensitive)
    private static let monthDay = try! NSRegularExpression(pattern: #"^(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s?(\d{1,2})(?:st|nd|rd|th)?(?:,?\s(\d{4}))?\b"#, options: .caseInsensitive)

    /// Parses a date at the very start of `s`. `dayFirst` resolves 03/04 ambiguity.
    public static func parse(_ s: String, dayFirst: Bool) -> Parsed? {
        let r = NSRange(s.startIndex..., in: s)
        func g(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            guard let rr = Range(m.range(at: i), in: s) else { return nil }
            return String(s[rr])
        }
        func year(_ y: String?) -> Int? {
            guard let y, let n = Int(y) else { return nil }
            if n >= 100 { return n }
            return n <= 69 ? 2000 + n : 1900 + n      // POSIX pivot: 99 → 1999, 25 → 2025
        }
        func valid(_ y: Int?, _ m: Int, _ d: Int) -> Bool {
            guard (1...12).contains(m), d >= 1 else { return false }
            let days = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1]
            if m == 2, let y, d == 29 { return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }
            return d <= days
        }
        func month(_ name: String) -> Int? {
            months.firstIndex(of: String(name.lowercased().prefix(3))).map { $0 + 1 }
        }
        if let m = iso.firstMatch(in: s, range: r), let y = Int(g(m, 1) ?? ""), let mo = Int(g(m, 2) ?? ""), let d = Int(g(m, 3) ?? ""),
           valid(y, mo, d) {
            return Parsed(year: y, month: mo, day: d, length: m.range.length)
        }
        if let m = numeric.firstMatch(in: s, range: r), let a = Int(g(m, 1) ?? ""), let b = Int(g(m, 2) ?? g(m, 4) ?? "") {
            var (mo, d) = dayFirst ? (b, a) : (a, b)
            if mo > 12, d <= 12 { swap(&mo, &d) }
            let y = year(g(m, 3) ?? g(m, 5))
            guard valid(y, mo, d) else { return nil }
            return Parsed(year: y, month: mo, day: d, length: m.range.length)
        }
        if let m = dayMonth.firstMatch(in: s, range: r), let d = Int(g(m, 1) ?? ""), let mo = month(g(m, 2) ?? ""), valid(year(g(m, 3)), mo, d) {
            return Parsed(year: year(g(m, 3)), month: mo, day: d, length: m.range.length)
        }
        if let m = monthDay.firstMatch(in: s, range: r), let mo = month(g(m, 1) ?? ""), let d = Int(g(m, 2) ?? ""), valid(year(g(m, 3)), mo, d) {
            return Parsed(year: year(g(m, 3)), month: mo, day: d, length: m.range.length)
        }
        return nil
    }

    /// Whether numeric dates in this text are day-first: any first number over 12 decides it,
    /// otherwise the Mac's region does.
    public static func detectDayFirst(_ samples: [String]) -> Bool {
        for s in samples {
            if let m = numeric.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
               let rr = Range(m.range(at: 1), in: s), let a = Int(s[rr]), a > 12 { return true }
            if let m = numeric.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
               let rr = Range(m.range(at: 2), in: s), let b = Int(s[rr]), b > 12 { return false }
        }
        return Locale.current.region?.identifier != "US"
    }

    public static func iso(_ p: Parsed, fallbackYear: Int) -> String {
        String(format: "%04d-%02d-%02d", p.year ?? fallbackYear, p.month, p.day)
    }
}
