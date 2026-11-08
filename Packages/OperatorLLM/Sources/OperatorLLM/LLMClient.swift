//
//  LLMClient.swift
//  OperatorLLM
//
//  Provider-agnostic chat interface. Implementations: OpenAICompatibleClient
//  (OpenAI / Anthropic-compat / Gemini-compat / custom) and the on-device route
//  via OnDeviceLLM. Lifted from MuseDrop's LLMClient.swift; made public.
//

import Foundation

public enum LLMRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    /// A tool's answer to one call the assistant made. Carries `toolCallID`, without which the turn
    /// is malformed — see `LLMToolCall.id`.
    case tool
}

public struct LLMMessage: Codable, Sendable, Equatable {
    public var role: LLMRole
    public var content: String
    /// PNG image bytes for multimodal (vision) input. Empty for text-only turns.
    /// Only honored by cloud providers whose model is vision-capable; the
    /// on-device route ignores images.
    public var images: [Data]
    /// On an ASSISTANT message: the tools it asked to call. The transcript must carry these back on
    /// the next request or the provider rejects the `tool` messages that answer them as unsolicited.
    public var toolCalls: [LLMToolCall]
    /// On a TOOL message: which call this answers.
    public var toolCallID: String?

    public init(_ role: LLMRole, _ content: String, images: [Data] = [],
                toolCalls: [LLMToolCall] = [], toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.images = images
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    /// A tool's result, as the model must receive it. `content` is JSON text by convention (Hermes's
    /// "all handlers return a JSON string"), which keeps a result parseable and keeps a handler from
    /// smuggling prose the model reads as instructions.
    public static func toolResult(_ callID: String, _ json: String, images: [Data] = []) -> LLMMessage {
        LLMMessage(.tool, json, images: images, toolCallID: callID)
    }

    /// The MIME type of image bytes, sniffed from the header (PNG, JPEG, GIF, WebP); PNG when unknown,
    /// which is what every caller sent before images could be anything else.
    public static func imageMediaType(_ data: Data) -> String {
        let head = [UInt8](data.prefix(12))
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if head.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if head.count >= 12, head.starts(with: [0x52, 0x49, 0x46, 0x46]), Array(head[8..<12]) == [0x57, 0x45, 0x42, 0x50] {
            return "image/webp"
        }
        return "image/png"
    }

    /// The transcript with images kept only on the last `keep` messages that carry any (older ones get a
    /// note in their place). Every request resends the whole transcript, so a long agent run that looks at
    /// frames again and again would otherwise pay for every old frame on every round.
    public static func keepingRecentImages(_ messages: [LLMMessage], keep: Int) -> [LLMMessage] {
        var remaining = max(0, keep)
        var result = messages
        for index in result.indices.reversed() where !result[index].images.isEmpty {
            if remaining > 0 {
                remaining -= 1
            } else {
                result[index].content += "\n[\(result[index].images.count) earlier image(s) omitted]"
                result[index].images = []
            }
        }
        return result
    }

    // Additive decoding: a message persisted before tool calling existed has neither field.
    private enum CodingKeys: String, CodingKey { case role, content, images, toolCalls, toolCallID }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(LLMRole.self, forKey: .role)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        images = try c.decodeIfPresent([Data].self, forKey: .images) ?? []
        toolCalls = try c.decodeIfPresent([LLMToolCall].self, forKey: .toolCalls) ?? []
        toolCallID = try c.decodeIfPresent(String.self, forKey: .toolCallID)
    }
}

/// What a tool hands back to the model: its text (JSON by convention) and, for tools that look at
/// something (rendered video frames), images. Routes that can't put images in a tool result say so in
/// the text instead (the on-device route), or carry them in a following user turn (OpenAI-compatible).
public struct LLMToolOutput: Sendable, Equatable {
    public var text: String
    /// Image bytes (PNG or JPEG; the type is sniffed when sent).
    public var images: [Data]

    public init(_ text: String, images: [Data] = []) {
        self.text = text
        self.images = images
    }
}

public enum LLMError: LocalizedError {
    case notConfigured(String)
    case missingAPIKey
    case invalidURL
    case http(status: Int, body: String)
    /// The provider accepted the credentials and refused on volume (HTTP 429).
    ///
    /// Worth its own case rather than folding into `.http`: nothing is misconfigured, so telling the
    /// user to check their settings sends them hunting for a fault that isn't there. It is also the
    /// one error class where waiting actually works — which callers can only act on if they can tell
    /// it apart. `retryAfter` is the provider's own `retry-after`, in seconds, when it sent one.
    case rateLimited(retryAfter: Int?)
    case decoding(String)
    case cancelled
    case unavailable(String)
    /// Apple's on-device safety classifier refused the prompt or the reply.
    ///
    /// Worth its own case rather than folding into `.unavailable`: the model IS available, it declined
    /// this particular text — and the classifier is known to fire on innocuous input, so the caller
    /// usually wants to retry elsewhere rather than tell the user their request was unsafe.
    case refused

    /// A 400 that is about the SIZE of what was sent, not its shape or the account
    /// (docs/OSS_LIFT_2026-09.md R6; the guide's postmortem #6: oversized payloads trip admission
    /// checks before quota and read like quota). Retrying at the same size fails identically; the
    /// remedy is a smaller prompt. Matched on the provider phrasings seen in the wild, not on a
    /// status code alone: a 400 can be many things.
    public var isPayloadTooLarge: Bool {
        guard case let .http(status, body) = self, status == 400 || status == 413 else { return false }
        if status == 413 { return true }
        let lower = body.lowercased()
        let signatures = ["too long", "too large", "context_length", "context length",
                          "maximum context", "max_tokens", "exceeds the", "token limit",
                          "request entity", "prompt is too", "input is too"]
        return signatures.contains { lower.contains($0) }
    }

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let detail): return detail
        case .refused:
            return "On-device AI wouldn't answer that. Try rephrasing, or set up a cloud model in Settings."
        case .missingAPIKey: return "Add an API key in ezpdf Settings → Assistant to use this provider."
        case .invalidURL: return "The provider base URL is invalid."
        case .rateLimited(let retryAfter):
            let wait = retryAfter.map { " Try again in \($0)s." } ?? ""
            return "Provider rate limit reached for this model.\(wait) If every model except the cheapest is rate-limited, the key is likely a subscription/OAuth token rather than a console API key — those carry little or no general API quota."
        case .http(let status, let body):
            let trimmed = body.count > 300 ? String(body.prefix(300)) + "…" : body
            return "Provider error (\(status)): \(trimmed)"
        case .decoding(let detail): return "Could not read the model response: \(detail)"
        case .cancelled: return "Request cancelled."
        case .unavailable(let detail): return detail
        }
    }
}

/// A streaming-capable chat client.
public protocol LLMClient: Sendable {
    /// Stream assistant text deltas. Throws on transport/HTTP errors.
    func stream(messages: [LLMMessage], model: String) -> AsyncThrowingStream<String, Error>
}

/// A client that can also offer tools and stream the model's calls back (`AgentLoop.Round`).
/// Two live implementations: the OpenAI-compatible route and the native Anthropic route; a chat
/// holds `any LLMToolClient` so the resolver's choice of route is invisible to it.
public protocol LLMToolClient: LLMClient {
    func streamWithTools(messages: [LLMMessage], model: String,
                         tools: [LLMToolSpec]) -> AsyncThrowingStream<LLMStreamEvent, Error>

    /// One complete reply that is a JSON document, for the brief, the action parse and the schedule
    /// assistant. `responseFormat` is the OpenAI `response_format` object (`json_schema` with a
    /// `schema`); a route without native structured output honours it by instruction and returns the
    /// same thing: the JSON text, with nothing around it.
    func completeJSON(messages: [LLMMessage], model: String, responseFormat: [String: Any]) async throws -> String
}

extension LLMClient {
    /// Convenience: accumulate the full response from the stream.
    public func complete(messages: [LLMMessage], model: String) async throws -> String {
        var text = ""
        for try await delta in stream(messages: messages, model: model) {
            text += delta
        }
        return text
    }
}
