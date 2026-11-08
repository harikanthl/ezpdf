import AppKit
import EzPDFCore

/// Asks you before an outside agent (Claude, Grok via TopRelay, any MCP client) changes or sends a
/// document. One request at a time; no answer in 2 minutes counts as no.
@MainActor
enum AgentApprovalPrompt {
    private static var showing = false

    static func install() {
        AgentApproval.handler = { await ask($0) }
    }

    static func ask(_ r: AgentApproval.Request) async -> Bool {
        while showing { try? await Task.sleep(for: .milliseconds(200)) }
        showing = true
        defer { showing = false }
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = r.remote ? .warning : .informational
        alert.messageText = "\(r.client) wants to use “\(r.tool)”"
        var info = r.remote ? "This request came through a relay, from outside this Mac.\n\n" : ""
        if !r.detail.isEmpty { info += r.detail + "\n\n" }
        info += "Undo reverts a change. No answer in 2 minutes counts as Don't Allow."
        alert.informativeText = info
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        if !r.remote {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Let agents on this Mac make changes without asking"
        }
        let timeout = Timer(timeInterval: 120, repeats: false) { _ in MainActor.assumeIsolated { NSApp.abortModal() } }
        RunLoop.main.add(timeout, forMode: .modalPanel)
        let response = alert.runModal()
        timeout.invalidate()
        let allowed = response == .alertFirstButtonReturn
        if allowed, alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(AgentApproval.Policy.allow.rawValue, forKey: AgentApproval.policyKey)
        }
        return allowed
    }
}
