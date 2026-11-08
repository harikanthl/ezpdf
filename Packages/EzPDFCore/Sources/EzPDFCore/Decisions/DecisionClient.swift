//
//  DecisionClient.swift
//  ezpdf (from ezRecord's Agents/DecisionClient.swift)
//
//  Decision models ("System One"): send some state and typed questions, get typed answers with probabilities
//  back in a few hundred milliseconds instead of generated text. ezpdf uses them where code needs a small
//  judgment it can't make with rules: which instant command a request means (CommandRouter).
//
//  Three providers speak the same System One API, chosen in Settings › Assistant (`DecisionProvider`):
//  - TypeSafe's Jev (POST https://api.typesafe.ai/v1/systemone; $0.042 per million input tokens, output free): text,
//    named images and Box questions;
//  - Cloudflare's Clef / Clef-flash on Workers AI (the person's own account; $0.24 / $0.038 per million input tokens,
//    output free, within Workers AI's free daily allowance for typical use): text and up to 4 images, no Box;
//  - Laya on this Mac (`laya-serve`, open weights, free and offline): text only. Untuned it can't make our editing
//    judgments (docs/research/laya-trial-2026-10.md); it's here for people who train their own.
//  Each provider says what it can do (`canSeeImages`, `canLocate`, `maxImages`), so features fall back where it
//  can't. Keys are the person's own, in the Keychain; with none, the assistant works as before.
//
//  Questions are batched: independent questions over the same state go in one request and are answered in
//  parallel. Requests over `maxQuestions` are split and sent concurrently.
//
//  Images and Box questions (TypeSafe's preview "Dreamer-ready" features, Jev 1.14+): JPEGs go in the request's
//  `assets`, base64-encoded, keyed by a reference string that the state or instructions use in the image's place;
//  a Box answer is where something is in an image. Requests carrying either send `TypeSafe-Danger-Zone-Images: true`.
//  Images leave the Mac, so features that send them say so in their tool descriptions.
//

import CoreGraphics
import Foundation

/// Which decision model answers: chosen in Settings › Assistant, read on every call so it switches live.
public enum DecisionProvider: String, CaseIterable, Identifiable, Sendable {
    case jev, clef, laya
    public var id: Self { self }

    public var title: String {
        switch self {
        case .jev: "TypeSafe Jev"
        case .clef: "Cloudflare Clef"
        case .laya: "Laya on this Mac"
        }
    }

    public static let key = "ezpdf.decisions.provider"
    public static var chosen: DecisionProvider {
        get { UserDefaults.standard.string(forKey: key).flatMap(DecisionProvider.init(rawValue:)) ?? .jev }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

public struct DecisionClient: Sendable {
    public static let keyAccount = "typesafe.apiKey"
    /// Cloudflare: a Workers AI API token (Keychain) and the account it belongs to; the model is "clef-flash" or "clef".
    public static let clefTokenAccount = "cloudflare.workersAI.token"
    public static let clefAccountKey = "ezpdf.decisions.clef.account"
    public static let clefModelKey = "ezpdf.decisions.clef.model"
    /// Laya: a `laya-serve` URL (default this Mac) and the checkpoint to ask for.
    public static let layaEndpointKey = "ezpdf.decisions.endpoint"
    public static let layaModelKey = "ezpdf.decisions.model"
    public static let defaultLayaEndpoint = "http://127.0.0.1:8000/v1/systemone"

    /// Whether the chosen provider is set up (a key, an account and token, or a server address).
    public static var hasKey: Bool { current != nil }

    /// The chosen provider's client, or nil when it isn't set up.
    public static var current: DecisionClient? { client(for: DecisionProvider.chosen) }

    public static func client(for provider: DecisionProvider) -> DecisionClient? {
        let defaults = UserDefaults.standard
        switch provider {
        case .jev:
            return Secrets.get(keyAccount).map { DecisionClient(apiKey: $0) }
        case .clef:
            guard let token = Secrets.get(clefTokenAccount),
                  let account = defaults.string(forKey: clefAccountKey).flatMap({ $0.isEmpty ? nil : $0 }),
                  account.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
            let model = defaults.string(forKey: clefModelKey) == "clef" ? "clef" : "clef-flash"
            guard let url = URL(string: "https://api.cloudflare.com/client/v4/accounts/\(account)/ai/run/@cf/cloudflare/\(model)") else { return nil }
            return DecisionClient(apiKey: token, model: model, endpoint: url, provider: .clef)
        case .laya:
            let address = defaults.string(forKey: layaEndpointKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultLayaEndpoint
            guard let url = URL(string: address), ["http", "https"].contains(url.scheme ?? "") else { return nil }
            let model = defaults.string(forKey: layaModelKey).flatMap { $0.isEmpty ? nil : $0 } ?? "typed-decisions"
            return DecisionClient(apiKey: "local", model: model, endpoint: url, provider: .laya)
        }
    }

    public var apiKey: String
    public var model = "jev-latest"
    var endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    public var provider: DecisionProvider = .jev
    /// Questions per request; more are split into concurrent requests over the same state.
    var maxQuestions = 48

    /// Whether requests may carry images (frame review, smart zoom).
    var canSeeImages: Bool { provider != .laya }
    /// Whether it answers Box questions (where something is in an image).
    var canLocate: Bool { provider == .jev }
    /// Images one request may carry.
    var maxImages: Int { provider == .clef ? 4 : provider == .jev ? 8 : 0 }

    public enum Question: Sendable {
        /// Probability that the statement holds.
        case noul(String)
        /// One of the named options (name → what it means).
        case choice(String, [(String, String)])
        /// A position on ordered levels (lowest first).
        case score(String, [String])
        /// Where something is in an image the request carries (name the image in the instructions).
        case box(String)

        var json: [String: Any] {
            switch self {
            case .noul(let instructions):
                return ["type": "noul", "instructions": instructions]
            case .choice(let instructions, let options):
                return ["type": "choice", "instructions": instructions,
                        "criteria": Dictionary(options.map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first })]
            case .score(let instructions, let levels):
                return ["type": "score", "instructions": instructions, "criteria": levels]
            case .box(let instructions):
                return ["type": "box", "instructions": instructions]
            }
        }
    }

    public struct Answer: Sendable {
        /// Noul: probability of yes. Choice: probability of the top choice. Score: the weighted score.
        public var value: Double
        /// Choice: the top option.
        public var choice: String?
        public var confidence: Double?
        public var probabilities: [String: Double]
        /// Box: the target's bounds as fractions of the image, origin top-left (y grows down).
        public var box: CGRect?
    }

    public enum DecisionError: LocalizedError {
        case http(Int, String)
        case malformed
        case unsupported(String)

        public var errorDescription: String? {
            switch self {
            case .http(401, _), .http(403, _): "The decision model refused the key or token. Check it in Settings › Assistant › Quick decisions."
            case .http(let status, let body): "The decision model answered \(status): \(body.prefix(200))"
            case .malformed: "The decision model sent an answer ezpdf couldn't read."
            case .unsupported(let why): why
            }
        }
    }

    /// Answers every question about `state`, keyed like the questions.
    public func ask(state: Any, questions: [String: Question]) async throws -> [String: Answer] {
        try await ask(state: state, questions: questions, images: [:])
    }

    /// Like `ask(state:questions:)`, with JPEG images keyed by the reference string that stands for each one in
    /// `state` (or the instructions). Every reference must be used somewhere, or TypeSafe answers 400; images in
    /// `state` go with every split of a large batch. Each image must be 280–1568 px a side.
    public func ask(state: Any, questions: [String: Question], images: [String: Data]) async throws -> [String: Answer] {
        guard !questions.isEmpty else { return [:] }
        let batches = stride(from: 0, to: questions.count, by: maxQuestions).map { start in
            Array(questions.sorted { $0.key < $1.key }[start..<min(start + maxQuestions, questions.count)])
        }
        guard images.isEmpty || canSeeImages else { throw DecisionError.unsupported("\(provider.title) can't look at images.") }
        var top: [String: Any] = ["state": state]
        if !images.isEmpty, provider == .clef {
            // Clef takes an ordered list of data URLs, not named assets: each reference in the state becomes "image N".
            let order = images.keys.sorted()
            guard order.count <= maxImages else { throw DecisionError.unsupported("Clef takes at most \(maxImages) images a request.") }
            var text = String(decoding: try JSONSerialization.data(withJSONObject: state), as: UTF8.self)
            for (i, reference) in order.enumerated() { text = text.replacingOccurrences(of: reference, with: "image \(i + 1)") }
            top["state"] = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) ?? state
            top["images"] = order.map { "data:image/jpeg;base64," + images[$0]!.base64EncodedString() }
        } else if !images.isEmpty {
            top["assets"] = images.mapValues { ["type": "image", "format": "jpg", "data_base64": $0.base64EncodedString()] }
        }
        let body = try JSONSerialization.data(withJSONObject: top)
        return try await withThrowingTaskGroup(of: [String: Answer].self) { group in
            for batch in batches {
                group.addTask { try await send(stateJSON: body, questions: batch) }
            }
            var answers: [String: Answer] = [:]
            for try await part in group { answers.merge(part) { first, _ in first } }
            return answers
        }
    }

    private func send(stateJSON: Data, questions: [(key: String, value: Question)]) async throws -> [String: Answer] {
        guard var payload = try JSONSerialization.jsonObject(with: stateJSON) as? [String: Any] else { throw DecisionError.malformed }
        payload["model"] = model
        payload["questions"] = Dictionary(uniqueKeysWithValues: questions.map { ($0.key, $0.value.json) })
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if provider == .jev, Self.needsImagesHeader(hasAssets: payload["assets"] != nil, questions: questions.map(\.value)) {
            request.setValue("true", forHTTPHeaderField: "TypeSafe-Danger-Zone-Images")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        var (data, response) = try await URLSession.shared.data(for: request)
        // Rate limited: wait as asked (at most a few seconds) and try once more.
        if (response as? HTTPURLResponse)?.statusCode == 429 {
            let wait = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init) ?? 1
            try await Task.sleep(for: .seconds(min(max(wait, 0.2), 5)))
            (data, response) = try await URLSession.shared.data(for: request)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw DecisionError.http(status, String(decoding: data, as: UTF8.self)) }
        guard let json = Self.unwrap(try JSONSerialization.jsonObject(with: data)),
              let answers = json["answers"] as? [String: [String: Any]] else { throw DecisionError.malformed }
        return answers.compactMapValues(Self.answer)
    }

    /// Images and Box questions are off unless the request opts in with a header.
    static func needsImagesHeader(hasAssets: Bool, questions: [Question]) -> Bool {
        hasAssets || questions.contains { if case .box = $0 { true } else { false } }
    }

    /// The answer object, from Workers AI's REST envelope (`{"result": {...}, "success": true}`) or bare.
    static func unwrap(_ json: Any) -> [String: Any]? {
        guard let object = json as? [String: Any] else { return nil }
        if object["answers"] == nil, let result = object["result"] as? [String: Any] { return result }
        return object
    }

    static func answer(_ json: [String: Any]) -> Answer? {
        let probabilities = (json["probabilities"] as? [String: Any])?.compactMapValues { ($0 as? NSNumber)?.doubleValue } ?? [:]
        let confidence = (json["confidence"] as? NSNumber)?.doubleValue
        switch json["type"] as? String {
        case "noul":
            guard let p = (json["noul"] as? NSNumber)?.doubleValue else { return nil }
            return Answer(value: p, confidence: nil, probabilities: ["true": p, "false": 1 - p])
        case "choice":
            guard let choice = json["choice"] as? String else { return nil }
            return Answer(value: probabilities[choice] ?? confidence ?? 0, choice: choice, confidence: confidence, probabilities: probabilities)
        case "score":
            guard let score = (json["score"] as? NSNumber)?.doubleValue else { return nil }
            return Answer(value: score, confidence: confidence, probabilities: probabilities)
        case "box":
            guard let edges = json["box"] as? [String: Any],
                  let top = (edges["top"] as? NSNumber)?.doubleValue, let bottom = (edges["bottom"] as? NSNumber)?.doubleValue,
                  let left = (edges["left"] as? NSNumber)?.doubleValue, let right = (edges["right"] as? NSNumber)?.doubleValue
            else { return nil }
            let box = CGRect(x: min(left, right), y: min(top, bottom), width: abs(right - left), height: abs(bottom - top))
            return Answer(value: confidence ?? 0, confidence: confidence, probabilities: [:], box: box)
        default:
            return nil
        }
    }
}
