import Foundation
import Testing
@testable import OperatorLLM

/// The native Anthropic route (docs/OSS_LIFT_2026-09.md L4): the body shape the Messages API holds
/// us to, the cache marks that earn the discount, and the stream events folded back into text,
/// calls and usage. No network anywhere.
@Suite struct AnthropicWireTests {
    private let readDoc = LLMToolSpec(name: "read_document", description: "Read a file.",
                                      parametersJSON: #"{"type":"object","properties":{"filename":{"type":"string"}}}"#)
    private let recall = LLMToolSpec.noArguments("recall", "Recall this thread.")

    private func body(_ messages: [LLMMessage], tools: [LLMToolSpec] = []) throws -> [String: Any] {
        try AnthropicWire.body(messages: messages, model: "claude-haiku-4-5", tools: tools, maxTokens: 100)
    }

    @Test func leadingSystemBecomesTopLevelSystemWithACacheMarkOnTheLastBlock() throws {
        let body = try body([LLMMessage(.system, "You are Builder."),
                             LLMMessage(.system, "Facts: none."),
                             LLMMessage(.user, "hi")])
        let system = try #require(body["system"] as? [[String: Any]])
        #expect(system.count == 2)
        #expect(system[0]["cache_control"] == nil)
        #expect((system[1]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        // The request-level mark caches the growing tail.
        #expect((body["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        #expect(body["stream"] as? Bool == true)
        #expect(body["max_tokens"] as? Int == 100)
    }

    @Test func toolsGetOneCacheMarkOnTheLastDefinitionAndAutoChoice() throws {
        let body = try body([LLMMessage(.user, "hi")], tools: [readDoc, recall])
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.count == 2)
        #expect(tools[0]["name"] as? String == "read_document")
        #expect(tools[0]["cache_control"] == nil)
        #expect(tools[1]["cache_control"] != nil)
        #expect((tools[0]["input_schema"] as? [String: Any])?["type"] as? String == "object")
        #expect((body["tool_choice"] as? [String: Any])?["type"] as? String == "auto")
    }

    @Test func noToolsMeansNoToolKeys() throws {
        let body = try body([LLMMessage(.user, "hi")])
        #expect(body["tools"] == nil)
        #expect(body["tool_choice"] == nil)
    }

    @Test func aToolCallTurnAndItsResultsBecomeToolUseAndOneToolResultMessage() throws {
        let calls = [LLMToolCall(id: "toolu_1", name: "read_document", argumentsJSON: #"{"filename":"a.md"}"#),
                     LLMToolCall(id: "toolu_2", name: "recall", argumentsJSON: "")]
        let body = try body([LLMMessage(.user, "compare"),
                             LLMMessage(.assistant, "Let me look.", toolCalls: calls),
                             LLMMessage.toolResult("toolu_1", #"{"body":"A"}"#),
                             LLMMessage.toolResult("toolu_2", #"{"lines":[]}"#),
                             LLMMessage(.assistant, "Both say A.")])
        let turns = try #require(body["messages"] as? [[String: Any]])
        #expect(turns.map { $0["role"] as? String } == ["user", "assistant", "user", "assistant"])
        let ask = try #require(turns[1]["content"] as? [[String: Any]])
        #expect(ask[0]["type"] as? String == "text")
        #expect(ask[1]["type"] as? String == "tool_use")
        #expect(ask[1]["id"] as? String == "toolu_1")
        #expect((ask[1]["input"] as? [String: Any])?["filename"] as? String == "a.md")
        #expect((ask[2]["input"] as? [String: Any])?.isEmpty == true)
        // ‼️ BOTH results in ONE user message, each citing its call.
        let results = try #require(turns[2]["content"] as? [[String: Any]])
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0["type"] as? String == "tool_result" })
        #expect(results[0]["tool_use_id"] as? String == "toolu_1")
        #expect(results[1]["tool_use_id"] as? String == "toolu_2")
    }

    @Test func consecutiveUserMessagesMergeSoRolesAlternate() throws {
        let body = try body([LLMMessage(.user, "one"), LLMMessage(.user, "two")])
        let turns = try #require(body["messages"] as? [[String: Any]])
        #expect(turns.count == 1)
        #expect((turns[0]["content"] as? [[String: Any]])?.count == 2)
    }

    @Test func aLateSystemMessageRidesTheNextUserTurnBracketed() throws {
        let body = try body([LLMMessage(.user, "hi"), LLMMessage(.assistant, "hello"),
                             LLMMessage(.system, "Terse mode."), LLMMessage(.user, "go")])
        let turns = try #require(body["messages"] as? [[String: Any]])
        #expect(body["system"] == nil)
        let last = try #require(turns.last?["content"] as? [[String: Any]])
        #expect(last[0]["text"] as? String == "[Terse mode.]")
        #expect(last[1]["text"] as? String == "go")
    }

    @Test func imagesBecomeBase64Blocks() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let body = try body([LLMMessage(.user, "what is this", images: [png])])
        let turns = try #require(body["messages"] as? [[String: Any]])
        let blocks = try #require(turns[0]["content"] as? [[String: Any]])
        #expect(blocks[1]["type"] as? String == "image")
        let source = try #require(blocks[1]["source"] as? [String: Any])
        #expect(source["media_type"] as? String == "image/png")
        #expect(source["data"] as? String == png.base64EncodedString())
    }

    @Test func aMalformedToolSchemaIsARefusalNotACrash() {
        let broken = LLMToolSpec(name: "x", description: "y", parametersJSON: "not json")
        #expect(throws: LLMError.self) {
            try AnthropicWire.body(messages: [LLMMessage(.user, "hi")], model: "m", tools: [broken],
                                   maxTokens: 10)
        }
    }
}

@Suite struct AnthropicMessagesClientHeaderTests {
    @Test func aConsoleKeyGoesInXApiKeyWithTheVersionHeader() throws {
        let client = AnthropicMessagesClient(apiKey: "sk-ant-api03-abc")
        let request = try client.makeRequest(messages: [LLMMessage(.user, "hi")], model: "m", tools: [])
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-api03-abc")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    }

    @Test func anOAuthTokenGoesAsBearerWithTheBetaFlag() throws {
        let client = AnthropicMessagesClient(apiKey: "sk-ant-oat01-xyz")
        let request = try client.makeRequest(messages: [LLMMessage(.user, "hi")], model: "m", tools: [])
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-ant-oat01-xyz")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
    }

    @Test func anEmptyKeyIsMissingAPIKey() {
        let client = AnthropicMessagesClient(apiKey: "")
        #expect(throws: LLMError.self) {
            try client.makeRequest(messages: [LLMMessage(.user, "hi")], model: "m", tools: [])
        }
    }
}

@Suite struct AnthropicStreamAccumulatorTests {
    private func event(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
    }

    @Test func textDeltasAreYieldedAsTheyLand() throws {
        var acc = AnthropicStreamAccumulator()
        let a = try acc.ingest(event(#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#))
        let b = try acc.ingest(event(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}"#))
        let c = try acc.ingest(event(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}"#))
        #expect(a == .none)
        #expect(b == .text("Hel"))
        #expect(c == .text("lo"))
        #expect(acc.calls.isEmpty)
    }

    @Test func aToolUseBlockIsAssembledFromItsJSONFragments() throws {
        var acc = AnthropicStreamAccumulator()
        _ = try acc.ingest(event(#"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_9","name":"read_document","input":{}}}"#))
        _ = try acc.ingest(event(#"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"filen"}}"#))
        _ = try acc.ingest(event(#"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"ame\":\"a.md\"}"}}"#))
        _ = try acc.ingest(event(#"{"type":"content_block_stop","index":1}"#))
        let calls = acc.calls
        #expect(calls.count == 1)
        #expect(calls[0].id == "toolu_9")
        #expect(calls[0].name == "read_document")
        #expect(calls[0].string("filename") == "a.md")
    }

    @Test func aToolUseWithNoArgumentsYieldsEmptyObjectJSON() throws {
        var acc = AnthropicStreamAccumulator()
        _ = try acc.ingest(event(#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"recall","input":{}}}"#))
        #expect(acc.calls.first?.argumentsJSON == "{}")
    }

    @Test func usageJoinsTheInputSplitFromMessageStartWithTheOutputFromMessageDelta() throws {
        var acc = AnthropicStreamAccumulator()
        _ = try acc.ingest(event(#"{"type":"message_start","message":{"usage":{"input_tokens":120,"cache_read_input_tokens":3000,"cache_creation_input_tokens":80,"output_tokens":1}}}"#))
        _ = try acc.ingest(event(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":42}}"#))
        let usage = try #require(acc.usage)
        #expect(usage.promptTokens == 120)
        #expect(usage.cacheReadTokens == 3000)
        #expect(usage.cacheWriteTokens == 80)
        #expect(usage.completionTokens == 42)
        #expect(usage.totalTokens == 120 + 3000 + 80 + 42)
        #expect(abs(usage.cachedShare - 3000.0 / 3200.0) < 0.001)
        #expect(acc.refusal == nil)
    }

    @Test func aRefusalStopReasonIsRecordedWithItsCategory() throws {
        var acc = AnthropicStreamAccumulator()
        _ = try acc.ingest(event(#"{"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"}},"usage":{"output_tokens":0}}"#))
        #expect(acc.refusal?.contains("cyber") == true)
    }

    @Test func anErrorEventThrows() {
        var acc = AnthropicStreamAccumulator()
        #expect(throws: LLMError.self) {
            try acc.ingest(event(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#))
        }
    }
}

@Suite struct OpenAIUsageCacheTests {
    @Test func cachedTokensAreSplitOutOfThePromptCount() {
        let data = Data(#"{"choices":[],"usage":{"prompt_tokens":1000,"completion_tokens":20,"total_tokens":1020,"prompt_tokens_details":{"cached_tokens":900}}}"#.utf8)
        let usage = OpenAICompatibleClient.parseUsage(data)
        #expect(usage?.promptTokens == 100)
        #expect(usage?.cacheReadTokens == 900)
        #expect(usage?.completionTokens == 20)
        #expect(usage.map { abs($0.cachedShare - 0.9) < 0.001 } == true)
    }

    // MARK: JSON by instruction (no `response_format` on the Messages API)

    @Test func theJSONInstructionCarriesTheSchemaWithSortedKeys() {
        let format: [String: Any] = ["type": "json_schema",
                                     "json_schema": ["name": "brief",
                                                     "schema": ["type": "object",
                                                                "properties": ["b": ["type": "string"], "a": ["type": "integer"]]]]]
        let text = AnthropicWire.jsonInstruction(responseFormat: format)
        #expect(text.hasPrefix("Reply with ONLY a single JSON object"))
        #expect(text.contains("\"properties\":{\"a\":{\"type\":\"integer\"},\"b\":{\"type\":\"string\"}}"))
        // The same schema is the same prefix every time, so it can cache.
        #expect(text == AnthropicWire.jsonInstruction(responseFormat: format))
    }

    @Test func aFormatWithoutASchemaStillAsksForBareJSON() {
        let text = AnthropicWire.jsonInstruction(responseFormat: ["type": "json_object"])
        #expect(text == "Reply with ONLY a single JSON object: no prose before or after it, no code fence.")
    }

    @Test func aFencedReplyIsUnwrappedAndABareOneIsOnlyTrimmed() {
        #expect(AnthropicWire.unfenced("```json\n{\"a\": 1}\n```") == "{\"a\": 1}")
        #expect(AnthropicWire.unfenced("```\n{\"a\": 1}\n```\n") == "{\"a\": 1}")
        #expect(AnthropicWire.unfenced("  {\"a\": 1}  ") == "{\"a\": 1}")
        // Backticks inside a value are content, not a fence.
        #expect(AnthropicWire.unfenced("{\"code\": \"```x```\"}") == "{\"code\": \"```x```\"}")
        #expect(AnthropicWire.unfenced("```") == "```")
    }
}
