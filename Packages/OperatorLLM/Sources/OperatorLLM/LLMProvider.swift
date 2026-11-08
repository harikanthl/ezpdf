//
//  LLMProvider.swift
//  OperatorLLM
//
//  Non-secret BYOK configuration (provider preset, model id, base URL). The API
//  key itself lives in the Keychain (see KeychainService), never here.
//
//  Lifted from MuseDrop's LLMProviderSettings.swift; made public and trimmed from
//  12 presets to 6 (.onDevice, .anthropic, .openai, .gemini, .openrouter, .custom). The rest
//  re-add trivially later — same struct shape.
//

import Foundation

public enum LLMProviderPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case onDevice
    case anthropic
    case openai
    case gemini
    /// One key, ~400 models, and the only preset whose ids match the browsable catalog Operator
    /// already ships. `ModelInfo.id` is an OpenRouter slug (`anthropic/claude-opus-5`) bound for
    /// OpenRouter's gateway — which is why that catalog cannot drive the Anthropic or OpenAI pickers
    /// (their APIs 404 on a vendor-prefixed slug) but drives THIS one directly, filters, Auto routers
    /// and all. The client needs no changes: OpenRouter is OpenAI-compatible, and
    /// `OpenAICompatibleClient` has always sent the `HTTP-Referer`/`X-Title` attribution headers
    /// OpenRouter ranks apps by.
    case openrouter
    /// xAI's Grok. OpenAI-compatible chat completions with tool calls at api.x.ai (added for ezRecord, PRD §6.8).
    case xai
    case custom
    /// A model running on the paired Mac — Ollama on its loopback (docs/LOCAL_MODELS.md §2.5),
    /// reached through the sealed session rather than the network. No key, nothing leaves the pair.
    /// The base URL is NOT stored here: it is the phone's own loopback proxy, minted when the proxy
    /// starts, and the resolver supplies it (`LocalModelProxy`).
    case thisMac

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .onDevice: return "On-Device (Apple Intelligence)"
        case .anthropic: return "Anthropic (Claude)"
        case .openai: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .openrouter: return "OpenRouter (400+ models)"
        case .xai: return "xAI (Grok)"
        case .custom: return "Custom (OpenAI-compatible)"
        case .thisMac: return "This Mac (local)"
        }
    }

    /// Base URL the OpenAI-compatible client posts `…/chat/completions` to. nil for
    /// on-device. Anthropic is reached via its OpenAI-compat endpoint.
    public var defaultBaseURL: String? {
        switch self {
        case .onDevice: return nil
        case .anthropic: return "https://api.anthropic.com/v1"
        case .openai: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .xai: return "https://api.x.ai/v1"
        case .custom: return ""
        // Supplied at resolve time by the phone's proxy; an empty default keeps `effectiveBaseURL`
        // honest (nothing to post to until the road is up) rather than naming a host that isn't there.
        case .thisMac: return ""
        }
    }

    /// Whether a key has to be typed. Ollama on the Mac takes none, and asking for one would be a field
    /// that a person fills with nonsense to get past.
    public var requiresAPIKey: Bool { self != .onDevice && self != .thisMac }

    /// Keychain account holding this preset's API key, or nil when none applies.
    public var keychainAccount: String? { KeychainService.Account.llm(self) }

    /// Default `reasoning_effort` for this provider's OpenAI-compat requests, or
    /// nil to leave the provider's own default. Some Gemini Flash models default to
    /// *medium* thinking even for simple work, billing those tokens as output; we
    /// ask for "low" so it still reasons a little but returns faster/cheaper.
    public var defaultReasoningEffort: String? {
        self == .gemini ? "low" : nil
    }

    /// Where the user obtains a key (shown as a link in Settings).
    public var getKeyURL: String? {
        switch self {
        case .anthropic: return "https://console.anthropic.com/settings/keys"
        case .openai: return "https://platform.openai.com/api-keys"
        case .gemini: return "https://aistudio.google.com/apikey"
        case .openrouter: return "https://openrouter.ai/keys"
        case .xai: return "https://console.x.ai"
        case .onDevice, .custom, .thisMac: return nil
        }
    }

    /// Placeholder hint for the key field (the provider's key prefix).
    public var keyHint: String {
        switch self {
        case .anthropic: return "sk-ant-…"
        case .openai: return "sk-…"
        case .gemini: return "AIza… (aistudio key)"
        case .openrouter: return "sk-or-…"
        case .xai: return "xai-…"
        case .onDevice, .custom: return "API key"
        case .thisMac: return "No key needed"
        }
    }

    /// Whether `GET {baseURL}/models` returns a usable catalog. On-device doesn't; the Mac's Ollama
    /// does (`/v1/models` lists what has been pulled), and needs no key to say so.
    public var supportsModelListing: Bool { self != .onDevice }

    /// Curated fallback model IDs shown immediately on selection. IDs drift over
    /// time; a live "Load models" call refreshes them where supported.
    public var modelSuggestions: [(label: String, id: String)] {
        switch self {
        case .anthropic:
            return [("Opus 5.5", "claude-opus-5-5"), ("Fable 5.1", "claude-fable-5-1"),
                    ("Sonnet 5.5", "claude-sonnet-5-5"), ("Haiku 5.5", "claude-haiku-5-5"),
                    ("Opus 5", "claude-opus-5"), ("Sonnet 5", "claude-sonnet-5")]
        case .openai:
            return [("GPT-5.6 Sol", "gpt-5.6-sol"), ("GPT-5.6 Terra", "gpt-5.6-terra"),
                    ("GPT-5.6 Luna", "gpt-5.6-luna"), ("GPT-5.5 Pro", "gpt-5.5-pro"),
                    ("GPT-5.5", "gpt-5.5"), ("GPT-5.4 mini", "gpt-5.4-mini")]
        case .gemini:
            return [("Gemini 3.6 Flash", "gemini-3.6-flash"), ("Gemini 3.5 Flash", "gemini-3.5-flash"),
                    ("Gemini 3.5 Flash Lite", "gemini-3.5-flash-lite"),
                    ("Gemini 3.1 Pro", "gemini-3.1-pro-preview"),
                    ("Gemini 3.1 Flash Lite", "gemini-3.1-flash-lite"),
                    ("Gemini 2.5 Pro", "gemini-2.5-pro"), ("Gemini 2.5 Flash", "gemini-2.5-flash")]
        case .openrouter:
            // The Auto routers first: OpenRouter picks the model per prompt server-side, which is the
            // headline reason to bring one key instead of four. `OpenRouterRouting`'s slugs live in
            // OperatorModels and this package has no dependencies, so they are repeated rather than
            // imported — the pairing is asserted in `LLMModelCatalogTests`.
            return [("Auto", "openrouter/auto-beta"), ("Auto (Coding)", "openrouter/pareto-code"),
                    ("Claude Opus 5", "anthropic/claude-opus-5"),
                    ("Claude Sonnet 5", "anthropic/claude-sonnet-5"),
                    ("GPT-5.6 Sol", "openai/gpt-5.6-sol"),
                    ("Gemini 3.6 Flash", "google/gemini-3.6-flash")]
        case .xai:
            // IDs move fast; "Load models" lists the live ones from /v1/models.
            return [("Grok 4.6", "grok-4.6"), ("Grok 4.5", "grok-4.5")]
        case .onDevice, .custom:
            return []
        case .thisMac:
            // Nothing curated: what is on the Mac is whatever was pulled, and "Load models" asks it.
            // Suggesting a tag that may not be there would be a menu of things that 404.
            return []
        }
    }

    /// The QUALITY default: the first curated suggestion, the flagship. What `effectiveModelId` falls
    /// back to for jobs judged on quality (curation, the brief), and what the suggestion menu leads with.
    public var defaultModelId: String { modelSuggestions.first?.id ?? "" }

    /// The FAST default: what the chat runs on when nobody picked a model, and what "Test connection"
    /// must therefore test. Cheap, low-latency, and available on every tier of every provider — which
    /// the flagship is not. Found 2026-09-05: switching to Anthropic wrote `defaultModelId` (Opus 5)
    /// into the model field, the chat then used it because the field was no longer blank, and a key
    /// without Opus access failed the test AND the chat while the fast model it would otherwise have
    /// used was fine. One definition here; the chat resolver reads it rather than keeping its own copy.
    ///
    /// Direct chat is latency-sensitive, so OpenRouter names a cheap concrete model rather than its
    /// Auto router: routing is chosen per prompt server-side and can land on a frontier model, which is
    /// the right default for a job and the wrong one for a chat bubble.
    public var fastModelId: String {
        switch self {
        case .anthropic:  return "claude-haiku-5-5"
        case .openai:     return "gpt-5.4-mini"
        case .gemini:     return "gemini-3.5-flash"
        case .openrouter: return "anthropic/claude-haiku-4-5"
        case .xai: return "grok-4.6"
        case .onDevice, .custom, .thisMac: return defaultModelId
        }
    }
}

/// Persisted, non-secret provider settings (UserDefaults-backed).
public struct LLMProviderSettings: Codable, Equatable, Sendable {
    public var preset: LLMProviderPreset
    public var modelId: String
    public var baseURL: String
    /// When true and on-device is available, prefer it even if a cloud key exists.
    public var preferOnDevice: Bool
    /// Model for the VOICE path only; empty ⇒ inherit `modelId`.
    ///
    /// One provider, per-role models. Voice resolution runs on every utterance, wants a tiny answer,
    /// and is judged on latency; memory curation and chat run rarely and are judged on quality. A
    /// single field can't serve both — pick Opus for quality and every spoken command pays for
    /// thinking it doesn't need. The provider and key stay shared: the split that matters is the
    /// model, and a second BYOK relationship would be setup cost for nothing.
    public var voiceModelId: String

    /// Model for the DAILY BRIEF; empty ⇒ inherit `modelId`. Same per-role split as `voiceModelId`,
    /// for the opposite reason: voice breaks out because it is judged on latency, and the brief breaks
    /// out because it is the one job here that is NOT. It runs once a day, nobody is watching the first
    /// token, and it is the artifact a person actually reads — so it is the one place where paying for
    /// a better model is obviously worth it, and the only place a chat-tuned default is clearly wrong.
    public var briefModelId: String

    /// Model for the LISTEN SCRIPT — turning a brief or an episode manifest into spoken dialogue.
    ///
    /// Separate from `briefModelId` because the two jobs fail differently and a person may well want to
    /// spend on one and not the other: the brief decides WHAT is worth saying, the script decides how it
    /// SOUNDS. Someone happy with their brief who thinks the two hosts read flat wants to change exactly
    /// one of these, and a single shared field would make them change both.
    public var listenModelId: String

    /// Model for background memory CURATION; empty ⇒ inherit `modelId`.
    ///
    /// Note this is the one role whose sensible answer is usually "the cheapest thing that works" rather
    /// than the best model available — curation runs after turns, so it runs often, and it is bookkeeping
    /// nobody is waiting on. `PhoneMemoryCurator` prefers on-device ahead of this for that reason; this
    /// field is what a cloud-only phone falls back to, and what someone who wants a specific small model
    /// for it can name.
    public var curationModelId: String

    /// Reasoning effort for the brief AND the Listen script; empty ⇒ the preset's own default.
    ///
    /// ONE FIELD FOR BOTH, unlike the model ids above, because effort is not a taste question the way a
    /// model is — it is the same trade in both places ("wait longer, think harder") and both are jobs
    /// the user is not sitting in front of. Chat is deliberately excluded: it stays on the low-latency
    /// default, because a first token that arrives late is the one failure a conversation cannot hide.
    public var briefReasoningEffort: String

    /// Talk live over OpenAI's GPT-Live (docs/GPT_LIVE.md). On by default: the control is always
    /// visible in Operator mode and, with no OpenAI key, opens a setup line rather than a session, so
    /// "on" costs nothing until a key exists. NOT a provider choice — the assistant provider above
    /// still answers; this only decides whether the mouth is offered.
    public var liveVoiceEnabled: Bool

    /// The GPT-Live voice name; empty ⇒ the server default (`marin`). Fixed for a session.
    public var liveVoice: String

    public init(preset: LLMProviderPreset,
                modelId: String,
                baseURL: String,
                preferOnDevice: Bool,
                voiceModelId: String = "",
                briefModelId: String = "",
                listenModelId: String = "",
                curationModelId: String = "",
                briefReasoningEffort: String = "",
                liveVoiceEnabled: Bool = true,
                liveVoice: String = "") {
        self.preset = preset
        self.modelId = modelId
        self.baseURL = baseURL
        self.preferOnDevice = preferOnDevice
        self.voiceModelId = voiceModelId
        self.briefModelId = briefModelId
        self.listenModelId = listenModelId
        self.curationModelId = curationModelId
        self.briefReasoningEffort = briefReasoningEffort
        self.liveVoiceEnabled = liveVoiceEnabled
        self.liveVoice = liveVoice
    }

    /// On-device by default — it's the free, private, zero-config route and is the
    /// default whenever the hardware supports it. BYOK is optional on top.
    public static let `default` = LLMProviderSettings(
        preset: .onDevice,
        modelId: "",
        baseURL: "",
        preferOnDevice: true
    )

    // MARK: Codable (resilient to fields added across versions)

    private enum CodingKeys: String, CodingKey {
        case preset, modelId, baseURL, preferOnDevice, voiceModelId
        case briefModelId, listenModelId, curationModelId, briefReasoningEffort
        case liveVoiceEnabled, liveVoice
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = LLMProviderSettings.default
        preset = try c.decodeIfPresent(LLMProviderPreset.self, forKey: .preset) ?? fallback.preset
        modelId = try c.decodeIfPresent(String.self, forKey: .modelId) ?? fallback.modelId
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? fallback.baseURL
        preferOnDevice = try c.decodeIfPresent(Bool.self, forKey: .preferOnDevice) ?? fallback.preferOnDevice
        // Absent on settings written before the split — an existing install keeps one shared model.
        voiceModelId = try c.decodeIfPresent(String.self, forKey: .voiceModelId) ?? ""
        // Same rule for the three roles added after them: absent decodes to empty, empty means
        // "inherit `modelId`", so every install that predates this upgrade keeps exactly the behaviour
        // it had. A per-role default other than inherit would silently change what someone's brief runs
        // on the first time they open the app after updating.
        briefModelId = try c.decodeIfPresent(String.self, forKey: .briefModelId) ?? ""
        listenModelId = try c.decodeIfPresent(String.self, forKey: .listenModelId) ?? ""
        curationModelId = try c.decodeIfPresent(String.self, forKey: .curationModelId) ?? ""
        briefReasoningEffort = try c.decodeIfPresent(String.self, forKey: .briefReasoningEffort) ?? ""
        // Absent on settings written before Talk existed: on, server-default voice — the same two
        // values a fresh install gets, so the upgrade changes nothing a person already chose.
        liveVoiceEnabled = try c.decodeIfPresent(Bool.self, forKey: .liveVoiceEnabled) ?? true
        liveVoice = try c.decodeIfPresent(String.self, forKey: .liveVoice) ?? ""
    }

    // MARK: UserDefaults persistence

    private static let key = "operator.llm.providerSettings"

    public static func load() -> LLMProviderSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(LLMProviderSettings.self, from: data) else {
            return .default
        }
        return decoded
    }

    public func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
        Self.announceChange()
    }

    // MARK: Change notice

    /// Posted whenever something the backend ladder reads has changed: these settings, a provider key
    /// in the Keychain, or a per-agent worker key.
    ///
    /// WHY IT EXISTS (2026-09-11). The phone's chat models resolve their backend once, when they are
    /// created, and the centers that own them keep them alive for the whole app run. A key saved in
    /// Settings after Home's Operator chat had been opened never reached it: the composer kept saying
    /// "answering with the small on-device model" until a relaunch, while the Brief, which resolves per
    /// generation, had already moved to the new key. Two surfaces disagreeing about who answers reads
    /// as a broken product. Every long-lived model listens for this and re-resolves.
    public static let didChange = Notification.Name("operator.llm.providerSettingsDidChange")

    /// Say so. `save()` calls this itself; the two key stores call it after a Keychain write, because a
    /// secret is not part of these settings but is very much part of the answer.
    public static func announceChange() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// The effective base URL (preset default unless custom overrides).
    public var effectiveBaseURL: String {
        if preset == .custom { return baseURL }
        return preset.defaultBaseURL ?? baseURL
    }

    /// The model for general work — chat, memory curation, vision. Falls back to the preset's default
    /// when the user never picked one.
    public var effectiveModelId: String {
        modelId.isEmpty ? preset.defaultModelId : modelId
    }

    // MARK: - Per-role resolution

    /// The jobs on this phone that ask a model a question, as one named list.
    ///
    /// Named rather than left as four call sites reading four fields, because the interesting property
    /// is that they SHARE a provider and a key and differ only in model and effort. A reader who sees
    /// this enum knows the split is per-role, not per-account, without having to go and check whether
    /// somebody quietly introduced a second BYOK relationship.
    public enum Role: String, CaseIterable, Sendable {
        /// The conversation. Never overridden — it is what `modelId` means.
        case chat
        /// The daily brief.
        case brief
        /// Turning a brief or an episode manifest into spoken dialogue.
        case listenScript
        /// Background memory curation.
        case curation

        public var title: String {
            switch self {
            case .chat:         return "Chat"
            case .brief:        return "Brief"
            case .listenScript: return "Listen script"
            case .curation:     return "Curation"
            }
        }
    }

    /// The model this role should use: its own override when set, otherwise the shared `modelId`.
    ///
    /// EMPTY MEANS INHERIT, and that is what makes "one model for all four" the default state rather
    /// than a thing the user has to configure four times. Trimmed, because a field someone cleared by
    /// selecting the text and hitting space is a field they meant to clear.
    public func modelId(for role: Role) -> String {
        let override = roleOverride(for: role)
        return override.isEmpty ? modelId : override
    }

    /// The role's OWN field, with no inheritance — empty means "not overridden".
    ///
    /// Separate from `modelId(for:)` because one caller must not inherit. When the chat is running on a
    /// per-agent key that was saved to spawn workers (the resolver's rung 3), the shared `modelId` may
    /// belong to a provider that is not the one answering — someone who configured OpenAI, then switched
    /// the preset back to on-device, still has `gpt-…` sitting in that field. Inheriting it onto an
    /// Anthropic key would name a model that provider has never heard of, and the request would fail in
    /// a way that reads as "the brief is broken" rather than "those two settings disagree".
    public func roleOverride(for role: Role) -> String {
        let raw: String
        switch role {
        case .chat:         raw = ""
        case .brief:        raw = briefModelId
        case .listenScript: raw = listenModelId
        case .curation:     raw = curationModelId
        }
        return raw.trimmingCharacters(in: .whitespaces)
    }

    /// The reasoning effort this role should ask for.
    ///
    /// Chat and curation are pinned to the low-latency default and are deliberately not configurable:
    /// chat is the one job where a late first token is the failure, and curation is bookkeeping that
    /// runs after every turn — letting either of them think harder spends the user's money in the two
    /// places they would least want it spent. The brief and the script get the choice because they are
    /// the only two nobody is waiting on.
    public func reasoningEffort(for role: Role) -> String? {
        let presetDefault = preset.defaultReasoningEffort ?? "low"
        switch role {
        case .chat, .curation:
            return presetDefault
        case .brief, .listenScript:
            let chosen = briefReasoningEffort.trimmingCharacters(in: .whitespaces)
            return chosen.isEmpty ? presetDefault : chosen
        }
    }

    /// The model for the voice path. Inherits `effectiveModelId` unless voice was given its own.
    public var effectiveVoiceModelId: String {
        voiceModelId.isEmpty ? effectiveModelId : voiceModelId
    }
}
