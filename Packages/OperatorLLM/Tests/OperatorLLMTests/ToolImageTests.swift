import Foundation
import Testing
@testable import OperatorLLM

/// Tool results that carry images (rendered video frames): the loop puts them on the tool message, the
/// Anthropic route puts them inside the `tool_result`, the OpenAI-compatible route (text-only tool
/// messages) puts them in one user turn after the run of results, and old ones are dropped from resends.
@MainActor
@Suite struct ToolImageTests {
    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2])
    private let calls = [LLMToolCall(id: "c1", name: "look_at_frames", argumentsJSON: "{}"),
                         LLMToolCall(id: "c2", name: "get_project", argumentsJSON: "{}")]

    @Test func mediaTypeIsSniffed() {
        #expect(LLMMessage.imageMediaType(jpeg) == "image/jpeg")
        #expect(LLMMessage.imageMediaType(png) == "image/png")
        #expect(LLMMessage.imageMediaType(Data("RIFF0000WEBP".utf8)) == "image/webp")
        #expect(LLMMessage.imageMediaType(Data()) == "image/png")
    }

    @Test func anthropicPutsImagesInsideTheToolResult() throws {
        let body = try AnthropicWire.body(messages: [LLMMessage(.user, "check"),
                                                     LLMMessage(.assistant, "", toolCalls: calls),
                                                     LLMMessage.toolResult("c1", "frames at 1 s", images: [jpeg]),
                                                     LLMMessage.toolResult("c2", "{}")],
                                          model: "m", tools: [], maxTokens: 10)
        let turns = try #require(body["messages"] as? [[String: Any]])
        #expect(turns.map { $0["role"] as? String } == ["user", "assistant", "user"])
        let results = try #require(turns[2]["content"] as? [[String: Any]])
        #expect(results.count == 2)
        let withImage = try #require(results[0]["content"] as? [[String: Any]])
        #expect(withImage.map { $0["type"] as? String } == ["text", "image"])
        let source = try #require(withImage[1]["source"] as? [String: Any])
        #expect(source["media_type"] as? String == "image/jpeg")
        #expect(source["data"] as? String == jpeg.base64EncodedString())
        #expect(results[1]["content"] as? String == "{}", "a text-only result stays a string")
    }

    @Test func openAIFollowsTheToolRunWithOneUserImageTurn() {
        let wire = OpenAICompatibleClient.encodeMessages([LLMMessage(.user, "check"),
                                                          LLMMessage(.assistant, "", toolCalls: calls),
                                                          LLMMessage.toolResult("c1", "frames", images: [jpeg, png]),
                                                          LLMMessage.toolResult("c2", "{}"),
                                                          LLMMessage(.assistant, "done")])
        #expect(wire.map { $0["role"] as? String } == ["user", "assistant", "tool", "tool", "user", "assistant"])
        #expect(wire[2]["content"] as? String == "frames", "tool messages stay text")
        let parts = wire[4]["content"] as? [[String: Any]] ?? []
        #expect(parts.map { $0["type"] as? String } == ["text", "image_url", "image_url"])
        let first = (parts[1]["image_url"] as? [String: Any])?["url"] as? String
        #expect(first?.hasPrefix("data:image/jpeg;base64,") == true)
    }

    @Test func onlyTheMostRecentImageMessagesAreKept() {
        let messages = [LLMMessage.toolResult("a", "old", images: [jpeg]),
                        LLMMessage(.user, "hi"),
                        LLMMessage.toolResult("b", "new", images: [jpeg, jpeg])]
        let kept = LLMMessage.keepingRecentImages(messages, keep: 1)
        #expect(kept[0].images.isEmpty)
        #expect(kept[0].content.contains("omitted"))
        #expect(kept[2].images.count == 2)
        #expect(kept[1] == messages[1])
    }

    @Test func theLoopCarriesImagesOntoTheToolMessageAndStopsWhenOutOfBudget() async throws {
        var rounds: [[LLMMessage]] = []
        let call = LLMToolCall(id: "c1", name: "look_at_frames", argumentsJSON: "{}")
        var calls = 0
        let outcome = try await AgentLoop.run(
            messages: [LLMMessage(.user, "look")], tools: [.noArguments("look_at_frames", "Look.")], maxRounds: 10,
            round: { messages, tools in
                rounds.append(messages)
                return AsyncThrowingStream { continuation in
                    if !tools.isEmpty { continuation.yield(.toolCalls([call])) } else { continuation.yield(.text("ok")) }
                    continuation.finish()
                }
            },
            executeOutput: { [jpeg] _ in calls += 1; return LLMToolOutput("one frame", images: [jpeg]) },
            outOfBudget: { calls >= 2 })
        #expect(outcome.hitBudget)
        #expect(calls == 2, "the budget is checked before each round after the first")
        #expect(outcome.appended[1].images == [jpeg])
        #expect(rounds.last?.last?.images == [jpeg])
    }
}
