import Foundation
import PDFKit
import Observation

/// Where a request came from, shown on its job row.
public enum JobSource: String, Codable, Sendable { case app, agent, browser, shortcut, cli }

@Observable
public final class Job: Identifiable, @unchecked Sendable {
    public enum State: Equatable, Sendable { case running, done, failed(String) }
    public let id = UUID()
    public var title: String
    public var detail: String
    public var state: State = .running
    public var documentID: String?
    public let source: JobSource
    public let startedAt = Date()
    public var notes: [String] = []

    init(title: String, source: JobSource) {
        self.title = title
        self.detail = "Starting"
        self.source = source
    }
}

/// Every ezpdf feature as one async function. The SwiftUI app, App Intents, the browser
/// extension and the MCP server all call these, so each surface can do what the others can.
@MainActor
@Observable
public final class EzPDF {
    public static let shared = EzPDF()

    public let library: Library
    public private(set) var jobs: [Job] = []
    /// Posted when a caller asks the app to show a document (object: ["id": String, "page": Int]).
    public static let openRequest = Notification.Name("EzPDFOpenRequest")

    public var defaultPreset: PagePreset {
        get { PagePreset(rawValue: UserDefaults.standard.string(forKey: "ezpdf.preset") ?? "") ?? .kindle }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "ezpdf.preset") }
    }
    public var defaultFormat: OutputFormat {
        get { OutputFormat(rawValue: UserDefaults.standard.string(forKey: "ezpdf.format") ?? "") ?? .both }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "ezpdf.format") }
    }
    public var exportFolder: URL {
        get {
            if let p = UserDefaults.standard.string(forKey: "ezpdf.exportFolder") { return URL(fileURLWithPath: p) }
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
        set { UserDefaults.standard.set(newValue.path, forKey: "ezpdf.exportFolder") }
    }

    public init(library: Library = .shared) { self.library = library }
    /// Full-text search over the library (in the library folder).
    @ObservationIgnored lazy var searchIndex = SearchIndex(path: library.root.appendingPathComponent(".search.sqlite"))

    func indexDocuments() -> [SearchIndex.Document] {
        library.all().map { SearchIndex.Document(id: $0.id, title: $0.title, url: library.pdfURL(for: $0.id), modified: $0.modifiedAt) }
    }

    /// Indexes the library in the background, reading scanned pages too, so later searches find them.
    public func refreshSearchIndex() async {
        try? await searchIndex.refresh(indexDocuments(), ocr: true)
    }

    /// Fonts made ready per document this launch (see `prepareFonts`).
    @ObservationIgnored var fontsPrepared: [String: [Fonts.Status]] = [:]

    // MARK: Jobs

    /// Conversions open web views and use a lot of memory; this many may run at once.
    static let maxConcurrentConversions = 3
    private var activeConversions = 0

    private func run<T>(_ title: String, source: JobSource, conversion: Bool = false, observe: ((Job) -> Void)? = nil,
                        _ body: (Job) async throws -> T) async throws -> T {
        if conversion {
            guard activeConversions < Self.maxConcurrentConversions else {
                throw EzPDFError.unavailable("ezpdf is already converting \(activeConversions) things. Try again when one finishes.")
            }
            activeConversions += 1
        }
        defer { if conversion { activeConversions -= 1 } }
        let job = Job(title: title, source: source)
        jobs.insert(job, at: 0)
        observe?(job)
        do {
            let value = try await body(job)
            job.state = .done
            job.detail = "Done"
            trimJobs()
            return value
        } catch {
            job.state = .failed(error.localizedDescription)
            job.detail = error.localizedDescription
            trimJobs()
            throw error
        }
    }

    private func trimJobs() {
        // Keep finished jobs briefly so their rows can show the result, then drop them.
        let cutoff = Date().addingTimeInterval(-600)
        jobs.removeAll { $0.state != .running && $0.startedAt < cutoff }
        // Over the cap, drop the oldest finished jobs; never a running one.
        while jobs.count > 30, let i = jobs.lastIndex(where: { $0.state != .running }) { jobs.remove(at: i) }
    }

    public func dismissJob(_ id: UUID) { jobs.removeAll { $0.id == id } }

    // MARK: Convert

    @discardableResult
    public func convert(url: URL, preset: PagePreset? = nil, format: OutputFormat? = nil, title: String? = nil,
                        source: JobSource = .app, observe: ((Job) -> Void)? = nil) async throws -> DocumentRecord {
        let preset = preset ?? defaultPreset
        let format = format ?? defaultFormat
        guard await URLGuard.resolvesPublic(url) else {
            throw EzPDFError.invalidInput("ezpdf doesn't open addresses on your local network.")
        }
        return try await run(url.host() ?? url.absoluteString, source: source, conversion: true, observe: observe) { job in
            // A link straight to a PDF (statements, papers): keep the file itself.
            if let pdf = try await Self.downloadIfPDF(url) {
                job.detail = "Saving the PDF"
                let name = url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
                let docTitle = title ?? (PDFDocument(data: pdf)?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
                var rec = DocumentRecord(title: docTitle, kind: .imported, sourceURL: url.absoluteString, siteName: url.host())
                rec = try library.add(rec, pdfData: pdf)
                job.title = rec.title
                job.documentID = rec.id
                return rec
            }
            let out = try await WebConverter.convert(url: url, preset: preset, format: format) { job.detail = $0 }
            job.title = title ?? out.title
            job.notes = out.notes
            var rec = DocumentRecord(title: title ?? out.title, kind: .web, sourceURL: url.absoluteString,
                                     byline: out.article?.byline, siteName: out.article?.siteName ?? out.finalURL.host(),
                                     excerpt: out.article?.excerpt, preset: preset.rawValue)
            rec = try library.add(rec, pdfData: out.pdf, epubData: out.epub, articleHTML: out.article?.html.strippingInlineImages)
            job.documentID = rec.id
            return rec
        }
    }

    /// The page as the browser already shows it (works behind logins).
    @discardableResult
    public func convert(html: String, url: URL, preset: PagePreset? = nil, format: OutputFormat? = nil, title: String? = nil,
                        source: JobSource = .browser, observe: ((Job) -> Void)? = nil) async throws -> DocumentRecord {
        let preset = preset ?? defaultPreset
        let format = format ?? defaultFormat
        guard html.utf8.count <= 20_000_000 else { throw EzPDFError.invalidInput("That page is too large to convert.") }
        return try await run(url.host() ?? "Page", source: source, conversion: true, observe: observe) { job in
            let out = try await WebConverter.convert(html: html, url: url, preset: preset, format: format) { job.detail = $0 }
            job.title = title ?? out.title
            job.notes = out.notes
            var rec = DocumentRecord(title: title ?? out.title, kind: .web, sourceURL: url.absoluteString,
                                     byline: out.article?.byline, siteName: out.article?.siteName ?? url.host(),
                                     excerpt: out.article?.excerpt, preset: preset.rawValue)
            rec = try library.add(rec, pdfData: out.pdf, epubData: out.epub, articleHTML: out.article?.html.strippingInlineImages)
            job.documentID = rec.id
            return rec
        }
    }

    /// If `url` serves a PDF, returns its bytes (one request, redirects re-checked, 300 MB cap).
    static func downloadIfPDF(_ url: URL) async throws -> Data? {
        let dl = GuardedDownload()
        defer { dl.finish() }
        let looksPDF = url.pathExtension.lowercased() == "pdf"
        let outcome: GuardedDownload.Outcome
        do {
            outcome = try await dl.fetch(url, maxBytes: 300_000_000) { resp in
                resp.mimeType == "application/pdf" || (looksPDF && resp.mimeType == "application/octet-stream")
            }
        } catch {
            if looksPDF { throw error }
            return nil   // not a PDF link, or HEAD-less server hiccup: let the web view handle it
        }
        switch outcome {
        case .data(let data, _): return data.starts(with: Data("%PDF".utf8)) ? data : nil
        case .tooLarge: throw EzPDFError.invalidInput("That PDF is over 300 MB.")
        case .skipped: return nil
        }
    }

    @discardableResult
    public func convert(files: [URL], preset: PagePreset? = nil, title: String? = nil,
                        source: JobSource = .app) async throws -> DocumentRecord {
        let preset = preset ?? defaultPreset
        guard let first = files.first else { throw EzPDFError.invalidInput("No files given.") }
        for f in files where !FileManager.default.isReadableFile(atPath: f.path) {
            throw EzPDFError.invalidInput("Can't read \(f.path).")
        }
        return try await run(first.lastPathComponent, source: source, conversion: true) { job in
            job.detail = files.count > 1 ? "Combining \(files.count) files" : "Converting"
            let out = try await FileConverter.convert(files, preset: preset)
            let kind: DocumentRecord.Kind = first.pathExtension.lowercased() == "pdf" && files.count == 1 ? .imported : .file
            var rec = DocumentRecord(title: title ?? out.title, kind: kind, sourceFileName: first.lastPathComponent, preset: preset.rawValue)
            rec = try library.add(rec, pdfData: out.pdf)
            job.title = rec.title
            job.documentID = rec.id
            return rec
        }
    }

    /// For remote callers that send file bytes instead of a path.
    @discardableResult
    public func convert(data: Data, fileName: String, preset: PagePreset? = nil, source: JobSource = .agent) async throws -> DocumentRecord {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ezpdf-in-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let name = (fileName as NSString).lastPathComponent.isEmpty ? "upload" : (fileName as NSString).lastPathComponent
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return try await convert(files: [url], preset: preset, source: source)
    }

    // MARK: Read

    public func list(query: String? = nil, kind: DocumentRecord.Kind? = nil, limit: Int = 50) -> [DocumentRecord] {
        var docs = library.all()
        if let kind { docs = docs.filter { $0.kind == kind } }
        if let q = query?.lowercased(), !q.isEmpty {
            docs = docs.filter { "\($0.title) \($0.siteName ?? "") \($0.sourceURL ?? "") \($0.sourceFileName ?? "")".lowercased().contains(q) }
        }
        return Array(docs.prefix(max(1, limit)))
    }

    /// Finds a document by id or title. A title must match one document; with `strict` (anything
    /// that changes or deletes), only an exact id or an exact, unique title is accepted.
    public func record(_ id: String, strict: Bool = false) throws -> DocumentRecord {
        let m = library.matches(id)
        switch m {
        case .id(let r): return r
        case .exactTitles(let rs) where rs.count == 1: return rs[0]
        case .partialTitles(let rs) where rs.count == 1 && !strict: return rs[0]
        case .none: throw EzPDFError.notFound(id)
        case .exactTitles(let rs), .partialTitles(let rs):
            if strict, case .partialTitles = m, rs.count == 1 {
                throw EzPDFError.invalidInput("To change or delete “\(rs[0].title)”, pass its id: \(rs[0].id).")
            }
            let list = rs.prefix(5).map { "“\($0.title)” (id \($0.id))" }.joined(separator: ", ")
            throw EzPDFError.invalidInput("“\(id)” matches \(rs.count) documents: \(list). Pass the id.")
        }
    }

    public func document(_ id: String, strict: Bool = false) throws -> (DocumentRecord, PDFDocument) {
        let rec = try record(id, strict: strict)
        guard let doc = PDFDocument(url: library.pdfURL(for: rec.id)) else { throw EzPDFError.failed("The PDF for “\(rec.title)” is missing or damaged.") }
        if doc.isLocked { throw EzPDFError.invalidInput("“\(rec.title)” has a password. Unlock it first (improve_pdf unlock).") }
        return (rec, doc)
    }

    public struct OutlineEntry: Codable, Sendable { public var title: String; public var page: Int; public var level: Int }

    public func outline(_ id: String) throws -> [OutlineEntry] {
        let (_, doc) = try document(id)
        var out: [OutlineEntry] = []
        func walk(_ node: PDFOutline, _ level: Int) {
            for i in 0..<node.numberOfChildren {
                guard let c = node.child(at: i) else { continue }
                let page = c.destination?.page.map { doc.index(for: $0) + 1 } ?? 0
                out.append(OutlineEntry(title: c.label ?? "", page: page, level: level))
                if out.count < 400 { walk(c, level + 1) }
            }
        }
        if let root = doc.outlineRoot { walk(root, 1) }
        return out
    }

    /// Text of the given pages ("1-3,5"), OCR'ing scanned pages, capped at `maxChars`.
    public func text(_ id: String, pages: String? = nil, maxChars: Int = 50_000) async throws -> (text: String, truncated: Bool, pages: [Int]) {
        let (_, doc) = try document(id)
        let indices = try PageOps.pages(pages, count: doc.pageCount)
        var parts: [String] = []
        var total = 0
        var used: [Int] = []
        for i in indices {
            guard let page = doc.page(at: i) else { continue }
            var t = page.string ?? ""
            if t.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 {
                // Scanned: read in reading order (paragraphs, columns in turn).
                if let read = try? await DocumentReader.read(page: page, index: i), !read.paragraphs.isEmpty {
                    t = read.text
                } else {
                    t = await PageText.ocrFragments(page: page, index: i).map(\.text).joined(separator: "\n")
                }
            }
            let block = "--- Page \(i + 1) ---\n\(t.trimmingCharacters(in: .whitespacesAndNewlines))"
            parts.append(block)
            used.append(i + 1)
            total += block.count
            if total >= maxChars { break }
        }
        var text = parts.joined(separator: "\n\n")
        let truncated = text.count > maxChars || used.count < indices.count
        if text.count > maxChars { text = String(text.prefix(maxChars)) }
        return (text, truncated, used)
    }

    public struct SearchHit: Codable, Sendable { public var id: String; public var title: String; public var page: Int; public var snippet: String }

    /// Searches off the main thread with its own PDFDocuments, so a big library doesn't freeze the UI.
    public func search(_ query: String, in id: String? = nil, limit: Int = 50) async throws -> [SearchHit] {
        guard query.trimmingCharacters(in: .whitespaces).count >= 2 else { throw EzPDFError.invalidInput("Search for at least 2 characters.") }
        // The whole library: the full-text index, brought up to date first (fast: only changed documents).
        if id == nil {
            do {
                try await searchIndex.refresh(indexDocuments())
                return try await searchIndex.search(query, limit: limit).map {
                    SearchHit(id: $0.id, title: $0.title, page: $0.page, snippet: $0.snippet)
                }
            } catch {
                // The index couldn't be used: read the files instead (slower, same results for text pages).
            }
        }
        let recs = try id.map { [try record($0)] } ?? library.all()
        let files = recs.map { (id: $0.id, title: $0.title, url: library.pdfURL(for: $0.id)) }
        let limit = max(1, limit)
        return await Task.detached(priority: .userInitiated) { Self.searchFiles(files, query: query, limit: limit) }.value
    }

    nonisolated private static func searchFiles(_ files: [(id: String, title: String, url: URL)], query: String, limit: Int) -> [SearchHit] {
        var hits: [SearchHit] = []
        for rec in files {
            guard let doc = PDFDocument(url: rec.url), !doc.isLocked else { continue }
            for sel in doc.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive]).prefix(limit) {
                guard let page = sel.pages.first else { continue }
                let ext = sel.copy() as! PDFSelection
                ext.extend(atStart: 60)
                ext.extend(atEnd: 60)
                let snippet = (ext.string ?? sel.string ?? "").replacingOccurrences(of: "\n", with: " ")
                hits.append(SearchHit(id: rec.id, title: rec.title, page: doc.index(for: page) + 1, snippet: snippet))
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }

    /// The PDF bytes, optionally only some pages.
    public func pdfData(_ id: String, pages: String? = nil) throws -> Data {
        let (rec, _) = try document(id)
        let full = try deliverableData(rec.id)
        if pages == nil || pages?.isEmpty == true { return full }
        guard let doc = PDFDocument(data: full) else { throw EzPDFError.failed("Couldn't read the PDF.") }
        let sub = PageOps.extract(doc, pages: try PageOps.pages(pages, count: doc.pageCount))
        guard let d = sub.dataRepresentation() else { throw EzPDFError.failed("Couldn't cut those pages.") }
        return d
    }

    // MARK: Edit

    /// Saves the current PDF as the undo point, then writes the new one.
    private func commit(_ id: String, _ doc: PDFDocument, caller: String = #function) throws -> DocumentRecord {
        guard let data = doc.dataRepresentation() else { throw EzPDFError.failed("Couldn't save the change.") }
        return try commit(id, data: data, caller: caller)
    }

    func commitEditData(_ id: String, _ data: Data, caller: String = #function) throws -> DocumentRecord { try commit(id, data: data, caller: caller) }

    /// What a change was, for the log, from the operation that made it.
    static func actionName(_ caller: String) -> String {
        let name = String(caller.prefix { $0 != "(" })
        let known: [String: String] = [
            "pages": "Change pages", "reflowArticle": "Reflow article", "addAnnotations": "Highlights and notes", "updateObject": "Move or edit a placed item",
            "deleteObject": "Delete a placed item", "stamp": "Header and footer", "fillForm": "Fill in the form", "redact": "Redact",
            "flatten": "Flatten", "makeFillable": "Make fillable", "replaceText": "Change text", "replaceSelection": "Change selected text",
            "addContent": "Add content", "optimize": "Improve the PDF", "setProperties": "Properties", "removeAnnotations": "Remove annotations",
            "sign": "Sign",
        ]
        if let k = known[name] { return k }
        let words = name.replacingOccurrences(of: #"([a-z])([A-Z])"#, with: "$1 $2", options: .regularExpression).lowercased()
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private func commit(_ id: String, data: Data, caller: String = #function) throws -> DocumentRecord {
        guard let check = PDFDocument(data: data), check.pageCount > 0 || check.isLocked else {
            throw EzPDFError.failed("That change produced a broken PDF, so it wasn't saved.")
        }
        let current = library.pdfURL(for: id)
        let history = EditHistory(folder: library.folder(for: id))
        do {
            try history.push(current, to: history.undoDir)
        } catch {
            throw EzPDFError.failed("Couldn't keep an undo copy, so the change wasn't made: \(error.localizedDescription)")
        }
        let saved: DocumentRecord
        do {
            saved = try library.replacePDF(id, with: data)
        } catch {
            // The change didn't happen: take back the undo step it would have had.
            if let step = history.newest(history.undoDir) { try? FileManager.default.removeItem(at: step) }
            throw error
        }
        history.clearRedo()
        history.trim()
        collectGarbage(id)
        logChange(id, fallback: Self.actionName(caller))
        return saved
    }

    /// Placed images no kept version uses (deleted, on deleted pages, past the undo limit) are cleared out.
    private func collectGarbage(_ id: String) {
        let history = EditHistory(folder: library.folder(for: id))
        Objects.collectGarbage(folder: library.folder(for: id), versions: [library.pdfURL(for: id)] + history.versions)
    }

    public func canUndo(_ id: String) -> Bool { EditHistory(folder: library.folder(for: id)).canUndo }
    public func canRedo(_ id: String) -> Bool { EditHistory(folder: library.folder(for: id)).canRedo }

    /// A new document made from pages of others. Placed objects get fresh ids and their image files
    /// come along; if the files can't be copied, the new document isn't kept.
    private func addDerived(_ record: DocumentRecord, _ doc: PDFDocument, images: [Objects.ImageCopy]) throws -> DocumentRecord {
        guard let data = doc.dataRepresentation() else { throw EzPDFError.failed("Couldn't make “\(record.title)”.") }
        let new = try library.add(record, pdfData: data)
        do {
            try Objects.copyImages(images, to: library.folder(for: new.id))
        } catch {
            try? library.delete(new.id)
            throw error
        }
        return new
    }

    /// Adds annotations made in the reader onto the current file (not over it), with an undo point.
    /// Merging onto what's on disk means edits made meanwhile (page changes, agents) are kept.
    @discardableResult
    public func addAnnotations(_ id: String, _ items: [(page: Int, annotation: PDFAnnotation)]) throws -> DocumentRecord {
        let (rec, doc) = try document(id)
        guard !items.isEmpty else { return rec }
        for item in items {
            guard let page = doc.page(at: item.page), let copy = item.annotation.copy() as? PDFAnnotation else { continue }
            page.addAnnotation(copy)
        }
        return try commit(rec.id, doc)
    }

    /// Restores the version before the last change (as many steps back as are kept).
    @discardableResult
    public func undo(_ id: String) throws -> DocumentRecord {
        let rec = try record(id, strict: true)
        let history = EditHistory(folder: library.folder(for: rec.id))
        guard let step = history.newest(history.undoDir) else { throw EzPDFError.invalidInput("Nothing to undo for “\(rec.title)”.") }
        let out = try swap(rec, with: step, saveCurrentTo: history.redoDir, history: history)
        log(rec.id, by: Self.actor?.by ?? "You", action: "Undo", detail: "", ok: true, result: "")
        return out
    }

    /// Puts back the change the last Undo took away.
    @discardableResult
    public func redo(_ id: String) throws -> DocumentRecord {
        let rec = try record(id, strict: true)
        let history = EditHistory(folder: library.folder(for: rec.id))
        guard let step = history.newest(history.redoDir) else { throw EzPDFError.invalidInput("Nothing to redo for “\(rec.title)”.") }
        let out = try swap(rec, with: step, saveCurrentTo: history.undoDir, history: history)
        log(rec.id, by: Self.actor?.by ?? "You", action: "Redo", detail: "", ok: true, result: "")
        return out
    }

    /// Makes `step` the current version and keeps the current one on the other side. If anything
    /// fails, the document stays as it was.
    private func swap(_ rec: DocumentRecord, with step: URL, saveCurrentTo other: URL, history: EditHistory) throws -> DocumentRecord {
        let data = try Data(contentsOf: step)
        guard let check = PDFDocument(data: data), check.pageCount > 0 || check.isLocked else {
            try? FileManager.default.removeItem(at: step)
            throw EzPDFError.failed("That saved version is damaged, so it was dropped. Try again for the one before it.")
        }
        try history.push(library.pdfURL(for: rec.id), to: other)
        let out: DocumentRecord
        do {
            out = try library.replacePDF(rec.id, with: data)
        } catch {
            if let pushed = history.newest(other) { try? FileManager.default.removeItem(at: pushed) }
            throw error
        }
        try? FileManager.default.removeItem(at: step)
        return out
    }

    public enum PageAction: String, Codable, Sendable, CaseIterable {
        case rotate, delete, move, extract, split, duplicate, insert_blank
    }

    public struct PageResult: Codable, Sendable {
        public var document: DocumentRecord
        public var created: [DocumentRecord]
    }

    public func pages(_ id: String, action: PageAction, pages spec: String? = nil, degrees: Int = 90,
                      to position: Int? = nil, every: Int? = nil, startPages: [Int]? = nil) throws -> PageResult {
        let (rec, doc) = try document(id, strict: action != .extract && action != .split)
        switch action {
        case .rotate:
            try PageOps.rotate(doc, pages: try PageOps.pages(spec, count: doc.pageCount), degrees: degrees)
            return PageResult(document: try commit(rec.id, doc), created: [])
        case .delete:
            guard let spec, !spec.isEmpty else { throw EzPDFError.invalidInput("Say which pages to delete.") }
            try PageOps.delete(doc, pages: try PageOps.pages(spec, count: doc.pageCount))
            return PageResult(document: try commit(rec.id, doc), created: [])
        case .move:
            guard let position else { throw EzPDFError.invalidInput("Say where to move the pages (to = 1-based position).") }
            PageOps.move(doc, pages: try PageOps.pages(spec, count: doc.pageCount), to: position - 1)
            return PageResult(document: try commit(rec.id, doc), created: [])
        case .duplicate:
            let indices = try PageOps.pages(spec, count: doc.pageCount)
            let folder = library.folder(for: rec.id)
            var images: [Objects.ImageCopy] = []
            for i in indices.sorted(by: >) {
                guard let p = doc.page(at: i)?.copy() as? PDFPage else { continue }
                // The copy's objects are new objects: own ids, own image files.
                images += Objects.reassignIDs(on: p, sourceFolder: folder)
                doc.insert(p, at: i + 1)
            }
            try Objects.copyImages(images, to: folder)
            return PageResult(document: try commit(rec.id, doc), created: [])
        case .insert_blank:
            let after = (try PageOps.pages(spec ?? "last", count: doc.pageCount)).last ?? doc.pageCount - 1
            PageOps.insertBlank(doc, after: after)
            return PageResult(document: try commit(rec.id, doc), created: [])
        case .extract:
            let sub = PageOps.extract(doc, pages: try PageOps.pages(spec, count: doc.pageCount))
            let images = Objects.reassignIDs(sub, sourceFolder: library.folder(for: rec.id))
            let new = try addDerived(DocumentRecord(title: "\(rec.title) (pages \(spec ?? "all"))", kind: .file, preset: rec.preset), sub, images: images)
            return PageResult(document: rec, created: [new])
        case .split:
            let parts = try PageOps.split(doc, every: every, at: startPages)
            var created: [DocumentRecord] = []
            for (i, part) in parts.enumerated() {
                let images = Objects.reassignIDs(part, sourceFolder: library.folder(for: rec.id))
                created.append(try addDerived(DocumentRecord(title: "\(rec.title), part \(i + 1)", kind: .file, preset: rec.preset), part, images: images))
            }
            return PageResult(document: rec, created: created)
        }
    }

    public func merge(_ ids: [String], title: String? = nil) throws -> DocumentRecord {
        guard ids.count >= 2 else { throw EzPDFError.invalidInput("Merge needs at least two documents.") }
        let merged = PDFDocument()
        var titles: [String] = []
        var images: [Objects.ImageCopy] = []
        for id in ids {
            let (rec, doc) = try document(id)
            // Fresh ids per source (the same document can be merged twice), files from its folder.
            images += Objects.reassignIDs(doc, sourceFolder: library.folder(for: rec.id))
            PageOps.append(doc, to: merged)
            titles.append(rec.title)
        }
        return try addDerived(DocumentRecord(title: title ?? titles.prefix(2).joined(separator: " + ") + (titles.count > 2 ? " + …" : ""), kind: .merged),
                              merged, images: images)
    }

    public enum Optimization: String, Codable, Sendable, CaseIterable {
        case compress, compress_strong, make_searchable, protect, unlock, page_numbers, watermark
    }

    public func optimize(_ id: String, _ action: Optimization, password: String? = nil, text: String? = nil) async throws -> (record: DocumentRecord, before: Int, after: Int) {
        let rec = try record(id, strict: true)
        let before = rec.byteCount
        let url = library.pdfURL(for: rec.id)
        let revision = rec.modifiedAt
        let out: Data?
        switch action {
        case .compress, .compress_strong:
            let (_, doc) = try document(rec.id)
            out = PageOps.compress(doc, level: action == .compress ? .light : .strong)
            if let o = out, o.count >= before { return (rec, before, before) }    // never make it bigger
        case .make_searchable:
            // OCR is slow, so it runs off the main thread on its own copy of the document
            // (PDFDocument isn't thread-safe; nothing else touches this one).
            let fileURL = url
            out = await Task.detached(priority: .userInitiated) { () -> Data? in
                guard let own = PDFDocument(url: fileURL) else { return nil }
                return PageOps.makeSearchable(own)
            }.value
        case .protect:
            guard let password, !password.isEmpty else { throw EzPDFError.invalidInput("Give a password.") }
            let (_, doc) = try document(id)
            out = PageOps.protect(doc, password: password, ownerPassword: nil, allowPrinting: true, allowCopying: false)
        case .unlock:
            out = try PageOps.unlock(try Data(contentsOf: url), password: password ?? "")
        case .page_numbers:
            let (_, doc) = try document(id)
            PageOps.addPageNumbers(doc)
            out = doc.dataRepresentation()
        case .watermark:
            guard let text, !text.isEmpty else { throw EzPDFError.invalidInput("Give the watermark text.") }
            let (_, doc) = try document(id)
            PageOps.watermark(doc, text: text)
            out = doc.dataRepresentation()
        }
        guard let out else { throw EzPDFError.failed("That didn't work on this PDF.") }
        // Slow steps (OCR) await; if the document changed meanwhile, don't overwrite that change.
        guard library.record(rec.id)?.modifiedAt == revision else {
            throw EzPDFError.failed("“\(rec.title)” changed while this was running, so the result wasn't saved. Try again.")
        }
        let saved = try commit(rec.id, data: out)
        return (saved, before, out.count)
    }

    public func highlight(_ id: String, text: String, pages: String? = nil) throws -> (record: DocumentRecord, count: Int) {
        let (rec, doc) = try document(id, strict: true)
        let set = try pages.map { Set(try PageOps.pages($0, count: doc.pageCount)) }
        let n = PageOps.highlight(doc, text: text, pages: set)
        guard n > 0 else { throw EzPDFError.invalidInput("“\(text)” doesn't appear in “\(rec.title)”.") }
        return (try commit(rec.id, doc), n)
    }

    public func addNote(_ id: String, page: Int, text: String) throws -> DocumentRecord {
        let (rec, doc) = try document(id, strict: true)
        try PageOps.addNote(doc, page: page - 1, text: text)
        return try commit(rec.id, doc)
    }

    public func rename(_ id: String, title: String) throws -> DocumentRecord {
        let rec = try record(id, strict: true)
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
        guard !clean.isEmpty else { throw EzPDFError.invalidInput("Give a title.") }
        try library.update(rec.id) { $0.title = String(clean) }
        return try record(rec.id)
    }

    public func delete(_ id: String) throws -> DocumentRecord {
        let rec = try record(id, strict: true)
        try library.delete(rec.id)
        return rec
    }

    // MARK: Data

    /// `remember` files the document under Statements/Invoices; read-only callers pass false.
    public func extract(_ id: String, kind: ExtractKind = .auto, source: JobSource = .app, remember: Bool = true) async throws -> ExtractionResult {
        let (rec, doc) = try document(id)
        return try await run("Reading \(rec.title)", source: source) { job in
            job.detail = "Reading the pages"
            let result = await DataExtractor.extract(doc, kind: kind)
            job.documentID = rec.id
            if remember, result.kind == .statement || result.kind == .invoice {
                try? library.update(rec.id) { $0.kind = result.kind == .statement ? .statement : .invoice }
            }
            return result
        }
    }

    public enum DataFormat: String, Codable, Sendable { case json, csv, xlsx }

    /// Writes extracted data to the export folder and returns the file.
    public func saveExtraction(_ result: ExtractionResult, for id: String, format: DataFormat, folder: URL? = nil) throws -> URL {
        let rec = try record(id)
        let suffix = result.kind == .statement ? "transactions" : result.kind == .invoice ? "invoice" : "tables"
        let base = "\(safeName(rec.title)) \(suffix)"
        let data: Data
        switch format {
        case .csv: data = Spreadsheet.csv(result.csvRows)
        case .xlsx: data = Spreadsheet.xlsx(result.sheets)
        case .json:
            let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try e.encode(result)
        }
        return try write(data, name: base, ext: format.rawValue, folder: folder)
    }

    /// On-device summary (Apple Intelligence). Never leaves the Mac.
    public var canSummarize: Bool { AIExtractor.isAvailable }

    public func summarize(_ id: String) async throws -> String {
        guard AIExtractor.isAvailable else {
            throw EzPDFError.unavailable("Summaries need Apple Intelligence turned on (System Settings → Apple Intelligence & Siri).")
        }
        let rec = try record(id)
        let (text, _, _) = try await text(rec.id, maxChars: 60_000)
        let cleaned = text.replacingOccurrences(of: #"--- Page \d+ ---"#, with: "", options: .regularExpression)
        return try await run("Summarizing \(rec.title)", source: .app) { job in
            job.detail = "Reading on this Mac"
            job.documentID = rec.id
            let raw = try await AIExtractor.summarize(cleaned)
            // Show bullets as "•", never as "-" or "*".
            return raw.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                let t = line.trimmingCharacters(in: .whitespaces)
                if let r = t.range(of: #"^([-*–—]|\d+[.)])\s+"#, options: .regularExpression) { return "• " + t[r.upperBound...] }
                return t
            }.joined(separator: "\n")
        }
    }

    // MARK: Export & send

    public enum ExportFormat: String, Codable, Sendable { case pdf, epub }

    public func export(_ id: String, format: ExportFormat = .pdf, folder: URL? = nil) throws -> URL {
        let rec = try record(id)
        let src = format == .pdf ? library.pdfURL(for: rec.id) : library.epubURL(for: rec.id)
        guard FileManager.default.fileExists(atPath: src.path) else {
            throw EzPDFError.invalidInput("“\(rec.title)” has no \(format.rawValue.uppercased()). EPUB is made only for web articles.")
        }
        let data = format == .pdf ? try deliverableData(rec.id) : try Data(contentsOf: src)
        return try write(data, name: safeName(rec.title), ext: format.rawValue, folder: folder)
    }

    /// Writes only inside the export folder the user chose (callers can pick a subfolder of it).
    private func write(_ data: Data, name: String, ext: String, folder: URL?) throws -> URL {
        let dir = folder ?? exportFolder
        guard FileAccess.isInside(dir, exportFolder) else {
            throw EzPDFError.invalidInput("ezpdf saves only into your export folder (\(exportFolder.lastPathComponent)).")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir.appendingPathComponent("\(name).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = dir.appendingPathComponent("\(name) \(n).\(ext)"); n += 1 }
        try data.write(to: url, options: .atomic)
        return url
    }

    /// A file name from a title: no path characters, no control characters, not hidden.
    private func safeName(_ s: String) -> String {
        var n = s.replacingOccurrences(of: "[/:\\\\?%*|\"<>\\p{Cc}]", with: " ", options: .regularExpression)
        n = n.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        n = String(n.prefix(90))
        return n.isEmpty ? "Document" : n
    }

    /// Sends to Kindle. EPUB is used when the document has one and the settings prefer it.
    public func sendToKindle(_ id: String, format: ExportFormat? = nil) async throws -> (record: DocumentRecord, format: ExportFormat, address: String) {
        let rec = try record(id)
        let settings = KindleSender.Settings.load()
        let useEPUB = format.map { $0 == .epub } ?? (settings.preferEPUB && rec.hasEPUB)
        if useEPUB, !rec.hasEPUB { throw EzPDFError.invalidInput("“\(rec.title)” has no EPUB.") }
        let file = useEPUB ? library.epubURL(for: rec.id) : try deliverableFile(rec.id)
        try await KindleSender.send(file: file, title: rec.title, settings: settings)
        try library.update(rec.id) { $0.sentToKindleAt = Date() }
        return (try record(rec.id), useEPUB ? .epub : .pdf, settings.address)
    }

    public func requestOpen(_ id: String, page: Int? = nil) throws -> DocumentRecord {
        let rec = try record(id)
        NotificationCenter.default.post(name: Self.openRequest, object: nil, userInfo: ["id": rec.id, "page": page ?? 0])
        return rec
    }
}
