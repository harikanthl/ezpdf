import SwiftUI
import OperatorLLM
import EzPDFCore

/// Settings › Models: every model in our catalog (catalog.operatorok.com, refreshed daily) plus
/// fal's image models, with prices and abilities, and one click to use one.
struct ModelsSettings: View {
    @State private var store = ModelCatalogStore.shared
    @State private var query = ""
    @State private var kind: Kind = .chat
    @State private var toolsOnly = true
    @State private var settings = LLMProviderSettings.load()
    @AppStorage("ezpdf.logoModel") private var logoModel = "apple"

    enum Kind: String, CaseIterable { case chat = "Chat", images = "Images", all = "All" }

    private var rows: [ModelCatalogStore.Entry] {
        store.entries.filter { e in
            switch kind {
            case .chat: guard e.category == "text" || e.category == "router" else { return false }
                if toolsOnly, e.supportsTools == false { return false }
            case .images: guard e.category == "image" else { return false }
            case .all: break
            }
            return query.isEmpty || e.name.localizedCaseInsensitiveContains(query) || e.id.localizedCaseInsensitiveContains(query)
                || e.provider.localizedCaseInsensitiveContains(query)
        }
        .prefix(300).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            current
            HStack {
                Picker("", selection: $kind) { ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                if kind == .chat { Toggle("Uses tools", isOn: $toolsOnly).help("Only models that can call ezpdf's tools") }
                Spacer()
                TextField("Search models", text: $query).textFieldStyle(.roundedBorder).frame(width: 180)
            }
            if store.entries.isEmpty {
                ContentUnavailableView {
                    Label(store.loading ? "Loading models…" : "No models yet", systemImage: "cpu")
                } description: {
                    Text(store.lastError ?? "Get the current list from the ezpdf model catalog.")
                } actions: {
                    Button("Load Models") { Task { await store.refresh() } }.disabled(store.loading)
                }
                .frame(maxHeight: .infinity)
            } else {
                List(rows) { e in row(e) }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    .frame(minHeight: 300)
            }
            footer
        }
        .padding(.top, 4)
        .task { await store.refreshIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: LLMProviderSettings.didChange)) { _ in settings = LLMProviderSettings.load() }
    }

    private var current: some View {
        HStack(spacing: 16) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Assistant").font(.caption).foregroundStyle(.secondary)
                    Text(settings.preset == .onDevice ? "Apple Intelligence" : "\(settings.effectiveModelId) · \(settings.preset.displayName)")
                        .font(.callout.weight(.medium)).lineLimit(1)
                }
            } icon: { Image(systemName: "bubble.left.and.text.bubble.right").foregroundStyle(Color.accentColor) }
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Images and logos").font(.caption).foregroundStyle(.secondary)
                    let m = ImageGen.model(id: logoModel)
                    Text("\(m.name) · \(m.provider.displayName)").font(.callout.weight(.medium)).lineLimit(1)
                }
            } icon: { Image(systemName: "wand.and.stars").foregroundStyle(Color.accentColor) }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary.opacity(0.4)))
    }

    private func row(_ e: ModelCatalogStore.Entry) -> some View {
        let isImage = e.category == "image"
        let inUse = isImage ? logoModel == e.id : (settings.modelId == e.id || settings.modelId == e.id.split(separator: "/").last.map(String.init))
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(e.name).font(.callout.weight(.medium)).lineLimit(1)
                    if e.supportsTools == true { badge("Tools") }
                    if e.cheapToday == true { badge("Cheap today", tint: .green) }
                    if e.source == "fal" { badge("fal", tint: .purple) }
                }
                Text(e.id).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                if let b = e.blurb, !b.isEmpty { Text(b).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(price(e)).font(.caption.monospacedDigit())
                if let c = e.contextLength { Text("\(c >= 1_000_000 ? "\(c / 1_000_000)M" : "\(c / 1000)K") context").font(.caption2).foregroundStyle(.secondary) }
            }
            .frame(width: 120, alignment: .trailing)
            if inUse {
                Label("In use", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly).foregroundStyle(.green).frame(width: 74)
            } else if isImage {
                Button("Use") { store.useForImages(e) }.buttonStyle(PressableStyle()).frame(width: 74)
                    .help("Use for logos and images")
            } else {
                Button("Use") { store.useForAssistant(e); settings = LLMProviderSettings.load() }.buttonStyle(PressableStyle()).frame(width: 74)
                    .help(routeHelp(e))
            }
        }
        .padding(.vertical, 2)
    }

    private func badge(_ s: String, tint: Color = .accentColor) -> some View {
        Text(s).font(.system(size: 9, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.15))).foregroundStyle(tint)
    }

    private func price(_ e: ModelCatalogStore.Entry) -> String {
        if let u = e.unitPrice { return u }
        guard let i = e.inputPrice, let o = e.outputPrice else { return "—" }
        if i == 0 && o == 0 { return "Free" }
        func f(_ v: Double) -> String { v < 1 ? String(format: "%.2f", v) : String(format: "%.0f", v) }
        return "$\(f(i)) / $\(f(o)) per M"
    }

    private func routeHelp(_ e: ModelCatalogStore.Entry) -> String {
        let r = store.route(for: e)
        return r.preset == .openrouter ? "Uses your OpenRouter key" : "Uses your \(r.preset.displayName) key directly"
    }

    private var footer: some View {
        HStack {
            Text("From our model catalog (catalog.operatorok.com)\(ImageGen.isReady(.fal) ? " and fal.ai" : "")\(store.updatedAt.map { ", updated " + $0.formatted(.relative(presentation: .named)) } ?? "").")
                .font(.caption).foregroundStyle(.secondary)
            if let e = store.lastError { Text(e).font(.caption).foregroundStyle(.orange).lineLimit(1) }
            Spacer()
            if store.loading { ProgressView().controlSize(.small) }
            Button("Refresh") { Task { await store.refresh() } }.disabled(store.loading)
        }
    }
}
