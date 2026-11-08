import Foundation
import AppKit
import ImageIO
import Vision
import Security
import UniformTypeIdentifiers
#if canImport(ImagePlayground)
import ImagePlayground
#endif

/// Logo and image generation for putting on PDFs.
/// - Apple Image Playground: on this Mac, free, no key.
/// - fal.ai (FLUX, Recraft, Ideogram): the queue API, ported from MuseDrop's FalClient: submit to
///   queue.fal.run/<model>, poll status_url, fetch response_url. The key only ever goes to fal hosts.
/// - OpenAI image generation (transparent backgrounds).
/// Keys live in the Keychain (service ai.harikanth.ezpdf.apikeys).
public enum ImageGen {
    public enum Provider: String, CaseIterable, Identifiable, Sendable {
        case apple, fal, openai, openrouter
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .apple: return "Apple Image Playground (free, on this Mac)"
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
            // Shares the assistant's OpenRouter key (Settings › Assistant).
            case .openrouter: return "operator.llm.openrouter.apiKey"
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

    /// Models found in the catalogs (Operator's catalog worker, fal's live list), set by the app.
    nonisolated(unsafe) public static var extraModels: [Model] = []

    /// Built-in models first, then catalog ones not already listed.
    public static var allModels: [Model] {
        var seen = Set(models.map(\.id))
        return models + extraModels.filter { seen.insert($0.id).inserted }
    }

    public static func model(id: String?) -> Model {
        allModels.first { $0.id == id } ?? models[0]
    }

    /// fal model ids: FLUX ids are the ones MuseDrop ships; Recraft and Ideogram are logo-friendly
    /// (check fal.ai/models if one is renamed; any fal text-to-image id can be typed in Settings).
    public static let models: [Model] = [
        Model(id: "apple", name: "Image Playground", provider: .apple, note: "Free, private. Illustration style."),
        Model(id: "fal-ai/recraft/v3/text-to-image", name: "Recraft V3", provider: .fal, note: "Clean logos and vector-style marks."),
        Model(id: "fal-ai/ideogram/v3", name: "Ideogram 3", provider: .fal, note: "Best at letters and words in logos."),
        Model(id: "fal-ai/flux/schnell", name: "FLUX schnell", provider: .fal, note: "Fast and cheap drafts."),
        Model(id: "fal-ai/flux-2-pro", name: "FLUX.2 pro", provider: .fal, note: "Highest detail."),
        Model(id: "gpt-image-1", name: "GPT Image", provider: .openai, note: "Transparent backgrounds."),
    ]

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
    }

    /// The prompt sent to the model: the user's words plus logo-friendly framing.
    public static func prompt(_ user: String, style: Style) -> String {
        "\(style.phrase). \(user). Centered on a plain white background with generous padding, no mockup, no extra text unless asked, high contrast, readable at small sizes."
    }

    // MARK: Keys

    static let service = "ai.harikanth.ezpdf.apikeys"

    public static func key(_ provider: Provider) -> String? {
        guard let account = provider.keyAccount else { return nil }
        for dataProtection in [true, false] {
            var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
            var out: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data, let s = String(data: d, encoding: .utf8), !s.isEmpty { return s }
        }
        return nil
    }

    @discardableResult
    public static func setKey(_ value: String?, for provider: Provider) -> OSStatus {
        guard let account = provider.keyAccount else { return errSecParam }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return errSecSuccess }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil)
    }

    public static func isReady(_ provider: Provider) -> Bool {
        switch provider {
        case .apple: return appleAvailable
        default: return key(provider) != nil
        }
    }

    public static var appleAvailable: Bool {
        #if canImport(ImagePlayground)
        return true
        #else
        return false
        #endif
    }

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

    /// Returns PNG data for each image (1…4).
    public static func generate(prompt: String, model: Model, count: Int = 2) async throws -> [Data] {
        let n = max(1, min(count, 4))
        switch model.provider {
        case .apple: return try await apple(prompt, count: n)
        case .fal: return try await fal(prompt, model: model.id, count: n)
        case .openai: return try await openAI(prompt, count: n)
        case .openrouter: return try await openRouter(prompt, model: model.id, count: n)
        }
    }

    static func apple(_ prompt: String, count: Int) async throws -> [Data] {
        #if canImport(ImagePlayground)
        let creator = try await ImageCreator()
        let style = creator.availableStyles.first { $0 == .illustration } ?? creator.availableStyles.first
        guard let style else { throw GenError.failed("Image Playground isn't available on this Mac.") }
        var out: [Data] = []
        for try await image in creator.images(for: [.text(String(prompt.prefix(900)))], style: style, limit: count) {
            if let png = PDFRaster.encode(image.cgImage, type: .png) { out.append(png) }
        }
        return out
        #else
        throw GenError.failed("Image Playground isn't available on this Mac.")
        #endif
    }

    static func isTrustedFalURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), !host.isEmpty else { return false }
        return host == "fal.run" || host.hasSuffix(".fal.run") || host == "fal.ai" || host.hasSuffix(".fal.ai") || host.hasSuffix(".fal.media")
    }

    static func fal(_ prompt: String, model: String, count: Int) async throws -> [Data] {
        guard let key = key(.fal) else { throw GenError.noKey(.fal) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        func request(_ url: URL, method: String = "GET", body: Data? = nil) -> URLRequest {
            var r = URLRequest(url: url, timeoutInterval: 60)
            r.httpMethod = method
            r.setValue("Key \(key)", forHTTPHeaderField: "Authorization")
            if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            return r
        }
        var input: [String: Any] = ["prompt": prompt, "num_images": count]
        if model.contains("recraft") { input["style"] = "vector_illustration"; input["image_size"] = "square_hd" }
        else if model.contains("ideogram") { input["image_size"] = "square_hd"; input["style"] = "DESIGN" }
        else { input["image_size"] = "square_hd" }
        guard let submitURL = URL(string: "https://queue.fal.run/\(model)") else { throw GenError.failed("Bad model id.") }
        let (subData, subResp) = try await session.data(for: request(submitURL, method: "POST", body: try JSONSerialization.data(withJSONObject: input)))
        try check(subResp, subData, provider: "fal.ai")
        guard let sub = try JSONSerialization.jsonObject(with: subData) as? [String: Any],
              let statusS = sub["status_url"] as? String, let responseS = sub["response_url"] as? String,
              let statusURL = URL(string: statusS), let responseURL = URL(string: responseS),
              isTrustedFalURL(statusURL), isTrustedFalURL(responseURL) else {
            throw GenError.failed("fal.ai returned an unexpected response.")
        }
        let deadline = Date().addingTimeInterval(180)
        while true {
            try Task.checkCancellation()
            guard Date() < deadline else { throw GenError.failed("fal.ai took too long.") }
            let (d, r) = try await session.data(for: request(statusURL))
            if (r as? HTTPURLResponse)?.statusCode == 429 { try await Task.sleep(for: .seconds(2)); continue }
            try check(r, d, provider: "fal.ai")
            let obj = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
            let status = (obj["status"] as? String ?? "").uppercased()
            if status == "COMPLETED" || status == "OK" {
                if let e = obj["error"] { throw GenError.failed("fal.ai: \(e)") }
                break
            }
            if status == "ERROR" || status == "FAILED" { throw GenError.failed("fal.ai: \(obj["error"] ?? "the job failed")") }
            try await Task.sleep(for: .milliseconds(900))
        }
        let (rd, rr) = try await session.data(for: request(responseURL))
        try check(rr, rd, provider: "fal.ai")
        let result = (try? JSONSerialization.jsonObject(with: rd) as? [String: Any]) ?? [:]
        let urls = ((result["images"] as? [[String: Any]]) ?? []).compactMap { ($0["url"] as? String).flatMap(URL.init(string:)) }
        guard !urls.isEmpty else { throw GenError.failed("fal.ai returned no images.") }
        var out: [Data] = []
        for u in urls.prefix(count) {
            // Images come from fal's CDN (or inline data URLs); never send the key there.
            if u.scheme == "data" { if let d = EPUBBuilder.decodeDataURL(u.absoluteString) { out.append(d) }; continue }
            guard u.scheme == "https" else { continue }
            let (d, r) = try await URLSession.shared.data(from: u)
            if (r as? HTTPURLResponse)?.statusCode == 200, d.count < 30_000_000 { out.append(d) }
        }
        return out
    }

    static func openAI(_ prompt: String, count: Int) async throws -> [Data] {
        guard let key = key(.openai) else { throw GenError.noKey(.openai) }
        var r = URLRequest(url: URL(string: "https://api.openai.com/v1/images/generations")!, timeoutInterval: 180)
        r.httpMethod = "POST"
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["model": "gpt-image-1", "prompt": prompt, "n": count,
                                                                  "size": "1024x1024", "background": "transparent"])
        let (d, resp) = try await URLSession.shared.data(for: r)
        try check(resp, d, provider: "OpenAI")
        let obj = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        let images = ((obj["data"] as? [[String: Any]]) ?? []).compactMap { ($0["b64_json"] as? String).flatMap { Data(base64Encoded: $0) } }
        guard !images.isEmpty else { throw GenError.failed("OpenAI returned no images.") }
        return images
    }

    /// OpenRouter image models answer a chat request with images (`modalities: ["image", "text"]`).
    static func openRouter(_ prompt: String, model: String, count: Int) async throws -> [Data] {
        guard let key = key(.openrouter) else { throw GenError.noKey(.openrouter) }
        var out: [Data] = []
        for _ in 0..<count {
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
            let (d, resp) = try await URLSession.shared.data(for: r)
            try check(resp, d, provider: "OpenRouter")
            let obj = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
            let message = ((obj["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]) ?? [:]
            for img in (message["images"] as? [[String: Any]]) ?? [] {
                if let u = (img["image_url"] as? [String: Any])?["url"] as? String {
                    if u.hasPrefix("data:"), let data = EPUBBuilder.decodeDataURL(u) { out.append(data) }
                    else if let url = URL(string: u), url.scheme == "https", let (data, _) = try? await URLSession.shared.data(from: url) { out.append(data) }
                }
            }
        }
        guard !out.isEmpty else { throw GenError.failed("That model didn't return an image. Pick an image model.") }
        return out
    }

    static func check(_ resp: URLResponse, _ data: Data, provider: String) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw GenError.failed("\(provider) didn't accept the key. Check it in Settings → Assistant → Images.")
        case 429: throw GenError.failed("\(provider) is rate limiting; try again shortly.")
        default:
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { ($0["detail"] ?? ($0["error"] as? [String: Any])?["message"] ?? $0["error"]) }
            throw GenError.failed("\(provider) error \(http.statusCode)\(msg.map { ": \($0)" } ?? "")")
        }
    }

    // MARK: Background removal

    /// Cuts the subject out (on this Mac, Vision) and returns a transparent PNG, trimmed to the subject.
    public static func removeBackground(_ data: Data) throws -> Data {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw GenError.failed("That image couldn't be read.")
        }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg)
        try handler.perform([request])
        guard let result = request.results?.first else { throw GenError.failed("No subject found to keep.") }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: true)
        let ci = CIImage(cvPixelBuffer: buffer)
        let ctx = CIContext()
        guard let out = ctx.createCGImage(ci, from: ci.extent), let png = PDFRaster.encode(out, type: .png) else {
            throw GenError.failed("Couldn't remove the background.")
        }
        return png
    }
}
