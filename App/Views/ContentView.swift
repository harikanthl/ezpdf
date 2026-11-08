import SwiftUI
import EzPDFCore
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dropping = false

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            LibrarySidebar()
                .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 380)
        } detail: {
            if let rec = app.selectedDocument {
                ReaderView(record: rec).id(rec.id)
            } else {
                EmptyState()
            }
        }
        .onDrop(of: [.fileURL, .url], isTargeted: Binding(get: { dropping }, set: { v in withAnimation(reduceMotion ? nil : Motion.outFast) { dropping = v } })) {
            app.handleDrop($0)
        }
        .overlay { if dropping { DropOverlay() } }
        .overlay(alignment: .bottom) {
            if let t = app.toast {
                ToastView(toast: t).padding(.bottom, 22).id(t.id)
                    .transition(Motion.toastTransition(reduceMotion: reduceMotion))
            }
        }
        .animation(reduceMotion ? nil : Motion.out, value: app.toast)
        .sheet(item: $app.extractFor) { rec in ExtractSheet(record: rec) }
        .sheet(item: $app.renaming) { rec in RenameSheet(record: rec) }
    }
}

// MARK: Sidebar

struct LibrarySidebar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            ConvertField().padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
            Picker("", selection: $app.filter) {
                ForEach(AppModel.Filter.allCases) { Image(systemName: $0.symbol).help($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 12).padding(.bottom, 6)

            List(selection: $app.selection) {
                let jobs = app.ops.jobs.filter { $0.state != .done }
                if !jobs.isEmpty {
                    Section("In progress") {
                        ForEach(jobs) { job in
                            JobRow(job: job)
                                .transition(Motion.rowTransition(reduceMotion: reduceMotion))
                        }
                    }
                }
                Section(app.filter == .all ? "Library" : app.filter.rawValue) {
                    ForEach(app.visibleDocuments) { doc in
                        DocumentRow(doc: doc).tag(doc.id)
                            .contextMenu { DocumentMenu(doc: doc) }
                    }
                }
            }
            .listStyle(.sidebar)
            .animation(reduceMotion ? nil : Motion.out, value: app.ops.jobs.map(\.id))
            .animation(reduceMotion ? nil : Motion.out, value: app.visibleDocuments.map(\.id))
            .searchable(text: $app.query, placement: .sidebar, prompt: "Filter")
            .overlay {
                if app.documents.isEmpty && app.ops.jobs.isEmpty {
                    Text("Your PDFs will appear here.").font(.callout).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

struct ConvertField: View {
    @Environment(AppModel.self) private var app
    @State private var text = ""
    @State private var preset: PagePreset = EzPDF.shared.defaultPreset
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "link").foregroundStyle(.secondary).font(.system(size: 12, weight: .semibold))
                TextField("Paste a link", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(submit)
                if !text.isEmpty {
                    Button(action: submit) { Image(systemName: "arrow.right.circle.fill").font(.system(size: 17)) }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        .help("Make PDF (Return)")
                }
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.background.opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(focused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08)))
            .animation(Motion.outFast, value: text.isEmpty)

            HStack(spacing: 4) {
                Menu {
                    ForEach(PagePreset.allCases) { p in
                        Button { preset = p } label: {
                            if p == preset { Label(p.displayName, systemImage: "checkmark") } else { Text(p.displayName) }
                        }
                        .help(p.detail)
                    }
                } label: {
                    Label(preset.displayName, systemImage: preset == .web ? "safari" : preset.rawValue.hasPrefix("kindle") ? "book.closed" : "doc")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Page size for new PDFs")
                Spacer()
                Text("or drop files").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 2)
        }
        .onChange(of: preset) { EzPDF.shared.defaultPreset = preset }
        .onChange(of: app.focusConvertField) { if app.focusConvertField { focused = true; app.focusConvertField = false } }
    }

    private func submit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        app.submit(t, preset: preset)
        text = ""
    }
}

struct JobRow: View {
    let job: Job
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if case .failed = job.state {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.title).lineLimit(1).font(.callout.weight(.medium))
                Text(job.detail).lineLimit(2).font(.caption).foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(Motion.outFast, value: job.detail)
            }
            Spacer(minLength: 0)
            if job.source != .app {
                Image(systemName: job.source == .agent ? "sparkles" : job.source == .browser ? "safari" : "bolt")
                    .font(.caption).foregroundStyle(.tertiary)
                    .help(job.source == .agent ? "Started by an AI agent" : job.source == .browser ? "Started from the browser" : "Started by Shortcuts")
            }
            if case .failed = job.state {
                Button { app.ops.dismissJob(job.id) } label: { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle())
            }
        }
        .padding(.vertical, 3)
    }
}

struct DocumentRow: View {
    let doc: DocumentRecord

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(doc.title).lineLimit(2).font(.callout.weight(.medium))
                HStack(spacing: 4) {
                    Text(detail).lineLimit(1)
                    if doc.sentToKindleAt != nil { Image(systemName: "paperplane.fill").font(.system(size: 8)).help("Sent to Kindle") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch doc.kind {
        case .web: return "globe"
        case .statement: return "banknote"
        case .invoice: return "doc.text.below.ecg"
        case .merged: return "square.stack"
        case .imported: return "doc.richtext"
        case .file: return "doc"
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let s = doc.siteName ?? doc.sourceFileName { parts.append(s) }
        parts.append("\(doc.pageCount) p")
        parts.append(doc.createdAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
        return parts.joined(separator: " · ")
    }
}

struct DocumentMenu: View {
    let doc: DocumentRecord
    @Environment(AppModel.self) private var app

    var body: some View {
        Button("Send to Kindle") { app.sendToKindle(doc) }
        Button("Extract Data…") { app.extractFor = doc }
        Divider()
        Button("Save PDF to Downloads") { app.export(doc, as: .pdf) }
        if doc.hasEPUB { Button("Save EPUB to Downloads") { app.export(doc, as: .epub) } }
        Button("Show in Finder") { app.revealInLibrary(doc) }
        if let s = doc.sourceURL, let u = URL(string: s) { Button("Open Original Page") { NSWorkspace.shared.open(u) } }
        Divider()
        Button("Rename…") { app.renaming = doc }
        Button("Move to Trash", role: .destructive) { app.delete(doc) }
    }
}

struct RenameSheet: View {
    let record: DocumentRecord
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename").font(.headline)
            TextField("Title", text: $title).textFieldStyle(.roundedBorder).frame(width: 360).onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(PressableStyle()).keyboardShortcut(.cancelAction)
                Button("Rename", action: save).buttonStyle(PressableStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .onAppear { title = record.title }
    }

    private func save() {
        _ = try? app.ops.rename(record.id, title: title)
        dismiss()
    }
}

// MARK: Empty state, drop overlay, toast

struct EmptyState: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(white: 0.93))
                    .frame(width: 84, height: 108)
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                    .rotationEffect(.degrees(-6))
                    .offset(x: -14)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 84, height: 108)
                    .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
                    .overlay(Image(systemName: "arrow.down.doc").font(.system(size: 30, weight: .light)).foregroundStyle(Color.accentColor))
                    .rotationEffect(.degrees(4))
                    .offset(x: 12)
            }
            .padding(.bottom, 4)
            VStack(spacing: 6) {
                Text("Anything into a good PDF").font(.title2.weight(.semibold))
                Text("Paste a link — an article, a paper, a docs page — and get a clean PDF and EPUB sized for your Kindle. Drop images, Word files, statements or invoices too.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 440)
            }
            HStack(spacing: 10) {
                Button { app.focusConvertField = true } label: { Label("Paste a Link", systemImage: "link") }
                    .buttonStyle(PressableStyle(prominent: true))
                Button { openFiles() } label: { Label("Choose Files…", systemImage: "folder") }
                    .buttonStyle(PressableStyle())
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                hint("⌘L", "Paste a link")
                hint("⌘O", "Convert files")
                hint("⌘F", "Find in a document")
                hint("⇧⌘H", "Highlight selection")
            }
            .font(.callout).foregroundStyle(.secondary)
            .padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func hint(_ key: String, _ text: String) -> some View {
        GridRow {
            Text(key).font(.callout.monospaced()).foregroundStyle(.tertiary).gridColumnAlignment(.trailing)
            Text(text)
        }
    }

    private func openFiles() { AppCommands.openFiles() }
}

struct DropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [8, 6]))
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.accentColor.opacity(0.06)))
            .overlay(Label("Drop to make a PDF", systemImage: "arrow.down.doc").font(.title3.weight(.semibold)).foregroundStyle(Color.accentColor))
            .padding(14)
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

struct ToastView: View {
    let toast: AppModel.Toast
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(toast.isError ? .orange : .green)
            Text(toast.message).font(.callout).lineLimit(3).frame(maxWidth: 420, alignment: .leading)
            if let id = toast.documentID, app.selection != id {
                Button("Open") { app.selection = id; app.toast = nil }.buttonStyle(PressableStyle())
            }
            if !toast.isError, let id = toast.documentID, let rec = app.documents.first(where: { $0.id == id }) {
                Button("Send to Kindle") { app.sendToKindle(rec) }.buttonStyle(PressableStyle())
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 14, y: 6)
    }
}
