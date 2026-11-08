import SwiftUI
import PDFKit
import AVFoundation
import EzPDFCore

enum ReadingTheme: String, CaseIterable, Identifiable {
    case system = "Default", sepia = "Sepia", night = "Night"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .sepia: return "sun.max"
        case .night: return "moon.stars"
        }
    }
}

/// Owns one PDFView. Adapted from MuseDrop's PaperReaderController: navigation, zoom, outline,
/// search, themes and read-aloud, plus highlights, notes and resume-where-you-left-off.
@MainActor
final class ReaderController: NSObject, ObservableObject {
    struct OutlineItem: Identifiable {
        let id = UUID()
        let label: String
        let level: Int
        let destination: PDFDestination?
        let page: Int
    }

    let pdfView = EditablePDFView()
    /// Asks the view to edit an object (double-click / Return): the object id and its current state.
    var onEditObject: ((String, PDFAnnotation) -> Void)?
    private(set) var documentID: String?

    @Published var pageCount = 0
    @Published var currentPageIndex = 0
    @Published var outline: [OutlineItem] = []
    @Published var theme: ReadingTheme = ReadingTheme(rawValue: UserDefaults.standard.string(forKey: "ezpdf.theme") ?? "") ?? .system
    @Published var isSpeaking = false
    @Published var speechRate: Float = UserDefaults.standard.object(forKey: "ezpdf.speechRate") as? Float ?? 0.5
    @Published var zoomPercent = 100
    @Published var matchCount = 0
    @Published var currentMatch = 0
    @Published var twoUp = false
    @Published var hasSelection = false
    @Published var unsavedAnnotations = false
    /// When this reader last saved the document; its own saves don't trigger a reload.
    private(set) var lastSavedModifiedAt: Date?
    /// The file version currently shown.
    private(set) var loadedModifiedAt: Date?

    private var matches: [PDFSelection] = []
    private let synthesizer = AVSpeechSynthesizer()
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private var saveTask: Task<Void, Never>?
    /// Highlights and notes added since the last save. Saving merges these onto the file on disk
    /// rather than writing this window's copy over it, so edits made meanwhile survive.
    private var pending: [(page: Int, annotation: PDFAnnotation)] = []
    /// True while opening a document, so the initial scroll doesn't overwrite the saved page.
    private var restoring = false

    override init() {
        super.init()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .underPageBackgroundColor
        pdfView.wantsLayer = true
        pdfView.pageShadowsEnabled = true
        pdfView.pageBreakMargins = NSEdgeInsets(top: 6, left: 6, bottom: 10, right: 6)
        synthesizer.delegate = self
        pdfView.onCommit = { [weak self] a, page in self?.commitObject(a, on: page) }
        pdfView.onDelete = { [weak self] a, page in self?.deleteObject(a, on: page) }
        pdfView.onEdit = { [weak self] a, _ in
            guard let id = Objects.objectID(a) else { return }
            self?.onEditObject?(id, a)
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncPage() }
        })
        observers.append(center.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncZoom() }
        })
        observers.append(center.addObserver(forName: .PDFViewSelectionChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hasSelection = !(self?.pdfView.currentSelection?.string ?? "").isEmpty }
        })
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    func load(_ rec: DocumentRecord, url: URL, page: Int? = nil) {
        flushAnnotations()
        let sameDocument = documentID == rec.id
        if !sameDocument {
            stopSpeaking()
            clearSearch()
        }
        documentID = rec.id
        loadedModifiedAt = Library.shared.record(rec.id)?.modifiedAt ?? rec.modifiedAt
        restoring = true
        guard let document = PDFDocument(url: url) else { pdfView.document = nil; pageCount = 0; return }
        pdfView.select(nil, on: nil)
        Objects.hydrate(document, folder: Library.shared.folder(for: rec.id))
        pdfView.document = document
        pageCount = document.pageCount
        buildOutline(document)
        setTheme(theme)
        let start = (page.map { $0 - 1 }) ?? rec.lastPage
        // PDFView ignores go(to:) until it has laid the document out.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if start > 0, let p = document.page(at: min(start, document.pageCount - 1)) {
                self.pdfView.layoutDocumentView()
                self.pdfView.go(to: p)
            }
            self.restoring = false
            self.syncPage()
        }
        if sameDocument, !matches.isEmpty { clearSearch() }   // old selections belong to the old document
        syncZoom()
    }

    /// A rectangle drawn over the PDF view (SwiftUI coordinates, origin top-left) → the page it's on
    /// and the rectangle in that page's points, origin top-left of the crop box.
    func pageRect(fromView r: CGRect) -> (page: Int, rect: CGRect)? {
        let h = pdfView.bounds.height
        let nsRect = CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
        guard let doc = pdfView.document,
              let page = pdfView.page(for: CGPoint(x: nsRect.midX, y: nsRect.midY), nearest: true) else { return nil }
        let p = pdfView.convert(nsRect, to: page)
        let crop = page.bounds(for: .cropBox)
        let topLeft = CGRect(x: p.minX - crop.minX, y: crop.maxY - p.maxY, width: p.width, height: p.height)
        return (doc.index(for: page) + 1, topLeft)
    }

    /// Pen strokes (SwiftUI view coordinates) → the page they're on, their box in page points
    /// (top-left), the words under them, and a picture of the area with the marks drawn on it.
    func mark(from strokes: [[CGPoint]]) -> AssistantModel.Mark? {
        let pts = strokes.flatMap { $0 }
        guard !pts.isEmpty, let doc = pdfView.document else { return nil }
        let h = pdfView.bounds.height
        let ns = pts.map { CGPoint(x: $0.x, y: h - $0.y) }
        let cx = ns.map(\.x).reduce(0, +) / CGFloat(ns.count), cy = ns.map(\.y).reduce(0, +) / CGFloat(ns.count)
        guard let page = pdfView.page(for: CGPoint(x: cx, y: cy), nearest: true) else { return nil }
        let pagePts = ns.map { pdfView.convert($0, to: page) }
        guard let minX = pagePts.map(\.x).min(), let maxX = pagePts.map(\.x).max(),
              let minY = pagePts.map(\.y).min(), let maxY = pagePts.map(\.y).max() else { return nil }
        let crop = page.bounds(for: .cropBox)
        let box = CGRect(x: minX, y: minY, width: max(4, maxX - minX), height: max(4, maxY - minY)).insetBy(dx: -6, dy: -6).intersection(crop)
        let text = (page.selection(for: box)?.string ?? "")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        let topLeft = CGRect(x: box.minX - crop.minX, y: crop.maxY - box.maxY, width: box.width, height: box.height)
        // Picture: the area plus some context, with the strokes in red.
        let area = box.insetBy(dx: -40, dy: -30).intersection(crop)
        let scale: CGFloat = 2
        var png: Data?
        if area.width > 2, area.height > 2, let ctx = CGContext(data: nil, width: Int(area.width * scale), height: Int(area.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: area.width * scale, height: area.height * scale))
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -area.minX, y: -area.minY)
            page.draw(with: .cropBox, to: ctx)
            ctx.setStrokeColor(NSColor.systemRed.cgColor)
            ctx.setLineWidth(2.5); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            var i = 0
            for s in strokes {
                let ps = s.map { pdfView.convert(CGPoint(x: $0.x, y: h - $0.y), to: page) }
                i += s.count
                guard ps.count > 1 else { continue }
                ctx.addLines(between: ps)
                ctx.strokePath()
            }
            if let img = ctx.makeImage() {
                let rep = NSBitmapImageRep(cgImage: img)
                png = rep.representation(using: .png, properties: [:])
            }
        }
        return AssistantModel.Mark(page: doc.index(for: page) + 1, rect: topLeft, text: String(text.prefix(1000)), image: png)
    }

    /// The selected text and its page (1-based), for "change selected text".
    var selectionForEdit: (text: String, page: Int)? {
        guard let sel = pdfView.currentSelection, let text = sel.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, let page = sel.pages.first, let doc = pdfView.document else { return nil }
        return (text, doc.index(for: page) + 1)
    }

    // MARK: Navigation

    var canGoBack: Bool { currentPageIndex > 0 }
    var canGoForward: Bool { currentPageIndex < pageCount - 1 }
    func goToPrevious() { pdfView.goToPreviousPage(nil) }
    func goToNext() { pdfView.goToNextPage(nil) }

    func goTo(pageNumber: Int) {
        guard let doc = pdfView.document else { return }
        if let p = doc.page(at: max(0, min(pageNumber - 1, doc.pageCount - 1))) { pdfView.go(to: p) }
    }

    func go(to item: OutlineItem) {
        if let d = item.destination { pdfView.go(to: d) } else { goTo(pageNumber: item.page) }
    }

    private func syncPage() {
        guard let doc = pdfView.document, let page = pdfView.currentPage else { return }
        currentPageIndex = doc.index(for: page)
        if !restoring { rememberPage() }
    }

    private var rememberTask: Task<Void, Never>?
    private func rememberPage() {
        rememberTask?.cancel()
        let id = documentID, page = currentPageIndex
        rememberTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let id else { return }
            try? Library.shared.update(id) { $0.lastPage = page }
        }
    }

    // MARK: Zoom & layout

    func zoomIn() { pdfView.autoScales = false; pdfView.scaleFactor = min(pdfView.maxScaleFactor, pdfView.scaleFactor * 1.15) }
    func zoomOut() { pdfView.autoScales = false; pdfView.scaleFactor = max(pdfView.minScaleFactor, pdfView.scaleFactor / 1.15) }
    func zoomToFit() { pdfView.autoScales = true; syncZoom() }
    private func syncZoom() { zoomPercent = max(1, Int((pdfView.scaleFactor * 100).rounded())) }

    func toggleTwoUp() {
        twoUp.toggle()
        pdfView.displayMode = twoUp ? .twoUpContinuous : .singlePageContinuous
        pdfView.displaysAsBook = twoUp
        if pdfView.autoScales { pdfView.autoScales = true }
    }

    // MARK: Theme

    func setTheme(_ t: ReadingTheme) {
        theme = t
        UserDefaults.standard.set(t.rawValue, forKey: "ezpdf.theme")
        switch t {
        case .system:
            pdfView.layer?.filters = nil
            pdfView.backgroundColor = .underPageBackgroundColor
        case .sepia:
            if let f = CIFilter(name: "CISepiaTone", parameters: [kCIInputIntensityKey: 0.45]) { pdfView.layer?.filters = [f] }
            pdfView.backgroundColor = NSColor(calibratedRed: 0.93, green: 0.90, blue: 0.83, alpha: 1)
        case .night:
            if let f = CIFilter(name: "CIColorInvert") { pdfView.layer?.filters = [f] }
            pdfView.backgroundColor = NSColor(white: 0.88, alpha: 1)   // inverts to near-black
        }
    }

    // MARK: Search

    func search(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let doc = pdfView.document, q.count >= 2 else { clearSearch(); return }
        let found = doc.findString(q, withOptions: [.caseInsensitive, .diacriticInsensitive])
        matches = found
        for s in found { s.color = .systemYellow }
        pdfView.highlightedSelections = found.isEmpty ? nil : found
        matchCount = found.count
        currentMatch = found.isEmpty ? 0 : 1
        focusMatch()
    }

    func nextMatch() { guard !matches.isEmpty else { return }; currentMatch = currentMatch % matches.count + 1; focusMatch() }
    func previousMatch() { guard !matches.isEmpty else { return }; currentMatch = (currentMatch - 2 + matches.count) % matches.count + 1; focusMatch() }

    func clearSearch() {
        matches = []; matchCount = 0; currentMatch = 0
        pdfView.highlightedSelections = nil
    }

    private func focusMatch() {
        guard currentMatch > 0, currentMatch <= matches.count else { return }
        pdfView.setCurrentSelection(matches[currentMatch - 1], animate: false)
        pdfView.scrollSelectionToVisible(nil)
    }

    // MARK: Annotate

    func highlightSelection(_ color: NSColor = .systemYellow, type: PDFAnnotationSubtype = .highlight) {
        guard let sel = pdfView.currentSelection, !(sel.string ?? "").isEmpty else { return }
        for line in sel.selectionsByLine() {
            for page in line.pages {
                let a = PDFAnnotation(bounds: line.bounds(for: page), forType: type, withProperties: nil)
                a.color = type == .highlight ? color.withAlphaComponent(0.45) : color
                page.addAnnotation(a)
                if let doc = pdfView.document { pending.append((doc.index(for: page), a)) }
            }
        }
        pdfView.clearSelection()
        scheduleSave()
    }

    func addNote(_ text: String) {
        guard let page = pdfView.currentPage, !text.isEmpty else { return }
        let b = page.bounds(for: .cropBox)
        let a = PDFAnnotation(bounds: CGRect(x: b.maxX - 44, y: b.maxY - 44, width: 20, height: 20), forType: .text, withProperties: nil)
        a.contents = text
        a.color = .systemYellow
        page.addAnnotation(a)
        if let doc = pdfView.document { pending.append((doc.index(for: page), a)) }
        scheduleSave()
    }

    private func scheduleSave() {
        unsavedAnnotations = true
        saveTask?.cancel()
        saveTask = Task { try? await Task.sleep(for: .seconds(1.5)); if !Task.isCancelled { flushAnnotations() } }
    }

    /// Saves pending highlights and notes by adding them to the current file (with an undo point).
    /// Call before any other edit so the order of changes is kept.
    func flushAnnotations() {
        saveTask?.cancel()
        guard let id = documentID, !pending.isEmpty else { unsavedAnnotations = false; return }
        let items = pending
        pending = []
        unsavedAnnotations = false
        do {
            let rec = try EzPDF.shared.addAnnotations(id, items)
            lastSavedModifiedAt = rec.modifiedAt
            // If nothing else changed the file, what's on screen is what's saved.
            if loadedModifiedAt != nil { loadedModifiedAt = rec.modifiedAt }
        } catch {
            pending = items + pending      // keep them; try again on the next save
            unsavedAnnotations = true
        }
    }

    // MARK: Objects

    /// Saves a moved or resized object; the view already shows it, so no reload follows.
    private func commitObject(_ a: PDFAnnotation, on page: PDFPage) {
        guard let docID = documentID, let objectID = Objects.objectID(a), let doc = pdfView.document else { return }
        flushAnnotations()
        let crop = page.bounds(for: .cropBox)
        let r = CGRect(x: a.bounds.minX - crop.minX, y: crop.maxY - a.bounds.maxY, width: a.bounds.width, height: a.bounds.height)
        if let rec = try? EzPDF.shared.updateObject(docID, object: objectID, .init(page: doc.index(for: page) + 1, rect: r)) {
            lastSavedModifiedAt = rec.modifiedAt
        }
    }

    private func deleteObject(_ a: PDFAnnotation, on page: PDFPage) {
        guard let docID = documentID, let objectID = Objects.objectID(a) else { return }
        flushAnnotations()
        page.removeAnnotation(a)
        if let rec = try? EzPDF.shared.deleteObject(docID, object: objectID) { lastSavedModifiedAt = rec.modifiedAt }
    }

    // MARK: Read aloud

    func toggleReadAloud() {
        if isSpeaking { stopSpeaking(); return }
        isSpeaking = true
        speakCurrentPage()
    }

    func stopSpeaking() {
        isSpeaking = false
        synthesizer.stopSpeaking(at: .immediate)
    }

    func setSpeechRate(_ r: Float) {
        speechRate = r
        UserDefaults.standard.set(r, forKey: "ezpdf.speechRate")
    }

    private var bestVoice: AVSpeechSynthesisVoice? {
        let lang = String(AVSpeechSynthesisVoice.currentLanguageCode().prefix(2))
        return AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(lang) }.max { $0.quality.rawValue < $1.quality.rawValue }
    }

    private func speakCurrentPage() {
        guard isSpeaking, let raw = pdfView.currentPage?.string else { isSpeaking = false; return }
        let text = Self.cleanForSpeech(raw)
        guard !text.isEmpty else { advanceOrStop(); return }
        let u = AVSpeechUtterance(string: text)
        u.voice = bestVoice
        u.rate = speechRate
        u.postUtteranceDelay = 0.35
        synthesizer.speak(u)
    }

    func advanceOrStop() {
        guard isSpeaking else { return }
        if canGoForward { goToNext(); DispatchQueue.main.async { [weak self] in self?.speakCurrentPage() } } else { isSpeaking = false }
    }

    static func cleanForSpeech(_ raw: String) -> String {
        var t = raw.replacingOccurrences(of: "-\n", with: "").replacingOccurrences(of: "\n", with: " ")
        t = t.replacingOccurrences(of: #"\[\d+(?:[\s,;–-]+\d+)*\]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Outline

    private func buildOutline(_ doc: PDFDocument) {
        var items: [OutlineItem] = []
        func walk(_ node: PDFOutline, _ level: Int) {
            for i in 0..<node.numberOfChildren {
                guard let c = node.child(at: i) else { continue }
                if let label = c.label, !label.isEmpty {
                    let page = c.destination?.page.map { doc.index(for: $0) + 1 } ?? 0
                    items.append(OutlineItem(label: label, level: level, destination: c.destination, page: page))
                }
                if items.count < 2000 { walk(c, level + 1) }
            }
        }
        if let root = doc.outlineRoot { walk(root, 0) }
        outline = items
    }
}

extension ReaderController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.advanceOrStop() }
    }
}

struct PDFViewHost: NSViewRepresentable {
    let controller: ReaderController
    func makeNSView(context: Context) -> PDFView { controller.pdfView }
    func updateNSView(_ nsView: PDFView, context: Context) {}
}

struct ThumbnailHost: NSViewRepresentable {
    let controller: ReaderController
    func makeNSView(context: Context) -> PDFThumbnailView {
        let v = PDFThumbnailView()
        v.pdfView = controller.pdfView
        v.thumbnailSize = NSSize(width: 120, height: 160)
        v.backgroundColor = .clear
        return v
    }
    func updateNSView(_ nsView: PDFThumbnailView, context: Context) {
        if nsView.pdfView !== controller.pdfView { nsView.pdfView = controller.pdfView }
    }
}
