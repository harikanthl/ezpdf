import UniformTypeIdentifiers
import SwiftUI
import EzPDFCore

/// Ready-made documents: pick one and it opens as a fillable PDF (click a blank and type, or ask
/// the assistant to fill it in).
struct TemplatesView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var making: String?
    @State private var mine: [UserTemplate] = []
    @State private var choosingForm = false
    @State private var dropTargeted = false
    @State private var importing: String?

    private var categories: [String] { Array(Set(DocTemplate.all.map(\.category))).sorted() }

    private func items(in category: String) -> [DocTemplate] {
        DocTemplate.all.filter { $0.category == category && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query)) }
    }

    private var myItems: [UserTemplate] {
        mine.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    private let grid = [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Start from a Template").font(.title3.weight(.semibold))
                Spacer()
                TextField("Search", text: $query).textFieldStyle(.roundedBorder).frame(width: 200)
                Button("Done") { dismiss() }.buttonStyle(PressableStyle()).keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("My Templates").font(.headline).foregroundStyle(.secondary)
                    LazyVGrid(columns: grid, spacing: 12) {
                        fromFormCard
                        ForEach(myItems) { t in mineCard(t) }
                    }
                    ForEach(categories, id: \.self) { cat in
                        let list = items(in: cat)
                        if !list.isEmpty {
                            Text(cat).font(.headline).foregroundStyle(.secondary)
                            LazyVGrid(columns: grid, spacing: 12) {
                                ForEach(list) { t in card(t) }
                            }
                        }
                    }
                    Text("Agreements and consent forms are starting points, not legal advice.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding(16)
            }
        }
        .frame(minWidth: 620, idealWidth: 760, minHeight: 480, idealHeight: 620)
        .onAppear { mine = app.ops.userTemplates() }
        .onReceive(NotificationCenter.default.publisher(for: EzPDF.templatesDidChange)) { _ in mine = app.ops.userTemplates() }
        .fileImporter(isPresented: $choosingForm, allowedContentTypes: [.pdf, .image]) { r in
            if case .success(let url) = r { importForm(url) }
        }
    }

    /// Drop or pick a printed form, a scan or a photo of one: it comes back fillable and is kept here.
    private var fromFormCard: some View {
        Button { choosingForm = true } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "doc.viewfinder").font(.system(size: 20, weight: .light)).foregroundStyle(Color.accentColor)
                    Spacer()
                    if importing != nil { ProgressView().controlSize(.small) }
                }
                Text(importing.map { "Reading \($0)…" } ?? "Make from a Form…").font(.callout.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                Text("Drop a PDF, scan or photo of a form. Its blanks become fields you can fill and reuse.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3).multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(dropTargeted ? 0.18 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(dropTargeted ? 0.8 : 0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyleLight())
        .disabled(importing != nil || making != nil)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.isFileURL else { return false }
            importForm(url)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private func mineCard(_ t: UserTemplate) -> some View {
        Button { make(saved: t) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "doc.text.fill").font(.system(size: 20, weight: .light)).foregroundStyle(Color.accentColor)
                    Spacer()
                    if making == t.id { ProgressView().controlSize(.small) }
                }
                Text(t.name).font(.callout.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                Text("\(t.fields.count) field\(t.fields.count == 1 ? "" : "s") · \(t.pageCount) page\(t.pageCount == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.45)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyleLight())
        .disabled(making != nil || importing != nil)
        .contextMenu {
            Button("Delete Template", role: .destructive) {
                do { try app.ops.deleteUserTemplate(t.id) } catch { app.show(error.localizedDescription, error: true) }
            }
        }
    }

    private func card(_ t: DocTemplate) -> some View {
        Button { make(t) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: t.symbol).font(.system(size: 20, weight: .light)).foregroundStyle(Color.accentColor)
                    Spacer()
                    if making == t.id { ProgressView().controlSize(.small) }
                }
                Text(t.name).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                Text(t.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.45)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyleLight())
        .disabled(making != nil || importing != nil)
    }

    private func make(_ t: DocTemplate) {
        making = t.id
        Task {
            defer { making = nil }
            do {
                let rec = try await app.ops.create(template: t)
                opened(rec)
            } catch { app.show(error.localizedDescription, error: true) }
        }
    }

    private func make(saved t: UserTemplate) {
        making = t.id
        defer { making = nil }
        do { opened(try app.ops.create(userTemplate: t.id)) }
        catch { app.show(error.localizedDescription, error: true) }
    }

    private func opened(_ rec: DocumentRecord) {
        app.selection = rec.id
        dismiss()
        app.show("Click a blank to type, or ask the assistant to fill it in", documentID: rec.id)
    }

    private func importForm(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        guard ext == "pdf" || UTType(filenameExtension: ext)?.conforms(to: .image) == true else {
            app.show("Drop a PDF or an image of a form.", error: true)
            return
        }
        let name = url.deletingPathExtension().lastPathComponent
        importing = name
        Task {
            defer { importing = nil }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let (r, t) = try await app.ops.importForm(url, templateName: name)
                app.selection = r.record.id
                dismiss()
                app.show("Found \(r.fields.count) blank\(r.fields.count == 1 ? "" : "s") and saved “\(t?.name ?? name)” to My Templates", documentID: r.record.id)
            } catch { app.show(error.localizedDescription, error: true) }
        }
    }
}

/// Header, footer, page numbers, Bates numbers and a logo for every page.
struct HeaderFooterSheet: View {
    var onApply: (Stamps.Config) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var c = Stamps.Config()
    @State private var choosingLogo = false
    @State private var size = 9.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Header & Footer").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("").frame(width: 50)
                    Text("Left").font(.caption).foregroundStyle(.secondary)
                    Text("Center").font(.caption).foregroundStyle(.secondary)
                    Text("Right").font(.caption).foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Header").font(.callout)
                    TextField("", text: $c.headerLeft).textFieldStyle(.roundedBorder)
                    TextField("", text: $c.headerCenter).textFieldStyle(.roundedBorder)
                    TextField("", text: $c.headerRight).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Footer").font(.callout)
                    TextField("", text: $c.footerLeft).textFieldStyle(.roundedBorder)
                    TextField("", text: $c.footerCenter).textFieldStyle(.roundedBorder)
                    TextField("", text: $c.footerRight).textFieldStyle(.roundedBorder)
                }
            }
            .frame(width: 520)
            HStack(spacing: 6) {
                Text("Insert:").font(.caption).foregroundStyle(.secondary)
                ForEach([("Page", "Page @page of @total"), ("Date", "@date"), ("Title", "@title"), ("Bates", "@bates")], id: \.0) { name, token in
                    Button(name) { c.footerCenter = c.footerCenter.isEmpty ? token : c.footerCenter + " " + token }.buttonStyle(ChipStyle())
                }
            }
            HStack {
                Stepper("Size \(Int(size)) pt", value: $size, in: 6...24)
                Toggle("Skip first page", isOn: $c.skipFirstPage)
                Toggle("Mirror even pages", isOn: $c.mirrorEvenPages)
            }
            HStack {
                Button(c.logo == nil ? "Add Logo…" : "Change Logo…") { choosingLogo = true }.buttonStyle(PressableStyle())
                if c.logo != nil {
                    Picker("", selection: $c.logoPosition) {
                        Text("Header left").tag(Stamps.LogoPosition.headerLeft)
                        Text("Header center").tag(Stamps.LogoPosition.headerCenter)
                        Text("Header right").tag(Stamps.LogoPosition.headerRight)
                        Text("Footer left").tag(Stamps.LogoPosition.footerLeft)
                        Text("Footer right").tag(Stamps.LogoPosition.footerRight)
                    }.labelsHidden().fixedSize()
                    Button("Remove") { c.logo = nil }.buttonStyle(PressableStyle())
                }
                Spacer()
                TextField("Bates prefix", text: $c.batesPrefix).textFieldStyle(.roundedBorder).frame(width: 110)
            }
            Text("Tokens: @page, @total, @date, @date{MMM d, yyyy}, @title, @author, @filename, @bates.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(PressableStyle()).keyboardShortcut(.cancelAction)
                Button("Apply") { c.fontSize = CGFloat(size); onApply(c); dismiss() }
                    .buttonStyle(PressableStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .fileImporter(isPresented: $choosingLogo, allowedContentTypes: [.image]) { r in
            if case .success(let url) = r {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                c.logo = try? Data(contentsOf: url)
            }
        }
    }
}
