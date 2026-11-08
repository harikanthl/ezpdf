import Foundation
import Network
import Observation
import CryptoKit
import AppKit

/// Who is calling. Remote callers (bots through TopRelay) get fewer powers than local ones.
struct CallContext {
    /// True when the request came through a relay (forwarded headers present).
    var isRemote: Bool
    var client: String?
}

/// One small HTTP/1.1 server on 127.0.0.1 that serves:
///   POST /mcp          MCP (Streamable HTTP, stateless JSON responses) for agents, Claude, TopRelay → Grok/ChatGPT
///   /ext/*             a tiny REST API for the paired ezpdf browser extension
/// Security:
///   - loopback only; `Host` must be localhost (blocks DNS rebinding); web-page Origins are refused
///   - /mcp needs the MCP token; /ext needs the extension token, which the user grants once in the app
///   - strict request parsing: header and body caps, no chunked bodies, per-connection deadlines,
///     a cap on open connections
@MainActor
@Observable
public final class LocalServer {
    public static let shared = LocalServer()
    nonisolated public static let defaultPort: UInt16 = 7337

    public private(set) var isRunning = false
    public private(set) var port: UInt16 = LocalServer.defaultPort
    public private(set) var lastError: String?
    public private(set) var requestCount = 0
    public private(set) var lastClient: String?

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private let queue = DispatchQueue(label: "ezpdf.server")
    @ObservationIgnored private let limiter = ConnectionLimiter(max: 32)
    @ObservationIgnored lazy var mcp = MCPHandler(ops: EzPDF.shared)

    public var mcpURL: String { "http://127.0.0.1:\(port)/mcp" }

    // MARK: Tokens

    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ezpdf")
    }
    public static var tokenFile: URL { supportDir.appendingPathComponent("mcp-token") }
    static var extensionTokenFile: URL { supportDir.appendingPathComponent("extension-token") }

    private static var cachedToken: String?
    private static var cachedExtensionToken: String?

    /// The MCP token: created once, kept in a 0600 file so local tools can read it, cached in memory.
    public static var token: String {
        if let t = cachedToken { return t }
        if let t = readSecret(tokenFile, prefix: "ezp_") { cachedToken = t; return t }
        return rotateToken()
    }

    /// Replaces the MCP token. Anything using the old one (agents, TopRelay) must be updated.
    @discardableResult
    public static func rotateToken() -> String {
        let t = "ezp_" + randomHex()
        writeSecret(t, to: tokenFile)
        cachedToken = t
        return t
    }

    /// The token the paired browser extension presents; nil until the user approves pairing.
    static var extensionToken: String? {
        if let t = cachedExtensionToken { return t }
        cachedExtensionToken = readSecret(extensionTokenFile, prefix: "ezx_")
        return cachedExtensionToken
    }

    static func makeExtensionToken() -> String {
        if let t = extensionToken { return t }
        let t = "ezx_" + randomHex()
        writeSecret(t, to: extensionTokenFile)
        cachedExtensionToken = t
        return t
    }

    /// Forgets the extension's token; the extension has to be paired again.
    public static func unpairExtension() {
        try? FileManager.default.removeItem(at: extensionTokenFile)
        cachedExtensionToken = nil
    }

    public static var isExtensionPaired: Bool { extensionToken != nil }

    private static func randomHex() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Fall back to CryptoKit's generator rather than ever using zeros.
            bytes = Array(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func readSecret(_ url: URL, prefix: String) -> String? {
        guard let t = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              t.hasPrefix(prefix), t.count >= 36 else { return nil }
        return t
    }

    /// Writes a secret so it's never readable by others, even for a moment.
    private static func writeSecret(_ s: String, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard fm.createFile(atPath: tmp.path, contents: Data(s.utf8), attributes: [.posixPermissions: 0o600]) else { return }
        _ = try? fm.replaceItemAt(url, withItemAt: tmp)
        if fm.fileExists(atPath: tmp.path) { try? fm.removeItem(at: tmp) }
    }

    // MARK: Lifecycle

    public func start(port: UInt16 = LocalServer.defaultPort) {
        stop()
        self.port = port
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            let l = try NWListener(using: params)
            let limiter = self.limiter
            let queue = self.queue
            l.newConnectionHandler = { [weak self] conn in
                // On the server queue: refuse when too many connections are open.
                guard limiter.acquire() else { conn.cancel(); return }
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .cancelled, .failed: limiter.release()
                    default: break
                    }
                }
                conn.start(queue: queue)
                RequestReader(conn: conn, queue: queue) { result in
                    Task { @MainActor in
                        guard let self else { conn.cancel(); return }
                        let response: HTTPResponse
                        switch result {
                        case .request(let req): response = await self.route(req)
                        case .reject(let status, let message): response = .json(status, ["error": message])
                        }
                        conn.send(content: response.serialize(), completion: .contentProcessed { _ in conn.cancel() })
                    }
                }.start()
            }
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready: self?.isRunning = true; self?.lastError = nil
                    case .failed(let e): self?.isRunning = false; self?.lastError = "Port \(port): \(e.localizedDescription)"
                    case .cancelled: self?.isRunning = false
                    default: break
                    }
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: Routing

    private func route(_ req: HTTPRequest) async -> HTTPResponse {
        requestCount += 1
        // DNS rebinding: a page on evil.com resolving to 127.0.0.1 still sends Host: evil.com.
        let host = (req.headers["host"] ?? "").lowercased()
        guard host == "127.0.0.1:\(port)" || host == "localhost:\(port)" || host == "127.0.0.1" || host == "localhost" else {
            return .json(403, ["error": "Forbidden host"])
        }
        let origin = req.headers["origin"]?.lowercased()
        let originScheme = origin.flatMap { URLComponents(string: $0)?.scheme }
        let originHost = origin.flatMap { URLComponents(string: $0)?.host }
        let extensionOrigin = ["chrome-extension", "safari-web-extension", "moz-extension"].contains(originScheme ?? "")
        if let originScheme, originScheme == "http" || originScheme == "https", originHost != "127.0.0.1", originHost != "localhost" {
            return .json(403, ["error": "Web pages can't use ezpdf's local server."])
        }
        if origin == "null" { return .json(403, ["error": "Forbidden origin"]) }

        let bearer: String? = req.headers["authorization"].flatMap { v in
            let parts = v.split(separator: " ", maxSplits: 1)
            return parts.count == 2 && parts[0].lowercased() == "bearer" ? String(parts[1]) : nil
        }
        let presented = req.headers["x-ezpdf-token"] ?? bearer
        let mcpAuthorized = presented.map { constantTimeEqual($0, Self.token) } ?? false
        let extAuthorized = req.headers["x-ezpdf-ext-token"].flatMap { t in Self.extensionToken.map { constantTimeEqual(t, $0) } } ?? false
        let context = CallContext(
            isRemote: req.headers["x-forwarded-for"] != nil || req.headers["cf-connecting-ip"] != nil || req.headers["x-toprelay-client"] != nil,
            client: req.headers["x-toprelay-client"] ?? req.headers["user-agent"].map { String($0.prefix(60)) })
        lastClient = context.client

        var response: HTTPResponse
        if req.method == "OPTIONS" {
            response = HTTPResponse(status: 204, headers: [:], body: Data())
        } else if req.path == "/mcp" || req.path == "/mcp/" {
            guard mcpAuthorized else {
                return .json(401, ["error": "Missing or wrong token. Copy it from ezpdf Settings → Agents."], extra: ["WWW-Authenticate": "Bearer"])
            }
            switch req.method {
            case "POST": response = await mcp.handle(req, context: context)
            case "DELETE": response = HTTPResponse(status: 200, headers: [:], body: Data())
            default: response = HTTPResponse(status: 405, headers: ["Allow": "POST, DELETE"], body: Data())
            }
        } else if req.path.hasPrefix("/ext/") {
            // Health and pairing are open to extension origins; everything else needs the paired token.
            let open = req.path == "/ext/health" || req.path == "/ext/pair"
            guard extensionOrigin || mcpAuthorized else { return .json(403, ["error": "Only the ezpdf browser extension can use this."]) }
            guard open || extAuthorized || mcpAuthorized else {
                return .json(401, ["error": "Pair the extension with ezpdf first.", "pair": true])
            }
            response = await ExtensionAPI.handle(req, origin: origin ?? "", authorized: extAuthorized || mcpAuthorized)
        } else if req.path == "/" || req.path == "/health" {
            response = .json(200, ["app": "ezpdf", "ok": true])
        } else {
            response = .json(404, ["error": "Not found"])
        }
        if extensionOrigin, let origin {
            response.headers["Access-Control-Allow-Origin"] = origin
            response.headers["Access-Control-Allow-Headers"] = "Content-Type, X-EzPDF-Ext-Token"
            response.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
            response.headers["Vary"] = "Origin"
        }
        return response
    }

    nonisolated func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    /// Proof the extension can check before it sends private page content: only the real ezpdf
    /// knows the extension token, so a program squatting on the port can't produce this.
    static func proof(nonce: String) -> String? {
        guard let t = extensionToken else { return nil }
        let mac = HMAC<SHA256>.authenticationCode(for: Data(nonce.utf8), using: SymmetricKey(data: Data(t.utf8)))
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Connection limits

/// Counts open connections. Used only from the server queue.
final class ConnectionLimiter: @unchecked Sendable {
    private let max: Int
    private var open = 0
    private let lock = NSLock()
    init(max: Int) { self.max = max }
    func acquire() -> Bool { lock.lock(); defer { lock.unlock() }; guard open < max else { return false }; open += 1; return true }
    func release() { lock.lock(); open = Swift.max(0, open - 1); lock.unlock() }
}

// MARK: - Minimal, strict HTTP

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    func json() -> Any? { body.isEmpty ? nil : try? JSONSerialization.jsonObject(with: body) }
}

struct HTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: Data

    static func json(_ status: Int, _ object: Any, extra: [String: String] = [:]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        var h = ["Content-Type": "application/json"]
        h.merge(extra) { $1 }
        return HTTPResponse(status: status, headers: h, body: data)
    }

    func serialize() -> Data {
        let reason = [200: "OK", 202: "Accepted", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                      404: "Not Found", 405: "Method Not Allowed", 408: "Request Timeout", 411: "Length Required",
                      413: "Payload Too Large", 429: "Too Many Requests", 431: "Request Header Fields Too Large",
                      500: "Internal Server Error", 503: "Service Unavailable"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        var h = headers
        h["Content-Length"] = String(body.count)
        h["Connection"] = "close"
        h["Cache-Control"] = "no-store"
        for (k, v) in h { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

/// Reads one request from a connection with hard limits. Runs on the server queue.
final class RequestReader: @unchecked Sendable {
    enum Result { case request(HTTPRequest), reject(Int, String) }

    static let maxHeader = 16 * 1024
    static let maxBody = 25 * 1024 * 1024
    static let headerDeadline: TimeInterval = 10
    static let totalDeadline: TimeInterval = 60

    private let conn: NWConnection
    private let queue: DispatchQueue
    private let done: (Result) -> Void
    private var buffer = Data()
    private var headerEnd: Int?
    private var scanFrom = 0
    private var head: (method: String, target: String, headers: [String: String], length: Int)?
    private var finished = false
    private let started = Date()

    init(conn: NWConnection, queue: DispatchQueue, done: @escaping (Result) -> Void) {
        self.conn = conn
        self.queue = queue
        self.done = done
    }

    func start() {
        queue.asyncAfter(deadline: .now() + Self.headerDeadline) { [self] in
            if head == nil { finish(.reject(408, "Request timed out")) }
        }
        queue.asyncAfter(deadline: .now() + Self.totalDeadline) { [self] in finish(.reject(408, "Request timed out")) }
        receive()
    }

    /// Parses a complete buffer without a connection (tests).
    static func testParse(_ data: Data) -> Result? {
        let r = RequestReader(conn: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), queue: .main) { _ in }
        r.buffer = data
        return r.step()
    }

    private func finish(_ r: Result) {
        guard !finished else { return }
        finished = true
        buffer = Data()
        done(r)
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [self] data, _, isComplete, error in
            guard !finished else { return }
            if let data { buffer.append(data) }
            if let result = step() { finish(result); return }
            if error != nil || isComplete { finish(.reject(400, "Incomplete request")); return }
            receive()
        }
    }

    /// Returns a result once the request is complete or invalid; nil to keep reading.
    private func step() -> Result? {
        if head == nil {
            // Search only the new bytes (minus 3, in case the terminator straddles reads).
            let start = max(0, scanFrom - 3)
            let sep = buffer.range(of: Data("\r\n\r\n".utf8), in: start..<buffer.count)
            scanFrom = buffer.count
            guard let sep else {
                return buffer.count > Self.maxHeader ? .reject(431, "Headers too large") : nil
            }
            if sep.lowerBound > Self.maxHeader { return .reject(431, "Headers too large") }
            guard let text = String(data: buffer[..<sep.lowerBound], encoding: .utf8) else { return .reject(400, "Bad headers") }
            let lines = text.components(separatedBy: "\r\n")
            let parts = lines[0].split(separator: " ")
            guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .reject(400, "Bad request line") }
            var headers: [String: String] = [:]
            for l in lines.dropFirst() {
                guard let c = l.firstIndex(of: ":") else { return .reject(400, "Bad header") }
                let name = l[..<c].trimmingCharacters(in: .whitespaces).lowercased()
                let value = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !name.contains(" ") else { return .reject(400, "Bad header") }
                // Duplicate security-relevant headers are ambiguous: refuse rather than guess.
                if headers[name] != nil, ["host", "content-length", "origin", "authorization", "x-ezpdf-token", "x-ezpdf-ext-token"].contains(name) {
                    return .reject(400, "Duplicate \(name) header")
                }
                headers[name] = value
            }
            if headers["transfer-encoding"] != nil { return .reject(411, "Send a Content-Length; chunked bodies aren't supported") }
            var length = 0
            if let cl = headers["content-length"] {
                guard let n = Int(cl), n >= 0, cl.allSatisfy(\.isNumber) else { return .reject(400, "Bad Content-Length") }
                guard n <= Self.maxBody else { return .reject(413, "Request too large") }
                length = n
            }
            head = (String(parts[0]).uppercased(), String(parts[1]), headers, length)
            headerEnd = sep.upperBound
        }
        guard let head, let headerEnd else { return nil }
        guard buffer.count - headerEnd >= head.length else { return nil }
        let body = buffer.subdata(in: headerEnd..<(headerEnd + head.length))
        let comps = URLComponents(string: "http://x" + (head.target.hasPrefix("/") ? head.target : "/" + head.target))
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return .request(HTTPRequest(method: head.method, path: comps?.path ?? head.target, query: query, headers: head.headers, body: body))
    }
}
