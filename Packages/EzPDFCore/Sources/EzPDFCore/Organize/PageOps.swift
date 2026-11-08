import Foundation
import PDFKit

/// Page-level edits. All take and return whole documents so the library can version them.
public enum PageOps {
    /// Parses "1-3, 5, 8-" (1-based, inclusive; "8-" means to the end) into 0-based indices.
    /// Empty or "all" means every page.
    public static func pages(_ spec: String?, count: Int) throws -> [Int] {
        guard let spec = spec?.trimmingCharacters(in: .whitespaces), !spec.isEmpty, spec.lowercased() != "all" else {
            return Array(0..<count)
        }
        var out: [Int] = []
        for part in spec.split(separator: ",") {
            let p = part.trimmingCharacters(in: .whitespaces).lowercased()
            if p == "last" { out.append(count - 1); continue }
            let bits = p.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if bits.count == 1, let n = Int(bits[0]) {
                out.append(n - 1)
            } else if bits.count == 2 {
                let a = bits[0].isEmpty ? 1 : Int(bits[0])
                let b = bits[1].isEmpty || bits[1] == "end" || bits[1] == "last" ? count : Int(bits[1])
                guard let a, let b, a <= b else { throw EzPDFError.invalidInput("Bad page range “\(part)”.") }
                out.append(contentsOf: (a - 1)...(b - 1))
            } else {
                throw EzPDFError.invalidInput("Bad page range “\(part)”. Use forms like 1-3, 5, 8-.")
            }
        }
        if let bad = out.first(where: { $0 < 0 || $0 >= count }) {
            throw EzPDFError.invalidInput("Page \(bad + 1) doesn't exist; the document has \(count) pages.")
        }
        return out
    }

    public static func append(_ src: PDFDocument, to dst: PDFDocument) {
        for i in 0..<src.pageCount {
            if let p = src.page(at: i)?.copy() as? PDFPage { dst.insert(p, at: dst.pageCount) }
        }
    }

    public static func rotate(_ doc: PDFDocument, pages: [Int], degrees: Int) throws {
        guard degrees % 90 == 0 else { throw EzPDFError.invalidInput("Rotate by 90, 180 or 270 degrees.") }
        for i in Set(pages) { if let p = doc.page(at: i) { p.rotation = ((p.rotation + degrees) % 360 + 360) % 360 } }
    }

    public static func delete(_ doc: PDFDocument, pages: [Int]) throws {
        guard Set(pages).count < doc.pageCount else { throw EzPDFError.invalidInput("That would delete every page.") }
        for i in Set(pages).sorted(by: >) { doc.removePage(at: i) }
    }

    /// New document with just these pages, in the order given.
    public static func extract(_ doc: PDFDocument, pages: [Int]) -> PDFDocument {
        let out = PDFDocument()
        for i in pages { if let p = doc.page(at: i)?.copy() as? PDFPage { out.insert(p, at: out.pageCount) } }
        out.documentAttributes = doc.documentAttributes
        return out
    }

    /// Moves `pages` (keeping their order) so they start at 0-based position `to` of the result.
    public static func move(_ doc: PDFDocument, pages: [Int], to: Int) {
        let set = Set(pages)
        let moving = pages.compactMap { doc.page(at: $0) }
        let staying = (0..<doc.pageCount).filter { !set.contains($0) }.compactMap { doc.page(at: $0) }
        let target = max(0, min(to, staying.count))
        let order = Array(staying[..<target]) + moving + Array(staying[target...])
        for i in (0..<doc.pageCount).reversed() { doc.removePage(at: i) }
        for (i, p) in order.enumerated() { doc.insert(p, at: i) }
    }

    /// Puts pages in exactly this order (a permutation or subset).
    public static func reorder(_ doc: PDFDocument, order: [Int]) -> PDFDocument { extract(doc, pages: order) }

    public static func insertBlank(_ doc: PDFDocument, after index: Int) {
        let size = doc.page(at: max(0, min(index, doc.pageCount - 1)))?.bounds(for: .mediaBox).size ?? CGSize(width: 612, height: 792)
        let page = PDFPage()
        page.setBounds(CGRect(origin: .zero, size: size), for: .mediaBox)
        doc.insert(page, at: min(index + 1, doc.pageCount))
    }

    /// Splits into consecutive chunks of `every` pages, or at explicit 1-based start pages.
    public static func split(_ doc: PDFDocument, every: Int?, at starts: [Int]?) throws -> [PDFDocument] {
        var bounds: [Int] = []
        if let every, every > 0 { bounds = Array(stride(from: 0, to: doc.pageCount, by: every)) }
        else if let starts, !starts.isEmpty { bounds = ([0] + starts.map { $0 - 1 }).filter { $0 >= 0 && $0 < doc.pageCount } }
        else { throw EzPDFError.invalidInput("Say how to split: every N pages, or the pages where new parts start.") }
        bounds = Array(Set(bounds)).sorted()
        return bounds.enumerated().map { i, start in
            let end = i + 1 < bounds.count ? bounds[i + 1] : doc.pageCount
            return extract(doc, pages: Array(start..<end))
        }
    }

    // MARK: Whole-document

    public enum CompressLevel: String, Sendable { case light, strong }

    /// Recompresses images. `strong` also downsamples them to screen resolution.
    public static func compress(_ doc: PDFDocument, level: CompressLevel) -> Data? {
        var opts: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true]
        if level == .strong { opts[.optimizeImagesForScreenOption] = true }
        return doc.dataRepresentation(options: opts)
    }

    /// Adds an invisible text layer to scanned pages so they can be searched and copied.
    public static func makeSearchable(_ doc: PDFDocument) -> Data? {
        let opts: [PDFDocumentWriteOption: Any] = [PDFDocumentWriteOption.saveTextFromOCROption: true]
        return doc.dataRepresentation(options: opts)
    }

    public static func protect(_ doc: PDFDocument, password: String, ownerPassword: String?, allowPrinting: Bool, allowCopying: Bool) -> Data? {
        // PDFAccessPermissions bits: 1 low-quality print, 2 high-quality print, 16 copy, 32 accessibility.
        var perms: UInt = 32
        if allowPrinting { perms |= 1 | 2 }
        if allowCopying { perms |= 16 }
        let owner: String = ownerPassword ?? (password + "-owner-" + String(UUID().uuidString.prefix(8)))
        let opts: [PDFDocumentWriteOption: Any] = [
            .userPasswordOption: password,
            .ownerPasswordOption: owner,
            .accessPermissionsOption: NSNumber(value: perms),
        ]
        return doc.dataRepresentation(options: opts)
    }

    public static func unlock(_ data: Data, password: String) throws -> Data {
        guard let doc = PDFDocument(data: data) else { throw EzPDFError.invalidInput("Not a PDF.") }
        if doc.isLocked, !doc.unlock(withPassword: password) { throw EzPDFError.invalidInput("Wrong password.") }
        guard let out = doc.dataRepresentation() else { throw EzPDFError.failed("Couldn't save the unlocked copy.") }
        return out
    }

    /// Small page numbers centered in the bottom margin.
    public static func addPageNumbers(_ doc: PDFDocument, format: String = "{n} / {total}") {
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let b = page.bounds(for: .cropBox)
            let text = format.replacingOccurrences(of: "{n}", with: "\(i + 1)").replacingOccurrences(of: "{total}", with: "\(doc.pageCount)")
            let a = PDFAnnotation(bounds: CGRect(x: b.midX - 60, y: b.minY + 14, width: 120, height: 14), forType: .freeText, withProperties: nil)
            a.contents = text
            a.font = NSFont.systemFont(ofSize: 8)
            a.fontColor = .secondaryLabelColor
            a.color = .clear
            a.alignment = .center
            a.border = PDFBorder()
            a.border?.lineWidth = 0
            page.addAnnotation(a)
        }
    }

    public static func watermark(_ doc: PDFDocument, text: String) {
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let b = page.bounds(for: .cropBox)
            let a = PDFAnnotation(bounds: CGRect(x: b.minX, y: b.midY - 30, width: b.width, height: 60), forType: .freeText, withProperties: nil)
            a.contents = text
            a.font = NSFont.boldSystemFont(ofSize: min(48, b.width / CGFloat(max(4, text.count)) * 1.6))
            a.fontColor = NSColor.gray.withAlphaComponent(0.25)
            a.color = .clear
            a.alignment = .center
            a.border = PDFBorder()
            a.border?.lineWidth = 0
            page.addAnnotation(a)
        }
    }

    // MARK: Annotations

    /// Highlights every occurrence of `text` (case-insensitive). Returns the number highlighted.
    @discardableResult
    public static func highlight(_ doc: PDFDocument, text: String, color: NSColor = .systemYellow, pages: Set<Int>? = nil) -> Int {
        var n = 0
        for sel in doc.findString(text, withOptions: [.caseInsensitive, .diacriticInsensitive]) {
            for line in sel.selectionsByLine() {
                for page in line.pages {
                    let index = doc.index(for: page)
                    if let pages, !pages.contains(index) { continue }
                    let a = PDFAnnotation(bounds: line.bounds(for: page), forType: .highlight, withProperties: nil)
                    a.color = color.withAlphaComponent(0.5)
                    page.addAnnotation(a)
                    n += 1
                }
            }
        }
        return n
    }

    public static func addNote(_ doc: PDFDocument, page index: Int, text: String) throws {
        guard let page = doc.page(at: index) else { throw EzPDFError.invalidInput("No page \(index + 1).") }
        let b = page.bounds(for: .cropBox)
        let a = PDFAnnotation(bounds: CGRect(x: b.maxX - 44, y: b.maxY - 44, width: 20, height: 20), forType: .text, withProperties: nil)
        a.contents = text
        a.color = .systemYellow
        page.addAnnotation(a)
    }
}
