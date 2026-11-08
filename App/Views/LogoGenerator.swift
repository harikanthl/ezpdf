import SwiftUI
import EzPDFCore

/// Describe a logo (or stamp, seal, picture), pick one of the results, and it lands on the page as
/// an object you can drag and resize.
struct LogoGeneratorSheet: View {
    var onPlace: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @AppStorage("ezpdf.settingsTab") private var settingsTab = "general"
    @AppStorage("ezpdf.logoModel") private var modelID = "apple"
    @State private var prompt = ""
    @State private var style: ImageGen.Style = .minimal
    @State private var results: [Data] = []
    @State private var picked: Int?
    @State private var cutOut = true
    @State private var working = false
    @State private var error: String?
    @State private var job: Task<Void, Never>?
    @State private var images: [NSImage] = []      // decoded once, not on every redraw
    @State private var ready: [ImageGen.Provider: Bool] = [:]

    private var model: ImageGen.Model { ImageGen.model(id: modelID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Generate a Logo or Image", systemImage: "wand.and.stars").font(.headline)
            TextField("Describe it: “Bean There coffee, a bean with a map pin”", text: $prompt, axis: .vertical)
                .lineLimit(1...3).textFieldStyle(.roundedBorder).frame(width: 520)
                .onSubmit(generate)
            HStack(spacing: 6) {
                ForEach(ImageGen.Style.allCases) { s in
                    Button(s.rawValue) { style = s }.buttonStyle(ChipStyle(isOn: style == s))
                }
            }
            HStack {
                Picker("Model", selection: $modelID) {
                    ForEach(ImageGen.allModels) { m in
                        Text(m.name + (ready[m.provider, default: true] ? "" : " (add key)")).tag(m.id)
                    }
                }
                .frame(width: 260)
                Text(model.note).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("More Models…") { settingsTab = "models"; openSettings() }.buttonStyle(PressableStyle())
            }
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.35))
                if working {
                    VStack(spacing: 8) {
                        ProgressView(); Text("Making images…").font(.caption).foregroundStyle(.secondary)
                        Button("Stop") { job?.cancel() }.buttonStyle(PressableStyle())
                    }
                } else if let error {
                    Text(error).font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center).padding()
                } else if results.isEmpty {
                    Text("Your options appear here.").font(.callout).foregroundStyle(.tertiary)
                } else {
                    HStack(spacing: 12) {
                        ForEach(Array(images.enumerated()), id: \.offset) { i, img in
                            Group {
                                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                                    .frame(width: 150, height: 150)
                                    .padding(6)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(picked == i ? Color.accentColor : .clear, lineWidth: 2.5))
                                    // Double first, so a double click isn't eaten by the single tap.
                                    .onTapGesture(count: 2) { picked = i; place() }
                                    .onTapGesture { picked = i }
                            }
                        }
                    }
                    .padding(10)
                }
            }
            .frame(width: 520, height: 190)
            Toggle("Remove the background (keeps just the logo)", isOn: $cutOut)
            HStack {
                Text(model.provider == .apple ? "Made on this Mac." : "Your description is sent to \(model.provider.displayName).")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(PressableStyle()).keyboardShortcut(.cancelAction)
                Button(results.isEmpty ? "Generate" : "Again") { generate() }.buttonStyle(PressableStyle()).disabled(trimmedPrompt.isEmpty || working)
                Button("Place on Page") { place() }.buttonStyle(PressableStyle(prominent: true)).keyboardShortcut(.defaultAction)
                    .disabled(picked == nil || working)
            }
        }
        .padding(18)
        .onAppear {
            ImageGen.refreshKeyState()
            ready = Dictionary(uniqueKeysWithValues: ImageGen.Provider.allCases.map { ($0, ImageGen.isReady($0)) })
            if ImageGen.savedModel(id: modelID) == nil, modelID != "apple" {
                error = "The model you picked before isn't available anymore; using \(model.name)."
            }
        }
        .onDisappear { job?.cancel() }      // closing the sheet stops (and cancels) the remote job
    }

    private var trimmedPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func generate() {
        guard !trimmedPrompt.isEmpty, !working else { return }
        working = true; error = nil; picked = nil
        let m = model, p = ImageGen.prompt(trimmedPrompt, style: style)
        job = Task {
            defer { working = false }
            do {
                let out = try await ImageGen.generate(prompt: p, model: m, count: m.provider == .apple ? 2 : 3)
                guard !Task.isCancelled else { return }
                results = out
                images = out.compactMap(NSImage.init(data:))
                picked = images.isEmpty ? nil : 0
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    private func place() {
        guard let picked, picked < results.count, !working else { return }
        let data = results[picked], lettering = style.isLettering, cut = cutOut
        working = true
        job = Task {
            defer { working = false }
            let out = cut ? ((try? await ImageGen.removeBackground(data, lettering: lettering)) ?? data) : data
            guard !Task.isCancelled else { return }
            onPlace(out)
            dismiss()
        }
    }
}

/// API keys for image generation (Settings → Assistant).
struct ImageKeysSection: View {
    @State private var falKey = ""
    @State private var openAIKey = ""
    @State private var hasFal = ImageGen.isReady(.fal)
    @State private var hasOpenAI = ImageGen.isReady(.openai)
    @State private var keyError: String?

    var body: some View {
        Section {
            keyRow("fal.ai key", text: $falKey, saved: $hasFal, provider: .fal)
            keyRow("OpenAI key", text: $openAIKey, saved: $hasOpenAI, provider: .openai)
        } header: {
            Text("Images and logos")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let keyError { Text(keyError).font(.caption).foregroundStyle(.orange) }
                Text("Apple Image Playground works without a key. fal.ai and OpenAI keys stay in your Keychain.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func keyRow(_ title: String, text: Binding<String>, saved: Binding<Bool>, provider: ImageGen.Provider) -> some View {
        LabeledContent(title) {
            HStack {
                SecureField(saved.wrappedValue ? "Saved in the Keychain" : "Paste key", text: text).textFieldStyle(.roundedBorder)
                Button("Save") {
                    let status = ImageGen.setKey(text.wrappedValue, for: provider)
                    text.wrappedValue = ""
                    saved.wrappedValue = ImageGen.isReady(provider)
                    keyError = status == errSecSuccess ? nil : "Couldn't save to the Keychain (error \(status))."
                }.disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if saved.wrappedValue {
                    Button("Remove") { ImageGen.setKey(nil, for: provider); saved.wrappedValue = false }
                    Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                }
                if let u = provider.keyURL { Link("Get a key", destination: u).font(.caption) }
            }
        }
    }
}
