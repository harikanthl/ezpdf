import SwiftUI
import EzPDFCore

enum SettingsTab: String { case general, kindle, agents, browser, help }

struct SettingsView: View {
    @AppStorage("ezpdf.settingsTab") private var tab = SettingsTab.general.rawValue

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general.rawValue)
            KindleSettings().tabItem { Label("Kindle", systemImage: "book.closed") }.tag(SettingsTab.kindle.rawValue)
            AgentSettings().tabItem { Label("Agents", systemImage: "sparkles") }.tag(SettingsTab.agents.rawValue)
            BrowserSettings().tabItem { Label("Browser", systemImage: "safari") }.tag(SettingsTab.browser.rawValue)
            HelpSettings().tabItem { Label("Help", systemImage: "questionmark.circle") }.tag(SettingsTab.help.rawValue)
        }
        .frame(width: 600)
        .scenePadding()
    }
}

struct GeneralSettings: View {
    @State private var preset = EzPDF.shared.defaultPreset
    @State private var format = EzPDF.shared.defaultFormat
    @State private var folder = EzPDF.shared.exportFolder

    var body: some View {
        Form {
            Picker("Page size for links", selection: $preset) {
                ForEach(PagePreset.allCases) { Text($0.displayName).tag($0) }
            }
            Text(preset.detail).font(.caption).foregroundStyle(.secondary)
            Picker("Make", selection: $format) {
                Text("PDF").tag(OutputFormat.pdf)
                Text("PDF and EPUB").tag(OutputFormat.both)
            }
            Text("EPUB reflows on a Kindle, so text size is yours to choose. Made only for article pages.").font(.caption).foregroundStyle(.secondary)
            LabeledContent("Save copies to") {
                HStack {
                    Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle)
                    Button("Change…") {
                        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                        if p.runModal() == .OK, let u = p.url { folder = u; EzPDF.shared.exportFolder = u }
                    }
                }
            }
            LabeledContent("Library") {
                Button("Show in Finder") { NSWorkspace.shared.open(Library.shared.root) }
            }
        }
        .formStyle(.grouped)
        .onChange(of: preset) { EzPDF.shared.defaultPreset = preset }
        .onChange(of: format) { EzPDF.shared.defaultFormat = format }
    }
}

struct KindleSettings: View {
    @State private var s = KindleSender.Settings.load()

    var body: some View {
        Form {
            Section {
                TextField("Send to Kindle address", text: $s.address, prompt: Text("name_abc123@kindle.com"))
                if !s.address.isEmpty && !KindleSender.isValidKindleAddress(s.address) {
                    Label("Kindle addresses end in @kindle.com", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                Picker("Send with", selection: $s.method) {
                    Text("Mail, automatically").tag(KindleSender.Method.mailAutomatic)
                    Text("Mail, as a draft I send").tag(KindleSender.Method.mailCompose)
                }
                Toggle("Send EPUB when there is one", isOn: $s.preferEPUB)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Find your address on Amazon under Manage Your Content and Devices → Preferences → Personal Document Settings. Add the email address Mail sends from to the Approved Personal Document Email List there, or Amazon will drop the document.")
                    Link("Open Amazon's settings", destination: URL(string: "https://www.amazon.com/hz/mycd/preferences/myx#/home/settings/payment")!)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: s.address) { s.save() }
        .onChange(of: s.method) { s.save() }
        .onChange(of: s.preferEPUB) { s.save() }
    }
}

struct AgentSettings: View {
    @State private var server = LocalServer.shared
    @State private var revealToken = false
    @State private var relayURL: String?
    @State private var relayConnected = false
    @State private var relayBusy = false
    @State private var relayMessage: String?
    @State private var output: String?

    private var token: String { LocalServer.token }

    var body: some View {
        Form {
            Section("This Mac") {
                LabeledContent("MCP server") {
                    HStack(spacing: 6) {
                        Circle().fill(server.isRunning ? Color.green : Color.red).frame(width: 7, height: 7)
                        Text(server.isRunning ? server.mcpURL : (server.lastError ?? "Stopped")).textSelection(.enabled).font(.callout.monospaced())
                    }
                }
                LabeledContent("Token") {
                    HStack {
                        Text(revealToken ? token : String(repeating: "•", count: 18)).font(.callout.monospaced()).textSelection(.enabled).lineLimit(1)
                        Button(revealToken ? "Hide" : "Show") { revealToken.toggle() }
                        Button("Copy") { copy(token) }
                    }
                }
                LabeledContent("Claude Code") {
                    Button("Copy Command") {
                        copy("claude mcp add --transport http ezpdf \(server.mcpURL) --header \"Authorization: Bearer \(token)\"")
                    }
                }
                LabeledContent("Claude Desktop, Cursor, others") {
                    Button("Copy JSON") {
                        copy("""
                        {
                          "mcpServers": {
                            "ezpdf": {
                              "command": "npx",
                              "args": ["-y", "mcp-remote", "\(server.mcpURL)", "--header", "Authorization: Bearer \(token)"]
                            }
                          }
                        }
                        """)
                    }
                }
                Button("New Token…") {
                    LocalServer.rotateToken()
                    revealToken = true
                    // TopRelay stored the old token as its upstream header; update it, or every relayed call fails.
                    if relayURL != nil {
                        relay {
                            relayURL = try await TopRelay.connect(localURL: server.mcpURL, token: LocalServer.token)
                            relayMessage = "TopRelay now uses the new token."
                        }
                    }
                }
                .help("Disconnects every agent using the old token")
            }

            Section {
                if TopRelay.binary == nil {
                    Text("Install TopRelay to reach ezpdf from Grok, ChatGPT and claude.ai. It runs on your own free Cloudflare account; nothing goes through us.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    LabeledContent("Public address") {
                        HStack(spacing: 6) {
                            if relayURL != nil { Circle().fill(relayConnected ? Color.green : Color.orange).frame(width: 7, height: 7) }
                            Text(relayURL ?? "Not connected").font(.callout.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                            if let u = relayURL { Button("Copy") { copy(u) } }
                        }
                    }
                    HStack {
                        Button(relayURL == nil ? "Make Reachable" : "Reconnect") { relay { relayURL = try await TopRelay.connect(localURL: server.mcpURL, token: token); try? await TopRelay.startAtLogin() } }
                        Button("Code for claude.ai / ChatGPT") { relay { let c = try await TopRelay.pairingCode(); output = "Pairing code: \(c)\nAdd \(relayURL ?? "the address") as a custom connector, then enter this code on the consent page."; copy(c) } }
                            .disabled(relayURL == nil)
                        Button("Key for Grok") { relay { let k = try await TopRelay.key(client: "xai"); output = k.snippet.isEmpty ? k.key : k.snippet; copy(output ?? "") } }
                            .disabled(relayURL == nil)
                        Button("Allow Editing Tools") { relay { try await TopRelay.allowAllTools(); relayMessage = "Agents can now edit, convert and send, not just read." } }
                            .disabled(relayURL == nil)
                    }
                    .disabled(relayBusy)
                    if relayBusy { ProgressView().controlSize(.small) }
                    if let m = relayMessage { Text(m).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    if let o = output {
                        Text(o).font(.caption.monospaced()).textSelection(.enabled)
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                        Text("Copied to the clipboard.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Grok, ChatGPT, claude.ai (via TopRelay)")
            } footer: {
                Text("Only reading tools are shared until you allow editing. Traffic passes through your own Cloudflare Worker.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { let s = await TopRelay.status(); relayURL = s.url; relayConnected = s.connected; relayMessage = s.error }
    }

    private func relay(_ body: @escaping () async throws -> Void) {
        relayBusy = true; relayMessage = nil
        Task {
            defer { relayBusy = false }
            do { try await body(); let s = await TopRelay.status(); relayConnected = s.connected; if relayURL == nil { relayURL = s.url } }
            catch { relayMessage = error.localizedDescription }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct BrowserSettings: View {
    @State private var paired = LocalServer.isExtensionPaired
    private var extensionFolder: URL? {
        Bundle.main.url(forResource: "ezpdf-extension", withExtension: nil)
    }

    var body: some View {
        Form {
            Section("Chrome, Edge, Arc, Brave") {
                Text("1. Open chrome://extensions and turn on Developer mode.\n2. Click “Load unpacked” and choose the ezpdf extension folder.\n3. Pin ezpdf. Click it on any page, right click a link, or drop a link on its popup.")
                    .font(.callout)
                HStack {
                    Button("Show Extension Folder") {
                        if let f = extensionFolder { NSWorkspace.shared.activateFileViewerSelecting([f]) }
                    }
                    .disabled(extensionFolder == nil)
                    Button("Open chrome://extensions") {
                        NSWorkspace.shared.open([URL(string: "chrome://extensions")!], withApplicationAt: URL(fileURLWithPath: "/Applications/Google Chrome.app"), configuration: .init())
                    }
                }
            }
            Section("Safari") {
                Text("Safari needs the extension packaged as an app extension. Run BrowserExtension/build.sh --safari, build the generated project once, then turn it on in Safari → Settings → Extensions.")
                    .font(.callout)
            }
            Section {
                LabeledContent("Connection") {
                    HStack {
                        Text(paired ? "Connected" : "Not connected yet").foregroundStyle(.secondary)
                        if paired { Button("Disconnect") { LocalServer.unpairExtension(); paired = false } }
                    }
                }
                Text("The first time you use the extension, ezpdf asks you to allow it. It talks only to ezpdf on this Mac (127.0.0.1); web pages can't use that connection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Help

/// How to use ezpdf, task by task. Short steps, the shortcut next to each, and a way to jump
/// straight to the setting a step mentions.
struct HelpSettings: View {
    @AppStorage("ezpdf.settingsTab") private var tab = SettingsTab.help.rawValue
    @State private var open: Set<String> = ["Make a PDF from a link"]

    struct Topic: Identifiable {
        var id: String { title }
        let title: String
        let symbol: String
        let steps: [String]
        var shortcut: String? = nil
        var settings: SettingsTab? = nil
    }

    static let topics: [Topic] = [
        Topic(title: "Make a PDF from a link", symbol: "link", steps: [
            "Paste a link into the box at the top of the sidebar and press Return. Several links at once work too.",
            "Pick the page size under the box first: Kindle for ereaders, Letter or A4 for printing, “As on the web” to keep the site's design.",
            "ezpdf removes ads and menus, keeps images, code, math and charts, and adds a clickable table of contents. Article pages also get an EPUB.",
            "A link straight to a PDF is saved as it is.",
        ], shortcut: "⌘L  ·  ⇧⌘V converts a link on the clipboard", settings: .general),
        Topic(title: "Make a PDF from files", symbol: "doc.badge.plus", steps: [
            "Drop files anywhere on the window, or choose File → Make PDF from Files.",
            "Images, iPhone photos (HEIC), Word, RTF, Markdown, HTML, CSV and text all work. Several files become one PDF, in name order.",
            "Drop a PDF to add it to your library as is.",
        ], shortcut: "⌘O"),
        Topic(title: "Read", symbol: "book", steps: [
            "Click a document in the library. It reopens where you left off.",
            "Use the toolbar for contents and page thumbnails, the page number, and Aa for zoom, Sepia or Night theme, and read aloud.",
            "Select text and press ⇧⌘H to highlight it. Add notes from the ⋯ menu. Changes save by themselves.",
            "“Summarize on This Mac” in the ⋯ menu uses Apple Intelligence; nothing leaves your Mac.",
        ], shortcut: "⌘F find  ·  ⌘G next match  ·  ⇧⌘H highlight  ·  ⌥⌘R read aloud"),
        Topic(title: "Rearrange, split and shrink", symbol: "square.grid.2x2", steps: [
            "Switch to Pages in the toolbar. Click pages to select them; ⌘ click adds, ⇧ click selects a range.",
            "Drag pages to reorder. Use the buttons to rotate, duplicate, extract to a new document or delete.",
            "The scissors menu splits a document, and Undo restores the version before your last change.",
            "In the ⋯ menu: Compress, Make Text Searchable (OCR for scans), and Add Page Numbers.",
        ], shortcut: "⌥⌘P switches between Read and Pages"),
        Topic(title: "Bank statements and invoices", symbol: "tablecells", steps: [
            "Open the statement or invoice and click the table icon (or Document → Extract Data).",
            "Statements become a list of transactions. ezpdf checks every row against the running balance and warns you if something doesn't add up.",
            "Invoices give the vendor, number, dates, tax, total and line items. Anything else gives its tables.",
            "Save to Excel or CSV, or Copy and paste into Numbers. Scanned pages are read on this Mac with OCR.",
        ], shortcut: "⇧⌘E"),
        Topic(title: "Send to Kindle", symbol: "paperplane", steps: [
            "Add your Send to Kindle address in the Kindle tab.",
            "On Amazon, add the email address Mail sends from to your Approved Personal Document Email List.",
            "Click the paper plane in the toolbar. Web articles go as EPUB, so you can change the text size on your Kindle.",
        ], shortcut: "⇧⌘K", settings: .kindle),
        Topic(title: "From your browser", symbol: "safari", steps: [
            "Install the ezpdf extension from the Browser tab.",
            "Click the ezpdf button on any page: Make PDF, To Kindle, EPUB or Extract data. Or right click a page or a link.",
            "Turn on “Use the page as I see it” for pages that need you to be signed in, like a bank's website.",
        ], shortcut: "⌥⇧P opens the popup  ·  ⌥⇧K sends the page to Kindle", settings: .browser),
        Topic(title: "Let AI agents use ezpdf", symbol: "sparkles", steps: [
            "Claude Code: copy the command in the Agents tab and paste it in Terminal.",
            "Claude Desktop, Cursor and others: copy the JSON from the Agents tab into the app's MCP settings.",
            "Grok, ChatGPT, claude.ai: click Make Reachable (needs TopRelay), then use the pairing code or the Grok key.",
            "Agents can read, convert, extract data and send to Kindle. Remote bots can only read until you allow editing.",
        ], settings: .agents),
        Topic(title: "Shortcuts, Spotlight and more", symbol: "bolt", steps: [
            "The Shortcuts app has ezpdf actions: Make PDF from Link, Make PDF from Files, Extract Statement or Invoice Data, Send Link to Kindle.",
            "Spotlight finds text inside every document in your library.",
            "Select a link in any app and choose Services → Make PDF with ezpdf.",
        ]),
        Topic(title: "Privacy", symbol: "lock.shield", steps: [
            "Conversion, OCR, data extraction and summaries run on this Mac.",
            "Your library is in ~/Library/Application Support/ezpdf. Pages are fetched without your browser's cookies.",
            "The agent server only listens on this Mac and needs a token. Web pages can't use it.",
        ]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Self.topics) { topic in
                    TopicRow(topic: topic, isOpen: Binding(
                        get: { open.contains(topic.id) },
                        set: { if $0 { open.insert(topic.id) } else { open.remove(topic.id) } }),
                        go: { tab = $0.rawValue })
                }
                HStack {
                    Text("Still stuck? Every feature is also in the menus, with its shortcut.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Link("Project on GitHub", destination: URL(string: "https://github.com/harikanthl/ezpdf")!).font(.caption)
                }
                .padding(.top, 8)
            }
            .padding(4)
        }
        .frame(height: 470)
    }
}

private struct TopicRow: View {
    let topic: HelpSettings.Topic
    @Binding var isOpen: Bool
    let go: (SettingsTab) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : Motion.out) { isOpen.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: topic.symbol).foregroundStyle(Color.accentColor).frame(width: 20)
                    Text(topic.title).font(.body.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(topic.steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(i + 1)").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary)
                                .frame(width: 14, alignment: .trailing)
                            Text(step).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if topic.shortcut != nil || topic.settings != nil {
                        HStack {
                            if let k = topic.shortcut {
                                Label(k, systemImage: "keyboard").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let s = topic.settings {
                                Button("Open \(s.rawValue.capitalized) Settings") { go(s) }.buttonStyle(PressableStyle()).controlSize(.small)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(.leading, 42).padding(.trailing, 12).padding(.bottom, 12)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -4)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(isOpen ? 0.55 : 0.3)))
    }
}
