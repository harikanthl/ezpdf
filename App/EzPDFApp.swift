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
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String { app.selection = id }
                }
        }
        .windowToolbarStyle(.unified)
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = ServiceProvider()
        NSUpdateDynamicServices()
        LocalServer.shared.start()
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
                guard let raw = q["url"], let target = URL(string: raw), target.scheme?.hasPrefix("http") == true else { continue }
                let flow: AppModel.Flow = q["flow"] == "kindle" ? .kindle : q["flow"] == "extract" ? .extract : .open
                app.convert(url: target, preset: PagePreset.parse(q["preset"]), then: flow)
            case "open":
                if let id = q["id"] { app.selection = id; app.openPage = Int(q["page"] ?? "") }
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
