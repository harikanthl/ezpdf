import Foundation
import Testing
@testable import OperatorLLM

/// Unit tests for the OpenAI-compatible SSE chunk parser against canned event
/// payloads. These exercise `parseDelta`/`parseUsage` directly (no network) — the
/// same JSON shapes the streaming loop feeds them line by line.
@Suite struct SSEParserTests {

    private func data(_ json: String) -> Data { Data(json.utf8) }

    // MARK: parseDelta

    @Test func parsesDeltaContentShape() {
        let chunk = data(#"{"choices":[{"index":0,"delta":{"content":"Hello"}}]}"#)
        #expect(OpenAICompatibleClient.parseDelta(chunk) == "Hello")
    }

    @Test func parsesMessageContentShape() {
        // Some gateways send the final token under "message" instead of "delta".
        let chunk = data(#"{"choices":[{"index":0,"message":{"content":"Done"}}]}"#)
        #expect(OpenAICompatibleClient.parseDelta(chunk) == "Done")
    }

    @Test func emptyDeltaContentYieldsNil() {
        let chunk = data(#"{"choices":[{"delta":{"content":""}}]}"#)
        #expect(OpenAICompatibleClient.parseDelta(chunk) == nil)
    }

    @Test func roleOnlyOpeningChunkYieldsNil() {
        // The first streamed chunk usually carries only the assistant role.
        let chunk = data(#"{"choices":[{"delta":{"role":"assistant"}}]}"#)
        #expect(OpenAICompatibleClient.parseDelta(chunk) == nil)
    }

    @Test func usageOnlyChunkHasNoDelta() {
        let chunk = data(#"{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}"#)
        #expect(OpenAICompatibleClient.parseDelta(chunk) == nil)
    }

    // MARK: parseUsage

    @Test func parsesUsageFrame() {
        let chunk = data(#"{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}"#)
        let usage = OpenAICompatibleClient.parseUsage(chunk)
        #expect(usage == Usage(promptTokens: 10, completionTokens: 5, totalTokens: 15))
    }

    @Test func parsesPartialUsageFrame() {
        // Missing fields default to 0 rather than failing the whole frame.
        let chunk = data(#"{"usage":{"total_tokens":42}}"#)
        let usage = OpenAICompatibleClient.parseUsage(chunk)
        #expect(usage == Usage(promptTokens: 0, completionTokens: 0, totalTokens: 42))
    }

    @Test func contentChunkHasNoUsage() {
        let chunk = data(#"{"choices":[{"delta":{"content":"Hi"}}]}"#)
        #expect(OpenAICompatibleClient.parseUsage(chunk) == nil)
    }

    // MARK: malformed input

    @Test func malformedJSONIsRejected() {
        let broken = data(#"{"choices":[{"delta":{"content":"#)   // truncated, invalid JSON
        #expect(OpenAICompatibleClient.parseDelta(broken) == nil)
        #expect(OpenAICompatibleClient.parseUsage(broken) == nil)
    }

    @Test func nonObjectJSONIsRejected() {
        let arrayJSON = data(#"[1,2,3]"#)
        #expect(OpenAICompatibleClient.parseDelta(arrayJSON) == nil)
        #expect(OpenAICompatibleClient.parseUsage(arrayJSON) == nil)
    }

    @Test func emptyDataIsRejected() {
        #expect(OpenAICompatibleClient.parseDelta(Data()) == nil)
        #expect(OpenAICompatibleClient.parseUsage(Data()) == nil)
    }
}
