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
        var docID: String = ""    // the document it was drawn on
    }
    var mark: Mark?

    /// On-device dictation into the composer (shared by the mic chip and the pen).
    let dictation = Dictation(name: "Assistant")
    var voiceProblem: String?

    @ObservationIgnored private var startingListen = false

    func startListening() {
        guard !dictation.isListening, !startingListen else { return }
        startingListen = true
        Task {
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            // Sent (or stopped) while the permission prompt was up: don't start.
            guard startingListen else { return }
            startingListen = false
            dictation.start(from: draft, microphoneAllowed: allowed, current: { [weak self] in self?.draft ?? "" },
                            onText: { [weak self] in self?.draft = $0 },
                            onProblem: { [weak self] in self?.voiceProblem = $0 })
        }
    }

    func toggleListening() {
        if dictation.isListening || startingListen { startingListen = false; dictation.stop() } else { startListening() }
    }

    /// The open document (id, title, page count, current page), read at each request.
    @ObservationIgnored var context: () -> (id: String, title: String, pages: Int, page: Int)? = { nil }
    /// Run before every change the assistant makes (the reader saves pending highlights and moves first).
    @ObservationIgnored var beforeEdit: () -> Void = {}
    @ObservationIgnored let toolbox = AssistantToolbox()
    @ObservationIgnored private var history: [LLMMessage] = []
    @ObservationIgnored private var steering: [String] = []
    @ObservationIgnored private var steerable = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pending: (id: UUID, continuation: CheckedContinuation<Bool, Never>)?
    /// Bumped by Stop and New conversation, so a run that unwinds late doesn't write into the new state.
    @ObservationIgnored private var runID = 0
    /// Messages typed while the on-device model works (it can't be steered): sent when it finishes.
    @ObservationIgnored private var queued: [String] = []

    static let chatRounds = 24
    /// One request may run at most this many tools, for at most this long; then it answers with what it has.
    static let maxToolCalls = 60
    static let maxRunTime: TimeInterval = 10 * 60

    // MARK: Sending

    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // The words are sent: nothing more from the mic goes into the composer.
        startingListen = false
        dictation.cancel()
        if isWorking {
            switch ChatSteering.route(text, isBusy: true) {
            case .stop: stop()
            case .steer, .send:
                guard !text.isEmpty else { return }
                items.append(Item(kind: .user(text)))
                if steerable {
                    steering.append(text)
                    items.append(Item(kind: .tool(title: "Taking that in", detail: "at the next step", ok: true)))
                } else {
                    queued.append(text)
                    items.append(Item(kind: .tool(title: "Next up", detail: "after this step", ok: true)))
                }
            }
            return
        }
        guard !text.isEmpty else { return }
        let doc = context()
        // A mark drawn on another document doesn't belong to this request.
        let mark = self.mark.flatMap { $0.docID.isEmpty || $0.docID == doc?.id ? $0 : nil }
        self.mark = nil
        items.append(Item(kind: .user(mark.map { "\(text)\n✎ marked on page \($0.page)" } ?? text)))
        draft = ""
        isWorking = true
        runID += 1
        let run = runID
        task = Task {
            defer {
                if runID == run {
                    isWorking = false
                    steering = []
                    task = nil
                    // Images were for this request; keep the words, don't resend pictures every round.
                    for i in history.indices where !history[i].images.isEmpty && history[i].toolCallID == nil { history[i].images = [] }
                    if !queued.isEmpty { let next = queued.joined(separator: "\n"); queued = []; send(next) }
                }
            }
            var fastPathFailed = false
            let docLine = doc.map { "The open document is “\($0.title)” (id \($0.id)), \($0.pages) pages; the user is looking at page \($0.page)." }
                ?? "No document is open; ask the user to open one, or use list_documents."
            let route = Route.resolve(modelChoice)
            var onDevice = false
            if case .onDevice = route { onDevice = true }
            var note = ""
            if let mark {
                let r = mark.rect
                note = onDevice
                    // The small model does best with just the words; coordinates tempt it to add things.
                    ? "\n[The user pointed with the pen at these words on page \(mark.page): \"\(mark.text.prefix(300))\". \"this\" means those words.]"
                    : "\n[The user marked an area with the pen on page \(mark.page): box x \(Self.int(r.minX)), y \(Self.int(r.minY)), width \(Self.int(r.width)), height \(Self.int(r.height)) (points from the top-left). Words under the marks: \"\(mark.text.prefix(600))\". Their request is about that spot: for wording use edit_text with those words and pages \"\(mark.page)\"; to add something new, place it in or next to that box. The pen marks are not part of the document.]"
            }
            history.append(LLMMessage(.user, text + note + "\n\n[\(docLine)]", images: onDevice ? [] : (mark?.image.map { [$0] } ?? [])))
            // Pen mark + a short request on the small model: one exact edit, decided by a structured
            // answer (replace / delete / other) instead of an open tool loop.
            if onDevice, let mark, let docID = doc?.id,
               let edit = await AssistantToolbox.markEdit(marked: mark.text, request: text, page: mark.page) {
                guard !Task.isCancelled, runID == run else { return }
                let args: [String: Any] = ["id": docID, "find": edit.find, "replace": edit.replace, "pages": edit.pages, "match_case": true]
                let json = (try? JSONSerialization.data(withJSONObject: args)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                let out = await execute(LLMToolCall(id: UUID().uuidString, name: "edit_text", argumentsJSON: json), docID: docID)
                let reply: String
                if out.text.hasPrefix("The user didn't allow") || Task.isCancelled {
                    reply = Task.isCancelled ? "Stopped." : "Left it as it was."
                } else if out.text.hasPrefix("Error:") {
                    // The words didn't match as one run (or similar): let the assistant work it out.
                    fastPathFailed = true
                    reply = ""
                } else if edit.replace.isEmpty {
                    reply = "Removed “\(edit.find)” on page \(mark.page)."
                } else {
                    reply = "Changed “\(edit.find)” to “\(edit.replace)” on page \(mark.page)."
                        + (out.text.range(of: "Notes: ").map { " " + out.text[$0.upperBound...] } ?? "")
                }
                if !fastPathFailed {
                    items.append(Item(kind: .assistant(reply)))
                    history.append(LLMMessage(.assistant, reply))
                    return
                }
            }
            // Instant commands ("compress it", "undo that", "make it fillable"): a quick decision model picks the
            // tool in a fraction of a second; anything else, or anything it isn't sure of, goes to the language model.
            if mark == nil, let docID = doc?.id, let client = DecisionClient.current,
               let instant = await CommandRouter(toolbox: toolbox, client: client).route(text) {
                guard !Task.isCancelled, runID == run else { return }
                let out = await execute(LLMToolCall(id: UUID().uuidString, name: instant.tool, argumentsJSON: instant.argumentsJSON), docID: docID)
                let reply = out.text.hasPrefix("Error:") ? out.text.replacingOccurrences(of: "Error: ", with: "")
                          : out.text.hasPrefix("The user didn't allow") ? "Left it as it was." : out.text
                items.append(Item(kind: .assistant(reply)))
                history.append(LLMMessage(.assistant, reply))
                return
            }
            do {
                switch route {
                case .onDevice: try await runOnDevice(docID: doc?.id, run: run)
                case .cloud(let settings, let client): try await runCloud(settings: settings, client: client, docID: doc?.id, run: run)
                }
                if Task.isCancelled, runID == run { items.append(Item(kind: .error("Stopped."))) }
            } catch {
                guard runID == run else { return }
                if Task.isCancelled || error is CancellationError { items.append(Item(kind: .error("Stopped."))); return }
                items.append(Item(kind: .error(error.localizedDescription)))
                // Keep the mark so the user can try again without drawing it again.
                if self.mark == nil, let mark { self.mark = mark }
            }
        }
    }

    func isCurrent(_ run: Int) -> Bool { runID == run }

    /// The assistant's instructions with what it remembers about the person (Settings › Assistant › Memory).
    static func withMemory(_ instructions: String, limit: Int) -> String {
        let memory = EzPDF.shared.memorySummary(limit: limit)
        return memory.isEmpty ? instructions : instructions + "\n\n" + memory
    }

    /// Int for prompt text, safe with infinite or NaN values.
    static func int(_ v: CGFloat) -> Int { v.isFinite ? Int(max(-1e6, min(1e6, v))) : 0 }

    func stop() {
        steering = []
        queued = []
        startingListen = false
        dictation.cancel()
        task?.cancel()
        task = nil
        resolve(allow: false)
        if isWorking {
            // The run unwinds on its own; from here on it can't write into the chat.
            runID += 1
            isWorking = false
            items.append(Item(kind: .error("Stopped.")))
        }
    }

    func clear() {
        stop()
        items = []
        history = []
        mark = nil
        draft = ""
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

    private func runCloud(settings: LLMProviderSettings, client: any LLMToolClient, docID: String?, run: Int) async throws {
        steerable = true
        defer { steerable = false }
        let specs = toolbox.specs.map { LLMToolSpec(name: $0.name, description: $0.description, parametersJSON: $0.schemaJSON) }
        let model = settings.modelId.isEmpty ? settings.preset.defaultModelId : settings.modelId
        var replyIndex: Int?
        var progress: [LLMMessage] = []
        let started = Date()
        var toolCalls = 0
        let outcome: AgentLoop.Outcome
        do {
        outcome = try await AgentLoop.run(
            messages: [LLMMessage(.system, Self.withMemory(AssistantToolbox.instructions, limit: 1500))] + history,
            tools: specs,
            maxRounds: Self.chatRounds,
            round: { messages, tools in client.streamWithTools(messages: messages, model: model, tools: tools) },
            executeOutput: { [weak self] call in
                guard let self, runID == run else { return LLMToolOutput("Stopped by the user.") }
                return await execute(call, docID: docID)
            },
            parallelSafe: { [toolbox] call in toolbox.isReadOnly(call.name, argumentsJSON: call.argumentsJSON) },
            outOfBudget: { toolCalls >= Self.maxToolCalls || Date().timeIntervalSince(started) > Self.maxRunTime },
            steer: { [weak self] in
                guard let self, runID == run, !steering.isEmpty else { return [] }
                defer { steering = [] }
                replyIndex = nil
                return steering
            },
            onText: { [weak self] delta in
                guard let self, runID == run else { return }
                if let i = replyIndex, i < items.count, case .assistant(let t) = items[i].kind {
                    items[i].kind = .assistant(t + delta)
                } else {
                    items.append(Item(kind: .assistant(delta)))
                    replyIndex = items.count - 1
                }
            },
            onToolCall: { _ in replyIndex = nil; toolCalls += 1 },
            onAppended: { progress.append($0) })
        } catch {
            // Keep the steps that already ran (and changed the document), so "continue" doesn't redo them.
            if runID == run, !progress.isEmpty {
                history += progress
                history = Self.trimmed(history)
            }
            throw error
        }
        // Stopped or cleared meanwhile: the stream ended quietly, but nothing of this run belongs anymore.
        guard runID == run, !Task.isCancelled else { return }
        if outcome.hitBudget {
            items.append(Item(kind: .assistant("I stopped at my step limit. Say “continue” to keep going.")))
        }
        history += outcome.appended
        if let i = replyIndex, i < items.count, case .assistant(let t) = items[i].kind { history.append(LLMMessage(.assistant, t)) }
        history = Self.trimmed(history)
    }

    /// Past ~120k characters, older tool results are cut to their opening so every call keeps its result.
    static func trimmed(_ history: [LLMMessage], limit: Int = 120_000, keepRecent: Int = 12) -> [LLMMessage] {
        var total = history.reduce(0) { $0 + $1.content.count + $1.images.count * 20_000 }
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

    private func runOnDevice(docID: String?, run: Int) async throws {
        guard OnDeviceLLM.isAvailable else {
            throw EzPDFError.unavailable("Turn on Apple Intelligence, or add an API key in Settings › Assistant.")
        }
        // The small model gets the flat tools that matter most for editing.
        let wanted = AssistantToolbox.onDeviceTools
        let specs = wanted.compactMap { toolbox.spec(named: $0) }.filter(\.flat).map {
            LLMToolSpec(name: $0.name, description: $0.description, parametersJSON: $0.schemaJSON)
        }
        let readOnlyNames = Set(toolbox.specs.filter(\.readOnly).map(\.name))   // the on-device tools have no list modes
        let tools = OnDeviceToolBridge.tools(specs) { [weak self] call in
            guard let self, await self.isCurrent(run) else { return "Stopped by the user." }
            let out = await self.execute(call, docID: docID, clip: 1500).text
            // The small model tends to keep calling tools after a change; tell it it's done.
            let readOnly = readOnlyNames.contains(call.name)
            return readOnly || out.hasPrefix("Error:") ? out : out + " Done. Now reply to the user in one sentence; don't call more tools unless they asked for more."
        }
        // The small model's window is ~4k tokens: only what was said (no tool results, no empty
        // tool-call turns from a cloud model), each clipped, the latest request in full.
        let said = history.filter { ($0.role == .user || $0.role == .assistant) && $0.toolCalls.isEmpty && $0.toolCallID == nil && !$0.content.isEmpty }
        let lines = said.suffix(6).enumerated().map { i, m -> String in
            let isLast = i == min(6, said.count) - 1
            let body = isLast ? String(m.content.prefix(2400)) : String(m.content.prefix(300))
            return "\(m.role == .user ? "User" : "Assistant"): \(body)"
        }
        let conversation = lines.joined(separator: "\n")
        var reply = ""
        var replyID: UUID?
        // The small model's window is small: a short memory.
        for try await delta in OnDeviceLLM(instructions: Self.withMemory(AssistantToolbox.compactInstructions, limit: 400)).streamText(prompt: conversation, tools: tools) {
            guard runID == run else { return }
            reply += delta
            if let replyID, let i = items.firstIndex(where: { $0.id == replyID }) { items[i].kind = .assistant(reply) }
            else { let item = Item(kind: .assistant(reply)); items.append(item); replyID = item.id }
        }
        guard runID == run, !Task.isCancelled else { return }
        history.append(LLMMessage(.assistant, reply))
    }

    // MARK: Tools

    private func execute(_ call: LLMToolCall, docID: String?, clip: Int = 12_000) async -> LLMToolOutput {
        guard let spec = toolbox.spec(named: call.name) else { return LLMToolOutput("Unknown tool \(call.name).") }
        let readOnly = toolbox.isReadOnly(call.name, argumentsJSON: call.argumentsJSON)
        // After Stop nothing more changes the document, even with Auto-apply on.
        if !readOnly, Task.isCancelled { return LLMToolOutput("Stopped by the user.") }
        var rowID: UUID?
        if !readOnly, !applyWithoutAsking || spec.name == "manage_document" && call.argumentsJSON.contains("delete") {
            // Say which document it changes: the user may have switched documents since asking.
            let target = toolbox.documentTitle(argumentsJSON: call.argumentsJSON, currentDocument: docID).map { "\nDocument: \($0)" } ?? ""
            let (allowed, cardID) = await confirm(title: spec.title, preview: toolbox.describe(call.name, argumentsJSON: call.argumentsJSON) + target)
            guard allowed, !Task.isCancelled else { return LLMToolOutput("The user didn't allow \(spec.title.lowercased()). Ask what they'd like instead.") }
            rowID = cardID       // the card turned into this call's row
        }
        if rowID == nil {
            let row = Item(kind: .tool(title: spec.title, detail: nil, ok: nil))
            items.append(row); rowID = row.id
        }
        if !readOnly { beforeEdit() }
        let result = await toolbox.call(call.name, argumentsJSON: call.argumentsJSON, currentDocument: docID)
        let detail = result.ok ? (readOnly ? nil : String(result.text.prefix(160))) : result.text
        if let rowID, let i = items.firstIndex(where: { $0.id == rowID }) {
            items[i].kind = .tool(title: spec.title, detail: detail, ok: result.ok)
        }
        let text = result.text.count > clip ? String(result.text.prefix(clip)) + "\n[clipped]" : result.text
        return LLMToolOutput(result.ok ? text : "Error: " + text)
    }

    private func confirm(title: String, preview: String) async -> (Bool, UUID?) {
        while pending != nil {
            guard !Task.isCancelled else { return (false, nil) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !Task.isCancelled else { return (false, nil) }
        let item = Item(kind: .confirm(title: title, preview: preview))
        items.append(item)
        let ok = await withCheckedContinuation { c in pending = (item.id, c) }
        return (ok, item.id)
    }
}
