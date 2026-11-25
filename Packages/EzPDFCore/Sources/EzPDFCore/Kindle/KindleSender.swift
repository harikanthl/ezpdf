import Foundation
import AppKit

/// Sends a document to a Kindle through Amazon's Send to Kindle email address.
/// Amazon has no public upload API; email from an approved sender is the supported route.
public enum KindleSender {
    public enum Method: String, Codable, Sendable, CaseIterable {
        case mailAutomatic   // Mail sends it in the background (asks once for Automation access)
        case mailCompose     // opens a Mail draft for you to send
    }

    public struct Settings: Codable, Sendable {
        public var address: String
        public var method: Method
        public var preferEPUB: Bool
        /// The Mail account address to send from; it must be on Amazon's approved sender list.
        /// Empty until chosen: Mail would otherwise use its default account, which may not be approved.
        public var sender: String
        /// Kindle addresses sent to successfully, most recent first.
        public var recent: [String]
        public init(address: String = "", method: Method = .mailAutomatic, preferEPUB: Bool = true, sender: String = "", recent: [String] = []) {
            self.address = address; self.method = method; self.preferEPUB = preferEPUB; self.sender = sender; self.recent = recent
        }

        /// Puts `address` first in `recent`, without repeats, keeping the last few.
        public mutating func remember(_ address: String) {
            let a = address.trimmingCharacters(in: .whitespaces)
            guard !a.isEmpty else { return }
            recent.removeAll { $0.caseInsensitiveCompare(a) == .orderedSame }
            recent.insert(a, at: 0)
            recent = Array(recent.prefix(Self.recentLimit))
        }
        static let recentLimit = 6
        // Settings saved before a field existed still load, keeping what they had.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Settings()
            address = try c.decodeIfPresent(String.self, forKey: .address) ?? d.address
            method = (try? c.decodeIfPresent(Method.self, forKey: .method)) ?? d.method
            preferEPUB = try c.decodeIfPresent(Bool.self, forKey: .preferEPUB) ?? d.preferEPUB
            sender = try c.decodeIfPresent(String.self, forKey: .sender) ?? d.sender
            recent = try c.decodeIfPresent([String].self, forKey: .recent) ?? d.recent
        }

        static let key = "ezpdf.kindle"
        public static func load() -> Settings {
            guard let d = UserDefaults.standard.data(forKey: key), let s = try? JSONDecoder().decode(Settings.self, from: d) else { return Settings() }
            return s
        }
        public func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key) }
    }

    public static func isValidKindleAddress(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9._%+-]+@(kindle\.com|free\.kindle\.com|kindle\.cn)$"#, options: .regularExpression) != nil
    }

    /// Copies `file` to a temp file named after the title (Kindle shows the file name) and sends it.
    /// Mail automation runs in a separate `osascript` process, so the app never blocks on it.
    @MainActor
    public static func send(file: URL, title: String, settings: Settings) async throws {
        let address = settings.address.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else {
            throw EzPDFError.invalidInput("Add your Send to Kindle address in ezpdf Settings → Kindle first.")
        }
        guard isValidKindleAddress(address) else {
            throw EzPDFError.invalidInput("“\(address)” isn't a Kindle address. It should end in @kindle.com.")
        }
        var safe = title.replacingOccurrences(of: "[/:\\\\?%*|\"<>\\p{Cc}]", with: " ", options: .regularExpression)
        safe = String(safe.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "."))).prefix(80))
        if safe.isEmpty { safe = "Document" }
        let sender = settings.sender.trimmingCharacters(in: .whitespaces)
        if settings.method == .mailAutomatic, sender.isEmpty {
            throw EzPDFError.invalidInput("Choose which email account to send from in ezpdf Settings → Kindle. Amazon only accepts documents from addresses on your approved list.")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ezpdf-kindle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let named = dir.appendingPathComponent("\(safe).\(file.pathExtension)")
        try FileManager.default.copyItem(at: file, to: named)

        switch settings.method {
        case .mailCompose:
            guard let service = NSSharingService(named: .composeEmail) else { throw EzPDFError.unavailable("Mail isn't available.") }
            // When Mail starts from closed, it drops the recipients and subject of a share that
            // arrives while it is still launching. Start it first and wait until it is up.
            try await launchMailAndWait()
            service.recipients = [address]
            service.subject = safe
            service.perform(withItems: [named])
            // Mail reads the attachment when the draft opens; tidy up later.
            Task.detached { try? await Task.sleep(for: .seconds(600)); try? FileManager.default.removeItem(at: dir) }
        case .mailAutomatic:
            defer { try? FileManager.default.removeItem(at: dir) }
            // Give Mail time to load the attachment before sending: about a second, plus one per 5 MB.
            let bytes = (try? named.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let settle = min(8, 1 + bytes / 5_000_000)
            let result = try await runOSAScript(mailScript, args: [safe, address, named.path, String(settle), sender], timeout: 180)
            if result.status != 0 {
                let err = result.stderr
                if err.contains("-1743") || err.localizedCaseInsensitiveContains("not authorized") {
                    throw EzPDFError.unavailable("ezpdf isn't allowed to control Mail. Allow it in System Settings → Privacy & Security → Automation, or switch Kindle sending to “Mail, as a draft I send”.")
                }
                if let msg = scriptMessage(err) { throw EzPDFError.failed(msg) }
                if err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw EzPDFError.failed("Mail took too long to send it. Open Mail, check it's signed in, and try again.")
                }
                throw EzPDFError.failed("Mail couldn't send it: \(err.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
    }

    /// Our own script errors use numbers 9001–9009; pulls their message out of osascript's stderr
    /// ("…: execution error: <message> (9002)").
    static func scriptMessage(_ stderr: String) -> String? {
        guard let r = stderr.range(of: #"execution error: (.*) \(90\d{2}\)"#, options: .regularExpression) else { return nil }
        let line = String(stderr[r])
        return line.replacingOccurrences(of: #"^execution error: "#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #" \(90\d{2}\)$"#, with: "", options: .regularExpression)
    }

    /// Starts Mail in the background if needed and waits until it has finished launching.
    @MainActor
    static func launchMailAndWait() async throws {
        let bundleID = "com.apple.mail"
        func running() -> NSRunningApplication? { NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first }
        if let app = running(), app.isFinishedLaunching { return }
        if running() == nil {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                throw EzPDFError.unavailable("Mail isn't available.")
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        }
        for _ in 0..<60 {   // up to 15 s
            if let app = running(), app.isFinishedLaunching { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        // Finished launching isn't quite ready for a compose request; give it a moment more.
        try await Task.sleep(for: .seconds(1.5))
    }

    /// The email addresses of Mail's enabled accounts, for choosing which one sends to Kindle.
    /// Asks for Automation access to Mail the first time. Empty if Mail has none or access is refused.
    public static func mailAccounts() async -> [String] {
        let script = """
        tell application "Mail"
            set out to ""
            repeat with acc in (get every account whose enabled is true)
                set addrs to (get email addresses of acc)
                repeat with i from 1 to count of addrs
                    set out to out & (item i of addrs as text) & linefeed
                end repeat
            end repeat
            return out
        end tell
        """
        guard let r = try? await runOSAScript(script, args: [], timeout: 30), r.status == 0 else { return [] }
        var seen = Set<String>()
        return r.stdout.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Values go in as argv, never into the script text, so nothing in them can change the script.
    /// The script waits for Mail to be ready when it had to start it, checks that the recipient and
    /// attachment stuck, checks that `send` worked, and never leaves a half-made message behind.
    static let mailScript = """
    on run argv
        set theSubject to item 1 of argv
        set theAddress to item 2 of argv
        set thePath to item 3 of argv
        set settleSeconds to (item 4 of argv) as integer
        set fromAddress to item 5 of argv
        set wasRunning to application "Mail" is running
        if not wasRunning then tell application "Mail" to launch
        -- A Mail that is still starting takes the message but drops its recipient. Wait for its accounts.
        set ready to false
        repeat 80 times
            try
                tell application "Mail"
                    if (count of accounts) > 0 then set ready to true
                end tell
            end try
            if ready then exit repeat
            delay 0.25
        end repeat
        if not ready then error "Mail has no email account set up. Add one in Mail, then try again." number 9001
        if not wasRunning then delay 3
        -- Send from the chosen account, as Mail writes it ("Name <address>"), never Mail's default.
        set theSender to missing value
        tell application "Mail"
            repeat with acc in (get every account whose enabled is true)
                if (get email addresses of acc) contains fromAddress then
                    set theSender to (get full name of acc) & " <" & fromAddress & ">"
                    exit repeat
                end if
            end repeat
        end tell
        if theSender is missing value then error "Mail has no account for " & fromAddress & ". Choose another in ezpdf Settings → Kindle." number 9005
        with timeout of 120 seconds
            tell application "Mail"
                set m to make new outgoing message with properties {subject:theSubject, content:"Sent with ezpdf", sender:theSender, visible:false}
                try
                    repeat 3 times
                        if (count of to recipients of m) > 0 then exit repeat
                        tell m to make new to recipient at end of to recipients with properties {address:theAddress}
                        delay 0.5
                    end repeat
                    if (count of to recipients of m) = 0 then error "Mail wouldn't take the Kindle address. Try again in a moment." number 9002
                    if (sender of m) does not contain fromAddress then error "Mail wouldn't send from " & fromAddress & ". Try again in a moment." number 9006
                    tell m to make new attachment with properties {file name:(POSIX file thePath)} at after the last paragraph
                    delay settleSeconds
                    set ok to send m
                    if ok is false then error "Mail didn't send it. Check Mail is signed in to your email account." number 9004
                on error errMsg number errNum
                    try
                        close m saving no
                    end try
                    error errMsg number errNum
                end try
            end tell
        end timeout
    end run
    """

    /// Runs AppleScript in `osascript` without blocking: output goes to temp files, completion
    /// arrives through the termination handler, and a timeout kills it.
    static func runOSAScript(_ source: String, args: [String], timeout: TimeInterval) async throws -> (status: Int32, stdout: String, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-"] + args
        let input = Pipe()
        let tmp = FileManager.default.temporaryDirectory
        let outFile = tmp.appendingPathComponent("ezpdf-osa-\(UUID().uuidString)")
        let errFile = tmp.appendingPathComponent("ezpdf-osa-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outFile.path, contents: nil)
        FileManager.default.createFile(atPath: errFile.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: outFile); try? FileManager.default.removeItem(at: errFile) }
        let outHandle = try FileHandle(forWritingTo: outFile)
        let errHandle = try FileHandle(forWritingTo: errFile)
        p.standardInput = input
        p.standardOutput = outHandle
        p.standardError = errHandle
        let status: Int32 = try await withCheckedThrowingContinuation { c in
            p.terminationHandler = { proc in c.resume(returning: proc.terminationStatus) }
            do { try p.run() } catch { p.terminationHandler = nil; c.resume(throwing: error); return }
            input.fileHandleForWriting.write(Data(source.utf8))
            try? input.fileHandleForWriting.close()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        }
        try? outHandle.close()
        try? errHandle.close()
        let out = (try? String(contentsOf: outFile, encoding: .utf8)) ?? ""
        let err = (try? String(contentsOf: errFile, encoding: .utf8)) ?? ""
        return (status, out, err)
    }
}
