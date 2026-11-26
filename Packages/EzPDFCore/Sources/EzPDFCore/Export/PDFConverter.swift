import Foundation
import PDFKit
import ImageIO
import UniformTypeIdentifiers

/// PDF → other formats: Word, Markdown, plain text, and page images (PNG or JPEG).
/// Runs on its own copy of the PDF, so it can work off the main thread.
public enum PDFConverter {
    public enum Format: String, Codable, Sendable, CaseIterable {
        case docx, md, txt, png, jpg

        public var label: String {
            switch self {
            case .docx: return "Word"
            case .md: return "Markdown"
            case .txt: return "Plain Text"
            case .png: return "PNG"
            case .jpg: return "JPEG"
            }
        }
        public var isImage: Bool { self == .png || self == .jpg }
    }

    public struct Options: Sendable {
        /// Page range like "1-3,5"; nil for all.
        public var pages: String?
        /// Images: pixels per inch (default 150).
        public var dpi: Int?
        /// JPEG quality 0…1 (default 0.85).
        public var quality: Double?
        public init(pages: String? = nil, dpi: Int? = nil, quality: Double? = nil) {
            self.pages = pages; self.dpi = dpi; self.quality = quality
        }
    }

    public struct File: Sendable {
        /// Relative path: a file name, or "folder/name" for a page image or a Markdown figure.
        public var path: String
        public var data: Data
    }

    public struct Output: Sendable {
        /// The main file first (for images: every page in order).
        public var files: [File]
        /// Things worth telling the person (pages read with OCR, a large image set…).
        public var notes: [String]
    }

    /// Most pages turned into images in one go.
    public static let maxImagePages = 500

    /// Every file in memory. For many page images use the `emit` version, which hands each file
    /// over as soon as it's made.
    public static func convert(_ pdf: Data, title: String, format: Format, options: Options = .init(),
                               progress: ((String) -> Void)? = nil) async throws -> Output {
        var files: [File] = []
        let notes = try await convert(pdf, title: title, format: format, options: options, progress: progress) { files.append($0) }
        return Output(files: files, notes: notes)
    }

    /// Hands each file to `emit` as it's made (main file first; page images in order), so page
    /// images never all sit in memory. Returns the notes.
    public static func convert(_ pdf: Data, title: String, format: Format, options: Options = .init(),
                               progress: ((String) -> Void)? = nil, emit: (File) throws -> Void) async throws -> [String] {
        guard let doc = PDFDocument(data: pdf) else { throw EzPDFError.failed("Couldn't read the PDF.") }
        if doc.isLocked { throw EzPDFError.invalidInput("That PDF has a password. Unlock it first.") }
        let pages = try PageOps.pages(options.pages, count: doc.pageCount)
        guard !pages.isEmpty else { throw EzPDFError.invalidInput("No pages to convert.") }
        let name = fileName(title)

        if format.isImage {
            guard pages.count <= maxImagePages else {
                throw EzPDFError.invalidInput("That's \(pages.count) pages; ezpdf makes images of up to \(maxImagePages) at a time. Give a page range.")
            }
            let dpi = min(max(options.dpi ?? 150, 36), 600)
            let quality = min(max(options.quality ?? 0.85, 0.1), 1)
            let digits = String(doc.pageCount).count
            for (n, i) in pages.enumerated() {
                progress?("Page \(n + 1) of \(pages.count)")
                // Each render is large; let it go before the next page.
                let data = autoreleasepool { doc.page(at: i).flatMap { image($0, format: format, dpi: dpi, quality: quality) } }
                guard let data else { throw EzPDFError.failed("Couldn't render page \(i + 1).") }
                let number = String(repeating: "0", count: max(0, digits - String(i + 1).count)) + String(i + 1)
                let file = pages.count == 1 ? "\(name)\(doc.pageCount > 1 ? " page \(i + 1)" : "").\(format.rawValue)"
                                            : "\(name) images/\(name) page \(number).\(format.rawValue)"
                try emit(File(path: file, data: data))
            }
            return []
        }

        let structured = await StructuredText.read(doc, pages: pages, options: .init(tables: true, figures: format != .txt)) { n, total in
            progress?("Reading page \(n) of \(total)")
        }
        var notes: [String] = []
        if structured.scannedPages > 0 {
            notes.append("\(structured.scannedPages) scanned page\(structured.scannedPages == 1 ? " was" : "s were") read with OCR on this Mac")
        }
        if structured.blocks.isEmpty { throw EzPDFError.invalidInput("There's no text in those pages to convert.") }
        switch format {
        case .docx:
            try emit(File(path: "\(name).docx", data: DocumentWriters.docx(structured)))
        case .txt:
            try emit(File(path: "\(name).txt", data: Data(DocumentWriters.plainText(structured).utf8)))
        case .md:
            let folder = "\(name) images"
            let text = DocumentWriters.markdown(structured) { "\(folder)/figure-\($0).jpg" }
            try emit(File(path: "\(name).md", data: Data(text.utf8)))
            var k = 0
            for case .figure(let f) in structured.blocks {
                k += 1
                try emit(File(path: "\(folder)/figure-\(k).jpg", data: f.jpeg))
            }
        case .png, .jpg:
            break       // written above
        }
        return notes
    }

    /// The page as shown, with its annotations, at `dpi`, with the resolution recorded in the file.
    static func image(_ page: PDFPage, format: Format, dpi: Int, quality: Double) -> Data? {
        guard let cg = PDFRaster.cgImage(page, scale: CGFloat(dpi) / 72) else { return nil }
        let size = EditOps.PageSpace(page).size
        let actualDPI = Double(cg.width) / Double(size.width) * 72       // lower if the page was too big
        let out = NSMutableData()
        let type: UTType = format == .png ? .png : .jpeg
        guard let dst = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [kCGImagePropertyDPIWidth: actualDPI, kCGImagePropertyDPIHeight: actualDPI]
        if format == .jpg { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dst, cg, props as CFDictionary)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }

    /// A file name from a title: no path characters, no control characters, not hidden.
    static func fileName(_ s: String) -> String {
        var n = s.replacingOccurrences(of: "[/:\\\\?%*|\"<>\\p{Cc}]", with: " ", options: .regularExpression)
        n = n.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        n = String(n.prefix(90)).trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "Document" : n
    }
}
