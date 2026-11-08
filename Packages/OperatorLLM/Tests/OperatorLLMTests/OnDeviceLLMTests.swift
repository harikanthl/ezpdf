import Foundation
import Testing
@testable import OperatorLLM

#if canImport(FoundationModels)
import FoundationModels

/// A tiny consumer-defined schema — the whole point of the thin extract is that
/// each caller declares its own @Generable type; OperatorLLM ships none.
@available(macOS 26.0, iOS 26.0, *)
@Generable
struct SmokeTestAnswer {
    @Guide(description: "A single lowercase word")
    var word: String
}
#endif

@Suite struct OnDeviceLLMTests {

    /// Availability probe is prompt-free and always answerable, on any hardware.
    @Test func availabilityIsQueryableWithoutCrashing() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            // Reading these must never trap, regardless of hardware/CI.
            let available = OnDeviceLLM.isAvailable
            // When unavailable there must be a reason string, and vice-versa.
            #expect(available == (OnDeviceLLM.availabilityMessage == nil))
        }
        #else
        #expect(OnDeviceLLM.isAvailable == false)
        #endif
    }

    /// @Generable round-trip. Skips cleanly (returns) when the on-device model
    /// isn't available — non-AI hardware and CI hit this path and still pass.
    @available(macOS 26.0, iOS 26.0, *)
    @Test func generableRoundTripSmokeTest() async throws {
        #if canImport(FoundationModels)
        guard OnDeviceLLM.isAvailable else {
            // Skip cleanly: nothing to exercise without the model.
            return
        }
        let llm = OnDeviceLLM(instructions: "Answer with exactly one lowercase word.")
        let answer: SmokeTestAnswer = try await llm.generate(
            prompt: "What is the opposite of 'up'? Reply with one word."
        )
        #expect(!answer.word.isEmpty)
        #else
        // No FoundationModels on this platform — nothing to smoke-test.
        #endif
    }
}
