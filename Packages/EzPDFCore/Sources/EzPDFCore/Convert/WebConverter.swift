import Foundation
import WebKit

/// Link → clean PDF (and EPUB). Loads the real page so client-rendered content and math
/// appear, extracts the article with Mozilla Readability, lays it out for the chosen device.
@MainActor
public enum WebConverter {
    public struct Article: Sendable {
        public var title: String
        public var byline: String?
        public var siteName: String?
        public var excerpt: String?
        public var publishedTime: String?
        public var lang: String?
        public var html: String          // cleaned article body
        public var textLength: Int
        public var sourceURL: URL
    }

    public struct Output: Sendable {
        public var pdf: Data
        public var epub: Data?
        public var article: Article?
        public var title: String
        /// False when the page wasn't an article and was captured as it looks instead.
        public var usedReader: Bool
        public var finalURL: URL
        public var notes: [String]
    }

    public static func convert(url: URL, preset: PagePreset, format: OutputFormat = .pdf,
                               allowLocal: Bool = false,
                               progress: @escaping @MainActor (String) -> Void = { _ in }) async throws -> Output {
        guard URLGuard.isAllowed(url, allowLocal: allowLocal) else {
            throw WebSession.SessionError.blocked(url.absoluteString)
        }
        let page = WebSession(width: PagePreset.web.pageSize.width, height: 1400, javaScript: true, allowLocal: allowLocal)
        defer { page.close() }
        var notes: [String] = []

        progress("Opening the page")
        try await page.load(url)
        await page.settle()

        // Pages that are a frame around the real content (Hugging Face Spaces, embeds).
        if let inner = try? await page.jsString(followFrameJS), let innerURL = URL(string: inner),
           innerURL != page.currentURL, URLGuard.isAllowed(innerURL, allowLocal: allowLocal) {
            progress("Opening the embedded page")
            try await page.load(innerURL)
            await page.settle()
            notes.append("Followed the embedded page at \(innerURL.host() ?? innerURL.absoluteString).")
        }

        // Work on the live page as little as possible: some pages (scroll-driven charts) peg
        // their own main thread and stop answering. Prepare, snapshot the DOM, picture the
        // embedded frames, then do everything else on a frozen copy with page scripts off.
        progress("Loading images")
        _ = try? await page.js(prepareJS, timeout: 8)
        _ = try? await page.js(freezeCanvasJS, timeout: 8)
        let frameCount = (try? await page.js(markFramesJS, timeout: 5)) as? Int ?? 0
        let snapshotHTML: String
        do {
            snapshotHTML = try await page.jsString(snapshotJS, timeout: 15)
        } catch {
            throw EzPDFError.failed("The page didn't respond, so it couldn't be saved.")
        }
        let finalURL = page.currentURL ?? url
        var frameImages: [Int: String] = [:]
        if frameCount > 0 {
            progress("Capturing embedded charts")
            frameImages = await captureFrames(page, count: frameCount)
        }
        page.close()
        return try await finish(snapshotHTML: snapshotHTML, finalURL: finalURL, frameImages: frameImages,
                                frameCount: frameCount, preset: preset, format: format, allowLocal: allowLocal,
                                notes: notes, progress: progress)
    }

    /// Converts HTML captured elsewhere, e.g. the page as you see it in your browser, including
    /// pages behind a login that ezpdf itself couldn't open.
    public static func convert(html: String, url: URL, preset: PagePreset, format: OutputFormat = .pdf,
                               progress: @escaping @MainActor (String) -> Void = { _ in }) async throws -> Output {
        let cleaned = html.replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: "", options: [.regularExpression, .caseInsensitive])
        return try await finish(snapshotHTML: cleaned, finalURL: url, frameImages: [:], frameCount: 0, preset: preset,
                                format: format, allowLocal: false, notes: [], progress: progress)
    }

    static func finish(snapshotHTML: String, finalURL: URL, frameImages: [Int: String], frameCount: Int,
                       preset: PagePreset, format: OutputFormat, allowLocal: Bool, notes: [String],
                       progress: @escaping @MainActor (String) -> Void) async throws -> Output {
        var notes = notes

        let snap = WebSession(width: PagePreset.web.pageSize.width, height: 1400, javaScript: false, allowLocal: allowLocal)
        defer { snap.close() }
        try await snap.loadHTML(snapshotHTML, baseURL: finalURL)
        _ = try? await snap.js(replaceFramesJS, ["images": Dictionary(uniqueKeysWithValues: frameImages.map { (String($0.key), $0.value) })])
        if frameCount > frameImages.count, frameCount > 0 {
            notes.append("\(frameCount - frameImages.count) embedded chart(s) couldn't be captured.")
        }

        var article: Article?
        if preset != .web || format != .pdf {
            progress("Finding the article")
            article = try? await extractArticle(snap, sourceURL: finalURL)
            if let a = article, a.textLength < 350 { article = nil }
        }

        let title: String
        let pdf: Data
        var usedReader = false
        if preset != .web, let article {
            progress("Laying out pages")
            let r = try await renderArticle(article, preset: preset)
            pdf = r.pdf
            if r.truncated { notes.append("The article was very long, so only the first part was saved.") }
            title = article.title
            usedReader = true
        } else {
            if preset != .web { notes.append("This page isn't an article, so it was saved as it looks on the web.") }
            progress("Capturing the page")
            let pageTitle = ((try? await snap.jsString("return document.title")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            title = pageTitle.isEmpty ? (finalURL.host() ?? "Web page") : pageTitle
            _ = try? await snap.js(hideOverlaysJS)
            await scrollThrough(snap)
            await snap.waitForImages()
            let w = PagePreset.web.pageSize.width
            let r = try await PageLayout.renderPDF(session: snap, pageSize: PagePreset.web.pageSize, margin: 0,
                                                   contentWidth: w, metadata: .init(title: title, author: nil, subject: finalURL.absoluteString))
            pdf = r.pdf
            if r.truncated { notes.append("The page was very long, so only the first part was saved.") }
        }

        var epub: Data?
        if format != .pdf {
            if let article {
                progress("Making the EPUB")
                epub = try await EPUBBuilder.build(article: article, allowLocal: allowLocal)
            } else {
                notes.append("No EPUB: the page has no readable article text.")
            }
        }
        return Output(pdf: pdf, epub: epub, article: article, title: title, usedReader: usedReader,
                      finalURL: finalURL, notes: notes)
    }

    /// Pictures each marked iframe (interactive charts, embeds) as a PNG, since a PDF can't run
    /// them. Stops at the first frame the page won't answer for.
    static func captureFrames(_ page: WebSession, count: Int) async -> [Int: String] {
        var out: [Int: String] = [:]
        var total = 0
        let budget = 12 * 1024 * 1024
        for i in 0..<min(count, 16) {
            guard let json = try? await page.jsString("""
                const f = document.querySelector('[data-ez-frame="\(i)"]');
                if (!f) return '';
                f.scrollIntoView({ block: 'center' });
                return 'ok';
                """, timeout: 4), !json.isEmpty else { break }
            try? await Task.sleep(for: .milliseconds(1500))
            guard let r = try? await page.jsString("""
                const f = document.querySelector('[data-ez-frame="\(i)"]');
                const r = f.getBoundingClientRect();
                return JSON.stringify([r.left + scrollX, r.top + scrollY, r.width, r.height]);
                """, timeout: 4),
                  let a = try? JSONSerialization.jsonObject(with: Data(r.utf8)) as? [Double], a.count == 4 else { break }
            guard a.allSatisfy(\.isFinite) else { break }
            let rect = CGRect(x: a[0], y: a[1], width: min(a[2], 1400), height: min(a[3], 1800))
            guard let pdf = try? await page.pdf(rect: rect, timeout: 8),
                  let jpeg = PDFRaster.jpeg(fromPDF: pdf, scale: 1.5) else { break }
            total += jpeg.count
            if total > budget { break }       // enough charts; the rest are left out with a note
            out[i] = "data:image/jpeg;base64," + jpeg.base64EncodedString()
        }
        return out
    }

    /// Compiles the private-network block list (diagnostics).
    public static func checkRules() async throws { _ = try await WebSession.ruleList() }

    // MARK: Article

    static func extractArticle(_ page: WebSession, sourceURL: URL) async throws -> Article? {
        let json = try await page.jsString(Scripts.readability + "\n" + extractJS)
        guard let data = json.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? String, !content.isEmpty else { return nil }
        func s(_ k: String) -> String? {
            let v = (obj[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (v?.isEmpty ?? true) ? nil : v
        }
        return Article(title: s("title") ?? sourceURL.host() ?? "Article", byline: s("byline"),
                       siteName: s("siteName"), excerpt: s("excerpt"), publishedTime: s("publishedTime"),
                       lang: s("lang"), html: content, textLength: obj["length"] as? Int ?? 0, sourceURL: sourceURL)
    }

    /// Lays out an article (or any body HTML) for a preset and returns the PDF.
    public static func renderArticle(_ article: Article, preset: PagePreset) async throws -> (pdf: Data, truncated: Bool) {
        let r = try await renderHTMLBody(article.html, title: article.title, preset: preset, baseURL: article.sourceURL,
                                 header: ArticleHTML.header(for: article), author: article.byline,
                                 subject: article.sourceURL.absoluteString, lang: article.lang)
        return (r.pdf, r.truncated)
    }

    static func renderHTMLBody(_ body: String, title: String, preset: PagePreset, baseURL: URL?,
                               header: String, author: String?, subject: String?, lang: String?) async throws -> (pdf: Data, truncated: Bool, slices: [Range<Double>]) {
        let p = preset == .web ? PagePreset.letter : preset
        let html = ArticleHTML.document(body: body, header: header, title: title, preset: p, lang: lang)
        let layout = WebSession(width: p.contentSize.width, height: p.contentSize.height, javaScript: false)
        defer { layout.close() }
        try await layout.loadHTML(html, baseURL: baseURL)
        await layout.waitForImages()
        _ = try? await layout.js(fitWideJS)
        return try await PageLayout.renderPDF(session: layout, pageSize: p.pageSize, margin: p.margin,
                                              contentWidth: p.contentSize.width,
                                              metadata: .init(title: title, author: author, subject: subject))
    }

    private static func scrollThrough(_ page: WebSession) async {
        let height = (try? await page.js("return Math.min(Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0), 60000)")) as? Double ?? 0
        var y = 0.0
        while y < height {
            _ = try? await page.js("window.scrollTo(0, \(Int(y)))")
            try? await Task.sleep(for: .milliseconds(90))
            y += 1200
        }
        _ = try? await page.js("window.scrollTo(0, 0)")
    }

    // MARK: Scripts

    static let followFrameJS = """
    const frames = Array.from(document.querySelectorAll('iframe[src]')).map(f => {
      const r = f.getBoundingClientRect(); return { src: f.src, a: r.width * r.height };
    }).filter(f => /^https?:/.test(f.src)).sort((a, b) => b.a - a.a);
    const big = frames[0];
    if (!big) return null;
    const text = (document.body && document.body.innerText || '').length;
    const isSpace = location.hostname === 'huggingface.co' && location.pathname.startsWith('/spaces/');
    if (isSpace || (big.a > innerWidth * innerHeight * 0.45 && text < 2500)) return big.src;
    return null;
    """

    /// Eager images, real sources for lazy ones, and math converted to native MathML
    /// (WebKit renders MathML itself, so formulas survive cleanup and print sharply).
    static let prepareJS = """
    document.querySelectorAll('img').forEach(img => {
      img.loading = 'eager';
      ['data-src','data-original','data-lazy-src','data-url'].forEach(k => {
        const v = img.getAttribute(k); if (v && (!img.getAttribute('src') || img.src.startsWith('data:'))) img.setAttribute('src', v);
      });
      const ds = img.getAttribute('data-srcset'); if (ds && !img.getAttribute('srcset')) img.setAttribute('srcset', ds);
    });
    document.querySelectorAll('.katex-display, .katex').forEach(k => {
      if (!k.isConnected) return;
      const m = k.querySelector('.katex-mathml math');
      if (!m) return;
      const c = m.cloneNode(true);
      const display = k.classList.contains('katex-display') || !!k.closest('.katex-display');
      if (display) c.setAttribute('display', 'block');
      (k.closest('.katex-display') || k).replaceWith(c);
    });
    document.querySelectorAll('mjx-container').forEach(k => {
      const m = k.querySelector('mjx-assistive-mml math');
      if (!m) return;
      const c = m.cloneNode(true);
      if (k.getAttribute('display') === 'true') c.setAttribute('display', 'block');
      k.replaceWith(c);
    });
    return true;
    """

    static let freezeCanvasJS = """
    document.querySelectorAll('canvas').forEach(c => {
      const r = c.getBoundingClientRect();
      if (r.width < 24 || r.height < 24) return;
      try {
        const img = document.createElement('img');
        img.src = c.toDataURL('image/png');
        img.width = Math.round(r.width); img.height = Math.round(r.height);
        c.replaceWith(img);
      } catch (e) {}
    });
    return true;
    """

    /// Shrinks tables, formulas and code wider than the page instead of letting them be cut off.
    static let fitWideJS = """
    const cw = document.body.clientWidth;
    document.querySelectorAll('table, math[display="block"], pre').forEach(t => {
      const w = t.scrollWidth;
      if (w > cw + 2) t.style.zoom = String(Math.max(0.45, cw / w));
    });
    return true;
    """

    static let markFramesJS = """
    const frames = Array.from(document.querySelectorAll('iframe')).filter(f => {
      const r = f.getBoundingClientRect(); return r.width >= 120 && r.height >= 80;
    });
    frames.forEach((f, i) => f.setAttribute('data-ez-frame', String(i)));
    return frames.length;
    """

    /// The settled DOM as HTML, minus scripts (the copy is shown with scripts off anyway) and
    /// <noscript> fallbacks, which would otherwise appear.
    static let snapshotJS = """
    const c = document.documentElement.cloneNode(true);
    c.querySelectorAll('script, noscript').forEach(e => e.remove());
    return '<!doctype html>' + c.outerHTML;
    """

    static let replaceFramesJS = """
    document.querySelectorAll('[data-ez-frame]').forEach(f => {
      const src = images[f.getAttribute('data-ez-frame')];
      if (!src) { f.remove(); return; }
      const fig = document.createElement('figure');
      const img = document.createElement('img');
      img.src = src;
      img.style.width = '100%';
      fig.appendChild(img);
      f.replaceWith(fig);
    });
    return true;
    """

    static let hideOverlaysJS = """
    document.querySelectorAll('body *').forEach(e => {
      const s = getComputedStyle(e);
      if (s.position === 'fixed') e.style.setProperty('display', 'none', 'important');
      else if (s.position === 'sticky') e.style.setProperty('position', 'static', 'important');
    });
    document.documentElement.style.setProperty('overflow', 'visible', 'important');
    if (document.body) document.body.style.setProperty('overflow', 'visible', 'important');
    return true;
    """

    static let extractJS = """
    const clone = document.cloneNode(true);
    const r = new Readability(clone, { charThreshold: 300, keepClasses: false }).parse();
    if (!r) return JSON.stringify({});
    return JSON.stringify({
      title: r.title, byline: r.byline, siteName: r.siteName, excerpt: r.excerpt,
      publishedTime: r.publishedTime, lang: r.lang || document.documentElement.lang,
      content: r.content, length: r.length
    });
    """
}

extension String {
    /// The HTML with inline (data:) images removed, for storing on disk; the PDF already has them.
    var strippingInlineImages: String {
        replacingOccurrences(of: #"src=\"data:image/[^\"]{2048,}\""#, with: "src=\"\"", options: .regularExpression)
    }
}

enum Scripts {
    static let readability: String = {
        guard let url = Bundle.module.url(forResource: "Readability", withExtension: "js"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return s
    }()

    static let readerCSS: String = {
        guard let url = Bundle.module.url(forResource: "reader", withExtension: "css"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return s
    }()
}

/// Builds the HTML document the layout web view prints.
enum ArticleHTML {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func header(for a: WebConverter.Article) -> String {
        var parts: [String] = []
        if let site = a.siteName { parts.append("<p class=\"ez-site\">\(escape(site))</p>") }
        parts.append("<h1 class=\"ez-title\">\(escape(a.title))</h1>")
        var line: [String] = []
        if let b = a.byline { line.append(escape(b)) }
        if let d = formattedDate(a.publishedTime) { line.append(escape(d)) }
        if !line.isEmpty { parts.append("<p class=\"ez-byline\">\(line.joined(separator: " · "))</p>") }
        parts.append("<p class=\"ez-source\">\(escape(a.sourceURL.absoluteString))</p>")
        return "<header>\(parts.joined())</header>"
    }

    static func header(title: String, subtitle: String?) -> String {
        var s = "<header><h1 class=\"ez-title\">\(escape(title))</h1>"
        if let subtitle { s += "<p class=\"ez-byline\">\(escape(subtitle))</p>" }
        return s + "</header>"
    }

    static func formattedDate(_ iso: String?) -> String? {
        guard let iso else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = f.date(from: iso) ?? { f.formatOptions = [.withInternetDateTime]; return f.date(from: iso) }()
            ?? { f.formatOptions = [.withFullDate]; return f.date(from: String(iso.prefix(10))) }()
        guard let date else { return nil }
        return date.formatted(date: .long, time: .omitted)
    }

    static func document(body: String, header: String, title: String, preset: PagePreset, lang: String?) -> String {
        let vars = ":root{--fs:\(preset.fontSize)px;--content-w:\(preset.contentSize.width)px;--page-h:\(preset.contentSize.height)px}"
        return """
        <!doctype html><html lang="\(escape(lang ?? "en"))"><head><meta charset="utf-8">
        <title>\(escape(title))</title><style>\(vars)</style><style>\(Scripts.readerCSS)</style></head>
        <body><article>\(header)\(body)</article></body></html>
        """
    }
}
