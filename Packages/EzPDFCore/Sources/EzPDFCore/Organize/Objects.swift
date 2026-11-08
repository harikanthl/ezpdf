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

    // MARK: Creating

    /// A text box (or typed signature) as an editable FreeText annotation.
    @discardableResult
    public static func addText(_ doc: PDFDocument, page index: Int, rect: CGRect, text: String, font: NSFont,
                               color: NSColor, alignment: NSTextAlignment = .left) throws -> String {
        guard let page = doc.page(at: index) else { throw EzPDFError.invalidInput("No page \(index + 1).") }
        let crop = page.bounds(for: .cropBox)
        var r = EditOps.pdfRect(rect, crop: crop)
        // Grow the box to fit the text so nothing is clipped.
        let need = (text as NSString).boundingRect(with: CGSize(width: r.width, height: .greatestFiniteMagnitude),
                                                   options: [.usesLineFragmentOrigin], attributes: [.font: font])
        if need.height + 4 > r.height { r.origin.y -= (need.height + 4 - r.height); r.size.height = need.height + 4 }
        let a = PDFAnnotation(bounds: r, forType: .freeText, withProperties: nil)
        a.contents = text
        a.font = font
        a.fontColor = color
        a.color = .clear
        a.alignment = alignment
        let border = PDFBorder(); border.lineWidth = 0
        a.border = border
        let id = UUID().uuidString.lowercased()
        a.userName = marker + id
        page.addAnnotation(a)
        return id
    }

    /// An image (logo, signature picture, stamp) as an editable object. The image is saved in `folder`.
    @discardableResult
    public static func addImage(_ doc: PDFDocument, page index: Int, rect: CGRect, imageData: Data, folder: URL) throws -> String {
        guard let page = doc.page(at: index) else { throw EzPDFError.invalidInput("No page \(index + 1).") }
        guard let src = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                    kCGImageSourceCreateThumbnailWithTransform: true,
                                                                    kCGImageSourceThumbnailMaxPixelSize: 3000] as CFDictionary),
              let png = PDFRaster.encode(cg, type: .png) else { throw EzPDFError.invalidInput("That image couldn't be read.") }
        let id = UUID().uuidString.lowercased()
        let dir = folder.appendingPathComponent("objects", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("\(id).png"), options: .atomic)
        let crop = page.bounds(for: .cropBox)
        let fitted = EditOps.fit(cg, in: rect)
        let a = ImageStampAnnotation(bounds: EditOps.pdfRect(fitted, crop: crop), image: cg)
        a.contents = imageKey + id
        a.userName = marker + id
        page.addAnnotation(a)
        return id
    }

    // MARK: Loading

    /// Turns saved image placeholders back into drawable image objects (after opening a document).
    public static func hydrate(_ doc: PDFDocument, folder: URL) {
        for p in 0..<doc.pageCount {
            guard let page = doc.page(at: p) else { continue }
            for a in page.annotations where !(a is ImageStampAnnotation) {
                guard let contents = a.contents, contents.hasPrefix(imageKey), let id = objectID(a) else { continue }
                let url = folder.appendingPathComponent("objects/\(id).png")
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
                let img = ImageStampAnnotation(bounds: a.bounds, image: cg)
                img.contents = contents
                img.userName = a.userName
                page.removeAnnotation(a)
                page.addAnnotation(img)
            }
        }
    }

    public static func find(_ doc: PDFDocument, id: String) -> (page: Int, annotation: PDFAnnotation)? {
        for p in 0..<doc.pageCount {
            if let a = doc.page(at: p)?.annotations.first(where: { objectID($0) == id }) { return (p, a) }
        }
        return nil
    }

    public static func list(_ doc: PDFDocument) -> [Info] {
        var out: [Info] = []
        for p in 0..<doc.pageCount {
            guard let page = doc.page(at: p) else { continue }
            let crop = page.bounds(for: .cropBox)
            for a in page.annotations {
                guard let id = objectID(a) else { continue }
                let r = EditOps.topLeftRect(a.bounds, crop: crop)
                let k = kind(a)
                out.append(Info(id: id, kind: k, page: p + 1, rect: [r.minX, r.minY, r.width, r.height].map { (Double($0) * 10).rounded() / 10 },
                                text: k == .image ? nil : a.contents, fontName: a.font?.fontName, fontSize: a.font.map { Double($0.pointSize) },
                                color: a.fontColor.map(hex)))
            }
        }
        return out
    }

    static func hex(_ c: NSColor) -> String {
        guard let s = c.usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int(s.redComponent * 255), Int(s.greenComponent * 255), Int(s.blueComponent * 255))
    }

    // MARK: Delivering

    public static func hasObjects(_ doc: PDFDocument) -> Bool {
        (0..<doc.pageCount).contains { p in doc.page(at: p)?.annotations.contains { objectID($0) != nil } ?? false }
    }

    /// The document as it should leave ezpdf: images drawn into their pages, then every annotation
    /// (text boxes, signatures, highlights, form values) burned in.
    public static func deliverable(_ doc: PDFDocument, folder: URL) throws -> Data {
        for p in 0..<doc.pageCount {
            guard let page = doc.page(at: p) else { continue }
            let crop = page.bounds(for: .cropBox)
            var overlays: [EditOps.Overlay] = []
            for a in page.annotations {
                guard let contents = a.contents, contents.hasPrefix(imageKey), let id = objectID(a) else { continue }
                let url = folder.appendingPathComponent("objects/\(id).png")
                if let src = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                    overlays.append(.image(cg, rect: EditOps.topLeftRect(a.bounds, crop: crop)))
                }
                page.removeAnnotation(a)
            }
            if !overlays.isEmpty { try EditOps.compose(doc, page: p, overlays: overlays) }
        }
        guard let data = EditOps.flatten(doc) else { throw EzPDFError.failed("Couldn't prepare the PDF.") }
        return data
    }
}

/// Draws an image object. PDFKit saves it as a plain stamp with a pointer to the image file;
/// `Objects.hydrate` turns it back into this when the document opens.
public final class ImageStampAnnotation: PDFAnnotation {
    public let image: CGImage

    public init(bounds: CGRect, image: CGImage) {
        self.image = image
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
    }

    required init?(coder: NSCoder) { nil }

    public override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
        context.restoreGState()
    }
}
