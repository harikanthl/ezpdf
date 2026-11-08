import Foundation
import Testing
@testable import OperatorLLM

/// The two defaults a provider has, and why they must stay two (found 2026-09-05, when a Claude
/// subscription key that could not use Opus failed "Test connection" AND the chat, while the fast
/// model the chat would have used on a blank field was fine — the settings screen had written the
/// flagship into the field on provider change).
@Suite struct ProviderDefaultsTests {

    /// The fast default is what a BLANK model field means for the chat and for "Test connection".
    /// It is never the flagship, on any provider that has one.
    @Test func theFastDefaultIsNeverTheFlagship() {
        for preset in [LLMProviderPreset.anthropic, .openai, .gemini, .openrouter] {
            let fast = preset.fastModelId
            #expect(!fast.isEmpty, "\(preset) needs a fast default")
            #expect(fast != preset.defaultModelId,
                    "\(preset): the chat's blank-field model must not be the quality default")
        }
        #expect(LLMProviderPreset.anthropic.fastModelId == "claude-haiku-5-5")
        // Direct chat is latency-sensitive: a concrete cheap model, never the Auto router.
        #expect(LLMProviderPreset.openrouter.fastModelId == "anthropic/claude-haiku-4-5")
    }

    /// Providers with no meaningful "fast vs flagship" split answer the same model for both, so a
    /// blank field on them means exactly what it always did.
    @Test func providersWithoutASplitInheritTheirDefault() {
        for preset in [LLMProviderPreset.onDevice, .custom, .thisMac] {
            #expect(preset.fastModelId == preset.defaultModelId)
        }
    }

    /// The quality default is still the flagship — the suggestion menu leads with it and quality jobs
    /// fall back to it. This test exists so nobody "fixes" the chat bug by demoting the flagship.
    @Test func theQualityDefaultIsStillTheFlagship() {
        #expect(LLMProviderPreset.anthropic.defaultModelId == "claude-opus-5-5")
    }

    // MARK: Anthropic's second credential shape reaches the chat client

    /// A Claude subscription / `ant auth login` token is an OAuth token, and Anthropic reads a plain
    /// `Bearer` as a console key — "Invalid Anthropic API Key", before any model is considered. The
    /// model-list request has carried the beta header for that shape since it existed; the chat
    /// client now does too. Keyed on the prefix only Anthropic mints.
    @Test func anOAuthShapedKeyCarriesTheBetaHeader() throws {
        let oauth = OpenAICompatibleClient(baseURL: "https://api.anthropic.com/v1", apiKey: "sk-ant-oat01-example")
        let request = try oauth.makeRequest(messages: [LLMMessage(.user, "ok")], model: "claude-haiku-4-5")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-ant-oat01-example")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/chat/completions")
    }

    /// A console key, and every other provider's key, is a plain Bearer with no beta header — an
    /// unknown header is ignored by other gateways, but it is not ours to send where it means nothing.
    @Test func aConsoleKeyStaysAPlainBearer() throws {
        for (base, key) in [("https://api.anthropic.com/v1", "sk-ant-api03-example"),
                            ("https://openrouter.ai/api/v1", "sk-or-v1-example"),
                            ("https://api.openai.com/v1", "sk-proj-example")] {
            let client = OpenAICompatibleClient(baseURL: base, apiKey: key)
            let request = try client.makeRequest(messages: [LLMMessage(.user, "ok")], model: "m")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)")
            #expect(request.value(forHTTPHeaderField: "anthropic-beta") == nil, "\(base)")
        }
    }
}
