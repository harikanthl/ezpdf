import Foundation
import AppKit
import PDFKit

/// Finds the blanks on a printed or scanned form and turns them into real fill-in fields.
///
/// The idea follows CommonForms / FFDNet (Barrow, 2025, arXiv 2509.16506): the same three kinds of
/// widgets (text boxes, choice buttons, signatures), found from what the page shows. Here that's done
/// on this Mac without a trained model: the page is rendered as shown and read for
/// - writing lines (drawn rules, and runs of underscores or dots in the text layer),
/// - boxes and table cells (closed by horizontal and vertical rules), empty or with a small label inside,
/// - checkboxes (small squares, and ☐-style characters),
/// with text masked out so letters are never taken for lines. Each blank is named after the label next
/// to it (left, inside its box, under a signature line, above, or right of a checkbox).
///
/// Coordinates are top-left points of the page as shown (see `EditOps.PageSpace`).
public enum FormDetector {
    public enum Kind: String, Codable, Sendable { case text, multiline, checkbox, signature, date }

    public struct Field: Codable, Sendable, Equatable {
        public var page: Int            // 0-based
        public var rect: CGRect
        public var kind: Kind
        public var label: String
        public var name: String
        /// One character per box, this many boxes (0 when it's an ordinary field).
        public var comb: Int = 0
        /// The line number printed beside it ("1a", "7"), on worksheets and numbered forms.
        public var number: String? = nil
    }

    // MARK: Detecting

    /// The blanks on every page (up to `maxPages`). Pages without a text layer are read with OCR for
    /// their labels. Blanks under existing form fields are left out.
    public static func detect(_ doc: PDFDocument, maxPages: Int = 50) async -> [Field] {
        var out: [Field] = []
        for i in 0..<min(doc.pageCount, maxPages) {
            guard let page = doc.page(at: i) else { continue }
            var words = PageText.words(page: page, index: i)
            var ocr = false
            if words.count < 5 { words = await PageText.ocrFragments(page: page, index: i); ocr = true }
            out += detect(page: page, index: i, words: words, fromOCR: ocr)
        }
        return named(out)
    }

    /// One page, given its words (top-left shown points).
    static func detect(page: PDFPage, index: Int, words: [TextFragment], fromOCR: Bool = false) -> [Field] {
        let space = EditOps.PageSpace(page)
        let isLeader: (String) -> Bool = { $0.range(of: #"^[_.…]{3,}$"#, options: .regularExpression) != nil }
        let textWords = words.filter { !isLeader($0.text) }
        let labels = PageText.group(textWords).flatMap(\.cells).map { cell -> TextFragment in
            var c = cell
            c.text = cell.text.replacingOccurrences(of: #"[_.…]{3,}"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            return c
        }.filter { !$0.text.isEmpty }

        var found: [Candidate] = []
        found += textLayerBlanks(page, space: space)
        if let ink = Ink(page: page, space: space, mask: textWords.map(\.rect)) {
            // Checkboxes first, on the unmasked page: OCR reads "☐ Yes" as one word, and masking
            // that word would erase the box.
            let squares = smallSquares(ink.horizontalRules(masked: false, maxLength: 24), ink.verticalRules(masked: false, maxLength: 24))
            for s in squares where ink.isEmptyInside(s) {
                // A square inside a word is a letter ("D", "O"), except where OCR read a box together
                // with the word after it ("•Student"): then it's at the word's start, which isn't a letter.
                let inWord = textWords.contains { w in
                    guard overlap(s, w.rect) > 0.3 else { return false }
                    let boxRead = fromOCR && s.minX - w.rect.minX <= max(6, s.width * 0.7)
                        && w.text.first.map { !$0.isLetter && !$0.isNumber || "oO口".contains($0) } == true
                    return !boxRead
                }
                if !inWord { found.append(Candidate(rect: s, checkbox: true, priority: 1)) }
            }
            let h = ink.horizontalRules(), v = ink.verticalRules()
            let (cells, edges) = cellsFrom(h, v)
            for c in cells where !isCheckboxSize(c) { found += blanks(inCell: c, words: textWords) }
            // Every rule can carry a writing line above it, box edges too (a box's top edge is often
            // the line of the row above it); where the space above is a box's blank, that one wins.
            _ = edges
            found += lineBlanks(h, words: textWords, pageWidth: space.size.width)
        }
        // Existing form fields stay as they are.
        let existing = page.annotations.filter { $0.type == "Widget" }.map { space.topLeft($0.bounds) }
        var kept: [Candidate] = []
        for c in found.sorted(by: { $0.priority < $1.priority }) {
            let r = c.rect
            guard r.width >= 5, r.height >= 5, space.bounds.contains(r.insetBy(dx: 1, dy: 1)) else { continue }
            if existing.contains(where: { overlap(r, $0) > 0.3 }) { continue }
            if kept.contains(where: { overlap(r, $0.rect) > 0.4 || overlap($0.rect, r) > 0.4 }) { continue }
            kept.append(c)
        }
        // Body text height, to tell section headings (larger type) from labels.
        let heights = textWords.map(\.rect.height).sorted()
        let body = heights.isEmpty ? 10 : heights[heights.count / 2]
        return combed(kept).compactMap { c in
            if let raw = c.label {
                let inside = cleanLabel(raw, before: false)
                return Field(page: index, rect: c.rect, kind: kind(for: c, label: inside), label: inside, name: "", comb: c.comb)
            }
            let hit = findLabel(for: c, in: labels)
            // A writing line nothing names is a rule (a border, a gap between sections), not a blank.
            if c.underLine, !c.inTable, hit == nil { return nil }
            if let hit, !c.checkbox, !c.inTable {
                // A line beside or under a section heading ("Part II  Certification", "Step 3: Credits")
                // is part of the heading's rule.
                if hit.side == .left || hit.side == .above, hit.lineHeight >= body * 1.35 { return nil }
                // A lone rule under a paragraph is a separator: its "label" is a whole sentence. (Lines
                // to write on under "Describe what happened." come several together.)
                if hit.side == .above, !c.stacked, hit.raw.count > 40, hit.raw.trimmingCharacters(in: .whitespaces).hasSuffix(".") { return nil }
            }
            let label = hit?.text ?? ""
            return Field(page: index, rect: c.rect, kind: kind(for: c, label: label), label: label, name: "", comb: c.comb, number: hit?.number)
        }
    }

    struct Candidate {
        var rect: CGRect
        var checkbox = false
        var label: String?
        var priority: Int            // lower wins when two overlap
        var underLine = false        // sits on a writing line (labels may be just below it)
        var inTable = false          // an empty box or table cell: its label may be a column header
        var comb = 0                 // a run of one-character boxes merged into one field (0: not a run)
        var stacked = false          // a writing line with more like it just above or below (lines to write on)
    }

    /// A row of two or more small boxes side by side (an SSN, a date, a code) is one field with one
    /// character per box, as on paper.
    static func combed(_ list: [Candidate]) -> [Candidate] {
        let small = list.indices.filter { list[$0].inTable && list[$0].rect.width <= 24 && list[$0].rect.height <= 40 }
        var used = Set<Int>()
        var out: [Candidate] = []
        let sorted = small.sorted { (list[$0].rect.minY, list[$0].rect.minX) < (list[$1].rect.minY, list[$1].rect.minX) }
        for i in sorted where !used.contains(i) {
            var run = [i]
            var last = list[i].rect
            for j in sorted where !used.contains(j) && !run.contains(j) {
                let r = list[j].rect
                guard abs(r.minY - last.minY) <= 1.5, abs(r.height - last.height) <= 1.5, abs(r.width - last.width) <= 3,
                      r.minX > last.minX, r.minX - last.maxX <= 5 else { continue }
                run.append(j); last = r
            }
            guard run.count >= 2 else { continue }
            run.forEach { used.insert($0) }
            var merged = list[i]
            merged.rect = run.map { list[$0].rect }.reduce(list[i].rect) { $0.union($1) }
            merged.comb = run.count
            out.append(merged)
        }
        return list.indices.filter { !used.contains($0) }.map { list[$0] } + out
    }

    /// Fraction of `a`'s area inside `b`.
    static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull, a.width > 0, a.height > 0 else { return 0 }
        return (i.width * i.height) / (a.width * a.height)
    }

    // MARK: Text layer: ____ and ...... leaders, ☐ boxes

    static func textLayerBlanks(_ page: PDFPage, space: EditOps.PageSpace) -> [Candidate] {
        guard let str = page.string, !str.isEmpty else { return [] }
        var out: [Candidate] = []
        let ns = str as NSString
        let full = NSRange(location: 0, length: ns.length)
        for m in try! NSRegularExpression(pattern: #"_{3,}|\.{6,}|…{3,}"#).matches(in: str, range: full) {
            guard let sel = page.selection(for: m.range) else { continue }
            for line in sel.selectionsByLine() {
                let r = space.topLeft(line.bounds(for: page))
                guard r.width >= 18 else { continue }
                // The blank is the line box the leader sits in, at least tall enough to type in.
                let h = max(r.height, 14)
                out.append(Candidate(rect: CGRect(x: r.minX, y: r.maxY - h, width: r.width, height: h), priority: 0, underLine: true))
            }
        }
        for m in try! NSRegularExpression(pattern: "[☐□▢❏❑◻⬜]").matches(in: str, range: full) {
            guard let sel = page.selection(for: m.range) else { continue }
            let r = space.topLeft(sel.bounds(for: page))
            let s = max(8, min(r.width, r.height))
            out.append(Candidate(rect: CGRect(x: r.midX - s / 2, y: r.midY - s / 2, width: s, height: s), checkbox: true, priority: 0))
        }
        return out
    }

    // MARK: Ink: rules found in the rendered page

    /// A rule (thin straight line) in top-left shown points.
    struct Rule { var a0: CGFloat, a1: CGFloat, at: CGFloat }   // along-axis start/end, cross-axis position

    /// The page rendered as shown, as a dark/light map with text masked out.
    struct Ink {
        let w: Int, h: Int, scale: CGFloat
        var dark: [Bool]
        /// Before text was masked.
        let raw: [Bool]

        init?(page: PDFPage, space: EditOps.PageSpace, mask: [CGRect], scale: CGFloat = 2) {
            guard let img = PDFRaster.cgImage(page, scale: scale) else { return nil }
            w = img.width; h = img.height
            self.scale = CGFloat(w) / max(1, space.size.width)
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let px = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
            dark = [Bool](repeating: false, count: w * h)
            for i in 0..<(w * h) where px[i] < 150 { dark[i] = true }    // memory rows run top to bottom
            raw = dark
            // Letters aren't lines: clear every word's box.
            for r in mask {
                let x0 = max(0, Int((r.minX - 0.5) * self.scale)), x1 = min(w, Int(ceil((r.maxX + 0.5) * self.scale)))
                let y0 = max(0, Int((r.minY - 0.5) * self.scale)), y1 = min(h, Int(ceil((r.maxY + 0.5) * self.scale)))
                guard x0 < x1, y0 < y1 else { continue }
                for y in y0..<y1 { for x in x0..<x1 { dark[y * w + x] = false } }
            }
        }

        func horizontalRules(masked: Bool = true, maxLength: CGFloat = .infinity) -> [Rule] {
            rules(horizontal: true, in: masked ? dark : raw).filter { $0.a1 - $0.a0 <= maxLength }
        }
        func verticalRules(masked: Bool = true, maxLength: CGFloat = .infinity) -> [Rule] {
            rules(horizontal: false, in: masked ? dark : raw).filter { $0.a1 - $0.a0 <= maxLength }
        }

        /// No ink inside the box (a checkbox that's ticked or has a letter in it isn't an empty box).
        func isEmptyInside(_ r: CGRect) -> Bool {
            let x0 = Int((r.minX + 2) * scale), x1 = Int((r.maxX - 2) * scale), y0 = Int((r.minY + 2) * scale), y1 = Int((r.maxY - 2) * scale)
            guard x0 < x1, y0 < y1, x0 >= 0, y0 >= 0, x1 <= w, y1 <= h else { return false }
            var ink = 0
            for y in y0..<y1 { for x in x0..<x1 where raw[y * w + x] { ink += 1 } }
            return Double(ink) < 0.04 * Double((x1 - x0) * (y1 - y0))
        }

        /// Straight runs at least 6 pt long and at most 4 pt thick (thicker is a filled shape, not a rule).
        /// Gaps of a pixel or two (scans) are bridged.
        private func rules(horizontal: Bool, in dark: [Bool]) -> [Rule] {
            let along = horizontal ? w : h, across = horizontal ? h : w
            let minLen = Int(6 * scale), maxThick = Int(ceil(4 * scale)), gap = 2
            struct Open { var a0: Int, a1: Int, c0: Int, c1: Int }
            var open: [Open] = []
            var done: [Open] = []
            for c in 0..<across {
                var runs: [(Int, Int)] = []
                var start = -1, lastDark = -10
                for a in 0..<along {
                    let d = horizontal ? dark[c * w + a] : dark[a * w + c]
                    if d {
                        if start < 0 || a - lastDark > gap + 1 {
                            if start >= 0, lastDark - start + 1 >= minLen { runs.append((start, lastDark)) }
                            start = a
                        }
                        lastDark = a
                    }
                }
                if start >= 0, lastDark - start + 1 >= minLen { runs.append((start, lastDark)) }
                var next: [Open] = []
                var used = [Bool](repeating: false, count: open.count)
                for (r0, r1) in runs {
                    let tol = max(3, (r1 - r0) / 50)
                    if let i = open.indices.first(where: { !used[$0] && abs(open[$0].a0 - r0) <= tol && abs(open[$0].a1 - r1) <= tol }) {
                        used[i] = true
                        var o = open[i]; o.c1 = c; o.a0 = min(o.a0, r0); o.a1 = max(o.a1, r1)
                        next.append(o)
                    } else {
                        next.append(Open(a0: r0, a1: r1, c0: c, c1: c))
                    }
                }
                for (i, o) in open.enumerated() where !used[i] { done.append(o) }
                open = next
            }
            done += open
            return done.filter { $0.c1 - $0.c0 + 1 <= maxThick }.map {
                Rule(a0: CGFloat($0.a0) / scale, a1: CGFloat($0.a1 + 1) / scale, at: CGFloat($0.c0 + $0.c1 + 1) / 2 / scale)
            }
        }
    }

    // MARK: Boxes and table cells

    /// Rectangles closed on all four sides by rules (single boxes and every cell of a grid), and the
    /// horizontal rules used as their edges.
    static func cellsFrom(_ h: [Rule], _ v: [Rule]) -> (cells: [CGRect], edges: Set<Int>) {
        let tol: CGFloat = 2.5
        var cells: [CGRect] = []
        var edges = Set<Int>()
        var claimed = Set<String>()
        func covers(_ r: Rule, _ x0: CGFloat, _ x1: CGFloat) -> Bool { r.a0 <= x0 + tol && r.a1 >= x1 - tol }
        let byY = h.indices.sorted { h[$0].at < h[$1].at }
        for ti in byY {
            let top = h[ti]
            for bi in byY where h[bi].at > top.at + 5 && h[bi].at - top.at < 320 {
                let bottom = h[bi]
                let lo = max(top.a0, bottom.a0), hi = min(top.a1, bottom.a1)
                guard hi - lo >= 5 else { continue }
                let xs = v.filter { $0.at >= lo - tol && $0.at <= hi + tol && $0.a0 <= top.at + tol && $0.a1 >= bottom.at - tol }
                    .map(\.at).sorted()
                var merged: [CGFloat] = []
                for x in xs where merged.last.map({ x - $0 > tol }) ?? true { merged.append(x) }
                guard merged.count >= 2 else { continue }
                for (a, b) in zip(merged, merged.dropFirst()) where b - a >= 5 {
                    guard covers(top, a, b), covers(bottom, a, b) else { continue }
                    // The nearest bottom closes the cell; farther ones would span several rows.
                    let key = "\(ti):\(Int(a.rounded())):\(Int(b.rounded()))"
                    guard claimed.insert(key).inserted else { continue }
                    cells.append(CGRect(x: a, y: top.at, width: b - a, height: bottom.at - top.at))
                    edges.insert(ti); edges.insert(bi)
                }
            }
        }
        return (cells, edges)
    }

    /// Checkbox-sized squares (6 to 22 points) closed by four short rules. Rules are looked up by
    /// position, so a page full of letter strokes stays fast.
    static func smallSquares(_ h: [Rule], _ v: [Rule]) -> [CGRect] {
        let tol: CGFloat = 2
        var vBuckets: [Int: [Rule]] = [:]
        for r in v { vBuckets[Int((r.at / 4).rounded()), default: []].append(r) }
        func vertical(at x: CGFloat, from y0: CGFloat, to y1: CGFloat) -> Bool {
            let k = Int((x / 4).rounded())
            return (k - 1...k + 1).contains { vBuckets[$0]?.contains { abs($0.at - x) <= tol && $0.a0 <= y0 + tol && $0.a1 >= y1 - tol } == true }
        }
        var hBuckets: [Int: [Rule]] = [:]
        for r in h { hBuckets[Int((r.a0 / 4).rounded()), default: []].append(r) }
        var out: [CGRect] = []
        for top in h {
            let len = top.a1 - top.a0
            guard len >= 6, len <= 22 else { continue }
            let k = Int((top.a0 / 4).rounded())
            var bottom: Rule?
            for key in (k - 1)...(k + 1) {
                for b in hBuckets[key] ?? [] {
                    let dy: CGFloat = b.at - top.at
                    guard abs(b.a0 - top.a0) <= tol, abs(b.a1 - top.a1) <= tol, dy >= 6, dy <= 22 else { continue }
                    if bottom.map({ b.at < $0.at }) ?? true { bottom = b }
                }
            }
            guard let bottom else { continue }
            let r = CGRect(x: top.a0, y: top.at, width: len, height: bottom.at - top.at)
            guard isCheckboxSize(r), vertical(at: r.minX, from: r.minY, to: r.maxY), vertical(at: r.maxX, from: r.minY, to: r.maxY) else { continue }
            if !out.contains(where: { abs($0.minX - r.minX) < 2 && abs($0.minY - r.minY) < 2 }) { out.append(r) }
        }
        return out
    }

    static func isCheckboxSize(_ c: CGRect) -> Bool {
        c.width >= 6 && c.height >= 6 && c.width <= 22 && c.height <= 22 && (0.7...1.43).contains(c.width / c.height)
    }

    /// The blank in a box (checkboxes are found separately): the whole box when it's empty; the room
    /// beside or below a small label inside it; nothing when it's full of text (a label cell).
    static func blanks(inCell c: CGRect, words: [TextFragment]) -> [Candidate] {
        let inside = words.filter { overlap($0.rect, c) > 0.5 }
        let room = c.insetBy(dx: 2, dy: 2)
        guard !inside.isEmpty else { return [Candidate(rect: room, priority: 2, inTable: true)] }
        let text = inside.map(\.rect).reduce(inside[0].rect) { $0.union($1) }
        let label = inside.sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }.map(\.text).joined(separator: " ")
        if c.maxY - text.maxY >= 13 {
            return [Candidate(rect: CGRect(x: room.minX, y: text.maxY + 1, width: room.width, height: room.maxY - text.maxY - 1), label: label, priority: 2)]
        }
        if c.maxX - text.maxX >= 50 {
            return [Candidate(rect: CGRect(x: text.maxX + 4, y: room.minY, width: room.maxX - text.maxX - 4, height: room.height), label: label, priority: 2)]
        }
        return []
    }

    // MARK: Writing lines

    /// The space just above each rule, where people write. A rule with text sitting right on it is an
    /// underline, not a blank.
    static func lineBlanks(_ rules: [Rule], words: [TextFragment], pageWidth: CGFloat) -> [Candidate] {
        var out: [Candidate] = []
        for r in rules where r.a1 - r.a0 >= 36 {
            var height: CGFloat = 16
            let band = CGRect(x: r.a0, y: r.at - 18, width: r.a1 - r.a0, height: 18)
            var underline = false
            for wd in words {
                let ix = min(wd.rect.maxX, band.maxX) - max(wd.rect.minX, band.minX)
                guard ix > wd.rect.width * 0.3, wd.rect.maxY > band.minY, wd.rect.minY < r.at else { continue }
                let gap = r.at - wd.rect.maxY
                if gap < 7 { underline = true; break }
                height = min(height, gap - 1)
            }
            guard !underline, height >= 8 else { continue }
            let stacked = rules.contains { o in
                abs(o.a0 - r.a0) <= 10 && abs(o.a1 - r.a1) <= 10 && abs(o.at - r.at) >= 12 && abs(o.at - r.at) <= 40
            }
            out.append(Candidate(rect: CGRect(x: r.a0, y: r.at - height - 0.5, width: r.a1 - r.a0, height: height), priority: 3,
                                 underLine: true, stacked: stacked))
        }
        return out
    }

    // MARK: Labels and names

    /// A label as a field name wants it: no item number ("3a", "5."), no trailing colon, and for long
    /// text the part nearest the blank (the start of text after it, the end of text before it).
    static func cleanLabel(_ s: String, before: Bool) -> String {
        // OCR reads a box in front of a word as a bullet ("•Student").
        var t = s.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "•·▪■□☐◻○◯")))
        t = t.replacingOccurrences(of: #"^(\(?\d{1,2}[a-z]?[.)]?|\(?[a-z][.)])\s+"#, with: "", options: .regularExpression)
        if t.count > 40 {
            let sentences = t.components(separatedBy: ". ").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            t = (before ? sentences.last : sentences.first) ?? t
            if !before, let cut = t.range(of: #"\s[(\[]|[:;]"#, options: .regularExpression), t.distance(from: t.startIndex, to: cut.lowerBound) >= 3 {
                t = String(t[..<cut.lowerBound])
            }
        }
        // Dot leaders and the line number at the end of "Add lines 1 and 2 . . . . . 3".
        t = t.replacingOccurrences(of: #"(\s*[.…]){2,}.*$"#, with: "", options: .regularExpression)
        while let last = t.last, ":*#(.;,$ ".contains(last) { t.removeLast() }
        // Long text: whole words only, from the end nearest the blank.
        if t.count > 50 {
            var words = t.split(separator: " ").map(String.init)
            var kept: [String] = []
            while let w = before ? words.popLast() : (words.isEmpty ? nil : words.removeFirst()),
                  (kept.joined(separator: " ").count + w.count) <= 50 || kept.isEmpty {
                if before { kept.insert(w, at: 0) } else { kept.append(w) }
            }
            t = kept.joined(separator: " ")
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Text that names something: at least one real word, not just an item number ("1a"), a "$" or leaders.
    static func isWords(_ s: String) -> Bool {
        s.range(of: #"\p{L}{2,}"#, options: .regularExpression) != nil && cleanLabel(s, before: true).range(of: #"\p{L}{2,}"#, options: .regularExpression) != nil
    }

    struct LabelHit {
        enum Side { case left, right, above, below }
        var text: String        // cleaned
        var raw: String         // as printed
        var rect: CGRect
        var side: Side
        var lineHeight: CGFloat     // one line of the label (its type size, for telling headings apart)
        var number: String? = nil   // a line number between the label and the blank ("1a")
    }

    static func findLabel(for c: Candidate, in labels: [TextFragment]) -> LabelHit? {
        let f = c.rect
        // On the blank's own line: the text's middle inside the blank's height.
        let sameRow = labels.filter { $0.rect.midY > f.minY - 3 && $0.rect.midY < f.maxY + 3 }
        func hit(_ t: TextFragment, _ side: LabelHit.Side, before: Bool) -> LabelHit {
            LabelHit(text: cleanLabel(t.text, before: before), raw: t.text, rect: t.rect, side: side, lineHeight: t.rect.height)
        }
        // The nearest words to the left that say something: a "$", a line number or dot leaders
        // between the label and the blank are skipped.
        func leftLabel(reach: CGFloat) -> LabelHit? {
            sameRow.filter { $0.rect.maxX <= f.minX + 6 && f.minX - $0.rect.maxX <= reach + 200 }
                .sorted { $0.rect.maxX > $1.rect.maxX }
                .first { isWords($0.text) }
                .flatMap { t in
                    // Within reach of the blank, or of a number / "$" that sits between them.
                    let between = sameRow.filter { $0.rect.minX >= t.rect.maxX - 1 && $0.rect.maxX <= f.minX + 6 }
                    let start = between.map(\.rect.minX).min() ?? f.minX
                    guard start - t.rect.maxX <= reach && f.minX - t.rect.maxX <= reach + 200 else { return nil }
                    var h = hit(t, .left, before: true)
                    h.number = between.sorted { $0.rect.maxX > $1.rect.maxX }.lazy.compactMap { lineNumber($0.text) }.first
                    return h
                }
        }
        if c.checkbox {
            // To the right; a word OCR read together with the box starts on the box itself.
            if let right = sameRow.filter({ $0.rect.maxX > f.maxX + 4 && $0.rect.minX >= f.minX - 6 && $0.rect.minX - f.maxX < 40 && isWords($0.text) }).min(by: { $0.rect.minX < $1.rect.minX }) {
                return hit(right, .right, before: false)
            }
            return leftLabel(reach: 120)
        }
        let overlapsX: (TextFragment) -> Bool = { $0.rect.minX < f.maxX && $0.rect.maxX > f.minX }
        // The nearest row of text above (a table cell looks up to its column's header, however many
        // rows up), the piece that lies most over the blank, and if that's the last line of a
        // label running over several lines, its first line.
        func aboveLabel(reach: CGFloat, needShare: CGFloat) -> LabelHit? {
            let above = labels.filter { overlapsX($0) && $0.rect.maxY <= f.minY + 3 && f.minY - $0.rect.maxY <= reach }
            guard let nearest = above.map(\.rect.maxY).max() else { return nil }
            // In that row, the piece most over the blank; between equals, the one that says most ("2" and
            // "Business name" both sit over line 2: the words win).
            let row = above.filter { nearest - $0.rect.maxY < 4 && isWords($0.text) }
            guard var best = row.max(by: { (columnShare($0.rect, f), $0.text.count) < (columnShare($1.rect, f), $1.text.count) }),
                  columnShare(best.rect, f) >= needShare else { return nil }
            var raw = best.text
            let lineHeight = best.rect.height
            while let up = labels.filter({ abs($0.rect.minX - best.rect.minX) <= 6 && $0.rect.maxY <= best.rect.minY + 2 && best.rect.minY - $0.rect.maxY <= 5 })
                    .max(by: { $0.rect.maxY < $1.rect.maxY }), raw.count < 400 {
                raw = up.text + " " + raw
                best = TextFragment(text: up.text, rect: up.rect.union(best.rect), page: up.page)
            }
            return LabelHit(text: cleanLabel(raw, before: false), raw: raw, rect: best.rect, side: .above, lineHeight: lineHeight)
        }
        if c.inTable {
            return aboveLabel(reach: 160, needShare: 0.5) ?? leftLabel(reach: 120)
        }
        if let left = leftLabel(reach: 200) { return left }
        if let above = aboveLabel(reach: 22, needShare: 0) { return above }
        // A caption under a writing line ("Signature", "Date").
        if c.underLine, let below = labels.filter({ overlapsX($0) && $0.rect.minY >= f.maxY - 2 && $0.rect.minY - f.maxY <= 12 && isWords($0.text) }).min(by: { $0.rect.minY < $1.rect.minY }) {
            return hit(below, .below, before: false)
        }
        return nil
    }

    /// How much a piece of text and a cell share their left-to-right span (0…1): the text's share
    /// inside the cell, or the cell's share under the text (a header over several boxes), whichever is more.
    static func columnShare(_ text: CGRect, _ cell: CGRect) -> CGFloat {
        guard text.width > 0, cell.width > 0 else { return 0 }
        let shared = max(0, min(text.maxX, cell.maxX) - max(text.minX, cell.minX))
        return max(shared / text.width, shared / cell.width)
    }

    static func kind(for c: Candidate, label: String) -> Kind {
        if c.checkbox { return .checkbox }
        if label.range(of: #"(?i)\bsign(ature|ed)?\b"#, options: .regularExpression) != nil { return .signature }
        if label.range(of: #"(?i)\b(date|dob|birth)\b"#, options: .regularExpression) != nil { return .date }
        return c.rect.height >= 30 ? .multiline : .text
    }

    /// A printed line number like "1a", "7", "(3)", "4(b)", or nil.
    static func lineNumber(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard let m = t.range(of: #"^\(?(\d{1,2})\)?\s?\(?([a-z])?\)?\.?$"#, options: .regularExpression), m.lowerBound == t.startIndex else { return nil }
        let kept = t.filter { $0.isNumber || $0.isLetter }
        return kept.isEmpty ? nil : kept
    }

    /// Words that don't tell fields apart ("Enter the amount from line 3 here").
    static let fillerWords: Set<String> = [
        "a", "an", "the", "and", "or", "of", "to", "in", "on", "for", "from", "by", "with", "at", "as", "is", "are", "be", "was",
        "were", "if", "then", "than", "this", "that", "these", "those", "your", "you", "yours", "my", "our", "their", "it", "its",
        "into", "over", "under", "up", "down", "out", "per", "each", "any", "all", "also", "not", "no", "do", "does", "here", "there",
        "enter", "add", "subtract", "multiply", "divide", "skip", "include", "including", "check", "write", "print", "fill", "complete",
        "amount", "amounts", "line", "lines", "page", "step", "see", "instructions", "result", "results", "otherwise", "only", "may",
        "must", "can", "will", "should", "optional", "applicable", "below", "above", "following", "etc", "e", "g", "i",
    ]

    /// A short field name from a label: its first few telling words (at most 4, about 32 characters),
    /// with the printed line number in front when there is one ("line_1b_qualified_overtime").
    static func shortName(label: String, number: String?) -> String {
        let words = label.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        // In a short label a single letter can matter ("C corporation", "S corporation"); in a sentence it's noise.
        let short = words.count <= 4
        let telling = words.filter { w in
            !fillerWords.contains(w) && !w.allSatisfy(\.isNumber) && lineNumber(w) == nil      // "2a": a reference to another line
                && (w.count > 1 || short && w.first?.isLetter == true)
        }
        var kept: [String] = []
        for w in telling.prefix(4) where (kept + [w]).joined(separator: "_").count <= 32 { kept.append(w) }
        // Nothing telling ("Enter the result here"): the line number, or the caller's plain name.
        let base = kept.joined(separator: "_")
        guard let number else { return base }
        return base.isEmpty ? "line_\(number)" : "line_\(number)_\(base)"
    }

    /// Field names, unique in the document, in reading order.
    static func named(_ fields: [Field]) -> [Field] {
        var seen: [String: Int] = [:]
        return fields.sorted { ($0.page, ($0.rect.minY / 4).rounded(), $0.rect.minX) < ($1.page, ($1.rect.minY / 4).rounded(), $1.rect.minX) }.map { f in
            var f = f
            var base = shortName(label: f.label, number: f.number)
            if base.isEmpty { base = f.kind == .checkbox ? "checkbox" : "field" }
            let n = (seen[base] ?? 0) + 1
            seen[base] = n
            f.name = n == 1 ? base : "\(base)_\(n)"
            return f
        }
    }

    // MARK: Making them fields

    /// Adds a form field for each blank. Returns how many were added.
    @discardableResult
    public static func addFields(_ fields: [Field], to doc: PDFDocument) -> Int {
        var n = 0
        let taken = Set(EditOps.formFields(doc).map(\.name))
        for f in fields {
            guard let page = doc.page(at: f.page) else { continue }
            let space = EditOps.PageSpace(page)
            let w = PDFAnnotation(bounds: space.pageRect(f.rect), forType: .widget, withProperties: nil)
            // The field type first: setting it renames the field (text0, button0…), so the name comes after.
            w.widgetFieldType = f.kind == .checkbox ? .button : .text
            w.fieldName = taken.contains(f.name) ? "\(f.name)_new" : f.name
            if !f.label.isEmpty { w.setValue(f.label, forAnnotationKey: PDFAnnotationKey(rawValue: "/TU")) }
            switch f.kind {
            case .checkbox:
                w.widgetControlType = .checkBoxControl
                w.buttonWidgetState = .offState
            case .text, .multiline, .date, .signature:
                w.isMultiline = f.kind == .multiline
                if f.comb > 1 {
                    w.setValue(f.comb, forAnnotationKey: .widgetMaxLen)
                    w.hasComb = true
                }
                let size = max(6, min(f.kind == .multiline ? 10 : 11, f.rect.height * 0.62))
                w.font = f.kind == .signature ? Objects.signatureFont(size: max(size, min(f.rect.height * 0.8, 22))) : .systemFont(ofSize: size)
                w.fontColor = f.kind == .signature ? NSColor(red: 0.05, green: 0.1, blue: 0.35, alpha: 1) : .black
                w.widgetStringValue = ""
            }
            w.backgroundColor = NSColor(calibratedRed: 0.93, green: 0.95, blue: 1.0, alpha: 0.35)
            let border = PDFBorder(); border.lineWidth = 0
            w.border = border
            page.addAnnotation(w)
            n += 1
        }
        return n
    }

    /// Redraws rotated pages upright (same look, rotation 0), so fields type the right way up in every
    /// viewer. Pages with annotations are left alone and reported by number.
    static func uprightRotatedPages(_ doc: PDFDocument) throws -> [Int] {
        var skipped: [Int] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), page.rotation % 360 != 0, let ref = page.pageRef else { continue }
            guard page.annotations.isEmpty else { skipped.append(i + 1); continue }
            let space = EditOps.PageSpace(page)
            let data = NSMutableData()
            var box = CGRect(origin: .zero, size: space.size)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw EzPDFError.failed("Couldn't redraw page \(i + 1).") }
            ctx.beginPDFPage(nil)
            ctx.concatenate(space.toShown)
            ctx.drawPDFPage(ref)
            ctx.endPDFPage()
            ctx.closePDF()
            guard let upright = PDFDocument(data: data as Data)?.page(at: 0) else { throw EzPDFError.failed("Couldn't redraw page \(i + 1).") }
            EditOps.replacePage(doc, at: i, old: page, with: upright)
        }
        return skipped
    }

    /// Detects the blanks and adds fields for them. Rotated pages are made upright first.
    public static func makeFillable(_ doc: PDFDocument) async throws -> (fields: [Field], skippedRotated: [Int]) {
        let skipped = try uprightRotatedPages(doc)
        let fields = await detect(doc).filter { f in !skipped.contains(f.page + 1) }
        addFields(fields, to: doc)
        return (fields, skipped)
    }
}
