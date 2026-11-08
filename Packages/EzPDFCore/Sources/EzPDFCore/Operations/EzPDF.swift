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

    // MARK: Jobs

    private func run<T>(_ title: String, source: JobSource, _ body: (Job) async throws -> T) async throws -> T {
        let job = Job(title: title, source: source)
        jobs.insert(job, at: 0)
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
        if jobs.count > 30 { jobs.removeLast(jobs.count - 30) }
    }

    public func dismissJob(_ id: UUID) { jobs.removeAll { $0.id == id } }

    // MARK: Convert

    @discardableResult
    public func convert(url: URL, preset: PagePreset? = nil, format: OutputFormat? = nil, title: String? = nil,
                        source: JobSource = .app) async throws -> DocumentRecord {
        let preset = preset ?? defaultPreset
        let format = format ?? defaultFormat
        return try await run(url.host() ?? url.absoluteString, source: source) { job in
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
            rec = try library.add(rec, pdfData: out.pdf, epubData: out.epub, articleHTML: out.article?.html)
            job.documentID = rec.id
            return rec
        }
    }

    /// The page as the browser already shows it (works behind logins).
    @discardableResult
    public func convert(html: String, url: URL, preset: PagePreset? = nil, format: OutputFormat? = nil, title: String? = nil,
                        source: JobSource = .browser) async throws -> DocumentRecord {
        let preset = preset ?? defaultPreset
        let format = format ?? defaultFormat
        return try await run(url.host() ?? "Page", source: source) { job in
            let out = try await WebConverter.convert(html: html, url: url, preset: preset, format: format) { job.detail = $0 }
            job.title = title ?? out.title
            job.notes = out.notes
            var rec = DocumentRecord(title: title ?? out.title, kind: .web, sourceURL: url.absoluteString,
                                     byline: out.article?.byline, siteName: out.article?.siteName ?? url.host(),
                                     excerpt: out.article?.excerpt, preset: preset.rawValue)
            rec = try library.add(rec, pdfData: out.pdf, epubData: out.epub, articleHTML: out.article?.html)
            job.documentID = rec.id
            return rec
        }
    }

    static func downloadIfPDF(_ url: URL) async throws -> Data? {
        guard URLGuard.isAllowed(url) else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = ["User-Agent": WebSession.userAgent]
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        let looksPDF = url.pathExtension.lowercased() == "pdf"
        if !looksPDF {
            guard let (_, resp) = try? await session.data(for: head),
                  (resp as? HTTPURLResponse)?.mimeType == "application/pdf" else { return nil }
        }
        let (data, resp) = try await session.data(from: url)
        if let final = resp.url, !URLGuard.isAllowed(final) { throw EzPDFError.invalidInput("The link redirected to a local address.") }
        guard data.starts(with: Data("%PDF".utf8)), data.count < 300_000_000 else { return looksPDF ? nil : nil }
        return data
    }

    @discardableResult
    public func convert(files: [URL], preset: PagePreset? = nil, title: String? = nil,
                        source: JobSource = .app) async throws -> DocumentRecord {
        let preset = preset ?? defaultPreset
        guard let first = files.first else { throw EzPDFError.invalidInput("No files given.") }
        for f in files where !FileManager.default.isReadableFile(atPath: f.path) {
            throw EzPDFError.invalidInput("Can't read \(f.path).")
        }
        return try await run(first.lastPathComponent, source: source) { job in
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

    public func record(_ id: String) throws -> DocumentRecord {
        guard let r = library.resolve(id) else { throw EzPDFError.notFound(id) }
        return r
    }

    public func document(_ id: String) throws -> (DocumentRecord, PDFDocument) {
        let rec = try record(id)
        guard let doc = PDFDocument(url: library.pdfURL(for: rec.id)) else { throw EzPDFError.failed("The PDF for “\(rec.title)” is missing or damaged.") }
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
                t = await PageText.ocrFragments(page: page, index: i).map(\.text).joined(separator: "\n")
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

    public func search(_ query: String, in id: String? = nil, limit: Int = 50) throws -> [SearchHit] {
        guard query.trimmingCharacters(in: .whitespaces).count >= 2 else { throw EzPDFError.invalidInput("Search for at least 2 characters.") }
        let recs = try id.map { [try record($0)] } ?? library.all()
        var hits: [SearchHit] = []
        for rec in recs {
            guard let doc = PDFDocument(url: library.pdfURL(for: rec.id)) else { continue }
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
        let (rec, doc) = try document(id)
        if pages == nil || pages?.isEmpty == true { return try Data(contentsOf: library.pdfURL(for: rec.id)) }
        let sub = PageOps.extract(doc, pages: try PageOps.pages(pages, count: doc.pageCount))
        guard let d = sub.dataRepresentation() else { throw EzPDFError.failed("Couldn't cut those pages.") }
        return d
    }

    // MARK: Edit

    /// Saves the current PDF as the undo point, then writes the new one.
    private func commit(_ id: String, _ doc: PDFDocument) throws -> DocumentRecord {
        guard let data = doc.dataRepresentation() else { throw EzPDFError.failed("Couldn't save the change.") }
        return try commit(id, data: data)
    }

    private func commit(_ id: String, data: Data) throws -> DocumentRecord {
        let current = library.pdfURL(for: id)
        let backup = library.folder(for: id).appendingPathComponent("document.prev.pdf")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: current, to: backup)
        return try library.replacePDF(id, with: data)
    }

    /// Restores the version before the last edit.
    @discardableResult
    public func undo(_ id: String) throws -> DocumentRecord {
        let rec = try record(id)
        let backup = library.folder(for: rec.id).appendingPathComponent("document.prev.pdf")
        guard let data = try? Data(contentsOf: backup) else { throw EzPDFError.invalidInput("Nothing to undo for “\(rec.title)”.") }
        let out = try library.replacePDF(rec.id, with: data)
        try? FileManager.default.removeItem(at: backup)
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
        let (rec, doc) = try document(id)
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
            for i in indices.sorted(by: >) { if let p = doc.page(at: i)?.copy() as? PDFPage { doc.insert(p, at: i + 1) } }
            return PageResult(document: try commit(rec.id, doc), created: [])
        case .insert_blank:
            let after = (try PageOps.pages(spec ?? "last", count: doc.pageCount)).last ?? doc.pageCount - 1
            PageOps.insertBlank(doc, after: after)
            return PageResult(document: try commit(rec.id, doc), created: [])
        case .extract:
            let sub = PageOps.extract(doc, pages: try PageOps.pages(spec, count: doc.pageCount))
            guard let data = sub.dataRepresentation() else { throw EzPDFError.failed("Couldn't extract the pages.") }
            let new = try library.add(DocumentRecord(title: "\(rec.title) (pages \(spec ?? "all"))", kind: .file, preset: rec.preset), pdfData: data)
            return PageResult(document: rec, created: [new])
        case .split:
            let parts = try PageOps.split(doc, every: every, at: startPages)
            var created: [DocumentRecord] = []
            for (i, part) in parts.enumerated() {
                guard let data = part.dataRepresentation() else { continue }
                created.append(try library.add(DocumentRecord(title: "\(rec.title) — part \(i + 1)", kind: .file, preset: rec.preset), pdfData: data))
            }
            return PageResult(document: rec, created: created)
        }
    }

    public func merge(_ ids: [String], title: String? = nil) throws -> DocumentRecord {
        guard ids.count >= 2 else { throw EzPDFError.invalidInput("Merge needs at least two documents.") }
        let merged = PDFDocument()
        var titles: [String] = []
        for id in ids {
            let (rec, doc) = try document(id)
            PageOps.append(doc, to: merged)
            titles.append(rec.title)
        }
        guard let data = merged.dataRepresentation() else { throw EzPDFError.failed("Couldn't merge.") }
        return try library.add(DocumentRecord(title: title ?? titles.prefix(2).joined(separator: " + ") + (titles.count > 2 ? " + …" : ""), kind: .merged), pdfData: data)
    }

    public enum Optimization: String, Codable, Sendable, CaseIterable {
        case compress, compress_strong, make_searchable, protect, unlock, page_numbers, watermark
    }

    public func optimize(_ id: String, _ action: Optimization, password: String? = nil, text: String? = nil) async throws -> (record: DocumentRecord, before: Int, after: Int) {
        let rec = try record(id)
        let before = rec.byteCount
        let url = library.pdfURL(for: rec.id)
        let out: Data?
        switch action {
        case .compress, .compress_strong:
            let (_, doc) = try document(id)
            out = PageOps.compress(doc, level: action == .compress ? .light : .strong)
            if let o = out, o.count >= before { return (rec, before, before) }    // never make it bigger
        case .make_searchable:
            let (_, doc) = try document(id)
            out = await Task.detached { PageOps.makeSearchable(doc) }.value
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
        let saved = try commit(rec.id, data: out)
        return (saved, before, out.count)
    }

    public func highlight(_ id: String, text: String, pages: String? = nil) throws -> (record: DocumentRecord, count: Int) {
        let (rec, doc) = try document(id)
        let set = pages.map { try? Set(PageOps.pages($0, count: doc.pageCount)) } ?? nil
        let n = PageOps.highlight(doc, text: text, pages: set)
        guard n > 0 else { throw EzPDFError.invalidInput("“\(text)” doesn't appear in “\(rec.title)”.") }
        return (try commit(rec.id, doc), n)
    }

    public func addNote(_ id: String, page: Int, text: String) throws -> DocumentRecord {
        let (rec, doc) = try document(id)
        try PageOps.addNote(doc, page: page - 1, text: text)
        return try commit(rec.id, doc)
    }

    public func rename(_ id: String, title: String) throws -> DocumentRecord {
        let rec = try record(id)
        try library.update(rec.id) { $0.title = title }
        return try record(rec.id)
    }

    public func delete(_ id: String) throws -> DocumentRecord {
        let rec = try record(id)
        try library.delete(rec.id)
        return rec
    }

    // MARK: Data

    public func extract(_ id: String, kind: ExtractKind = .auto, source: JobSource = .app) async throws -> ExtractionResult {
        let (rec, doc) = try document(id)
        return try await run("Reading \(rec.title)", source: source) { job in
            job.detail = "Reading the pages"
            let result = await DataExtractor.extract(doc, kind: kind)
            job.documentID = rec.id
            if result.kind == .statement || result.kind == .invoice {
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
        let base = "\(safeName(rec.title)) – \(suffix)"
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
            return try await AIExtractor.summarize(cleaned)
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
        return try write(try Data(contentsOf: src), name: safeName(rec.title), ext: format.rawValue, folder: folder)
    }

    private func write(_ data: Data, name: String, ext: String, folder: URL?) throws -> URL {
        let dir = folder ?? exportFolder
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir.appendingPathComponent("\(name).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = dir.appendingPathComponent("\(name) \(n).\(ext)"); n += 1 }
        try data.write(to: url, options: .atomic)
        return url
    }

    private func safeName(_ s: String) -> String {
        String(s.replacingOccurrences(of: "[/:\\\\?%*|\"<>]", with: "-", options: .regularExpression).prefix(90))
    }

    /// Sends to Kindle. EPUB is used when the document has one and the settings prefer it.
    public func sendToKindle(_ id: String, format: ExportFormat? = nil) throws -> (record: DocumentRecord, format: ExportFormat, address: String) {
        let rec = try record(id)
        let settings = KindleSender.Settings.load()
        let useEPUB = format.map { $0 == .epub } ?? (settings.preferEPUB && rec.hasEPUB)
        let file = useEPUB ? library.epubURL(for: rec.id) : library.pdfURL(for: rec.id)
        if useEPUB, !rec.hasEPUB { throw EzPDFError.invalidInput("“\(rec.title)” has no EPUB.") }
        try KindleSender.send(file: file, title: rec.title, settings: settings)
        try library.update(rec.id) { $0.sentToKindleAt = Date() }
        return (try record(rec.id), useEPUB ? .epub : .pdf, settings.address)
    }

    public func requestOpen(_ id: String, page: Int? = nil) throws -> DocumentRecord {
        let rec = try record(id)
        NotificationCenter.default.post(name: Self.openRequest, object: nil, userInfo: ["id": rec.id, "page": page ?? 0])
        return rec
    }
}
