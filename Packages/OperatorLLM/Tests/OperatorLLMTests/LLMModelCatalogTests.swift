import Foundation
import Testing
@testable import OperatorLLM

/// Unit tests for live model discovery against canned `/models` payloads — the
/// three response shapes the four cloud presets actually return. No network.
@Suite struct LLMModelCatalogTests {

    private func data(_ json: String) -> Data { Data(json.utf8) }

    // MARK: Response shapes

    @Test func parsesAnthropicShape() {
        // Anthropic: `data`, `display_name`, ISO-8601 `created_at`.
        let payload = data(#"""
        {"data":[
          {"type":"model","id":"claude-opus-5","display_name":"Claude Opus 5","created_at":"2026-06-01T00:00:00Z"},
          {"type":"model","id":"claude-haiku-4-5","display_name":"Claude Haiku 4.5","created_at":"2025-10-01T00:00:00Z"}
        ],"has_more":false}
        """#)
        let options = LLMModelCatalog.parse(payload)
        #expect(options.count == 2)
        #expect(options.first?.id == "claude-opus-5")
        #expect(options.first?.label == "Claude Opus 5")
    }

    @Test func parsesOpenAIShape() {
        // OpenAI: `data`, no display name, epoch `created`.
        let payload = data(#"""
        {"object":"list","data":[
          {"id":"gpt-5.5","object":"model","created":1750000000,"owned_by":"openai"}
        ]}
        """#)
        let options = LLMModelCatalog.parse(payload)
        #expect(options.count == 1)
        #expect(options.first?.id == "gpt-5.5")
        // Falls back to the id when the provider names nothing.
        #expect(options.first?.label == "gpt-5.5")
    }

    @Test func parsesGeminiShape() {
        // Gemini's native surface: `models`, `name`, `displayName`.
        let payload = data(#"""
        {"models":[
          {"name":"models/gemini-3.5-flash","displayName":"Gemini 3.5 Flash"}
        ]}
        """#)
        let options = LLMModelCatalog.parse(payload)
        #expect(options.count == 1)
        // The resource-name prefix must be stripped — the `model` param wants the bare id.
        #expect(options.first?.id == "gemini-3.5-flash")
        #expect(options.first?.label == "Gemini 3.5 Flash")
    }

    // MARK: Ordering, filtering, robustness

    @Test func sortsDatedEntriesNewestFirst() {
        let payload = data(#"""
        {"data":[
          {"id":"old-model","created":1000},
          {"id":"new-model","created":9000},
          {"id":"mid-model","created":5000}
        ]}
        """#)
        #expect(LLMModelCatalog.parse(payload).map(\.id) == ["new-model", "mid-model", "old-model"])
    }

    @Test func keepsServerOrderWhenNothingIsDated() {
        let payload = data(#"{"data":[{"id":"beta"},{"id":"alpha"},{"id":"gamma"}]}"#)
        #expect(LLMModelCatalog.parse(payload).map(\.id) == ["beta", "alpha", "gamma"])
    }

    @Test func dropsNonChatModels() {
        let payload = data(#"""
        {"data":[
          {"id":"gpt-5.5"},
          {"id":"text-embedding-3-large"},
          {"id":"whisper-1"},
          {"id":"dall-e-3"},
          {"id":"omni-moderation-latest"}
        ]}
        """#)
        #expect(LLMModelCatalog.parse(payload).map(\.id) == ["gpt-5.5"])
    }

    @Test func skipsUnreadableEntriesWithoutFailingTheLoad() {
        // A malformed row must not cost the user the whole catalog.
        let payload = data(#"{"data":[{"id":"good-model"},{"object":"model"},{"id":""}]}"#)
        #expect(LLMModelCatalog.parse(payload).map(\.id) == ["good-model"])
    }

    @Test func dropsDuplicateIDs() {
        let payload = data(#"{"data":[{"id":"m"},{"id":"m"},{"name":"models/m"}]}"#)
        #expect(LLMModelCatalog.parse(payload).count == 1)
    }

    @Test func returnsEmptyForUnrecognizedPayloads() {
        #expect(LLMModelCatalog.parse(data("[]")).isEmpty)
        #expect(LLMModelCatalog.parse(data("not json")).isEmpty)
        #expect(LLMModelCatalog.parse(data(#"{"error":{"message":"bad key"}}"#)).isEmpty)
    }

    // MARK: Request construction

    @Test func anthropicConsoleKeyUsesAPIKeyHeader() throws {
        // sk-ant-api… is a console key: x-api-key, never Bearer, and never both.
        let request = try LLMModelCatalog.makeRequest(
            preset: .anthropic, baseURL: "https://api.anthropic.com/v1", apiKey: "sk-ant-api03-test")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-api03-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        // Default page size is 20; ask for the whole catalog.
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/models?limit=100")
    }

    @Test func anthropicOAuthTokenUsesBearerAndTheOAuthBeta() throws {
        // sk-ant-oat… comes from `ant auth login` / a Claude subscription. Sending it as x-api-key
        // returns 401 "invalid x-api-key" — the exact bug this pair of tests pins down.
        let request = try LLMModelCatalog.makeRequest(
            preset: .anthropic, baseURL: "https://api.anthropic.com/v1", apiKey: "sk-ant-oat01-test")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-ant-oat01-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    }

    @Test func alternateAuthFlipsBothDirections() throws {
        // A prefix is a convention, not a contract — the 401 retry must work either way round.
        let consoleRetry = try LLMModelCatalog.makeRequest(
            preset: .anthropic, baseURL: "https://api.anthropic.com/v1",
            apiKey: "sk-ant-api03-test", forceAlternateAuth: true)
        #expect(consoleRetry.value(forHTTPHeaderField: "Authorization") == "Bearer sk-ant-api03-test")
        #expect(consoleRetry.value(forHTTPHeaderField: "x-api-key") == nil)

        let oauthRetry = try LLMModelCatalog.makeRequest(
            preset: .anthropic, baseURL: "https://api.anthropic.com/v1",
            apiKey: "sk-ant-oat01-test", forceAlternateAuth: true)
        #expect(oauthRetry.value(forHTTPHeaderField: "x-api-key") == "sk-ant-oat01-test")
        #expect(oauthRetry.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func unrecognizedAnthropicKeyPrefixDefaultsToAPIKeyThenRetriesBearer() throws {
        // An unknown shape must still be tried both ways rather than failing on the first guess.
        let first = try LLMModelCatalog.makeRequest(
            preset: .anthropic, baseURL: "https://api.anthropic.com/v1", apiKey: "mystery-key")
        #expect(first.value(forHTTPHeaderField: "x-api-key") == "mystery-key")
        let second = try LLMModelCatalog.makeRequest(
            preset: .anthropic, baseURL: "https://api.anthropic.com/v1",
            apiKey: "mystery-key", forceAlternateAuth: true)
        #expect(second.value(forHTTPHeaderField: "Authorization") == "Bearer mystery-key")
    }

    @Test func otherProvidersUseBearer() throws {
        let request = try LLMModelCatalog.makeRequest(
            preset: .openai, baseURL: "https://api.openai.com/v1", apiKey: "sk-test")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/models")
    }

    @Test func toleratesTrailingSlashInBaseURL() throws {
        let request = try LLMModelCatalog.makeRequest(
            preset: .custom, baseURL: "  https://host/v1/  ", apiKey: "k")
        #expect(request.url?.absoluteString == "https://host/v1/models")
    }

    @Test func rejectsEmptyBaseURL() {
        #expect(throws: LLMError.self) {
            try LLMModelCatalog.makeRequest(preset: .custom, baseURL: "   ", apiKey: "k")
        }
    }

    // MARK: Fallback behaviour

    @Test func fallsBackToCuratedListUntilSomethingLoads() {
        let curated = LLMModelCatalog.options(loaded: [], preset: .anthropic)
        #expect(curated.map(\.id) == LLMProviderPreset.anthropic.modelSuggestions.map(\.id))
        #expect(!curated.isEmpty)

        let live = [LLMModelOption(id: "live-model", label: "Live")]
        #expect(LLMModelCatalog.options(loaded: live, preset: .anthropic) == live)
    }

    // MARK: Precedence — live fetch > cron seed > built-in

    @Test func cronSeedOverridesTheBuiltInList() {
        // `.custom` has no built-in suggestions, so this can't collide with another
        // test's preset while still proving the seed is consulted.
        #expect(LLMModelCatalog.options(loaded: [], preset: .custom).isEmpty)

        let seeded = [LLMModelOption(id: "seeded-model", label: "Seeded")]
        LLMModelCatalog.applyRemote(["custom": seeded])

        #expect(LLMModelCatalog.hasRemoteSeed(for: .custom))
        #expect(LLMModelCatalog.options(loaded: [], preset: .custom) == seeded)

        // A live per-user fetch still outranks the seed.
        let live = [LLMModelOption(id: "live-model", label: "Live")]
        #expect(LLMModelCatalog.options(loaded: live, preset: .custom) == live)
    }

    @Test func emptySeedIsIgnoredRatherThanEmptyingTheMenu() {
        // A malformed publish must degrade to the built-in list, never to a blank menu.
        LLMModelCatalog.applyRemote(["gemini": []])
        #expect(!LLMModelCatalog.hasRemoteSeed(for: .gemini))
        #expect(LLMModelCatalog.options(loaded: [], preset: .gemini).map(\.id)
                == LLMProviderPreset.gemini.modelSuggestions.map(\.id))
    }

    @Test func onDeviceHasNoCatalogToLoad() async {
        await #expect(throws: LLMError.self) {
            try await LLMModelCatalog.fetch(preset: .onDevice, baseURL: "", apiKey: "k")
        }
    }

    @Test func fetchRequiresAKey() async {
        await #expect(throws: LLMError.self) {
            try await LLMModelCatalog.fetch(
                preset: .anthropic, baseURL: "https://api.anthropic.com/v1", apiKey: "")
        }
    }

    // MARK: The curated fallback itself

    // MARK: OpenRouter preset

    @Test func openRouterIsAGatewayPresetWithVendorPrefixedIDs() {
        // The point of this preset: its ids are OpenRouter slugs, which is exactly what the browsable
        // model catalog carries. Every other preset needs the prefix STRIPPED (see normalizeForVendor
        // in the cron ingest); here the prefix is correct and must survive.
        let ids = LLMProviderPreset.openrouter.modelSuggestions.map(\.id)
        #expect(ids.contains("anthropic/claude-opus-5"))
        #expect(ids.allSatisfy { $0.contains("/") })
        #expect(LLMProviderPreset.openrouter.defaultBaseURL == "https://openrouter.ai/api/v1")
        // Auto first — routing server-side is the reason to bring one key instead of four.
        #expect(LLMProviderPreset.openrouter.defaultModelId == "openrouter/auto-beta")
    }

    @Test func openRouterRouterSlugsMatchTheModelCatalog() {
        // OperatorLLM has no dependencies, so `OpenRouterRouting`'s slugs are repeated here rather
        // than imported. That duplication is only safe if something fails when they drift — this is
        // that something. Values mirror OperatorModels/ModelInfo.swift.
        let ids = LLMProviderPreset.openrouter.modelSuggestions.map(\.id)
        #expect(ids.contains("openrouter/auto-beta"))     // OpenRouterRouting.autoSlug
        #expect(ids.contains("openrouter/pareto-code"))   // OpenRouterRouting.paretoSlug
    }

    @Test func everyKeyedPresetHasAKeyHintAndAWayToGetOne() {
        // A new preset that forgets these ships a key field with no placeholder and no "Get a key"
        // link — the two things that make BYOK setup possible without leaving the app.
        for preset in LLMProviderPreset.allCases where preset.requiresAPIKey && preset != .custom {
            #expect(preset.getKeyURL?.isEmpty == false, "\(preset.rawValue) has no getKeyURL")
            #expect(preset.keyHint != "API key", "\(preset.rawValue) has the generic key hint")
            #expect(preset.defaultBaseURL?.isEmpty == false, "\(preset.rawValue) has no base URL")
        }
    }

    // MARK: Cursor

    @Test func parsesCursorShape() {
        // Cursor: `items`, `displayName`, plus per-model parameters/variants we ignore — one row per
        // model id is the menu, and the id is what `--model` takes.
        let payload = data(#"""
        {"items":[
          {"id":"composer-2","displayName":"Composer 2","aliases":["composer-latest"],
           "parameters":[{"id":"fast","displayName":"Fast","values":[{"value":"true"}]}]},
          {"id":"claude-opus-5","displayName":"Claude Opus 5"},
          {"id":"gpt-image-1"},
          {"id":"composer-2"}
        ]}
        """#)
        let options = LLMModelCatalog.parseCursor(payload)
        #expect(options.map(\.id) == ["composer-2", "claude-opus-5"], "non-chat and duplicates drop out")
        #expect(options.first?.label == "Composer 2")
    }

    @Test func cursorRosterBeatsTheSeedWhichBeatsTheFallback() {
        let fallback = [(label: "Fallback", id: "fallback")]
        // Nothing loaded, nothing seeded → the built-in list.
        #expect(LLMModelCatalog.options(loaded: [], key: "cursor-test", fallback: fallback).map(\.id)
                == ["fallback"])
        // A published seed wins over the binary…
        LLMModelCatalog.applyRemote(["cursor-test": [LLMModelOption(id: "seeded", label: "Seeded")]])
        #expect(LLMModelCatalog.options(loaded: [], key: "cursor-test", fallback: fallback).map(\.id)
                == ["seeded"])
        // …and this account's own roster wins over both.
        let loaded = [LLMModelOption(id: "composer-2", label: "Composer 2")]
        #expect(LLMModelCatalog.options(loaded: loaded, key: "cursor-test", fallback: fallback).map(\.id)
                == ["composer-2"])
    }

    @Test func curatedAnthropicListLeadsWithCurrentOpus() {
        // `defaultModelId` is `modelSuggestions.first`, so ordering here picks the
        // default model for anyone newly switching to Anthropic.
        #expect(LLMProviderPreset.anthropic.defaultModelId == "claude-opus-5-5")
        let ids = LLMProviderPreset.anthropic.modelSuggestions.map(\.id)
        #expect(ids.contains("claude-sonnet-5-5"))
        // Every curated id must survive the chat filter, or it would vanish from the
        // menu the moment a live load fails back to it.
        #expect(ids.allSatisfy(LLMModelCatalog.isChatModel))
    }
}
