//
//  Dictation.swift
//  ezpdf (lifted from ezRecord's Voice/Dictation.swift)
//
//  Talk-to-type, on this Mac: the prompter's on-device recognizer (VoiceFollower fed by RehearsalMic), so no audio
//  leaves the Mac. Finished phrases are committed and the phrase in progress is shown after them, appended to the
//  text that was there when talking started. Stopping finalizes rather than cancels, so the last words still land;
//  if nothing was heard at all it says so (and logs the mic's peak level) instead of staying silent.
//  Used by the home composer and by the after-action review on the saved card.
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class Dictation {
    private(set) var isListening = false
    /// The mic's level while listening, 0…1, rising at once and falling back gently: drives the voice wave.
    private(set) var level: Float = 0

    @ObservationIgnored private let name: String
    @ObservationIgnored private var follower: VoiceFollower?
    @ObservationIgnored private let mic = RehearsalMic()
    /// One listening session: its own callbacks and counters, so a slow finish from the last session
    /// can't write into (or silence) the next one.
    private final class Session {
        let id = UUID()
        var onText: ((String) -> Void)?
        var onProblem: ((String?) -> Void)?
        var base = "", done = "", lastWritten = ""
        var accepting = true
        var results = 0
        var peak: Float = 0
        var failed = false
    }
    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var levelTask: Task<Void, Never>?

    init(name: String) { self.name = name }

    /// Starts listening; `onText` gets the whole text (base plus what's heard) as it grows, `onProblem` a reason
    /// to show, or nil once it's going. `current` reads the field now, so typing while talking isn't erased.
    func start(from base: String, microphoneAllowed: Bool, current: (() -> String)? = nil,
               onText: @escaping (String) -> Void, onProblem: @escaping (String?) -> Void) {
        guard !isListening else { return }
        guard microphoneAllowed else {
            onProblem("Allow the microphone for ezpdf in System Settings › Privacy & Security › Microphone to talk instead of typing.")
            return
        }
        let s = Session()
        s.onText = onText
        s.onProblem = onProblem
        s.base = base.isEmpty || base.hasSuffix(" ") || base.hasSuffix("\n") ? base : base + " "
        s.lastWritten = base
        self.current = current
        session = s
        onProblem(nil)
        isListening = true
        Task {
            do {
                let follower = try await VoiceFollower.start { [weak self, weak s] heard, isFinal in
                    guard let self, let s else { return }
                    self.heard(heard, isFinal: isFinal, in: s)
                }
                // Stopped (or restarted) while the recognizer was getting ready: don't open the mic.
                guard isListening, session === s else { await follower.stop(); return }
                self.follower = follower
                try mic.start(feeding: follower)
                levelTask = Task { [weak self, weak s] in
                    for await level in follower.levels {
                        guard let self, let s, self.session === s else { return }
                        s.peak = max(s.peak, level)
                        self.level = max(min(level * 4, 1), self.level * 0.7)
                    }
                }
            } catch {
                Log.capture.notice("\(self.name, privacy: .public) dictation failed: \(error.localizedDescription, privacy: .public)")
                guard session === s else { return }
                s.failed = true
                s.onProblem?(error.localizedDescription)
                stop()
            }
        }
    }
    @ObservationIgnored private var current: (() -> String)?

    /// Stops listening. With `deliver` the last words still land; without (the text was just sent),
    /// nothing more is written.
    func stop(deliver: Bool = true) {
        guard isListening, let s = session else { return }
        isListening = false
        mic.stop()
        levelTask?.cancel()
        levelTask = nil
        level = 0
        if !deliver { s.accepting = false; s.onText = nil }
        guard let follower else { s.accepting = false; return }
        self.follower = nil
        Task {
            await follower.finish()
            s.accepting = false
            Log.capture.notice("\(self.name, privacy: .public) dictation: \(s.results) results, mic peak \(s.peak, format: .fixed(precision: 3))")
            if deliver, s.results == 0, !s.failed, session === s {
                s.onProblem?(s.peak < 0.01
                    ? "The microphone sent only silence. Check the input in System Settings › Sound."
                    : "Didn't catch any words. Try again a little closer to the microphone.")
            }
        }
    }

    /// Stops without writing anything more (the draft was sent or cleared).
    func cancel() { stop(deliver: false) }

    private func heard(_ phrase: String, isFinal: Bool, in s: Session) {
        guard s.accepting, let onText = s.onText else { return }
        s.results += 1
        // Typed or edited since the last words we wrote: carry on from what's there now.
        if let now = current?(), session === s, now != s.lastWritten {
            s.base = now.isEmpty || now.hasSuffix(" ") || now.hasSuffix("\n") ? now : now + " "
            s.done = ""
        }
        let phrase = phrase.trimmingCharacters(in: .whitespaces)
        let text: String
        if isFinal {
            if !phrase.isEmpty { s.done += phrase + " " }
            text = s.base + s.done
        } else {
            text = s.base + s.done + phrase
        }
        s.lastWritten = text
        onText(text)
    }
}
