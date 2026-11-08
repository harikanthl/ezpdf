//
//  AssistantSettings.swift
//  ezpdf (adapted from the "Assistant model" section of ezRecord's Settings/AISettingsView.swift)
//
//  Which model the assistant uses: Apple Intelligence (free, private) or a provider with your own
//  key, stored in the Keychain.
//

import SwiftUI
import OperatorLLM

struct AssistantSettings: View {
    @State private var settings = LLMProviderSettings.load()
    @State private var key = ""
    @State private var hasKey = false
    @State private var saveFailure: String?
    @State private var testing = false
    @State private var test: String?

    private let presets: [LLMProviderPreset] = [.onDevice, .anthropic, .openai, .gemini, .xai, .openrouter, .custom]

    var body: some View {
        Form {
            Section {
                Picker("Model", selection: $settings.preset) {
                    ForEach(presets) { Text($0.displayName).tag($0) }
                }
                if settings.preset == .onDevice {
                    Text(OnDeviceLLM.availabilityMessage ?? "Free and private: nothing leaves this Mac. It's small, so it handles one-step edits best; add a key for longer requests.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    if settings.preset == .custom {
                        TextField("Server URL", text: $settings.baseURL, prompt: Text("http://127.0.0.1:11434/v1"))
                    }
                    LabeledContent("API key") {
                        HStack {
                            SecureField(hasKey ? "Saved in the Keychain" : settings.preset.keyHint, text: $key)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(saveKey)
                            Button("Save", action: saveKey).disabled(key.isEmpty)
                            if hasKey, let account = settings.preset.keychainAccount {
                                Button("Remove") { KeychainService.delete(account); refreshKey(); LLMProviderSettings.announceChange() }
                            }
                            if let saveFailure {
                                Label("Not saved", systemImage: "xmark.circle.fill").foregroundStyle(.red).help(saveFailure).font(.caption)
                            } else if hasKey {
                                Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                            }
                        }
                    }
                    if let link = settings.preset.getKeyURL.flatMap(URL.init(string:)) {
                        Link("Get a key", destination: link).font(.caption)
                    }
                    LabeledContent("Model id") {
                        HStack {
                            TextField("", text: $settings.modelId, prompt: Text(settings.preset.defaultModelId.isEmpty ? "model id" : settings.preset.defaultModelId))
                                .textFieldStyle(.roundedBorder)
                            let options = LLMModelCatalog.options(loaded: [], preset: settings.preset)
                            if !options.isEmpty {
                                Menu("") { ForEach(options) { o in Button(o.label) { settings.modelId = o.id } } }
                                    .menuStyle(.borderlessButton).fixedSize()
                            }
                        }
                    }
                    HStack {
                        Button("Test") { Task { await runTest() } }.disabled(testing || (!hasKey && settings.preset.requiresAPIKey))
                        if testing { ProgressView().controlSize(.small) }
                        if let test { Text(test).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                }
            } footer: {
                Text("The assistant edits your PDFs with the same tools AI agents use. With a cloud model, the text it reads from your document is sent to that provider. Keys stay in your Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ImageKeysSection()
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshKey)
        .onChange(of: settings.preset) { settings.modelId = ""; refreshKey(); test = nil }
        .onChange(of: settings) { settings.save() }
    }

    private func refreshKey() {
        key = ""
        saveFailure = nil
        hasKey = settings.preset.keychainAccount.map { KeychainService.has($0) } ?? false
    }

    private func saveKey() {
        guard let account = settings.preset.keychainAccount, !key.isEmpty else { return }
        let status = KeychainService.store(key.trimmingCharacters(in: .whitespacesAndNewlines), for: account)
        refreshKey()
        saveFailure = status == errSecSuccess ? nil : KeychainService.describe(status)
        test = nil
        LLMProviderSettings.announceChange()
    }

    private func runTest() async {
        testing = true
        defer { testing = false }
        settings.save()
        guard case let .cloud(current, client) = AssistantModel.Route.resolve() else { test = "Using Apple Intelligence."; return }
        do {
            let model = current.modelId.isEmpty ? current.preset.fastModelId : current.modelId
            let reply = try await client.complete(messages: [LLMMessage(.user, "Reply with the single word: ready")], model: model)
            test = "Works: \(reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))"
        } catch {
            test = error.localizedDescription
        }
    }
}
