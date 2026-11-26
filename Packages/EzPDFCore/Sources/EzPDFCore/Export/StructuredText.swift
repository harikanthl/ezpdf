import Foundation
import PDFKit
import AppKit

/// A PDF read back as a document: headings, paragraphs (with bold and italic), lists, tables and
/// figures, in reading order, with running headers, footers and page numbers left out. This is the
/// shared input for the Word, Markdown and plain-text exports.
///
/// Text comes from the PDF's text layer (PDFKit's reading order, its fonts for sizes and styles).
/// Headings are lines set larger than the body text, or short bold lines standing on their own.
/// Tables are found with Apple's document reader and filled with the PDF's own text; figures are
/// the places the page draws an image, cut from the rendered page. Scanned pages are read on this
/// Mac with the document reader.
public enum StructuredText {
    public struct Run: Sendable, Equatable {
        public var text: String
        public var bold = false
        public var italic = false
        public init(text: String, bold: Bool = false, italic: Bool = false) { self.text = text; self.bold = bold; self.italic = italic }
    }

    public struct Figure: Sendable {
        /// JPEG of the figure as the page shows it.
        public var jpeg: Data
        /// Size on the page, in points.
        public var size: CGSize
    }

    public enum Block: Sendable {
        case heading(level: Int, text: String)
        case paragraph([Run])
        case listItem(ListMarker, runs: [Run])
        /// Rows of cells; the first row is treated as the header.
        case table([[String]])
        case figure(Figure)
    }

    /// How a list item is marked: a bullet, or its own number or letter (a = 1).
    public enum ListMarker: Sendable, Equatable {
        case bullet, number(Int), letter(Int)
    }

    public struct Document: Sendable {
        public var blocks: [Block]
        /// The first page's size, in points.
        public var pageSize: CGSize
        public var title: String?
        /// Pages read with OCR because they had no text layer.
        public var scannedPages: Int
    }

    public struct Options: Sendable {
        public var tables = true
        public var figures = true
        public init(tables: Bool = true, figures: Bool = true) { self.tables = tables; self.figures = figures }
    }

    /// Render scale for finding tables: only the grid matters, the cell text comes from the PDF.
    static let tableScale: CGFloat = 1.5

    /// Most pages read for tables with the document reader (it takes a moment per page).
    static let maxTablePages = 300

    public static func read(_ doc: PDFDocument, pages: [Int]? = nil, options: Options = .init(),
                            progress: ((Int, Int) -> Void)? = nil) async -> Document {
        let indices = (pages ?? Array(0..<doc.pageCount)).filter { $0 >= 0 && $0 < doc.pageCount }
        // 1. Each page's text lines, and the pages the document reader should see: those with no
        //    text layer (read as scans), and those that look like they hold a table.
        var pageLinesList: [[Line]] = []
        var wanted: [(index: Int, scanned: Bool)] = []
        var tablePages = 0
        for (n, i) in indices.enumerated() {
            progress?(n + 1, indices.count * 2)
            guard let page = doc.page(at: i) else { pageLinesList.append([]); continue }
            // PDFKit's text calls leave autoreleased objects behind; let them go page by page.
            autoreleasepool {
                let lines = pageLines(page, index: i)
                pageLinesList.append(lines)
                let scanned = lines.map(\.text.count).reduce(0, +) < 20
                if scanned { wanted.append((i, true)) }
                else if options.tables, tablePages < maxTablePages, mayHaveTable(page, index: i) { tablePages += 1; wanted.append((i, false)) }
            }
        }
        // 2. The document reader on those pages: rendered a batch at a time (renders are big) and
        //    read a few at once.
        var reads: [Int: DocumentReader.Page] = [:]
        var scannedSet = Set<Int>()
        for start in stride(from: 0, to: wanted.count, by: 8) {
            let batch = wanted[start..<min(start + 8, wanted.count)]
            var renders: [(Int, CGImage, CGSize)] = []
            for w in batch {
                guard let page = doc.page(at: w.index) else { continue }
                if w.scanned { scannedSet.insert(w.index) }
                // Scans need small print read well; for tables only the grid matters (the text comes from the PDF).
                autoreleasepool {
                    if let image = PDFRaster.cgImage(page, scale: w.scanned ? 2.5 : Self.tableScale) {
                        renders.append((w.index, image, EditOps.PageSpace(page).size))
                    }
                }
            }
            await withTaskGroup(of: (Int, DocumentReader.Page?).self) { group in
                for (i, image, size) in renders {
                    group.addTask { (i, try? await DocumentReader.read(image: image, size: size, index: i)) }
                }
                for await (i, page) in group { if let page { reads[i] = page } }
            }
            progress?(indices.count + (start + batch.count) * indices.count / max(wanted.count, 1), indices.count * 2)
        }
        // 3. Pages put together: scans from what was read; others from their text, with tables and figures.
        var perPage: [[Item]] = []
        var scanned = 0
        for (n, i) in indices.enumerated() {
            guard let page = doc.page(at: i) else { perPage.append([]); continue }
            var lines = pageLinesList[n]
            if scannedSet.contains(i) {
                if let read = reads[i], !read.paragraphs.isEmpty || !read.tables.isEmpty {
                    scanned += 1
                    perPage.append(scannedItems(read))
                    continue
                }
            }
            var extras: [(y: CGFloat, item: Item)] = []
            if let read = reads[i], !scannedSet.contains(i) {
                for t in read.tables where t.rowCount >= 2 && t.columnCount >= 2 {
                    let area = t.rect.insetBy(dx: -2, dy: -2)
                    let grid = tableGrid(t, page: page, index: i)
                    guard grid.flatMap({ $0 }).filter({ !$0.isEmpty }).count >= 4 else { continue }
                    lines.removeAll { area.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }
                    extras.append((t.rect.minY, .table(grid)))
                }
            }
            if options.figures {
                for f in figures(page, lines: lines) { extras.append((f.y, .figure(f.figure))) }
            }
            perPage.append(merge(lines: lines, extras: extras))
        }
        dropRunningHeads(&perPage, pageIndices: indices, pageHeights: indices.compactMap { doc.page(at: $0).map { EditOps.PageSpace($0).size.height } })
        let items = perPage.flatMap { $0 }
        let first = indices.first.flatMap { doc.page(at: $0) }
        let title = (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Document(blocks: assemble(items), pageSize: first.map { EditOps.PageSpace($0).size } ?? CGSize(width: 612, height: 792),
                        title: title, scannedPages: scanned)
    }

    // MARK: Lines from the text layer

    struct Line {
        var page: Int
        /// Top-left points of the page as shown.
        var rect: CGRect
        var runs: [Run]
        var size: CGFloat
        var text: String { runs.map(\.text).joined() }
        var bold: Bool { runs.allSatisfy { $0.bold || $0.text.trimmingCharacters(in: .whitespaces).isEmpty } && runs.contains { $0.bold } }
    }

    enum Item {
        case line(Line)
        case table([[String]])
        case figure(Figure)
        case paragraph(String)
        case heading(String)
    }

    static func pageLines(_ page: PDFPage, index: Int) -> [Line] {
        guard let str = page.string, !str.isEmpty else { return [] }
        let ns = str as NSString
        let attributed = page.attributedString
        let useFonts = attributed?.length == ns.length
        let space = EditOps.PageSpace(page)
        var out: [Line] = []
        func isSpace(_ c: unichar) -> Bool { c == 32 || c == 9 || c == 0xA0 || c == 10 || c == 13 }
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            var r = range
            while r.length > 0, isSpace(ns.character(at: r.location)) { r.location += 1; r.length -= 1 }
            while r.length > 0, isSpace(ns.character(at: r.location + r.length - 1)) { r.length -= 1 }
            guard r.length > 0, let sel = page.selection(for: r) else { return }
            let b = sel.bounds(for: page)
            guard !b.isEmpty, b.width.isFinite, b.height.isFinite, b.height > 0 else { return }
            let rect = space.topLeft(b)
            var runs: [Run] = []
            var sizeSum: CGFloat = 0, sizeCount = 0
            if useFonts, let attributed {
                attributed.enumerateAttribute(.font, in: r, options: []) { value, sub, _ in
                    let text = ns.substring(with: sub).replacingOccurrences(of: "\t", with: " ")
                    var bold = false, italic = false
                    if let font = value as? NSFont {
                        let traits = font.fontDescriptor.symbolicTraits
                        let name = font.fontName.lowercased()
                        bold = traits.contains(.bold) || ["bold", "black", "heavy", "semibold", "demi"].contains { name.contains($0) }
                        italic = traits.contains(.italic) || name.contains("italic") || name.contains("oblique")
                        let letters = text.filter { !$0.isWhitespace }.count
                        if font.pointSize > 0, letters > 0 { sizeSum += font.pointSize * CGFloat(letters); sizeCount += letters }
                    }
                    if let last = runs.last, last.bold == bold, last.italic == italic { runs[runs.count - 1].text += text }
                    else { runs.append(Run(text: text, bold: bold, italic: italic)) }
                }
            } else {
                runs = [Run(text: ns.substring(with: r).replacingOccurrences(of: "\t", with: " "))]
            }
            var size = sizeCount > 0 ? sizeSum / CGFloat(sizeCount) : rect.height / 1.2
            // Fonts scaled by the text matrix report a nominal size; the box is then the better guide.
            if size > rect.height * 3 || size < rect.height * 0.3 { size = rect.height / 1.2 }
            out.append(Line(page: index, rect: rect, runs: runs, size: size))
        }
        return out
    }

    // MARK: Tables

    /// Only pages with columns of text are read for tables: at least three lines split into cells
    /// (column-sized gaps) whose cells start at the same places as another line's.
    static func mayHaveTable(_ page: PDFPage, index: Int) -> Bool {
        let rows = PageText.group(PageText.words(page: page, index: index)).filter { $0.cells.count >= 2 }
        guard rows.count >= 3 else { return false }
        var aligned = 0
        for (k, row) in rows.enumerated() {
            let starts = row.cells.map(\.rect.minX)
            let matches = rows.enumerated().contains { j, other in
                j != k && other.cells.filter { c in starts.contains { abs($0 - c.rect.minX) < 3 } }.count >= 2
            }
            if matches { aligned += 1; if aligned >= 3 { return true } }
        }
        return false
    }

    /// The table's cells with the PDF's own words where it has some (exact), else what OCR read.
    /// A word belongs to the cell its centre is in, so text the reader's box clips isn't cut.
    static func tableGrid(_ t: DocumentReader.Table, page: PDFPage, index: Int) -> [[String]] {
        let area = t.rect.insetBy(dx: -4, dy: -4)
        let words = PageText.words(page: page, index: index).filter { area.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }
        var cells: [Int: [TextFragment]] = [:]
        let list = t.cells.filter { $0.rows.lowerBound < t.rowCount && $0.columns.lowerBound < t.columnCount }
        for w in words {
            let c = CGPoint(x: w.rect.midX, y: w.rect.midY)
            // The cell containing it, else the nearest one in its row band (boxes hug the text).
            if let k = list.firstIndex(where: { $0.rect.insetBy(dx: -3, dy: -2).contains(c) }) ?? list.indices
                .filter({ list[$0].rect.minY - 3 <= c.y && c.y <= list[$0].rect.maxY + 3 })
                .min(by: { abs(list[$0].rect.midX - c.x) < abs(list[$1].rect.midX - c.x) }) {
                cells[k, default: []].append(w)
            }
        }
        var grid = Array(repeating: Array(repeating: "", count: t.columnCount), count: t.rowCount)
        for (k, c) in list.enumerated() {
            let fromPDF = PageText.group(cells[k] ?? []).map(\.text).joined(separator: " ")
            grid[c.rows.lowerBound][c.columns.lowerBound] = (fromPDF.isEmpty ? c.text : fromPDF).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return grid.filter { $0.contains { !$0.isEmpty } }
    }

    // MARK: Figures

    /// Images the page draws, cut from the rendered page. Backgrounds (nearly the whole page, or
    /// with text over them), tiny marks and rules are left out; overlapping tiles become one figure.
    static func figures(_ page: PDFPage, lines: [Line]) -> [(y: CGFloat, figure: Figure)] {
        guard let ref = page.pageRef else { return [] }
        let space = EditOps.PageSpace(page)
        let bounds = CGRect(origin: .zero, size: space.size)
        var rects: [CGRect] = []
        for (_, ctm) in TextEraser.imageDraws(ref) {
            let r = space.topLeft(CGRect(x: 0, y: 0, width: 1, height: 1).applying(ctm)).intersection(bounds)
            guard !r.isNull, r.width >= 24, r.height >= 24 else { continue }
            rects.append(r)
        }
        // Join tiles and overlapping images.
        var merged: [CGRect] = []
        for r in rects {
            var u = r
            var changed = true
            while changed {
                changed = false
                for (k, m) in merged.enumerated() where m.insetBy(dx: -1, dy: -1).intersects(u) {
                    u = u.union(m); merged.remove(at: k); changed = true; break
                }
            }
            merged.append(u)
        }
        let pageArea = bounds.width * bounds.height
        let keep = merged.filter { r in
            guard r.width * r.height < pageArea * 0.8 else { return false }
            let covered = lines.filter { r.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }.count
            return covered < 3
        }.sorted { $0.minY < $1.minY }
        guard !keep.isEmpty else { return [] }
        let scale: CGFloat = 2
        guard let image = PDFRaster.cgImage(page, scale: scale) else { return [] }
        let actual = CGFloat(image.width) / bounds.width     // the render may be scaled down
        return keep.compactMap { r in
            let px = CGRect(x: r.minX * actual, y: r.minY * actual, width: r.width * actual, height: r.height * actual).integral
            guard let crop = image.cropping(to: px), let jpeg = PDFRaster.encode(crop, type: .jpeg, quality: 0.85) else { return nil }
            return (r.minY, Figure(jpeg: jpeg, size: r.size))
        }
    }

    // MARK: Scanned pages

    static func scannedItems(_ read: DocumentReader.Page) -> [Item] {
        var placed: [(y: CGFloat, item: Item)] = []
        let tableRects = read.tables.map { $0.rect.insetBy(dx: -2, dy: -2) }
        for t in read.tables where t.rowCount >= 1 { placed.append((t.rect.minY, .table(t.grid.filter { $0.contains { !$0.isEmpty } }))) }
        for p in read.paragraphs where !tableRects.contains(where: { $0.contains(CGPoint(x: p.rect.midX, y: p.rect.midY)) }) {
            let text = p.text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let joined = joinLines(text)
            guard !joined.isEmpty else { continue }
            placed.append((p.rect.minY, joined == read.title?.trimmingCharacters(in: .whitespacesAndNewlines) ? .heading(joined) : .paragraph(joined)))
        }
        return placed.sorted { $0.y < $1.y }.map(\.item)
    }

    static func joinLines(_ lines: [String]) -> String {
        var out = ""
        for l in lines {
            if out.isEmpty { out = l; continue }
            if dehyphenates(out, l) { out.removeLast(); out += l } else { out += " " + l }
        }
        return out
    }

    /// "infor-" + "mation" → "information" (a hyphen at the end of a line before a lowercase word).
    static func dehyphenates(_ before: String, _ after: String) -> Bool {
        guard before.hasSuffix("-"), before.count >= 2, let next = after.first, next.isLowercase else { return false }
        let prev = before[before.index(before.endIndex, offsetBy: -2)]
        return prev.isLetter
    }

    // MARK: Putting a page together

    /// Text lines in the text layer's order, with tables and figures placed before the first line
    /// below their top.
    static func merge(lines: [Line], extras: [(y: CGFloat, item: Item)]) -> [Item] {
        var before: [Int: [(y: CGFloat, item: Item)]] = [:]
        for e in extras {
            let at = lines.firstIndex { $0.rect.minY >= e.y } ?? lines.count
            before[at, default: []].append(e)
        }
        var items: [Item] = []
        for k in 0...lines.count {
            items += (before[k] ?? []).sorted { $0.y < $1.y }.map(\.item)
            if k < lines.count { items.append(.line(lines[k])) }
        }
        return items
    }

    /// Running headers and footers: lines near the top or bottom that repeat on most pages (digits
    /// ignored, so "Page 3" matches "Page 4"), and bare page numbers.
    static func dropRunningHeads(_ pages: inout [[Item]], pageIndices: [Int], pageHeights: [CGFloat]) {
        guard pages.count == pageHeights.count, pages.count == pageIndices.count else { return }
        func zone(_ l: Line, _ h: CGFloat) -> Int? {
            if l.rect.maxY < h * 0.12 { return 0 }
            if l.rect.minY > h * 0.88 { return 1 }
            return nil
        }
        func key(_ l: Line) -> String {
            l.text.lowercased().replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        var counts: [String: Int] = [:]
        for (p, items) in pages.enumerated() {
            var seen = Set<String>()
            for case .line(let l) in items {
                guard let z = zone(l, pageHeights[p]) else { continue }
                seen.insert("\(z)|\(key(l))")
            }
            for k in seen { counts[k, default: 0] += 1 }
        }
        // Heads that change by section ("4 Chapter 1 What is…", "1.1 The age of… 3") still carry the
        // page number, which keeps step with the page: the same offset from the page index on many pages.
        func number(_ l: Line) -> Int? {
            let t = l.text.trimmingCharacters(in: .whitespaces)
            if let r = t.range(of: #"^\d{1,4}(?!\.\d)"#, options: .regularExpression) { return Int(t[r]) }
            if let r = t.range(of: #"(?<![\d.])\d{1,4}$"#, options: .regularExpression) { return Int(t[r]) }
            return nil
        }
        var offsetPages: [Int: Set<Int>] = [:]
        for (p, items) in pages.enumerated() {
            for case .line(let l) in items where zone(l, pageHeights[p]) != nil {
                if let n = number(l) { offsetPages[n - pageIndices[p], default: []].insert(p) }
            }
        }
        let steady = Set(offsetPages.filter { $0.value.count >= 3 }.keys)
        let pageNumber = try! NSRegularExpression(pattern: #"^(page\s*)?[#ivxlc]+(\s*(of|/)\s*#)?$|^[-–]\s*#\s*[-–]$"#, options: .caseInsensitive)
        let repeats = max(3, (pages.count + 1) / 2)
        let pageCount = pages.count
        for p in pages.indices {
            pages[p].removeAll { item in
                guard case .line(let l) = item, let z = zone(l, pageHeights[p]) else { return false }
                let k = key(l)
                if pageCount >= 3, counts["\(z)|\(k)", default: 0] >= repeats { return true }
                if let n = number(l), steady.contains(n - pageIndices[p]) { return true }
                return pageNumber.firstMatch(in: k, range: NSRange(k.startIndex..., in: k)) != nil
            }
        }
    }

    // MARK: Blocks

    static let marker = try! NSRegularExpression(
        pattern: #"^\s*(?:([•◦▪▫●○■□‣⁃∙·¡\-–—*\x{F0B7}\x{F0A7}\x{F076}\x{F0D8}\x{F0FC}])|\(?(\d{1,3}|[a-z])[.)])\s+"#)

    /// The list marker at the start of a line, and the length of the marker text.
    static func listMarker(_ text: String) -> (marker: ListMarker, length: Int)? {
        let ns = text as NSString
        guard let m = marker.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        guard m.range.length < ns.length else { return nil }      // a marker with nothing after it
        if m.range(at: 1).location != NSNotFound { return (.bullet, m.range.length) }
        let token = ns.substring(with: m.range(at: 2))
        if let n = Int(token) { return (.number(n), m.range.length) }
        return (.letter(Int((token.unicodeScalars.first?.value ?? 97) - 96)), m.range.length)
    }

    static let leaderPattern = #"\s*(?:[.·…]\s?){4,}\s*"#

    static func endsSentence(_ s: String) -> Bool {
        guard let c = s.trimmingCharacters(in: .whitespaces).last else { return true }
        return ".!?:;\"”’)".contains(c)
    }

    struct Open {
        enum Kind: Equatable { case paragraph, heading(Int), list(ListMarker) }
        var kind: Kind
        var runs: [Run]
        var last: Line
        var left: CGFloat
        var right: CGFloat
        var size: CGFloat
        var markerX: CGFloat
    }

    static func assemble(_ items: [Item]) -> [Block] {
        let lines = items.compactMap { if case .line(let l) = $0 { return l } else { return nil } }
        // Body size: the size most of the text is set in.
        var weight: [Int: Int] = [:]
        for l in lines { weight[Int((l.size * 2).rounded()), default: 0] += l.text.count }
        let body = CGFloat(weight.max { $0.value < $1.value }?.key ?? 22) / 2
        // Heading sizes, largest first; up to three levels.
        var sizes: [CGFloat] = []
        for l in lines where l.size >= body * 1.18 && l.text.count <= 200 && l.text.contains(where: \.isLetter) {
            let s = (l.size * 2).rounded() / 2
            if !sizes.contains(where: { abs($0 - s) < 0.75 }) { sizes.append(s) }
        }
        sizes.sort(by: >)
        func sizeLevel(_ l: Line) -> Int? {
            guard l.size >= body * 1.18, l.text.count <= 200, l.text.contains(where: \.isLetter) else { return nil }
            let k = sizes.firstIndex { abs($0 - (l.size * 2).rounded() / 2) < 0.75 } ?? sizes.count - 1
            return min(k + 1, 3)
        }
        let boldLevel = min(4, max(2, min(sizes.count, 3) + 1))
        // The usual space between lines of a paragraph.
        var gaps: [CGFloat] = []
        for (a, b) in zip(lines, lines.dropFirst()) where a.page == b.page && abs(a.size - b.size) < body * 0.1 {
            let lh = max(a.rect.height, b.rect.height)
            let g = b.rect.minY - a.rect.maxY
            if g > -lh * 0.3, g < lh * 1.2 { gaps.append(g) }
        }
        let typicalGap = gaps.isEmpty ? 0 : gaps.sorted()[gaps.count / 2]

        var blocks: [Block] = []
        var open: Open?
        func flush() {
            guard let o = open else { return }
            open = nil
            let runs = tidy(o.runs)
            let text = runs.map(\.text).joined()
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            switch o.kind {
            case .heading(let level):
                if text.count > 220 { blocks.append(.paragraph(runs.map { Run(text: $0.text, bold: true, italic: $0.italic) })) }
                else { blocks.append(.heading(level: level, text: text.trimmingCharacters(in: .whitespaces))) }
            case .paragraph: blocks.append(.paragraph(runs))
            case .list(let marker): blocks.append(.listItem(marker, runs: runs))
            }
        }
        func append(_ l: Line, runs: [Run], to o: inout Open) {
            let before = o.runs.map(\.text).joined()
            let after = runs.map(\.text).joined()
            if dehyphenates(before, after), !o.runs.isEmpty {
                o.runs[o.runs.count - 1].text.removeLast()
            } else {
                o.runs.append(Run(text: " ", bold: o.runs.last?.bold == true && runs.first?.bold == true,
                                  italic: o.runs.last?.italic == true && runs.first?.italic == true))
            }
            o.runs += runs
            o.last = l
            o.left = min(o.left, l.rect.minX)
            o.right = max(o.right, l.rect.maxX)
        }

        for (idx, item) in items.enumerated() {
            switch item {
            case .table(let rows): flush(); if !rows.isEmpty { blocks.append(.table(rows)) }; continue
            case .figure(let f): flush(); blocks.append(.figure(f)); continue
            case .paragraph(let s): flush(); blocks.append(.paragraph([Run(text: s)])); continue
            case .heading(let s): flush(); blocks.append(.heading(level: 1, text: s)); continue
            case .line: break
            }
            guard case .line(let l) = item else { continue }
            var runs = l.runs
            // A contents line ("2.1 Matrix form . . . . 7") stands on its own, leaders shortened.
            let leader = l.text.range(of: Self.leaderPattern, options: .regularExpression) != nil
            if leader {
                runs = runs.map { var r = $0; r.text = r.text.replacingOccurrences(of: Self.leaderPattern, with: " … ", options: .regularExpression); return r }
                flush()
                blocks.append(.paragraph(tidy(runs)))
                continue
            }
            var mark = listMarker(l.text)
            // "…grew by\n100. The next year…": a number starting a line inside a running sentence
            // is the sentence wrapping, not a list.
            if let m = mark, m.marker != .bullet, let o = open, o.kind == .paragraph, !endsSentence(o.last.text),
               continues(o, l, level: nil, marker: false, body: body, typicalGap: typicalGap) {
                mark = nil
            }
            if let mark { runs = dropPrefix(runs, mark.length) }
            var level = sizeLevel(l)
            if level == nil, mark == nil, l.bold, l.text.count <= 90, l.text.contains(where: \.isLetter),
               !l.text.hasSuffix(":"), !l.text.hasSuffix(","), abs(l.size - body) < body * 0.2 {
                // A short bold line is a heading when it stands on its own: the next line isn't bold
                // body text running on from it.
                var next: Line?
                for case .line(let n) in items[(idx + 1)...].prefix(1) { next = n }
                let standsAlone = next.map { n in !n.bold || n.page != l.page || n.rect.minY - l.rect.maxY > typicalGap + l.rect.height * 0.3 } ?? true
                let fresh = open.map { o in o.last.page != l.page || l.rect.minY - o.last.rect.maxY > typicalGap + l.rect.height * 0.3 || endsSentence(o.last.text) } ?? true
                if standsAlone && fresh { level = boldLevel }
            }

            if var o = open, continues(o, l, level: level, marker: mark != nil, body: body, typicalGap: typicalGap) {
                append(l, runs: runs, to: &o)
                open = o
                continue
            }
            flush()
            let kind: Open.Kind = mark.map { .list($0.marker) } ?? level.map { .heading($0) } ?? .paragraph
            open = Open(kind: kind, runs: runs, last: l, left: l.rect.minX, right: l.rect.maxX, size: l.size, markerX: l.rect.minX)
        }
        flush()
        return blocks
    }

    static func continues(_ o: Open, _ l: Line, level: Int?, marker: Bool, body: CGFloat, typicalGap: CGFloat) -> Bool {
        if marker { return false }
        let sameSize = abs(l.size - o.size) < max(o.size, l.size) * 0.15
        if l.page != o.last.page {
            // A paragraph carries on over the page break when its sentence does.
            guard o.kind == .paragraph, level == nil, sameSize else { return false }
            return !endsSentence(o.last.text)
        }
        let lh = max(l.rect.height, o.last.rect.height)
        let gap = l.rect.minY - o.last.rect.maxY
        if gap < -lh * 0.5 { return false }                      // back up the page: a new column
        if gap > max(typicalGap, 0) + lh * 0.45 { return false }  // a paragraph space
        switch o.kind {
        case .heading(let h): return level == h && gap < lh * 0.6
        case .list: return level == nil && sameSize && l.rect.minX > o.markerX + 2
        case .paragraph:
            guard level == nil, sameSize else { return false }
            if endsSentence(o.last.text) {
                // The last line stopped short, or this one is indented: a new paragraph.
                let width = o.right - o.left
                if width > lh * 8, o.last.rect.maxX < o.right - max(lh * 2, width * 0.12) { return false }
                if l.rect.minX > o.left + lh * 1.2 { return false }
            }
            return true
        }
    }

    /// Runs with the first `count` characters (a list marker) taken off.
    static func dropPrefix(_ runs: [Run], _ count: Int) -> [Run] {
        var left = count
        var out: [Run] = []
        for r in runs {
            let n = (r.text as NSString).length
            if left >= n { left -= n; continue }
            var copy = r
            if left > 0 { copy.text = (r.text as NSString).substring(from: left); left = 0 }
            out.append(copy)
        }
        return out
    }

    /// Joins neighbouring runs with the same style and squeezes repeated spaces.
    static func tidy(_ runs: [Run]) -> [Run] {
        var out: [Run] = []
        for var r in runs {
            r.text = r.text.replacingOccurrences(of: #"[ \u{00A0}]{2,}"#, with: " ", options: .regularExpression)
            guard !r.text.isEmpty else { continue }
            if let last = out.last, last.bold == r.bold, last.italic == r.italic { out[out.count - 1].text += r.text }
            else { out.append(r) }
        }
        if let f = out.first { out[0].text = String(f.text.drop { $0 == " " }) }
        if let l = out.last { out[out.count - 1].text = String(l.text.reversed().drop { $0 == " " }.reversed()) }
        return tidyJoin(out.filter { !$0.text.isEmpty })
    }

    private static func tidyJoin(_ runs: [Run]) -> [Run] {
        var out: [Run] = []
        for r in runs {
            if let last = out.last, last.bold == r.bold, last.italic == r.italic { out[out.count - 1].text += r.text } else { out.append(r) }
        }
        return out
    }
}
