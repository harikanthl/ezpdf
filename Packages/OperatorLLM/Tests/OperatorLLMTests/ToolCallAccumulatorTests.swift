import Foundation
import Testing
@testable import OperatorLLM

/// Reassembling OpenAI's fragmented `delta.tool_calls`. This is the one part of tool calling that
/// fails SILENTLY when it is wrong: a truncated argument string still parses (to `[:]`), so the tool
/// runs with no arguments and the model is told something plausible and false.
@Suite struct ToolCallAccumulatorTests {

    private func chunk(_ json: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    @Test func argumentsSplitAcrossChunksAreJoinedInOrder() {
        var acc = ToolCallAccumulator()
        acc.ingest(chunk(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read_document","arguments":"{\"file"}}]}}]}"#))
        acc.ingest(chunk(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"name\":\"net"}}]}}]}"#))
        acc.ingest(chunk(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"work.md\"}"}}]}}]}"#))
        let calls = acc.calls
        #expect(calls.count == 1)
        #expect(calls[0].id == "call_1")
        #expect(calls[0].name == "read_document")
        #expect(calls[0].string("filename") == "network.md")
    }

    @Test func twoParallelCallsKeepTheirOwnArgumentsAndOrder() {
        var acc = ToolCallAccumulator()
        acc.ingest(chunk(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"read_document","arguments":"{\"filename\":\"one.md\"}"}},{"index":1,"id":"b","function":{"name":"session_status","arguments":"{}"}}]}}]}"#))
        let calls = acc.calls
        #expect(calls.map(\.id) == ["a", "b"])
        #expect(calls[0].string("filename") == "one.md")
        #expect(calls[1].name == "session_status")
    }

    /// A gateway that sends the whole thing at once under `message` rather than `delta`.
    @Test func aNonStreamingShapeIsUnderstoodToo() {
        var acc = ToolCallAccumulator()
        acc.ingest(chunk(#"{"choices":[{"message":{"tool_calls":[{"index":0,"id":"z","function":{"name":"recall","arguments":"{\"query\":\"wifi\"}"}}]}}]}"#))
        #expect(acc.calls.first?.string("query") == "wifi")
    }

    /// Some gateways omit the id on a single call. Dropping it would lose the call; the result
    /// message needs SOMETHING to join on, so one is synthesised.
    @Test func aMissingIdIsSynthesisedRatherThanDroppingTheCall() {
        var acc = ToolCallAccumulator()
        acc.ingest(chunk(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"session_status","arguments":"{}"}}]}}]}"#))
        #expect(acc.calls.count == 1)
        #expect(acc.calls[0].id == "call_0")
    }

    @Test func fragmentsWithNoNameAreNotCalls() {
        var acc = ToolCallAccumulator()
        acc.ingest(chunk(#"{"choices":[{"delta":{"content":"just talking"}}]}"#))
        acc.ingest(chunk(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{}"}}]}}]}"#))
        #expect(acc.calls.isEmpty)
        #expect(!acc.isEmpty, "a fragment was seen; it just never became a call")
    }

    @Test func plainTextChunksLeaveItEmpty() {
        var acc = ToolCallAccumulator()
        acc.ingest(chunk(#"{"choices":[{"delta":{"content":"hello"}}]}"#))
        acc.ingest(chunk(#"{"usage":{"total_tokens":9}}"#))
        #expect(acc.isEmpty)
        #expect(acc.calls.isEmpty)
    }

    // MARK: Argument reading

    @Test func argumentsAreReadLenientlyBecauseModelsAreNot() {
        let call = LLMToolCall(id: "1", name: "t",
                               argumentsJSON: #"{"filename":"  a.md  ","n":"3","m":4}"#)
        #expect(call.string("filename") == "a.md", "trimmed")
        #expect(call.int("n") == 3, "a numeric string is a number")
        #expect(call.int("m") == 4)
        #expect(call.string("missing") == nil)
        // A no-argument tool called with "" or "null" is normal, not an error.
        #expect(LLMToolCall(id: "1", name: "t", argumentsJSON: "").arguments.isEmpty)
        #expect(LLMToolCall(id: "1", name: "t", argumentsJSON: "null").arguments.isEmpty)
        // A blank string argument is the same as absent.
        #expect(LLMToolCall(id: "1", name: "t", argumentsJSON: #"{"q":"   "}"#).string("q") == nil)
    }

    // MARK: The spec's wire form

    @Test func aSpecEncodesAsOpenAIsFunctionShape() throws {
        let spec = LLMToolSpec(name: "read_document", description: "Read a file.",
                               parametersJSON: #"{"type":"object","properties":{"filename":{"type":"string"}}}"#)
        let wire = try spec.wireForm()
        #expect(wire["type"] as? String == "function")
        let function = try #require(wire["function"] as? [String: Any])
        #expect(function["name"] as? String == "read_document")
        #expect((function["parameters"] as? [String: Any])?["type"] as? String == "object")
    }

    /// A malformed schema is a programming error and fails the request, rather than silently
    /// encoding as `{}` and shipping a tool the model cannot call correctly.
    @Test func aMalformedSchemaThrowsRatherThanEncodingEmpty() {
        let bad = LLMToolSpec(name: "x", description: "y", parametersJSON: "not json")
        #expect(throws: LLMError.self) { try bad.wireForm() }
    }

    @Test func theNoArgumentHelperIsAValidEmptyObjectSchema() throws {
        let spec = LLMToolSpec.noArguments("session_status", "What is running.")
        let function = try #require(try spec.wireForm()["function"] as? [String: Any])
        let parameters = try #require(function["parameters"] as? [String: Any])
        #expect(parameters["type"] as? String == "object")
        #expect((parameters["properties"] as? [String: Any])?.isEmpty == true)
    }
}
