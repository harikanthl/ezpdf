//
//  ModelCatalog.swift
//  ezpdf (the provider-models part follows ezRecord's Agents/ModelCatalog.swift)
//
//  Models from our catalog worker on Cloudflare (catalog.operatorok.com), so model menus don't go
//  stale between app updates:
//  - /provider-models (~11 KB): the newest exact ids per provider, pushed into the assistant's
//    model menus (LLMModelCatalog.applyRemote).
//  - / (the full catalog): every model with category, price, context and tool support, for the
//    Models page; its image models become choices for logos (through OpenRouter).
//  - fal's live list of text-to-image models (api.fal.ai/v1/models, as MuseDrop's FalLiveCatalog),
//    when a fal key is saved.
//  Refreshed at most once a day, or from Settings › Models. Cached on disk; the built-in lists
//  stand in until the first fetch, and any id can still be typed.
//

import Foundation
import Observation
import OperatorLLM
import EzPDFCore

@MainActor
@Observable
final class ModelCatalogStore {
    static let shared = ModelCatalogStore()

    struct Entry: Identifiable, Codable, Hashable {
        var id: String
        var name: String
        var provider: String
        var category: String            // text, image, audio, video, router
        var source: String              // "catalog" or "fal"
        var contextLength: Int?
        var inputPrice: Double?         // $ per million tokens
        var outputPrice: Double?
        var unitPrice: String?          // fal: "$0.04 / image"
        var supportsTools: Bool?
        var blurb: String?
        var cheapToday: Bool?
    }

    private(set) var entries: [Entry] = []
    private(set) var updatedAt: Date?
    private(set) var loading = false
    private(set) var lastError: String?

    static let base = URL(string: "https://catalog.operatorok.com")!
    private static let fetchedKey = "ezpdf.catalog.fetchedAt"

    private var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ezpdf/model-catalog.json")
    }
    private var providerCacheURL: URL { cacheURL.deletingLastPathComponent().appendingPathComponent("provider-models.json") }

    init() { loadCache() }

    // MARK: Refresh

    func refreshIfNeeded() async {
        let last = UserDefaults.standard.object(forKey: Self.fetchedKey) as? Date ?? .distantPast
        if Date().timeIntervalSince(last) > 24 * 60 * 60 { await refresh() }
    }

    func refresh() async {
        guard !loading else { return }
        loading = true
        lastError = nil
        defer { loading = false }
        // Each source on its own: one failing keeps what it had before instead of emptying the list.
        var fresh: [Entry] = []
        var allOK = true
        do { try await fetchProviderModels() } catch { allOK = false }
        do { fresh += try await fetchCatalogModels() } catch {
            allOK = false
            lastError = "Couldn't reach the model catalog: \(error.localizedDescription)"
            fresh += entries.filter { $0.source == "catalog" }
        }
        ImageGen.refreshKeyState()
        if ImageGen.isReady(.fal) {
            do { fresh += try await fetchFalImageModels() } catch { allOK = false; fresh += entries.filter { $0.source == "fal" } }
        }
        guard !fresh.isEmpty else { return }
        entries = fresh
        updatedAt = Date()
        // Only a complete refresh resets the daily timer, so a partial one is retried next launch.
        if allOK { UserDefaults.standard.set(updatedAt, forKey: Self.fetchedKey) }
        saveCache()
        publishImageModels()
    }

    private func get(_ url: URL, headers: [String: String] = [:], timeout: TimeInterval = 30) async throws -> Data {
        var r = URLRequest(url: url, timeoutInterval: timeout)
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        let (d, resp) = try await URLSession.shared.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return d
    }

    /// Newest chat model ids per provider → the assistant's model menus.
    private func fetchProviderModels() async throws {
        let data = try await get(Self.base.appendingPathComponent("provider-models"), timeout: 15)
        try data.write(to: providerCacheURL, options: .atomic)
        applyProviderModels(data)
    }

    private func applyProviderModels(_ data: Data) {
        struct Doc: Decodable { struct E: Decodable { let id: String; let label: String }; let providerModels: [String: [E]] }
        guard let doc = try? JSONDecoder().decode(Doc.self, from: data) else { return }
        let nonChat = ["embed", "whisper", "tts", "dall-e", "moderation", "rerank", "transcribe", "image", "audio", "realtime", "veo", "imagen", "sora", "banana", "live"]
        let keys: [LLMProviderPreset: String] = [.anthropic: "anthropic", .openai: "openai", .gemini: "gemini", .xai: "grok"]
        var lists: [String: [LLMModelOption]] = [:]
        for (preset, key) in keys {
            let chat = (doc.providerModels[key] ?? []).filter { e in !nonChat.contains { e.id.lowercased().contains($0) } }
            lists[preset.rawValue] = chat.prefix(8).map { LLMModelOption(id: $0.id, label: $0.label) }
        }
        LLMModelCatalog.applyRemote(lists)
    }

    /// Every model in the full catalog (only the `models` part is kept).
    private func fetchCatalogModels() async throws -> [Entry] {
        let data = try await get(Self.base, timeout: 45)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
        return models.compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            let pricing = m["pricing"] as? [String: Any] ?? [:]
            // "image" models that only read images (not make them) aren't image generators.
            var category = (m["category"] as? String) ?? "text"
            if category == "image", let outs = m["outputs"] as? [String], !outs.contains("image") { category = "vision" }
            func perMillion(_ k: String) -> Double? { (pricing[k] as? NSNumber).map { $0.doubleValue * 1_000_000 } }
            return Entry(id: id, name: (m["name"] as? String) ?? id, provider: (m["provider"] as? String) ?? "", category: category,
                         source: "catalog", contextLength: m["contextLength"] as? Int, inputPrice: perMillion("prompt"),
                         outputPrice: perMillion("completion"), unitPrice: nil, supportsTools: m["supportsTools"] as? Bool,
                         blurb: m["blurb"] as? String, cheapToday: m["cheapToday"] as? Bool)
        }
    }

    /// fal's live text-to-image models (needs the user's fal key; keyless calls are rate limited).
    private func fetchFalImageModels() async throws -> [Entry] {
        guard let key = ImageGen.key(.fal) else { return [] }
        var out: [Entry] = []
        var cursor: String?
        for _ in 0..<4 {
            var c = URLComponents(string: "https://api.fal.ai/v1/models")!
            c.queryItems = [URLQueryItem(name: "category", value: "text-to-image"), URLQueryItem(name: "status", value: "active")]
                + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
            let data = try await get(c.url!, headers: ["Authorization": "Key \(key)"])
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { break }
            for m in root["models"] as? [[String: Any]] ?? [] {
                guard let id = m["endpoint_id"] as? String, let md = m["metadata"] as? [String: Any] else { continue }
                out.append(Entry(id: id, name: (md["display_name"] as? String) ?? id, provider: "fal", category: "image", source: "fal",
                                 contextLength: nil, inputPrice: nil, outputPrice: nil, unitPrice: nil, supportsTools: nil,
                                 blurb: md["description"] as? String, cheapToday: nil))
            }
            cursor = root["next_cursor"] as? String
            if (root["has_more"] as? Bool) != true || cursor == nil { break }
        }
        return out
    }

    // MARK: Using a model

    /// Image models become choices for logo generation.
    private func publishImageModels() {
        ImageGen.extraModels = entries.filter { $0.category == "image" }.map {
            ImageGen.Model(id: $0.id, name: $0.name, provider: $0.source == "fal" ? .fal : .openrouter,
                           note: $0.source == "fal" ? "fal.ai" : "via OpenRouter")
        }
    }

    /// The route the assistant will take for a catalog model: the provider's own API when a key for
    /// it is saved, otherwise OpenRouter with the catalog id.
    func route(for e: Entry) -> (preset: LLMProviderPreset, modelId: String) {
        let direct: [String: LLMProviderPreset] = ["anthropic": .anthropic, "openai": .openai, "google": .gemini, "x-ai": .xai]
        if let preset = direct[e.provider], let account = preset.keychainAccount, KeychainService.has(account) {
            // Catalog ids are OpenRouter style ("anthropic/claude-sonnet-4.5", "x-ai/grok-4:free"); the
            // providers' own APIs want the bare name, and Anthropic spells versions with dashes.
            var bare = e.id.split(separator: "/").last.map(String.init) ?? e.id
            if let colon = bare.firstIndex(of: ":") { bare = String(bare[..<colon]) }
            if preset == .anthropic { bare = bare.replacingOccurrences(of: ".", with: "-") }
            return (preset, bare)
        }
        return (.openrouter, e.id)
    }

    func useForAssistant(_ e: Entry) {
        let r = route(for: e)
        var settings = LLMProviderSettings.load()
        settings.preset = r.preset
        settings.modelId = r.modelId
        settings.save()
        LLMProviderSettings.announceChange()
    }

    func useForImages(_ e: Entry) {
        UserDefaults.standard.set(e.id, forKey: "ezpdf.logoModel")
    }

    // MARK: Cache

    private func loadCache() {
        if let d = try? Data(contentsOf: providerCacheURL) { applyProviderModels(d) }
        guard let d = try? Data(contentsOf: cacheURL), let saved = try? JSONDecoder().decode([Entry].self, from: d) else { return }
        entries = saved
        updatedAt = UserDefaults.standard.object(forKey: Self.fetchedKey) as? Date
        publishImageModels()
    }

    private func saveCache() {
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(entries) { try? d.write(to: cacheURL, options: .atomic) }
    }
}
