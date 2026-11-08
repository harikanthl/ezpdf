import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Article → EPUB 3 with images embedded and a table of contents. Kindle reflows EPUB text
/// to the reader's chosen font size, which a fixed-page PDF can't do.
@MainActor
enum EPUBBuilder {
    static func build(article: WebConverter.Article, allowLocal: Bool = false) async throws -> Data {
        let html = ArticleHTML.document(body: article.html, header: ArticleHTML.header(for: article),
                                        title: article.title, preset: .kindle, lang: article.lang)
        let session = WebSession(width: 600, height: 800, javaScript: false, allowLocal: allowLocal)
        defer { session.close() }
        try await session.loadHTML(html, baseURL: article.sourceURL)

        // Download each image once and give it a local name.
        let srcs = (try await session.js("return Array.from(new Set(Array.from(document.images).map(i => i.currentSrc || i.src).filter(Boolean))).slice(0, 80)") as? [String]) ?? []
        let images = await downloadImages(srcs, allowLocal: allowLocal)
        var map: [String: String] = [:]
        for (src, img) in images { map[src] = "images/\(img.name)" }

        let json = try await session.jsString(serializeJS, ["map": map])
        guard let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let body = obj["xhtml"] as? String else { throw EzPDFError.failed("Couldn't build the EPUB.") }
        let toc = (obj["toc"] as? [[String: Any]] ?? []).compactMap { t -> (id: String, level: Int, text: String)? in
            guard let id = t["id"] as? String, let text = t["text"] as? String else { return nil }
            return (id, t["level"] as? Int ?? 2, text)
        }
        return package(title: article.title, author: article.byline, lang: article.lang ?? "en",
                       source: article.sourceURL.absoluteString, body: body, toc: toc,
                       images: Array(images.values), hasMath: body.contains("<math"), hasSVG: body.contains("<svg"))
    }

    struct Image { let name: String; let mediaType: String; let data: Data }

    static func downloadImages(_ srcs: [String], allowLocal: Bool) async -> [String: Image] {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = ["User-Agent": WebSession.userAgent]
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        return await withTaskGroup(of: (String, Image?).self) { group in
            for (i, src) in srcs.enumerated() {
                group.addTask {
                    let data: Data?
                    if src.hasPrefix("data:") {
                        data = Self.decodeDataURL(src)
                    } else if let url = URL(string: src), URLGuard.isAllowed(url, allowLocal: allowLocal) {
                        data = try? await session.data(from: url).0
                    } else {
                        data = nil
                    }
                    guard let data, data.count > 0, data.count < 15_000_000,
                          let img = Self.normalize(data, index: i) else { return (src, nil) }
                    return (src, img)
                }
            }
            var out: [String: Image] = [:]
            for await (src, img) in group { if let img { out[src] = img } }
            return out
        }
    }

    nonisolated static func decodeDataURL(_ s: String) -> Data? {
        guard let comma = s.firstIndex(of: ",") else { return nil }
        let meta = s[..<comma]
        let payload = String(s[s.index(after: comma)...])
        if meta.contains(";base64") { return Data(base64Encoded: payload) }
        return payload.removingPercentEncoding.map { Data($0.utf8) }
    }

    /// Keeps JPEG/PNG/GIF/SVG as is; re-encodes anything else (WebP, AVIF, HEIC) as JPEG,
    /// since older Kindle conversion doesn't take them.
    nonisolated static func normalize(_ data: Data, index: Int) -> Image? {
        let head = String(decoding: data.prefix(256), as: UTF8.self)
        if head.contains("<svg") || (head.hasPrefix("<?xml") && head.contains("svg")) {
            return Image(name: "img\(index).svg", mediaType: "image/svg+xml", data: data)
        }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(src) as String? else { return nil }
        switch type {
        case UTType.jpeg.identifier: return Image(name: "img\(index).jpg", mediaType: "image/jpeg", data: data)
        case UTType.png.identifier: return Image(name: "img\(index).png", mediaType: "image/png", data: data)
        case UTType.gif.identifier: return Image(name: "img\(index).gif", mediaType: "image/gif", data: data)
        default:
            guard let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            let out = NSMutableData()
            guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dst, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(dst) else { return nil }
            return Image(name: "img\(index).jpg", mediaType: "image/jpeg", data: out as Data)
        }
    }

    static let serializeJS = """
    document.querySelectorAll('img').forEach(img => {
      const s = img.currentSrc || img.src;
      if (map[s]) img.setAttribute('src', map[s]); else { img.remove(); return; }
      ['srcset','sizes','loading','decoding','fetchpriority'].forEach(a => img.removeAttribute(a));
      if (!img.getAttribute('alt')) img.setAttribute('alt', '');
    });
    document.querySelectorAll('picture source, script, noscript, iframe, video, audio, object, embed, style, link, form, input, button, select, textarea').forEach(e => e.remove());
    document.querySelectorAll('*').forEach(e => {
      for (const a of Array.from(e.attributes)) {
        if (/^on/i.test(a.name) || a.name.includes(':') && !/^(xmlns|xlink)/.test(a.name)) e.removeAttribute(a.name);
      }
    });
    const toc = [];
    document.querySelectorAll('article h1, article h2, article h3').forEach((h, i) => {
      const t = (h.textContent || '').trim().replace(/\\s+/g, ' ');
      if (!t) return;
      const id = 'ez-h' + i; h.setAttribute('id', id);
      toc.push({ id, level: +h.tagName[1], text: t.slice(0, 160) });
    });
    const art = document.querySelector('article');
    return JSON.stringify({ xhtml: new XMLSerializer().serializeToString(art), toc });
    """

    static let css = """
    body { font-family: serif; line-height: 1.5; margin: 0 4%; }
    h1, h2, h3, h4 { font-family: sans-serif; line-height: 1.25; }
    .ez-site { font-family: sans-serif; font-size: 0.75em; letter-spacing: 0.06em; text-transform: uppercase; color: #777; }
    .ez-title { font-size: 1.6em; margin: 0.2em 0 0.4em; }
    .ez-byline, .ez-source { font-family: sans-serif; font-size: 0.8em; color: #666; }
    .ez-source { word-break: break-all; }
    img, svg { max-width: 100%; height: auto; }
    figure { margin: 1em 0; } figcaption { font-size: 0.8em; color: #666; text-align: center; }
    pre { white-space: pre-wrap; font-size: 0.8em; background: #f4f4f4; padding: 0.6em; }
    code { font-family: monospace; }
    blockquote { margin: 1em 0; padding-left: 1em; border-left: 3px solid #ccc; }
    table { border-collapse: collapse; font-size: 0.85em; } th, td { border-bottom: 1px solid #ddd; padding: 0.25em 0.4em; }
    """

    static func x(_ s: String) -> String { ArticleHTML.escape(s) }

    static func package(title: String, author: String?, lang: String, source: String, body: String,
                        toc: [(id: String, level: Int, text: String)], images: [Image],
                        hasMath: Bool, hasSVG: Bool) -> Data {
        let uid = "urn:uuid:\(UUID().uuidString.lowercased())"
        let modified = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: "\\.\\d+", with: "", options: .regularExpression)
        var zip = ZipWriter()
        zip.add("mimetype", "application/epub+zip", compress: false)     // must be first, stored
        zip.add("META-INF/container.xml", """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """)

        var props: [String] = []
        if hasMath { props.append("mathml") }
        if hasSVG { props.append("svg") }
        let chapterProps = props.isEmpty ? "" : " properties=\"\(props.joined(separator: " "))\""
        let imageItems = images.sorted { $0.name < $1.name }.map {
            "<item id=\"\(x($0.name.replacingOccurrences(of: ".", with: "_")))\" href=\"images/\(x($0.name))\" media-type=\"\($0.mediaType)\"/>"
        }.joined(separator: "\n    ")
        let creator = author.map { "<dc:creator>\(x($0))</dc:creator>" } ?? ""
        zip.add("OEBPS/content.opf", """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid" xml:lang="\(x(lang))">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">\(uid)</dc:identifier>
            <dc:title>\(x(title))</dc:title>
            <dc:language>\(x(lang))</dc:language>
            \(creator)
            <dc:source>\(x(source))</dc:source>
            <meta property="dcterms:modified">\(modified)</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"\(chapterProps)/>
            <item id="css" href="style.css" media-type="text/css"/>
            \(imageItems)
          </manifest>
          <spine><itemref idref="chapter"/></spine>
        </package>
        """)

        let tocItems = toc.isEmpty
            ? "<li><a href=\"chapter.xhtml\">\(x(title))</a></li>"
            : toc.map { "<li><a href=\"chapter.xhtml#\($0.id)\">\(x($0.text))</a></li>" }.joined(separator: "\n")
        zip.add("OEBPS/nav.xhtml", """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(x(lang))" xml:lang="\(x(lang))">
        <head><meta charset="utf-8"/><title>\(x(title))</title></head>
        <body><nav epub:type="toc" id="toc"><h1>Contents</h1><ol>
        \(tocItems)
        </ol></nav></body></html>
        """)
        zip.add("OEBPS/style.css", css)
        zip.add("OEBPS/chapter.xhtml", """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(x(lang))" xml:lang="\(x(lang))">
        <head><meta charset="utf-8"/><title>\(x(title))</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
        <body>\(body)</body></html>
        """)
        for img in images { zip.add("OEBPS/images/\(img.name)", img.data, compress: false) }
        return zip.finish()
    }
}
