import Foundation
import AppKit
import ImageIO
import Vision
import Security
import CoreImage
import UniformTypeIdentifiers
#if canImport(ImagePlayground)
import ImagePlayground
#endif

/// Logo and image generation for putting on PDFs.
/// - Apple Image Playground: on this Mac, free, no key (needs Apple Intelligence and the app in front).
/// - fal.ai (FLUX, Recraft, Ideogram, any live fal text-to-image model): the queue API, ported from
///   MuseDrop's FalClient: submit, poll status_url with backoff, fetch response_url, cancel the remote
///   job if abandoned. The key only ever goes to fal's API hosts.
/// - OpenAI image models, and OpenRouter image models (shares the assistant's OpenRouter key).
/// Keys live in the Keychain (service ai.harikanth.ezpdf.apikeys).
public enum ImageGen {
    public enum Provider: String, CaseIterable, Identifiable, Sendable {
        case apple, fal, openai, openrouter
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .apple: return "Apple Image Playground"
            case .fal: return "fal.ai"
            case .openai: return "OpenAI"
            case .openrouter: return "OpenRouter"
            }
        }
        public var keyAccount: String? {
            switch self {
            case .apple: return nil
            case .fal: return "image.fal.apiKey"
            case .openai: return "image.openai.apiKey"
            case .openrouter: return "operator.llm.openrouter.apiKey"   // the assistant's OpenRouter key
            }
        }
        public var keyURL: URL? {
            switch self {
            case .apple: return nil
            case .fal: return URL(string: "https://fal.ai/dashboard/keys")
            case .openai: return URL(string: "https://platform.openai.com/api-keys")
            case .openrouter: return URL(string: "https://openrouter.ai/keys")
            }
        }
    }

    public struct Model: Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let provider: Provider
        public let note: String
        public init(id: String, name: String, provider: Provider, note: String) {
            self.id = id; self.name = name; self.provider = provider; self.note = note
        }
    }

    /// Built-in choices. FLUX ids are the ones MuseDrop ships; Recraft and Ideogram are logo-friendly.
    /// The Models page adds every current fal and catalog image model.
    public static let models: [Model] = [
        Model(id: "apple", name: "Image Playground", provider: .apple, note: "Free, private. Illustration style."),
        Model(id: "fal-ai/recraft/v3/text-to-image", name: "Recraft V3", provider: .fal, note: "Clean logos and vector-style marks."),
        Model(id: "fal-ai/ideogram/v3", name: "Ideogram 3", provider: .fal, note: "Best at letters and words in logos."),
        Model(id: "fal-ai/flux/schnell", name: "FLUX schnell", provider: .fal, note: "Fast and cheap drafts."),
        Model(id: "fal-ai/flux-2-pro", name: "FLUX.2 pro", provider: .fal, note: "Highest detail."),
        Model(id: "gpt-image-1", name: "GPT Image", provider: .openai, note: "Transparent backgrounds."),
    ]

    /// Models found in the catalogs (set on the main actor by the app's catalog store).
    @MainActor public static var extraModels: [Model] = []

    @MainActor public static var allModels: [Model] {
        var seen = Set(models.map(\.id))
        return models + extraModels.filter { seen.insert($0.id).inserted }
    }

    /// The saved choice, or nil when it's no longer available (so callers can say so rather than
    /// silently switching models).
    @MainActor public static func savedModel(id: String?) -> Model? {
        guard let id else { return nil }
        return allModels.first { $0.id == id }
    }

    @MainActor public static func model(id: String?) -> Model { savedModel(id: id) ?? models[0] }

    public enum Style: String, CaseIterable, Identifiable, Sendable {
        case minimal = "Minimal mark", lettermark = "Lettermark", emblem = "Emblem", mascot = "Mascot", stamp = "Rubber stamp", seal = "Seal"
        public var id: String { rawValue }
        var phrase: String {
            switch self {
            case .minimal: return "a minimal modern logo mark, flat vector, bold simple shapes, 2-3 colors"
            case .lettermark: return "a lettermark logo built from the initials, flat vector, crisp geometric letterforms"
            case .emblem: return "an emblem logo inside a badge shape, flat vector, balanced and symmetric"
            case .mascot: return "a friendly mascot logo character, clean flat illustration, thick outlines"
            case .stamp: return "a rubber stamp design with a round border and bold text, single ink color, slightly worn texture"
            case .seal: return "an official-looking round seal with a ring of text and a star in the middle, single color"
            }
        }
        /// Styles built from lettering, where cutting out a "subject" can drop the words.
        public var isLettering: Bool { self == .lettermark || self == .stamp || self == .seal }
    }

    public static func prompt(_ user: String, style: Style) -> String {
        "\(style.phrase). \(user). Centered on a plain white background with generous padding, no mockup, no extra text unless asked, high contrast, readable at small sizes."
    }

    // MARK: Keys

    nonisolated(unsafe) private static var readyCache: [Provider: Bool] = [:]
    private static let cacheLock = NSLock()

    /// The secret itself: read only when making a request.
    public static func key(_ provider: Provider) -> String? {
        provider.keyAccount.flatMap(Secrets.get)
    }

    /// Whether a key is saved, without decrypting it (cached, cheap enough for UI).
    public static func hasKey(_ provider: Provider) -> Bool {
        guard let account = provider.keyAccount else { return true }
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let v = readyCache[provider] { return v }
        let found = Secrets.has(account)
        readyCache[provider] = found
        return found
    }

    /// Forgets cached key presence (after keys change elsewhere, e.g. the assistant's settings).
    public static func refreshKeyState() { cacheLock.lock(); readyCache = [:]; cacheLock.unlock() }

    @discardableResult
    public static func setKey(_ value: String?, for provider: Provider) -> OSStatus {
        guard let account = provider.keyAccount else { return errSecParam }
        defer { refreshKeyState() }
        return Secrets.set(value, for: account)
    }

    public static func isReady(_ provider: Provider) -> Bool {
        provider == .apple ? appleUsable != false : hasKey(provider)
    }

    /// nil until tried; false once Image Playground said it can't run on this Mac.
    nonisolated(unsafe) public private(set) static var appleUsable: Bool? = nil

    // MARK: Generate

    public enum GenError: LocalizedError {
        case noKey(Provider), failed(String)
        public var errorDescription: String? {
            switch self {
            case .noKey(let p): return "Add your \(p.displayName) key in ezpdf Settings › \(p == .openrouter ? "Assistant" : "Assistant › Images")."
            case .failed(let s): return s
            }
        }
    }

    /// Returns image data for each result (1…4). Cancelling the task cancels remote work where the
    /// provider supports it.
    public static func generate(prompt: String, model: Model, count: Int = 2) async throws -> [Data] {
        let n = max(1, min(count, 4))
        let p = String(prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        guard !p.isEmpty else { throw GenError.failed("Describe the image first.") }
        let out: [Data]
        switch model.provider {
        case .apple: out = try await apple(p, count: n)
        case .fal: out = try await fal(p, model: model.id, count: n)
        case .openai: out = try await openAI(p, model: model.id, count: n)
        case .openrouter: out = try await openRouter(p, model: model.id, count: n)
        }
        guard !out.isEmpty else { throw GenError.failed("\(model.provider.displayName) returned no usable images. Try again or pick another model.") }
        return out
    }

    static func apple(_ prompt: String, count: Int) async throws -> [Data] {
        #if canImport(ImagePlayground)
        do {
            let creator = try await ImageCreator()
            appleUsable = true
            let style = creator.availableStyles.first { $0 == .illustration } ?? creator.availableStyles.first
            guard let style else { throw GenError.failed("Image Playground has no styles available on this Mac.") }
            var out: [Data] = []
            for try await image in creator.images(for: [.text(String(prompt.prefix(900)))], style: style, limit: count) {
                if let png = PDFRaster.encode(image.cgImage, type: .png) { out.append(png) }
            }
            return out
        } catch let e as GenError {
            throw e
        } catch {
            let text = "\(error)".lowercased()
            if text.contains("background") || text.contains("hidden") {
                throw GenError.failed("Image Playground only works while ezpdf is the front window. Bring ezpdf forward, or pick a fal.ai, OpenAI or OpenRouter model.")
            }
            appleUsable = false
            throw GenError.failed("Image Playground isn't available on this Mac (it needs Apple Intelligence). Pick a fal.ai, OpenAI or OpenRouter model in Settings › Models.")
        }
        #else
        appleUsable = false
        throw GenError.failed("Image Playground isn't available on this Mac.")
        #endif
    }

    // MARK: fal

    /// Only fal's API hosts receive the key (as MuseDrop): `fal.run`, `*.fal.run`, `fal.ai`, `*.fal.ai`, https only.
    static func isTrustedFalURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), !host.isEmpty else { return false }
        return host == "fal.run" || host.hasSuffix(".fal.run") || host == "fal.ai" || host.hasSuffix(".fal.ai")
    }

    /// Where result images may be downloaded from (no key is sent there).
    static func isFalResultHost(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host.hasSuffix(".fal.media") || host == "fal.media" || isTrustedFalURL(url)
            || host == "storage.googleapis.com" || host.hasSuffix(".storage.googleapis.com")
    }

    /// fal's `error` (string or {message}) plus `error_type`, or nil when neither is set (ported).
    static func falErrorText(_ obj: [String: Any]) -> String? {
        var parts: [String] = []
        if let e = obj["error"] as? String, !e.isEmpty { parts.append(e) }
        else if let e = obj["error"] as? [String: Any], let m = (e["message"] as? String) ?? (e["msg"] as? String) { parts.append(m) }
        if let t = obj["error_type"] as? String, !t.isEmpty { parts.append("(\(t))") }
        return parts.isEmpty ? nil : "fal.ai: " + parts.joined(separator: " ")
    }

    static func retryAfter(_ r: URLResponse) -> TimeInterval? {
        guard let v = (r as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"), let s = Double(v.trimmingCharacters(in: .whitespaces)) else { return nil }
        return max(0, s)
    }

    static func backoff(_ attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        let exp = min(30, 0.8 * pow(2, Double(min(attempt, 8))))
        return min(120, max(retryAfter ?? 0, exp))
    }

    static func fal(_ prompt: String, model: String, count: Int) async throws -> [Data] {
        guard let key = key(.fal) else { throw GenError.noKey(.fal) }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./"))
        guard !model.isEmpty, model.unicodeScalars.allSatisfy(allowed.contains), !model.contains("..") else { throw GenError.failed("Bad fal model id.") }
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        func request(_ url: URL, method: String = "GET", body: Data? = nil) -> URLRequest {
            var r = URLRequest(url: url, timeoutInterval: 60)
            r.httpMethod = method
            r.setValue("Key \(key)", forHTTPHeaderField: "Authorization")
            if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            return r
        }
        var input: [String: Any] = ["prompt": prompt, "num_images": count, "image_size": "square_hd"]
        if model.contains("recraft") { input["style"] = "vector_illustration" }
        else if model.contains("ideogram") { input["style"] = "DESIGN" }
        guard let submitURL = URL(string: "https://queue.fal.run/\(model)") else { throw GenError.failed("Bad fal model id.") }
        let (subData, subResp) = try await session.data(for: request(submitURL, method: "POST", body: try JSONSerialization.data(withJSONObject: input)))
        try check(subResp, subData, provider: "fal.ai")
        guard let sub = try JSONSerialization.jsonObject(with: subData) as? [String: Any],
              let statusS = sub["status_url"] as? String, let responseS = sub["response_url"] as? String,
              let statusURL = URL(string: statusS), let responseURL = URL(string: responseS),
              isTrustedFalURL(statusURL), isTrustedFalURL(responseURL) else {
            throw GenError.failed("fal.ai returned a queue address on an unexpected host; your key wasn't sent there.")
        }
        // On abandonment (cancel, timeout, error) tell fal to stop, so the job isn't billed for nothing.
        let cancelURL: URL? = (sub["cancel_url"] as? String).flatMap(URL.init(string:)).flatMap { isTrustedFalURL($0) ? $0 : nil }
            ?? (statusS.hasSuffix("/status") ? URL(string: String(statusS.dropLast(7)) + "/cancel") : nil)
        func cancelRemote() {
            guard let cancelURL else { return }
            let r = request(cancelURL, method: "PUT")
            Task.detached { _ = try? await URLSession.shared.data(for: r) }
        }
        let deadline = Date().addingTimeInterval(180)
        do {
            var attempt = 0
            while true {
                try Task.checkCancellation()
                guard Date() < deadline else { throw GenError.failed("fal.ai took longer than 3 minutes.") }
                let (d, r) = try await session.data(for: request(statusURL))
                if (r as? HTTPURLResponse)?.statusCode == 429 {
                    let wait = min(backoff(attempt, retryAfter: retryAfter(r)), max(0.1, deadline.timeIntervalSinceNow))
                    attempt += 1
                    try await Task.sleep(for: .seconds(wait))
                    continue
                }
                try check(r, d, provider: "fal.ai")
                attempt = 0
                let obj = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
                let status = (obj["status"] as? String ?? "").uppercased()
                if status == "COMPLETED" || status == "OK" {
                    if let failure = falErrorText(obj) { throw GenError.failed(failure) }
                    break
                }
                if status == "ERROR" || status == "FAILED" { throw GenError.failed(falErrorText(obj) ?? "fal.ai: the job failed.") }
                try await Task.sleep(for: .milliseconds(900))
            }
            // The result: retried on 429 (the job is done and billed).
            var resultData = Data()
            for tries in 0..<8 {
                let (rd, rr) = try await session.data(for: request(responseURL))
                if (rr as? HTTPURLResponse)?.statusCode == 429, tries < 7 {
                    try await Task.sleep(for: .seconds(backoff(tries, retryAfter: retryAfter(rr)))); continue
                }
                try check(rr, rd, provider: "fal.ai")
                resultData = rd
                break
            }
            let result = (try? JSONSerialization.jsonObject(with: resultData) as? [String: Any]) ?? [:]
            if result["error_type"] != nil, let failure = falErrorText(result) { throw GenError.failed(failure) }
            let urls = ((result["images"] as? [[String: Any]]) ?? []).compactMap { ($0["url"] as? String) }
            var out: [Data] = []
            for u in urls.prefix(count) {
                if u.hasPrefix("data:") {
                    if u.utf8.count < 40_000_000, let d = EPUBBuilder.decodeDataURL(u), isImage(d) { out.append(d) }
                } else if let url = URL(string: u), isFalResultHost(url), let d = await downloadImage(url) {
                    out.append(d)
                }
            }
            return out
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? GenError) != nil { cancelRemote() }
            throw error
        }
    }

    /// Downloads a result image: https only, no redirects off the host, at most 25 MB, must decode.
    static func downloadImage(_ url: URL) async -> Data? {
        let dl = GuardedDownload()
        defer { dl.finish() }
        guard case .data(let d, _)? = try? await dl.fetch(url, maxBytes: 25_000_000), isImage(d) else { return nil }
        return d
    }

    static func isImage(_ d: Data) -> Bool {
        guard let src = CGImageSourceCreateWithData(d as CFData, nil) else { return false }
        return CGImageSourceGetCount(src) > 0
    }

    // MARK: OpenAI, OpenRouter

    static func openAI(_ prompt: String, model: String, count: Int) async throws -> [Data] {
        guard let key = key(.openai) else { throw GenError.noKey(.openai) }
        var r = URLRequest(url: URL(string: "https://api.openai.com/v1/images/generations")!, timeoutInterval: 180)
        r.httpMethod = "POST"
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["model": model.isEmpty ? "gpt-image-1" : model, "prompt": prompt, "n": count,
                                                                  "size": "1024x1024", "background": "transparent"])
        let (d, resp) = try await URLSession.shared.data(for: r)
        try check(resp, d, provider: "OpenAI")
        let obj = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        return ((obj["data"] as? [[String: Any]]) ?? []).compactMap { ($0["b64_json"] as? String).flatMap { Data(base64Encoded: $0) } }.filter(isImage)
    }

    /// OpenRouter image models answer a chat request with images (`modalities: ["image", "text"]`).
    static func openRouter(_ prompt: String, model: String, count: Int) async throws -> [Data] {
        guard let key = key(.openrouter) else { throw GenError.noKey(.openrouter) }
        var out: [Data] = []
        var lastError: String?
        for _ in 0..<count {
            try Task.checkCancellation()
            var r = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!, timeoutInterval: 180)
            r.httpMethod = "POST"
            r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue("https://github.com/harikanthl/ezpdf", forHTTPHeaderField: "HTTP-Referer")
            r.setValue("ezpdf", forHTTPHeaderField: "X-Title")
            r.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model, "modalities": ["image", "text"],
                "messages": [["role": "user", "content": "Generate this image: " + prompt]],
            ])
            do {
                let (d, resp) = try await URLSession.shared.data(for: r)
                try check(resp, d, provider: "OpenRouter")
                let obj = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
                if let e = obj["error"] as? [String: Any] { lastError = "OpenRouter: \(e["message"] ?? "error")"; continue }
                let message = ((obj["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]) ?? [:]
                for img in (message["images"] as? [[String: Any]]) ?? [] {
                    guard let u = (img["image_url"] as? [String: Any])?["url"] as? String else { continue }
                    if u.hasPrefix("data:"), u.utf8.count < 40_000_000, let data = EPUBBuilder.decodeDataURL(u), isImage(data) { out.append(data) }
                }
            } catch let e as CancellationError {
                throw e
            } catch {
                lastError = error.localizedDescription
                if !out.isEmpty { break }      // keep what came back
            }
        }
        if out.isEmpty, let lastError { throw GenError.failed(lastError) }
        return out
    }

    static func check(_ resp: URLResponse, _ data: Data, provider: String) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        let message: String? = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { o -> String? in
            if let d = o["detail"] as? String { return d }
            if let e = o["error"] as? [String: Any] { return e["message"] as? String }
            return o["error"] as? String
        }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw GenError.failed("\(provider) didn't accept the key. Check it in Settings › Assistant › Images.")
        case 403: throw GenError.failed("\(provider) refused the request\(message.map { ": \($0)" } ?? ". The key may not have access to this model.")")
        case 429: throw GenError.failed("\(provider) is rate limiting; try again shortly.")
        default: throw GenError.failed("\(provider) error \(http.statusCode)\(message.map { ": \($0)" } ?? "")")
        }
    }

    // MARK: Background removal

    private static let ciContext = CIContext(options: [.outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    /// Cuts the subject out (on this Mac, Vision) and returns a transparent PNG trimmed to it. Runs off
    /// the main thread. Images that already have transparency are returned as they are; for lettering
    /// styles, a cut that drops most of the drawing falls back to keeping the original.
    public static func removeBackground(_ data: Data, lettering: Bool = false) async throws -> Data {
        try await Task.detached(priority: .userInitiated) { try cutOut(data, lettering: lettering) }.value
    }

    static func cutOut(_ data: Data, lettering: Bool) throws -> Data {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                    kCGImageSourceCreateThumbnailWithTransform: true,
                                                                    kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary) else {
            throw GenError.failed("That image couldn't be read.")
        }
        if hasTransparency(cg) { return PDFRaster.encode(cg, type: .png) ?? data }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg)
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else { throw GenError.failed("No subject found to keep.") }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: true)
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let out = ciContext.createCGImage(ci, from: ci.extent) else { throw GenError.failed("Couldn't remove the background.") }
        // Words around a seal or stamp can be read as background; if most of the drawing vanished, keep the original.
        if lettering, Double(out.width * out.height) < 0.35 * Double(cg.width * cg.height) {
            return PDFRaster.encode(cg, type: .png) ?? data
        }
        guard let png = PDFRaster.encode(out, type: .png) else { throw GenError.failed("Couldn't remove the background.") }
        return png
    }

    static func hasTransparency(_ cg: CGImage) -> Bool {
        switch cg.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        // Sample: any pixel noticeably transparent.
        let w = min(cg.width, 256), h = min(cg.height, 256)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let px = { ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h)); return ctx.data?.assumingMemoryBound(to: UInt8.self) }() else { return false }
        for i in stride(from: 3, to: w * h * 4, by: 4) where px[i] < 200 { return true }
        return false
    }
}
