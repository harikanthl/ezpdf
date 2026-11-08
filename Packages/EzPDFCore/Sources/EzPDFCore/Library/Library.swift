import Foundation
import PDFKit

/// One document in the ezpdf library. Stored as a folder:
/// `<library>/<id>/document.pdf`, optional `document.epub`, `article.html`, and `meta.json`.
public struct DocumentRecord: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case web, file, statement, invoice, merged, imported }

    public var id: String
    public var title: String
    public var kind: Kind
    public var sourceURL: String?
    public var sourceFileName: String?
    public var byline: String?
    public var siteName: String?
    public var excerpt: String?
    public var preset: String?
    public var pageCount: Int
    public var byteCount: Int
    public var hasEPUB: Bool
    public var createdAt: Date
    public var modifiedAt: Date
    /// Last page the reader was on (0-based), so documents reopen where you left off.
    public var lastPage: Int
    public var sentToKindleAt: Date?

    public init(id: String = Library.newID(), title: String, kind: Kind, sourceURL: String? = nil,
                sourceFileName: String? = nil, byline: String? = nil, siteName: String? = nil,
                excerpt: String? = nil, preset: String? = nil, pageCount: Int = 0, byteCount: Int = 0,
                hasEPUB: Bool = false, createdAt: Date = Date(), lastPage: Int = 0) {
        self.id = id; self.title = title; self.kind = kind; self.sourceURL = sourceURL
        self.sourceFileName = sourceFileName; self.byline = byline; self.siteName = siteName
        self.excerpt = excerpt; self.preset = preset; self.pageCount = pageCount
        self.byteCount = byteCount; self.hasEPUB = hasEPUB; self.createdAt = createdAt
        self.modifiedAt = createdAt; self.lastPage = lastPage
    }
}

/// File-backed document store. Thread-safe; all mutation goes through a lock.
public final class Library: @unchecked Sendable {
    public static let shared = Library()

    public let root: URL
    /// Guards the cache and serializes read-modify-write operations (recursive: save() inside update()).
    private let lock = NSRecursiveLock()
    private var cache: [String: DocumentRecord] = [:]
    private var loaded = false

    /// Posted on the main queue after any change. `object` is the changed id, or nil.
    public static let didChange = Notification.Name("EzPDFLibraryDidChange")

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else if let custom = ProcessInfo.processInfo.environment["EZPDF_LIBRARY"], !custom.isEmpty {
            // A separate library (tests, the CLI in development) so nothing lands in the real one.
            self.root = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.root = support.appendingPathComponent("ezpdf/Library", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    public static func newID() -> String {
        // Short, sortable, URL-safe: time prefix + random suffix.
        let t = String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
        let r = String(UInt32.random(in: 0...UInt32.max), radix: 36)
        return "\(t)\(r)"
    }

    // MARK: Paths

    public func folder(for id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    public func pdfURL(for id: String) -> URL { folder(for: id).appendingPathComponent("document.pdf") }
    public func epubURL(for id: String) -> URL { folder(for: id).appendingPathComponent("document.epub") }
    public func articleURL(for id: String) -> URL { folder(for: id).appendingPathComponent("article.html") }
    private func metaURL(for id: String) -> URL { folder(for: id).appendingPathComponent("meta.json") }

    // MARK: Read

    public func all() -> [DocumentRecord] {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return cache.values.sorted { $0.createdAt > $1.createdAt }
    }

    public func record(_ id: String) -> DocumentRecord? {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return cache[id]
    }

    public enum Match { case id(DocumentRecord), exactTitles([DocumentRecord]), partialTitles([DocumentRecord]), none }

    /// How `idOrTitle` matches: an exact id, exact titles (case-insensitive), or titles containing it.
    /// Callers decide what's unambiguous enough (see EzPDF.record).
    public func matches(_ idOrTitle: String) -> Match {
        let q = idOrTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return .none }
        if let r = record(q) { return .id(r) }
        let lower = q.lowercased()
        let docs = all()
        let exact = docs.filter { $0.title.lowercased() == lower }
        if !exact.isEmpty { return .exactTitles(exact) }
        guard q.count >= 3 else { return .none }
        let partial = docs.filter { $0.title.lowercased().contains(lower) }
        return partial.isEmpty ? .none : .partialTitles(partial)
    }

    /// Convenience for the UI: exact id, or a unique title match.
    public func resolve(_ idOrTitle: String) -> DocumentRecord? {
        switch matches(idOrTitle) {
        case .id(let r): return r
        case .exactTitles(let rs) where rs.count == 1, .partialTitles(let rs) where rs.count == 1: return rs[0]
        default: return nil
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        let decoder = JSONDecoder.ezpdf
        for dir in items where dir.hasDirectoryPath || (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let meta = dir.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: meta),
                  let rec = try? decoder.decode(DocumentRecord.self, from: data) else { continue }
            cache[rec.id] = rec
        }
    }

    // MARK: Write

    /// Adds a PDF to the library, taking ownership of `pdfData`.
    @discardableResult
    public func add(_ record: DocumentRecord, pdfData: Data, epubData: Data? = nil, articleHTML: String? = nil) throws -> DocumentRecord {
        var rec = record
        let dir = folder(for: rec.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try pdfData.write(to: pdfURL(for: rec.id), options: .atomic)
        if let epubData {
            try epubData.write(to: epubURL(for: rec.id), options: .atomic)
            rec.hasEPUB = true
        }
        if let articleHTML { try articleHTML.write(to: articleURL(for: rec.id), atomically: true, encoding: .utf8) }
        if rec.pageCount == 0 { rec.pageCount = PDFDocument(data: pdfData)?.pageCount ?? 0 }
        rec.byteCount = pdfData.count
        try save(rec)
        SpotlightIndexer.index(rec, pdf: pdfURL(for: rec.id))
        return rec
    }

    /// Replaces a document's PDF (after page edits, compression, annotation...).
    @discardableResult
    public func replacePDF(_ id: String, with data: Data) throws -> DocumentRecord {
        lock.lock(); defer { lock.unlock() }
        guard var rec = record(id) else { throw EzPDFError.notFound(id) }
        guard let parsed = PDFDocument(data: data) else { throw EzPDFError.failed("Not a valid PDF; nothing was changed.") }
        try data.write(to: pdfURL(for: id), options: .atomic)
        rec.pageCount = parsed.isLocked ? rec.pageCount : parsed.pageCount
        rec.byteCount = data.count
        rec.modifiedAt = Date()
        try save(rec)
        SpotlightIndexer.index(rec, pdf: pdfURL(for: rec.id))
        return rec
    }

    public func setEPUB(_ id: String, data: Data) throws {
        guard var rec = record(id) else { throw EzPDFError.notFound(id) }
        try data.write(to: epubURL(for: id), options: .atomic)
        rec.hasEPUB = true
        try save(rec)
    }

    public func update(_ id: String, _ change: (inout DocumentRecord) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard var rec = record(id) else { throw EzPDFError.notFound(id) }
        change(&rec)
        try save(rec)
    }

    public func save(_ record: DocumentRecord) throws {
        let data = try JSONEncoder.ezpdf.encode(record)
        lock.lock(); defer { lock.unlock() }
        // Load what's on disk first, or a write before any read would hide every other document.
        loadIfNeeded()
        try FileManager.default.createDirectory(at: folder(for: record.id), withIntermediateDirectories: true)
        try data.write(to: metaURL(for: record.id), options: .atomic)
        cache[record.id] = record
        notify(record.id)
    }

    public func delete(_ id: String) throws {
        let dir = folder(for: id)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.trashItem(at: dir, resultingItemURL: nil)
        }
        lock.lock(); cache[id] = nil; lock.unlock()
        SpotlightIndexer.remove(id)
        notify(nil)
    }

    private func notify(_ id: String?) {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Library.didChange, object: id) }
    }
}

public enum EzPDFError: LocalizedError, Equatable {
    case notFound(String)
    case invalidInput(String)
    case failed(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id): return "No document matches “\(id)”."
        case .invalidInput(let s): return s
        case .failed(let s): return s
        case .unavailable(let s): return s
        }
    }
}

extension JSONEncoder {
    static var ezpdf: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var ezpdf: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
