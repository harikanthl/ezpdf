//
//  LLMTools.swift
//  OperatorLLM
//
//  TOOL CALLING — the vocabulary, lifted in shape from Hermes Agent's `tools/registry.py` +
//  `model_tools.py` (NousResearch, read 2026-09-04) and expressed in Swift.
//
//  Hermes's registry is `register(name:, toolset:, schema:, handler:, check_fn:)` where "all handlers
//  return a JSON string", results come back as `"tool"`-role messages, and the loop iterates until the
//  model stops asking. Three of those four ideas are the whole contract, and they are what this file
//  gives the client:
//
//    • a SPEC the model is shown (name, description, JSON-Schema parameters);
//    • a CALL the model makes (id, name, arguments as JSON text);
//    • a RESULT that goes back as a `tool` message carrying the call's id.
//
//  ‼️ PARAMETERS AND ARGUMENTS ARE JSON TEXT, not `[String: Any]`. A dictionary of `Any` is neither
//  `Sendable` nor `Equatable`, and both matter here: a spec crosses into the streaming task, and a
//  tool catalog has to be comparable in a test. Text is decoded once, at the moment the request body
//  is built, where a malformed schema fails loudly instead of silently encoding as `{}`.
//
//  The gateway contract is OpenAI's, which every provider this app talks to implements — including
//  Anthropic and Gemini through their compat layers, and Ollama for a local model.
//

import Foundation

/// One tool, as the model is shown it.
public struct LLMToolSpec: Sendable, Equatable, Codable, Identifiable {
    /// The name the model calls. Lowercase with underscores, by convention and by every provider's
    /// validator (`^[a-zA-Z0-9_-]{1,64}$`).
    public var name: String
    /// What it does, in the second person, and — Hermes's rule, worth keeping — describing only its
    /// OWN capability. A description that mentions a tool from another set teaches the model to call
    /// something that is not on offer.
    public var description: String
    /// JSON Schema for the arguments, as JSON text. `{"type":"object","properties":{}}` for none.
    public var parametersJSON: String

    public var id: String { name }

    public init(name: String, description: String, parametersJSON: String) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }

    /// A spec that takes no arguments.
    public static func noArguments(_ name: String, _ description: String) -> LLMToolSpec {
        LLMToolSpec(name: name, description: description,
                    parametersJSON: #"{"type":"object","properties":{},"additionalProperties":false}"#)
    }

    /// The OpenAI `tools[]` entry. Throws when `parametersJSON` is not an object — a schema typo is a
    /// programming error, and failing the request beats sending a tool the model cannot call.
    ///
    /// Public so a catalog can be VALIDATED where it is authored (`BotToolKitTests` does exactly
    /// this): a malformed schema is otherwise invisible until a live turn refuses.
    public func wireForm() throws -> [String: Any] {
        guard let data = parametersJSON.data(using: .utf8),
              let schema = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.notConfigured("Tool \(name) has a malformed parameter schema.")
        }
        return ["type": "function",
                "function": ["name": name, "description": description, "parameters": schema]]
    }
}

/// One call the model made.
public struct LLMToolCall: Sendable, Equatable, Codable, Identifiable {
    /// The provider's id for this call. It must come back on the result message or the turn is
    /// malformed — this is the join key of the whole protocol.
    public var id: String
    public var name: String
    /// The arguments as JSON text, exactly as the model emitted them. Parsed by the handler, which is
    /// the only thing that knows the shape it wants.
    public var argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }

    /// The arguments as a dictionary, or empty when absent/malformed. Lenient on purpose: a model that
    /// emits `""` or `"null"` for a no-argument tool is common and is not an error.
    public var arguments: [String: Any] {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    /// One string argument, trimmed, or nil when missing or blank.
    public func string(_ key: String) -> String? {
        guard let raw = arguments[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// One integer argument. Accepts a JSON number or a numeric string, because models emit both.
    public func int(_ key: String) -> Int? {
        if let i = arguments[key] as? Int { return i }
        if let n = arguments[key] as? NSNumber { return n.intValue }
        if let s = arguments[key] as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}

/// Token usage reported by the gateway on the final streaming chunk (when
/// `stream_options.include_usage` is honored). Fields absent from the payload
/// default to 0.
///
/// Lives here, beside `LLMStreamEvent.usage` which carries it and `AgentLoop` which sums it, rather
/// than in `OpenAICompatibleClient.swift` where it was written: that file is one of the three the
/// Linux build excludes (`URLSession.bytes` does not exist there — see Package.swift), and a shared
/// value type inside an excluded file takes the whole package down on that platform. Moved
/// 2026-09-11; same module, same name, same members, no behaviour change.
public struct Usage: Sendable, Equatable {
    public var promptTokens: Int
    public var completionTokens: Int
    public var totalTokens: Int
    /// Prompt tokens served from the provider's cache at the discounted rate. On the Anthropic
    /// route this is `cache_read_input_tokens`; on OpenAI-compatible gateways it is
    /// `prompt_tokens_details.cached_tokens`. Zero when the route reports nothing.
    public var cacheReadTokens: Int
    /// Prompt tokens written to the cache this request (Anthropic's `cache_creation_input_tokens`).
    public var cacheWriteTokens: Int

    public init(promptTokens: Int, completionTokens: Int, totalTokens: Int,
                cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }

    /// The share of the prompt that came from cache, 0...1. What a chat shows as "92% cached".
    public var cachedShare: Double {
        let prompt = promptTokens + cacheReadTokens + cacheWriteTokens
        guard prompt > 0 else { return 0 }
        return Double(cacheReadTokens) / Double(prompt)
    }
}

/// What a tool-capable stream emits. Text arrives token by token as it always did; tool calls arrive
/// once, complete, because a half-parsed argument string is not something a caller can act on.
public enum LLMStreamEvent: Sendable, Equatable {
    case text(String)
    case toolCalls([LLMToolCall])
    /// What the turn cost, once, after the text and the calls. Carries the prompt-cache split on
    /// routes that report it, so a chat can show that the discount is real.
    case usage(Usage)
}

/// Accumulates OpenAI's fragmented `delta.tool_calls` into whole calls.
///
/// The wire format is a stream of fragments keyed by INDEX, not by id: the first fragment for an index
/// carries the id and the function name, and every later one appends a slice of the argument JSON.
///
/// ```
/// {"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read_document","arguments":"{\"fi"}}]}}
/// {"delta":{"tool_calls":[{"index":0,"function":{"arguments":"le\":\"a.md\"}"}}]}
/// ```
///
/// Pure and `internal` so the reassembly is tested without a network — the one part of tool calling
/// that is fiddly enough to get quietly wrong, and invisible when it does (a truncated argument
/// string parses as `[:]` and the tool runs with no arguments).
struct ToolCallAccumulator: Sendable {
    private struct Partial { var id = ""; var name = ""; var arguments = "" }
    private var partials: [Int: Partial] = [:]
    private var order: [Int] = []

    var isEmpty: Bool { partials.isEmpty }

    /// Fold one SSE chunk's `tool_calls` fragments in. Ignores chunks that carry none.
    mutating func ingest(_ json: [String: Any]) {
        guard let choices = json["choices"] as? [[String: Any]], let first = choices.first else { return }
        // `delta` while streaming; `message` from a gateway that sends the whole thing at the end.
        let container = (first["delta"] as? [String: Any]) ?? (first["message"] as? [String: Any])
        guard let fragments = container?["tool_calls"] as? [[String: Any]] else { return }
        for fragment in fragments {
            let index = (fragment["index"] as? Int) ?? (fragment["index"] as? NSNumber)?.intValue ?? 0
            if partials[index] == nil { partials[index] = Partial(); order.append(index) }
            if let id = fragment["id"] as? String, !id.isEmpty { partials[index]?.id = id }
            guard let function = fragment["function"] as? [String: Any] else { continue }
            if let name = function["name"] as? String, !name.isEmpty { partials[index]?.name = name }
            if let arguments = function["arguments"] as? String { partials[index]?.arguments += arguments }
        }
    }

    /// The finished calls, in the order the model asked for them.
    ///
    /// A fragment set with no name is dropped: it is a provider quirk, not a call, and inventing a
    /// nameless tool call would fail downstream with a worse message. A missing id is SYNTHESIZED
    /// rather than dropped — some gateways omit it on a single call, and the result message needs
    /// something to join on.
    var calls: [LLMToolCall] {
        order.compactMap { index in
            guard let partial = partials[index], !partial.name.isEmpty else { return nil }
            let id = partial.id.isEmpty ? "call_\(index)" : partial.id
            return LLMToolCall(id: id, name: partial.name, argumentsJSON: partial.arguments)
        }
    }
}
