import Foundation
import Testing
@testable import OperatorLLM

/// A canned `LLMClient` that replays a fixed list of deltas without touching the
/// network. This is the seam every downstream consumer (e.g. the voice resolvers)
/// injects in its own tests instead of a live client.
struct FakeLLMClient: LLMClient {
    let deltas: [String]
    /// If set, the stream throws this error instead of finishing.
    var failure: LLMError?
    /// Records the last call's arguments so tests can assert on them.
    final class Calls: @unchecked Sendable {
        var lastMessages: [LLMMessage] = []
        var lastModel: String = ""
    }
    let calls = Calls()

    func stream(messages: [LLMMessage], model: String) -> AsyncThrowingStream<String, Error> {
        calls.lastMessages = messages
        calls.lastModel = model
        let deltas = deltas
        let failure = failure
        return AsyncThrowingStream { continuation in
            for delta in deltas { continuation.yield(delta) }
            if let failure {
                continuation.finish(throwing: failure)
            } else {
                continuation.finish()
            }
        }
    }
}

@Suite struct LLMClientFakeTests {

    @Test func completeAccumulatesStreamedDeltas() async throws {
        let client = FakeLLMClient(deltas: ["Hel", "lo, ", "world"])
        let text = try await client.complete(
            messages: [LLMMessage(.user, "hi")],
            model: "fake-model"
        )
        #expect(text == "Hello, world")
    }

    @Test func streamYieldsDeltasInOrder() async throws {
        let client = FakeLLMClient(deltas: ["a", "b", "c"])
        var collected: [String] = []
        for try await delta in client.stream(messages: [], model: "m") {
            collected.append(delta)
        }
        #expect(collected == ["a", "b", "c"])
    }

    @Test func protocolSeamCapturesArguments() async throws {
        let client = FakeLLMClient(deltas: ["ok"])
        _ = try await client.complete(
            messages: [LLMMessage(.system, "sys"), LLMMessage(.user, "u")],
            model: "seam-check"
        )
        #expect(client.calls.lastModel == "seam-check")
        #expect(client.calls.lastMessages.count == 2)
        #expect(client.calls.lastMessages.first?.role == .system)
    }

    @Test func streamErrorPropagatesThroughComplete() async {
        let client = FakeLLMClient(deltas: ["partial"], failure: .missingAPIKey)
        await #expect(throws: LLMError.self) {
            _ = try await client.complete(messages: [], model: "m")
        }
    }
}
