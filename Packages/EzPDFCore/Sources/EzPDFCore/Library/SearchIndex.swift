import Foundation
import PDFKit
import SQLite3

/// Full-text search over the whole library: one row per page in an SQLite FTS5 index (the SQLite
/// built into macOS) in the library folder. Ranked, accent-insensitive, with highlighted snippets.
///
/// Kept up to date by comparing each document's modification date with the one it was indexed at,
/// so any change (edits, agents, undo) is picked up on the next search; deleted documents drop out.
/// Scanned pages are read with Apple's document reader in a background pass (`refresh(ocr: true)`),
/// never while someone waits for results.
public actor SearchIndex {
    public struct Hit: Sendable {
        public var id: String
        public var page: Int          // 1-based
        public var title: String
        public var snippet: String
    }

    public struct Document: Sendable {
        public var id: String
        public var title: String
        public var url: URL
        public var modified: Date
        public init(id: String, title: String, url: URL, modified: Date) { self.id = id; self.title = title; self.url = url; self.modified = modified }
    }

    private var db: OpaquePointer?
    private let path: URL

    public init(path: URL) {
        self.path = path
    }

    deinit { if let db { sqlite3_close(db) } }

    private func open() throws -> OpaquePointer {
        if let db { return db }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw EzPDFError.failed("Couldn't open the search index.")
        }
        db = handle
        try exec("""
            PRAGMA journal_mode = WAL;
            CREATE VIRTUAL TABLE IF NOT EXISTS pages USING fts5(doc UNINDEXED, page UNINDEXED, title, body, tokenize = 'unicode61 remove_diacritics 2');
            CREATE TABLE IF NOT EXISTS docs (id TEXT PRIMARY KEY, modified REAL NOT NULL, ocr INTEGER NOT NULL DEFAULT 0);
            """)
        return handle
    }

    private func exec(_ sql: String) throws {
        guard let db else { throw EzPDFError.failed("The search index isn't open.") }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw EzPDFError.failed("Search index: \(message)")
        }
    }

    /// Runs a statement with text/real bindings; calls `row` for each result row.
    private func run(_ sql: String, _ bindings: [Any] = [], row: ((OpaquePointer) -> Void)? = nil) throws {
        let db = try open()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw EzPDFError.failed("Search index: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in bindings.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case let s as String: sqlite3_bind_text(stmt, index, s, -1, transient)
            case let d as Double: sqlite3_bind_double(stmt, index, d)
            case let n as Int: sqlite3_bind_int64(stmt, index, Int64(n))
            default: sqlite3_bind_null(stmt, index)
            }
        }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { row?(stmt); continue }
            if rc == SQLITE_DONE { return }
            throw EzPDFError.failed("Search index: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private static func text(_ stmt: OpaquePointer, _ col: Int32) -> String {
        sqlite3_column_text(stmt, col).map { String(cString: $0) } ?? ""
    }

    // MARK: Keeping it current

    /// Brings the index in line with `documents`: new and changed ones are (re)indexed, removed ones
    /// dropped. With `ocr`, pages without a text layer are read with the document reader (slow; for
    /// the background pass).
    public func refresh(_ documents: [Document], ocr: Bool = false) async throws {
        _ = try open()
        var indexed: [String: (modified: Double, ocr: Bool)] = [:]
        try run("SELECT id, modified, ocr FROM docs") { s in
            indexed[Self.text(s, 0)] = (sqlite3_column_double(s, 1), sqlite3_column_int(s, 2) != 0)
        }
        let current = Set(documents.map(\.id))
        for gone in indexed.keys where !current.contains(gone) {
            try run("DELETE FROM pages WHERE doc = ?", [gone])
            try run("DELETE FROM docs WHERE id = ?", [gone])
        }
        for d in documents {
            let stamp = d.modified.timeIntervalSince1970
            if let i = indexed[d.id], abs(i.modified - stamp) < 0.001, i.ocr || !ocr { continue }
            try await index(d, stamp: stamp, ocr: ocr)
        }
    }

    private func index(_ d: Document, stamp: Double, ocr: Bool) async throws {
        guard let pdf = PDFDocument(url: d.url), !pdf.isLocked else { return }
        var pages: [(Int, String)] = []
        for i in 0..<min(pdf.pageCount, 2000) {
            guard let page = pdf.page(at: i) else { continue }
            var body = page.string ?? ""
            if ocr, body.trimmingCharacters(in: .whitespacesAndNewlines).count < 20, i < 300,
               let read = try? await DocumentReader.read(page: page, index: i) {
                body = read.text
            }
            pages.append((i + 1, body))
        }
        try exec("BEGIN")
        do {
            try run("DELETE FROM pages WHERE doc = ?", [d.id])
            for (n, body) in pages where !body.isEmpty || n == 1 {
                try run("INSERT INTO pages (doc, page, title, body) VALUES (?, ?, ?, ?)", [d.id, n, d.title, body])
            }
            try run("INSERT OR REPLACE INTO docs (id, modified, ocr) VALUES (?, ?, ?)", [d.id, stamp, ocr ? 1 : 0])
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: Searching

    /// The query as FTS5 terms: each word a quoted term (so punctuation can't break the syntax),
    /// all required, the last one also matching as a prefix ("invo" finds "invoice").
    static func ftsQuery(_ query: String) -> String? {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map { $0.replacingOccurrences(of: "\"", with: "") }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.enumerated().map { i, w in i == words.count - 1 && w.count >= 2 ? "\"\(w)\"*" : "\"\(w)\"" }.joined(separator: " ")
    }

    /// Best matches first; the matched words are wrapped in « ».
    public func search(_ query: String, limit: Int = 50) throws -> [Hit] {
        guard let fts = Self.ftsQuery(query) else { return [] }
        var hits: [Hit] = []
        try run("""
            SELECT doc, page, title, snippet(pages, 3, '«', '»', '…', 14)
            FROM pages WHERE pages MATCH ? ORDER BY rank LIMIT ?
            """, [fts, max(1, min(limit, 500))]) { s in
            hits.append(Hit(id: Self.text(s, 0), page: Int(sqlite3_column_int(s, 1)), title: Self.text(s, 2), snippet: Self.text(s, 3)))
        }
        return hits
    }
}
