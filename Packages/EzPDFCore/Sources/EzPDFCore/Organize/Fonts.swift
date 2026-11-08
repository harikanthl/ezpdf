import Foundation
import AppKit
import PDFKit
import CoreText

/// Getting a document's own fonts onto this Mac, so edits are set in the same type.
///
/// For each font a document uses, in order:
/// 1. Already here (installed, or fetched before): nothing to do.
/// 2. Embedded in the PDF in full (not a subset): registered for ezpdf from the PDF itself.
///    Subsets ("ABCDEF+Name") only hold the letters the document uses, so they're not used for new words.
/// 3. An open-licensed family (OFL, Apache, UFL) in the Google Fonts collection: downloaded to
///    ezpdf's fonts folder and registered. Calibri and Cambria get their metric-compatible open
///    twins, Carlito and Caladea (same widths, so lines break the same way).
/// 4. Otherwise not available; edits use the closest system face and say so.
/// Fonts are registered for ezpdf only (not installed for every app).
public enum Fonts {
    public enum Source: String, Codable, Sendable { case installed, embedded, downloaded, substituteDownloaded = "substitute_downloaded", unavailable }

    public struct Status: Codable, Sendable {
        public var name: String           // as the PDF names it, without a subset prefix
        public var source: Source
        public var detail: String
    }

    /// Open twins with the same metrics as common fonts that aren't on a Mac.
    static let metricTwins: [String: String] = ["calibri": "Carlito", "cambria": "Caladea"]

    static var folder: URL {
        let base = ProcessInfo.processInfo.environment["EZPDF_LIBRARY"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).deletingLastPathComponent() }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ezpdf")
        return base.appendingPathComponent("Fonts", isDirectory: true)
    }

    nonisolated(unsafe) private static var registeredSaved = false
    private static let lock = NSLock()

    /// Registers the fonts fetched before (once per launch).
    public static func registerSaved() {
        lock.lock(); defer { lock.unlock() }
        guard !registeredSaved else { return }
        registeredSaved = true
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            + ((try? FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("from-documents"), includingPropertiesForKeys: nil)) ?? [])
        let fonts = files.filter { ["ttf", "otf", "ttc"].contains($0.pathExtension.lowercased()) }
        if !fonts.isEmpty { CTFontManagerRegisterFontURLs(fonts as CFArray, .process, true, nil) }
    }

    // MARK: Names

    /// "ABCDEF+OpenSans-SemiBoldItalic" → "OpenSans-SemiBoldItalic".
    public static func baseName(_ pdfName: String) -> String {
        if let plus = pdfName.firstIndex(of: "+"), pdfName.distance(from: pdfName.startIndex, to: plus) == 6 {
            return String(pdfName[pdfName.index(after: plus)...])
        }
        return pdfName
    }

    /// Family, weight (NSFontManager scale 1…14) and italic from a PostScript-style name.
    static func parts(_ name: String) -> (family: String, weight: Int, italic: Bool) {
        let base = baseName(name)
        let split = base.split(separator: "-", maxSplits: 1).map(String.init)
        var family = split[0].replacingOccurrences(of: ",", with: " ")
        var style = split.count > 1 ? split[1].lowercased() : ""
        // "TimesNewRomanPS-BoldMT", "Arial,Bold", "CalibriLight"
        for suffix in ["PSMT", "MT", "PS"] where family.hasSuffix(suffix) { family.removeLast(suffix.count) }
        for w in ["Light", "Bold", "Semibold", "SemiBold", "Medium", "Black", "Thin"] where family.hasSuffix(w) && family.count > w.count + 2 {
            family.removeLast(w.count); style += w.lowercased()
        }
        let weight: Int
        switch true {
        case style.contains("thin"), style.contains("hairline"): weight = 2
        case style.contains("extralight"), style.contains("ultralight"): weight = 3
        case style.contains("light"): weight = 4
        case style.contains("medium"): weight = 6
        case style.contains("semibold"), style.contains("demibold"): weight = 8
        case style.contains("extrabold"), style.contains("ultrabold"): weight = 10
        case style.contains("black"), style.contains("heavy"): weight = 11
        case style.contains("bold"): weight = 9
        default: weight = 5
        }
        // "OpenSans" → "Open Sans" for family lookups.
        let spaced = family.replacingOccurrences(of: #"([a-z])([A-Z])"#, with: "$1 $2", options: .regularExpression)
        return (spaced, weight, style.contains("italic") || style.contains("oblique"))
    }

    /// The font for a PDF font name at a size, if this Mac has it (by exact name, or by family,
    /// weight and slant).
    public static func installed(_ pdfName: String, size: CGFloat) -> NSFont? {
        registerSaved()
        let base = baseName(pdfName)
        if let f = NSFont(name: base, size: size) { return f }
        let p = parts(base)
        let traits: NSFontTraitMask = p.italic ? .italicFontMask : []
        for family in [p.family, p.family.replacingOccurrences(of: " ", with: "")] {
            if let f = NSFontManager.shared.font(withFamily: family, traits: traits, weight: p.weight, size: size) { return f }
        }
        if let twin = metricTwins[p.family.lowercased().replacingOccurrences(of: " ", with: "")],
           let f = NSFontManager.shared.font(withFamily: twin, traits: traits, weight: p.weight, size: size) {
            return f
        }
        return nil
    }

    /// The font a document really uses for text PDFKit reports in `reported`. When the PDF's font
    /// isn't on this Mac, PDFKit reports a stand-in (often Helvetica); if the page uses exactly one
    /// font that isn't here, that's the one meant. Otherwise the reported name stands.
    public static func documentFontName(reported: String, page: PDFPage) -> String {
        let base = baseName(reported)
        let names = Set(fontNames(on: page).keys.map(baseName))
        if names.isEmpty || names.contains(base) { return base }
        let missing = names.filter { NSFont(name: $0, size: 12) == nil }
        return missing.count == 1 ? missing.first! : base
    }

    // MARK: Making them available

    /// The fonts a document uses (BaseFont name → font dictionary), from the first 200 pages.
    static func fontNames(in doc: PDFDocument) -> [String: CGPDFDictionaryRef] {
        var all: [String: CGPDFDictionaryRef] = [:]
        for i in 0..<min(doc.pageCount, 200) {
            guard let page = doc.page(at: i) else { continue }
            all.merge(fontNames(on: page)) { first, _ in first }
        }
        return all
    }

    /// The fonts one page's resources name (BaseFont name → font dictionary).
    static func fontNames(on page: PDFPage) -> [String: CGPDFDictionaryRef] {
        final class Found { var fonts: [String: CGPDFDictionaryRef] = [:] }
        let found = Found()
        guard let dict = page.pageRef?.dictionary else { return [:] }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources else { return [:] }
        var fonts: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "Font", &fonts), let fonts else { return [:] }
        CGPDFDictionaryApplyBlock(fonts, { _, object, info in
            var font: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &font), let font else { return true }
            var namePtr: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(font, "BaseFont", &namePtr), let namePtr else { return true }
            Unmanaged<Found>.fromOpaque(info!).takeUnretainedValue().fonts[String(cString: namePtr)] = font
            return true
        }, Unmanaged.passUnretained(found).toOpaque())
        return found.fonts
    }

    /// The font program embedded for a font (TrueType or OpenType/CFF), if any.
    static func embeddedProgram(_ font: CGPDFDictionaryRef) -> Data? {
        var descriptor: CGPDFDictionaryRef?
        if !CGPDFDictionaryGetDictionary(font, "FontDescriptor", &descriptor) {
            // Composite (Type0) fonts keep it in their descendant.
            var descendants: CGPDFArrayRef?
            var child: CGPDFDictionaryRef?
            if CGPDFDictionaryGetArray(font, "DescendantFonts", &descendants), let descendants,
               CGPDFArrayGetDictionary(descendants, 0, &child), let child {
                _ = CGPDFDictionaryGetDictionary(child, "FontDescriptor", &descriptor)
            }
        }
        guard let descriptor else { return nil }
        for key in ["FontFile2", "FontFile3"] {
            var stream: CGPDFStreamRef?
            if CGPDFDictionaryGetStream(descriptor, key, &stream), let stream {
                var format = CGPDFDataFormat.raw
                if let data = CGPDFStreamCopyData(stream, &format), format == .raw { return data as Data }
            }
        }
        return nil
    }

    /// Makes every font the document uses available to ezpdf where it can, and reports each one.
    /// `allowDownload` lets it fetch open-licensed families.
    public static func prepare(_ doc: PDFDocument, allowDownload: Bool = true) async -> [Status] {
        registerSaved()
        var out: [Status] = []
        var seen = Set<String>()
        for (pdfName, dict) in fontNames(in: doc).sorted(by: { $0.key < $1.key }) {
            let base = baseName(pdfName)
            guard seen.insert(base).inserted else { continue }
            if installed(base, size: 12) != nil {
                let twin = NSFont(name: base, size: 12) == nil && metricTwins[parts(base).family.lowercased().replacingOccurrences(of: " ", with: "")] != nil
                out.append(Status(name: base, source: twin ? .substituteDownloaded : .installed, detail: twin ? "Using its open twin with the same widths." : "On this Mac."))
                continue
            }
            // A full embedded font (no subset prefix) is the document's own type: use it.
            if pdfName == base, let program = embeddedProgram(dict), register(program) {
                out.append(Status(name: base, source: .embedded, detail: "Taken from the document itself."))
                continue
            }
            if allowDownload, let detail = await download(family: parts(base).family) {
                out.append(Status(name: base, source: .downloaded, detail: detail))
                continue
            }
            let twinFamily = metricTwins[parts(base).family.lowercased().replacingOccurrences(of: " ", with: "")]
            if allowDownload, let twinFamily, let detail = await download(family: twinFamily) {
                out.append(Status(name: base, source: .substituteDownloaded, detail: "Not freely available; fetched its open twin with the same widths. " + detail))
                continue
            }
            out.append(Status(name: base, source: .unavailable,
                              detail: pdfName != base ? "Only part of it is in the document, and it isn't open-licensed; edits use the closest font on this Mac."
                                                      : "Not on this Mac and not open-licensed; edits use the closest font on this Mac."))
        }
        return out
    }

    /// Keeps an embedded font program in ezpdf's fonts folder (named by its content, so each is kept
    /// once) and registers it for ezpdf. True when it's a usable font.
    static func register(_ data: Data) -> Bool {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor], !descriptors.isEmpty else { return false }
        let dir = folder.appendingPathComponent("from-documents", isDirectory: true)
        let file = dir.appendingPathComponent(String(format: "%016llx", contentHash(data)) + ".otf")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file.path) { try data.write(to: file, options: .atomic) }
        } catch { return false }
        CTFontManagerRegisterFontURLs([file] as CFArray, .process, true, nil)
        return true
    }

    /// FNV-1a: a stable name for a font file.
    static func contentHash(_ data: Data) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in data { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    // MARK: Google Fonts (open-licensed families)

    /// Fetches a family's font files from the Google Fonts collection (github.com/google/fonts) into
    /// ezpdf's fonts folder and registers them. Returns a description, or nil when there's no such
    /// open family.
    static func download(family: String) async -> String? {
        let dirName = family.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !dirName.isEmpty, dirName.count <= 60 else { return nil }
        for license in ["ofl", "apache", "ufl"] {
            guard let api = URL(string: "https://api.github.com/repos/google/fonts/contents/\(license)/\(dirName)") else { continue }
            var request = URLRequest(url: api, timeoutInterval: 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("ezpdf", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            let files = items.compactMap { item -> (String, URL)? in
                guard let name = item["name"] as? String, ["ttf", "otf"].contains((name as NSString).pathExtension.lowercased()),
                      let raw = item["download_url"] as? String, let url = URL(string: raw),
                      url.scheme == "https", url.host == "raw.githubusercontent.com" else { return nil }
                return (name, url)
            }
            guard !files.isEmpty else { continue }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var saved: [URL] = []
            for (name, url) in files.prefix(24) {
                let safe = name.replacingOccurrences(of: "/", with: "_")
                let dest = folder.appendingPathComponent(safe)
                if FileManager.default.fileExists(atPath: dest.path) { saved.append(dest); continue }
                let dl = GuardedDownload()
                defer { dl.finish() }
                guard case .data(let bytes, _)? = try? await dl.fetch(url, maxBytes: 15_000_000),
                      let descriptors = CTFontManagerCreateFontDescriptorsFromData(bytes as CFData) as? [CTFontDescriptor], !descriptors.isEmpty,
                      (try? bytes.write(to: dest, options: .atomic)) != nil else { continue }
                saved.append(dest)
            }
            guard !saved.isEmpty else { continue }
            CTFontManagerRegisterFontURLs(saved as CFArray, .process, true, nil)
            return "Downloaded the open-licensed \(family) (\(license.uppercased())) from the Google Fonts collection."
        }
        return nil
    }
}
