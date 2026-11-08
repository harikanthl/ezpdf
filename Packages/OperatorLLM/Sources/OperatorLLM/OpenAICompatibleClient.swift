//
//  OpenAICompatibleClient.swift
//  OperatorLLM
//
//  One client for every OpenAI-compatible gateway: OpenAI, Anthropic (via its
//  OpenAI-compat endpoint, api.anthropic.com/v1), Gemini (OpenAI-compat), or any
//  custom base URL. Streams `POST {baseURL}/chat/completions` Server-Sent Events.
//
//  Lifted from MuseDrop's OpenAICompatibleLLMClient.swift; made public. The
//  MuseDrop `TokenMeterService` dependency is stripped and replaced with an
//  optional `onUsage` callback so this package stays UI/telemetry free.
//

import Foundation
#if canImport(FoundationNetworking)
// Linux keeps URLSession in its own module. This package became part of the LINUX build on
// 2026-09-04, when OperatorCore took an edge to it (31e6784) — see `KeychainService.swift`'s header.
import FoundationNetworking
#endif

// `Usage` MOVED to LLMTools.swift on 2026-09-11 — it is vocabulary (five Ints and a ratio), it is
// referenced by `LLMStreamEvent` and `AgentLoop` which are vocabulary too, and this file is excluded
// from the Linux build (Package.swift). A shared type living inside an excluded file took the whole
// package down with it. Behaviour unchanged; same module, same name, same members.

public struct OpenAICompatibleClient: LLMToolClient {
    public let baseURL: String
    public let apiKey: String?
    /// Optional attribution headers (OpenRouter-style gateways rank apps by these;
    /// ignored elsewhere).
    public var referer: String
    public var appTitle: String
    /// Thinking/reasoning budget hint (OpenAI `reasoning_effort`: "none"|"low"|
    /// "medium"|"high"). Thinking tokens bill as OUTPUT and dominate latency on
    /// some Gemini Flash models. Set "none"/"low" to cut cost + time. nil ⇒
    /// provider default. Ignored by gateways that don't support it.
    public var reasoningEffort: String?
    /// Output ceiling for one reply. Covers thinking AND visible text on thinking-capable models, so
    /// it must leave room for both — see the note at the `max_tokens` payload key. A ceiling is not a
    /// spend: unused headroom is free, so this is generous by default.
    public var maxTokens: Int
    /// Best-effort callback invoked once with real token spend when the gateway
    /// appends a usage chunk. Replaces MuseDrop's TokenMeterService. nil ⇒ no
    /// metering. Called from the streaming task; keep it lightweight and Sendable.
    public var onUsage: (@Sendable (Usage) -> Void)?

    public init(baseURL: String,
                apiKey: String?,
                referer: String = "https://operator.app",
                appTitle: String = "Operator",
                reasoningEffort: String? = nil,
                maxTokens: Int = 16_384,
                onUsage: (@Sendable (Usage) -> Void)? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.referer = referer
        self.appTitle = appTitle
        self.reasoningEffort = reasoningEffort
        self.maxTokens = maxTokens
        self.onUsage = onUsage
    }

    /// Internal, not private, so the header rules below can be pinned by a test without a network.
    func makeRequest(messages: [LLMMessage], model: String,
                     responseFormat: [String: Any]? = nil,
                     tools: [LLMToolSpec] = []) throws -> URLRequest {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedBase.isEmpty, let url = URL(string: trimmedBase + "/chat/completions") else {
            throw LLMError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            // Anthropic's second credential shape. `LLMModelCatalog.makeRequest` has known this since
            // the model list existed; the chat client did not, so a subscription token (`sk-ant-oat…`,
            // from `ant auth login` or a Claude plan) went out as a plain Bearer, which the API reads as
            // a console key and refuses with "Invalid Anthropic API Key" — before any model is looked
            // at. Probed 2026-09-05 against the OpenAI-compatible endpoint: with this header the same
            // token is judged AS an OAuth token ("OAuth access token is invalid" for a bogus one), which
            // is the shape a real one needs. Keyed on the prefix, not the base URL: only Anthropic mints
            // it, and every other gateway ignores a header it does not know.
            if apiKey.hasPrefix("sk-ant-oat") {
                request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            }
        }
        // OpenRouter-style attribution (ignored by other gateways).
        request.setValue(referer, forHTTPHeaderField: "HTTP-Referer")
        request.setValue(appTitle, forHTTPHeaderField: "X-Title")

        var payload: [String: Any] = [
            "model": model,
            "stream": true,
            // REQUIRED in practice, not optional. Anthropic's Messages API mandates `max_tokens`, and
            // its OpenAI-compat layer substitutes a small default when we omit it. On a model that
            // thinks by default (Opus 5, Sonnet 5, Fable 5) that budget covers thinking AND visible
            // text, so reasoning consumes it and the reply comes back empty or truncated — while a
            // non-thinking model like Haiku 4.5 answers fine. That asymmetry is the bug this fixes.
            // A ceiling costs nothing unspent, so it is set generously rather than tuned.
            "max_tokens": maxTokens,
            // Ask the gateway to append a final usage chunk so we can meter real token
            // spend (OpenAI-compat standard; ignored by gateways that don't support it).
            "stream_options": ["include_usage": true],
            "messages": Self.encodeMessages(messages)
        ]
        // Native structured output (constrained-decoding standard). Honored by
        // Gemini-compat, OpenAI, etc.; providers that don't support it reply 400,
        // and the caller retries without it (prose-JSON fallback).
        if let responseFormat { payload["response_format"] = responseFormat }
        if let reasoningEffort { payload["reasoning_effort"] = reasoningEffort }
        // EVERY TOOL ON EVERY CALL — Hermes's own rule, and the reason the bar for adding one is
        // high: the whole catalog is in the prompt of every request, so a tool nobody calls is a tax
        // on every turn. `tool_choice: auto` because the model deciding NOT to call anything and just
        // answering is the common, correct case.
        if !tools.isEmpty {
            payload["tools"] = try tools.map { try $0.wireForm() }
            payload["tool_choice"] = "auto"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    /// The whole transcript. Tool messages are text-only in the OpenAI schema, so images a tool returned
    /// (rendered frames) follow the run of tool messages they belong to as ONE user message: a user turn
    /// between two tool messages would orphan the second from its call.
    static func encodeMessages(_ messages: [LLMMessage]) -> [[String: Any]] {
        var wire: [[String: Any]] = []
        var pending: [Data] = []
        func flush() {
            guard !pending.isEmpty else { return }
            let note = "[Images returned by the tool calls above, in order.]"
            wire.append(encodeMessage(LLMMessage(.user, note, images: pending)))
            pending = []
        }
        for message in messages {
            if message.role != .tool { flush() }
            wire.append(encodeMessage(message))
            if message.role == .tool { pending += message.images }
        }
        flush()
        return wire
    }

    /// Serializes one message to the OpenAI chat schema. Text-only messages use
    /// the plain `content: String` form; messages carrying images use the
    /// content-parts array (`text` + `image_url` with base64 data URLs).
    static func encodeMessage(_ msg: LLMMessage) -> [String: Any] {
        // A TOOL result: the id is what joins it to the call, and a provider rejects the message
        // without it. Content is the handler's JSON string, sent verbatim.
        if msg.role == .tool {
            return ["role": "tool", "tool_call_id": msg.toolCallID ?? "", "content": msg.content]
        }
        // An ASSISTANT turn that ASKED for tools. `content` is often empty in that case, and must
        // still be sent (as null, not "") — several gateways reject a tool-calling assistant message
        // whose content key is missing entirely.
        if !msg.toolCalls.isEmpty {
            return ["role": msg.role.rawValue,
                    "content": msg.content.isEmpty ? NSNull() : msg.content,
                    "tool_calls": msg.toolCalls.map { call in
                        ["id": call.id, "type": "function",
                         "function": ["name": call.name,
                                      "arguments": call.argumentsJSON.isEmpty ? "{}" : call.argumentsJSON]]
                    }]
        }
        guard !msg.images.isEmpty else {
            return ["role": msg.role.rawValue, "content": msg.content]
        }
        var parts: [[String: Any]] = []
        if !msg.content.isEmpty {
            parts.append(["type": "text", "text": msg.content])
        }
        for image in msg.images {
            let dataURL = "data:\(LLMMessage.imageMediaType(image));base64,\(image.base64EncodedString())"
            parts.append(["type": "image_url", "image_url": ["url": dataURL]])
        }
        return ["role": msg.role.rawValue, "content": parts]
    }

    public func stream(messages: [LLMMessage], model: String) -> AsyncThrowingStream<String, Error> {
        stream(messages: messages, model: model, responseFormat: nil)
    }

    /// Streaming variant that can request native structured output. The plain
    /// `stream` above delegates here with nil.
    public func stream(messages: [LLMMessage], model: String,
                       responseFormat: [String: Any]?) -> AsyncThrowingStream<String, Error> {
        let onUsage = self.onUsage
        // Build the request up front: `URLRequest` is Sendable and can cross into
        // the streaming task, whereas the `[String: Any]?` payload cannot.
        let request: URLRequest
        do {
            request = try makeRequest(messages: messages, model: model, responseFormat: responseFormat)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        // 429 is not a misconfiguration — surface it as itself so the caller doesn't
                        // send the user hunting through settings for a fault that isn't there.
                        if http.statusCode == 429 {
                            let retryAfter = (http.value(forHTTPHeaderField: "retry-after")).flatMap(Int.init)
                            throw LLMError.rateLimited(retryAfter: retryAfter)
                        }
                        // Drain a little of the error body for a useful message.
                        var body = ""
                        for try await line in bytes.lines { body += line; if body.count > 600 { break } }
                        throw LLMError.http(status: http.statusCode, body: body)
                    }

                    var usage: Usage?
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8) else { continue }
                        if let delta = Self.parseDelta(data) {
                            continuation.yield(delta)
                        }
                        if let u = Self.parseUsage(data) { usage = u }
                    }
                    // Report real token spend to the optional callback (best-effort).
                    if let usage { onUsage?(usage) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: LLMError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Stream a turn the model may answer with TOOL CALLS instead of prose (`docs/BOTS.md` §14.9).
    ///
    /// Text arrives token by token exactly as `stream` delivers it. Tool calls arrive ONCE, complete,
    /// at the end: the wire fragments them across chunks keyed by index (`ToolCallAccumulator`), and
    /// half an argument string is not something a caller can act on. A turn yields text, or calls, or
    /// both — a model is allowed to say "let me look that up" and then look it up.
    public func streamWithTools(messages: [LLMMessage], model: String,
                                tools: [LLMToolSpec]) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let onUsage = self.onUsage
        let request: URLRequest
        do {
            request = try makeRequest(messages: messages, model: model, tools: tools)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        if http.statusCode == 429 {
                            let retryAfter = (http.value(forHTTPHeaderField: "retry-after")).flatMap(Int.init)
                            throw LLMError.rateLimited(retryAfter: retryAfter)
                        }
                        var body = ""
                        for try await line in bytes.lines { body += line; if body.count > 600 { break } }
                        throw LLMError.http(status: http.statusCode, body: body)
                    }
                    var usage: Usage?
                    var accumulator = ToolCallAccumulator()
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8) else { continue }
                        if let delta = Self.parseDelta(data) { continuation.yield(.text(delta)) }
                        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            accumulator.ingest(json)
                        }
                        if let u = Self.parseUsage(data) { usage = u }
                    }
                    // After the text, so a caller that renders as it goes has already shown the words
                    // the model said before it asked for something.
                    let calls = accumulator.calls
                    if !calls.isEmpty { continuation.yield(.toolCalls(calls)) }
                    if let usage {
                        continuation.yield(.usage(usage))
                        onUsage?(usage)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: LLMError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Accumulate a full response while requesting native structured output
    /// (`response_format: json_schema`). Returns the complete JSON text.
    public func completeJSON(messages: [LLMMessage], model: String, responseFormat: [String: Any]) async throws -> String {
        var text = ""
        for try await delta in stream(messages: messages, model: model, responseFormat: responseFormat) {
            text += delta
        }
        return text
    }

    // MARK: - SSE parsing (exposed at package scope for unit tests)

    /// Extracts `choices[0].delta.content` (or `.message.content` for gateways
    /// that send the final token under "message") from a streaming chunk.
    static func parseDelta(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first else {
            return nil
        }
        if let delta = first["delta"] as? [String: Any],
           let content = delta["content"] as? String, !content.isEmpty {
            return content
        }
        // Some gateways send the final token under "message".
        if let message = first["message"] as? [String: Any],
           let content = message["content"] as? String, !content.isEmpty {
            return content
        }
        return nil
    }

    /// Extracts the `usage` object from a streaming chunk (present on the final
    /// chunk when `stream_options.include_usage` is honored). nil on content chunks.
    static func parseUsage(_ data: Data) -> Usage? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = json["usage"] as? [String: Any],
              !usage.isEmpty else { return nil }
        func intField(_ key: String) -> Int {
            if let i = usage[key] as? Int { return i }
            if let n = usage[key] as? NSNumber { return n.intValue }
            return 0
        }
        // OpenAI and OpenRouter report the cached part of the prompt under `prompt_tokens_details`;
        // `prompt_tokens` already includes it, so the split is informational there.
        var cached = 0
        if let details = usage["prompt_tokens_details"] as? [String: Any] {
            if let i = details["cached_tokens"] as? Int { cached = i }
            else if let n = details["cached_tokens"] as? NSNumber { cached = n.intValue }
        }
        return Usage(
            promptTokens: intField("prompt_tokens") - cached,
            completionTokens: intField("completion_tokens"),
            totalTokens: intField("total_tokens"),
            cacheReadTokens: cached
        )
    }
}
