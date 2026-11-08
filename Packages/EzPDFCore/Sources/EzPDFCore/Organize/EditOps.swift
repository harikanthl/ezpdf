import Foundation
import AppKit
import PDFKit
import CoreText
import ImageIO

/// Editing on top of PDFKit and Core Graphics.
///
/// Two kinds of edits:
/// - Page content (text, images, signatures, white-outs): the page is redrawn as vector PDF with
///   the new content drawn on top, so it's part of the page, not a removable annotation. Text stays
///   real, selectable text.
/// - Annotations (highlights, notes, shapes, ink, form values): standard PDF annotations other
///   apps understand; `flatten` burns them into the page.
///
/// Coordinates: callers give points with the origin at the TOP-left of the page as it is shown
/// (crop box, after the page's rotation), which is what people and agents see. `PageSpace` does
/// every conversion to and from PDF page space.
public enum EditOps {
    // MARK: Overlays drawn into page content

    public enum Overlay {
        case text(String, rect: CGRect, font: NSFont, color: NSColor, alignment: NSTextAlignment)
        case image(CGImage, rect: CGRect)
        case fill(CGRect, NSColor)
        /// Old text going away: the glyphs under the area are taken out of the page (see
        /// TextEraser), then the area is painted in its background color for anything else there.
        case erase(CGRect, NSColor)
    }

    /// Redraws `index` with overlays on top. Overlay rects are top-left points of the page as shown,
    /// and overlays are drawn upright as shown, on rotated pages too. Annotations on the page are
    /// kept, and outline entries and links that pointed at the page point at the new one.
    public static func compose(_ doc: PDFDocument, page index: Int, overlays: [Overlay]) throws {
        try compose(doc, overlays: [index: overlays])
    }

    /// Redraws several pages at once. They're written in one pass so fonts and images the pages
    /// share are embedded once, not once per page (page numbers on 50 pages stay small).
    public static func compose(_ doc: PDFDocument, overlays byPage: [Int: [Overlay]]) throws {
        let indices = byPage.filter { !$0.value.isEmpty }.keys.sorted()
        guard !indices.isEmpty else { return }
        var olds: [PDFPage] = []
        for i in indices {
            guard let page = doc.page(at: i), page.pageRef != nil else { throw EzPDFError.invalidInput("No page \(i + 1).") }
            olds.append(page)
        }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw EzPDFError.failed("Couldn't redraw the page.") }
        // The box keys must be CFData of a CGRect; a CGRect value is silently ignored (the page loses its crop).
        func boxData(_ r: CGRect) -> CFData { var r = r; return Data(bytes: &r, count: MemoryLayout<CGRect>.size) as CFData }
        for (k, old) in olds.enumerated() {
            let media = old.bounds(for: .mediaBox), crop = old.bounds(for: .cropBox)
            let space = PageSpace(old)
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: boxData(media), kCGPDFContextCropBox as String: boxData(crop)] as CFDictionary)
            // Text being replaced leaves the page itself, so it can't be selected, searched or
            // edited again under the new words. If the eraser can't read the page, it's painted over.
            let eraseRects = (byPage[indices[k]] ?? []).compactMap { o -> CGRect? in
                if case .erase(let r, _) = o { return space.pageRect(r) } else { return nil }
            }
            var source = old.pageRef!
            if !eraseRects.isEmpty, let erased = TextEraser.erase(source, rects: eraseRects), erased.removed > 0,
               let provider = CGDataProvider(data: erased.data as CFData), let cleaned = CGPDFDocument(provider)?.page(at: 1) {
                source = cleaned
            }
            ctx.drawPDFPage(source)
            // From here on, draw in the shown page's space (bottom-left origin) so overlays come out upright.
            ctx.saveGState()
            ctx.concatenate(space.toPage)
            for o in byPage[indices[k]] ?? [] {
                switch o {
                case .fill(let r, let color), .erase(let r, let color):
                    ctx.setFillColor(color.cgColor)
                    ctx.fill(space.shownRect(r))
                case .image(let img, let r):
                    ctx.interpolationQuality = .high
                    ctx.draw(img, in: space.shownRect(r))
                case .text(let s, let r, let font, let color, let alignment):
                    drawText(s, in: space.shownRect(r), font: font, color: color, alignment: alignment, context: ctx)
                }
            }
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()

        guard let newDoc = PDFDocument(data: data as Data), newDoc.pageCount == olds.count else {
            throw EzPDFError.failed("Couldn't redraw the page.")
        }
        let newPages = (0..<newDoc.pageCount).compactMap { newDoc.page(at: $0) }
        for (k, old) in olds.enumerated() {
            let newPage = newPages[k]
            newPage.rotation = old.rotation
            replacePage(doc, at: indices[k], old: old, with: newPage)
        }
    }

    /// Text in a box (bottom-left space), wrapping by word; grows downward past the box rather than
    /// clipping. Used for page content and for drawing text objects, so both look the same.
    static func drawText(_ s: String, in pr: CGRect, font: NSFont, color: NSColor, alignment: NSTextAlignment, context ctx: CGContext) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byWordWrapping
        let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil,
                                                               CGSize(width: max(1, pr.width), height: .greatestFiniteMagnitude), nil)
        let h = max(pr.height, ceil(fit.height) + 1)
        let path = CGPath(rect: CGRect(x: pr.minX, y: pr.maxY - h, width: max(1, pr.width), height: h), transform: nil)
        ctx.saveGState()
        ctx.textMatrix = .identity
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(), path, nil), ctx)
        ctx.restoreGState()
    }

    /// Swaps in a redrawn page: moves the old page's annotations onto it (`keep` can drop one by
    /// returning nil, or give it new bounds), and re-points everything that referred to the old
    /// page: outline entries and link annotations on any page.
    ///
    /// The page goes into the document first and the annotations are moved, not copied, after:
    /// a form field copied, or added while the page belongs to another document, loses its name.
    static func replacePage(_ doc: PDFDocument, at index: Int, old: PDFPage, with newPage: PDFPage,
                            keep: (PDFAnnotation) -> CGRect? = { $0.bounds }) {
        let annotations = old.annotations
        for a in annotations { old.removeAnnotation(a) }
        doc.removePage(at: index)
        doc.insert(newPage, at: index)
        for a in annotations {
            guard let bounds = keep(a) else { continue }
            a.bounds = bounds
            newPage.addAnnotation(a)
        }
        func moved(_ d: PDFDestination?) -> PDFDestination? {
            guard let d, d.page === old else { return nil }
            let n = PDFDestination(page: newPage, at: d.point)
            n.zoom = d.zoom
            return n
        }
        func fix(_ item: PDFOutline) {
            if let d = moved(item.destination) { item.destination = d }
            if let go = item.action as? PDFActionGoTo, let d = moved(go.destination) { item.action = PDFActionGoTo(destination: d) }
            for i in 0..<item.numberOfChildren { if let c = item.child(at: i) { fix(c) } }
        }
        if let root = doc.outlineRoot { fix(root) }
        for p in 0..<doc.pageCount {
            guard let page = doc.page(at: p) else { continue }
            for a in page.annotations where a.type == "Link" {
                if let d = moved(a.destination) { a.destination = d }
                if let go = a.action as? PDFActionGoTo, let d = moved(go.destination) { a.action = PDFActionGoTo(destination: d) }
            }
        }
    }

    /// The page as it is shown: crop box, after rotation. Converts between top-left "shown" points
    /// (what callers use), the shown page's bottom-left space (for drawing upright), and PDF page space.
    public struct PageSpace {
        /// Page space → shown space (bottom-left origin, size `size`).
        public let toShown: CGAffineTransform
        public let toPage: CGAffineTransform
        /// The shown page's size (width and height swap on 90° and 270° pages).
        public let size: CGSize
        public let rotation: Int

        public init(_ page: PDFPage) {
            toShown = page.transform(for: .cropBox)
            toPage = toShown.inverted()
            let crop = page.bounds(for: .cropBox)
            rotation = ((page.rotation % 360) + 360) % 360
            size = rotation == 90 || rotation == 270 ? CGSize(width: crop.height, height: crop.width) : crop.size
        }

        /// Top-left shown rect → shown bottom-left rect.
        public func shownRect(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height)
        }
        /// Top-left shown rect → PDF page-space rect (annotation bounds).
        public func pageRect(_ r: CGRect) -> CGRect { shownRect(r).applying(toPage) }
        /// PDF page-space rect → top-left shown rect.
        public func topLeft(_ r: CGRect) -> CGRect {
            let d = r.applying(toShown)
            return CGRect(x: d.minX, y: size.height - d.maxY, width: d.width, height: d.height)
        }
        /// Top-left shown point → PDF page-space point.
        public func pagePoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: size.height - p.y).applying(toPage) }
        /// The whole shown page, top-left.
        public var bounds: CGRect { CGRect(origin: .zero, size: size) }
    }

    // MARK: Text

    /// Adds text as page content. `rect` top-left in points; height grows to fit.
    public static func addText(_ doc: PDFDocument, page: Int, text: String, rect: CGRect, fontName: String? = nil,
                               fontSize: CGFloat = 12, color: NSColor = .black, alignment: NSTextAlignment = .left) throws {
        let font = font(named: fontName, size: fontSize)
        try compose(doc, page: page, overlays: [.text(text, rect: rect, font: font, color: color, alignment: alignment)])
    }

    public struct Replacement: Sendable {
        public var page: Int
        public var old: String
        public var new: String
        /// What the edit checks changed or noticed (see EditCheck), for the person or agent to read.
        public var notes: [String] = []
    }

    /// Takes invisible text off these pages (words an earlier version of ezPDF painted over but left in
    /// the text layer; see TextEraser.eraseHidden), so an edit sees only what the page shows. The
    /// pages look exactly the same. Returns how many glyphs went.
    @discardableResult
    static func removeHiddenText(_ doc: PDFDocument, pages: [Int]) -> Int {
        var total = 0
        for i in Set(pages).sorted() {
            guard let old = doc.page(at: i), let ref = old.pageRef, let r = TextEraser.eraseHidden(ref), r.removed > 0,
                  let page = PDFDocument(data: r.data)?.page(at: 0) else { continue }
            page.rotation = old.rotation
            replacePage(doc, at: i, old: old, with: page)
            total += r.removed
        }
        return total
    }

    /// Replaces text where it appears: takes the old words out of the page, then writes the new
    /// text in the same font, size and color, on the same baseline, moving the rest of the line
    /// and paragraph along (see EditCheck). The new words are real text.
    @discardableResult
    public static func replaceText(_ doc: PDFDocument, find: String, with replacement: String, pages: Set<Int>? = nil,
                                   matchCase: Bool = false, wholeWord: Bool = false, limit: Int = 500) throws -> [Replacement] {
        guard !find.isEmpty else { throw EzPDFError.invalidInput("Say what text to replace.") }
        var opts: NSString.CompareOptions = [.diacriticInsensitive]
        if !matchCase { opts.insert(.caseInsensitive) }
        var byPage: [Int: [Overlay]] = [:]
        var done: [Replacement] = []
        var didntFit: [String] = []
        var wordsByPage: [Int: [TextFragment]] = [:]
        var insideWords = 0
        removeHiddenText(doc, pages: doc.findString(find, withOptions: opts).compactMap { $0.pages.first.map(doc.index(for:)) })
        for sel in doc.findString(find, withOptions: opts) {
            // A match that runs onto the next page can't be rewritten in one place: skip it.
            guard done.count < limit, sel.pages.count == 1, let page = sel.pages.first else { continue }
            let index = doc.index(for: page)
            if let pages, !pages.contains(index) { continue }
            if wholeWord, !isWholeWord(sel, in: page) { insideWords += 1; continue }
            let words = wordsByPage[index] ?? PageText.words(page: page, index: index)
            wordsByPage[index] = words
            do {
                let plan = try EditCheck.plan(sel, on: page, replacement: replacement, words: words)
                byPage[index, default: []] += plan.overlays
                done.append(Replacement(page: index + 1, old: sel.string ?? find, new: plan.newWords, notes: plan.notes))
            } catch let e as EditCheck.TooLong {
                didntFit.append("page \(index + 1): \(e.message)")
            }
        }
        guard !done.isEmpty else {
            if !didntFit.isEmpty {
                throw EzPDFError.doesNotFit(didntFit.count == 1 ? String(didntFit[0].drop { $0 != ":" }.dropFirst(2)) : didntFit.prefix(3).joined(separator: " "))
            }
            if insideWords > 0 {
                throw EzPDFError.invalidInput("“\(find)” only appears inside other words or numbers (\(insideWords) place\(insideWords == 1 ? "" : "s")). Give the whole word or number as printed, e.g. “October 14” rather than “14”.")
            }
            throw EzPDFError.invalidInput("“\(find)” doesn't appear\(pages == nil ? "" : " on those pages").")
        }
        try compose(doc, overlays: byPage)
        if !didntFit.isEmpty, var last = done.popLast() {
            last.notes.append("Not changed where it didn't fit: \(didntFit.prefix(3).joined(separator: " "))")
            done.append(last)
        }
        return done
    }

    /// Where to write replacement text: on the old first line's baseline, as wide as the text
    /// needs (at least `minWidth`), wrapping downward rather than running off the page.
    static func textBox(for text: String, font: NSFont, firstLine first: CGRect, minWidth: CGFloat, page: CGRect) -> CGRect {
        // CoreText draws from the top of the box; place it so the baseline lands where the old one was.
        let baselineFromTop = first.height - abs(font.descender)
        let natural = (text as NSString).size(withAttributes: [.font: font]).width + 2
        let room = max(8, page.maxX - first.minX - 8)
        let width = min(max(natural, minWidth, 8), max(room, min(minWidth, page.width)))
        return CGRect(x: first.minX, y: first.minY + baselineFromTop - font.ascender, width: width,
                      height: font.ascender - font.descender + 2)
    }

    /// What a reader selection is: its words, page, line boxes (top-left points) and style.
    public struct SelectionInfo: Sendable {
        public var text: String
        public var page: Int            // 0-based
        public var lines: [CGRect]
        public var fontName: String
        public var fontSize: CGFloat
        public var colorHex: String
    }

    public static func selectionInfo(_ sel: PDFSelection, in doc: PDFDocument) -> SelectionInfo? {
        guard let page = sel.pages.first else { return nil }
        let space = PageSpace(page)
        let lines = sel.selectionsByLine().filter { $0.pages.first == page }.map { space.topLeft($0.bounds(for: page)) }.filter { !$0.isEmpty }
        let text = (sel.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lines.isEmpty, !text.isEmpty else { return nil }
        let style = textStyle(of: sel)
        return SelectionInfo(text: text, page: doc.index(for: page), lines: lines, fontName: style.font.fontName,
                             fontSize: style.font.pointSize, colorHex: Objects.hex(style.color))
    }

    /// Replaces exactly what was selected: each line is painted over in its background color and
    /// the new text is written from the first line's baseline in the same font, wrapping inside the
    /// selection's width. Nothing is searched, so it works whatever the selection contains.
    /// Replaces a selection made in the reader, set like any text edit (see EditCheck): same type,
    /// the rest of the line and paragraph moved along as needed. Returns the edit checks' notes.
    @discardableResult
    public static func replaceRegion(_ doc: PDFDocument, page index: Int, lines: [CGRect], text: String,
                                     font: NSFont, color: NSColor) throws -> [String] {
        guard doc.page(at: index) != nil, let first = lines.first, let last = lines.last else { throw EzPDFError.invalidInput("Nothing selected.") }
        removeHiddenText(doc, pages: [index])
        guard let page = doc.page(at: index) else { throw EzPDFError.invalidInput("Nothing selected.") }
        let space = PageSpace(page)
        // The same selection again: one line by its area (what's drawn there, whatever order the text
        // layer lists it in); several lines from the start of the first box to the end of the last.
        let again = lines.count == 1
            ? page.selection(for: space.pageRect(first.insetBy(dx: 0.5, dy: first.height * 0.2)))
            : page.selection(from: space.pagePoint(CGPoint(x: first.minX + 0.5, y: first.midY)),
                             to: space.pagePoint(CGPoint(x: last.maxX - 0.5, y: last.midY)))
        guard let sel = again, !(sel.string ?? "").trimmingCharacters(in: .whitespaces).isEmpty else {
            throw EzPDFError.invalidInput("That selection has no text in it anymore; select it again.")
        }
        do {
            let plan = try EditCheck.plan(sel, on: page, replacement: text, words: PageText.words(page: page, index: index))
            try compose(doc, page: index, overlays: plan.overlays)
            return plan.notes
        } catch let e as EditCheck.TooLong {
            throw EzPDFError.doesNotFit(e.message)
        }
    }

    // MARK: Images and signatures

    /// A typed signature in a handwriting-style font, as an image-free vector text overlay.
    public static func addTypedSignature(_ doc: PDFDocument, page: Int, name: String, rect: CGRect, color: NSColor = NSColor(red: 0.05, green: 0.1, blue: 0.35, alpha: 1)) throws {
        let candidates = ["SignPainter-HouseScript", "Snell Roundhand", "Savoye LET", "Bradley Hand"]
        let face = candidates.lazy.compactMap { NSFont(name: $0, size: 10) }.first ?? .systemFont(ofSize: 10)
        let size = min(rect.height * 0.8, fittingSize(face, text: name, width: rect.width))
        try compose(doc, page: page, overlays: [.text(name, rect: rect, font: face.withSize(max(8, size)), color: color, alignment: .left)])
    }

    // MARK: Annotations

    public enum Shape: String, Codable, Sendable, CaseIterable { case rectangle, ellipse, line, arrow }

    public static func addShape(_ doc: PDFDocument, page index: Int, shape: Shape, rect: CGRect, color: NSColor = .systemRed, lineWidth: CGFloat = 2) throws {
        guard let page = doc.page(at: index) else { throw EzPDFError.invalidInput("No page \(index + 1).") }
        let space = PageSpace(page)
        let r = space.pageRect(rect)
        let border = PDFBorder(); border.lineWidth = lineWidth
        let a: PDFAnnotation
        switch shape {
        case .rectangle: a = PDFAnnotation(bounds: r, forType: .square, withProperties: nil)
        case .ellipse: a = PDFAnnotation(bounds: r, forType: .circle, withProperties: nil)
        case .line, .arrow:
            a = PDFAnnotation(bounds: r.insetBy(dx: -lineWidth * 4, dy: -lineWidth * 4), forType: .line, withProperties: nil)
            // From the shown top-left corner to the shown bottom-right one, whatever the rotation.
            let start = space.pagePoint(CGPoint(x: rect.minX, y: rect.minY)), end = space.pagePoint(CGPoint(x: rect.maxX, y: rect.maxY))
            a.startPoint = CGPoint(x: start.x - a.bounds.minX, y: start.y - a.bounds.minY)
            a.endPoint = CGPoint(x: end.x - a.bounds.minX, y: end.y - a.bounds.minY)
            if shape == .arrow { a.endLineStyle = .openArrow }
        }
        a.color = color
        a.border = border
        page.addAnnotation(a)
    }

    /// Freehand ink from strokes given in top-left page points.
    public static func addInk(_ doc: PDFDocument, page index: Int, strokes: [[CGPoint]], color: NSColor = .systemBlue, lineWidth: CGFloat = 2) throws {
        guard let page = doc.page(at: index), !strokes.isEmpty else { throw EzPDFError.invalidInput("No page \(index + 1).") }
        let space = PageSpace(page)
        let pts = strokes.flatMap { $0 }.map(space.pagePoint)
        guard let minX = pts.map(\.x).min(), let maxX = pts.map(\.x).max(), let minY = pts.map(\.y).min(), let maxY = pts.map(\.y).max() else { return }
        let bounds = CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY)).insetBy(dx: -lineWidth * 2, dy: -lineWidth * 2)
        let a = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        for stroke in strokes {
            let path = NSBezierPath()
            for (i, p) in stroke.enumerated() {
                let pp = space.pagePoint(p)
                let q = CGPoint(x: pp.x - bounds.minX, y: pp.y - bounds.minY)
                if i == 0 { path.move(to: q) } else { path.line(to: q) }
            }
            a.add(path)
        }
        a.color = color
        let border = PDFBorder(); border.lineWidth = lineWidth
        a.border = border
        page.addAnnotation(a)
    }

    public struct AnnotationInfo: Codable, Sendable {
        public var page: Int, index: Int, type: String, text: String?, rect: [Double]
    }

    public static func listAnnotations(_ doc: PDFDocument) -> [AnnotationInfo] {
        var out: [AnnotationInfo] = []
        for p in 0..<doc.pageCount {
            guard let page = doc.page(at: p) else { continue }
            let space = PageSpace(page)
            for (i, a) in page.annotations.enumerated() where a.type != "Widget" && a.type != "Link" && a.type != "Popup" {
                let r = space.topLeft(a.bounds)
                out.append(AnnotationInfo(page: p + 1, index: i, type: a.type ?? "Annotation", text: a.contents,
                                          rect: [r.minX, r.minY, r.width, r.height].map { Double($0) }))
            }
        }
        return out
    }

    /// Removes annotations: all of the given types (e.g. "Highlight"), or all non-form ones.
    @discardableResult
    public static func removeAnnotations(_ doc: PDFDocument, pages: Set<Int>?, types: Set<String>?) -> Int {
        var n = 0
        for p in 0..<doc.pageCount {
            if let pages, !pages.contains(p) { continue }
            guard let page = doc.page(at: p) else { continue }
            for a in page.annotations where a.type != "Widget" && a.type != "Link" {
                if let types, !types.contains(where: { $0.caseInsensitiveCompare(a.type ?? "") == .orderedSame }) { continue }
                page.removeAnnotation(a); n += 1
            }
        }
        return n
    }

    // MARK: Forms

    public struct FormField: Codable, Sendable {
        public var name: String, type: String, value: String, options: [String]?, page: Int
    }

    public static func formFields(_ doc: PDFDocument) -> [FormField] {
        var out: [FormField] = []
        var seen = Set<String>()
        for p in 0..<doc.pageCount {
            guard let page = doc.page(at: p) else { continue }
            for a in page.annotations where a.type == "Widget" {
                let name = a.fieldName ?? ""
                guard !name.isEmpty, seen.insert(name + "#\(a.widgetFieldType.rawValue)").inserted || a.widgetFieldType == .button else { continue }
                switch a.widgetFieldType {
                case .text: out.append(FormField(name: name, type: "text", value: a.widgetStringValue ?? "", options: nil, page: p + 1))
                case .choice: out.append(FormField(name: name, type: "choice", value: a.widgetStringValue ?? "", options: a.choices, page: p + 1))
                case .button:
                    if a.widgetControlType == .checkBoxControl || a.widgetControlType == .radioButtonControl {
                        let on = a.buttonWidgetState == .onState
                        out.append(FormField(name: name, type: a.widgetControlType == .checkBoxControl ? "checkbox" : "radio",
                                             value: on ? (a.buttonWidgetStateString.isEmpty ? "on" : a.buttonWidgetStateString) : "off",
                                             options: nil, page: p + 1))
                    }
                case .signature: out.append(FormField(name: name, type: "signature", value: "", options: nil, page: p + 1))
                default: break
                }
            }
        }
        return out
    }

    /// Sets form values by field name. Checkboxes take true/false/on/off; radios take the option
    /// name. Returns the names that were set.
    @discardableResult
    public static func fillForm(_ doc: PDFDocument, values: [String: String]) throws -> [String] {
        var set: [String] = []
        for p in 0..<doc.pageCount {
            guard let page = doc.page(at: p) else { continue }
            for a in page.annotations where a.type == "Widget" {
                guard let name = a.fieldName, let v = values[name] else { continue }
                switch a.widgetFieldType {
                case .text, .choice:
                    a.widgetStringValue = v
                case .button where a.widgetControlType == .checkBoxControl:
                    let on = ["true", "yes", "on", "1", "x", "checked"].contains(v.lowercased())
                    a.buttonWidgetState = on ? .onState : .offState
                case .button where a.widgetControlType == .radioButtonControl:
                    a.buttonWidgetState = a.buttonWidgetStateString.caseInsensitiveCompare(v) == .orderedSame ? .onState : .offState
                default: continue
                }
                if !set.contains(name) { set.append(name) }
            }
        }
        if set.isEmpty { throw EzPDFError.invalidInput("No form fields named \(values.keys.sorted().joined(separator: ", ")).") }
        return set
    }

    /// Burns annotations and form values into page content, so every viewer shows the same thing
    /// and nothing can be edited further.
    public static func flatten(_ doc: PDFDocument) -> Data? {
        doc.dataRepresentation(options: [PDFDocumentWriteOption.burnInAnnotationsOption: true])
    }

    // MARK: Redaction

    /// Real redaction: the page is rendered to an image with the areas blacked out and replaces
    /// the original, so nothing under the boxes survives (text, images, hidden layers). The rest of
    /// the page's text is restored as searchable OCR text when the document is saved. `rects` are
    /// top-left points of the page as shown. Annotations clear of the boxes are kept; any that
    /// touch a box (form values, notes, placed objects) are dropped with what they covered.
    public static func redact(_ doc: PDFDocument, page index: Int, rects: [CGRect], scale: CGFloat = 3) throws {
        guard let page = doc.page(at: index) else { throw EzPDFError.invalidInput("No page \(index + 1).") }
        let crop = page.bounds(for: .cropBox)
        let space = PageSpace(page)
        let pageBoxes = rects.map { space.pageRect($0).insetBy(dx: -1, dy: -1) }
        // Render unrotated (the boxes are in unrotated page space); the new page keeps the rotation.
        let rotation = page.rotation
        page.rotation = 0
        let rendered = PDFRaster.cgImage(page, scale: scale)
        page.rotation = rotation
        guard let cg = rendered else { throw EzPDFError.failed("Couldn't render the page.") }
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw EzPDFError.failed("Couldn't render the page.")
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(NSColor.black.cgColor)
        // The render is the unrotated crop box with its origin at (0, 0).
        let sx = CGFloat(w) / crop.width, sy = CGFloat(h) / crop.height
        for b in pageBoxes {
            ctx.fill(CGRect(x: (b.minX - crop.minX) * sx, y: (b.minY - crop.minY) * sy, width: b.width * sx, height: b.height * sy))
        }
        guard let redacted = ctx.makeImage() else { throw EzPDFError.failed("Couldn't render the page.") }
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: crop.size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let pctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw EzPDFError.failed("Couldn't redraw the page.") }
        pctx.beginPDFPage(nil)
        pctx.interpolationQuality = .high
        pctx.draw(redacted, in: box)
        pctx.endPDFPage()
        pctx.closePDF()
        guard let newDoc = PDFDocument(data: data as Data), let newPage = newDoc.page(at: 0) else { throw EzPDFError.failed("Couldn't redraw the page.") }
        newPage.rotation = rotation
        // Annotations touching a box go with what they covered. The new page's space starts at
        // (0, 0); the old crop box's origin may not.
        replacePage(doc, at: index, old: page, with: newPage) { a in
            pageBoxes.contains { $0.intersects(a.bounds) } ? nil : a.bounds.offsetBy(dx: -crop.minX, dy: -crop.minY)
        }
    }

    /// Finds every occurrence of `text` and returns its boxes per page (top-left points), for redaction.
    public static func rects(of text: String, in doc: PDFDocument, pages: Set<Int>?) -> [Int: [CGRect]] {
        var out: [Int: [CGRect]] = [:]
        for sel in doc.findString(text, withOptions: [.caseInsensitive, .diacriticInsensitive]) {
            for line in sel.selectionsByLine() {
                guard let page = line.pages.first else { continue }
                let i = doc.index(for: page)
                if let pages, !pages.contains(i) { continue }
                out[i, default: []].append(PageSpace(page).topLeft(line.bounds(for: page)))
            }
        }
        return out
    }

    // MARK: Metadata

    public static func setMetadata(_ doc: PDFDocument, title: String?, author: String?, subject: String?, keywords: [String]?) {
        var attrs = doc.documentAttributes ?? [:]
        if let title { attrs[PDFDocumentAttribute.titleAttribute] = title }
        if let author { attrs[PDFDocumentAttribute.authorAttribute] = author }
        if let subject { attrs[PDFDocumentAttribute.subjectAttribute] = subject }
        if let keywords { attrs[PDFDocumentAttribute.keywordsAttribute] = keywords }
        doc.documentAttributes = attrs
    }

    // MARK: Helpers

    struct TextStyle {
        var font: NSFont
        var color: NSColor
        /// The document's font name when it isn't on this Mac and `font` stands in for it.
        var substitutedFor: String? = nil
    }

    /// Font and color of the first character of a selection, as PDFKit reports them.
    static func textStyle(of sel: PDFSelection) -> TextStyle {
        guard let attr = sel.attributedString, attr.length > 0 else { return TextStyle(font: .systemFont(ofSize: 11), color: .black) }
        let a = attr.attributes(at: 0, effectiveRange: nil)
        let font = (a[.font] as? NSFont) ?? .systemFont(ofSize: 11)
        let color = (a[.foregroundColor] as? NSColor) ?? .black
        // The document's own font: installed, taken from the PDF, or fetched (see Fonts.prepare).
        // PDFKit names a stand-in when the font isn't here, so ask the page which font it really uses.
        let name = sel.pages.first.map { Fonts.documentFontName(reported: font.fontName, page: $0) } ?? Fonts.baseName(font.fontName)
        if let installed = Fonts.installed(name, size: font.pointSize) {
            return TextStyle(font: installed, color: color.usingColorSpace(.sRGB) ?? color)
        }
        // Not on this Mac: a close system face, and say so.
        let close = closestSystemFont(to: name, size: font.pointSize, bold: font.fontDescriptor.symbolicTraits.contains(.bold))
        return TextStyle(font: close, color: color.usingColorSpace(.sRGB) ?? color, substitutedFor: name)
    }

    static func closestSystemFont(to name: String, size: CGFloat, bold: Bool) -> NSFont {
        let n = name.lowercased()
        let serif = ["times", "georgia", "garamond", "serif", "minion", "cambria", "palatino", "book"].contains { n.contains($0) }
        let mono = ["courier", "mono", "consolas", "menlo"].contains { n.contains($0) }
        let isBold = bold || n.contains("bold") || n.contains("black") || n.contains("heavy")
        if mono { return NSFont.monospacedSystemFont(ofSize: size, weight: isBold ? .bold : .regular) }
        if serif {
            let base = NSFont(name: isBold ? "Times New Roman Bold" : "Times New Roman", size: size) ?? NSFont(name: "Times", size: size)
            if let base { return base }
        }
        return NSFont.systemFont(ofSize: size, weight: isBold ? .bold : .regular)
    }

    static func font(named name: String?, size: CGFloat) -> NSFont {
        let s = max(4, min(size, 400))
        if let name, let f = NSFont(name: name, size: s) { return f }
        if let name { return closestSystemFont(to: name, size: s, bold: false) }
        return .systemFont(ofSize: s)
    }

    static func fittingSize(_ font: NSFont, text: String, width: CGFloat) -> CGFloat {
        let w = (text as NSString).size(withAttributes: [.font: font.withSize(100)]).width
        return w > 0 ? 100 * width / w : font.pointSize
    }

    static func fit(_ img: CGImage, in rect: CGRect) -> CGRect {
        let s = min(rect.width / CGFloat(img.width), rect.height / CGFloat(img.height))
        let w = CGFloat(img.width) * s, h = CGFloat(img.height) * s
        return CGRect(x: rect.minX + (rect.width - w) / 2, y: rect.minY + (rect.height - h) / 2, width: w, height: h)
    }

    /// True when the match isn't part of a longer word: the character before it and the one after
    /// it (each looked at on its own, so "ll" in "lll" is judged right) aren't letters or digits.
    /// The words in a selection made by area (a pen mark, a drawn box), without the pieces of
    /// words cut at its edges: a loop around "October 14" that clips "date:" and "by" gives
    /// "October 14, 2026," rather than "e: October 14, 2026, b". Whitespace is collapsed.
    public static func wholeWords(_ sel: PDFSelection) -> String {
        let raw = (sel.string ?? "").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        var words = raw.split(separator: " ").map(String.init)
        guard words.count > 1 else { return raw }
        let letters = CharacterSet.alphanumerics
        func continues(atStart: Bool) -> Bool {
            guard let wider = sel.copy() as? PDFSelection else { return false }
            if atStart { wider.extend(atStart: 1) } else { wider.extend(atEnd: 1) }
            let s = (wider.string ?? "")
            guard s.count > (sel.string ?? "").count, let c = (atStart ? s.first : s.last)?.unicodeScalars.first else { return false }
            if wider.selectionsByLine().count > sel.selectionsByLine().count { return false }   // another line
            return letters.contains(c)
        }
        if let first = words.first?.unicodeScalars.first, letters.contains(first), continues(atStart: true) { words.removeFirst() }
        if words.count > 1, let last = words.last?.unicodeScalars.last, letters.contains(last), continues(atStart: false) { words.removeLast() }
        return words.joined(separator: " ")
    }

    static func isWholeWord(_ sel: PDFSelection, in page: PDFPage) -> Bool {
        let inner = sel.string ?? ""
        let letters = CharacterSet.alphanumerics
        func neighbor(atStart: Bool) -> Unicode.Scalar? {
            guard let wider = sel.copy() as? PDFSelection else { return nil }
            if atStart { wider.extend(atStart: 1) } else { wider.extend(atEnd: 1) }
            let s = wider.string ?? ""
            guard s.count > inner.count else { return nil }      // at the start or end of the page
            // The character is on another line: the word ends with its line.
            if wider.selectionsByLine().count > sel.selectionsByLine().count { return nil }
            return (atStart ? s.first : s.last)?.unicodeScalars.first
        }
        let before = neighbor(atStart: true), after = neighbor(atStart: false)
        return before.map { !letters.contains($0) } ?? true && after.map { !letters.contains($0) } ?? true
    }

    /// The most common color in a thin ring around `bounds` on the rendered page: what to paint
    /// over old text so the cover blends in (white paper, tinted table cells, dark slides).
    static func backgroundColor(_ page: PDFPage, around bounds: CGRect) -> NSColor? {
        let crop = page.bounds(for: .cropBox)
        let ring = bounds.insetBy(dx: -3, dy: -3).intersection(crop)
        guard !ring.isNull, ring.width > 2, ring.height > 2 else { return nil }
        let scale: CGFloat = 2
        let w = Int(ring.width * scale), h = Int(ring.height * scale)
        guard w > 0, h > 0, w * h < 4_000_000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        // The page's own content in page space (no crop shift, no rotation), so the ring lines up.
        ctx.translateBy(x: -ring.minX, y: -ring.minY)
        guard let ref = page.pageRef else { return nil }
        ctx.drawPDFPage(ref)
        guard let px = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        // Bucket by coarse color, then average the real pixels in the winning bucket (rounding
        // to the bucket would leave a visibly darker patch on white paper).
        var counts: [UInt32: (n: Int, r: Int, g: Int, b: Int)] = [:]
        let edge = 3
        for y in 0..<h { for x in 0..<w where x < edge || x >= w - edge || y < edge || y >= h - edge {
            let i = (y * w + x) * 4
            let key = UInt32(px[i] & 0xF0) << 16 | UInt32(px[i + 1] & 0xF0) << 8 | UInt32(px[i + 2] & 0xF0)
            var c = counts[key] ?? (0, 0, 0, 0)
            c.n += 1; c.r += Int(px[i]); c.g += Int(px[i + 1]); c.b += Int(px[i + 2])
            counts[key] = c
        }}
        guard let best = counts.values.max(by: { $0.n < $1.n }), best.n > 0 else { return nil }
        return NSColor(srgbRed: CGFloat(best.r) / CGFloat(best.n) / 255, green: CGFloat(best.g) / CGFloat(best.n) / 255,
                       blue: CGFloat(best.b) / CGFloat(best.n) / 255, alpha: 1)
    }
}
