//
//  VoiceFollower.swift
//  ezpdf (lifted from ezRecord)
//
//  Hears you for the prompter's Follow voice (PRD §3.6, §6.4): on-device SpeechAnalyzer with volatile, fast
//  results, so the script moves as soon as a word is out. It doesn't own a microphone:
//  - while recording, it's fed the recording's own mic buffers (the same samples written to mic.mov) on the
//    mic writer's queue, so there's no second audio engine and no device contention;
//  - while rehearsing (no recording), `RehearsalMic` feeds it from an AVAudioEngine input tap.
//  Buffers are converted to the analyzer's format and queued newest-first (a slow recognizer drops audio, it
//  never back-pressures the recording). Nothing on the feeding path hops actors or creates tasks: heard text
//  arrives on the main actor straight from the analyzer's results, and the level goes out on a newest-only
//  stream throttled to ~15 Hz (PRD §7.2 rules 4 and 7).
//
//  Adapted from ezPrompter `Shared/VoiceTracker.swift` (our own repo, PRD §6.9: "split so it accepts buffers
//  from the live tap instead of owning an AVAudioEngine").
//

@preconcurrency import AVFoundation
import os
import Speech
import Synchronization

nonisolated final class VoiceFollower: Sendable {
    private let analyzer: SpeechAnalyzer
    private let format: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let results: Task<Void, Never>
    /// Mic level 0…1 for the meter: newest-only, at most ~15 Hz. Ends on `stop()`.
    let levels: AsyncStream<Float>
    private let levelContinuation: AsyncStream<Float>.Continuation
    /// Loudest peak since the last published level, and when that was (uptime ns).
    private let level = Mutex<(peak: Float, sentAt: UInt64)>((0, 0))
    private static let levelInterval: UInt64 = 66_000_000
    /// The converter for the current input format. Producers are one queue at a time (mic queue or audio
    /// thread), but the lock keeps a switch between them safe.
    private let conversion = Mutex<(converter: AVAudioConverter?, input: AVAudioFormat?)>((nil, nil))

    /// Prepares the on-device model and starts listening for buffers.
    /// `vocabulary`: the script's own words (names, product words) to bias recognition toward. Apple honours
    /// contextual strings in some transcribers only, so this helps where it can; WordMatcher copes either way.
    static func start(vocabulary: [String] = [], onHeard: @escaping @MainActor @Sendable (String, _ isFinal: Bool) -> Void) async throws -> VoiceFollower {
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) ?? Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw Transcriber.TranscriberError.noFormat
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try? await analyzer.setContext(context)
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let results = Task { @MainActor in
            do {
                for try await result in transcriber.results { onHeard(String(result.text.characters), result.isFinal) }
            } catch {
                Log.capture.notice("Voice follow stopped: \(error.localizedDescription, privacy: .public)")
            }
        }
        try await analyzer.start(inputSequence: stream)
        return VoiceFollower(analyzer: analyzer, format: format, continuation: continuation, results: results)
    }

    private init(analyzer: SpeechAnalyzer, format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation,
                 results: Task<Void, Never>) {
        self.analyzer = analyzer
        self.format = format
        self.continuation = continuation
        self.results = results
        (levels, levelContinuation) = AsyncStream<Float>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    // MARK: Feeding

    /// A recorded mic buffer (on the mic writer's queue).
    func append(_ sampleBuffer: CMSampleBuffer) {
        guard let description = sampleBuffer.formatDescription,
              let buffer = AVAudioPCMBuffer.from(sampleBuffer, description: description) else { return }
        append(buffer)
    }

    /// A PCM buffer from the rehearsal mic (on the audio thread) or the recording.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let output = convert(buffer) else { return }
        continuation.yield(AnalyzerInput(buffer: output))
        publishLevel(Self.peak(of: buffer))
    }

    /// Yields the loudest peak since the last yield, at most every `levelInterval`.
    private func publishLevel(_ peak: Float) {
        let now = DispatchTime.now().uptimeNanoseconds
        let due = level.withLock { state -> Float? in
            state.peak = max(state.peak, peak)
            guard now &- state.sentAt >= Self.levelInterval else { return nil }
            defer { state = (0, now) }
            return state.peak
        }
        if let due { levelContinuation.yield(due) }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        conversion.withLock { state -> AVAudioPCMBuffer? in
            if state.input != buffer.format {
                state.input = buffer.format
                state.converter = AVAudioConverter(from: buffer.format, to: format)
            }
            guard let converter = state.converter else { return nil }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
            let input = OneShotBuffer(buffer)
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                guard let next = input.take() else { status.pointee = .noDataNow; return nil }
                status.pointee = .haveData
                return next
            }
            return error == nil && output.frameLength > 0 ? output : nil
        }
    }

    /// Rough input level 0…1 for the mic meter.
    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0] else { return 0 }
        var peak: Float = 0
        for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[i])) }
        return min(1, peak * 2)
    }

    /// Ends the input and waits for the last words to come back final, for dictation, where the tail of the
    /// sentence matters (`stop()` drops whatever is still being recognized).
    func finish() async {
        continuation.finish()
        levelContinuation.finish()
        do { try await analyzer.finalizeAndFinishThroughEndOfInput() } catch {
            Log.capture.notice("Voice finish failed: \(error.localizedDescription, privacy: .public)")
        }
        await results.value
    }

    func stop() async {
        continuation.finish()
        levelContinuation.finish()
        results.cancel()
        await analyzer.cancelAndFinishNow()
    }
}

/// Hands a buffer to AVAudioConverter's synchronous input block exactly once.
nonisolated private final class OneShotBuffer: @unchecked Sendable {
    // @unchecked Sendable: used only within one synchronous `convert` call.
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

/// The microphone for rehearsing with the prompter when nothing is recording. While recording, the recording's
/// own mic feeds the follower instead.
nonisolated final class RehearsalMic: Sendable {
    private let engine = Mutex<AVAudioEngine?>(nil)

    func start(feeding follower: VoiceFollower) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw RehearsalError.noInput }
        input.installTap(onBus: 0, bufferSize: 2048, format: format, block: Self.tap(follower))
        engine.prepare()
        try engine.start()
        self.engine.withLock { $0 = engine }
    }

    func stop() {
        guard let engine = engine.withLock({ current -> AVAudioEngine? in defer { current = nil }; return current }) else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Built outside any actor: the tap runs on the realtime audio thread.
    private static func tap(_ follower: VoiceFollower) -> AVAudioNodeTapBlock {
        { buffer, _ in follower.append(buffer) }
    }

    enum RehearsalError: LocalizedError {
        case noInput
        var errorDescription: String? { "Couldn't read from the microphone. Check the input in System Settings › Sound." }
    }
}
