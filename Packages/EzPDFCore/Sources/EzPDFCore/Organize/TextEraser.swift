import Foundation
import CoreGraphics
import CoreText
import Compression
import AppKit

/// Takes text out of a page for real: the glyphs at least half inside the given areas are
/// removed from the page's own content stream (and from form XObjects it draws), so they no longer
/// show, select, search or copy. Everything else in the stream is kept byte for byte; each removed
/// glyph becomes an equal horizontal move, so the glyphs around it stay exactly where they were.
///
/// Painting over text (what an edit did before) leaves the old words in the text layer under the
/// new ones; a second edit on the same line then selects both. This is what keeps edited pages clean.
///
/// The page comes back as a one-page PDF written from scratch: the same boxes, rotation and
/// resources (fonts, images, patterns) and the rewritten content. Annotations aren't part of it
/// (the caller keeps the page's annotations). It returns nil when the page uses something it can't
/// follow exactly (vertical text, a CID font without Identity-H encoding, a form drawn twice and
/// changed); the caller then paints over as before.
enum TextEraser {
    struct Result {
        var data: Data
        var removed: Int
    }

    /// `rects` are in the page's default user space (PDFKit page coordinates).
    static func erase(_ page: CGPDFPage, rects: [CGRect]) -> Result? {
        guard !rects.isEmpty else { return nil }
        return rewrite(page, Interpreter(mode: .areas(rects)))
    }

    /// Takes out text nobody can see: glyphs that an opaque rectangle drawn later covers (at least
    /// 90% of the glyph). Earlier versions of ezPDF painted over replaced words this way, leaving
    /// them in the text layer; editing such a line again picked them up. Nil when the page can't be
    /// read; `removed` 0 when nothing is hidden.
    static func eraseHidden(_ page: CGPDFPage) -> Result? {
        guard let content = contentBytes(page), let resources = page.dictionary.flatMap({ inherited($0, "Resources") }).flatMap(dictValue) else { return nil }
        let survey = Interpreter(mode: .survey)
        guard survey.run(content, resources: resources, ctm: .identity, depth: 0) != nil, !survey.failed else { return nil }
        var hidden = Set<Int>()
        for glyph in survey.glyphs where glyph.box.width > 0.01 && glyph.box.height > 0.01 {
            let area = glyph.box.width * glyph.box.height
            if survey.fills.contains(where: { fill in
                guard fill.order > glyph.order else { return false }
                let o = fill.rect.intersection(glyph.box)
                return !o.isNull && o.width * o.height >= area * 0.9
            }) { hidden.insert(glyph.order) }
        }
        guard !hidden.isEmpty else { return Result(data: Data(), removed: 0) }
        return rewrite(page, Interpreter(mode: .glyphs(hidden)))
    }

    /// The page's content streams, joined.
    static func contentBytes(_ page: CGPDFPage) -> [UInt8]? {
        guard let pageDict = page.dictionary else { return nil }
        var streams: [CGPDFStreamRef] = []
        var contents: CGPDFObjectRef?
        if CGPDFDictionaryGetObject(pageDict, "Contents", &contents), let contents {
            if let s = streamValue(contents) { streams = [s] }
            else if let a = arrayValue(contents) {
                for i in 0..<CGPDFArrayGetCount(a) { var s: CGPDFStreamRef?; if CGPDFArrayGetStream(a, i, &s), let s { streams.append(s) } }
            }
        }
        var bytes: [UInt8] = []
        for s in streams {
            var format = CGPDFDataFormat.raw
            guard let d = CGPDFStreamCopyData(s, &format) as Data?, format == .raw else { return nil }
            bytes += d; bytes.append(0x0A)
        }
        return bytes
    }

    /// Runs `eraser` over the page and writes the page again with what it changed.
    private static func rewrite(_ page: CGPDFPage, _ eraser: Interpreter) -> Result? {
        guard let pageDict = page.dictionary, let bytes = contentBytes(page),
              let resources = inherited(pageDict, "Resources").flatMap(dictValue) else { return nil }
        guard let newContent = eraser.run(bytes, resources: resources, ctm: .identity, depth: 0), !eraser.failed else { return nil }
        guard eraser.removed > 0 else { return Result(data: Data(), removed: 0) }
        // A changed form drawn more than once can't be changed for one place only.
        for (form, n) in eraser.formUses where n > 1 && eraser.formReplacements[form] != nil { return nil }

        let w = Writer(replacements: eraser.formReplacements)
        let media = page.getBoxRect(.mediaBox), crop = page.getBoxRect(.cropBox)
        func box(_ r: CGRect) -> String { "[\(num(r.minX)) \(num(r.minY)) \(num(r.maxX)) \(num(r.maxY))]" }
        let contentID = w.reserve()
        w.writeStream(contentID, dict: [:], data: Data(newContent))
        var pageEntries = "/Type /Page /Parent 2 0 R /MediaBox \(box(media)) /CropBox \(box(crop))"
        let rotation = Int(page.rotationAngle)
        if rotation % 360 != 0 { pageEntries += " /Rotate \(rotation)" }
        pageEntries += " /Resources " + w.value(dict: resources)
        if let group = pageDict.object("Group") { pageEntries += " /Group " + w.value(group) }
        if let unit = pageDict.object("UserUnit") { pageEntries += " /UserUnit " + w.value(unit) }
        pageEntries += " /Contents \(contentID) 0 R"
        w.write(1, "<< /Type /Catalog /Pages 2 0 R >>")
        w.write(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        w.write(3, "<< \(pageEntries) >>")
        guard let data = w.finish(), !w.failed else { return nil }
        return Result(data: data, removed: eraser.removed)
    }

    // MARK: Reading CGPDF objects

    static func dictValue(_ o: CGPDFObjectRef) -> CGPDFDictionaryRef? {
        var d: CGPDFDictionaryRef?
        if CGPDFObjectGetValue(o, .dictionary, &d) { return d }
        var s: CGPDFStreamRef?
        if CGPDFObjectGetValue(o, .stream, &s), let s { return CGPDFStreamGetDictionary(s) }
        return nil
    }
    static func streamValue(_ o: CGPDFObjectRef) -> CGPDFStreamRef? {
        var s: CGPDFStreamRef?
        return CGPDFObjectGetValue(o, .stream, &s) ? s : nil
    }
    static func arrayValue(_ o: CGPDFObjectRef) -> CGPDFArrayRef? {
        var a: CGPDFArrayRef?
        return CGPDFObjectGetValue(o, .array, &a) ? a : nil
    }
    static func numberValue(_ o: CGPDFObjectRef) -> Double? {
        var r: CGPDFReal = 0
        if CGPDFObjectGetValue(o, .real, &r) { return Double(r) }
        var i: CGPDFInteger = 0
        if CGPDFObjectGetValue(o, .integer, &i) { return Double(i) }
        return nil
    }
    static func nameValue(_ o: CGPDFObjectRef) -> String? {
        var n: UnsafePointer<CChar>?
        return CGPDFObjectGetValue(o, .name, &n) ? n.map { String(cString: $0) } : nil
    }
    /// A page key that may be inherited from the page tree (Resources, MediaBox, …).
    static func inherited(_ page: CGPDFDictionaryRef, _ key: String) -> CGPDFObjectRef? {
        var d: CGPDFDictionaryRef? = page
        for _ in 0..<32 {
            guard let cur = d else { return nil }
            if let o = cur.object(key) { return o }
            var parent: CGPDFDictionaryRef?
            d = CGPDFDictionaryGetDictionary(cur, "Parent", &parent) ? parent : nil
        }
        return nil
    }

    static func num(_ v: CGFloat) -> String { num(Double(v)) }
    static func num(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e9 { return String(Int(v)) }
        var s = String(format: "%.5f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    // MARK: Content streams

    /// One value in a content stream.
    indirect enum Val {
        case number(Double), name(String), string([UInt8]), array([Val]), dict([String: Val]), bool(Bool), null
        var number: Double? { if case .number(let n) = self { return n }; return nil }
        var name: String? { if case .name(let n) = self { return n }; return nil }
    }

    /// An operator with its operands and where it sits in the stream (operands included).
    struct Instruction {
        var op: String
        var operands: [Val]
        var range: Range<Int>
    }

    /// Splits a content stream into instructions. Inline images (BI … ID … EI) come back as one
    /// "BI" instruction that is never changed.
    static func parse(_ b: [UInt8]) -> [Instruction]? {
        var i = 0
        let n = b.count
        var out: [Instruction] = []
        var operands: [Val] = []
        var operandStart: Int?
        func isWhite(_ c: UInt8) -> Bool { c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32 }
        func isDelim(_ c: UInt8) -> Bool { "()<>[]{}/%".utf8.contains(c) }
        func skipWhite() {
            while i < n {
                if isWhite(b[i]) { i += 1 }
                else if b[i] == UInt8(ascii: "%") { while i < n, b[i] != 10, b[i] != 13 { i += 1 } }
                else { break }
            }
        }
        func regular() -> String {
            let s = i
            while i < n, !isWhite(b[i]), !isDelim(b[i]) { i += 1 }
            return String(decoding: b[s..<i], as: UTF8.self)
        }
        func literal() -> [UInt8]? {
            i += 1   // (
            var depth = 1
            var s: [UInt8] = []
            while i < n {
                let c = b[i]
                if c == UInt8(ascii: "\\") {
                    i += 1
                    guard i < n else { return nil }
                    let e = b[i]
                    switch e {
                    case UInt8(ascii: "n"): s.append(10); i += 1
                    case UInt8(ascii: "r"): s.append(13); i += 1
                    case UInt8(ascii: "t"): s.append(9); i += 1
                    case UInt8(ascii: "b"): s.append(8); i += 1
                    case UInt8(ascii: "f"): s.append(12); i += 1
                    case 13: i += 1; if i < n, b[i] == 10 { i += 1 }
                    case 10: i += 1
                    case UInt8(ascii: "0")...UInt8(ascii: "7"):
                        var v = 0, k = 0
                        while k < 3, i < n, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(b[i]) { v = v * 8 + Int(b[i] - 48); i += 1; k += 1 }
                        s.append(UInt8(v & 0xFF))
                    default: s.append(e); i += 1
                    }
                    continue
                }
                if c == UInt8(ascii: "(") { depth += 1 }
                if c == UInt8(ascii: ")") { depth -= 1; if depth == 0 { i += 1; return s } }
                s.append(c); i += 1
            }
            return nil
        }
        func hex() -> [UInt8]? {
            i += 1   // <
            var digits: [UInt8] = []
            while i < n, b[i] != UInt8(ascii: ">") {
                let c = b[i]
                if let v = hexDigit(c) { digits.append(v) } else if !isWhite(c) { return nil }
                i += 1
            }
            guard i < n else { return nil }
            i += 1
            if digits.count % 2 == 1 { digits.append(0) }
            return stride(from: 0, to: digits.count, by: 2).map { digits[$0] << 4 | digits[$0 + 1] }
        }
        func value() -> Val? {
            skipWhite()
            guard i < n else { return nil }
            let c = b[i]
            switch c {
            case UInt8(ascii: "("): return literal().map(Val.string)
            case UInt8(ascii: "<"):
                if i + 1 < n, b[i + 1] == UInt8(ascii: "<") {
                    i += 2
                    var d: [String: Val] = [:]
                    while true {
                        skipWhite()
                        guard i < n else { return nil }
                        if b[i] == UInt8(ascii: ">") { i += 2; return .dict(d) }
                        guard case .name(let k)? = value(), let v = value() else { return nil }
                        d[k] = v
                    }
                }
                return hex().map(Val.string)
            case UInt8(ascii: "["):
                i += 1
                var a: [Val] = []
                while true {
                    skipWhite()
                    guard i < n else { return nil }
                    if b[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
                    guard let v = value() else { return nil }
                    a.append(v)
                }
            case UInt8(ascii: "/"):
                i += 1
                return .name(regular())
            default:
                let s = regular()
                if let d = Double(s) { return .number(d) }
                if s == "true" { return .bool(true) }
                if s == "false" { return .bool(false) }
                if s == "null" { return .null }
                return nil
            }
        }
        while true {
            skipWhite()
            guard i < n else { break }
            let start = i
            let c = b[i]
            let opening = c == UInt8(ascii: "(") || c == UInt8(ascii: "<") || c == UInt8(ascii: "[") || c == UInt8(ascii: "/")
                || c == UInt8(ascii: "-") || c == UInt8(ascii: "+") || c == UInt8(ascii: ".") || (48...57).contains(c)
            if opening {
                guard let v = value() else { return nil }
                if operandStart == nil { operandStart = start }
                operands.append(v)
                continue
            }
            if isDelim(c) { return nil }   // a stray ) ] > }
            let word = regular()
            if word.isEmpty { return nil }
            if word == "true" || word == "false" || word == "null" {
                if operandStart == nil { operandStart = start }
                operands.append(word == "null" ? .null : .bool(word == "true"))
                continue
            }
            if word == "BI" {
                // Inline image: skip its dictionary and data up to "EI" standing alone.
                guard let id = find(b, "ID", from: i) else { return nil }
                var j = id + 3
                var end: Int?
                while j + 1 < n {
                    if b[j] == UInt8(ascii: "E"), b[j + 1] == UInt8(ascii: "I"), isWhite(b[j - 1]), j + 2 >= n || isWhite(b[j + 2]) || isDelim(b[j + 2]) {
                        end = j + 2; break
                    }
                    j += 1
                }
                guard let end else { return nil }
                out.append(Instruction(op: "BI", operands: [], range: (operandStart ?? start)..<end))
                i = end
            } else {
                out.append(Instruction(op: word, operands: operands, range: (operandStart ?? start)..<i))
            }
            operands = []
            operandStart = nil
        }
        return out
    }

    static func hexDigit(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 65...70: return c - 55
        case 97...102: return c - 87
        default: return nil
        }
    }

    static func find(_ b: [UInt8], _ word: String, from: Int) -> Int? {
        let w = Array(word.utf8)
        var i = from
        while i + w.count <= b.count {
            if b[i..<(i + w.count)].elementsEqual(w), i == 0 || [0, 9, 10, 12, 13, 32].contains(b[i - 1]),
               i + w.count == b.count || [0, 9, 10, 12, 13, 32].contains(b[i + w.count]) { return i }
            i += 1
        }
        return nil
    }

    // MARK: Fonts

    /// What it takes to step through a font's glyphs: code length and advance widths (text space, per unit size).
    struct Font {
        var twoByte: Bool
        var width: (Int) -> Double
    }

    static func loadFont(_ dict: CGPDFDictionaryRef) -> Font? {
        var subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype else { return nil }
        switch String(cString: subtype) {
        case "Type0":
            // Only Identity-H, where the code is the CID; other CMaps need their tables.
            var enc: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dict, "Encoding", &enc), let enc, String(cString: enc) == "Identity-H" else { return nil }
            var descendants: CGPDFArrayRef?
            var cid: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetArray(dict, "DescendantFonts", &descendants), let descendants,
                  CGPDFArrayGetDictionary(descendants, 0, &cid), let cid else { return nil }
            var dw: CGPDFReal = 1000
            var dwInt: CGPDFInteger = 0
            if CGPDFDictionaryGetInteger(cid, "DW", &dwInt) { dw = CGFloat(dwInt) } else { _ = CGPDFDictionaryGetNumber(cid, "DW", &dw) }
            var widths: [Int: Double] = [:]
            var w: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(cid, "W", &w), let w {
                var k = 0
                let count = CGPDFArrayGetCount(w)
                while k < count {
                    var first: CGPDFObjectRef?
                    guard CGPDFArrayGetObject(w, k, &first), let first, let c0 = numberValue(first) else { return nil }
                    var next: CGPDFObjectRef?
                    guard CGPDFArrayGetObject(w, k + 1, &next), let next else { return nil }
                    if let list = arrayValue(next) {
                        for j in 0..<CGPDFArrayGetCount(list) {
                            var o: CGPDFObjectRef?
                            if CGPDFArrayGetObject(list, j, &o), let o, let v = numberValue(o) { widths[Int(c0) + j] = v }
                        }
                        k += 2
                    } else {
                        var third: CGPDFObjectRef?
                        guard let c1 = numberValue(next), CGPDFArrayGetObject(w, k + 2, &third), let third, let v = numberValue(third),
                              c1 >= c0, c1 - c0 < 70_000 else { return nil }
                        for c in Int(c0)...Int(c1) { widths[c] = v }
                        k += 3
                    }
                }
            }
            let fallback = Double(dw)
            return Font(twoByte: true, width: { (widths[$0] ?? fallback) / 1000 })
        case "Type3":
            var matrix: CGPDFArrayRef?
            var a: CGPDFReal = 0.001
            if CGPDFDictionaryGetArray(dict, "FontMatrix", &matrix), let matrix { _ = CGPDFArrayGetNumber(matrix, 0, &a) }
            let widths = simpleWidths(dict)
            guard let widths else { return nil }
            let scale = Double(a)
            return Font(twoByte: false, width: { (widths.list[$0] ?? widths.missing) * scale })
        default:
            if let widths = simpleWidths(dict) {
                return Font(twoByte: false, width: { (widths.list[$0] ?? widths.missing) / 1000 })
            }
            // A standard font without a Widths array: measure it with the Mac's copy of the face.
            var base: UnsafePointer<CChar>?
            var name = "Helvetica"
            if CGPDFDictionaryGetName(dict, "BaseFont", &base), let base { name = Fonts.baseName(String(cString: base)) }
            let ct = CTFontCreateWithName((NSFont(name: name, size: 1000)?.fontName ?? "Helvetica") as CFString, 1000, nil)
            var cache: [Int: Double] = [:]
            return Font(twoByte: false, width: { code in
                if let v = cache[code] { return v }
                var ch = UniChar(code), glyph = CGGlyph(0)
                var v = 0.5
                if CTFontGetGlyphsForCharacters(ct, &ch, &glyph, 1) {
                    var adv = CGSize.zero
                    CTFontGetAdvancesForGlyphs(ct, .horizontal, &glyph, &adv, 1)
                    v = Double(adv.width) / 1000
                }
                cache[code] = v
                return v
            })
        }
    }

    static func simpleWidths(_ dict: CGPDFDictionaryRef) -> (list: [Int: Double], missing: Double)? {
        var widths: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dict, "Widths", &widths), let widths else { return nil }
        var firstInt: CGPDFInteger = 0
        _ = CGPDFDictionaryGetInteger(dict, "FirstChar", &firstInt)
        var list: [Int: Double] = [:]
        for j in 0..<CGPDFArrayGetCount(widths) {
            var o: CGPDFObjectRef?
            if CGPDFArrayGetObject(widths, j, &o), let o, let v = numberValue(o) { list[firstInt + j] = v }
        }
        var missing: CGPDFReal = 0
        var descriptor: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(dict, "FontDescriptor", &descriptor), let descriptor { _ = CGPDFDictionaryGetNumber(descriptor, "MissingWidth", &missing) }
        return (list, Double(missing))
    }

    // MARK: Interpreting

    final class Interpreter {
        enum Mode {
            /// Remove glyphs at least half inside these areas.
            case areas([CGRect])
            /// Remove the glyphs with these drawing-order numbers (from a survey of the same page).
            case glyphs(Set<Int>)
            /// Remove nothing; record glyph boxes and opaque rectangle fills in drawing order.
            case survey
        }
        let mode: Mode
        /// Every glyph and every fill gets the next number, in the order they're drawn.
        private var order = 0
        var glyphs: [(order: Int, box: CGRect)] = []
        var fills: [(order: Int, rect: CGRect)] = []
        var removed = 0
        var failed = false
        /// New content for form XObjects that lost glyphs, by stream.
        var formReplacements: [CGPDFStreamRef: [UInt8]] = [:]
        var formUses: [CGPDFStreamRef: Int] = [:]
        private var fonts: [CGPDFDictionaryRef: Font] = [:]

        init(mode: Mode) { self.mode = mode }

        private func shouldRemove(_ glyph: CGRect, at point: CGPoint, order: Int) -> Bool {
            switch mode {
            case .survey:
                glyphs.append((order, glyph))
                return false
            case .glyphs(let set):
                return set.contains(order)
            case .areas(let rects):
                // At least half the glyph's box inside an area (pdfSweep's overlap rule); a zero-width
                // glyph (an accent) when its position is inside.
                if glyph.width < 0.01 || glyph.height < 0.01 { return rects.contains { $0.contains(point) } }
                let area = glyph.width * glyph.height
                return rects.contains { let o = $0.intersection(glyph); return !o.isNull && o.width * o.height >= area * 0.5 }
            }
        }

        struct TextState {
            var charSpace = 0.0, wordSpace = 0.0, scale = 1.0, leading = 0.0, rise = 0.0, size = 0.0
            /// Text render mode (Tr): 4–7 also add the glyphs to the clipping path.
            var mode = 0
            var font: Font?
            /// Set by Tf when the font couldn't be read: glyph positions are then unknown.
            var unreadable = false
        }
        struct GState {
            var ctm: CGAffineTransform
            var text: TextState
            /// Fills may be see-through (ExtGState alpha, soft mask, blending): then they don't count as covering.
            var opaque = true
            /// The clip so far, when it's made of rectangles; `clipKnown` false once it isn't.
            var clip = CGRect.infinite
            var clipKnown = true
        }

        /// Returns the stream with glyphs inside `rects` taken out (unchanged bytes if none were).
        func run(_ bytes: [UInt8], resources: CGPDFDictionaryRef?, ctm: CGAffineTransform, depth: Int) -> [UInt8]? {
            guard depth < 8, let instructions = TextEraser.parse(bytes) else { failed = true; return nil }
            var g = GState(ctm: ctm, text: TextState())
            var stack: [GState] = []
            var tm = CGAffineTransform.identity, tlm = CGAffineTransform.identity
            var edits: [(Range<Int>, [UInt8])] = []
            var marked: [(ins: Instruction, actual: Bool, touched: Bool)] = []
            var clipText = false
            var path: [CGRect] = []
            var pathIsRects = true
            var pendingClip = false

            func font(named name: String) -> Font? {
                guard let resources else { return nil }
                var fontsDict: CGPDFDictionaryRef?
                var f: CGPDFDictionaryRef?
                guard CGPDFDictionaryGetDictionary(resources, "Font", &fontsDict), let fontsDict,
                      CGPDFDictionaryGetDictionary(fontsDict, name, &f), let f else { return nil }
                if let cached = fonts[f] { return cached }
                guard let loaded = TextEraser.loadFont(f) else { return nil }
                fonts[f] = loaded
                return loaded
            }
            func moveLine(_ tx: Double, _ ty: Double) {
                tlm = CGAffineTransform(translationX: tx, y: ty).concatenating(tlm)
                tm = tlm
            }
            /// Steps through a show operator's pieces; returns its rewritten TJ array if any glyph was removed.
            func show(_ pieces: [Val]) -> [UInt8]?? {
                let t = g.text
                guard let f = t.font else { return .some(nil) }   // no font: nothing to place (and nothing drawn)
                let th = t.scale
                guard t.size != 0, th != 0 else { return .some(nil) }
                var out: [Val] = []
                var kept: [UInt8] = []
                var changed = false
                func flush() { if !kept.isEmpty { out.append(.string(kept)); kept = [] } }
                for piece in pieces {
                    switch piece {
                    case .number(let adj):
                        flush()
                        out.append(.number(adj))
                        tm = CGAffineTransform(translationX: -adj / 1000 * t.size * th, y: 0).concatenating(tm)
                    case .string(let s):
                        var k = 0
                        while k < s.count {
                            let len = f.twoByte ? 2 : 1
                            guard k + len <= s.count else { break }
                            let code = f.twoByte ? Int(s[k]) << 8 | Int(s[k + 1]) : Int(s[k])
                            let w0 = f.width(code)
                            let isSpace = !f.twoByte && code == 32
                            let tx = (w0 * t.size + t.charSpace + (isSpace ? t.wordSpace : 0)) * th
                            // The glyph's box on the page: its advance × descent…ascent.
                            let m = tm.concatenating(g.ctm)
                            let glyph = CGRect(x: 0, y: -0.22 * t.size + t.rise, width: max(0, w0 * t.size * th), height: 1.0 * t.size).applying(m)
                            order += 1
                            let inside = shouldRemove(glyph, at: CGPoint(x: 0, y: 0.3 * t.size + t.rise).applying(m), order: order)
                            if inside, t.mode >= 4 { clipText = true }
                            if inside {
                                flush()
                                out.append(.number(-tx * 1000 / (t.size * th)))
                                changed = true
                                removed += 1
                            } else {
                                kept.append(contentsOf: s[k..<(k + len)])
                            }
                            tm = CGAffineTransform(translationX: tx, y: 0).concatenating(tm)
                            k += len
                        }
                    default: break
                    }
                }
                flush()
                guard changed else { return .some(nil) }
                return .some(TextEraser.serialize(.array(out)) + Array(" TJ".utf8))
            }

            for ins in instructions {
                let o = ins.operands
                func nums(_ k: Int) -> [Double]? {
                    let v = o.suffix(k).compactMap(\.number)
                    return v.count == k ? v : nil
                }
                switch ins.op {
                case "q": stack.append(g)
                case "Q": if let last = stack.popLast() { g = last }
                case "cm":
                    if let m = nums(6) { g.ctm = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]).concatenating(g.ctm) }
                case "BT": tm = .identity; tlm = .identity
                case "Tc": if let v = nums(1) { g.text.charSpace = v[0] }
                case "Tw": if let v = nums(1) { g.text.wordSpace = v[0] }
                case "Tz": if let v = nums(1) { g.text.scale = v[0] / 100 }
                case "TL": if let v = nums(1) { g.text.leading = v[0] }
                case "Ts": if let v = nums(1) { g.text.rise = v[0] }
                case "Tr": if let v = nums(1) { g.text.mode = Int(v[0]) }
                case "re":
                    // A rectangle on the page (only exact when the CTM doesn't rotate or skew it).
                    if let v = nums(4), abs(g.ctm.b) < 1e-6, abs(g.ctm.c) < 1e-6 {
                        path.append(CGRect(x: v[0], y: v[1], width: v[2], height: v[3]).standardized.applying(g.ctm))
                    } else { pathIsRects = false }
                case "m", "l", "c", "v", "y", "h": pathIsRects = false
                case "W", "W*":
                    // The clip applies once the path is painted (or ended with n); rectangles keep it exact.
                    pendingClip = true
                case "f", "F", "f*", "B", "B*", "b", "b*", "n", "S", "s":
                    if ins.op != "n", ins.op != "S", ins.op != "s", pathIsRects, g.opaque, g.clipKnown {
                        for r in path {
                            let shown = r.intersection(g.clip)
                            if !shown.isNull, !shown.isEmpty { order += 1; fills.append((order, shown)) }
                        }
                    }
                    if pendingClip {
                        if pathIsRects, path.count == 1 { g.clip = g.clip.intersection(path[0]) } else { g.clipKnown = false }
                        pendingClip = false
                    }
                    path = []; pathIsRects = true
                case "gs":
                    // See-through or masked drawing doesn't hide what's under it.
                    if let name = o.last?.name, let resources {
                        var states: CGPDFDictionaryRef?, state: CGPDFDictionaryRef?
                        if CGPDFDictionaryGetDictionary(resources, "ExtGState", &states), let states,
                           CGPDFDictionaryGetDictionary(states, name, &state), let state {
                            var alpha: CGPDFReal = 1
                            if CGPDFDictionaryGetNumber(state, "ca", &alpha) { g.opaque = alpha >= 0.999 }
                            if let mask = state.object("SMask"), TextEraser.nameValue(mask) != "None" { g.opaque = false }
                            var blend: UnsafePointer<CChar>?
                            if CGPDFDictionaryGetName(state, "BM", &blend), let blend, !["Normal", "Compatible"].contains(String(cString: blend)) { g.opaque = false }
                        }
                    }
                case "BDC", "BMC":
                    var actual = false
                    if ins.op == "BDC", case .dict(let d)? = o.last, d["ActualText"] != nil { actual = true }
                    marked.append((ins, actual, false))
                case "EMC":
                    if let last = marked.popLast(), last.actual, last.touched, case .dict(var d)? = last.ins.operands.last, let tag = last.ins.operands.first?.name {
                        // Its replacement text would still read as the removed words.
                        d["ActualText"] = nil
                        var rewritten: [UInt8] = Array(TextEraser.name(tag).utf8)
                        if d.isEmpty {
                            rewritten += Array(" BMC".utf8)
                        } else {
                            rewritten.append(32)
                            rewritten += TextEraser.serialize(.dict(d))
                            rewritten += Array(" BDC".utf8)
                        }
                        edits.append((last.ins.range, rewritten))
                    }
                case "Tf":
                    if o.count >= 2, let name = o[o.count - 2].name, let size = o[o.count - 1].number {
                        g.text.size = size
                        g.text.font = font(named: name)
                        g.text.unreadable = g.text.font == nil
                    }
                case "Td": if let v = nums(2) { moveLine(v[0], v[1]) }
                case "TD": if let v = nums(2) { g.text.leading = -v[1]; moveLine(v[0], v[1]) }
                case "Tm":
                    if let m = nums(6) { tlm = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]); tm = tlm }
                case "T*": moveLine(0, -g.text.leading)
                case "Tj", "'", "\"", "TJ":
                    // Text in a font this can't measure: its glyphs can't be placed, so stop.
                    if g.text.unreadable { failed = true; return nil }
                    var prefix: [UInt8] = []
                    var pieces: [Val] = []
                    switch ins.op {
                    case "Tj": if case .string(let s)? = o.last { pieces = [.string(s)] }
                    case "TJ": if case .array(let a)? = o.last { pieces = a }
                    case "'":
                        moveLine(0, -g.text.leading)
                        prefix = Array("T* ".utf8)
                        if case .string(let s)? = o.last { pieces = [.string(s)] }
                    default:   // "  aw ac string
                        if o.count >= 3, let aw = o[o.count - 3].number, let ac = o[o.count - 2].number, case .string(let s) = o[o.count - 1] {
                            g.text.wordSpace = aw; g.text.charSpace = ac
                            prefix = Array("\(TextEraser.num(aw)) Tw \(TextEraser.num(ac)) Tc T* ".utf8)
                            pieces = [.string(s)]
                        }
                        moveLine(0, -g.text.leading)
                    }
                    if let result = show(pieces), let rewritten = result {
                        edits.append((ins.range, prefix + rewritten))
                        for k in marked.indices where marked[k].actual { marked[k].touched = true }
                    }
                    // Taking out glyphs that clip would change what the clip shows.
                    if clipText { failed = true; return nil }
                case "Do":
                    guard let name = o.last?.name, let resources else { break }
                    var xobjects: CGPDFDictionaryRef?
                    var stream: CGPDFStreamRef?
                    guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects,
                          CGPDFDictionaryGetStream(xobjects, name, &stream), let stream,
                          let dict = CGPDFStreamGetDictionary(stream) else { break }
                    var st: UnsafePointer<CChar>?
                    guard CGPDFDictionaryGetName(dict, "Subtype", &st), let st, String(cString: st) == "Form" else { break }
                    formUses[stream, default: 0] += 1
                    var matrix = CGAffineTransform.identity
                    var m: CGPDFArrayRef?
                    if CGPDFDictionaryGetArray(dict, "Matrix", &m), let m, CGPDFArrayGetCount(m) == 6 {
                        var v = [CGPDFReal](repeating: 0, count: 6)
                        for k in 0..<6 { _ = CGPDFArrayGetNumber(m, k, &v[k]) }
                        matrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
                    }
                    var formResources: CGPDFDictionaryRef?
                    let res = CGPDFDictionaryGetDictionary(dict, "Resources", &formResources) ? formResources : resources
                    var format = CGPDFDataFormat.raw
                    guard let data = CGPDFStreamCopyData(stream, &format) as Data?, format == .raw else { failed = true; return nil }
                    let before = removed
                    guard let rewritten = run([UInt8](data), resources: res, ctm: matrix.concatenating(g.ctm), depth: depth + 1) else { return nil }
                    if removed > before { formReplacements[stream] = rewritten }
                default: break
                }
            }
            guard !edits.isEmpty else { return bytes }
            var out: [UInt8] = []
            var at = 0
            for (r, new) in edits.sorted(by: { $0.0.lowerBound < $1.0.lowerBound }) {
                out += bytes[at..<r.lowerBound]
                out += new
                at = r.upperBound
            }
            out += bytes[at...]
            return out
        }
    }

    /// A content-stream value written back out (strings as hex).
    static func serialize(_ v: Val) -> [UInt8] {
        switch v {
        case .number(let d): return Array(num(d).utf8)
        case .name(let s): return Array(name(s).utf8)
        case .string(let s): return Array(("<" + s.map { String(format: "%02X", $0) }.joined() + ">").utf8)
        case .array(let a):
            var out = Array("[".utf8)
            for (k, v) in a.enumerated() {
                if k > 0 { out.append(32) }
                out += serialize(v)
            }
            return out + Array("]".utf8)
        case .dict(let d):
            var out = Array("<<".utf8)
            for (k, v) in d {
                out += Array(name(k).utf8)
                out.append(32)
                out += serialize(v)
                out.append(32)
            }
            return out + Array(">>".utf8)
        case .bool(let b): return Array((b ? "true" : "false").utf8)
        case .null: return Array("null".utf8)
        }
    }

    // MARK: Writing a PDF

    /// Writes objects copied from a CGPDF document into a new file. Streams become their own
    /// objects (shared ones written once); dictionaries and arrays are written inline.
    final class Writer {
        private var out = Data()
        private var offsets: [Int: Int] = [:]
        private var next = 4
        private var streamIDs: [CGPDFStreamRef: Int] = [:]
        private var pending: [(Int, CGPDFStreamRef)] = []
        private let replacements: [CGPDFStreamRef: [UInt8]]
        private var path: Set<CGPDFDictionaryRef> = []
        var failed = false

        init(replacements: [CGPDFStreamRef: [UInt8]]) {
            self.replacements = replacements
            out.append(contentsOf: Array("%PDF-1.7\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8))
        }

        func reserve() -> Int { defer { next += 1 }; return next }

        func write(_ id: Int, _ body: String) { write(id, Data(body.utf8)) }
        func write(_ id: Int, _ body: Data) {
            offsets[id] = out.count
            out.append(contentsOf: Array("\(id) 0 obj\n".utf8))
            out.append(body)
            out.append(contentsOf: Array("\nendobj\n".utf8))
        }

        func writeStream(_ id: Int, dict: [String: String], data: Data, compress: Bool = true) {
            var entries = dict
            var payload = data
            if compress, let z = TextEraser.zlib(data) { payload = z; entries["Filter"] = "/FlateDecode" }
            entries["Length"] = "\(payload.count)"
            var body = Data(("<< " + entries.map { "/\($0.key) \($0.value)" }.joined(separator: " ") + " >>\nstream\n").utf8)
            body.append(payload)
            body.append(contentsOf: Array("\nendstream".utf8))
            write(id, body)
        }

        func value(_ o: CGPDFObjectRef, depth: Int = 0) -> String {
            guard depth < 64 else { return "null" }
            switch CGPDFObjectGetType(o) {
            case .null: return "null"
            case .boolean:
                var b: CGPDFBoolean = 0
                CGPDFObjectGetValue(o, .boolean, &b)
                return b != 0 ? "true" : "false"
            case .integer:
                var i: CGPDFInteger = 0
                CGPDFObjectGetValue(o, .integer, &i)
                return String(i)
            case .real:
                var r: CGPDFReal = 0
                CGPDFObjectGetValue(o, .real, &r)
                return TextEraser.num(r)
            case .name:
                return TextEraser.nameValue(o).map(TextEraser.name) ?? "null"
            case .string:
                var s: CGPDFStringRef?
                guard CGPDFObjectGetValue(o, .string, &s), let s, let p = CGPDFStringGetBytePtr(s) else { return "()" }
                let bytes = UnsafeBufferPointer(start: p, count: CGPDFStringGetLength(s))
                return "<" + bytes.map { String(format: "%02X", $0) }.joined() + ">"
            case .array:
                guard let a = TextEraser.arrayValue(o) else { return "[]" }
                var parts: [String] = []
                for k in 0..<CGPDFArrayGetCount(a) {
                    var e: CGPDFObjectRef?
                    if CGPDFArrayGetObject(a, k, &e), let e { parts.append(value(e, depth: depth + 1)) } else { parts.append("null") }
                }
                return "[" + parts.joined(separator: " ") + "]"
            case .dictionary:
                var d: CGPDFDictionaryRef?
                guard CGPDFObjectGetValue(o, .dictionary, &d), let d else { return "<<>>" }
                return value(dict: d, depth: depth + 1)
            case .stream:
                guard let s = TextEraser.streamValue(o) else { return "null" }
                if let id = streamIDs[s] { return "\(id) 0 R" }
                let id = reserve()
                streamIDs[s] = id
                pending.append((id, s))
                return "\(id) 0 R"
            @unknown default: return "null"
            }
        }

        func value(dict d: CGPDFDictionaryRef, depth: Int = 0, skipping skip: Set<String> = ["Parent"]) -> String {
            guard !path.contains(d) else { return "null" }   // a loop back up the tree
            path.insert(d)
            defer { path.remove(d) }
            var parts: [String] = []
            CGPDFDictionaryApplyBlock(d, { key, obj, _ in
                let k = String(cString: key)
                if !skip.contains(k) { parts.append(TextEraser.name(k) + " " + self.value(obj, depth: depth + 1)) }
                return true
            }, nil)
            return "<< " + parts.joined(separator: " ") + " >>"
        }

        private func writePendingStreams() {
            while let (id, s) = pending.popLast() {
                guard let d = CGPDFStreamGetDictionary(s) else { failed = true; continue }
                var format = CGPDFDataFormat.raw
                let data: Data
                if let replaced = replacements[s] { data = Data(replaced) }
                else if let copied = CGPDFStreamCopyData(s, &format) as Data? { data = copied }
                else { failed = true; continue }
                var entries: [String: String] = [:]
                var filter: String?
                CGPDFDictionaryApplyBlock(d, { key, obj, _ in
                    let k = String(cString: key)
                    if k == "Filter" { filter = TextEraser.nameValue(obj) }
                    if !["Length", "Filter", "DecodeParms"].contains(k) { entries[k] = self.value(obj, depth: 1) }
                    return true
                }, nil)
                switch format {
                case .jpegEncoded:
                    entries["Filter"] = "/DCTDecode"
                    if filter == "DCTDecode", let parms = d.object("DecodeParms") { entries["DecodeParms"] = value(parms, depth: 1) }
                    writeStream(id, dict: entries, data: data, compress: false)
                case .JPEG2000:
                    entries["Filter"] = "/JPXDecode"
                    writeStream(id, dict: entries, data: data, compress: false)
                default:
                    writeStream(id, dict: entries, data: data)
                }
            }
        }

        func finish() -> Data? {
            writePendingStreams()
            let count = next
            let xref = out.count
            var table = "xref\n0 \(count)\n0000000000 65535 f \n"
            for id in 1..<count {
                guard let at = offsets[id] else { return nil }
                table += String(format: "%010d 00000 n \n", at)
            }
            table += "trailer\n<< /Size \(count) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
            out.append(contentsOf: Array(table.utf8))
            return out
        }
    }

    /// A PDF name with the characters a name can't hold written as #xx.
    static func name(_ s: String) -> String {
        var out = "/"
        for b in s.utf8 {
            if b < 33 || b > 126 || "()<>[]{}/%#".utf8.contains(b) { out += String(format: "#%02X", b) }
            else { out.append(Character(UnicodeScalar(b))) }
        }
        return out
    }

    /// zlib-wrapped DEFLATE (what /FlateDecode reads).
    static func zlib(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data([0x78, 0x9C, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01]) }
        let capacity = data.count + data.count / 10 + 1024
        var dst = [UInt8](repeating: 0, count: capacity)
        let n = data.withUnsafeBytes { src in
            compression_encode_buffer(&dst, capacity, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
        guard n > 0 else { return nil }
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        let adler = (b << 16) | a
        var out = Data([0x78, 0x9C])
        out.append(contentsOf: dst[0..<n])
        out.append(contentsOf: [UInt8(adler >> 24), UInt8(adler >> 16 & 0xFF), UInt8(adler >> 8 & 0xFF), UInt8(adler & 0xFF)])
        return out
    }
}

extension CGPDFDictionaryRef {
    func object(_ key: String) -> CGPDFObjectRef? {
        var o: CGPDFObjectRef?
        return CGPDFDictionaryGetObject(self, key, &o) ? o : nil
    }
}
