//
//  OnDeviceLLM.swift
//  OperatorLLM
//
//  Thin wrapper over Apple's Foundation Models framework (macOS 26+ / iOS 26+):
//  availability gating, session creation, a generic `generate<T: Generable>`, and
//  streaming text. Deliberately a THIN extract of MuseDrop's FoundationModelBridge
//  — all of MuseDrop's @Generable domain structs (flashcards, summaries, mind
//  maps…) stay behind; each consumer defines its own schema.
//

import Foundation

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, iOS 26.0, *)
public struct OnDeviceLLM: Sendable {
    /// Optional system instructions applied to every session this wrapper creates.
    private let instructions: String?

    public init(instructions: String? = nil) {
        self.instructions = instructions
    }

    /// Whether the on-device model can run right now (hardware + Apple Intelligence
    /// enabled + model downloaded). Prompt-free.
    public static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    /// A human-readable reason the model is unavailable, or nil when available.
    public static var availabilityMessage: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings to use on-device AI."
        case .unavailable(.deviceNotEligible):
            return "This device doesn't support Apple Intelligence."
        case .unavailable(.modelNotReady):
            return "The on-device model is still downloading. Try again shortly."
        case .unavailable:
            return "Apple Intelligence is unavailable right now."
        @unknown default:
            return "Apple Intelligence is unavailable right now."
        }
    }

    /// Generate a structured value of any caller-defined `@Generable` type.
    public func generate<T: Generable>(prompt: String, as type: T.Type = T.self) async throws -> T {
        guard Self.isAvailable else {
            throw LLMError.unavailable(Self.availabilityMessage ?? "On-device model unavailable.")
        }
        let session = LanguageModelSession(model: .default, tools: [], instructions: instructions)
        return try await session.respond(to: prompt, generating: type).content
    }

    /// Stream plain assistant text as incremental deltas. Foundation Models yields
    /// cumulative snapshots; we diff against the last snapshot to emit only new text.
    ///
    /// - Parameter tools: what the model may call mid-answer (`OnDeviceToolBridge.tools`). The
    ///   session runs them itself and continues; only the resulting text reaches the caller. Empty
    ///   is the plain chat it always was.
    public func streamText(prompt: String, tools: [any Tool] = []) -> AsyncThrowingStream<String, Error> {
        let instructions = self.instructions
        return AsyncThrowingStream { continuation in
            guard Self.isAvailable else {
                continuation.finish(
                    throwing: LLMError.unavailable(Self.availabilityMessage ?? "On-device model unavailable.")
                )
                return
            }
            let task = Task {
                do {
                    // PERMISSIVE guardrails for the text path. Apple's default classifier fires on
                    // innocuous input — live-caught 2026-08-07, when "schedule lead-follow up today"
                    // came back as "content likely to be unsafe" — and a scheduling assistant that
                    // occasionally accuses the user of unsafe content is worse than one that is absent.
                    // `permissiveContentTransformations` is the option Apple ships for exactly this;
                    // its documented limitation is that it does not apply to `Generable` output, which
                    // is why `generate(prompt:as:)` above deliberately keeps the default guardrails.
                    let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
                    let session = LanguageModelSession(model: model, tools: tools, instructions: instructions)
                    var previous = ""
                    for try await snapshot in session.streamResponse(to: prompt) {
                        try Task.checkCancellation()
                        let text = snapshot.content
                        guard text.count > previous.count else { continue }
                        let delta = String(text[text.index(text.startIndex, offsetBy: previous.count)...])
                        previous = text
                        if !delta.isEmpty { continuation.yield(delta) }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: LLMError.cancelled)
                } catch let error as LanguageModelSession.GenerationError {
                    // Surface a refusal AS a refusal. Apple's raw description ("content likely to be
                    // unsafe") is shown to the user verbatim otherwise, which reads as an accusation
                    // rather than a limitation of the on-device model.
                    if case .guardrailViolation = error {
                        continuation.finish(throwing: LLMError.refused)
                    } else {
                        continuation.finish(throwing: error)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

#else

/// Fallback for platforms without Foundation Models. The package targets
/// macOS 26 / iOS 26 where the framework is always present, so this exists only
/// to keep the type referenceable in unusual build configurations.
public struct OnDeviceLLM: Sendable {
    public init(instructions: String? = nil) {}
    public static var isAvailable: Bool { false }
    public static var availabilityMessage: String? { "On-device AI requires Apple Intelligence." }
}

#endif
