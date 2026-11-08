import SwiftUI
import EzPDFCore
import UniformTypeIdentifiers

/// App-wide UI state. All real work goes through `EzPDF.shared` (the same functions agents use).
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", web = "Web", files = "Files", data = "Statements & invoices"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .all: return "tray.full"
            case .web: return "globe"
            case .files: return "doc"
            case .data: return "tablecells"
            }
        }
    }

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var message: String
        var isError = false
        var documentID: String?
    }

    let ops = EzPDF.shared
    var documents: [DocumentRecord] = []
    var selection: String?
    var filter: Filter = .all
    var query = ""
    var toast: Toast?
    var focusConvertField = false
    var openPage: Int?
    var extractFor: DocumentRecord?
    var renaming: DocumentRecord?
    /// Set to a tab to open Settings there (from ezpdf://settings links).
    var settingsRequest: String?
    /// The assistant beside the reader; it works on whichever document is open.
    let assistant = AssistantModel()
    var showAssistant = UserDefaults.standard.bool(forKey: "ezpdf.showAssistant") {
        didSet { UserDefaults.standard.set(showAssistant, forKey: "ezpdf.showAssistant") }
    }
    /// The templates gallery sheet.
    var showTemplates = false
    /// The page the reader shows (1-based), for the assistant's context.
    var currentPage = 1

    private var toastTask: Task<Void, Never>?

    init() {
        reload()
        assistant.context = { [weak self] in
            guard let self, let doc = self.selectedDocument else { return nil }
            return (doc.id, doc.title, doc.pageCount, self.currentPage)
        }
        NotificationCenter.default.addObserver(forName: Library.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        NotificationCenter.default.addObserver(forName: EzPDF.openRequest, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let id = note.userInfo?["id"] as? String else { return }
                self?.selection = id
                let page = note.userInfo?["page"] as? Int ?? 0
                self?.openPage = page > 0 ? page : nil
                NSApp.activate()
            }
        }
    }

    func reload() {
        documents = ops.library.all()
        if let s = selection, !documents.contains(where: { $0.id == s }) { selection = nil }
    }

    var visibleDocuments: [DocumentRecord] {
        documents.filter { d in
            switch filter {
            case .all: return true
            case .web: return d.kind == .web
            case .files: return [.file, .imported, .merged].contains(d.kind)
            case .data: return d.kind == .statement || d.kind == .invoice
            }
        }.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || ($0.siteName ?? "").localizedCaseInsensitiveContains(query) }
    }

    var selectedDocument: DocumentRecord? { selection.flatMap { id in documents.first { $0.id == id } } }

    // MARK: Actions

    /// Text from the convert field or a paste: one or more links, or file paths.
    func submit(_ text: String, preset: PagePreset? = nil, then flow: Flow = .open) {
        let tokens = text.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        let urls = tokens.compactMap { t -> URL? in
            if t.hasPrefix("http://") || t.hasPrefix("https://") { return URL(string: t) }
            if !t.hasPrefix("/"), !t.hasPrefix("~"),
               t.range(of: #"^[\w-]+(\.[\w-]+)+(/\S*)?$"#, options: .regularExpression) != nil { return URL(string: "https://" + t) }
            return nil
        }
        let files = tokens.compactMap { t -> URL? in
            let p = (t as NSString).expandingTildeInPath
            return t.hasPrefix("/") || t.hasPrefix("~") ? (FileManager.default.fileExists(atPath: p) ? URL(fileURLWithPath: p) : nil) : nil
        }
        if urls.isEmpty && files.isEmpty {
            show("That doesn't look like a link.", error: true)
            return
        }
        for u in urls { convert(url: u, preset: preset, then: flow) }
        if !files.isEmpty { convert(files: files, preset: preset) }
    }

    enum Flow { case open, kindle, extract, stay }

    func convert(url: URL, preset: PagePreset? = nil, then flow: Flow = .open) {
        Task {
            do {
                let rec = try await ops.convert(url: url, preset: preset)
                await after(rec, flow)
            } catch { show(error.localizedDescription, error: true) }
        }
    }

    func convert(files: [URL], preset: PagePreset? = nil, then flow: Flow = .open) {
        Task {
            do {
                let rec = try await ops.convert(files: files, preset: preset)
                await after(rec, flow)
            } catch { show(error.localizedDescription, error: true) }
        }
    }

    private func after(_ rec: DocumentRecord, _ flow: Flow) async {
        switch flow {
        case .open:
            if selection == nil { selection = rec.id }
            let notes = ops.jobs.first { $0.documentID == rec.id }?.notes ?? []
            show(notes.first ?? "“\(rec.title)” is ready", documentID: rec.id)
        case .kindle:
            sendToKindle(rec)
        case .extract: extractFor = rec
        case .stay: break
        }
    }

    func sendToKindle(_ rec: DocumentRecord) {
        show("Sending “\(rec.title)” to your Kindle…")
        Task {
            do {
                let r = try await ops.sendToKindle(rec.id)
                show("Sent to Kindle as \(r.format.rawValue.uppercased())")
            } catch {
                show(error.localizedDescription, error: true)
            }
        }
    }

    func export(_ rec: DocumentRecord, as format: EzPDF.ExportFormat) {
        do {
            let url = try ops.export(rec.id, format: format)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { show(error.localizedDescription, error: true) }
    }

    func revealInLibrary(_ rec: DocumentRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([ops.library.pdfURL(for: rec.id)])
    }

    func delete(_ rec: DocumentRecord) {
        do {
            _ = try ops.delete(rec.id)
            show("Moved “\(rec.title)” to the Trash")
        } catch { show(error.localizedDescription, error: true) }
    }

    /// Saves what the open reader still holds (highlights, a nudge) before the document changes underneath it.
    @ObservationIgnored var flushPendingEdits: () -> Void = {}

    /// Undo or redo the open document's last change (⌘Z, ⇧⌘Z).
    func undoDocument(redo: Bool) {
        guard let id = selection else { NSSound.beep(); return }
        flushPendingEdits()
        do {
            let rec = redo ? try ops.redo(id) : try ops.undo(id)
            show(redo ? "Redone" : "Undone", documentID: rec.id)
        } catch {
            show(error.localizedDescription, error: true)
        }
    }

    func show(_ message: String, error: Bool = false, documentID: String? = nil) {
        toast = Toast(message: message, isError: error, documentID: documentID)
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(error ? 7 : 4))
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: Drops & pastes

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        let group = DispatchGroup()
        var fileURLs: [URL] = []
        var webURLs: [URL] = []
        let lock = NSLock()
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    // Finder can hand over file-reference URLs (file:///.file/id=…); use the real path.
                    if let url, let path = (url as NSURL).filePathURL { lock.lock(); fileURLs.append(path); lock.unlock() }
                    group.leave()
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                handled = true
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { lock.lock(); webURLs.append(url); lock.unlock() }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            for u in webURLs where u.scheme?.hasPrefix("http") == true { self.convert(url: u) }
            if !fileURLs.isEmpty { self.convert(files: fileURLs.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) }
        }
        return handled
    }
}
