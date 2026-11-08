import Foundation
import AppKit
import PDFKit
import ImageIO

/// Headers, footers, page numbers, Bates numbers, dates and logos on every page.
///
/// Text may contain tokens (the scheme follows Stirling-PDF's StampController, MIT):
///   @page  @total  @date  @date{MMM d, yyyy}  @time  @year  @title  @author  @filename  @bates  @@ (a literal @)
/// Drawn as page content (so it prints everywhere), with an undo point like any edit.
public enum Stamps {
    public struct Config: Sendable {
        public var headerLeft = "", headerCenter = "", headerRight = ""
        public var footerLeft = "", footerCenter = "", footerRight = ""
        public var fontName: String? = nil
        public var fontSize: CGFloat = 9
        public var color: NSColor = .darkGray
        /// Distance from the page edge, in points (at least 18).
        public var margin: CGFloat = 30
        public var skipFirstPage = false
        /// Swap left and right on even pages (for bound, two-sided documents).
        public var mirrorEvenPages = false
        public var pages: Set<Int>? = nil            // 0-based; nil = all
        public var logo: Data? = nil
        public var logoPosition: LogoPosition = .headerLeft
        public var logoHeight: CGFloat = 28
        public var batesPrefix = ""
        public var batesStart = 1
        public var batesDigits = 6
        public init() {}
    }

    public enum LogoPosition: String, Sendable, CaseIterable { case headerLeft, headerRight, headerCenter, footerLeft, footerRight }

    public static func apply(_ doc: PDFDocument, _ c: Config, fileName: String) throws -> Int {
        let attrs = doc.documentAttributes ?? [:]
        let title = attrs[PDFDocumentAttribute.titleAttribute] as? String ?? ""
        let author = attrs[PDFDocumentAttribute.authorAttribute] as? String ?? ""
        let total = doc.pageCount
        let font = EditOps.font(named: c.fontName, size: c.fontSize)
        var logo: CGImage?
        if let d = c.logo {
            guard let img = PDFRaster.decodeImage(d, maxPixels: 1200) else {
                throw EzPDFError.invalidInput("The logo image couldn't be read. Use PNG, JPEG, HEIC, TIFF, GIF, WebP or SVG.")
            }
            logo = img
        }
        var byPage: [Int: [EditOps.Overlay]] = [:]
        var bates = c.batesStart
        for i in 0..<total {
            if c.skipFirstPage && i == 0 { continue }
            if let pages = c.pages, !pages.contains(i) { continue }
            guard let page = doc.page(at: i) else { continue }
            let size = EditOps.PageSpace(page).size          // as shown, after rotation
            let m = max(18, min(c.margin, min(size.width, size.height) / 4))
            let mirror = c.mirrorEvenPages && (i + 1) % 2 == 0
            func fill(_ s: String) -> String {
                expand(s, page: i + 1, total: total, title: title, author: author, fileName: fileName,
                       bates: c.batesPrefix + String(format: "%0\(max(1, min(c.batesDigits, 12)))d", bates))
            }
            var overlays: [EditOps.Overlay] = []
            let lineH = ceil(font.ascender - font.descender) + 2
            let width = size.width - 2 * m
            func slot(_ text: String, y: CGFloat, align: NSTextAlignment) {
                let t = fill(text)
                guard !t.isEmpty else { return }
                overlays.append(.text(t, rect: CGRect(x: m, y: y, width: width, height: lineH), font: font, color: c.color, alignment: align))
            }
            let (hl, hr) = mirror ? (c.headerRight, c.headerLeft) : (c.headerLeft, c.headerRight)
            let (fl, fr) = mirror ? (c.footerRight, c.footerLeft) : (c.footerLeft, c.footerRight)
            let headerY = m
            let footerY = size.height - m - lineH
            slot(hl, y: headerY, align: .left); slot(c.headerCenter, y: headerY, align: .center); slot(hr, y: headerY, align: .right)
            slot(fl, y: footerY, align: .left); slot(c.footerCenter, y: footerY, align: .center); slot(fr, y: footerY, align: .right)
            if let logo {
                // Fit inside its box, never larger than the image itself.
                let h = min(c.logoHeight, CGFloat(logo.height))
                let w = h * CGFloat(logo.width) / CGFloat(max(1, logo.height))
                let top = c.logoPosition.rawValue.hasPrefix("header")
                let y = top ? m - 4 : size.height - m - h + 4
                var pos = c.logoPosition
                if mirror { pos = pos == .headerLeft ? .headerRight : pos == .headerRight ? .headerLeft : pos == .footerLeft ? .footerRight : pos == .footerRight ? .footerLeft : pos }
                let x: CGFloat
                switch pos {
                case .headerLeft, .footerLeft: x = m
                case .headerRight, .footerRight: x = size.width - m - w
                case .headerCenter: x = (size.width - w) / 2
                }
                overlays.append(.image(logo, rect: CGRect(x: x, y: max(4, y), width: w, height: h)))
            }
            guard !overlays.isEmpty else { continue }
            byPage[i] = overlays
            bates += 1
        }
        // All pages in one pass, so the stamp's font is embedded once for the whole document.
        try EditOps.compose(doc, overlays: byPage)
        return byPage.count
    }

    static let token = try! NSRegularExpression(pattern: #"@@|@date\{([^}]{1,50})\}|@[a-z_]+"#)

    /// Replaces tokens in one pass, so text that comes in through a token (a file named
    /// "report@page.pdf") is never read as another token. Tokens are whole words: "@page" is a
    /// token, "@pages" and "name@pagesmith.com" are left alone.
    static func expand(_ s: String, page: Int, total: Int, title: String, author: String, fileName: String, bates: String, now: Date = Date()) -> String {
        guard s.contains("@") else { return s }
        let d = DateFormatter(); d.dateStyle = .long
        let tm = DateFormatter(); tm.timeStyle = .short
        let values: [String: String] = [
            "@total_pages": "\(total)", "@page_count": "\(total)", "@page_number": "\(page)", "@filename": fileName,
            "@datetime": d.string(from: now) + " " + tm.string(from: now), "@author": author, "@title": title,
            "@total": "\(total)", "@bates": bates, "@date": d.string(from: now), "@time": tm.string(from: now),
            "@year": String(Calendar.current.component(.year, from: now)), "@page": "\(page)",
        ]
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in token.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let t = ns.substring(with: m.range)
            if t == "@@" {
                out += "@"
            } else if m.range(at: 1).location != NSNotFound {
                let f = DateFormatter(); f.dateFormat = ns.substring(with: m.range(at: 1))
                out += f.string(from: now)
            } else {
                // Unknown words after @ (an email address, a handle) stay exactly as typed.
                out += values[t] ?? t
            }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}
