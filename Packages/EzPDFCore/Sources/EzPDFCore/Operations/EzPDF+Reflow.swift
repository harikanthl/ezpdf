import Foundation
import PDFKit
import CryptoKit

// MARK: Reflowing a web article

/// A document made from a web page keeps the article it was laid out from (`article.html`). A
/// change that needs more room than its line and paragraph have (fixed positions on a PDF page)
/// can be made there instead: the text is changed in the article and the whole article is laid
/// out again, so everything after it moves along, across pages.
///
/// Each laid-out version remembers the article it came from (keyed by the PDF's SHA-256), so
/// Undo and Redo of a reflow keep the PDF and its article in step, and a later reflow builds on
/// the right one.
extension EzPDF {
    /// The document was made from a web page and its article is kept.
    public func canReflow(_ id: String) -> Bool {
        guard let rec = try? record(id), rec.kind == .web, rec.sourceURL != nil else { return false }
        return FileManager.default.fileExists(atPath: library.articleURL(for: rec.id).path)
    }

    /// Changes made directly on the pages since the article was last laid out (edits, highlights,
    /// signatures, filled fields): a reflow can't carry them over. Empty when there are none.
    public func pageChangesSinceLayout(_ id: String) throws -> [String] {
        let rec = try record(id, strict: true)
        guard let pdf = try? Data(contentsOf: library.pdfURL(for: rec.id)) else { return [] }
        var changes: [String] = []
        if reflowArticle(for: pdf, id: rec.id) == nil {
            // Not a version a reflow made: any logged change since the last reflow (or ever) counts.
            let events = (try? history(rec.id, limit: 2000)) ?? []
            let sinceLayout = events.prefix { $0.action != Self.reflowAction }
            // Earlier versions kept for Undo mean the pages were changed (also before changes were logged).
            if !sinceLayout.isEmpty || canUndo(rec.id) { changes.append("changes made on the pages") }
        }
        if let doc = PDFDocument(data: pdf) {
            let notes = (0..<doc.pageCount).reduce(0) { $0 + (doc.page(at: $1)?.annotations.count ?? 0) }
            if notes > 0 { changes.append("\(notes) highlight\(notes == 1 ? "" : "s"), note\(notes == 1 ? "" : "s") or field\(notes == 1 ? "" : "s")") }
        }
        return changes
    }

    static let reflowAction = "Reflow article"

    /// Changes `find` to `replacement` in the article (whole words, every place it appears as one
    /// run of text) and lays the whole article out again in the document's page size. Throws when
    /// the words aren't in the article's text. Page-level changes since the last layout are replaced;
    /// callers ask first (see `pageChangesSinceLayout`).
    @discardableResult
    public func reflowArticle(_ id: String, find: String, with replacement: String,
                              context: ArticleEdit.Context? = nil) async throws -> (record: DocumentRecord, count: Int) {
        let rec = try record(id, strict: true)
        guard canReflow(rec.id), let source = rec.sourceURL.flatMap(URL.init(string:)) else {
            throw EzPDFError.invalidInput("“\(rec.title)” wasn’t made from a web page, so it can’t be laid out again.")
        }
        let current = (try? Data(contentsOf: library.pdfURL(for: rec.id))) ?? Data()
        let base = try reflowArticle(for: current, id: rec.id) ?? String(contentsOf: library.articleURL(for: rec.id), encoding: .utf8)
        var (html, count) = ArticleEdit.replace(in: base, find: find, with: replacement, context: context)
        if count == 0, context != nil {
            // The words around it may cross a link or formatting: fine if the words themselves are there once.
            let plain = ArticleEdit.replace(in: base, find: find, with: replacement)
            guard plain.1 <= 1 else {
                throw EzPDFError.invalidInput("“\(find)” appears \(plain.1) times in the article and the words around the selection didn’t pick one. Select a few more words around it.")
            }
            (html, count) = plain
        }
        guard count > 0 else {
            throw EzPDFError.invalidInput("“\(find)” isn’t in the article as one run of text (it may be split by a link or formatting). Select a shorter part of it.")
        }
        let preset = rec.preset.flatMap(PagePreset.init(rawValue:)) ?? .kindle
        let article = WebConverter.Article(title: rec.title, byline: rec.byline, siteName: rec.siteName, excerpt: rec.excerpt,
                                           publishedTime: nil, lang: ArticleEdit.lang(of: base), html: html,
                                           textLength: html.count, sourceURL: source)
        let rendered = try await WebConverter.renderArticle(article, preset: preset)
        let who = EzPDF.actor.map { EzPDF.Actor(by: $0.by, action: Self.reflowAction, detail: $0.detail) }
            ?? EzPDF.Actor(by: "You", action: Self.reflowAction, detail: "\(find) → \(replacement)")
        let saved = try EzPDF.$actor.withValue(who) { try commitEditData(rec.id, rendered.pdf) }
        // Remember which article this version came from (and which the version before it did).
        if reflowArticle(for: current, id: rec.id) == nil, let original = try? String(contentsOf: library.articleURL(for: rec.id), encoding: .utf8) {
            try? saveReflowArticle(original, for: current, id: rec.id)
        }
        if let now = try? Data(contentsOf: library.pdfURL(for: rec.id)) { try saveReflowArticle(html, for: now, id: rec.id) }
        return (saved, count)
    }

    /// Reflows the article with a selection made in the reader changed: the words just before and
    /// after the selection pick out which place in the article it was.
    @discardableResult
    public func reflowSelection(_ id: String, _ info: EditOps.SelectionInfo, with text: String) async throws -> DocumentRecord {
        let (rec, doc) = try document(id)
        // Read the selection as the page shows it, without words left hidden by older edits.
        EditOps.removeHiddenText(doc, pages: [info.page])
        guard let page = doc.page(at: info.page), let first = info.lines.first, let last = info.lines.last else {
            throw EzPDFError.invalidInput("That page is gone; select the text again.")
        }
        let space = EditOps.PageSpace(page)
        var context: ArticleEdit.Context?
        if let sel = page.selection(from: space.pagePoint(CGPoint(x: first.minX + 0.5, y: first.midY)),
                                    to: space.pagePoint(CGPoint(x: last.maxX - 0.5, y: last.midY))),
           let before = sel.copy() as? PDFSelection, let after = sel.copy() as? PDFSelection {
            let inner = sel.string ?? ""
            before.extend(atStart: 40); after.extend(atEnd: 40)
            let b = (before.string ?? "").dropLast(inner.count), a = (after.string ?? "").dropFirst(inner.count)
            context = ArticleEdit.Context(before: b.split(whereSeparator: \.isWhitespace).suffix(2).joined(separator: " "),
                                          after: a.split(whereSeparator: \.isWhitespace).prefix(2).joined(separator: " "))
        }
        let shown = page.selection(from: space.pagePoint(CGPoint(x: first.minX + 0.5, y: first.midY)),
                                   to: space.pagePoint(CGPoint(x: last.maxX - 0.5, y: last.midY)))?.string ?? info.text
        let find = shown.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return try await reflowArticle(rec.id, find: find, with: text, context: context).record
    }

    private func reflowFolder(_ id: String) -> URL { library.folder(for: id).appendingPathComponent("articles", isDirectory: true) }

    private func reflowKey(_ pdf: Data) -> String {
        SHA256.hash(data: pdf).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The article a laid-out version came from, if a reflow made (or started from) it.
    func reflowArticle(for pdf: Data, id: String) -> String? {
        guard !pdf.isEmpty else { return nil }
        return try? String(contentsOf: reflowFolder(id).appendingPathComponent(reflowKey(pdf) + ".html"), encoding: .utf8)
    }

    private func saveReflowArticle(_ html: String, for pdf: Data, id: String) throws {
        let folder = reflowFolder(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try html.write(to: folder.appendingPathComponent(reflowKey(pdf) + ".html"), atomically: true, encoding: .utf8)
    }
}

/// Text changes in an article's HTML: only in the text between tags, never in tags or attributes.
public enum ArticleEdit {
    /// The words just before and after a change, to pick one place among several.
    public struct Context: Sendable {
        public var before: String
        public var after: String
    }

    /// A regex for text as it is in HTML: escaped, any run of spaces matching spaces or &nbsp;.
    static func pattern(_ text: String) -> String {
        NSRegularExpression.escapedPattern(for: escape(text)).replacingOccurrences(of: " ", with: "(?:\\s|&nbsp;|&#160;)+")
    }

    /// Replaces whole-word occurrences of `find` in the article's text (only where `context`'s words
    /// sit around it, when given). Returns the new HTML and how many changed.
    static func replace(in html: String, find: String, with replacement: String, context: Context? = nil) -> (String, Int) {
        let trimmed = find.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (html, 0) }
        let space = "(?:\\s|&nbsp;|&#160;)*"
        let before = context.map { $0.before.isEmpty ? "" : pattern($0.before) + space } ?? ""
        let after = context.map { $0.after.isEmpty ? "" : space + pattern($0.after) } ?? ""
        let core = "(?<![\\p{L}\\p{N}])" + pattern(trimmed) + "(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: "(" + before + ")" + core + "(" + after + ")") else { return (html, 0) }
        let template = "$1" + NSRegularExpression.escapedTemplate(for: escape(replacement)) + "$2"
        var out = ""
        var count = 0
        var inSkipped: String?   // inside <script> or <style>
        var rest = Substring(html)
        while !rest.isEmpty {
            if rest.first == "<", let close = rest.firstIndex(of: ">") {
                let tag = rest[...close]
                let lower = tag.lowercased()
                if let skipped = inSkipped { if lower.hasPrefix("</\(skipped)") { inSkipped = nil } }
                else if lower.hasPrefix("<script") { inSkipped = "script" }
                else if lower.hasPrefix("<style") { inSkipped = "style" }
                out += tag
                rest = rest[rest.index(after: close)...]
                continue
            }
            let end = rest.firstIndex(of: "<") ?? rest.endIndex
            let text = String(rest[..<end])
            if inSkipped == nil {
                let range = NSRange(text.startIndex..., in: text)
                let n = regex.numberOfMatches(in: text, range: range)
                if n > 0 {
                    count += n
                    out += regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
                } else { out += text }
            } else { out += text }
            rest = rest[end...]
            if rest.first == "<", rest.firstIndex(of: ">") == nil { out += rest; break }
        }
        return (out, count)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// The article's language from its first lang attribute.
    static func lang(of html: String) -> String? {
        guard let r = html.range(of: #"lang="([A-Za-z-]{2,12})""#, options: .regularExpression) else { return nil }
        return String(html[r].dropFirst(6).dropLast())
    }
}
