import SwiftUI
import UniformTypeIdentifiers
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
    @State private var editTool: EditTool?
    @State private var placed: (tool: EditTool, page: Int, rect: CGRect)?
    @State private var showPlacement = false
    @State private var replacing: (text: String, page: Int)?
    @State private var showReplace = false
    @State private var editingObject: ObjectEditSheet.Model?
    @State private var showHeaderFooter = false
    @State private var marking = false
    @State private var showLogoGen = false
    @State private var dropTargeted = false
    @State private var strokes: [[CGPoint]] = []
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if showSearch { searchBar }
            mainArea
        }
        // A native inspector column: resizable, and it gives way properly when the window narrows.
        .inspector(isPresented: Binding(get: { app.showAssistant }, set: { app.showAssistant = $0 })) {
            AssistantPanel(chat: app.assistant)
                .inspectorColumnWidth(min: 280, ideal: 340, max: 520)
        }
        .navigationTitle(record.title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .onAppear {
            reload(page: app.openPage); app.openPage = nil
            reader.onEditObject = { id, a in
                editingObject = .init(id: id, isText: a.type == "FreeText", text: a.contents ?? "",
                                      font: a.font?.fontName ?? ".AppleSystemUIFont", size: Double(a.font?.pointSize ?? 12),
                                      color: Color(nsColor: (a.type == "FreeText" ? a.fontColor : a.color) ?? .black))
            }
        }
        .onChange(of: record.modifiedAt) {
            // Reload only for changes made elsewhere (page edits, agents, undo), not our own saves.
            // load() first merges any pending highlights onto the new version.
            if record.modifiedAt != reader.lastSavedModifiedAt { reload(page: reader.currentPageIndex + 1) }
        }
        .onChange(of: app.openPage) {
            if let p = app.openPage { withoutAnimation { mode = .read }; reader.goTo(pageNumber: p); app.openPage = nil }
        }
        // Sending the message uses the mark; clear the strokes then.
        .onChange(of: app.assistant.mark) { if app.assistant.mark == nil, !strokes.isEmpty { strokes = []; marking = false } }
        .onChange(of: reader.currentPageIndex) { pageField = "\(reader.currentPageIndex + 1)"; app.currentPage = reader.currentPageIndex + 1 }
        .sheet(isPresented: $showPlacement) {
            if let placed {
                PlacementSheet(tool: placed.tool) { text, size, color, image in applyPlacement(text: text, fontSize: size, color: color, image: image) }
            }
        }
        .sheet(isPresented: $showLogoGen) {
            LogoGeneratorSheet { data in placeImage(data, atView: nil) }
        }
        .sheet(isPresented: $showHeaderFooter) {
            HeaderFooterSheet { c in
                reader.flushAnnotations()
                do { let r = try app.ops.stamp(record.id, c); app.show("Added to \(r.pages) page\(r.pages == 1 ? "" : "s")") }
                catch { app.show(error.localizedDescription, error: true) }
            }
        }
        .sheet(item: $editingObject) { m in
            ObjectEditSheet(model: m, onSave: { saveObject($0) }, onDelete: { deleteObject(m.id) })
        }
        .sheet(isPresented: $showReplace) {
            if let replacing {
                ReplaceSheet(original: replacing.text) { new in replaceSelection(replacing.text, with: new, page: replacing.page) }
            }
        }
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

    private var mainArea: some View {
    HStack(spacing: 0) {
        if side != .none, mode == .read {
            sidebar(side)
                .frame(minWidth: 150, idealWidth: 210, maxWidth: 260)
                .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
            Divider()
        }
        documentArea
            .frame(minWidth: 320)
    }
    }

    private var documentArea: some View {
    ZStack {
        PDFViewHost(controller: reader)
            .opacity(mode == .read ? 1 : 0)
            // Drop a picture (logo, signature, stamp) onto the page to place it there.
            .onDrop(of: [.image, .fileURL], isTargeted: $dropTargeted) { providers, location in
                handleImageDrop(providers, at: location)
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                        .padding(6).allowsHitTesting(false).transition(.opacity)
                }
            }
        if mode == .pages {
            PagesView(record: record, beforeEdit: { reader.flushAnnotations() })
        }
        if marking, mode == .read {
            MarkOverlay(strokes: $strokes, onStrokeEnded: {
                withAnimation(Motion.outFast) { app.assistant.mark = strokes.isEmpty ? nil : reader.mark(from: strokes) }
            }, onDone: { stopMarking() })
            .transition(.opacity)
        }
        if let tool = editTool, mode == .read {
            PlacementOverlay(tool: tool, onRect: { r in
                guard let p = reader.pageRect(fromView: r) else { return }
                placed = (tool, p.page, p.rect)
                withoutAnimation { editTool = nil }
                if [.box, .whiteout, .redact].contains(tool) { applyPlacement(text: "", fontSize: 12, color: "red", image: nil) }
                else { showPlacement = true }
            }, onCancel: { withoutAnimation { editTool = nil } })
            .transition(.opacity)
        }
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
            Menu {
                ForEach(EditTool.allCases) { t in
                    Button { withoutAnimation { mode = .read; editTool = t } } label: { Label(t.rawValue, systemImage: t.symbol) }
                }
                Divider()
                Button {
                    if let sel = reader.selectionForEdit { replacing = sel; showReplace = true }
                    else { app.show("Select the text to change first.", error: true) }
                } label: { Label("Change Selected Text…", systemImage: "character.cursor.ibeam") }
                Button { showLogoGen = true } label: { Label("Generate Logo or Image…", systemImage: "wand.and.stars") }
                Button { showHeaderFooter = true } label: { Label("Header, Footer & Page Numbers…", systemImage: "rectangle.topthird.inset.filled") }
                Button { optimizeFlatten() } label: { Label("Flatten Annotations and Forms", systemImage: "square.3.layers.3d.down.right") }
            } label: { Image(systemName: "pencil.tip.crop.circle") }
            .help("Edit: add text, sign, images, boxes, white-out, redact, change text")
            Button { marking ? stopMarking() : startMarking() } label: {
                Image(systemName: marking ? "pencil.and.scribble" : "pencil.and.scribble")
                    .foregroundStyle(marking ? Color.accentColor : Color.primary)
            }
            .help("Mark & Talk: draw on the page and say what to change (⇧⌘M)")
            .keyboardShortcut("m", modifiers: [.command, .shift])
            Button { withAnimation(reduceMotion ? nil : Motion.out) { app.showAssistant.toggle() } } label: {
                Image(systemName: app.showAssistant ? "sparkles.rectangle.stack.fill" : "sparkles")
            }
            .help("Assistant: ask for edits in words or by voice (⌘J)")
            .keyboardShortcut("j")
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
            Button { shareDeliverable() } label: { Image(systemName: "square.and.arrow.up") }
                .help("Share (with everything you placed made part of the pages)")
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

    /// Pen on: the assistant opens and listens, so you mark and talk at once (like ezRecord's pencil).
    private func startMarking() {
        withoutAnimation { mode = .read; editTool = nil; marking = true }
        strokes = []
        withAnimation(reduceMotion ? nil : Motion.out) { app.showAssistant = true }
        app.assistant.startListening()
    }

    private func stopMarking() {
        withoutAnimation { marking = false }
    }

    private func handleImageDrop(_ providers: [NSItemProvider], at point: CGPoint) -> Bool {
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "tif", "tiff", "webp", "svg", "bmp"]
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, imageExts.contains(url.pathExtension.lowercased()), let data = try? Data(contentsOf: url) else { return }
                    Task { @MainActor in placeImage(data, atView: point) }
                }
                return true
            }
            if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in placeImage(data, atView: point) }
                }
                return true
            }
        }
        return false
    }

    /// Puts an image on the page as a movable object: where it was dropped, or near the top left of
    /// the page being read. Drag it, or its corner dot, to place and size it.
    private func placeImage(_ data: Data, atView point: CGPoint?) {
        reader.flushAnnotations()
        var page = reader.currentPageIndex + 1
        var rect = CGRect(x: 48, y: 40, width: 110, height: 110)
        if let point, let p = reader.pageRect(fromView: CGRect(x: point.x - 60, y: point.y - 60, width: 120, height: 120)) {
            page = p.page; rect = p.rect
        }
        do {
            try app.ops.addContent(record.id, .init(kind: .image, page: page, rect: rect, imageData: data))
            app.show("Placed. Drag it to move, drag the corner dot to resize.")
        } catch { app.show(error.localizedDescription, error: true) }
    }

    private func applyPlacement(text: String, fontSize: Int, color: String, image: Data?) {
        guard let placed else { return }
        reader.flushAnnotations()
        Task {
            do {
                switch placed.tool {
                case .redact:
                    withAnimation(Motion.out) { busy = "Redacting…" }
                    defer { withAnimation(Motion.outFast) { busy = nil } }
                    _ = try await app.ops.redact(record.id, boxes: [(placed.page, placed.rect)])
                    app.show("Redacted. That area is gone for good (Undo still restores it).")
                case .text:
                    try app.ops.addContent(record.id, .init(kind: .text, page: placed.page, rect: placed.rect, text: text,
                                                            fontSize: CGFloat(fontSize), color: ColorName.parse(color)))
                case .signature:
                    try app.ops.addContent(record.id, .init(kind: .signature, page: placed.page, rect: placed.rect, text: text, imageData: image))
                case .image:
                    try app.ops.addContent(record.id, .init(kind: .image, page: placed.page, rect: placed.rect, imageData: image))
                case .box:
                    try app.ops.addContent(record.id, .init(kind: .shape, page: placed.page, rect: placed.rect, color: .systemRed, shape: .rectangle))
                case .whiteout:
                    try app.ops.addContent(record.id, .init(kind: .whiteout, page: placed.page, rect: placed.rect))
                }
            } catch { app.show(error.localizedDescription, error: true) }
            self.placed = nil
        }
    }

    private func saveObject(_ m: ObjectEditSheet.Model) {
        do {
            _ = try app.ops.updateObject(record.id, object: m.id, .init(
                text: m.isText ? m.text : nil, fontName: m.isText ? m.font : nil, fontSize: m.isText ? CGFloat(m.size) : nil,
                color: NSColor(m.color)))
        } catch { app.show(error.localizedDescription, error: true) }
    }

    private func deleteObject(_ id: String) {
        do { _ = try app.ops.deleteObject(record.id, object: id) } catch { app.show(error.localizedDescription, error: true) }
    }

    private func replaceSelection(_ old: String, with new: String, page: Int) {
        reader.flushAnnotations()
        do {
            let r = try app.ops.replaceText(record.id, find: old, with: new, pages: "\(page)", matchCase: true)
            app.show("Changed \(r.changes.count) place\(r.changes.count == 1 ? "" : "s") on page \(page)")
        } catch { app.show(error.localizedDescription, error: true) }
    }

    private func optimizeFlatten() {
        reader.flushAnnotations()
        do { _ = try app.ops.flatten(record.id); app.show("Annotations and form values are now part of the pages") }
        catch { app.show(error.localizedDescription, error: true) }
    }

    private func shareDeliverable() {
        do {
            let url = try app.ops.deliverableFile(record.id)
            let picker = NSSharingServicePicker(items: [url])
            if let view = NSApp.keyWindow?.contentView {
                picker.show(relativeTo: CGRect(x: view.bounds.maxX - 60, y: view.bounds.maxY - 10, width: 1, height: 1), of: view, preferredEdge: .minY)
            }
        } catch { app.show(error.localizedDescription, error: true) }
    }

    private func undo() {
        reader.flushAnnotations()
        do { _ = try app.ops.undo(record.id); app.show("Restored the previous version") }
        catch { app.show(error.localizedDescription, error: true) }
    }
}

