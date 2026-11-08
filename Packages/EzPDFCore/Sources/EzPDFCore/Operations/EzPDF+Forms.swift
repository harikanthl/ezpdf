import Foundation
import PDFKit

/// A form the user made into a reusable template ("My Templates").
public struct UserTemplate: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var createdAt: Date
    public var pageCount: Int
    /// Field names, in reading order (what `fill_form` takes).
    public var fields: [String]
}

/// Making forms fillable, and keeping them as templates.
extension EzPDF {
    public struct FillableResult: Sendable {
        public var record: DocumentRecord
        public var fields: [FormDetector.Field]
        /// Rotated pages with annotations that were left as they were (1-based).
        public var skippedRotated: [Int]
    }

    /// Finds the blanks (lines, boxes, table cells, checkboxes, signature and date lines) and makes
    /// each a fill-in field, with an undo point. Existing fields are kept. If the document changes
    /// while it's being read, it's read again rather than written over.
    @discardableResult
    public func makeFillable(_ id: String) async throws -> FillableResult {
        for _ in 0..<3 {
            let (rec, doc) = try document(id, strict: true)
            let revision = rec.modifiedAt
            let found = try await FormDetector.makeFillable(doc)
            guard try record(rec.id, strict: true).modifiedAt == revision else { continue }
            guard !found.fields.isEmpty else {
                let existing = (0..<doc.pageCount).reduce(0) { n, i in n + (doc.page(at: i)?.annotations.filter { $0.type == "Widget" }.count ?? 0) }
                if existing > 0 {
                    throw EzPDFError.invalidInput("“\(rec.title)” is already fillable: it has \(existing) field\(existing == 1 ? "" : "s"). Click a field to type in it.")
                }
                throw EzPDFError.invalidInput("No blanks found in “\(rec.title)”: no writing lines, boxes or checkboxes to turn into fields.")
            }
            let saved = try commitEdit(rec.id, doc)
            return FillableResult(record: saved, fields: found.fields, skippedRotated: found.skippedRotated)
        }
        throw EzPDFError.failed("The document kept changing while reading it; nothing was changed. Try again.")
    }

    /// A dropped form (PDF, scan or photo of one) as a new fillable document; with `templateName`
    /// it's also kept in My Templates. Nothing is kept if no blanks are found.
    public func importForm(_ url: URL, templateName: String? = nil, source: JobSource = .app) async throws -> (result: FillableResult, template: UserTemplate?) {
        let base = url.deletingPathExtension().lastPathComponent
        let rec = try await convert(files: [url], title: base, source: source)
        let result: FillableResult
        do {
            result = try await makeFillable(rec.id)
        } catch {
            _ = try? delete(rec.id)
            throw error
        }
        let name = templateName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = try name.flatMap { $0.isEmpty ? nil : try saveTemplate(result.record.id, name: $0) }
        return (result, template)
    }

    // MARK: My Templates

    var templatesRoot: URL { library.root.appendingPathComponent(".templates", isDirectory: true) }

    /// Keeps a document (as it would be shared: placed objects drawn in, fields kept) as a template.
    @discardableResult
    public func saveTemplate(_ id: String, name: String) throws -> UserTemplate {
        let rec = try record(id, strict: true)
        let title = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !title.isEmpty else { throw EzPDFError.invalidInput("Give the template a name.") }
        let data = try deliverableData(rec.id)
        guard let doc = PDFDocument(data: data), doc.pageCount > 0 else { throw EzPDFError.failed("Couldn't read “\(rec.title)”.") }
        let t = UserTemplate(id: Library.newID(), name: title, createdAt: Date(), pageCount: doc.pageCount,
                             fields: EditOps.formFields(doc).map(\.name))
        let dir = templatesRoot.appendingPathComponent(t.id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try data.write(to: dir.appendingPathComponent("template.pdf"), options: .atomic)
            try JSONEncoder.ezpdf.encode(t).write(to: dir.appendingPathComponent("template.json"), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        NotificationCenter.default.post(name: Self.templatesDidChange, object: nil)
        return t
    }

    public static let templatesDidChange = Notification.Name("EzPDFTemplatesDidChange")

    /// Saved templates, newest first. Damaged entries are skipped.
    public func userTemplates() -> [UserTemplate] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: templatesRoot, includingPropertiesForKeys: nil) else { return [] }
        return dirs.compactMap { dir in
            guard let d = try? Data(contentsOf: dir.appendingPathComponent("template.json")),
                  let t = try? JSONDecoder.ezpdf.decode(UserTemplate.self, from: d),
                  FileManager.default.fileExists(atPath: dir.appendingPathComponent("template.pdf").path) else { return nil }
            return t
        }.sorted { $0.createdAt > $1.createdAt }
    }

    /// A saved template by id or (exact, case-insensitive) name.
    public func userTemplate(_ idOrName: String) -> UserTemplate? {
        let all = userTemplates()
        return all.first { $0.id == idOrName } ?? all.first { $0.name.caseInsensitiveCompare(idOrName) == .orderedSame }
    }

    /// A new document from a saved template, optionally filled in.
    public func create(userTemplate idOrName: String, title: String? = nil, values: [String: String] = [:], source: JobSource = .app) throws -> DocumentRecord {
        guard let t = userTemplate(idOrName) else { throw EzPDFError.invalidInput("No saved template “\(idOrName)”.") }
        let data = try Data(contentsOf: templatesRoot.appendingPathComponent(t.id).appendingPathComponent("template.pdf"))
        guard let doc = PDFDocument(data: data) else { throw EzPDFError.failed("The template “\(t.name)” is damaged.") }
        if !values.isEmpty { try EditOps.fillForm(doc, values: values) }
        guard let out = doc.dataRepresentation() else { throw EzPDFError.failed("Couldn't make the document.") }
        let rec = DocumentRecord(title: title ?? t.name, kind: .file, sourceFileName: "\(t.name) template")
        return try library.add(rec, pdfData: out)
    }

    public func deleteUserTemplate(_ id: String) throws {
        guard let t = userTemplate(id) else { throw EzPDFError.invalidInput("No saved template “\(id)”.") }
        try FileManager.default.removeItem(at: templatesRoot.appendingPathComponent(t.id, isDirectory: true))
        NotificationCenter.default.post(name: Self.templatesDidChange, object: nil)
    }
}
