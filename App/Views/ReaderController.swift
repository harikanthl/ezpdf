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
    /// A change to a placed object couldn't be saved: the message to show (the view is reloaded).
    var onError: ((String) -> Void)?
    /// A picture pasted onto the page (placed like a dropped image).
    var onPasteImage: ((Data) -> Void)?
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
    /// Changes whenever the visible area scrolls or zooms (overlays pinned to pages redraw on it).
    @Published private(set) var viewport = 0
    nonisolated(unsafe) private var scrollObserver: NSObjectProtocol?
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
    /// Form values as last loaded or saved, by field name. Typing in a field changes the open
    /// document only; saving compares against this and writes what changed.
    private var savedFieldValues: [String: String] = [:]
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
        pdfView.onCopyObject = { [weak self] a, page in self?.copyObject(a, on: page) }
        pdfView.onPaste = { [weak self] in self?.paste() }
        pdfView.canPaste = { ObjectClipboard.hasContent(NSPasteboard.general) }
        pdfView.onEdit = { [weak self] a, _ in
            guard let id = Objects.objectID(a) else { return }
            self?.onEditObject?(id, a)
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncPage() }
        })
        observers.append(center.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncZoom(); self?.viewport &+= 1 }
        })
        observers.append(center.addObserver(forName: .PDFViewSelectionChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hasSelection = !(self?.pdfView.currentSelection?.string ?? "").isEmpty }
        })
        // Form fields: a click on a checkbox or radio, or the end of typing in a text field.
        observers.append(center.addObserver(forName: .PDFViewAnnotationHit, object: pdfView, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let a = n.userInfo?["PDFAnnotationHit"] as? PDFAnnotation, a.type == "Widget" else { return }
                self?.scheduleFieldSave()
            }
        })
        observers.append(center.addObserver(forName: NSControl.textDidEndEditingNotification, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, let v = n.object as? NSView, v.isDescendant(of: self.pdfView) else { return }
                self.scheduleFieldSave()
            }
        })
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    /// Follows scrolling of the PDF view's clip view (it's created with the document).
    private func watchScrolling() {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        guard let clip = pdfView.documentView?.enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.viewport &+= 1 }
        }
    }

    func load(_ rec: DocumentRecord, url: URL, page: Int? = nil) {
        flushAnnotations()
        let sameDocument = documentID == rec.id
        if !sameDocument {
            stopSpeaking()
            clearSearch()
        }
        // The same document again (after an edit, undo or agent change): stay where the reader was.
        let keep: (page: Int, point: CGPoint, scale: CGFloat)? = {
            guard sameDocument, let d = pdfView.currentDestination, let p = d.page, let old = pdfView.document else { return nil }
            return (old.index(for: p), d.point, pdfView.scaleFactor)
        }()
        documentID = rec.id
        loadedModifiedAt = Library.shared.record(rec.id)?.modifiedAt ?? rec.modifiedAt
        restoring = true
        guard let document = PDFDocument(url: url) else { pdfView.document = nil; pageCount = 0; return }
        pdfView.select(nil, on: nil)
        Objects.hydrate(document, folder: Library.shared.folder(for: rec.id))
        pdfView.document = document
        savedFieldValues = Self.fieldValues(document)
        pageCount = document.pageCount
        buildOutline(document)
        setTheme(theme)
        let start = (page.map { $0 - 1 }) ?? rec.lastPage
        // PDFView ignores go(to:) until it has laid the document out.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let keep, let p = document.page(at: min(keep.page, document.pageCount - 1)) {
                if !self.pdfView.autoScales { self.pdfView.scaleFactor = keep.scale }
                self.pdfView.layoutDocumentView()
                self.pdfView.go(to: PDFDestination(page: p, at: keep.point))
            } else if start > 0, let p = document.page(at: min(start, document.pageCount - 1)) {
                self.pdfView.layoutDocumentView()
                self.pdfView.go(to: p)
            }
            self.restoring = false
            self.syncPage()
            self.watchScrolling()
        }
        if sameDocument, !matches.isEmpty { clearSearch() }   // old selections belong to the old document
        syncZoom()
    }

    /// A rectangle drawn over the PDF view (SwiftUI coordinates, origin top-left) → the page it's on
    /// and the rectangle in that page's points, origin top-left of the page as shown.
    func pageRect(fromView r: CGRect) -> (page: Int, rect: CGRect)? {
        let h = pdfView.bounds.height
        let nsRect = CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
        guard let doc = pdfView.document,
              let page = pdfView.page(for: CGPoint(x: nsRect.midX, y: nsRect.midY), nearest: true) else { return nil }
        let p = pdfView.convert(nsRect, to: page)
        return (doc.index(for: page) + 1, EditOps.PageSpace(page).topLeft(p))
    }

    /// A pen stroke pinned to the page it was drawn on, in page points, so it stays on the same
    /// words when the view scrolls or zooms.
    struct PenStroke: Equatable {
        var page: Int          // 0-based
        var points: [CGPoint]
    }

    /// A stroke drawn over the view (SwiftUI coordinates, origin top-left) → pinned to its page.
    func anchor(_ viewPoints: [CGPoint]) -> PenStroke? {
        guard viewPoints.count > 1, let doc = pdfView.document else { return nil }
        let h = pdfView.bounds.height
        let ns = viewPoints.map { CGPoint(x: $0.x, y: h - $0.y) }
        let cx = ns.map(\.x).reduce(0, +) / CGFloat(ns.count), cy = ns.map(\.y).reduce(0, +) / CGFloat(ns.count)
        guard let page = pdfView.page(for: CGPoint(x: cx, y: cy), nearest: true) else { return nil }
        return PenStroke(page: doc.index(for: page), points: ns.map { pdfView.convert($0, to: page) })
    }

    /// Where a pinned stroke is on screen now (SwiftUI coordinates).
    func viewPoints(_ s: PenStroke) -> [CGPoint] {
        guard let page = pdfView.document?.page(at: s.page) else { return [] }
        let h = pdfView.bounds.height
        return s.points.map { let v = pdfView.convert($0, from: page); return CGPoint(x: v.x, y: h - v.y) }
    }

    /// Pen strokes → the page they're on (the latest stroke's page), their box in page points
    /// (top-left, as shown), the words under them, and a picture of the area with the marks on it.
    func mark(from all: [PenStroke]) -> AssistantModel.Mark? {
        guard let last = all.last, let doc = pdfView.document, let page = doc.page(at: last.page) else { return nil }
        let strokes = all.filter { $0.page == last.page }.map(\.points)
        let pagePts = strokes.flatMap { $0 }
        guard let minX = pagePts.map(\.x).min(), let maxX = pagePts.map(\.x).max(),
              let minY = pagePts.map(\.y).min(), let maxY = pagePts.map(\.y).max() else { return nil }
        let crop = page.bounds(for: .cropBox)
        let box = CGRect(x: minX, y: minY, width: max(4, maxX - minX), height: max(4, maxY - minY)).insetBy(dx: -6, dy: -6).intersection(crop)
        // Drawn beside the page (in the gutter): nothing is marked.
        guard !box.isNull, box.width >= 1, box.height >= 1, box.minX.isFinite, box.minY.isFinite else { return nil }
        // Whole words only: a loop drawn loosely clips the neighbours' letters at its edges.
        let text = page.selection(for: box).map(EditOps.wholeWords) ?? ""
        let space = EditOps.PageSpace(page)
        let topLeft = space.topLeft(box)
        // Picture: the area as shown plus some context, with the strokes in red.
        let area = space.shownRect(topLeft).insetBy(dx: -40, dy: -30).intersection(CGRect(origin: .zero, size: space.size))
        // Sharp enough for a model to read, capped so a big scribble on a poster page stays small.
        let scale: CGFloat = min(2, 1568 / max(1, max(area.width, area.height)))
        var png: Data?
        if area.width > 2, area.height > 2, let ctx = CGContext(data: nil, width: Int(area.width * scale), height: Int(area.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: area.width * scale, height: area.height * scale))
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -area.minX, y: -area.minY)
            page.draw(with: .cropBox, to: ctx)          // draws the page as shown (crop and rotation applied)
            ctx.concatenate(space.toShown)              // strokes are in page space
            ctx.setStrokeColor(NSColor.systemRed.cgColor)
            ctx.setLineWidth(2.5); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            for ps in strokes where ps.count > 1 {
                ctx.addLines(between: ps)
                ctx.strokePath()
            }
            if let img = ctx.makeImage() {
                png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
            }
        }
        return AssistantModel.Mark(page: doc.index(for: page) + 1, rect: topLeft, text: String(text.prefix(1000)), image: png, docID: documentID ?? "")
    }

    /// The selection, with its line boxes and style, for "change selected text".
    var selectionForEdit: EditOps.SelectionInfo? {
        guard let sel = pdfView.currentSelection, let doc = pdfView.document else { return nil }
        return EditOps.selectionInfo(sel, in: doc)
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
        // Top right of the page as shown.
        let space = EditOps.PageSpace(page)
        let a = PDFAnnotation(bounds: space.pageRect(CGRect(x: space.size.width - 44, y: 24, width: 20, height: 20)), forType: .text, withProperties: nil)
        a.contents = text
        a.color = .systemYellow
        page.addAnnotation(a)
        if let doc = pdfView.document { pending.append((doc.index(for: page), a)) }
        scheduleSave()
    }

    /// Every field's value by name: text as typed, checkboxes "on"/"off", radios their chosen option.
    static func fieldValues(_ doc: PDFDocument) -> [String: String] {
        var out: [String: String] = [:]
        for i in 0..<doc.pageCount {
            for a in doc.page(at: i)?.annotations ?? [] where a.type == "Widget" {
                guard let name = a.fieldName, !name.isEmpty else { continue }
                switch a.widgetFieldType {
                case .text, .choice:
                    out[name] = a.widgetStringValue ?? ""
                case .button where a.widgetControlType == .checkBoxControl:
                    out[name] = a.buttonWidgetState == .onState ? "on" : "off"
                case .button where a.widgetControlType == .radioButtonControl:
                    if a.buttonWidgetState == .onState { out[name] = a.buttonWidgetStateString }
                    else if out[name] == nil { out[name] = "" }
                default: continue
                }
            }
        }
        return out
    }

    private func scheduleFieldSave() {
        // The value lands on the widget just after the notification; read it on the next save.
        saveTask?.cancel()
        saveTask = Task { try? await Task.sleep(for: .seconds(0.8)); if !Task.isCancelled { flushAnnotations() } }
    }

    /// Writes form values typed or clicked on screen since the last save (one undo point).
    private func flushFields() {
        guard let id = documentID, let doc = pdfView.document else { return }
        let now = Self.fieldValues(doc)
        // Off for a radio group means no option chosen; fillForm can't express that, so skip it.
        let changed = now.filter { name, value in savedFieldValues[name] != value && !(value.isEmpty && savedFieldValues[name] == nil) }
        guard !changed.isEmpty else { return }
        let onDiskBefore = Library.shared.record(id)?.modifiedAt
        do {
            let rec = try EzPDF.shared.fillForm(id, values: changed).record
            savedFieldValues = now
            lastSavedModifiedAt = rec.modifiedAt
            if onDiskBefore == loadedModifiedAt { loadedModifiedAt = rec.modifiedAt }
        } catch {
            onError?("Couldn't save the form: \(error.localizedDescription)")
        }
    }

    private func scheduleSave() {
        unsavedAnnotations = true
        saveTask?.cancel()
        saveTask = Task { try? await Task.sleep(for: .seconds(1.5)); if !Task.isCancelled { flushAnnotations() } }
    }

    /// Saves pending highlights and notes by adding them to the current file (with an undo point).
    /// Call before any other edit so the order of changes is kept.
    func flushAnnotations() {
        pdfView.flushNudge()
        saveTask?.cancel()
        flushFields()
        guard let id = documentID, !pending.isEmpty else { unsavedAnnotations = false; return }
        let items = pending
        pending = []
        unsavedAnnotations = false
        let onDiskBefore = Library.shared.record(id)?.modifiedAt
        do {
            let rec = try EzPDF.shared.addAnnotations(id, items)
            lastSavedModifiedAt = rec.modifiedAt
            if onDiskBefore == loadedModifiedAt {
                // Nothing else changed the file: what's on screen is what's saved.
                loadedModifiedAt = rec.modifiedAt
            } else {
                // Someone else saved first (an agent, the assistant): show their change too.
                DispatchQueue.main.async { [weak self] in
                    guard let self, let latest = Library.shared.record(id), self.documentID == id else { return }
                    self.load(latest, url: Library.shared.pdfURL(for: id), page: self.currentPageIndex + 1)
                }
            }
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
        let pageNumber = doc.index(for: page) + 1
        do {
            let rec = try EzPDF.shared.updateObject(docID, object: objectID, onPage: pageNumber,
                                                    .init(page: pageNumber, rect: EditOps.PageSpace(page).topLeft(a.bounds)))
            lastSavedModifiedAt = rec.modifiedAt
            loadedModifiedAt = rec.modifiedAt
        } catch {
            failed("Couldn't save that move: \(error.localizedDescription)")
        }
    }

    private func deleteObject(_ a: PDFAnnotation, on page: PDFPage) {
        guard let docID = documentID, let objectID = Objects.objectID(a), let doc = pdfView.document else { return }
        flushAnnotations()
        let pageNumber = doc.index(for: page) + 1
        page.removeAnnotation(a)
        do {
            let rec = try EzPDF.shared.deleteObject(docID, object: objectID, onPage: pageNumber)
            lastSavedModifiedAt = rec.modifiedAt
            loadedModifiedAt = rec.modifiedAt
        } catch {
            failed("Couldn't delete it: \(error.localizedDescription)")
        }
    }

    // MARK: Copy and paste

    private func copyObject(_ a: PDFAnnotation, on page: PDFPage) {
        guard let docID = documentID, let objectID = Objects.objectID(a), let doc = pdfView.document else { return }
        let image = a is ImageStampAnnotation || (a.contents ?? "").hasPrefix("ezpdf-image:")
            ? try? Data(contentsOf: Library.shared.folder(for: docID).appendingPathComponent("objects/\(objectID).png")) : nil
        let clip = ObjectClipboard.Clip(
            documentID: docID, page: doc.index(for: page), rect: EditOps.PageSpace(page).topLeft(a.bounds),
            text: image == nil && a.type == "FreeText" ? a.contents : nil,
            fontName: a.font?.fontName, fontSize: a.font.map { Double($0.pointSize) },
            color: (a.type == "FreeText" ? a.fontColor : a.color).map { Objects.hexColor($0) }, image: image,
            shape: a.type == "Square" ? "rectangle" : a.type == "Circle" ? "ellipse" : a.type == "Line" ? "line" : nil)
        ObjectClipboard.write(clip, to: NSPasteboard.general)
    }

    /// Pastes onto the page in view: a copied object (a little offset if it's the same page it came
    /// from), a picture as an image object, or text as a text box.
    private func paste() {
        guard let docID = documentID, let doc = pdfView.document, let page = pdfView.currentPage else { return }
        flushAnnotations()
        let pageIndex = doc.index(for: page)
        let shown = EditOps.PageSpace(page).bounds
        let pb = NSPasteboard.general
        do {
            if let clip = ObjectClipboard.read(pb) {
                var r = clip.rect
                if clip.documentID == docID && clip.page == pageIndex { r = r.offsetBy(dx: 14, dy: 14) }
                r.origin.x = min(max(0, r.minX), max(0, shown.width - r.width))
                r.origin.y = min(max(0, r.minY), max(0, shown.height - r.height))
                let color = clip.color.flatMap { ColorName.parse($0) }
                let rec: DocumentRecord
                if let image = clip.image {
                    rec = try EzPDF.shared.addContent(docID, .init(kind: .image, page: pageIndex + 1, rect: r, imageData: image))
                } else if let text = clip.text {
                    rec = try EzPDF.shared.addContent(docID, .init(kind: .text, page: pageIndex + 1, rect: r, text: text, fontName: clip.fontName,
                                                                   fontSize: clip.fontSize.map { CGFloat($0) }, color: color))
                } else if let shape = clip.shape.flatMap(EditOps.Shape.init(rawValue:)) {
                    rec = try EzPDF.shared.addContent(docID, .init(kind: .shape, page: pageIndex + 1, rect: r, color: color, shape: shape))
                } else { return }
                _ = rec
            } else if let image = ObjectClipboard.image(pb) {
                onPasteImage?(image)
            } else if let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                let r = CGRect(x: 48, y: 60, width: min(360, shown.width - 96), height: 20)
                _ = try EzPDF.shared.addContent(docID, .init(kind: .text, page: pageIndex + 1, rect: r, text: String(text.prefix(4000))))
            }
        } catch {
            onError?("Couldn't paste: \(error.localizedDescription)")
        }
    }

    /// Shows the error and puts the saved state back on screen, so the view never shows a change
    /// the file doesn't have.
    private func failed(_ message: String) {
        onError?(message)
        guard let id = documentID, let rec = Library.shared.record(id) else { return }
        let page = currentPageIndex + 1
        load(rec, url: Library.shared.pdfURL(for: id), page: page)
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
