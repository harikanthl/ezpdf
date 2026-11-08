import SwiftUI
import PDFKit
import EzPDFCore

struct ReaderView: View {
    let record: DocumentRecord
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var reader = ReaderController()

    enum Mode: String, CaseIterable { case read = "Read", pages = "Pages" }

    @State private var mode: Mode = .read
    @State private var side: SideChoice = .none
    @State private var showSearch = false
    @State private var searchText = ""
    @State private var pageField = "1"
    @State private var noteText = ""
    @State private var showNote = false
    @State private var busy: String?
    @State private var summary: String?
    @State private var showSummary = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if showSearch { searchBar }
            HStack(spacing: 0) {
                if side != .none, mode == .read {
                    sidebar(side)
                        .frame(width: 210)
                        .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
                    Divider()
                }
                ZStack {
                    PDFViewHost(controller: reader)
                        .opacity(mode == .read ? 1 : 0)
                    if mode == .pages {
                        PagesView(record: record, beforeEdit: { reader.flushAnnotations() })
                    }
                }
            }
        }
        .navigationTitle(record.title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .onAppear { reload(page: app.openPage); app.openPage = nil }
        .onChange(of: record.modifiedAt) {
            // Reload only for changes made elsewhere (page edits, agents, undo), not our own saves.
            // load() first merges any pending highlights onto the new version.
            if record.modifiedAt != reader.lastSavedModifiedAt { reload(page: reader.currentPageIndex + 1) }
        }
        .onChange(of: app.openPage) {
            if let p = app.openPage { withoutAnimation { mode = .read }; reader.goTo(pageNumber: p); app.openPage = nil }
        }
        .onChange(of: reader.currentPageIndex) { pageField = "\(reader.currentPageIndex + 1)" }
        .onDisappear { reader.flushAnnotations(); reader.stopSpeaking() }
        .sheet(isPresented: $showSummary) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Summary", systemImage: "apple.intelligence").font(.title3.weight(.semibold))
                ScrollView { Text(summary ?? "").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                Text("Made on this Mac with Apple Intelligence. Check important details against the document.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(summary ?? "", forType: .string) }
                        .buttonStyle(PressableStyle())
                    Button("Done") { showSummary = false }.buttonStyle(PressableStyle(prominent: true)).keyboardShortcut(.defaultAction)
                }
            }
            .padding(20).frame(width: 520, height: 420)
        }
        .overlay(alignment: .bottom) {
            if let busy {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(busy).font(.callout) }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 18)
                    .transition(Motion.toastTransition(reduceMotion: reduceMotion))
            }
        }
        .background {
            // Keyboard shortcuts: no animation on any of these.
            Group {
                Button("") { withoutAnimation { showSearch = true }; searchFocused = true }.keyboardShortcut("f")
                Button("") { reader.highlightSelection() }.keyboardShortcut("h", modifiers: [.command, .shift])
                Button("") { withoutAnimation { mode = mode == .read ? .pages : .read } }.keyboardShortcut("p", modifiers: [.command, .option])
            }.opacity(0).allowsHitTesting(false)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let s = record.siteName ?? record.sourceFileName { parts.append(s) }
        parts.append("\(record.pageCount) page\(record.pageCount == 1 ? "" : "s")")
        if let p = record.preset, let preset = PagePreset(rawValue: p) { parts.append(preset.displayName) }
        return parts.joined(separator: " · ")
    }

    private func reload(page: Int? = nil) {
        reader.load(record, url: Library.shared.pdfURL(for: record.id), page: page)
        pageField = "\(reader.currentPageIndex + 1)"
    }

    // MARK: Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in document", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { reader.search(searchText) }
                .onChange(of: searchText) { reader.search(searchText) }
            if reader.matchCount > 0 {
                Text("\(reader.currentMatch) of \(reader.matchCount)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            } else if searchText.count >= 2 {
                Text("No matches").font(.callout).foregroundStyle(.secondary)
            }
            Button { reader.previousMatch() } label: { Image(systemName: "chevron.up") }.buttonStyle(IconButtonStyle())
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button { reader.nextMatch() } label: { Image(systemName: "chevron.down") }.buttonStyle(IconButtonStyle())
                .keyboardShortcut("g")
            Button("Done") { withoutAnimation { showSearch = false }; searchText = ""; reader.clearSearch() }
                .buttonStyle(PressableStyle()).keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: Sidebar

    @ViewBuilder
    private func sidebar(_ side: SideChoice) -> some View {
        switch side {
        case .none:
            EmptyView()
        case .thumbnails:
            ThumbnailHost(controller: reader)
        case .outline:
            if reader.outline.isEmpty {
                ContentUnavailableView("No contents", systemImage: "list.bullet.indent", description: Text("This document has no table of contents."))
            } else {
                List(reader.outline) { item in
                    Button { reader.go(to: item) } label: {
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.label).lineLimit(2)
                                .font(item.level == 0 ? .callout.weight(.medium) : .callout)
                                .foregroundStyle(item.level == 0 ? .primary : .secondary)
                            Spacer(minLength: 6)
                            if item.page > 0 { Text("\(item.page)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary) }
                        }
                        .padding(.leading, CGFloat(min(item.level, 4)) * 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.sidebar)
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Sidebar", selection: Binding(get: { side }, set: { v in withAnimation(reduceMotion ? nil : Motion.out) { side = v } })) {
                Image(systemName: "rectangle").tag(SideChoice.none)
                Image(systemName: "list.bullet.indent").tag(SideChoice.outline)
                Image(systemName: "square.grid.2x2").tag(SideChoice.thumbnails)
            }
            .pickerStyle(.segmented)
            .help("Contents or page thumbnails")
            .disabled(mode == .pages)
        }
        ToolbarItem(placement: .principal) {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
            .help("Read, or rearrange pages (⌥⌘P)")
        }
        ToolbarItemGroup {
            if mode == .read {
                HStack(spacing: 2) {
                    TextField("", text: $pageField)
                        .frame(width: 38)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if let n = Int(pageField) { reader.goTo(pageNumber: n) } }
                    Text("/ \(reader.pageCount)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                .help("Page")
                Menu {
                    Button("Zoom In") { reader.zoomIn() }.keyboardShortcut("+")
                    Button("Zoom Out") { reader.zoomOut() }.keyboardShortcut("-")
                    Button("Fit Width") { reader.zoomToFit() }.keyboardShortcut("0")
                    Toggle("Two Pages", isOn: Binding(get: { reader.twoUp }, set: { _ in reader.toggleTwoUp() }))
                    Divider()
                    Picker("Theme", selection: Binding(get: { reader.theme }, set: { reader.setTheme($0) })) {
                        ForEach(ReadingTheme.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
                    }
                    Divider()
                    Button(reader.isSpeaking ? "Stop Reading Aloud" : "Read Aloud from This Page") { reader.toggleReadAloud() }
                        .keyboardShortcut("r", modifiers: [.command, .option])
                } label: {
                    Image(systemName: reader.isSpeaking ? "speaker.wave.2.fill" : "textformat.size")
                }
                .help("Zoom \(reader.zoomPercent)%, theme, read aloud")
                Button { reader.highlightSelection() } label: { Image(systemName: "highlighter") }
                    .disabled(!reader.hasSelection)
                    .help("Highlight selection (⇧⌘H)")
            }
            Button { app.extractFor = record } label: { Image(systemName: "tablecells") }
                .help("Extract transactions, invoice fields or tables")
            Button { app.sendToKindle(record) } label: { Image(systemName: "paperplane") }
                .help("Send to Kindle")
            Menu {
                Button("Summarize on This Mac") { summarize() }.disabled(!app.ops.canSummarize)
                Button("Add Note to This Page…") { showNote = true }.disabled(mode != .read)
                Divider()
                Button("Save PDF to Downloads") { app.export(record, as: .pdf) }
                if record.hasEPUB { Button("Save EPUB to Downloads") { app.export(record, as: .epub) } }
                Divider()
                Button("Compress") { optimize(.compress) }
                Button("Compress More (lower image quality)") { optimize(.compress_strong) }
                Button("Make Text Searchable (OCR)") { optimize(.make_searchable) }
                Button("Add Page Numbers") { optimize(.page_numbers) }
                Divider()
                Button("Undo Last Change") { undo() }
                Button("Show in Finder") { app.revealInLibrary(record) }
                if let src = record.sourceURL, let u = URL(string: src) { Button("Open Original Page") { NSWorkspace.shared.open(u) } }
            } label: { Image(systemName: "ellipsis.circle") }
            .help("More")
            .popover(isPresented: $showNote, arrowEdge: .bottom) { notePopover }
            ShareLink(item: Library.shared.pdfURL(for: record.id)) { Image(systemName: "square.and.arrow.up") }
                .help("Share")
        }
    }

    enum SideChoice: Hashable { case none, outline, thumbnails }

    private var notePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Note on page \(reader.currentPageIndex + 1)").font(.headline)
            TextEditor(text: $noteText).frame(width: 260, height: 90).font(.body)
                .scrollContentBackground(.hidden).padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
            HStack {
                Spacer()
                Button("Cancel") { showNote = false }.buttonStyle(PressableStyle()).keyboardShortcut(.escape, modifiers: [])
                Button("Add") { reader.addNote(noteText); noteText = ""; showNote = false }
                    .buttonStyle(PressableStyle(prominent: true)).keyboardShortcut(.return, modifiers: .command)
                    .disabled(noteText.isEmpty)
            }
        }
        .padding(14)
    }

    private func optimize(_ action: EzPDF.Optimization) {
        reader.flushAnnotations()
        withAnimation(reduceMotion ? nil : Motion.out) { busy = action == .make_searchable ? "Reading scanned pages…" : "Working…" }
        Task {
            defer { withAnimation(reduceMotion ? nil : Motion.outFast) { busy = nil } }
            do {
                let r = try await app.ops.optimize(record.id, action)
                switch action {
                case .compress, .compress_strong:
                    app.show(r.after < r.before ? "Now \(ByteCountFormatter.string(fromByteCount: Int64(r.after), countStyle: .file)), was \(ByteCountFormatter.string(fromByteCount: Int64(r.before), countStyle: .file))" : "Already as small as this setting gets")
                case .make_searchable: app.show("Text is now searchable")
                default: app.show("Done")
                }
            } catch { app.show(error.localizedDescription, error: true) }
        }
    }

    private func summarize() {
        withAnimation(reduceMotion ? nil : Motion.out) { busy = "Summarizing on this Mac…" }
        Task {
            defer { withAnimation(reduceMotion ? nil : Motion.outFast) { busy = nil } }
            do { summary = try await app.ops.summarize(record.id); showSummary = true }
            catch { app.show(error.localizedDescription, error: true) }
        }
    }

    private func undo() {
        reader.flushAnnotations()
        do { _ = try app.ops.undo(record.id); app.show("Restored the previous version") }
        catch { app.show(error.localizedDescription, error: true) }
    }
}

