import Foundation
import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers

/// Local files → PDF. Images become pages, rich documents keep their formatting, text formats
/// get the same reader layout as web articles.
@MainActor
public enum FileConverter {
    nonisolated public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "webp", "bmp", "avif"]
    nonisolated public static let richExtensions: Set<String> = ["docx", "doc", "rtf", "rtfd", "odt", "webarchive", "wordml"]
    nonisolated public static let textExtensions: Set<String> = ["md", "markdown", "txt", "text", "html", "htm", "csv", "tsv", "json", "log", "xml", "yaml", "yml", "swift", "py", "js", "ts"]

    nonisolated public static var supportedExtensions: Set<String> { imageExtensions.union(richExtensions).union(textExtensions).union(["pdf"]) }

    public struct Output { public var pdf: Data; public var title: String }

    public static func convert(_ urls: [URL], preset: PagePreset) async throws -> Output {
        guard let first = urls.first else { throw EzPDFError.invalidInput("No files.") }
        let ext = first.pathExtension.lowercased()
        let title = first.deletingPathExtension().lastPathComponent
        if urls.count > 1, urls.allSatisfy({ imageExtensions.contains($0.pathExtension.lowercased()) }) {
            return Output(pdf: try images(urls, preset: preset), title: title)
        }
        if urls.count > 1 {
            // Mixed batch: convert each, then join in order.
            let merged = PDFDocument()
            for u in urls {
                let part = try await convert([u], preset: preset)
                guard let d = PDFDocument(data: part.pdf) else { throw EzPDFError.failed("\(u.lastPathComponent) couldn't be added.") }
                PageOps.append(d, to: merged)
            }
            guard let data = merged.dataRepresentation() else { throw EzPDFError.failed("Couldn't join the files.") }
            return Output(pdf: data, title: title)
        }
        switch ext {
        case "pdf":
            guard let doc = PDFDocument(url: first) else { throw EzPDFError.invalidInput("That PDF couldn't be opened.") }
            if doc.isLocked { throw EzPDFError.invalidInput("That PDF has a password. Unlock it first.") }
            return Output(pdf: try Data(contentsOf: first), title: (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? title)
        case _ where imageExtensions.contains(ext):
            return Output(pdf: try images([first], preset: preset), title: title)
        case _ where richExtensions.contains(ext):
            return Output(pdf: try rich(first, preset: preset), title: title)
        case "md", "markdown":
            let md = try readText(first)
            let body = Markdown.html(md)
            let docTitle = Markdown.firstHeading(md) ?? title
            let pdf = try await WebConverter.renderHTMLBody(body, title: docTitle, preset: preset, baseURL: nil,
                                                            header: "", author: nil, subject: first.lastPathComponent, lang: nil).pdf
            return Output(pdf: pdf, title: docTitle)
        case "html", "htm":
            let html = try readText(first)
            let body = html.range(of: "<body[^>]*>", options: [.regularExpression, .caseInsensitive]).map { r -> String in
                let rest = html[r.upperBound...]
                return String(rest[..<(rest.range(of: "</body>", options: .caseInsensitive)?.lowerBound ?? rest.endIndex)])
            } ?? html
            let pdf = try await WebConverter.renderHTMLBody(stripScripts(body), title: title, preset: preset, baseURL: nil,
                                                            header: "", author: nil, subject: first.lastPathComponent, lang: nil).pdf
            return Output(pdf: pdf, title: title)
        case "csv", "tsv":
            let text = try readText(first)
            let body = CSV.htmlTable(text, separator: ext == "tsv" ? "\t" : ",")
            let pdf = try await WebConverter.renderHTMLBody(body, title: title, preset: preset, baseURL: nil,
                                                            header: ArticleHTML.header(title: title, subtitle: nil), author: nil, subject: first.lastPathComponent, lang: nil).pdf
            return Output(pdf: pdf, title: title)
        case _ where textExtensions.contains(ext):
            let text = try readText(first)
            let body = "<div class=\"ez-plain\">\(ArticleHTML.escape(text))</div>"
            let pdf = try await WebConverter.renderHTMLBody(body, title: title, preset: preset, baseURL: nil,
                                                            header: ArticleHTML.header(title: first.lastPathComponent, subtitle: nil),
                                                            author: nil, subject: first.lastPathComponent, lang: nil).pdf
            return Output(pdf: pdf, title: title)
        default:
            throw EzPDFError.invalidInput("ezpdf can't convert .\(ext) files yet. Supported: \(supportedExtensions.sorted().joined(separator: ", ")).")
        }
    }

    /// Reads a text file: UTF-8, or whatever encoding it declares or looks like (e.g. Windows-1252
    /// CSV exports), refusing files too big to lay out.
    static func readText(_ url: URL) throws -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size <= 30 * 1024 * 1024 else { throw EzPDFError.invalidInput("\(url.lastPathComponent) is too large to turn into a PDF (over 30 MB of text).") }
        let data = try Data(contentsOf: url)
        if let s = String(data: data, encoding: .utf8) { return s }
        var converted: NSString?
        let enc = NSString.stringEncoding(for: data, encodingOptions: nil, convertedString: &converted, usedLossyConversion: nil)
        if enc != 0, let converted { return converted as String }
        return String(decoding: data, as: UTF8.self)
    }

    static func stripScripts(_ html: String) -> String {
        html.replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<iframe[\\s\\S]*?</iframe>", with: "", options: [.regularExpression, .caseInsensitive])
    }

    // MARK: Images

    /// One page per image, fitted to the preset page and turned upright from EXIF orientation.
    /// "As on the web" keeps each image's own size.
    nonisolated static func images(_ urls: [URL], preset: PagePreset) throws -> Data {
        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw EzPDFError.failed("Couldn't create the PDF.") }
        var pages = 0
        for url in urls {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { continue }
            let count = max(1, CGImageSourceGetCount(src))
            for i in 0..<count {   // multi-page TIFFs
                let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                             kCGImageSourceCreateThumbnailWithTransform: true,
                                             kCGImageSourceThumbnailMaxPixelSize: 6000]
                guard let img = CGImageSourceCreateThumbnailAtIndex(src, i, opts as CFDictionary) else { continue }
                let iw = CGFloat(img.width), ih = CGFloat(img.height)
                var page: CGRect
                var target: CGRect
                if preset == .web {
                    // 1 px = 0.5 pt keeps photos from becoming wall-sized pages.
                    page = CGRect(x: 0, y: 0, width: iw / 2, height: ih / 2)
                    target = page
                } else {
                    var size = preset.pageSize
                    if iw > ih, preset == .letter || preset == .a4 { size = CGSize(width: size.height, height: size.width) }
                    page = CGRect(origin: .zero, size: size)
                    let m = min(preset.margin, 36)
                    let avail = page.insetBy(dx: m, dy: m)
                    let s = min(avail.width / iw, avail.height / ih)
                    target = CGRect(x: avail.midX - iw * s / 2, y: avail.midY - ih * s / 2, width: iw * s, height: ih * s)
                }
                ctx.beginPDFPage([kCGPDFContextMediaBox as String: page] as CFDictionary)
                ctx.draw(img, in: target)
                ctx.endPDFPage()
                pages += 1
            }
        }
        ctx.closePDF()
        guard pages > 0 else { throw EzPDFError.invalidInput("Those images couldn't be read.") }
        return out as Data
    }

    // MARK: Word, RTF, ODT

    /// Paginates an attributed document with TextKit and draws each page as vector PDF.
    /// Type is scaled up for e-reader presets so 11 pt body text stays readable on a Kindle.
    static func rich(_ url: URL, preset: PagePreset) throws -> Data {
        let attr = try NSMutableAttributedString(url: url, options: [:], documentAttributes: nil)
        let p = preset == .web ? PagePreset.letter : preset
        let scale = p.fontSize / 12.5
        if abs(scale - 1) > 0.05 {
            attr.enumerateAttribute(.font, in: NSRange(location: 0, length: attr.length)) { value, range, _ in
                if let f = value as? NSFont { attr.addAttribute(.font, value: f.withSize(f.pointSize * scale), range: range) }
            }
        }
        let storage = NSTextStorage(attributedString: attr)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        var containers: [NSTextContainer] = []
        repeat {
            let c = NSTextContainer(size: p.contentSize)
            c.lineFragmentPadding = 0
            layout.addTextContainer(c)
            containers.append(c)
            _ = layout.glyphRange(for: c)
        } while NSMaxRange(layout.glyphRange(for: containers.last!)) < layout.numberOfGlyphs && containers.count < 2000

        let out = NSMutableData()
        var box = CGRect(origin: .zero, size: p.pageSize)
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw EzPDFError.failed("Couldn't create the PDF.") }
        for c in containers {
            let range = layout.glyphRange(for: c)
            if range.length == 0, containers.count > 1 { continue }
            ctx.beginPDFPage(nil)
            let g = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = g
            ctx.translateBy(x: 0, y: p.pageSize.height)
            ctx.scaleBy(x: 1, y: -1)
            let origin = CGPoint(x: p.margin, y: p.margin)
            layout.drawBackground(forGlyphRange: range, at: origin)
            layout.drawGlyphs(forGlyphRange: range, at: origin)
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return out as Data
    }
}

enum CSV {
    static func parse(_ text: String, separator: Character = ",") -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var it = text.makeIterator()
        var pending: Character? = nil
        while true {
            let next: Character? = pending != nil ? pending : it.next()
            guard let ch = next else { break }
            pending = nil
            if quoted {
                if ch == "\"" {
                    if let n = it.next() { if n == "\"" { field.append("\"") } else { quoted = false; pending = n } } else { quoted = false }
                } else { field.append(ch) }
            } else if ch == "\"" { quoted = true }
            else if ch == separator { row.append(field); field = "" }
            else if ch == Character("\n") || ch == Character("\r\n") { row.append(field); rows.append(row); row = []; field = "" }
            else if ch != "\r" { field.append(ch) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func htmlTable(_ text: String, separator: Character) -> String {
        let rows = parse(text, separator: separator).prefix(5000)
        guard let head = rows.first else { return "" }
        var html = "<table><thead><tr>"
        for cell in head { html += "<th>" + ArticleHTML.escape(cell) + "</th>" }
        html += "</tr></thead><tbody>"
        for row in rows.dropFirst() {
            html += "<tr>"
            for cell in row { html += "<td>" + ArticleHTML.escape(cell) + "</td>" }
            html += "</tr>"
        }
        return html + "</tbody></table>"
    }
}
