import Foundation

/// Small CommonMark-ish Markdown → HTML: headings, paragraphs, lists, quotes, fenced code,
/// tables, rules, images, links, emphasis, inline code. Enough for READMEs and notes.
enum Markdown {
    static func firstHeading(_ md: String) -> String? {
        md.split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
    }

    static func html(_ md: String) -> String {
        let lines = md.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [String] = []
        var i = 0
        var para: [String] = []
        func flushPara() {
            if !para.isEmpty { out.append("<p>\(inline(para.joined(separator: " ")))</p>"); para = [] }
        }
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                flushPara()
                let fence = String(t.prefix(3))
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { code.append(lines[i]); i += 1 }
                out.append("<pre><code>\(ArticleHTML.escape(code.joined(separator: "\n")))</code></pre>")
                i += 1; continue
            }
            if t.isEmpty { flushPara(); i += 1; continue }
            if let m = t.range(of: #"^#{1,6}\s"#, options: .regularExpression) {
                flushPara()
                let level = t[m].filter { $0 == "#" }.count
                out.append("<h\(level)>\(inline(String(t[m.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " #"))))</h\(level)>")
                i += 1; continue
            }
            if t.range(of: #"^([-*_])(\s*\1){2,}$"#, options: .regularExpression) != nil { flushPara(); out.append("<hr>"); i += 1; continue }
            if t.hasPrefix(">") {
                flushPara()
                var quote: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)); i += 1
                }
                out.append("<blockquote>\(html(quote.joined(separator: "\n")))</blockquote>")
                continue
            }
            if t.contains("|"), i + 1 < lines.count, lines[i + 1].range(of: #"^\s*\|?\s*:?-{2,}"#, options: .regularExpression) != nil {
                flushPara()
                func cells(_ s: String) -> [String] {
                    var s = s.trimmingCharacters(in: .whitespaces)
                    if s.hasPrefix("|") { s.removeFirst() }
                    if s.hasSuffix("|") { s.removeLast() }
                    return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                }
                var table = "<table><thead><tr>" + cells(t).map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead><tbody>"
                i += 2
                while i < lines.count, lines[i].contains("|") {
                    table += "<tr>" + cells(lines[i]).map { "<td>\(inline($0))</td>" }.joined() + "</tr>"; i += 1
                }
                out.append(table + "</tbody></table>")
                continue
            }
            if let ordered = listMarker(t) {
                flushPara()
                var items: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    guard let o = listMarker(l), o.ordered == ordered.ordered else {
                        // Continuation lines indented under an item.
                        if !l.isEmpty, lines[i].hasPrefix("  "), !items.isEmpty { items[items.count - 1] += " " + l; i += 1; continue }
                        break
                    }
                    items.append(o.text); i += 1
                }
                let tag = ordered.ordered ? "ol" : "ul"
                out.append("<\(tag)>" + items.map { item -> String in
                    if item.hasPrefix("[ ] ") { return "<li>☐ \(inline(String(item.dropFirst(4))))</li>" }
                    if item.lowercased().hasPrefix("[x] ") { return "<li>☑ \(inline(String(item.dropFirst(4))))</li>" }
                    return "<li>\(inline(item))</li>"
                }.joined() + "</\(tag)>")
                continue
            }
            para.append(t)
            i += 1
        }
        flushPara()
        return out.joined(separator: "\n")
    }

    static func listMarker(_ t: String) -> (ordered: Bool, text: String)? {
        if let r = t.range(of: #"^[-*+]\s+"#, options: .regularExpression) { return (false, String(t[r.upperBound...])) }
        if let r = t.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression) { return (true, String(t[r.upperBound...])) }
        return nil
    }

    static func inline(_ s: String) -> String {
        // Protect code spans first so their contents aren't formatted.
        var codes: [String] = []
        var text = s.replacingOccurrences(of: #"`([^`]+)`"#, with: "\u{1}$1\u{2}", options: .regularExpression)
        while let r = text.range(of: "\u{1}[^\u{2}]*\u{2}", options: .regularExpression) {
            codes.append(String(text[r].dropFirst().dropLast()))
            text.replaceSubrange(r, with: "\u{3}\(codes.count - 1)\u{3}")
        }
        text = ArticleHTML.escape(text)
        let rules: [(String, String)] = [
            (#"!\[([^\]]*)\]\(([^)\s]+)(?:\s+&quot;[^)]*&quot;)?\)"#, "<img alt=\"$1\" src=\"$2\">"),
            (#"\[([^\]]+)\]\(([^)\s]+)(?:\s+&quot;[^)]*&quot;)?\)"#, "<a href=\"$2\">$1</a>"),
            (#"\*\*([^*]+)\*\*"#, "<strong>$1</strong>"),
            (#"__([^_]+)__"#, "<strong>$1</strong>"),
            (#"(?<![\w*])\*([^*\n]+)\*(?![\w*])"#, "<em>$1</em>"),
            (#"(?<![\w_])_([^_\n]+)_(?![\w_])"#, "<em>$1</em>"),
            (#"~~([^~]+)~~"#, "<del>$1</del>"),
            (#"(?<![\"=>])(https?://[^\s<]+)"#, "<a href=\"$1\">$1</a>"),
        ]
        for (p, r) in rules { text = text.replacingOccurrences(of: p, with: r, options: .regularExpression) }
        for (n, code) in codes.enumerated() {
            text = text.replacingOccurrences(of: "\u{3}\(n)\u{3}", with: "<code>\(ArticleHTML.escape(code))</code>")
        }
        return text
    }
}
