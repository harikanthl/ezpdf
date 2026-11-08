import Foundation
import Testing
@testable import OperatorLLM

/// Per-role model + effort resolution (`LLMProviderSettings.Role`).
///
/// The four jobs on the phone that ask a model a question — chat, brief, Listen script, curation —
/// share one provider and one key and differ only in model and effort. Nearly every test here is about
/// the DEFAULT, because the shipped state has to be the one-model behaviour that existed before the
/// split: an override is something a person opts into, and an install that upgrades must not quietly
/// start running its brief somewhere else.
@Suite struct LLMProviderSettingsRoleTests {

    private func settings(model: String = "anthropic/claude-sonnet-4-5",
                          brief: String = "", listen: String = "", curation: String = "",
                          effort: String = "") -> LLMProviderSettings {
        LLMProviderSettings(preset: .anthropic, modelId: model, baseURL: "", preferOnDevice: false,
                            briefModelId: brief, listenModelId: listen, curationModelId: curation,
                            briefReasoningEffort: effort)
    }

    // MARK: - Inherit is the default

    /// The whole design in one case: set nothing, and all four roles answer with the shared model.
    @Test func everyRoleInheritsTheSharedModelByDefault() {
        let s = settings()
        for role in LLMProviderSettings.Role.allCases {
            #expect(s.modelId(for: role) == "anthropic/claude-sonnet-4-5",
                    "\(role.rawValue) did not inherit the shared model")
        }
    }

    /// An override moves ONE role. The others must not follow it — that is the difference between this
    /// and simply changing the shared model.
    @Test func anOverrideMovesOnlyItsOwnRole() {
        let s = settings(brief: "anthropic/claude-opus-4-1")
        #expect(s.modelId(for: .brief) == "anthropic/claude-opus-4-1")
        #expect(s.modelId(for: .chat) == "anthropic/claude-sonnet-4-5")
        #expect(s.modelId(for: .listenScript) == "anthropic/claude-sonnet-4-5")
        #expect(s.modelId(for: .curation) == "anthropic/claude-sonnet-4-5")
    }

    /// Chat IS the shared model, so it can never be overridden — the settings UI shows it read-only for
    /// the same reason. A stray value in another field must not change that.
    @Test func chatAlwaysReportsTheSharedModel() {
        let s = settings(brief: "x/y", listen: "p/q", curation: "m/n")
        #expect(s.modelId(for: .chat) == "anthropic/claude-sonnet-4-5")
    }

    /// Whitespace is not a choice. A field someone cleared by selecting it and hitting space reads as
    /// cleared, because the alternative is a role silently pointed at a model id of " ".
    @Test func whitespaceOnlyOverridesReadAsInherit() {
        let s = settings(brief: "   ")
        #expect(s.modelId(for: .brief) == "anthropic/claude-sonnet-4-5")
    }

    // MARK: - Effort

    /// Chat and curation are pinned, and this is the money argument rather than a style one: chat is
    /// the one job where a late first token is the failure, and curation runs after every single turn.
    @Test func chatAndCurationIgnoreTheEffortSetting() {
        let s = settings(effort: "high")
        #expect(s.reasoningEffort(for: .chat) != "high")
        #expect(s.reasoningEffort(for: .curation) != "high")
    }

    /// The two nobody is waiting on get the choice.
    @Test func theBriefAndTheScriptHonourTheEffortSetting() {
        let s = settings(effort: "high")
        #expect(s.reasoningEffort(for: .brief) == "high")
        #expect(s.reasoningEffort(for: .listenScript) == "high")
    }

    /// Unset effort is not "no effort" — it falls back to the preset's own default, so a user who never
    /// opens the picker gets exactly what they got before the picker existed.
    @Test func unsetEffortFallsBackRatherThanBlanking() {
        let s = settings(effort: "")
        #expect(s.reasoningEffort(for: .brief) != nil)
        #expect(s.reasoningEffort(for: .brief) == s.reasoningEffort(for: .chat))
    }

    // MARK: - Upgrading an existing install

    /// THE COMPATIBILITY CASE. Settings written before this split carry none of the four new keys, and
    /// decoding one must produce inherit-everything — not a nil, not a crash, and above all not a
    /// different model. Someone updating the app should not discover their brief moved.
    @Test func settingsWrittenBeforeTheSplitDecodeAsInherit() throws {
        let legacy = """
        {"preset":"anthropic","modelId":"anthropic/claude-sonnet-4-5","baseURL":"","preferOnDevice":false}
        """
        let decoded = try JSONDecoder().decode(LLMProviderSettings.self,
                                               from: Data(legacy.utf8))
        #expect(decoded.briefModelId.isEmpty)
        #expect(decoded.listenModelId.isEmpty)
        #expect(decoded.curationModelId.isEmpty)
        #expect(decoded.briefReasoningEffort.isEmpty)
        for role in LLMProviderSettings.Role.allCases {
            #expect(decoded.modelId(for: role) == "anthropic/claude-sonnet-4-5")
        }
    }

    /// And a round trip keeps them, so the override survives the app being closed.
    @Test func overridesSurviveARoundTrip() throws {
        let original = settings(brief: "a/b", listen: "c/d", curation: "e/f", effort: "medium")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LLMProviderSettings.self, from: data)
        #expect(decoded.modelId(for: .brief) == "a/b")
        #expect(decoded.modelId(for: .listenScript) == "c/d")
        #expect(decoded.modelId(for: .curation) == "e/f")
        #expect(decoded.reasoningEffort(for: .brief) == "medium")
    }
}
