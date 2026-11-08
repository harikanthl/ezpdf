import Foundation
import AppKit
import PDFKit

/// Editing operations. Each one opens the current file, changes it, and commits with an undo
/// point, like every other edit; callers (UI, chat agent, MCP, Shortcuts) share these.
extension EzPDF {
    public struct PageLayout: Codable, Sendable {
        public struct Line: Codable, Sendable { public var text: String; public var rect: [Double] }
        public var page: Int
        public var width: Double
        public var height: Double
        public var lines: [Line]
    }

    /// Page size and every text line with its box (points, origin top-left), so an agent can
    /// place things next to existing content ("put the date under the signature line").
    public func pageLayout(_ id: String, page: Int) async throws -> PageLayout {
        let (_, doc) = try document(id)
        guard let p = doc.page(at: page - 1) else { throw EzPDFError.invalidInput("No page \(page).") }
        let size = EditOps.PageSpace(p).size
        var frags = PageText.words(page: p, index: page - 1)
        if frags.count < 5 { frags = await PageText.ocrFragments(page: p, index: page - 1) }
        let lines = PageText.group(frags).prefix(400).map { l -> PageLayout.Line in
            let r = l.cells.map(\.rect).reduce(CGRect.null) { $0.union($1) }
            return .init(text: l.text, rect: [r.minX, r.minY, r.width, r.height].map { (Double($0) * 10).rounded() / 10 })
        }
        return PageLayout(page: page, width: Double(size.width), height: Double(size.height), lines: Array(lines))
    }

    @discardableResult
    public func replaceText(_ id: String, find: String, with replacement: String, pages: String? = nil,
                            matchCase: Bool = false, wholeWord: Bool = false) throws -> (record: DocumentRecord, changes: [EditOps.Replacement]) {
        let (rec, doc) = try document(id, strict: true)
        let set = try pages.map { Set(try PageOps.pages($0, count: doc.pageCount)) }
        let changes = try EditOps.replaceText(doc, find: find, with: replacement, pages: set, matchCase: matchCase, wholeWord: wholeWord)
        return (try commitEdit(rec.id, doc), changes)
    }

    /// Replaces a selection made in the reader (see EditOps.replaceRegion). Returns the edit checks' notes.
    @discardableResult
    public func replaceSelection(_ id: String, _ info: EditOps.SelectionInfo, with text: String) throws -> (record: DocumentRecord, notes: [String]) {
        let (rec, doc) = try document(id, strict: true)
        guard info.page >= 0, info.page < doc.pageCount else { throw EzPDFError.invalidInput("That page is gone; select the text again.") }
        let notes = try EditOps.replaceRegion(doc, page: info.page, lines: info.lines, text: text,
                                              font: EditOps.font(named: info.fontName, size: info.fontSize),
                                              color: ColorName.parse(info.colorHex) ?? .black)
        return (try commitEdit(rec.id, doc), notes)
    }

    public enum ContentKind: String, Codable, Sendable, CaseIterable { case text, image, signature, shape, whiteout }

    public struct ContentRequest: Sendable {
        public var kind: ContentKind
        public var page: Int
        public var rect: CGRect
        public var text: String?
        public var fontName: String?
        public var fontSize: CGFloat?
        public var color: NSColor?
        public var alignment: NSTextAlignment?
        public var imageData: Data?
        public var shape: EditOps.Shape?
        public init(kind: ContentKind, page: Int, rect: CGRect, text: String? = nil, fontName: String? = nil, fontSize: CGFloat? = nil,
                    color: NSColor? = nil, alignment: NSTextAlignment? = nil, imageData: Data? = nil, shape: EditOps.Shape? = nil) {
            self.kind = kind; self.page = page; self.rect = rect; self.text = text; self.fontName = fontName
            self.fontSize = fontSize; self.color = color; self.alignment = alignment; self.imageData = imageData; self.shape = shape
        }
    }

    @discardableResult
    public func addContent(_ id: String, _ req: ContentRequest) throws -> DocumentRecord {
        let (rec, doc) = try document(id, strict: true)
        let index = req.page - 1
        guard let page = doc.page(at: index) else { throw EzPDFError.invalidInput("No page \(req.page); the document has \(doc.pageCount).") }
        let space = EditOps.PageSpace(page)
        let size = space.size
        let r = req.rect
        guard r.width > 0, r.height > 0, r.width.isFinite, r.height.isFinite, r.minX > -size.width, r.minY > -size.height,
              r.minX < size.width, r.minY < size.height else {
            throw EzPDFError.invalidInput("That box is off the page (page is \(Int(size.width)) × \(Int(size.height)) points, origin top-left).")
        }
        let folder = library.folder(for: rec.id)
        switch req.kind {
        case .text:
            guard let t = req.text, !t.isEmpty else { throw EzPDFError.invalidInput("Give the text to add.") }
            try Objects.addText(doc, page: index, rect: r, text: t, font: EditOps.font(named: req.fontName, size: req.fontSize ?? 12),
                                color: req.color ?? .black, alignment: req.alignment ?? .left)
        case .image:
            guard let d = req.imageData else { throw EzPDFError.invalidInput("Give the image.") }
            try Objects.addImage(doc, page: index, rect: r, imageData: d, folder: folder)
        case .signature:
            if let d = req.imageData {
                try Objects.addImage(doc, page: index, rect: r, imageData: d, folder: folder)
            } else if let name = (req.text?.isEmpty == false ? req.text : UserDefaults.standard.string(forKey: "ezpdf.signatureName")), !name.isEmpty {
                let base = Objects.signatureFont(size: 10)
                let size = max(10, min(r.height * 0.75, EditOps.fittingSize(base, text: name, width: r.width)))
                try Objects.addText(doc, page: index, rect: r, text: name, font: Objects.signatureFont(size: size),
                                    color: req.color ?? NSColor(red: 0.05, green: 0.1, blue: 0.35, alpha: 1))
            } else {
                throw EzPDFError.invalidInput("Give the name to sign (text), or a signature image.")
            }
        case .shape:
            try EditOps.addShape(doc, page: index, shape: req.shape ?? .rectangle, rect: r, color: req.color ?? .systemRed)
            if let a = doc.page(at: index)?.annotations.last { a.userName = Objects.marker + Objects.newID() }
        case .whiteout:
            let bg = EditOps.backgroundColor(page, around: space.pageRect(r)) ?? .white
            try EditOps.compose(doc, page: index, overlays: [.fill(r, req.color ?? bg)])
        }
        return try commitEdit(rec.id, doc)
    }

    /// Signs with a typed name (or an image). With no box, it finds the place: just above a line
    /// that mentions a signature ("Signature", "Sign here", "Authorized by"), else the bottom right
    /// of the page (default: the last page).
    @discardableResult
    public func sign(_ id: String, name: String?, imageData: Data? = nil, page: Int? = nil, rect: CGRect? = nil) async throws -> (record: DocumentRecord, page: Int, rect: CGRect) {
        let (rec, doc) = try document(id, strict: true)
        let pageNumber = page ?? doc.pageCount
        guard pageNumber >= 1, pageNumber <= doc.pageCount else { throw EzPDFError.invalidInput("No page \(pageNumber).") }
        var box = rect
        if box == nil {
            let layout = try await pageLayout(rec.id, page: pageNumber)
            let cue = try! NSRegularExpression(pattern: #"(?i)\b(signature|sign here|signed|authori[sz]ed by|signatory)\b"#)
            if let line = layout.lines.last(where: { cue.firstMatch(in: $0.text, range: NSRange($0.text.startIndex..., in: $0.text)) != nil }) {
                let r = line.rect
                // On the same line, to the right of the label when there's room; else just above it.
                let x = r[0] + r[2] + 8
                box = x + 160 < layout.width - 20
                    ? CGRect(x: x, y: r[1] + r[3] - 34, width: 180, height: 38)
                    : CGRect(x: r[0], y: max(10, r[1] - 40), width: 180, height: 38)
            } else {
                let lastLineBottom = layout.lines.map { $0.rect[1] + $0.rect[3] }.max() ?? (layout.height * 0.7)
                let y = min(layout.height - 90, lastLineBottom + 40)
                box = CGRect(x: layout.width - 250, y: y, width: 200, height: 42)
            }
        }
        let saved = try addContent(rec.id, .init(kind: .signature, page: pageNumber, rect: box!, text: name, imageData: imageData))
        if let name, !name.isEmpty { UserDefaults.standard.set(name, forKey: "ezpdf.signatureName") }
        return (saved, pageNumber, box!)
    }

    // MARK: Templates

    /// Makes a new document from a template (blank, or with some fields filled) and returns it.
    @discardableResult
    public func create(template: DocTemplate, values: [String: String] = [:], title: String? = nil, source: JobSource = .app) async throws -> DocumentRecord {
        let data = try await TemplateRenderer.render(template, values: values)
        let rec = DocumentRecord(title: title ?? template.name, kind: .file, sourceFileName: "\(template.name) template", preset: PagePreset.letter.rawValue)
        return try library.add(rec, pdfData: data)
    }

    // MARK: Headers, footers, numbers, logos

    @discardableResult
    public func stamp(_ id: String, _ config: Stamps.Config) throws -> (record: DocumentRecord, pages: Int) {
        let (rec, doc) = try document(id, strict: true)
        let n = try Stamps.apply(doc, config, fileName: rec.sourceFileName ?? rec.title)
        guard n > 0 else { throw EzPDFError.invalidInput("Nothing to add: give header, footer, page number or logo text.") }
        return (try commitEdit(rec.id, doc), n)
    }

    // MARK: Objects

    public func objects(_ id: String) throws -> [Objects.Info] {
        let (_, doc) = try document(id)
        return Objects.list(doc)
    }

    public struct ObjectChange: Sendable {
        public var page: Int?          // 1-based; moves to another page
        public var rect: CGRect?       // top-left page points
        public var text: String?
        public var fontName: String?
        public var fontSize: CGFloat?
        public var color: NSColor?
        public init(page: Int? = nil, rect: CGRect? = nil, text: String? = nil, fontName: String? = nil, fontSize: CGFloat? = nil, color: NSColor? = nil) {
            self.page = page; self.rect = rect; self.text = text; self.fontName = fontName; self.fontSize = fontSize; self.color = color
        }
    }

    /// Moves, resizes or edits a placed object (text box, signature, image, box).
    @discardableResult
    /// `onPage` (1-based) is where the caller saw the object, preferred when looking it up.
    public func updateObject(_ id: String, object: String, onPage: Int? = nil, _ change: ObjectChange) throws -> DocumentRecord {
        let (rec, doc) = try document(id, strict: true)
        guard let (pageIndex, a) = Objects.find(doc, id: object, preferring: onPage.map { $0 - 1 }) else {
            throw EzPDFError.invalidInput("No object \(object) in “\(rec.title)”.")
        }
        var page = doc.page(at: pageIndex)!
        if let target = change.page, target - 1 != pageIndex {
            guard let dest = doc.page(at: target - 1) else { throw EzPDFError.invalidInput("No page \(target).") }
            // Same spot as shown on the new page (pages can differ in size, crop and rotation).
            let shown = EditOps.PageSpace(page).topLeft(a.bounds)
            page.removeAnnotation(a); dest.addAnnotation(a); page = dest
            a.bounds = EditOps.PageSpace(dest).pageRect(shown)
        }
        if let r = change.rect {
            guard r.width > 2, r.height > 2, r.width.isFinite, r.height.isFinite, r.minX.isFinite, r.minY.isFinite else {
                throw EzPDFError.invalidInput("That box is too small.")
            }
            a.bounds = EditOps.PageSpace(page).pageRect(r)
        }
        if a.type == "FreeText" {
            if let t = change.text { a.contents = t }
            if change.fontName != nil || change.fontSize != nil {
                let current = a.font ?? .systemFont(ofSize: 12)
                let size = change.fontSize ?? current.pointSize
                a.font = change.fontName.map { EditOps.font(named: $0, size: size) } ?? current.withSize(size)
            }
            if let c = change.color { a.fontColor = c }
            if change.text != nil || change.fontName != nil || change.fontSize != nil { Objects.refit(a, on: page) }
        } else if let c = change.color {
            a.color = c
        }
        Objects.clampToPage(a, on: page)
        return try commitEdit(rec.id, doc)
    }

    @discardableResult
    public func deleteObject(_ id: String, object: String, onPage: Int? = nil) throws -> DocumentRecord {
        let (rec, doc) = try document(id, strict: true)
        guard let (pageIndex, a) = Objects.find(doc, id: object, preferring: onPage.map { $0 - 1 }) else {
            throw EzPDFError.invalidInput("No object \(object).")
        }
        doc.page(at: pageIndex)?.removeAnnotation(a)
        // The image file stays while the undo copy uses it; commit clears files nothing uses.
        return try commitEdit(rec.id, doc)
    }

    /// The bytes to hand outside ezpdf: placed objects drawn into the pages when there are any
    /// (links, bookmarks, forms and markup kept), else the file as it is.
    public func deliverableData(_ id: String) throws -> Data {
        let rec = try record(id)
        let url = library.pdfURL(for: rec.id)
        guard let doc = PDFDocument(url: url), !doc.isLocked, Objects.hasObjects(doc) else { return try Data(contentsOf: url) }
        return try Objects.deliverable(doc, folder: library.folder(for: rec.id))
    }

    /// A temporary file of `deliverableData`, named after the document (for Share, Kindle, Shortcuts).
    public func deliverableFile(_ id: String, ext: String = "pdf") throws -> URL {
        let rec = try record(id)
        var name = rec.title.replacingOccurrences(of: "[/:\\\\?%*|\"<>\\p{Cc}]", with: " ", options: .regularExpression)
        name = String(name.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "."))).prefix(90))
        if name.isEmpty { name = "Document" }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ezpdf-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).\(ext)")
        try deliverableData(rec.id).write(to: url, options: .atomic)
        return url
    }

    public func formFields(_ id: String) throws -> [EditOps.FormField] {
        let (_, doc) = try document(id)
        return EditOps.formFields(doc)
    }

    @discardableResult
    public func fillForm(_ id: String, values: [String: String]) throws -> (record: DocumentRecord, filled: [String]) {
        let (rec, doc) = try document(id, strict: true)
        let filled = try EditOps.fillForm(doc, values: values)
        return (try commitEdit(rec.id, doc), filled)
    }

    /// Real redaction of every occurrence of `text` and/or the given boxes. The affected pages are
    /// rebuilt from pixels, so nothing under the boxes survives; their text is made searchable again.
    @discardableResult
    public func redact(_ id: String, text: String? = nil, boxes: [(page: Int, rect: CGRect)] = [], pages: String? = nil) async throws -> (record: DocumentRecord, count: Int, pages: [Int]) {
        // OCR takes a while; if something else saves the document meanwhile, redo the redaction on
        // the newer file rather than writing over that change.
        for _ in 0..<3 {
            let (rec, doc) = try document(id, strict: true)
            let revision = rec.modifiedAt
            let set = try pages.map { Set(try PageOps.pages($0, count: doc.pageCount)) }
            var byPage: [Int: [CGRect]] = [:]
            if let text, !text.isEmpty {
                for (p, rects) in EditOps.rects(of: text, in: doc, pages: set) { byPage[p, default: []] += rects }
            }
            for b in boxes where b.page >= 1 && b.page <= doc.pageCount { byPage[b.page - 1, default: []].append(b.rect) }
            let total = byPage.values.reduce(0) { $0 + $1.count }
            guard total > 0 else { throw EzPDFError.invalidInput(text.map { "“\($0)” doesn't appear in “\(rec.title)”." } ?? "Nothing to redact.") }
            for (p, rects) in byPage { try EditOps.redact(doc, page: p, rects: rects) }
            // Make the rebuilt pages searchable again, off the main thread on a private copy.
            guard let raw = doc.dataRepresentation() else { throw EzPDFError.failed("Couldn't save the redaction.") }
            let ocr = await Task.detached(priority: .userInitiated) { () -> Data? in
                guard let own = PDFDocument(data: raw) else { return nil }
                return PageOps.makeSearchable(own)
            }.value
            guard try record(rec.id, strict: true).modifiedAt == revision else { continue }
            let saved = try commitEditData(rec.id, ocr ?? raw)
            return (saved, total, byPage.keys.sorted().map { $0 + 1 })
        }
        throw EzPDFError.failed("The document kept changing while redacting; nothing was redacted. Try again.")
    }

    public func listAnnotations(_ id: String) throws -> [EditOps.AnnotationInfo] {
        let (_, doc) = try document(id)
        return EditOps.listAnnotations(doc)
    }

    @discardableResult
    public func removeAnnotations(_ id: String, pages: String? = nil, types: [String]? = nil) throws -> (record: DocumentRecord, count: Int) {
        let (rec, doc) = try document(id, strict: true)
        let set = try pages.map { Set(try PageOps.pages($0, count: doc.pageCount)) }
        let n = EditOps.removeAnnotations(doc, pages: set, types: types.map(Set.init))
        guard n > 0 else { throw EzPDFError.invalidInput("No matching annotations.") }
        return (try commitEdit(rec.id, doc), n)
    }

    @discardableResult
    public func flatten(_ id: String) throws -> DocumentRecord {
        let (rec, doc) = try document(id, strict: true)
        // Placed objects first (an image is only a placeholder until it's drawn in), then the rest.
        let source = Objects.hasObjects(doc) ? PDFDocument(data: try Objects.deliverable(doc, folder: library.folder(for: rec.id))) : doc
        guard let source, let data = EditOps.flatten(source) else { throw EzPDFError.failed("Couldn't flatten.") }
        return try commitEditData(rec.id, data)
    }

    @discardableResult
    public func setProperties(_ id: String, title: String?, author: String?, subject: String?, keywords: [String]?) throws -> DocumentRecord {
        let (rec, doc) = try document(id, strict: true)
        EditOps.setMetadata(doc, title: title, author: author, subject: subject, keywords: keywords)
        var out = try commitEdit(rec.id, doc)
        if let title, !title.isEmpty { out = try rename(rec.id, title: title) }
        return out
    }

    // Edits go through the same validated, undoable commit as page operations.
    func commitEdit(_ id: String, _ doc: PDFDocument, caller: String = #function) throws -> DocumentRecord {
        guard let data = doc.dataRepresentation() else { throw EzPDFError.failed("Couldn't save the change.") }
        return try commitEditData(id, data, caller: caller)
    }
}

/// Colors from agents and settings: "#RRGGBB", "red", "blue"…
public enum ColorName {
    public static func parse(_ s: String?) -> NSColor? {
        guard var t = s?.trimmingCharacters(in: .whitespaces).lowercased(), !t.isEmpty else { return nil }
        let named: [String: NSColor] = ["black": .black, "white": .white, "red": .systemRed, "blue": .systemBlue, "green": .systemGreen,
                                        "yellow": .systemYellow, "orange": .systemOrange, "purple": .systemPurple, "gray": .gray, "grey": .gray,
                                        "navy": NSColor(red: 0.05, green: 0.1, blue: 0.35, alpha: 1)]
        if let c = named[t] { return c }
        if t.hasPrefix("#") { t.removeFirst() }
        guard t.count == 6, let v = UInt32(t, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

// MARK: Fonts

extension EzPDF {
    /// Whether ezpdf may fetch open-licensed fonts a document uses (Settings › General).
    public static let fetchFontsKey = "ezpdf.fetchFonts"
    public static var mayFetchFonts: Bool { UserDefaults.standard.object(forKey: fetchFontsKey) as? Bool ?? true }

    /// Makes the document's fonts available for edits (see `Fonts.prepare`), once per document per launch.
    @discardableResult
    public func prepareFonts(_ id: String, force: Bool = false) async -> [Fonts.Status] {
        guard let rec = try? record(id) else { return [] }
        if !force, let done = fontsPrepared[rec.id] { return done }
        guard let doc = PDFDocument(url: library.pdfURL(for: rec.id)), !doc.isLocked else { return [] }
        let status = await Fonts.prepare(doc, allowDownload: Self.mayFetchFonts)
        fontsPrepared[rec.id] = status
        return status
    }
}
