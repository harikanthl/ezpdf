import Foundation
import AppKit

/// Sends a document to a Kindle through Amazon's Send-to-Kindle email address.
/// Amazon has no public upload API; email from an approved sender is the supported route.
public enum KindleSender {
    public enum Method: String, Codable, Sendable, CaseIterable {
        case mailAutomatic   // Mail.app sends it in the background (asks once for Automation access)
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
    @MainActor
    public static func send(file: URL, title: String, settings: Settings) throws {
        guard !settings.address.isEmpty else {
            throw EzPDFError.invalidInput("Add your Send-to-Kindle address in ezpdf Settings → Kindle first.")
        }
        let safe = title.replacingOccurrences(of: "[/:\\\\?%*|\"<>]", with: "-", options: .regularExpression).prefix(80)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ezpdf-kindle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let named = dir.appendingPathComponent("\(safe).\(file.pathExtension)")
        try FileManager.default.copyItem(at: file, to: named)

        switch settings.method {
        case .mailCompose:
            guard let service = NSSharingService(named: .composeEmail) else { throw EzPDFError.unavailable("Mail isn't available.") }
            service.recipients = [settings.address]
            service.subject = String(safe)
            service.perform(withItems: [named])
        case .mailAutomatic:
            let script = """
            tell application "Mail"
                set m to make new outgoing message with properties {subject:"\(escape(String(safe)))", content:"Sent with ezpdf", visible:false}
                tell m
                    make new to recipient at end of to recipients with properties {address:"\(escape(settings.address))"}
                    make new attachment with properties {file name:(POSIX file "\(escape(named.path))")} at after the last paragraph
                end tell
                delay 2
                send m
            end tell
            """
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let error {
                let msg = error[NSAppleScript.errorMessage] as? String ?? "unknown error"
                let code = error[NSAppleScript.errorNumber] as? Int ?? 0
                if code == -1743 {
                    throw EzPDFError.unavailable("ezpdf isn't allowed to control Mail. Allow it in System Settings → Privacy & Security → Automation, or switch Kindle sending to “Open a Mail draft”.")
                }
                throw EzPDFError.failed("Mail couldn't send it: \(msg)")
            }
        }
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
