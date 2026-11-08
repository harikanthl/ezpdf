import Foundation

/// Drives the `toprelay` CLI (github: TopRelay) to give ezpdf's local MCP server a private
/// HTTPS address that Grok, ChatGPT, claude.ai and API agents can reach. Every call uses
/// `--json`, which prints exactly one JSON object and never prompts.
enum TopRelay {
    static let service = "ezpdf"

    static var binary: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/opt/homebrew/bin/toprelay", "/usr/local/bin/toprelay", "\(home)/go/bin/toprelay",
                          "\(home)/.local/bin/toprelay", "\(home)/Projects/toprelay/agent/toprelay"]
        return candidates.map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    struct Failure: LocalizedError {
        let message: String
        let fix: String?
        var errorDescription: String? { fix.map { "\(message) — \($0)" } ?? message }
    }

    @discardableResult
    static func run(_ args: [String]) async throws -> [String: Any] {
        guard let bin = binary else {
            throw Failure(message: "TopRelay isn't installed", fix: "build it with `cd toprelay/agent && go build -o toprelay ./cmd/toprelay` and put it on your PATH")
        }
        return try await Task.detached {
            let p = Process()
            p.executableURL = bin
            p.arguments = args + ["--json"]
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if let e = obj["error"] as? [String: Any] {
                throw Failure(message: e["message"] as? String ?? "toprelay failed", fix: e["fix"] as? String)
            }
            if p.terminationStatus != 0 && obj.isEmpty {
                let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw Failure(message: msg.isEmpty ? "toprelay exited with \(p.terminationStatus)" : msg, fix: nil)
            }
            return obj
        }.value
    }

    /// Registers ezpdf (or refreshes its token header). Read-only tools are exposed by default;
    /// the rest can be allowed in Settings.
    static func connect(localURL: String, token: String) async throws -> String? {
        let list = try? await run(["list"])
        let exists = (list?["services"] as? [[String: Any]])?.contains { $0["name"] as? String == service } ?? false
        if exists { _ = try? await run(["remove", service]) }
        let r = try await run(["add", service, "--mcp-url", localURL, "--header", "X-EzPDF-Token: \(token)",
                               "--tools-default", "allow-readonly"])
        return r["url"] as? String
    }

    static func status() async -> (url: String?, connected: Bool, error: String?) {
        guard let r = try? await run(["status"]) else { return (nil, false, nil) }
        let svc = (r["services"] as? [[String: Any]])?.first { $0["name"] as? String == service }
        return (svc?["url"] as? String, svc?["connected"] as? Bool ?? false, svc?["error"] as? String)
    }

    static func allowAllTools() async throws { try await run(["tools", service, "--allow-all"]) }
    static func startAtLogin() async throws { try await run(["up", "--install"]) }

    static func pairingCode() async throws -> String {
        let r = try await run(["pair", service])
        return r["code"] as? String ?? ""
    }

    /// A bearer key plus ready-made snippets per client (xai, openai, claude-api …).
    static func key(client: String) async throws -> (key: String, snippet: String) {
        let r = try await run(["key", service, "--client", client])
        let snippets = r["snippets"] as? [String: String] ?? [:]
        return (r["key"] as? String ?? "", snippets[client] ?? snippets.values.first ?? "")
    }
}
