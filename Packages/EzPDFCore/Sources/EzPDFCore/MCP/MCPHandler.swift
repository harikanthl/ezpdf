import Foundation

/// JSON-RPC / MCP over Streamable HTTP, stateless: every POST gets a JSON reply (no SSE, no
/// session id), which every MCP client and TopRelay support.
@MainActor
final class MCPHandler {
    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    let tools: [MCPTool]

    init(ops: EzPDF) { tools = MCPTools.all(ops) }

    static let maxBatch = 20

    func handle(_ req: HTTPRequest, context: CallContext) async -> HTTPResponse {
        guard let json = req.json() else {
            return .json(400, rpcError(nil, -32700, "Parse error"))
        }
        if let batch = json as? [Any] {
            guard !batch.isEmpty, batch.count <= Self.maxBatch else {
                return .json(400, rpcError(nil, -32600, batch.isEmpty ? "Empty batch" : "At most \(Self.maxBatch) requests per batch"))
            }
            var out: [[String: Any]] = []
            for item in batch {
                guard let m = item as? [String: Any] else { out.append(rpcError(nil, -32600, "Invalid request")); continue }
                if let r = await message(m, context) { out.append(r) }
            }
            return out.isEmpty ? HTTPResponse(status: 202, headers: [:], body: Data()) : .json(200, out)
        }
        guard let m = json as? [String: Any] else { return .json(400, rpcError(nil, -32600, "Invalid request")) }
        guard let r = await message(m, context) else { return HTTPResponse(status: 202, headers: [:], body: Data()) }
        return .json(200, r)
    }

    /// Nil for notifications and responses (nothing to send back).
    private func message(_ m: [String: Any], _ context: CallContext) async -> [String: Any]? {
        let id = m["id"]
        guard let method = m["method"] as? String else { return nil }
        guard m["jsonrpc"] as? String == "2.0" else { return id == nil ? nil : rpcError(id, -32600, "jsonrpc must be \"2.0\"") }
        if id == nil || id is NSNull { return nil }      // notification
        let params = m["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? Self.supportedVersions[0]
            let version = Self.supportedVersions.contains(asked) ? asked : Self.supportedVersions[0]
            return ok(id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "ezpdf", "title": "ezpdf", "version": "0.1.0"],
                "instructions": Self.instructions,
            ])
        case "ping":
            return ok(id, [:])
        case "tools/list":
            return ok(id, ["tools": tools.map(\.descriptor)])
        case "tools/call":
            guard let name = params["name"] as? String, let tool = tools.first(where: { $0.name == name }) else {
                return rpcError(id, -32602, "Unknown tool \(params["name"] as? String ?? "")")
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let out = try await tool.run(args, context)
                return ok(id, out.json)
            } catch {
                return ok(id, ToolOutput.error(error.localizedDescription).json)
            }
        case "resources/list": return ok(id, ["resources": []])
        case "prompts/list": return ok(id, ["prompts": []])
        default:
            return rpcError(id, -32601, "Method not found: \(method)")
        }
    }

    private func ok(_ id: Any?, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }

    private func rpcError(_ id: Any?, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    static let instructions = """
    ezpdf is a Mac app that makes clean PDFs and EPUBs from links and files, reads and edits PDFs, \
    pulls transactions out of bank statements and fields out of invoices, and sends documents to a Kindle. \
    Documents live in the user's ezpdf library and are referred to by id (a title also works). \
    Typical flow: convert_url or convert_file → use the returned id with get_text, extract_data, edit_pages, \
    send_to_kindle or export_file. Files are saved on the user's Mac; get_pdf returns small PDFs inline.
    """
}

struct ToolOutput {
    var text: String
    var structured: Any?
    var extra: [[String: Any]] = []
    var isError = false

    static func error(_ s: String) -> ToolOutput { ToolOutput(text: s, structured: nil, isError: true) }

    var json: [String: Any] {
        var content: [[String: Any]] = [["type": "text", "text": text]]
        content.append(contentsOf: extra)
        var r: [String: Any] = ["content": content, "isError": isError]
        if let structured { r["structuredContent"] = structured }
        return r
    }
}

struct MCPTool {
    var name: String
    var title: String
    var description: String
    var schema: [String: Any]
    var readOnly: Bool
    var destructive = false
    var idempotent = false
    var openWorld = false
    var run: ([String: Any], CallContext) async throws -> ToolOutput

    var descriptor: [String: Any] {
        ["name": name, "title": title, "description": description, "inputSchema": schema,
         "annotations": ["title": title, "readOnlyHint": readOnly, "destructiveHint": destructive,
                         "idempotentHint": idempotent, "openWorldHint": openWorld]]
    }
}

/// JSON Schema helpers.
enum S {
    static func object(_ props: [String: [String: Any]], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": props, "required": required, "additionalProperties": false]
    }
    static func string(_ d: String, enum values: [String]? = nil) -> [String: Any] {
        var s: [String: Any] = ["type": "string", "description": d]
        if let values { s["enum"] = values }
        return s
    }
    static func int(_ d: String) -> [String: Any] { ["type": "integer", "description": d] }
    static func bool(_ d: String) -> [String: Any] { ["type": "boolean", "description": d] }
    static func strings(_ d: String) -> [String: Any] { ["type": "array", "items": ["type": "string"], "description": d] }
    static func ints(_ d: String) -> [String: Any] { ["type": "array", "items": ["type": "integer"], "description": d] }
}

extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? {
        if let s = self[k] as? String { let t = s.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t }
        if let n = self[k] as? NSNumber { return n.stringValue }
        return nil
    }
    /// Integers from callers are untrusted: clamp to a sane range so they can't overflow or
    /// make `prefix(-1)` trap.
    func int(_ k: String, in range: ClosedRange<Int> = 0...1_000_000) -> Int? {
        let raw: Int?
        if let n = self[k] as? NSNumber {
            let d = n.doubleValue
            raw = d.isFinite ? Int(Swift.max(-1e9, Swift.min(1e9, d))) : nil
        } else {
            raw = (self[k] as? String).flatMap { Int($0) }
        }
        return raw.map { Swift.min(Swift.max($0, range.lowerBound), range.upperBound) }
    }
    func bool(_ k: String) -> Bool? { (self[k] as? Bool) ?? (self[k] as? NSNumber)?.boolValue }
    func need(_ k: String) throws -> String {
        guard let v = str(k) else { throw EzPDFError.invalidInput("Missing “\(k)”.") }
        return v
    }
}
