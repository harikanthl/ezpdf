//
//  AssistantModel.swift
//  ezpdf (adapted from ezRecord's Agents/ChatModel.swift)
//
//  The in-app assistant: "change the date to Nov 7 and sign it as Hari". It uses the same tools as
//  outside agents (AssistantToolbox → MCPTools), through OperatorLLM:
//  - Cloud (Anthropic, OpenAI, xAI Grok, Gemini, OpenRouter, Ollama…, keys in the Keychain): AgentLoop
//    with the full tool list, streaming text and tool calls.
//  - On-device (Apple Intelligence, free and private): Foundation Models' own tool loop with the tools
//    whose arguments it can fill (flat ones), since its window is small.
//  Changes wait for Apply on a card unless the user turned on "Apply without asking". Every change
//  goes through EzPDF's undoable commit.
//  Text read from the document is data: the instructions tell the model never to follow it.
//

import Foundation
import AVFoundation
import Observation
import OperatorLLM
import EzPDFCore

@MainActor
@Observable
final class AssistantModel {
    struct Item: Identifiable {
        enum Kind {
            case user(String)
            case assistant(String)
            case tool(title: String, detail: String?, ok: Bool?)
            case confirm(title: String, preview: String)
            case error(String)
        }
        let id = UUID()
        var kind: Kind
    }

    private(set) var items: [Item] = []
    private(set) var isWorking = false
    var applyWithoutAsking = false
    var draft = ""
    /// The model this chat asks; nil follows Settings › Assistant.
    var modelChoice: ModelChoice?

    /// An area the user marked with the pen (Mark & Talk): sent with the next message.
    struct Mark: Equatable {
        var page: Int
        var rect: CGRect          // points, top-left of the page
        var text: String          // the document's words under the marks
        var image: Data?          // the area with the marks drawn on it (for models that see images)
    }
    var mark: Mark?

    /// On-device dictation into the composer (shared by the mic chip and the pen).
    let dictation = Dictation(name: "Assistant")
    var voiceProblem: String?

    func startListening() {
        guard !dictation.isListening else { return }
        Task {
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            dictation.start(from: draft, microphoneAllowed: allowed,
                            onText: { [weak self] in self?.draft = $0 },
                            onProblem: { [weak self] in self?.voiceProblem = $0 })
        }
    }

    func toggleListening() {
        if dictation.isListening { dictation.stop() } else { startListening() }
    }

    /// The open document (id, title, page count, current page), read at each request.
    @ObservationIgnored var context: () -> (id: String, title: String, pages: Int, page: Int)? = { nil }
    @ObservationIgnored let toolbox = AssistantToolbox()
    @ObservationIgnored private var history: [LLMMessage] = []
    @ObservationIgnored private var steering: [String] = []
    @ObservationIgnored private var steerable = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pending: (id: UUID, continuation: CheckedContinuation<Bool, Never>)?

    static let chatRounds = 24

    // MARK: Sending

    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if isWorking {
            switch ChatSteering.route(text, isBusy: true) {
            case .stop: stop()
            case .steer:
                items.append(Item(kind: .user(text)))
                if steerable {
                    steering.append(text)
                    items.append(Item(kind: .tool(title: "Taking that in", detail: "at the next step", ok: true)))
                }
            case .send: break
            }
            return
        }
        guard !text.isEmpty else { return }
        let mark = self.mark
        self.mark = nil
        if dictation.isListening { dictation.stop() }
        items.append(Item(kind: .user(mark.map { "\(text)\n✎ marked on page \($0.page)" } ?? text)))
        draft = ""
        isWorking = true
        task = Task {
            defer { isWorking = false }
            let doc = context()
            let docLine = doc.map { "The open document is “\($0.title)” (id \($0.id)), \($0.pages) pages; the user is looking at page \($0.page)." }
                ?? "No document is open; ask the user to open one, or use list_documents."
            var note = ""
            if let mark {
                let r = mark.rect
                note = "\n[The user marked an area with the pen on page \(mark.page): box x \(Int(r.minX)), y \(Int(r.minY)), width \(Int(r.width)), height \(Int(r.height)) (points from the top-left). Words under the marks: \"\(mark.text.prefix(600))\". Their request is about that spot; act on it (for wording, edit_text with those words; for new things, place them in or next to that box). The pen marks are not part of the document.]"
            }
            history.append(LLMMessage(.user, text + note + "\n\n[\(docLine)]", images: mark?.image.map { [$0] } ?? []))
            do {
                switch Route.resolve(modelChoice) {
                case .onDevice: try await runOnDevice(docID: doc?.id)
                case .cloud(let settings, let client): try await runCloud(settings: settings, client: client, docID: doc?.id)
                }
            } catch is CancellationError {
                items.append(Item(kind: .error("Stopped.")))
            } catch {
                if Task.isCancelled { items.append(Item(kind: .error("Stopped."))); return }
                items.append(Item(kind: .error(error.localizedDescription)))
            }
        }
    }

    func stop() {
        steering = []
        task?.cancel()
        resolve(allow: false)
    }

    func clear() {
        stop()
        items = []
        history = []
    }

    /// The user's answer to a confirmation card.
    func resolve(allow: Bool) {
        guard let pending else { return }
        self.pending = nil
        if let i = items.firstIndex(where: { $0.id == pending.id }), case .confirm(let title, _) = items[i].kind {
            items[i].kind = .tool(title: title, detail: allow ? "Applying…" : "Not applied", ok: allow ? nil : false)
        }
        pending.continuation.resume(returning: allow)
    }

    var isWaitingForUser: Bool { pending != nil }

    // MARK: Routes

    struct ModelChoice: Hashable, Identifiable {
        var preset: LLMProviderPreset
        var modelId: String
        var title: String
        var id: String { "\(preset.rawValue)/\(modelId)" }
        static let onDevice = ModelChoice(preset: .onDevice, modelId: "", title: "Apple Intelligence")

        /// Apple Intelligence when it's on, and the leading models of every provider with a saved key.
        static func available() -> [ModelChoice] {
            var choices = OnDeviceLLM.isAvailable ? [onDevice] : []
            for preset in [LLMProviderPreset.anthropic, .openai, .gemini, .xai, .openrouter] {
                guard let account = preset.keychainAccount, KeychainService.has(account) else { continue }
                let prefix = preset == .anthropic ? "Claude " : preset == .openrouter ? "OpenRouter · " : ""
                choices += preset.modelSuggestions.prefix(3).map { ModelChoice(preset: preset, modelId: $0.id, title: prefix + $0.label) }
            }
            return choices
        }
    }

    var modelTitle: String {
        if let modelChoice { return modelChoice.title }
        switch Route.resolve() {
        case .onDevice: return ModelChoice.onDevice.title
        case .cloud(let settings, _):
            let id = settings.effectiveModelId
            return settings.preset.modelSuggestions.first { $0.id == id }.map { (settings.preset == .anthropic ? "Claude " : "") + $0.label } ?? id
        }
    }

    enum Route {
        case onDevice
        case cloud(LLMProviderSettings, any LLMToolClient)

        static func resolve(_ choice: ModelChoice? = nil) -> Route {
            var settings = LLMProviderSettings.load()
            if let choice {
                guard choice.preset != .onDevice else { return .onDevice }
                settings.preset = choice.preset
                settings.modelId = choice.modelId
            }
            guard settings.preset != .onDevice else { return .onDevice }
            let key = settings.preset.keychainAccount.flatMap { KeychainService.get($0) }
            if settings.preset.requiresAPIKey, key?.isEmpty != false { return .onDevice }
            if settings.preset == .anthropic { return .cloud(settings, AnthropicMessagesClient(apiKey: key ?? "")) }
            return .cloud(settings, OpenAICompatibleClient(baseURL: settings.effectiveBaseURL, apiKey: key,
                                                           referer: "https://github.com/harikanthl/ezpdf", appTitle: "ezpdf",
                                                           reasoningEffort: settings.preset.defaultReasoningEffort))
        }
    }

    // MARK: Cloud

    private func runCloud(settings: LLMProviderSettings, client: any LLMToolClient, docID: String?) async throws {
        steerable = true
        defer { steerable = false }
        let specs = toolbox.specs.map { LLMToolSpec(name: $0.name, description: $0.description, parametersJSON: $0.schemaJSON) }
        let model = settings.modelId.isEmpty ? settings.preset.defaultModelId : settings.modelId
        var replyIndex: Int?
        let outcome = try await AgentLoop.run(
            messages: [LLMMessage(.system, AssistantToolbox.instructions)] + history,
            tools: specs,
            maxRounds: Self.chatRounds,
            round: { messages, tools in client.streamWithTools(messages: messages, model: model, tools: tools) },
            executeOutput: { [weak self] call in await self?.execute(call, docID: docID) ?? LLMToolOutput("The chat closed.") },
            parallelSafe: { [toolbox] call in toolbox.spec(named: call.name)?.readOnly == true },
            outOfBudget: { false },
            steer: { [weak self] in
                guard let self, !steering.isEmpty else { return [] }
                defer { steering = [] }
                replyIndex = nil
                return steering
            },
            onText: { [weak self] delta in
                guard let self else { return }
                if let i = replyIndex, i < items.count, case .assistant(let t) = items[i].kind {
                    items[i].kind = .assistant(t + delta)
                } else {
                    items.append(Item(kind: .assistant(delta)))
                    replyIndex = items.count - 1
                }
            },
            onToolCall: { _ in replyIndex = nil })
        if outcome.hitBudget {
            items.append(Item(kind: .assistant("I stopped at my step limit. Say “continue” to keep going.")))
        }
        history += outcome.appended
        if let i = replyIndex, case .assistant(let t) = items[i].kind { history.append(LLMMessage(.assistant, t)) }
        history = Self.trimmed(history)
    }

    /// Past ~120k characters, older tool results are cut to their opening so every call keeps its result.
    static func trimmed(_ history: [LLMMessage], limit: Int = 120_000, keepRecent: Int = 12) -> [LLMMessage] {
        var total = history.reduce(0) { $0 + $1.content.count }
        guard total > limit else { return history }
        var result = history
        for i in result.indices.dropLast(keepRecent) where result[i].toolCallID != nil && result[i].content.count > 400 {
            total -= result[i].content.count - 400
            result[i].content = String(result[i].content.prefix(400)) + " … [older result trimmed]"
            if total <= limit { break }
        }
        return result
    }

    // MARK: On device

    private func runOnDevice(docID: String?) async throws {
        guard OnDeviceLLM.isAvailable else {
            throw EzPDFError.unavailable("Turn on Apple Intelligence, or add an API key in Settings › Assistant.")
        }
        // The small model gets the flat tools that matter most for editing.
        let wanted = AssistantToolbox.onDeviceTools
        let specs = wanted.compactMap { toolbox.spec(named: $0) }.filter(\.flat).map {
            LLMToolSpec(name: $0.name, description: $0.description, parametersJSON: $0.schemaJSON)
        }
        let tools = OnDeviceToolBridge.tools(specs) { [weak self] call in
            await self?.execute(call, docID: docID, clip: 1500).text ?? "The chat closed."
        }
        let conversation = history.suffix(6).map { "\($0.role == .user ? "User" : "Assistant"): \($0.content)" }.joined(separator: "\n")
        var reply = ""
        var index: Int?
        for try await delta in OnDeviceLLM(instructions: AssistantToolbox.compactInstructions).streamText(prompt: conversation, tools: tools) {
            reply += delta
            if let index, index < items.count { items[index].kind = .assistant(reply) }
            else { items.append(Item(kind: .assistant(reply))); index = items.count - 1 }
        }
        history.append(LLMMessage(.assistant, reply))
    }

    // MARK: Tools

    private func execute(_ call: LLMToolCall, docID: String?, clip: Int = 12_000) async -> LLMToolOutput {
        guard let spec = toolbox.spec(named: call.name) else { return LLMToolOutput("Unknown tool \(call.name).") }
        if !spec.readOnly, !applyWithoutAsking || spec.name == "manage_document" && call.argumentsJSON.contains("delete") {
            let allowed = await confirm(title: spec.title, preview: toolbox.describe(call.name, argumentsJSON: call.argumentsJSON))
            guard allowed else { return LLMToolOutput("The user didn't allow \(spec.title.lowercased()). Ask what they'd like instead.") }
        }
        let index = items.count
        if spec.readOnly || applyWithoutAsking { items.append(Item(kind: .tool(title: spec.title, detail: nil, ok: nil))) }
        let result = await toolbox.call(call.name, argumentsJSON: call.argumentsJSON, currentDocument: docID)
        let detail = result.ok ? (spec.readOnly ? nil : String(result.text.prefix(160))) : result.text
        if index < items.count, case .tool = items[index].kind {
            items[index].kind = .tool(title: spec.title, detail: detail, ok: result.ok)
        } else if let last = items.lastIndex(where: { if case .tool(let t, _, nil) = $0.kind { t == spec.title } else { false } }) {
            items[last].kind = .tool(title: spec.title, detail: detail, ok: result.ok)
        }
        let text = result.text.count > clip ? String(result.text.prefix(clip)) + "\n[clipped]" : result.text
        return LLMToolOutput(result.ok ? text : "Error: " + text)
    }

    private func confirm(title: String, preview: String) async -> Bool {
        while pending != nil {
            guard !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !Task.isCancelled else { return false }
        let item = Item(kind: .confirm(title: title, preview: preview))
        items.append(item)
        return await withCheckedContinuation { c in pending = (item.id, c) }
    }
}
