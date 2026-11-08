import Foundation
import PDFKit
import ImageIO
import UniformTypeIdentifiers

enum PDFRaster {
    /// Renders page 1 of a PDF to PNG at `scale` × its point size.
    static func png(fromPDF data: Data, scale: CGFloat) -> Data? {
        guard let doc = PDFDocument(data: data), let page = doc.page(at: 0) else { return nil }
        guard let cg = cgImage(page, scale: scale) else { return nil }
        return encode(cg, type: .png)
    }

    static func jpeg(fromPDF data: Data, scale: CGFloat) -> Data? {
        guard let doc = PDFDocument(data: data), let page = doc.page(at: 0), let cg = cgImage(page, scale: scale) else { return nil }
        return encode(cg, type: .jpeg, quality: 0.82)
    }

    /// Largest bitmap ezpdf renders (about 100 MB); bigger pages are scaled down to fit.
    static let maxPixels: CGFloat = 25_000_000

    /// Renders the page's crop box (what a viewer shows). The scale is reduced if needed so big
    /// pages still render instead of failing.
    static func cgImage(_ page: PDFPage, scale requested: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .cropBox)
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
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .cropBox, to: ctx)
        return ctx.makeImage()
    }

    static func encode(_ image: CGImage, type: UTType, quality: Double = 0.85) -> Data? {
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }
}
