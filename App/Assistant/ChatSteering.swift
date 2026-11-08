//
//  ChatSteering.swift
//  ezpdf (lifted from ezRecord)
//
//  What typing does while the assistant is working (the idea of Operator's wake router, lifted from qm): nothing
//  running → a new request; running and the note is a halt word ("stop", "cancel") → stop; running and anything
//  else → steer, so the next step follows it ("make it shorter", "use the blue style") without starting over.
//  Only an exact halt word stops, so "stop cutting the pauses" steers rather than stops.
//
//  Pure: nonisolated, unit-tested.
//

import Foundation

nonisolated enum ChatSteering {
    enum Route: Equatable, Sendable { case send, stop, steer }

    static let haltWords: Set<String> = ["stop", "cancel", "abort", "halt", "wait", "hold on", "never mind", "nevermind", "stop it", "stop that"]

    static func route(_ text: String, isBusy: Bool) -> Route {
        guard isBusy else { return .send }
        let words = text.lowercased().filter { $0.isLetter || $0 == " " }.split(separator: " ").joined(separator: " ")
        if words.isEmpty { return .send }
        return haltWords.contains(words) ? .stop : .steer
    }
}
