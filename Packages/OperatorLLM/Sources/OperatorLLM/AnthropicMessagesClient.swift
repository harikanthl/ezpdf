//
//  AnthropicMessagesClient.swift
//  OperatorLLM
//
//  The native Anthropic Messages route (`POST {baseURL}/messages`), beside the OpenAI-compatible
//  client (docs/OSS_LIFT_2026-09.md L4).
//
//  WHY A SECOND CLIENT. The Anthropic preset used to post to Anthropic's OpenAI-compatibility layer,
//  which speaks the chat-completions shape and nothing else. Prompt caching is a Messages-API
//  feature: `cache_control` marks on the system prefix and the tool list, and a top-level mark that
//  caches the growing conversation tail. `DirectChatModel.send` was already written to keep its
//  prefix byte-stable for exactly this discount, and nothing on the wire claimed it. This client does.
//
//  WHAT IS MARKED. Two explicit breakpoints and one automatic: the last system block, the last tool
//  definition, and the request-level `cache_control` that the API places on the last cacheable block
//  of `messages`. Four is the API's maximum per request; three leaves room for a caller that marks a
//  document. The read discount shows up in `Usage.cacheReadTokens`, which the stream yields as its
//  last event so a chat can say what the turn cost.
//
//  WHAT IS NOT SENT. No `thinking` parameter (the current models run adaptive thinking by default and
//  reject the old budget shape), no forced `tool_choice` (rejected on the newest tier; `auto` plus the
//  tool description is the supported way), no prefill (removed on the 4.6+ family).
//
//  Pure pieces are separate types so they are tested without a network: `AnthropicWire` builds the
//  request body from `LLMMessage`s, `AnthropicStreamAccumulator` folds the server-sent events into
//  text, tool calls and usage.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // Linux keeps URLSession in its own module.
#endif

public struct AnthropicMessagesClient: LLMToolClient {
    public let baseURL: String
    public let apiKey: String
    /// Output ceiling for one reply; covers thinking and visible text on thinking-capable models,
    /// so it is generous. Unused headroom costs nothing.
    public var maxTokens: Int
    /// Best-effort callback with real token spend once the stream ends.
    public var onUsage: (@Sendable (Usage) -> Void)?

    public static let defaultBaseURL = "https://api.anthropic.com/v1"
    static let apiVersion = "2023-06-01"

    public init(baseURL: String = AnthropicMessagesClient.defaultBaseURL,
                apiKey: String,
                maxTokens: Int = 16_384,
                onUsage: (@Sendable (Usage) -> Void)? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.maxTokens = maxTokens
        self.onUsage = onUsage
    }

    /// Internal so the header rules and body shape can be pinned by a test without a network.
    func makeRequest(messages: [LLMMessage], model: String, tools: [LLMToolSpec]) throws -> URLRequest {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedBase.isEmpty, let url = URL(string: trimmedBase + "/messages") else {
            throw LLMError.invalidURL
        }
        guard !apiKey.isEmpty else { throw LLMError.missingAPIKey }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        // Two credential shapes. A console key goes in `x-api-key`; a subscription token from
        // `ant auth login` or a Claude plan (`sk-ant-oat…`) is an OAuth bearer and needs the beta
        // flag, or the API reads it as a malformed console key. Same rule `OpenAICompatibleClient`
        // and `LLMModelCatalog` keep.
        if apiKey.hasPrefix("sk-ant-oat") {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        } else {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        let body = try AnthropicWire.body(messages: messages, model: model, tools: tools,
                                          maxTokens: maxTokens)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// The Messages API has no `response_format`. The schema the OpenAI route would send natively is
    /// put in front of the model as an instruction instead, and the reply is unwrapped from the code
    /// fence Claude tends to add, so the caller gets what the other route gives it: JSON text, bare.
    public func completeJSON(messages: [LLMMessage], model: String,
                             responseFormat: [String: Any]) async throws -> String {
        let instruction = AnthropicWire.jsonInstruction(responseFormat: responseFormat)
        var prompted = messages
        if let index = prompted.firstIndex(where: { $0.role == .system }) {
            prompted[index] = LLMMessage(.system, prompted[index].content + "\n\n" + instruction)
        } else {
            prompted.insert(LLMMessage(.system, instruction), at: 0)
        }
        return AnthropicWire.unfenced(try await complete(messages: prompted, model: model))
    }

    public func stream(messages: [LLMMessage], model: String) -> AsyncThrowingStream<String, Error> {
        let events = streamWithTools(messages: messages, model: model, tools: [])
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in events {
                        if case let .text(delta) = event { continuation.yield(delta) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

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
                    var accumulator = AnthropicStreamAccumulator()
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }
                        switch try accumulator.ingest(json) {
                        case let .text(delta):
                            continuation.yield(.text(delta))
                        case .none:
                            break
                        }
                    }
                    // Text first, then the calls, then what it cost: a caller rendering as it goes
                    // has shown the words before the model's ask arrives, and the usage line lands
                    // once the turn is whole.
                    let calls = accumulator.calls
                    if !calls.isEmpty { continuation.yield(.toolCalls(calls)) }
                    if let usage = accumulator.usage {
                        continuation.yield(.usage(usage))
                        onUsage?(usage)
                    }
                    if let refusal = accumulator.refusal {
                        throw LLMError.unavailable(refusal)
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
}

// MARK: - Request body

/// `LLMMessage`s to the Messages API's body. Pure, so the shape is pinned by tests.
public enum AnthropicWire {
    // Computed: `[String: Any]` is not `Sendable`, and a two-entry literal is free to rebuild.
    static var cacheMark: [String: Any] { ["type": "ephemeral"] }

    /// The instruction that stands in for `response_format`: the schema, when the caller gave one,
    /// and the rule that the reply is the JSON and nothing else. Keys are sorted so the same schema
    /// is the same prompt prefix every time, which is what lets it cache.
    public static func jsonInstruction(responseFormat: [String: Any]) -> String {
        var lines = ["Reply with ONLY a single JSON object: no prose before or after it, no code fence."]
        let jsonSchema = responseFormat["json_schema"] as? [String: Any]
        if let schema = jsonSchema?["schema"],
           JSONSerialization.isValidJSONObject(schema),
           let data = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            lines.append("The object must match this JSON Schema exactly:")
            lines.append(text)
        }
        return lines.joined(separator: "\n")
    }

    /// A reply with the ``` fence Claude adds despite the instruction, unwrapped; anything else
    /// returned trimmed. Only a fence that wraps the WHOLE reply is removed, so a JSON string value
    /// that happens to contain backticks is left alone.
    public static func unfenced(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```"), trimmed.count >= 6 else { return trimmed }
        var inner = trimmed.dropFirst(3).dropLast(3)
        if let newline = inner.firstIndex(of: "\n") {
            let tag = inner[inner.startIndex..<newline]
            if !tag.contains(" ") && !tag.contains("{") { inner = inner[inner.index(after: newline)...] }
        }
        return inner.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func body(messages: [LLMMessage], model: String, tools: [LLMToolSpec],
                            maxTokens: Int) throws -> [String: Any] {
        let (system, turns) = encode(messages)
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "messages": turns,
            // Automatic caching of the conversation tail: the API places this on the last
            // cacheable block of `messages`, so each turn reads the previous turn's prefix.
            "cache_control": cacheMark,
        ]
        if !system.isEmpty { body["system"] = system }
        if !tools.isEmpty {
            var wired = try tools.map { tool -> [String: Any] in
                guard let data = tool.parametersJSON.data(using: .utf8),
                      let schema = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw LLMError.notConfigured("Tool \(tool.name) has a malformed parameter schema.")
                }
                return ["name": tool.name, "description": tool.description, "input_schema": schema]
            }
            // The tool list is part of the stable prefix (rendered before `system`): one mark on
            // the last definition covers them all.
            wired[wired.count - 1]["cache_control"] = cacheMark
            body["tools"] = wired
            body["tool_choice"] = ["type": "auto"]
        }
        return body
    }

    /// Split the transcript into the top-level `system` blocks (the leading system messages, with
    /// a cache mark on the last) and the alternating turns.
    ///
    /// Rules the API holds us to, each one a rejected request if skipped:
    /// • a tool's result is a `tool_result` block in a USER message, and every result answering
    ///   one assistant turn goes in ONE user message;
    /// • an assistant turn that called tools carries `tool_use` blocks whose ids the results cite;
    /// • consecutive messages of one role are merged, so the roles alternate.
    /// A system message that appears after the first user turn is not a top-level system block;
    /// it rides the next user turn as a bracketed operator line, which every model reads.
    static func encode(_ messages: [LLMMessage]) -> (system: [[String: Any]], turns: [[String: Any]]) {
        var system: [[String: Any]] = []
        var turns: [[String: Any]] = []
        var seenNonSystem = false

        func append(role: String, blocks: [[String: Any]]) {
            guard !blocks.isEmpty else { return }
            if let last = turns.last, last["role"] as? String == role,
               var content = last["content"] as? [[String: Any]] {
                content.append(contentsOf: blocks)
                turns[turns.count - 1]["content"] = content
            } else {
                turns.append(["role": role, "content": blocks])
            }
        }

        for message in messages {
            switch message.role {
            case .system:
                if !seenNonSystem {
                    if !message.content.isEmpty { system.append(["type": "text", "text": message.content]) }
                } else if !message.content.isEmpty {
                    append(role: "user", blocks: [["type": "text", "text": "[\(message.content)]"]])
                }
            case .user:
                seenNonSystem = true
                var blocks: [[String: Any]] = []
                if !message.content.isEmpty { blocks.append(["type": "text", "text": message.content]) }
                blocks += message.images.map(imageBlock)
                append(role: "user", blocks: blocks)
            case .assistant:
                seenNonSystem = true
                var blocks: [[String: Any]] = []
                if !message.content.isEmpty { blocks.append(["type": "text", "text": message.content]) }
                for call in message.toolCalls {
                    blocks.append(["type": "tool_use", "id": call.id, "name": call.name,
                                   "input": call.arguments])
                }
                append(role: "assistant", blocks: blocks)
            case .tool:
                seenNonSystem = true
                // Images (rendered frames) go INSIDE the tool_result, which the API allows: content is
                // then a list of text and image blocks instead of a string.
                let content: Any = message.images.isEmpty ? message.content
                    : [["type": "text", "text": message.content]] + message.images.map(imageBlock)
                append(role: "user", blocks: [["type": "tool_result",
                                               "tool_use_id": message.toolCallID ?? "",
                                               "content": content]])
            }
        }
        if !system.isEmpty { system[system.count - 1]["cache_control"] = cacheMark }
        return (system, turns)
    }

    static func imageBlock(_ data: Data) -> [String: Any] {
        ["type": "image",
         "source": ["type": "base64", "media_type": LLMMessage.imageMediaType(data), "data": data.base64EncodedString()]]
    }
}

// MARK: - Stream accumulation

/// Folds the Messages API's server-sent events into text deltas (yielded as they land), the tool
/// calls (whole, at the end), the usage (from `message_start` and `message_delta`), and a refusal.
/// Pure: `ingest` takes the decoded event and returns what to yield now.
struct AnthropicStreamAccumulator: Sendable {
    enum Yield: Equatable { case text(String), none }

    private struct Partial { var id = ""; var name = ""; var json = "" }
    private var partials: [Int: Partial] = [:]
    private var order: [Int] = []
    private(set) var usage: Usage?
    private(set) var refusal: String?

    mutating func ingest(_ event: [String: Any]) throws -> Yield {
        guard let type = event["type"] as? String else { return .none }
        switch type {
        case "message_start":
            if let message = event["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any] {
                self.usage = Self.usage(from: usage, base: self.usage)
            }
        case "content_block_start":
            guard let index = Self.int(event["index"]),
                  let block = event["content_block"] as? [String: Any],
                  block["type"] as? String == "tool_use" else { return .none }
            var partial = Partial()
            partial.id = block["id"] as? String ?? ""
            partial.name = block["name"] as? String ?? ""
            partials[index] = partial
            order.append(index)
        case "content_block_delta":
            guard let index = Self.int(event["index"]),
                  let delta = event["delta"] as? [String: Any],
                  let kind = delta["type"] as? String else { return .none }
            switch kind {
            case "text_delta":
                if let text = delta["text"] as? String, !text.isEmpty { return .text(text) }
            case "input_json_delta":
                if let fragment = delta["partial_json"] as? String { partials[index]?.json += fragment }
            default:
                break
            }
        case "message_delta":
            if let usage = event["usage"] as? [String: Any] {
                self.usage = Self.usage(from: usage, base: self.usage)
            }
            if let delta = event["delta"] as? [String: Any],
               delta["stop_reason"] as? String == "refusal" {
                let details = delta["stop_details"] as? [String: Any]
                let category = details?["category"] as? String
                refusal = "The model declined this request"
                    + (category.map { " (\($0))" } ?? "") + ". Try rephrasing."
            }
        case "error":
            let error = event["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "The provider reported a stream error."
            throw LLMError.http(status: 0, body: message)
        default:
            break
        }
        return .none
    }

    /// Tool calls in the order their blocks started. An empty `input` is sent as `{}` so a handler
    /// that parses arguments never sees a truncated string.
    var calls: [LLMToolCall] {
        order.compactMap { index in
            guard let partial = partials[index], !partial.name.isEmpty else { return nil }
            let id = partial.id.isEmpty ? "toolu_\(index)" : partial.id
            let json = partial.json.trimmingCharacters(in: .whitespacesAndNewlines)
            return LLMToolCall(id: id, name: partial.name, argumentsJSON: json.isEmpty ? "{}" : json)
        }
    }

    /// `message_start` carries the input side (including the cache split); `message_delta` carries
    /// the output count. Fields absent from one stay as the other reported them.
    private static func usage(from payload: [String: Any], base: Usage?) -> Usage {
        var usage = base ?? Usage(promptTokens: 0, completionTokens: 0, totalTokens: 0)
        if let input = int(payload["input_tokens"]) { usage.promptTokens = input }
        if let output = int(payload["output_tokens"]) { usage.completionTokens = output }
        if let read = int(payload["cache_read_input_tokens"]) { usage.cacheReadTokens = read }
        if let written = int(payload["cache_creation_input_tokens"]) { usage.cacheWriteTokens = written }
        usage.totalTokens = usage.promptTokens + usage.cacheReadTokens + usage.cacheWriteTokens
            + usage.completionTokens
        return usage
    }

    private static func int(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        return nil
    }
}
