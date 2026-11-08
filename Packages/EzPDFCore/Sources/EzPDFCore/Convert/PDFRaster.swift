import Foundation
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import AppKit

enum PDFRaster {
    static func jpeg(fromPDF data: Data, scale: CGFloat) -> Data? {
        guard let doc = PDFDocument(data: data), let page = doc.page(at: 0), let cg = cgImage(page, scale: scale) else { return nil }
        return encode(cg, type: .jpeg, quality: 0.82)
    }

    /// Largest bitmap ezpdf renders (about 100 MB); bigger pages are scaled down to fit.
    static let maxPixels: CGFloat = 25_000_000

    /// Renders the page as a viewer shows it (crop box, rotated). The scale is reduced if needed so
    /// big pages still render instead of failing.
    static func cgImage(_ page: PDFPage, scale requested: CGFloat) -> CGImage? {
        let bounds = CGRect(origin: .zero, size: EditOps.PageSpace(page).size)
        guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite else { return nil }
        let scale = min(requested, sqrt(maxPixels / (bounds.width * bounds.height)))
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        // draw(with: .cropBox) already puts the crop box's origin at (0, 0); shifting again would
        // offset everything on cropped pages (and make redaction miss).
        page.draw(with: .cropBox, to: ctx)
        return ctx.makeImage()
    }

    /// Decodes any image people drop or generate: everything ImageIO reads (PNG, JPEG, HEIC, TIFF,
    /// GIF, WebP…), and SVG through AppKit, drawn at up to `maxPixels` on the long side.
    static func decodeImage(_ data: Data, maxPixels: Int = 3000) -> CGImage? {
        if let src = CGImageSourceCreateWithData(data as CFData, nil),
           let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                 kCGImageSourceCreateThumbnailWithTransform: true,
                                                                 kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary) {
            return cg
        }
        // Vector images: scale up so a small viewBox still comes out sharp.
        guard let img = NSImage(data: data), img.size.width > 0, img.size.height > 0 else { return nil }
        let long = max(img.size.width, img.size.height)
        let scale = min(CGFloat(maxPixels), max(long, 2000)) / long
        var rect = CGRect(x: 0, y: 0, width: (img.size.width * scale).rounded(), height: (img.size.height * scale).rounded())
        return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    static func encode(_ image: CGImage, type: UTType, quality: Double = 0.85) -> Data? {
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }
}
