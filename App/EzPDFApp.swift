import SwiftUI
import EzPDFCore
import UniformTypeIdentifiers
import CoreSpotlight

@main
struct EzPDFApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel.shared

    var body: some Scene {
        WindowGroup("ezpdf", id: "main") {
            ContentView()
                .environment(app)
                .frame(minWidth: 860, minHeight: 560)
                // Links and files go to the window that's already open, not a new one.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String { app.selection = id }
                }
        }
        .windowToolbarStyle(.unified)
        .handlesExternalEvents(matching: ["*"])
        .commands { AppCommands(app: app) }

        Settings {
            SettingsView()
        }
    }
}

struct AppCommands: Commands {
    let app: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Make PDF from Link…") { app.focusConvertField = true }.keyboardShortcut("l")
            Button("Make PDF from Files…") { Self.openFiles() }.keyboardShortcut("o")
            Button("Make PDF from Clipboard") { pasteLink() }.keyboardShortcut("v", modifiers: [.command, .shift])
            Divider()
            Button("New from Template…") { app.showTemplates = true }.keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { undoOrRedo(redo: false) }.keyboardShortcut("z")
            Button("Redo") { undoOrRedo(redo: true) }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandMenu("Document") {
            Button("Send to Kindle") { if let d = app.selectedDocument { app.sendToKindle(d) } }
                .keyboardShortcut("k", modifiers: [.command, .shift]).disabled(app.selectedDocument == nil)
            Button("Extract Data…") { app.extractFor = app.selectedDocument }
                .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(app.selectedDocument == nil)
            Divider()
            Button("Save PDF to Downloads") { if let d = app.selectedDocument { app.export(d, as: .pdf) } }
                .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(app.selectedDocument == nil)
            Button("Merge All Visible…") { mergeVisible() }.disabled(app.visibleDocuments.count < 2)
        }
    }

    /// Typing in a field undoes the typing first; otherwise it's the open document's last change.
    private func undoOrRedo(redo: Bool) {
        if let responder = NSApp.keyWindow?.firstResponder as? NSTextView, let manager = responder.undoManager,
           redo ? manager.canRedo : manager.canUndo {
            redo ? manager.redo() : manager.undo()
            return
        }
        app.undoDocument(redo: redo)
    }

    private func pasteLink() {
        if let s = NSPasteboard.general.string(forType: .string) { app.submit(s) }
    }

    private func mergeVisible() {
        do {
            let rec = try app.ops.merge(app.visibleDocuments.reversed().map(\.id))
            app.selection = rec.id
        } catch { app.show(error.localizedDescription, error: true) }
    }

    @MainActor
    static func openFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = FileConverter.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = "Several files are combined into one PDF, in name order."
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            AppModel.shared.convert(files: panel.urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Times of recent ezpdf:// conversions; links can come from any web page, so they're rate-limited.
    private var recentLinkConversions: [Date] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = ServiceProvider()
        NSUpdateDynamicServices()
        AgentApprovalPrompt.install()
        Fonts.registerSaved()        // fonts fetched for documents earlier, so pages that use them draw right
        LocalServer.shared.start()
        // The library's full-text index, scanned pages included (in the background; searches never wait on it).
        Task(priority: .utility) { @MainActor in await EzPDF.shared.refreshSearchIndex() }
        // Current model ids from our catalog worker (at most once a day).
        Task { @MainActor in await ModelCatalogStore.shared.refreshIfNeeded() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Files opened from Finder and ezpdf:// links:
    ///   ezpdf://convert?url=…&flow=pdf|kindle|extract&preset=kindle
    ///   ezpdf://open?id=…&page=3
    func application(_ application: NSApplication, open urls: [URL]) {
        let app = AppModel.shared
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty { app.convert(files: files) }
        for u in urls where u.scheme == "ezpdf" {
            let q = Dictionary(URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { a, _ in a })
            switch u.host() {
            case "convert":
                // Any web page can open an ezpdf:// link, so links never act silently: at most a few
                // per minute, and sending email (Kindle) or reading data asks first.
                guard let raw = q["url"], let target = URL(string: raw), target.scheme == "http" || target.scheme == "https" else { continue }
                recentLinkConversions = recentLinkConversions.filter { $0.timeIntervalSinceNow > -60 }
                guard recentLinkConversions.count < 3 else { app.show("Too many ezpdf links at once; ignored one.", error: true); continue }
                recentLinkConversions.append(Date())
                var flow: AppModel.Flow = q["flow"] == "kindle" ? .kindle : q["flow"] == "extract" ? .extract : .open
                if flow != .open {
                    NSApp.activate()
                    let alert = NSAlert()
                    alert.messageText = flow == .kindle ? "Send this page to your Kindle?" : "Make a PDF and read its data?"
                    alert.informativeText = "A link asked ezpdf to \(flow == .kindle ? "email a PDF of" : "convert") \(target.host() ?? raw)."
                    alert.addButton(withTitle: flow == .kindle ? "Send" : "Continue")
                    alert.addButton(withTitle: "Just Make PDF")
                    alert.addButton(withTitle: "Cancel")
                    switch alert.runModal() {
                    case .alertFirstButtonReturn: break
                    case .alertSecondButtonReturn: flow = .open
                    default: continue
                    }
                }
                app.convert(url: target, preset: PagePreset.parse(q["preset"]), then: flow)
            case "open":
                if let id = q["id"] { app.selection = id; app.openPage = Int(q["page"] ?? "") }
            case "settings", "help":
                app.settingsRequest = u.host() == "help" ? "help" : (q["tab"] ?? "general")
            default: break
            }
        }
    }
}

/// macOS Services menu: select a link (or text containing links) anywhere → “Make PDF with ezpdf”.
final class ServiceProvider: NSObject {
    @objc func convertService(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let text = pboard.string(forType: .URL) ?? pboard.string(forType: .string) ?? ""
        Task { @MainActor in AppModel.shared.submit(text) }
    }
}
