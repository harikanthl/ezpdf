import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Makes PDFs smaller by re-encoding their images: each image is sized for how big it is actually
/// drawn on the page (down to `maxDPI`) and saved as JPEG at `quality`. Text, vector drawing and
/// fonts are copied as they are, and annotations, form fields, links and the outline stay put.
///
/// Only images it can read exactly are changed: 8-bit gray or RGB (plain, ICC-based or JPEG), with
/// no color-key mask or Decode array. Anything else (CMYK, indexed, 1-bit, masks) is kept, and an
/// image is only replaced when the new one is clearly smaller.
public enum ImageCompressor {
    public struct Settings: Sendable, Equatable {
        /// The highest resolution kept, in pixels per inch of the image as drawn.
        public var maxDPI: Double
        /// JPEG quality, 0…1.
        public var quality: Double

        public init(maxDPI: Double, quality: Double) {
            self.maxDPI = min(max(maxDPI, 36), 1200)
            self.quality = min(max(quality, 0.1), 1)
        }

        /// Keeps print quality: 220 ppi, light JPEG.
        public static let balanced = Settings(maxDPI: 220, quality: 0.8)
        /// Screen quality: 120 ppi.
        public static let small = Settings(maxDPI: 120, quality: 0.62)
        /// Smallest that's still readable on screen (email attachments): 80 ppi.
        public static let smallest = Settings(maxDPI: 80, quality: 0.45)
    }

    public struct Result {
        public var data: Data
        /// Images re-encoded.
        public var images: Int
    }

    /// Nil when nothing could be made smaller (or the file can't be rewritten).
    public static func compress(_ doc: PDFDocument, settings: Settings) -> Result? {
        guard doc.pageCount > 0, !doc.isLocked, let cgDoc = doc.documentRef, cgDoc.numberOfPages == doc.pageCount else { return nil }

        // 1. Where every image is drawn, and the largest size it's drawn at (points): on the page
        //    and in annotations' appearances. Images in tiling patterns and soft-mask groups are
        //    drawn at sizes this doesn't follow, so they're kept as they are.
        var drawn: [CGPDFStreamRef: CGSize] = [:]
        var order: [CGPDFStreamRef] = []
        var kept = Set<CGPDFStreamRef>()
        for i in 1...cgDoc.numberOfPages {
            guard let page = cgDoc.page(at: i) else { return nil }
            var seen = Set<CGPDFDictionaryRef>()
            if let res = page.dictionary.flatMap({ TextEraser.inherited($0, "Resources") }).flatMap(TextEraser.dictValue) {
                unmeasured(res, into: &kept, seen: &seen, depth: 0)
            }
            for (stream, ctm) in TextEraser.imageDraws(page) + annotationImageDraws(page, kept: &kept, seen: &seen) {
                let size = CGSize(width: hypot(ctm.a, ctm.b), height: hypot(ctm.c, ctm.d))
                guard size.width.isFinite, size.height.isFinite else { continue }
                if let old = drawn[stream] {
                    drawn[stream] = CGSize(width: max(old.width, size.width), height: max(old.height, size.height))
                } else {
                    drawn[stream] = size
                    order.append(stream)
                }
            }
        }

        // 2. New encodings for the images worth changing.
        var replacements: [CGPDFStreamRef: TextEraser.Writer.ImageReplacement] = [:]
        for stream in order where !kept.contains(stream) {
            guard let size = drawn[stream], let new = reencode(stream, drawnAt: size, settings: settings) else { continue }
            replacements[stream] = new.image
            if let mask = new.mask { replacements[mask.stream] = mask.replacement }
        }
        let changed = replacements.values.filter(\.jpeg).count
        guard changed > 0 else { return nil }

        // 3. The whole document written again with the new images: pages, annotations, form
        //    fields, outline and structure are copied object for object (each written once).
        guard let data = write(cgDoc, images: replacements), let check = PDFDocument(data: data),
              check.pageCount == doc.pageCount, !check.isLocked else { return nil }
        return Result(data: data, images: changed)
    }

    // MARK: Where images are drawn

    /// Images in annotations' appearance streams (normal, rollover, down), each drawn under the
    /// transform that maps the appearance's box onto the annotation's rectangle.
    static func annotationImageDraws(_ page: CGPDFPage, kept: inout Set<CGPDFStreamRef>,
                                     seen: inout Set<CGPDFDictionaryRef>) -> [(CGPDFStreamRef, CGAffineTransform)] {
        guard let pageDict = page.dictionary, let annots = pageDict.object("Annots").flatMap(TextEraser.arrayValue) else { return [] }
        var out: [(CGPDFStreamRef, CGAffineTransform)] = []
        for k in 0..<CGPDFArrayGetCount(annots) {
            var annot: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(annots, k, &annot), let annot,
                  let rect = annot.object("Rect").flatMap(rectValue),
                  let ap = annot.object("AP").flatMap(TextEraser.dictValue) else { continue }
            var appearances: [CGPDFStreamRef] = []
            for key in ["N", "R", "D"] {
                guard let o = ap.object(key) else { continue }
                if let s = TextEraser.streamValue(o) { appearances.append(s) }
                else if let states = TextEraser.dictValue(o) {
                    CGPDFDictionaryApplyBlock(states, { _, v, _ in
                        if let s = TextEraser.streamValue(v) { appearances.append(s) }
                        return true
                    }, nil)
                }
            }
            for form in appearances {
                guard let d = CGPDFStreamGetDictionary(form), let bbox = d.object("BBox").flatMap(rectValue),
                      bbox.width > 0, bbox.height > 0 else { continue }
                let matrix = d.object("Matrix").flatMap(matrixValue) ?? .identity
                let box = bbox.applying(matrix)
                guard box.width > 0, box.height > 0 else { continue }
                // PDF 12.5.5: the transformed box is scaled and moved onto the annotation's rectangle.
                let fit = CGAffineTransform(translationX: -box.minX, y: -box.minY)
                    .concatenating(CGAffineTransform(scaleX: rect.width / box.width, y: rect.height / box.height))
                    .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY))
                var format = CGPDFDataFormat.raw
                guard let content = CGPDFStreamCopyData(form, &format) as Data?, format == .raw else { continue }
                let resources = d.object("Resources").flatMap(TextEraser.dictValue)
                if let resources { unmeasured(resources, into: &kept, seen: &seen, depth: 0) }
                let i = TextEraser.Interpreter(mode: .images)
                _ = i.run([UInt8](content), resources: resources, ctm: matrix.concatenating(fit), depth: 0)
                out += i.imageDraws.map { ($0.stream, $0.ctm) }
            }
        }
        return out
    }

    /// Images reachable from tiling patterns and soft-mask groups under `resources` (also inside
    /// the forms it holds). Those are drawn at sizes the interpreter doesn't follow.
    static func unmeasured(_ resources: CGPDFDictionaryRef, into kept: inout Set<CGPDFStreamRef>,
                           seen: inout Set<CGPDFDictionaryRef>, depth: Int) {
        guard depth < 12, seen.insert(resources).inserted else { return }
        func entries(_ key: String) -> [CGPDFObjectRef] {
            guard let d = resources.object(key).flatMap(TextEraser.dictValue) else { return [] }
            var list: [CGPDFObjectRef] = []
            CGPDFDictionaryApplyBlock(d, { _, v, _ in list.append(v); return true }, nil)
            return list
        }
        // Forms: look inside their resources too.
        for o in entries("XObject") {
            guard let s = TextEraser.streamValue(o), let d = CGPDFStreamGetDictionary(s), subtype(d) == "Form",
                  let r = d.object("Resources").flatMap(TextEraser.dictValue) else { continue }
            unmeasured(r, into: &kept, seen: &seen, depth: depth + 1)
        }
        // Tiling patterns: every image under them is kept.
        for o in entries("Pattern") {
            guard let s = TextEraser.streamValue(o), let r = CGPDFStreamGetDictionary(s)?.object("Resources").flatMap(TextEraser.dictValue) else { continue }
            var visited = Set<CGPDFDictionaryRef>()
            allImages(r, into: &kept, seen: &visited, depth: depth + 1)
        }
        // Soft masks drawn from a group: so is every image in the group.
        for o in entries("ExtGState") {
            guard let gs = TextEraser.dictValue(o), let mask = gs.object("SMask").flatMap(TextEraser.dictValue),
                  let group = mask.object("G").flatMap(TextEraser.streamValue),
                  let r = CGPDFStreamGetDictionary(group)?.object("Resources").flatMap(TextEraser.dictValue) else { continue }
            var visited = Set<CGPDFDictionaryRef>()
            allImages(r, into: &kept, seen: &visited, depth: depth + 1)
        }
    }

    /// Every image under `resources`, through forms, patterns and soft-mask groups.
    static func allImages(_ resources: CGPDFDictionaryRef, into kept: inout Set<CGPDFStreamRef>,
                          seen: inout Set<CGPDFDictionaryRef>, depth: Int) {
        guard depth < 12 else { return }
        var children: [CGPDFStreamRef] = []
        for key in ["XObject", "Pattern"] {
            guard let d = resources.object(key).flatMap(TextEraser.dictValue) else { continue }
            CGPDFDictionaryApplyBlock(d, { _, v, _ in
                if let s = TextEraser.streamValue(v) { children.append(s) }
                return true
            }, nil)
        }
        if let states = resources.object("ExtGState").flatMap(TextEraser.dictValue) {
            CGPDFDictionaryApplyBlock(states, { _, v, _ in
                if let gs = TextEraser.dictValue(v), let mask = gs.object("SMask").flatMap(TextEraser.dictValue),
                   let group = mask.object("G").flatMap(TextEraser.streamValue) { children.append(group) }
                return true
            }, nil)
        }
        for s in children {
            guard let sd = CGPDFStreamGetDictionary(s) else { continue }
            if subtype(sd) == "Image" { kept.insert(s); continue }
            // Each resource dictionary once: forms can share them, or (in broken files) loop.
            if let r = sd.object("Resources").flatMap(TextEraser.dictValue), seen.insert(r).inserted {
                allImages(r, into: &kept, seen: &seen, depth: depth + 1)
            }
        }
    }

    static func subtype(_ d: CGPDFDictionaryRef) -> String? {
        var n: UnsafePointer<CChar>?
        return CGPDFDictionaryGetName(d, "Subtype", &n) ? n.map { String(cString: $0) } : nil
    }

    static func numbers(_ o: CGPDFObjectRef, count: Int) -> [CGFloat]? {
        guard let a = TextEraser.arrayValue(o), CGPDFArrayGetCount(a) == count else { return nil }
        var v: [CGFloat] = []
        for k in 0..<count {
            var x: CGPDFReal = 0
            guard CGPDFArrayGetNumber(a, k, &x), x.isFinite else { return nil }
            v.append(x)
        }
        return v
    }

    static func rectValue(_ o: CGPDFObjectRef) -> CGRect? {
        numbers(o, count: 4).map { CGRect(x: $0[0], y: $0[1], width: $0[2] - $0[0], height: $0[3] - $0[1]).standardized }
    }

    static func matrixValue(_ o: CGPDFObjectRef) -> CGAffineTransform? {
        numbers(o, count: 6).map { CGAffineTransform(a: $0[0], b: $0[1], c: $0[2], d: $0[3], tx: $0[4], ty: $0[5]) }
    }

    // MARK: Re-encoding one image

    struct Reencoded {
        var image: TextEraser.Writer.ImageReplacement
        var mask: (stream: CGPDFStreamRef, replacement: TextEraser.Writer.ImageReplacement)?
    }

    static func reencode(_ stream: CGPDFStreamRef, drawnAt drawnSize: CGSize, settings: Settings) -> Reencoded? {
        guard let dict = CGPDFStreamGetDictionary(stream) else { return nil }
        var w: CGPDFInteger = 0, h: CGPDFInteger = 0, bpc: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(dict, "Width", &w), CGPDFDictionaryGetInteger(dict, "Height", &h), w > 0, h > 0 else { return nil }
        var isMask: CGPDFBoolean = 0
        if CGPDFDictionaryGetBoolean(dict, "ImageMask", &isMask), isMask != 0 { return nil }
        if dict.object("Decode") != nil { return nil }
        // A color-key mask (an array of colors) can't survive lossy compression; a mask image can.
        if let m = dict.object("Mask"), CGPDFObjectGetType(m) == .array { return nil }
        guard let components = components(dict) else { return nil }

        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) as Data? else { return nil }
        var length: CGPDFInteger = 0
        let encodedLength = CGPDFDictionaryGetInteger(dict, "Length", &length) && length > 0 ? Int(length) : data.count
        guard encodedLength > 12_000 else { return nil }    // small images aren't worth it

        let source: CGImage?
        switch format {
        case .jpegEncoded, .JPEG2000:
            // ImageIO reads JPEG and JPEG 2000. CMYK stays CMYK, only from JPEG (see below).
            guard components != 4 || format == .jpegEncoded else { return nil }
            source = CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        case .raw:
            guard CGPDFDictionaryGetInteger(dict, "BitsPerComponent", &bpc), bpc == 8, components == 1 || components == 3 else { return nil }
            source = rawImage(data, width: Int(w), height: Int(h), components: components)
        @unknown default:
            return nil
        }
        guard let source, source.width == Int(w), source.height == Int(h) else { return nil }

        // Pixels needed for the size it's drawn at; never upsample.
        let needW = drawnSize.width / 72 * settings.maxDPI, needH = drawnSize.height / 72 * settings.maxDPI
        var scale = min(1, max(needW / Double(w), needH / Double(h)))
        if scale > 0.9 { scale = 1 }
        let newW = max(1, Int((Double(w) * scale).rounded())), newH = max(1, Int((Double(h) * scale).rounded()))
        let gray = components == 1, cmyk = components == 4
        guard let scaled = redraw(source, width: newW, height: newH, gray: gray, cmyk: cmyk),
              let jpeg = PDFRaster.encode(scaled, type: .jpeg, quality: settings.quality),
              Double(jpeg.count) < Double(encodedLength) * 0.85 else { return nil }
        // CMYK JPEGs are read differently depending on Adobe's marker (inverted or not); the new one
        // must be written the same way as the old, or its colors would flip.
        if cmyk, hasAdobeMarker(data) != hasAdobeMarker(jpeg) { return nil }

        var entries = ["Width": "\(newW)", "Height": "\(newH)", "BitsPerComponent": "8",
                       "ColorSpace": gray ? "/DeviceGray" : cmyk ? "/DeviceCMYK" : "/DeviceRGB"]
        var mask: (CGPDFStreamRef, TextEraser.Writer.ImageReplacement)?
        // A soft mask is resized with the image (losslessly) when it's a plain 8-bit gray one.
        // (A mask may be a different size from its image, so one that can't be resized is kept.)
        if let smaskObj = dict.object("SMask"), let smask = TextEraser.streamValue(smaskObj), newW != w || newH != h,
           let m = resizeMask(smask, width: newW, height: newH) {
            mask = (smask, m)
        }
        entries["SMaskInData"] = ""     // JPEG has no alpha of its own
        return Reencoded(image: .init(data: jpeg, entries: entries, jpeg: true), mask: mask)
    }

    /// Color components of the image's color space: 1 gray, 3 RGB, 4 CMYK; nil for anything else.
    static func components(_ dict: CGPDFDictionaryRef) -> Int? {
        guard let cs = dict.object("ColorSpace") else {
            // JPEG 2000 may carry its own color space.
            var f: UnsafePointer<CChar>?
            return CGPDFDictionaryGetName(dict, "Filter", &f) && f.map { String(cString: $0) } == "JPXDecode" ? 3 : nil
        }
        if let name = TextEraser.nameValue(cs) {
            switch name {
            case "DeviceGray", "CalGray", "G": return 1
            case "DeviceRGB", "CalRGB", "RGB": return 3
            case "DeviceCMYK", "CMYK": return 4
            default: return nil
            }
        }
        guard let a = TextEraser.arrayValue(cs), CGPDFArrayGetCount(a) == 2 else { return nil }
        var family: UnsafePointer<CChar>?
        guard CGPDFArrayGetName(a, 0, &family), let family else { return nil }
        switch String(cString: family) {
        case "ICCBased":
            var profile: CGPDFStreamRef?
            var n: CGPDFInteger = 0
            guard CGPDFArrayGetStream(a, 1, &profile), let profile, let pd = CGPDFStreamGetDictionary(profile),
                  CGPDFDictionaryGetInteger(pd, "N", &n) else { return nil }
            return [1, 3, 4].contains(Int(n)) ? Int(n) : nil
        case "CalGray": return 1
        case "CalRGB": return 3
        default: return nil
        }
    }

    static func rawImage(_ data: Data, width: Int, height: Int, components: Int) -> CGImage? {
        let row = width * components
        guard data.count >= row * height, let provider = CGDataProvider(data: data as CFData) else { return nil }
        let space = components == 1 ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * components, bytesPerRow: row,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func redraw(_ image: CGImage, width: Int, height: Int, gray: Bool, cmyk: Bool = false) -> CGImage? {
        let space = gray ? CGColorSpaceCreateDeviceGray() : cmyk ? CGColorSpaceCreateDeviceCMYK() : CGColorSpace(name: CGColorSpace.sRGB)!
        let info = gray || cmyk ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// Whether a JPEG carries Adobe's APP14 marker (how CMYK JPEGs say their samples are inverted).
    static func hasAdobeMarker(_ jpeg: Data) -> Bool {
        let bytes = [UInt8](jpeg.prefix(64 * 1024))
        var i = 2
        while i + 4 < bytes.count, bytes[i] == 0xFF {
            let marker = bytes[i + 1]
            if marker == 0xDA { break }          // start of scan: no more header markers
            let len = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            if marker == 0xEE, i + 9 < bytes.count, Array(bytes[(i + 4)..<(i + 9)]) == Array("Adobe".utf8) { return true }
            i += 2 + len
        }
        return false
    }

    /// An 8-bit gray soft mask resampled to the image's new size, as raw samples.
    static func resizeMask(_ stream: CGPDFStreamRef, width: Int, height: Int) -> TextEraser.Writer.ImageReplacement? {
        guard let dict = CGPDFStreamGetDictionary(stream) else { return nil }
        var w: CGPDFInteger = 0, h: CGPDFInteger = 0, bpc: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(dict, "Width", &w), CGPDFDictionaryGetInteger(dict, "Height", &h),
              CGPDFDictionaryGetInteger(dict, "BitsPerComponent", &bpc), bpc == 8,
              dict.object("Matte") == nil, dict.object("Decode") == nil else { return nil }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) as Data?, format == .raw,
              let src = rawImage(data, width: Int(w), height: Int(h), components: 1) else { return nil }
        // Only shrink: a mask smaller than the new image is kept as it is.
        guard Int(w) > width || Int(h) > height else { return nil }
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let bytes = ctx.data else { return nil }
        let out = Data(bytes: bytes, count: width * height)
        return .init(data: out, entries: ["Width": "\(width)", "Height": "\(height)", "BitsPerComponent": "8",
                                          "ColorSpace": "/DeviceGray"], jpeg: false)
    }

    // MARK: Writing

    /// The document copied from its catalog down, with `images` swapped in. Encrypted files aren't
    /// copied (their objects would have to be encrypted again).
    static func write(_ cgDoc: CGPDFDocument, images: [CGPDFStreamRef: TextEraser.Writer.ImageReplacement]) -> Data? {
        guard !cgDoc.isEncrypted, let catalog = cgDoc.catalog else { return nil }
        let w = TextEraser.Writer(replacements: [:], images: images, shareDictionaries: true)
        let root = w.reference(catalog)
        var extra = ""
        if let info = cgDoc.info { extra += "/Info " + w.reference(info) }
        if let id = cgDoc.fileIdentifier, CGPDFArrayGetCount(id) == 2 {
            var parts: [String] = []
            for k in 0..<2 {
                var s: CGPDFStringRef?
                guard CGPDFArrayGetString(id, k, &s), let s, let p = CGPDFStringGetBytePtr(s) else { continue }
                parts.append("<" + UnsafeBufferPointer(start: p, count: CGPDFStringGetLength(s)).map { String(format: "%02X", $0) }.joined() + ">")
            }
            if parts.count == 2 { extra += " /ID [\(parts[0]) \(parts[1])]" }
        }
        w.setTrailer(root: root, extra: extra)
        guard let data = w.finish(), !w.failed else { return nil }
        return data
    }
}

extension TextEraser {
    /// Every image XObject the page draws (also inside forms), with the CTM it's drawn under.
    static func imageDraws(_ page: CGPDFPage) -> [(CGPDFStreamRef, CGAffineTransform)] {
        guard let content = contentBytes(page),
              let resources = page.dictionary.flatMap({ inherited($0, "Resources") }).flatMap(dictValue) else { return [] }
        let i = Interpreter(mode: .images)
        _ = i.run(content, resources: resources, ctm: .identity, depth: 0)
        return i.imageDraws.map { ($0.stream, $0.ctm) }
    }
}
