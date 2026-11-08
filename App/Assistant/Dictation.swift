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
    @ObservationIgnored private var onText: ((String) -> Void)?
    @ObservationIgnored private var onProblem: ((String?) -> Void)?
    /// The text when talking started, and the phrases finished since.
    @ObservationIgnored private var spokenBase = ""
    @ObservationIgnored private var spokenDone = ""
    /// Results are still welcome: from start until the last words come back after stopping.
    @ObservationIgnored private var dictating = false
    @ObservationIgnored private var resultCount = 0
    @ObservationIgnored private var peakLevel: Float = 0

    /// `name` labels the log lines ("Home", "Review").
    /// Watches the mic level while dictating; cancelled on stop.
    @ObservationIgnored private var levelTask: Task<Void, Never>?

    init(name: String) { self.name = name }

    /// Starts listening; `onText` gets the whole text (base plus what's heard) as it grows, `onProblem` a reason
    /// to show, or nil once it's going.
    func start(from base: String, microphoneAllowed: Bool,
               onText: @escaping (String) -> Void, onProblem: @escaping (String?) -> Void) {
        guard !isListening else { return }
        guard microphoneAllowed else {
            onProblem("Allow the microphone for ezpdf in System Settings › Privacy & Security › Microphone to talk instead of typing.")
            return
        }
        self.onText = onText
        self.onProblem = onProblem
        onProblem(nil)
        isListening = true
        spokenBase = base.isEmpty || base.hasSuffix(" ") ? base : base + " "
        spokenDone = ""
        dictating = true
        resultCount = 0
        peakLevel = 0
        Task {
            do {
                let follower = try await VoiceFollower.start { [weak self] heard, isFinal in self?.heard(heard, isFinal: isFinal) }
                guard isListening else { await follower.stop(); return }
                self.follower = follower
                try mic.start(feeding: follower)
                levelTask = Task { [weak self] in
                    for await level in follower.levels {
                        guard let self else { return }
                        self.peakLevel = max(self.peakLevel, level)
                        self.level = max(min(level * 4, 1), self.level * 0.7)
                    }
                }
            } catch {
                Log.capture.notice("\(self.name, privacy: .public) dictation failed: \(error.localizedDescription, privacy: .public)")
                self.onProblem?(error.localizedDescription)
                stop()
            }
        }
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        mic.stop()
        levelTask?.cancel()
        levelTask = nil
        level = 0
        guard let follower else { dictating = false; return }
        self.follower = nil
        Task {
            await follower.finish()
            dictating = false
            Log.capture.notice("\(self.name, privacy: .public) dictation: \(self.resultCount) results, mic peak \(self.peakLevel, format: .fixed(precision: 3))")
            if resultCount == 0 {
                onProblem?(peakLevel < 0.01
                    ? "The microphone sent only silence. Check the input in System Settings › Sound."
                    : "Didn't catch any words. Try again a little closer to the microphone.")
            }
        }
    }

    private func heard(_ phrase: String, isFinal: Bool) {
        guard dictating else { return }
        resultCount += 1
        let phrase = phrase.trimmingCharacters(in: .whitespaces)
        if isFinal {
            if !phrase.isEmpty { spokenDone += phrase + " " }
            onText?(spokenBase + spokenDone)
        } else {
            onText?(spokenBase + spokenDone + phrase)
        }
    }
}
