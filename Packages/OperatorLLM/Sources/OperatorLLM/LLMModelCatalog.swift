//
//  LLMModelCatalog.swift
//  OperatorLLM
//
//  Live model discovery — `GET {baseURL}/models` against whichever provider the
//  user configured, using their own key.
//
//  This exists because `LLMProviderPreset.modelSuggestions` is a hand-written
//  array, and a hand-written array of model IDs is wrong the moment a provider
//  ships something new. The curated list stays as the offline fallback (shown
//  before any key is entered, and when a fetch fails); this makes it possible to
//  replace it with what the provider actually serves today.
//
//  Deliberately NOT the OpenRouter catalog in OperatorModels: `ModelInfo.id` is an
//  OpenRouter slug ("anthropic/claude-opus-4.8") bound for OpenRouter's gateway,
//  while `LLMProviderSettings.modelId` goes straight to the provider's own API,
//  which 404s on a vendor-prefixed slug. Same words, different namespaces.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // Linux keeps URLSession in its own module.
#endif
import Synchronization

/// One selectable model from a provider's catalog.
public struct LLMModelOption: Identifiable, Sendable, Hashable, Codable {
    /// The exact string to send as the `model` parameter.
    public let id: String
    /// Human label for the menu. Falls back to `id` when the provider names nothing.
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public enum LLMModelCatalog {

    // MARK: Fetch

    /// Ask the provider what it serves. Throws `LLMError` on every failure path so
    /// callers can surface `errorDescription` directly.
    public static func fetch(preset: LLMProviderPreset,
                             baseURL: String,
                             apiKey: String,
                             session: URLSession = .shared) async throws -> [LLMModelOption] {
        guard preset.supportsModelListing else {
            throw LLMError.unavailable("\(preset.displayName) has no model catalog to load.")
        }
        // A provider that takes no key (the Mac's own Ollama) lists without one; refusing an empty key
        // there would make "Load models" unreachable for exactly the provider whose list is the only
        // way to know what to type.
        guard !apiKey.isEmpty || !preset.requiresAPIKey else { throw LLMError.missingAPIKey }

        var request = try makeRequest(preset: preset, baseURL: baseURL, apiKey: apiKey)
        var (data, response) = try await session.data(for: request)

        // Anthropic has TWO credential shapes and picking wrong is a 401, not a hint. We guess from
        // the key prefix; if the guess was wrong, swap and retry once. A prefix is a convention, not
        // a contract, so the retry is what actually makes this correct.
        if preset == .anthropic, (response as? HTTPURLResponse)?.statusCode == 401 {
            request = try makeRequest(preset: preset, baseURL: baseURL, apiKey: apiKey,
                                      forceAlternateAuth: true)
            (data, response) = try await session.data(for: request)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LLMError.http(status: http.statusCode,
                                body: String(decoding: data, as: UTF8.self))
        }

        let options = parse(data)
        guard !options.isEmpty else {
            throw LLMError.decoding("the provider listed no chat models.")
        }
        return options
    }

    /// What the model menu should show, in precedence order:
    ///
    ///   1. `loaded` — this user's own provider, fetched with this user's own key.
    ///      Always the truth when present.
    ///   2. the cron seed — `providerModels` from the catalog KV, refreshed every
    ///      6h by CatalogWorker. Keeps the menu current between app releases.
    ///   3. `modelSuggestions` — the built-in list compiled into the app. Only
    ///      reached offline, before a first catalog fetch.
    ///
    /// Both platforms call this, so the two pickers cannot drift apart — which is
    /// exactly how the stale-list bug got in.
    public static func options(loaded: [LLMModelOption],
                               preset: LLMProviderPreset) -> [LLMModelOption] {
        guard loaded.isEmpty else { return loaded }
        if let seeded = remoteSeed.withLock({ $0[preset.rawValue] }), !seeded.isEmpty {
            return seeded
        }
        return preset.modelSuggestions.map { LLMModelOption(id: $0.id, label: $0.label) }
    }

    /// The options a VOICE model picker should offer, fastest-looking first.
    ///
    /// Voice is latency-bound, so the ordering is the whole point: a menu that leads with the
    /// frontier model invites the choice that makes every spoken command slow. Ranked by name — the
    /// catalog carries no latency figure, and `mini`/`flash`/`lite`/`haiku` is what providers
    /// actually call their fast tiers.
    public static func voiceOptions(loaded: [LLMModelOption],
                                    preset: LLMProviderPreset) -> [LLMModelOption] {
        let all = options(loaded: loaded, preset: preset)
        let fastMarkers = ["haiku", "mini", "nano", "flash", "lite", "small", "turbo", "fast"]
        let fast = all.filter { option in
            let id = option.id.lowercased()
            return fastMarkers.contains { id.contains($0) }
        }
        // Stable partition, not a sort: within each half the catalog's own order (newest first) holds.
        return fast + all.filter { !fast.contains($0) }
    }

    /// Install the cron-published seed, keyed by `LLMProviderPreset.rawValue`. Called
    /// by the app layer whenever the catalog mirror refreshes.
    ///
    /// This package deliberately has no dependencies, so it can't reach the mirror
    /// itself — the seed is pushed in, never pulled. Empty lists are ignored so a
    /// malformed publish degrades to the built-in list rather than an empty menu.
    public static func applyRemote(_ lists: [String: [LLMModelOption]]) {
        remoteSeed.withLock { store in
            for (preset, rows) in lists where !rows.isEmpty {
                store[preset] = rows
            }
        }
    }

    /// Drop every installed seed. **Tests only**, and it exists because `applyRemote` deliberately
    /// ignores empty lists (a malformed publish must degrade to the built-in list, not to an empty
    /// menu) — which leaves a test that seeds a REAL key no way to put the catalog back. Existing
    /// tests dodged that by seeding invented keys; a test that has to assert an agent's own key
    /// reads its seed cannot, so it resets instead of leaking a sentinel into every later test.
    public static func resetRemoteSeedForTesting() {
        remoteSeed.withLock { $0.removeAll() }
    }

    /// Whether a cron seed has been installed for this preset (diagnostics/tests).
    public static func hasRemoteSeed(for preset: LLMProviderPreset) -> Bool {
        remoteSeed.withLock { $0[preset.rawValue]?.isEmpty == false }
    }

    /// The cron seed under an ARBITRARY key, for model lists that aren't provider presets.
    ///
    /// The agent model pickers (`WorkerExtras`) key off agent ids — `glm`, `kimi`, `grok` — which
    /// have no `LLMProviderPreset` because they are backends a CLI rides, not BYOK providers Operator
    /// talks to. They were hand-written arrays, which is precisely the thing that went months stale
    /// and started this work; the cron publishes them under these keys so they can't.
    ///
    /// Returns [] when the catalog has never been fetched, so callers keep their built-in list.
    public static func seeded(key: String) -> [LLMModelOption] {
        remoteSeed.withLock { $0[key] ?? [] }
    }

    /// A seeded list under `key`, else the supplied fallback. The one-liner every agent picker wants.
    public static func options(key: String, fallback: [(label: String, id: String)]) -> [LLMModelOption] {
        let seeded = seeded(key: key)
        guard seeded.isEmpty else { return seeded }
        return fallback.map { LLMModelOption(id: $0.id, label: $0.label) }
    }

    /// The same three-step precedence as `options(loaded:preset:)`, for a list keyed by AGENT id
    /// rather than by BYOK preset: this user's own fetch wins, then the cron seed, then the built-in
    /// fallback. Cursor is the caller that needs all three — its roster is per-account.
    public static func options(loaded: [LLMModelOption], key: String,
                               fallback: [(label: String, id: String)]) -> [LLMModelOption] {
        guard loaded.isEmpty else { return loaded }
        return options(key: key, fallback: fallback)
    }

    // MARK: Cursor

    /// Cursor's roster, asked of Cursor with the user's own key.
    ///
    /// Cursor is the one agent whose model list CANNOT be published by the catalog cron: the roster is
    /// per ACCOUNT (plan and pool decide what a key may address), and `cursor-agent --list-models` runs
    /// inside a box the phone doesn't have. So this is the same "ask the provider with the user's key"
    /// road `fetch(preset:…)` takes for BYOK providers, against Cursor's documented models endpoint.
    ///
    /// Auth is HTTP Basic with the key as the USERNAME and an empty password (`curl -u KEY:`), which is
    /// what Cursor's API reference specifies — not a bearer token. The response is Cursor's own shape,
    /// `{"items":[{"id","displayName"}]}`, so it does not go through `parse`.
    public static func fetchCursorModels(apiKey: String,
                                         session: URLSession = .shared) async throws -> [LLMModelOption] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw LLMError.missingAPIKey }
        guard let url = URL(string: "https://api.cursor.com/v1/models") else { throw LLMError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let basic = Data("\(key):".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LLMError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return parseCursor(data)
    }

    /// DeepSeek's roster, asked of DeepSeek with the user's own key.
    ///
    /// NOT published by the catalog cron, and that is a decision rather than an omission. The cron
    /// derives every other backend's list from OpenRouter, but OpenRouter's `deepseek/` slugs strip to
    /// ids api.deepseek.com does not accept — its own API names models `deepseek-flash` and
    /// `deepseek-v4-pro`, and Operator pins that id into the claude CLI against DeepSeek's
    /// Anthropic-compatible endpoint. A near-miss there is worse than a missing row: the user picks a
    /// model that 404s at spawn. DeepSeek publishes `/models`, so we ask it directly instead.
    ///
    /// OpenAI-shaped (`{"data":[{"id":…}]}`), so the generic `parse` handles it.
    public static func fetchDeepSeekModels(apiKey: String,
                                           session: URLSession = .shared) async throws -> [LLMModelOption] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw LLMError.missingAPIKey }
        guard let url = URL(string: "https://api.deepseek.com/models") else { throw LLMError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LLMError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return parse(data)
    }

    /// `{"items":[{"id":"composer-2","displayName":"Composer 2","aliases":[…]}]}`. Aliases and the
    /// per-model `parameters`/`variants` are deliberately ignored: what the picker pins is the id the
    /// CLI's `--model` takes, and one row per model is the menu someone wants.
    static func parseCursor(_ data: Data) -> [LLMModelOption] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        return items.compactMap { entry in
            guard let raw = entry["id"] as? String else { return nil }
            let id = raw.trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, isChatModel(id), seen.insert(id).inserted else { return nil }
            let label = (entry["displayName"] as? String)?.trimmingCharacters(in: .whitespaces)
            return LLMModelOption(id: id, label: (label?.isEmpty == false) ? label! : id)
        }
    }

    private static let remoteSeed = Mutex<[String: [LLMModelOption]]>([:])

    // MARK: Request

    /// `forceAlternateAuth` flips Anthropic to the *other* credential shape after a 401 (see `fetch`).
    static func makeRequest(preset: LLMProviderPreset,
                            baseURL: String,
                            apiKey: String,
                            forceAlternateAuth: Bool = false) throws -> URLRequest {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Anthropic's catalog pages at 20 by default and we want the whole thing in
        // one call; the OpenAI-compatible gateways ignore unknown query items anyway,
        // but there's no reason to send it where it means nothing.
        let path = preset == .anthropic ? "/models?limit=100" : "/models"
        guard !trimmed.isEmpty, let url = URL(string: trimmed + path) else {
            throw LLMError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard preset == .anthropic else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            return request
        }

        // Anthropic accepts two credential shapes, and they are NOT interchangeable — sending the
        // wrong one is a flat 401 "invalid x-api-key":
        //
        //   sk-ant-api…  console API key   → x-api-key
        //   sk-ant-oat…  OAuth token       → Authorization: Bearer + anthropic-beta: oauth-2025-04-20
        //                (`ant auth login`, or a Claude subscription)
        //
        // Never send both: the API rejects two competing credentials. `anthropic-version` is
        // required either way.
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let looksOAuth = apiKey.hasPrefix("sk-ant-oat")
        if looksOAuth != forceAlternateAuth {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        } else {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        return request
    }

    // MARK: Parsing

    /// Lenient by design: three providers, three response shapes, and a "custom"
    /// preset that can be any gateway at all. Anything unreadable is skipped rather
    /// than failing the whole load.
    static func parse(_ data: Data) -> [LLMModelOption] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        // OpenAI, Anthropic and the compat gateways return `data`; Gemini's native
        // surface returns `models`.
        let entries = (root["data"] as? [[String: Any]])
            ?? (root["models"] as? [[String: Any]])
            ?? []

        var seen = Set<String>()
        var rows: [(option: LLMModelOption, sort: Double)] = []
        for entry in entries {
            guard let raw = (entry["id"] as? String) ?? (entry["name"] as? String) else { continue }
            let id = normalizeID(raw)
            guard !id.isEmpty, isChatModel(id), seen.insert(id).inserted else { continue }
            let label = (entry["display_name"] as? String)
                ?? (entry["displayName"] as? String)
                ?? id
            rows.append((LLMModelOption(id: id, label: label), createdAt(entry)))
        }

        // Newest first where the provider dates its entries; otherwise leave the
        // server's own ordering, which is usually already meaningful.
        if rows.contains(where: { $0.sort > 0 }) {
            rows.sort { $0.sort > $1.sort }
        }
        return rows.map(\.option)
    }

    /// Gemini returns fully-qualified resource names ("models/gemini-2.5-pro"); the
    /// `model` parameter wants the bare id.
    static func normalizeID(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("models/") else { return trimmed }
        return String(trimmed.dropFirst("models/".count))
    }

    /// A provider's `/models` is its *whole* inventory — embeddings, speech, image
    /// generation, moderation. Only chat completions belong in this menu.
    ///
    /// A substring denylist, not an allowlist: an allowlist would silently hide
    /// every model released after this line was written, which is the exact failure
    /// this file exists to end. The model field stays free text either way, so a
    /// false positive here costs the user a paste, not the feature.
    static func isChatModel(_ id: String) -> Bool {
        let lower = id.lowercased()
        return !nonChatMarkers.contains { lower.contains($0) }
    }

    private static let nonChatMarkers = [
        "embed", "whisper", "tts", "dall-e", "moderation", "rerank",
        "transcribe", "image", "audio", "realtime", "veo", "imagen", "sora"
    ]

    /// OpenAI-compat dates entries with `created` (epoch seconds); Anthropic uses
    /// `created_at` (ISO-8601). 0 means undated.
    static func createdAt(_ entry: [String: Any]) -> Double {
        if let number = entry["created"] as? NSNumber { return number.doubleValue }
        guard let iso = entry["created_at"] as? String else { return 0 }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: iso) { return date.timeIntervalSince1970 }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)?.timeIntervalSince1970 ?? 0
    }
}
