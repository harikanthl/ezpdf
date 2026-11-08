import SwiftUI
import EzPDFCore

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            KindleSettings().tabItem { Label("Kindle", systemImage: "book.closed") }
            AgentSettings().tabItem { Label("Agents", systemImage: "sparkles") }
            BrowserSettings().tabItem { Label("Browser", systemImage: "safari") }
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
                TextField("Send-to-Kindle address", text: $s.address, prompt: Text("name_abc123@kindle.com"))
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
                    Text("Find your address on Amazon under Manage Your Content and Devices → Preferences → Personal Document Settings. Add the email address Mail sends from to the Approved Personal Document E-mail List there, or Amazon will drop the document.")
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
                Button("New Token…") { LocalServer.rotateToken(); revealToken = true }
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
                Text("Only read-only tools are shared until you allow editing. Traffic passes through your own Cloudflare Worker.")
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
    private var extensionFolder: URL? {
        Bundle.main.url(forResource: "ezpdf-extension", withExtension: nil)
    }

    var body: some View {
        Form {
            Section("Chrome, Edge, Arc, Brave") {
                Text("1. Open chrome://extensions and turn on Developer mode.\n2. Click “Load unpacked” and choose the ezpdf extension folder.\n3. Pin ezpdf. Click it on any page, right-click a link, or drop a link on its popup.")
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
                Text("The extension talks only to ezpdf on this Mac (127.0.0.1). Web pages can't use that connection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
