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
        public init(address: String = "", method: Method = .mailAutomatic, preferEPUB: Bool = true) {
            self.address = address; self.method = method; self.preferEPUB = preferEPUB
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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ezpdf-kindle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let named = dir.appendingPathComponent("\(safe).\(file.pathExtension)")
        try FileManager.default.copyItem(at: file, to: named)

        switch settings.method {
        case .mailCompose:
            guard let service = NSSharingService(named: .composeEmail) else { throw EzPDFError.unavailable("Mail isn't available.") }
            service.recipients = [address]
            service.subject = safe
            service.perform(withItems: [named])
            // Mail reads the attachment when the draft opens; tidy up later.
            Task.detached { try? await Task.sleep(for: .seconds(600)); try? FileManager.default.removeItem(at: dir) }
        case .mailAutomatic:
            defer { try? FileManager.default.removeItem(at: dir) }
            // Values go in as argv, never into the script text, so nothing in them can change the script.
            let script = """
            on run argv
                set theSubject to item 1 of argv
                set theAddress to item 2 of argv
                set thePath to item 3 of argv
                tell application "Mail"
                    set m to make new outgoing message with properties {subject:theSubject, content:"Sent with ezpdf", visible:false}
                    tell m
                        make new to recipient at end of to recipients with properties {address:theAddress}
                        make new attachment with properties {file name:(POSIX file thePath)} at after the last paragraph
                    end tell
                    delay 1
                    send m
                end tell
            end run
            """
            let result = try await runOSAScript(script, args: [safe, address, named.path], timeout: 90)
            if result.status != 0 {
                if result.stderr.contains("-1743") || result.stderr.localizedCaseInsensitiveContains("not authorized") {
                    throw EzPDFError.unavailable("ezpdf isn't allowed to control Mail. Allow it in System Settings → Privacy & Security → Automation, or switch Kindle sending to “Mail, as a draft I send”.")
                }
                throw EzPDFError.failed("Mail couldn't send it: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
    }

    /// Runs AppleScript in `osascript` without blocking: output goes to temp files, completion
    /// arrives through the termination handler, and a timeout kills it.
    static func runOSAScript(_ source: String, args: [String], timeout: TimeInterval) async throws -> (status: Int32, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-"] + args
        let input = Pipe()
        let errFile = FileManager.default.temporaryDirectory.appendingPathComponent("ezpdf-osa-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: errFile.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errFile) }
        let errHandle = try FileHandle(forWritingTo: errFile)
        p.standardInput = input
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errHandle
        let status: Int32 = try await withCheckedThrowingContinuation { c in
            p.terminationHandler = { proc in c.resume(returning: proc.terminationStatus) }
            do { try p.run() } catch { p.terminationHandler = nil; c.resume(throwing: error); return }
            input.fileHandleForWriting.write(Data(source.utf8))
            try? input.fileHandleForWriting.close()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        }
        try? errHandle.close()
        let err = (try? String(contentsOf: errFile, encoding: .utf8)) ?? ""
        return (status, err)
    }
}
