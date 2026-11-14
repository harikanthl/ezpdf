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
        var errorDescription: String? { fix.map { "\(message). \($0)" } ?? message }
    }

    @discardableResult
    static func run(_ args: [String], timeout: TimeInterval = 120) async throws -> [String: Any] {
        guard let bin = binary else {
            throw Failure(message: "TopRelay isn't installed", fix: "build it with `cd toprelay/agent && go build -o toprelay ./cmd/toprelay` and put it on your PATH")
        }
        // Output goes to temp files, not pipes: a chatty stderr or a child process that keeps a
        // pipe open (up --install) can't hang ezpdf. Completion comes from the termination handler.
        let tmp = FileManager.default.temporaryDirectory
        let outURL = tmp.appendingPathComponent("ezpdf-toprelay-\(UUID().uuidString).out")
        let errURL = tmp.appendingPathComponent("ezpdf-toprelay-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: errURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: outURL); try? FileManager.default.removeItem(at: errURL) }
        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)
        let p = Process()
        p.executableURL = bin
        p.arguments = args + ["--json"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = outHandle
        p.standardError = errHandle
        let status: Int32 = try await withCheckedThrowingContinuation { c in
            p.terminationHandler = { proc in c.resume(returning: proc.terminationStatus) }
            do { try p.run() } catch { p.terminationHandler = nil; c.resume(throwing: error); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        }
        try? outHandle.close(); try? errHandle.close()
        let data = (try? Data(contentsOf: outURL)) ?? Data()
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let e = obj["error"] as? [String: Any] {
            throw Failure(message: e["message"] as? String ?? "toprelay failed", fix: e["fix"] as? String)
        }
        if status != 0 && obj.isEmpty {
            let msg = (try? String(contentsOf: errURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw Failure(message: msg.isEmpty ? "toprelay exited with \(status)" : String(msg.prefix(400)), fix: nil)
        }
        return obj
    }

    /// What `connect` did, so Settings can say whether paired bots keep working.
    enum Outcome {
        /// Added for the first time.
        case added
        /// Already there: the token header now points at the token file. Keys, OAuth grants and tool choices are kept.
        case kept
        /// The local address changed (a different port), which TopRelay can only change by removing the service:
        /// paired bots and keys must be set up again.
        case readded
    }

    /// Registers ezpdf, or brings an existing registration up to date without disconnecting anyone.
    ///
    /// The token travels as `--header-file`: TopRelay reads the 0600 token file on every request, so the token
    /// never appears in a process list and a new token takes effect without touching TopRelay. An existing
    /// service is updated with `set-header` rather than removed, because `remove` revokes every key and OAuth
    /// grant. Read-only tools are exposed by default; the rest can be allowed in Settings.
    static func connect(localURL: String, tokenFile: URL) async throws -> (url: String?, outcome: Outcome) {
        let header = "X-EzPDF-Token=\(tokenFile.path)"
        // Before `toprelay login` there is no configuration and `list` fails; `add` then reports what to do.
        // A failed list can't cause damage: `add` refuses a name that already exists.
        let list = (try? await run(["list"])) ?? [:]
        let existing = (list["services"] as? [[String: Any]])?.first { $0["name"] as? String == service }
        if let existing, existing["local"] as? String == localURL {
            try await run(["set-header", service, "--file", header])
            return (existing["url"] as? String, .kept)
        }
        if existing != nil { try await run(["remove", service]) }
        let r = try await run(["add", service, "--mcp-url", localURL, "--header-file", header,
                               "--tools-default", "allow-readonly"])
        return (r["url"] as? String, existing == nil ? .added : .readded)
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
