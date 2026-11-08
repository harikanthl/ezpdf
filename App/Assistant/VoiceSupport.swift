//
//  VoiceSupport.swift
//  ezpdf
//
//  The few helpers Dictation and VoiceFollower used from elsewhere in ezRecord (where they were
//  lifted from): a logger, the "no audio format" error, and copying a CMSampleBuffer into a PCM
//  buffer (from ezRecord's LiveTranscriber).
//

import AVFoundation
import os

enum Log {
    static let capture = Logger(subsystem: "ai.harikanth.ezpdf", category: "voice")
}

enum Transcriber {
    enum TranscriberError: LocalizedError {
        case noFormat
        var errorDescription: String? { "Speech recognition isn't available for this microphone." }
    }
}

nonisolated extension AVAudioPCMBuffer {
    /// Copies a CMSampleBuffer's PCM audio into a new buffer in its own format.
    static func from(_ sampleBuffer: CMSampleBuffer, description: CMFormatDescription) -> AVAudioPCMBuffer? {
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                                 into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
