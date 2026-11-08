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
/// Coordinates: callers give page-space points with the origin at the TOP-left of the page's crop
/// box (what people expect); conversion to PDF space happens here.
public enum EditOps {
    // MARK: Overlays drawn into page content

    public enum Overlay {
        case text(String, rect: CGRect, font: NSFont, color: NSColor, alignment: NSTextAlignment)
        case image(CGImage, rect: CGRect)
        case fill(CGRect, NSColor)
    }

    /// Redraws `index` with overlays on top. Annotations on the page are kept.
    public static func compose(_ doc: PDFDocument, page index: Int, overlays: [Overlay]) throws {
        guard let old = doc.page(at: index), let cg = old.pageRef else { throw EzPDFError.invalidInput("No page \(index + 1).") }
        let media = old.bounds(for: .mediaBox)
        let crop = old.bounds(for: .cropBox)
        let rotation = old.rotation

        let data = NSMutableData()
        var box = media
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw EzPDFError.failed("Couldn't redraw the page.") }
        ctx.beginPDFPage([kCGPDFContextMediaBox as String: media, kCGPDFContextCropBox as String: crop] as CFDictionary)
        ctx.drawPDFPage(cg)
        let g = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        for o in overlays {
            switch o {
            case .fill(let r, let color):
                ctx.setFillColor(color.cgColor)
                ctx.fill(pdfRect(r, crop: crop))
            case .image(let img, let r):
                ctx.interpolationQuality = .high
                ctx.draw(img, in: pdfRect(r, crop: crop))
            case .text(let s, let r, let font, let color, let alignment):
                let style = NSMutableParagraphStyle()
                style.alignment = alignment
                style.lineBreakMode = .byWordWrapping
                let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
                let pr = pdfRect(r, crop: crop)
                let framesetter = CTFramesetterCreateWithAttributedString(attr)
                // Grow downward if the text needs more room than the box gives.
                let fit = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil,
                                                                       CGSize(width: pr.width, height: .greatestFiniteMagnitude), nil)
                let h = max(pr.height, ceil(fit.height) + 1)
                let path = CGPath(rect: CGRect(x: pr.minX, y: pr.maxY - h, width: pr.width, height: h), transform: nil)
                CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(), path, nil), ctx)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()

        guard let newDoc = PDFDocument(data: data as Data), let newPage = newDoc.page(at: 0) else {
            throw EzPDFError.failed("Couldn't redraw the page.")
        }
        newPage.rotation = rotation
        for a in old.annotations { if let c = a.copy() as? PDFAnnotation { newPage.addAnnotation(c) } }
        doc.removePage(at: index)
        doc.insert(newPage, at: index)
    }

    /// Top-left page coordinates → PDF space (bottom-left origin) inside the crop box.
    static func pdfRect(_ r: CGRect, crop: CGRect) -> CGRect {
        CGRect(x: crop.minX + r.minX, y: crop.maxY - r.maxY, width: r.width, height: r.height)
    }

    static func topLeftRect(_ r: CGRect, crop: CGRect) -> CGRect {
        CGRect(x: r.minX - crop.minX, y: crop.maxY - r.maxY, width: r.width, height: r.height)
    }

    // MARK: Text

    /// Adds text as page content. `rect` top-left in points; height grows to fit.
    public static func addText(_ doc: PDFDocument, page: Int, text: String, rect: CGRect, fontName: String? = nil,
                               fontSize: CGFloat = 12, color: NSColor = .black, alignment: NSTextAlignment = .left) throws {
        let font = font(named: fontName, size: fontSize)
        try compose(doc, page: page, overlays: [.text(text, rect: rect, font: font, color: color, alignment: alignment)])
    }

    public struct Replacement: Sendable { public var page: Int; public var old: String; public var new: String }

    /// Replaces text where it appears: covers each match with the background color sampled around
    /// it, then writes the new text in the same font, size and color, on the same baseline.
    /// When `removeOriginal` is on and the content can be edited, the old glyphs are also taken out
    /// of the page so copy and search find only the new text (ContentEditor).
    @discardableResult
    public static func replaceText(_ doc: PDFDocument, find: String, with replacement: String, pages: Set<Int>? = nil,
                                   matchCase: Bool = false, wholeWord: Bool = false, limit: Int = 500,
                                   removeOriginal: Bool = true) throws -> [Replacement] {
        guard !find.isEmpty else { throw EzPDFError.invalidInput("Say what text to replace.") }
        var opts: NSString.CompareOptions = [.diacriticInsensitive]
        if !matchCase { opts.insert(.caseInsensitive) }
        var byPage: [Int: [Overlay]] = [:]
        var removals: [Int: [CGRect]] = [:]
        var done: [Replacement] = []
        for sel in doc.findString(find, withOptions: opts) {
            guard done.count < limit, let page = sel.pages.first else { continue }
            let index = doc.index(for: page)
            if let pages, !pages.contains(index) { continue }
            if wholeWord, !isWholeWord(sel, in: page) { continue }
            let crop = page.bounds(for: .cropBox)
            let bounds = sel.bounds(for: page)
            guard !bounds.isEmpty else { continue }
            let style = textStyle(of: sel)
            let bg = backgroundColor(page, around: bounds) ?? .white
            // Cover a hair larger than the glyph box so antialiased edges don't peek out.
            let cover = topLeftRect(bounds.insetBy(dx: -1, dy: -1), crop: crop)
            let newFont = fitted(style.font, text: replacement, width: nil)
            // Same baseline: CoreText draws from the top of the box; place the box so the
            // baseline lands where the old one was.
            let baselineFromTop = bounds.height - abs(style.font.descender)
            let textWidth = (replacement as NSString).size(withAttributes: [.font: newFont]).width + 2
            var textRect = topLeftRect(bounds, crop: crop)
            textRect.size.width = max(textWidth, 4)
            textRect.origin.y += baselineFromTop - newFont.ascender
            textRect.size.height = newFont.ascender - newFont.descender + 2
            byPage[index, default: []].append(.fill(cover, bg))
            if !replacement.isEmpty {
                byPage[index, default: []].append(.text(replacement, rect: textRect, font: newFont, color: style.color, alignment: .left))
            }
            removals[index, default: []].append(bounds)
            done.append(Replacement(page: index + 1, old: sel.string ?? find, new: replacement))
        }
        guard !done.isEmpty else { throw EzPDFError.invalidInput("“\(find)” doesn't appear\(pages == nil ? "" : " on those pages").") }
        if removeOriginal {
            for (index, rects) in removals { try? removeText(doc, page: index, in: rects) }
        }
        for (index, overlays) in byPage { try compose(doc, page: index, overlays: overlays) }
        return done
    }

    /// Removes the text drawn inside `rects` from a page's content, keeping everything else
    /// vector. Implemented by rewriting the page's text-showing operators (see ContentEditor).
    public static func removeText(_ doc: PDFDocument, page index: Int, in rects: [CGRect]) throws {
        guard let page = doc.page(at: index) else { return }
        try ContentEditor.removeText(from: page, in: doc, pageIndex: index, rects: rects)
    }

    // MARK: Images and signatures

    public static func addImage(_ doc: PDFDocument, page: Int, imageData: Data, rect: CGRect) throws {
        guard let src = CGImageSourceCreateWithData(imageData as CFData, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                                                     kCGImageSourceThumbnailMaxPixelSize: 4000] as CFDictionary) else {
            throw EzPDFError.invalidInput("That image couldn't be read.")
        }
        try compose(doc, page: page, overlays: [.image(img, rect: fit(img, in: rect))])
    }

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
        let crop = page.bounds(for: .cropBox)
        let r = pdfRect(rect, crop: crop)
        let border = PDFBorder(); border.lineWidth = lineWidth
        let a: PDFAnnotation
        switch shape {
        case .rectangle: a = PDFAnnotation(bounds: r, forType: .square, withProperties: nil)
        case .ellipse: a = PDFAnnotation(bounds: r, forType: .circle, withProperties: nil)
        case .line, .arrow:
            a = PDFAnnotation(bounds: r.insetBy(dx: -lineWidth * 4, dy: -lineWidth * 4), forType: .line, withProperties: nil)
            a.startPoint = CGPoint(x: r.minX - a.bounds.minX, y: r.maxY - a.bounds.minY)
            a.endPoint = CGPoint(x: r.maxX - a.bounds.minX, y: r.minY - a.bounds.minY)
            if shape == .arrow { a.endLineStyle = .openArrow }
        }
        a.color = color
        a.border = border
        page.addAnnotation(a)
    }

    /// Freehand ink from strokes given in top-left page points.
    public static func addInk(_ doc: PDFDocument, page index: Int, strokes: [[CGPoint]], color: NSColor = .systemBlue, lineWidth: CGFloat = 2) throws {
        guard let page = doc.page(at: index), !strokes.isEmpty else { throw EzPDFError.invalidInput("No page \(index + 1).") }
        let crop = page.bounds(for: .cropBox)
        let pts = strokes.flatMap { $0 }.map { CGPoint(x: crop.minX + $0.x, y: crop.maxY - $0.y) }
        guard let minX = pts.map(\.x).min(), let maxX = pts.map(\.x).max(), let minY = pts.map(\.y).min(), let maxY = pts.map(\.y).max() else { return }
        let bounds = CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY)).insetBy(dx: -lineWidth * 2, dy: -lineWidth * 2)
        let a = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        for stroke in strokes {
            let path = NSBezierPath()
            for (i, p) in stroke.enumerated() {
                let q = CGPoint(x: crop.minX + p.x - bounds.minX, y: crop.maxY - p.y - bounds.minY)
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
            let crop = page.bounds(for: .cropBox)
            for (i, a) in page.annotations.enumerated() where a.type != "Widget" && a.type != "Link" && a.type != "Popup" {
                let r = topLeftRect(a.bounds, crop: crop)
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
        let missing = Set(values.keys).subtracting(set)
        if set.isEmpty { throw EzPDFError.invalidInput("No form fields named \(values.keys.sorted().joined(separator: ", ")).") }
        if !missing.isEmpty { set.append(contentsOf: []) }
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
    /// the page's text is restored as searchable OCR text when the document is saved.
    public static func redact(_ doc: PDFDocument, page index: Int, rects: [CGRect], scale: CGFloat = 3) throws {
        guard let page = doc.page(at: index) else { throw EzPDFError.invalidInput("No page \(index + 1).") }
        let crop = page.bounds(for: .cropBox)
        guard let cg = PDFRaster.cgImage(page, scale: scale) else { throw EzPDFError.failed("Couldn't render the page.") }
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw EzPDFError.failed("Couldn't render the page.")
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(NSColor.black.cgColor)
        let sx = CGFloat(w) / crop.width, sy = CGFloat(h) / crop.height
        for r in rects {
            // rects are top-left page points
            ctx.fill(CGRect(x: r.minX * sx, y: (crop.height - r.maxY) * sy, width: r.width * sx, height: r.height * sy).insetBy(dx: -1, dy: -1))
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
        newPage.rotation = page.rotation
        doc.removePage(at: index)
        doc.insert(newPage, at: index)
    }

    /// Finds every occurrence of `text` and returns its boxes per page (top-left points), for redaction.
    public static func rects(of text: String, in doc: PDFDocument, pages: Set<Int>?) -> [Int: [CGRect]] {
        var out: [Int: [CGRect]] = [:]
        for sel in doc.findString(text, withOptions: [.caseInsensitive, .diacriticInsensitive]) {
            for line in sel.selectionsByLine() {
                guard let page = line.pages.first else { continue }
                let i = doc.index(for: page)
                if let pages, !pages.contains(i) { continue }
                out[i, default: []].append(topLeftRect(line.bounds(for: page), crop: page.bounds(for: .cropBox)))
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

    struct TextStyle { var font: NSFont; var color: NSColor }

    /// Font and color of the first character of a selection, as PDFKit reports them.
    static func textStyle(of sel: PDFSelection) -> TextStyle {
        guard let attr = sel.attributedString, attr.length > 0 else { return TextStyle(font: .systemFont(ofSize: 11), color: .black) }
        let a = attr.attributes(at: 0, effectiveRange: nil)
        let font = (a[.font] as? NSFont) ?? .systemFont(ofSize: 11)
        let color = (a[.foregroundColor] as? NSColor) ?? .black
        // PDF-embedded subset fonts often aren't installed; fall back to a close system face.
        let usable = NSFont(name: font.fontName, size: font.pointSize)
            ?? closestSystemFont(to: font.fontName, size: font.pointSize, bold: font.fontDescriptor.symbolicTraits.contains(.bold))
        return TextStyle(font: usable, color: color.usingColorSpace(.sRGB) ?? color)
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

    static func fitted(_ font: NSFont, text: String, width: CGFloat?) -> NSFont {
        guard let width else { return font }
        return font.withSize(min(font.pointSize, fittingSize(font, text: text, width: width)))
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

    static func isWholeWord(_ sel: PDFSelection, in page: PDFPage) -> Bool {
        guard let wider = sel.copy() as? PDFSelection else { return true }
        wider.extend(atStart: 1); wider.extend(atEnd: 1)
        let s = wider.string ?? "", inner = sel.string ?? ""
        guard s.count > inner.count else { return true }
        let before = s.prefix(1).unicodeScalars.first, after = s.suffix(1).unicodeScalars.first
        let letters = CharacterSet.alphanumerics
        let startOK = s.hasPrefix(inner) || before.map { !letters.contains($0) } ?? true
        let endOK = s.hasSuffix(inner) || after.map { !letters.contains($0) } ?? true
        return startOK && endOK
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
        ctx.translateBy(x: -ring.minX, y: -ring.minY)
        page.draw(with: .cropBox, to: ctx)
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
