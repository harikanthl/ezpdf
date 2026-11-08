import Foundation
import AppKit
import PDFKit
import ImageIO

/// Editable objects placed on pages: text boxes, signatures, images and logos, boxes. They're PDF
/// annotations tagged with an ezpdf id, so the reader can select, move, resize, edit and delete
/// them. Images are kept next to the document (PDFKit can't save a custom drawing) and drawn by
/// `ImageStampAnnotation`. When a document leaves ezpdf, `deliverable` burns everything into the
/// pages so every viewer shows the same thing.
public enum Objects {
    public static let marker = "ezpdf-object:"
    static let imageKey = "ezpdf-image:"

    public enum Kind: String, Codable, Sendable { case text, signature, image, shape }

    public struct Info: Codable, Sendable, Identifiable {
        public var id: String
        public var kind: Kind
        public var page: Int            // 1-based
        public var rect: [Double]       // x, y, width, height; top-left page points
        public var text: String?
        public var fontName: String?
        public var fontSize: Double?
        public var color: String?
    }

    public static func objectID(_ a: PDFAnnotation) -> String? {
        guard let u = a.userName, u.hasPrefix(marker) else { return nil }
        return String(u.dropFirst(marker.count))
    }

    static func kind(_ a: PDFAnnotation) -> Kind {
        if a is ImageStampAnnotation || (a.contents ?? "").hasPrefix(imageKey) { return .image }
        if a.type == "FreeText" { return isSignatureFont(a.font) ? .signature : .text }
        return .shape
    }

    static let signatureFonts = ["SignPainter-HouseScript", "Snell Roundhand", "SnellRoundhand", "Savoye LET", "SavoyeLetPlain", "Bradley Hand", "BradleyHandITCTT-Bold"]
    static func isSignatureFont(_ f: NSFont?) -> Bool {
        guard let n = f?.fontName else { return false }
        return signatureFonts.contains { n.localizedCaseInsensitiveContains($0.replacingOccurrences(of: " ", with: "")) || n == $0 }
    }

    public static func signatureFont(size: CGFloat) -> NSFont {
        signatureFonts.lazy.compactMap { NSFont(name: $0, size: size) }.first ?? .systemFont(ofSize: size)
    }

    // MARK: Fitting

    /// FreeText inset, each side: text is drawn this far inside the object's box.
    static let textInset: CGFloat = 4

    /// Grows a text box (top-left shown points, top edge fixed) so the text is never clipped.
    /// Script fonts swash below their nominal descender, so there's room for that; a signature
    /// (single line, script font) grows sideways instead of wrapping. Stays on the page.
    static func fitted(_ r: CGRect, text: String, font: NSFont, page: CGRect) -> CGRect {
        let script = isSignatureFont(font)
        let pad = textInset
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        var width = r.width
        if script || !text.contains("\n") {
            let line = (text as NSString).size(withAttributes: attrs).width + 2 * pad + (script ? font.pointSize * 0.3 : 2)
            if script || line <= page.width { width = max(width, min(line, page.maxX - r.minX)) }
        }
        let need = (text as NSString).boundingRect(with: CGSize(width: max(8, width - 2 * pad), height: .greatestFiniteMagnitude),
                                                   options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs)
        let overhang = script ? font.pointSize * 0.35 : font.pointSize * 0.12   // swashes and descenders
        let height = max(r.height, ceil(need.height + overhang + 2 * pad))
        var out = CGRect(x: r.minX, y: r.minY, width: width, height: height)
        if out.maxY > page.maxY { out.origin.y = max(page.minY, page.maxY - height) }   // keep it on the page
        return out
    }

    /// Re-fits a placed text object after its words or font changed.
    public static func refit(_ a: PDFAnnotation, on page: PDFPage) {
        guard a.type == "FreeText", let font = a.font else { return }
        let space = EditOps.PageSpace(page)
        a.bounds = space.pageRect(fitted(space.topLeft(a.bounds), text: a.contents ?? "", font: font, page: space.bounds))
    }

    /// Keeps an object's box on its page (a drag or a page change can leave it off the edge, where
    /// it can't be clicked but would still be printed).
    public static func clampToPage(_ a: PDFAnnotation, on page: PDFPage) {
        let space = EditOps.PageSpace(page)
        var r = space.topLeft(a.bounds)
        let b = space.bounds
        r.size.width = min(r.width, b.width); r.size.height = min(r.height, b.height)
        r.origin.x = min(max(r.minX, b.minX), b.maxX - r.width)
        r.origin.y = min(max(r.minY, b.minY), b.maxY - r.height)
        a.bounds = space.pageRect(r)
    }

    // MARK: Creating

    /// A text box (or typed signature) as an editable FreeText annotation. `rect` is top-left
    /// points of the page as shown.
    @discardableResult
    public static func addText(_ doc: PDFDocument, page index: Int, rect: CGRect, text: String, font: NSFont,
                               color: NSColor, alignment: NSTextAlignment = .left) throws -> String {
        guard let page = doc.page(at: index) else { throw EzPDFError.invalidInput("No page \(index + 1).") }
        let space = EditOps.PageSpace(page)
        let r = space.pageRect(fitted(rect, text: text, font: font, page: space.bounds))
        let a = PDFAnnotation(bounds: r, forType: .freeText, withProperties: nil)
        a.contents = text
        a.font = font
        a.fontColor = color
        a.color = .clear
        a.alignment = alignment
        let border = PDFBorder(); border.lineWidth = 0
        a.border = border
        let id = newID()
        a.userName = marker + id
        page.addAnnotation(a)
        clampToPage(a, on: page)
        return id
    }

    /// An image (logo, signature picture, stamp) as an editable object. The image is saved in `folder`.
    @discardableResult
    public static func addImage(_ doc: PDFDocument, page index: Int, rect: CGRect, imageData: Data, folder: URL) throws -> String {
        guard let page = doc.page(at: index) else { throw EzPDFError.invalidInput("No page \(index + 1).") }
        guard let cg = PDFRaster.decodeImage(imageData), let png = PDFRaster.encode(cg, type: .png) else {
            throw EzPDFError.invalidInput("That image couldn't be read. Use PNG, JPEG, HEIC, TIFF, GIF, WebP or SVG.")
        }
        let id = newID()
        let dir = folder.appendingPathComponent("objects", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("\(id).png"), options: .atomic)
        let space = EditOps.PageSpace(page)
        let a = ImageStampAnnotation(bounds: space.pageRect(EditOps.fit(cg, in: rect)), image: cg)
        a.contents = imageKey + id
        a.userName = marker + id
        page.addAnnotation(a)
        clampToPage(a, on: page)
        return id
    }

    static func newID() -> String { UUID().uuidString.lowercased() }

    // MARK: Loading

    /// Turns saved objects back into drawable ones after opening a document: image placeholders
    /// get their image, and text objects draw upright on rotated pages (PDFKit draws FreeText in
    /// unrotated page space, so it would come out sideways).
    public static func hydrate(_ doc: PDFDocument, folder: URL) {
        for p in 0..<doc.pageCount {
            guard let page = doc.page(at: p) else { continue }
            for a in page.annotations where objectID(a) != nil && !(a is ImageStampAnnotation) && !(a is TextObjectAnnotation) {
                if let contents = a.contents, contents.hasPrefix(imageKey), let id = objectID(a) {
                    let url = folder.appendingPathComponent("objects/\(id).png")
                    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
                    let img = ImageStampAnnotation(bounds: a.bounds, image: cg)
                    img.contents = contents
                    img.userName = a.userName
                    page.removeAnnotation(a)
                    page.addAnnotation(img)
                } else if a.type == "FreeText", page.rotation % 360 != 0 {
                    let t = TextObjectAnnotation(copying: a)
                    page.removeAnnotation(a)
                    page.addAnnotation(t)
                }
            }
        }
    }

    /// The object with `id`, looked for first on `preferring` (0-based) when given.
    public static func find(_ doc: PDFDocument, id: String, preferring: Int? = nil) -> (page: Int, annotation: PDFAnnotation)? {
        if let p = preferring, let a = doc.page(at: p)?.annotations.first(where: { objectID($0) == id }) { return (p, a) }
        for p in 0..<doc.pageCount {
            if let a = doc.page(at: p)?.annotations.first(where: { objectID($0) == id }) { return (p, a) }
        }
        return nil
    }

    public static func list(_ doc: PDFDocument) -> [Info] {
        var out: [Info] = []
        for p in 0..<doc.pageCount {
            guard let page = doc.page(at: p) else { continue }
            let space = EditOps.PageSpace(page)
            for a in page.annotations {
                guard let id = objectID(a) else { continue }
                let r = space.topLeft(a.bounds)
                let k = kind(a)
                out.append(Info(id: id, kind: k, page: p + 1, rect: [r.minX, r.minY, r.width, r.height].map { (Double($0) * 10).rounded() / 10 },
                                text: k == .image ? nil : a.contents, fontName: a.font?.fontName, fontSize: a.font.map { Double($0.pointSize) },
                                color: a.fontColor.map(hex)))
            }
        }
        return out
    }

    /// "#RRGGBB" for a color (sRGB).
    public static func hexColor(_ c: NSColor) -> String { hex(c) }

    static func hex(_ c: NSColor) -> String {
        guard let s = c.usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int(s.redComponent * 255), Int(s.greenComponent * 255), Int(s.blueComponent * 255))
    }

    // MARK: Delivering

    public static func hasObjects(_ doc: PDFDocument) -> Bool {
        (0..<doc.pageCount).contains { p in doc.page(at: p)?.annotations.contains { objectID($0) != nil } ?? false }
    }

    /// The document as it should leave ezpdf: placed text, signatures and images drawn into their
    /// pages (upright, as shown). Everything else stays as it is: links, bookmarks, form fields
    /// and markup (highlights, notes, shapes) still work for whoever receives it.
    public static func deliverable(_ doc: PDFDocument, folder: URL) throws -> Data {
        var byPage: [Int: [EditOps.Overlay]] = [:]
        for p in 0..<doc.pageCount {
            guard let page = doc.page(at: p) else { continue }
            let space = EditOps.PageSpace(page)
            for a in page.annotations {
                guard let id = objectID(a) else { continue }
                let r = space.topLeft(a.bounds)
                if let contents = a.contents, contents.hasPrefix(imageKey) {
                    let url = folder.appendingPathComponent("objects/\(id).png")
                    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                        throw EzPDFError.failed("An image on page \(p + 1) is missing from the library, so the PDF wasn't made. Undo the last change or delete that image.")
                    }
                    byPage[p, default: []].append(.image(cg, rect: r))
                    page.removeAnnotation(a)
                } else if a.type == "FreeText" {
                    let text = a.contents ?? ""
                    if !text.isEmpty {
                        byPage[p, default: []].append(.text(text, rect: r.insetBy(dx: textInset, dy: textInset), font: a.font ?? .systemFont(ofSize: 12),
                                                            color: a.fontColor ?? .black, alignment: a.alignment))
                    }
                    page.removeAnnotation(a)
                } else {
                    // Boxes and other shapes are ordinary annotations: keep them, minus our tag.
                    a.userName = nil
                }
            }
        }
        try EditOps.compose(doc, overlays: byPage)
        guard let data = doc.dataRepresentation() else { throw EzPDFError.failed("Couldn't prepare the PDF.") }
        return data
    }

    // MARK: Copies and files

    /// An image file an object needs in another (or the same) document's folder.
    public struct ImageCopy: Sendable { public let from: URL; public let id: String }

    /// Gives every object on `page` a new id (after the page was duplicated or copied into another
    /// document, so two objects never share one) and returns the image files to copy for them.
    public static func reassignIDs(on page: PDFPage, sourceFolder: URL) -> [ImageCopy] {
        var copies: [ImageCopy] = []
        for a in page.annotations {
            guard let old = objectID(a) else { continue }
            let id = newID()
            a.userName = marker + id
            if let contents = a.contents, contents.hasPrefix(imageKey) {
                a.contents = imageKey + id
                copies.append(ImageCopy(from: sourceFolder.appendingPathComponent("objects/\(old).png"), id: id))
            }
        }
        return copies
    }

    public static func reassignIDs(_ doc: PDFDocument, sourceFolder: URL) -> [ImageCopy] {
        (0..<doc.pageCount).flatMap { p in doc.page(at: p).map { reassignIDs(on: $0, sourceFolder: sourceFolder) } ?? [] }
    }

    /// Copies image files for `copies` into `folder`. A missing source is reported, not skipped.
    public static func copyImages(_ copies: [ImageCopy], to folder: URL) throws {
        guard !copies.isEmpty else { return }
        let dir = folder.appendingPathComponent("objects", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for c in copies {
            let dest = dir.appendingPathComponent("\(c.id).png")
            guard FileManager.default.fileExists(atPath: c.from.path) else {
                throw EzPDFError.failed("A placed image's file is missing (\(c.from.lastPathComponent)).")
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: c.from, to: dest)
        }
    }

    /// The image ids a document refers to.
    static func imageIDs(in doc: PDFDocument) -> Set<String> {
        var ids = Set<String>()
        for p in 0..<doc.pageCount {
            for a in doc.page(at: p)?.annotations ?? [] {
                if let c = a.contents, c.hasPrefix(imageKey) { ids.insert(String(c.dropFirst(imageKey.count))) }
            }
        }
        return ids
    }

    /// Deletes image files no kept version uses (the current file and the undo copy), so deleting
    /// an image can still be undone and nothing piles up.
    public static func collectGarbage(folder: URL, versions: [URL]) {
        let dir = folder.appendingPathComponent("objects", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
              files.contains(where: { $0.pathExtension == "png" }) else { return }
        var keep = Set<String>()
        for v in versions where FileManager.default.fileExists(atPath: v.path) {
            // A version that can't be read keeps everything (never delete on doubt).
            guard let doc = PDFDocument(url: v), !doc.isLocked else { return }
            keep.formUnion(imageIDs(in: doc))
        }
        for f in files where f.pathExtension == "png" && !keep.contains(f.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: f)
        }
    }
}

/// Draws an image object. PDFKit saves it as a plain stamp with a pointer to the image file;
/// `Objects.hydrate` turns it back into this when the document opens. Drawn upright as the page
/// is shown.
public final class ImageStampAnnotation: PDFAnnotation {
    public let image: CGImage

    public init(bounds: CGRect, image: CGImage) {
        self.image = image
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
    }

    required init?(coder: NSCoder) { nil }

    /// PDFKit copies annotations (pages, documents); the copy must keep its image.
    public override func copy(with zone: NSZone? = nil) -> Any {
        let c = ImageStampAnnotation(bounds: bounds, image: image)
        c.contents = contents
        c.userName = userName
        return c
    }

    public override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        context.interpolationQuality = .high
        if let page {
            let space = EditOps.PageSpace(page)
            context.concatenate(space.toPage)
            context.draw(image, in: bounds.applying(space.toShown))
        } else {
            context.draw(image, in: bounds)
        }
        context.restoreGState()
    }
}

/// A placed text object on a rotated page, drawn upright as the page is shown (the same layout
/// `deliverable` burns in). Saved as an ordinary FreeText annotation.
public final class TextObjectAnnotation: PDFAnnotation {
    public init(copying a: PDFAnnotation) {
        super.init(bounds: a.bounds, forType: .freeText, withProperties: nil)
        contents = a.contents
        font = a.font
        fontColor = a.fontColor
        color = .clear
        alignment = a.alignment
        border = a.border
        userName = a.userName
    }

    required init?(coder: NSCoder) { nil }

    public override func copy(with zone: NSZone? = nil) -> Any { TextObjectAnnotation(copying: self) }

    public override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let page, let text = contents, !text.isEmpty else { return }
        let space = EditOps.PageSpace(page)
        context.saveGState()
        context.concatenate(space.toPage)
        let shown = bounds.applying(space.toShown).insetBy(dx: Objects.textInset, dy: Objects.textInset)
        EditOps.drawText(text, in: shown, font: font ?? .systemFont(ofSize: 12), color: fontColor ?? .black,
                         alignment: alignment, context: context)
        context.restoreGState()
    }
}
