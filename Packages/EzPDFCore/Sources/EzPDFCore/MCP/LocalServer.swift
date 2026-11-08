import Foundation
import Network
import Observation

/// One small HTTP/1.1 server on 127.0.0.1 that serves:
///   POST /mcp          MCP (Streamable HTTP, stateless JSON responses) for agents, Claude, TopRelay → Grok/ChatGPT
///   /ext/*             a tiny REST API for the ezpdf browser extension
/// Security: loopback only; Host must be localhost (blocks DNS rebinding); web-page Origins are
/// refused (a site can't drive ezpdf); /mcp needs the token; /ext needs an extension Origin or the token.
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
    @ObservationIgnored lazy var mcp = MCPHandler(ops: EzPDF.shared)

    public var mcpURL: String { "http://127.0.0.1:\(port)/mcp" }

    // MARK: Token

    public static var tokenFile: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("ezpdf/mcp-token")
    }

    /// Random token, created on first use and kept in a 0600 file so local tools can read it.
    public static var token: String {
        if let t = try? String(contentsOf: tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), t.count >= 32 { return t }
        return rotateToken()
    }

    @discardableResult
    public static func rotateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let t = "ezp_" + bytes.map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.createDirectory(at: tokenFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? t.write(to: tokenFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
        return t
    }

    // MARK: Lifecycle

    public func start(port: UInt16 = LocalServer.defaultPort) {
        stop()
        self.port = port
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
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

    // MARK: Connections

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        HTTPReader.read(conn) { [weak self] request in
            Task { @MainActor in
                guard let self else { conn.cancel(); return }
                let response: HTTPResponse
                if let request { response = await self.route(request) }
                else { response = .json(400, ["error": "Bad request"]) }
                conn.send(content: response.serialize(), completion: .contentProcessed { _ in conn.cancel() })
            }
        }
    }

    private func route(_ req: HTTPRequest) async -> HTTPResponse {
        requestCount += 1
        // DNS rebinding: a page on evil.com resolving to 127.0.0.1 still sends Host: evil.com.
        let host = (req.headers["host"] ?? "").lowercased()
        guard host == "127.0.0.1:\(port)" || host == "localhost:\(port)" || host == "127.0.0.1" || host == "localhost" else {
            return .json(403, ["error": "Forbidden host"])
        }
        let origin = req.headers["origin"]?.lowercased()
        let webOrigin = origin.map { ($0.hasPrefix("http://") || $0.hasPrefix("https://")) && !$0.hasPrefix("http://127.0.0.1") && !$0.hasPrefix("http://localhost") } ?? false
        let extensionOrigin = origin.map { $0.hasPrefix("chrome-extension://") || $0.hasPrefix("safari-web-extension://") || $0.hasPrefix("moz-extension://") } ?? false
        if webOrigin { return .json(403, ["error": "Web pages can't use ezpdf's local server."]) }

        let presented = req.headers["x-ezpdf-token"] ?? req.headers["authorization"].flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }
        let authorized = presented.map { constantTimeEqual($0, Self.token) } ?? false
        lastClient = req.headers["x-toprelay-client"] ?? req.headers["user-agent"].map { String($0.prefix(60)) }

        var response: HTTPResponse
        if req.method == "OPTIONS" {
            response = HTTPResponse(status: 204, headers: [:], body: Data())
        } else if req.path == "/mcp" || req.path == "/mcp/" {
            guard authorized else {
                return .json(401, ["error": "Missing or wrong token. Copy it from ezpdf Settings → Agents."], extra: ["WWW-Authenticate": "Bearer"])
            }
            switch req.method {
            case "POST": response = await mcp.handle(req)
            case "DELETE": response = HTTPResponse(status: 200, headers: [:], body: Data())
            default: response = HTTPResponse(status: 405, headers: ["Allow": "POST, DELETE"], body: Data())
            }
        } else if req.path.hasPrefix("/ext/") {
            guard extensionOrigin || authorized else { return .json(403, ["error": "Only the ezpdf browser extension can use this."]) }
            response = await ExtensionAPI.handle(req)
        } else if req.path == "/" || req.path == "/health" {
            response = .json(200, ["app": "ezpdf", "ok": true])
        } else {
            response = .json(404, ["error": "Not found"])
        }
        if extensionOrigin, let origin {
            response.headers["Access-Control-Allow-Origin"] = origin
            response.headers["Access-Control-Allow-Headers"] = "Content-Type, X-EzPDF-Token"
            response.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
            response.headers["Vary"] = "Origin"
        }
        return response
    }

    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}

// MARK: - Minimal HTTP

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
                      404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large", 500: "Internal Server Error"][status] ?? "OK"
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

enum HTTPReader {
    static let maxBody = 40 * 1024 * 1024

    static func read(_ conn: NWConnection, buffer: Data = Data(), completion: @escaping @Sendable (HTTPRequest?) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
            var buf = buffer
            if let data { buf.append(data) }
            if let req = parse(buf) { completion(req); return }
            if buf.count > maxBody + 64 * 1024 || error != nil || isComplete { completion(nil); return }
            read(conn, buffer: buf, completion: completion)
        }
    }

    /// Returns a request once headers and the full Content-Length body have arrived.
    static func parse(_ buf: Data) -> HTTPRequest? {
        guard let sep = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: buf[..<sep.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            guard let c = l.firstIndex(of: ":") else { continue }
            headers[l[..<c].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        let length = min(Int(headers["content-length"] ?? "0") ?? 0, maxBody)
        let bodyStart = sep.upperBound
        guard buf.count - bodyStart >= length else { return nil }
        let target = String(parts[1])
        let comps = URLComponents(string: "http://x" + target)
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return HTTPRequest(method: String(parts[0]).uppercased(), path: comps?.path ?? target, query: query,
                           headers: headers, body: buf.subdata(in: bodyStart..<(bodyStart + length)))
    }
}
