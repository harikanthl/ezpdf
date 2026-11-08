import Foundation
import AppKit

/// REST endpoints for the ezpdf browser extension (Safari and Chrome share one codebase).
///   GET  /ext/health[?nonce=…]       → {app, version, kindle, preset, paired, proof?}
///   POST /ext/pair                   → asks the user once in the app, then {token}
///   POST /ext/run {url, flow, preset?, html?, title?} → {job}      (paired only)
///   GET  /ext/status?job=…           → {state, detail, title, document, path?}
///   POST /ext/open {id}              → shows the document in ezpdf
///   POST /ext/reveal {path}          → shows a file ezpdf saved in Finder
@MainActor
enum ExtensionAPI {
    enum Flow: String { case pdf, epub, kindle, extract, open }

    struct ExtJob {
        var state = "running"
        var detail = "Starting"
        var title = ""
        var documentID: String?
        var savedPath: String?
        var message: String?
        var started = Date()
    }
    static var jobs: [String: ExtJob] = [:]
    static let maxJobs = 40
    static var pairingInProgress = false

    static func handle(_ req: HTTPRequest, origin: String, authorized: Bool) async -> HTTPResponse {
        let body = req.json() as? [String: Any] ?? [:]
        switch (req.method, req.path) {
        case ("GET", "/ext/health"):
            let k = KindleSender.Settings.load()
            var o: [String: Any] = ["app": "ezpdf", "version": "0.1.0", "kindle": !k.address.isEmpty,
                                    "preset": EzPDF.shared.defaultPreset.rawValue, "paired": LocalServer.isExtensionPaired,
                                    "presets": PagePreset.allCases.map { ["id": $0.rawValue, "name": $0.displayName] }]
            if let nonce = req.query["nonce"], nonce.count >= 16, nonce.count <= 128, let proof = LocalServer.proof(nonce: nonce) {
                o["proof"] = proof
            }
            return .json(200, o)

        case ("POST", "/ext/pair"):
            return await pair(origin: origin)

        case ("POST", "/ext/run"):
            guard let raw = body.str("url"), let url = URL(string: raw), url.scheme == "http" || url.scheme == "https" else {
                return .json(400, ["error": "That tab has no web address ezpdf can open."])
            }
            let html = body["html"] as? String
            // ezpdf fetches the page itself unless the extension sent what the user is looking at.
            if html == nil, !URLGuard.isAllowed(url) {
                return .json(400, ["error": "ezpdf doesn't open addresses on your local network."])
            }
            guard jobs.values.filter({ $0.state == "running" }).count < 4 else {
                return .json(429, ["error": "ezpdf is busy with other pages. Try again in a moment."])
            }
            let flow = Flow(rawValue: body.str("flow") ?? "pdf") ?? .pdf
            let id = UUID().uuidString
            jobs[id] = ExtJob(title: body.str("title").map { String($0.prefix(200)) } ?? url.host() ?? "")
            prune()
            let preset = PagePreset.parse(body.str("preset"))
            let title = body.str("title").map { String($0.prefix(200)) }
            Task { await run(id, url: url, flow: flow, preset: preset, html: html, title: title) }
            return .json(200, ["job": id])

        case ("GET", "/ext/status"):
            guard let id = req.query["job"], let j = jobs[id] else { return .json(404, ["error": "Unknown job"]) }
            var o: [String: Any] = ["state": j.state, "detail": j.detail, "title": j.title]
            if let d = j.documentID { o["document"] = d }
            if let p = j.savedPath { o["path"] = p }
            if let m = j.message { o["message"] = m }
            return .json(200, o)

        case ("POST", "/ext/open"):
            guard let id = body.str("id"), let rec = try? EzPDF.shared.requestOpen(id) else { return .json(404, ["error": "Not found"]) }
            NSApp.activate()
            return .json(200, ["ok": true, "title": rec.title])

        case ("POST", "/ext/reveal"):
            // Only files ezpdf itself saved: inside the export folder or the library.
            guard let p = body.str("path") else { return .json(404, ["error": "Not found"]) }
            let url = URL(fileURLWithPath: p)
            guard FileAccess.isInside(url, EzPDF.shared.exportFolder) || FileAccess.isInside(url, Library.shared.root),
                  FileManager.default.fileExists(atPath: url.path) else { return .json(404, ["error": "Not found"]) }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return .json(200, ["ok": true])

        default:
            return .json(404, ["error": "Not found"])
        }
    }

    /// The user approves the extension once, in the app. Other programs (or another account's
    /// browser) can't pair silently.
    static func pair(origin: String) async -> HTTPResponse {
        guard !pairingInProgress else { return .json(429, ["error": "Already asking. Check the ezpdf window."]) }
        pairingInProgress = true
        defer { pairingInProgress = false }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Connect the ezpdf browser extension?"
        alert.informativeText = "A browser extension (\(origin)) wants to make PDFs, send pages to your Kindle and save files with ezpdf. Allow it only if you just clicked the ezpdf extension."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        guard alert.runModal() == .alertFirstButtonReturn else { return .json(403, ["error": "Not allowed in ezpdf."]) }
        return .json(200, ["token": LocalServer.makeExtensionToken()])
    }

    static func run(_ id: String, url: URL, flow: Flow, preset: PagePreset?, html: String?, title: String?) async {
        let ops = EzPDF.shared
        func update(_ change: (inout ExtJob) -> Void) { if var j = jobs[id] { change(&j); jobs[id] = j } }
        // Mirror only this request's own job progress.
        var watched: Job?
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                if let w = watched, w.state == .running { update { $0.detail = w.detail } }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        defer { watcher.cancel() }
        do {
            let format: OutputFormat = flow == .epub || flow == .kindle ? .both : (flow == .extract ? .pdf : ops.defaultFormat)
            let rec: DocumentRecord
            if let html, !html.isEmpty {
                rec = try await ops.convert(html: html, url: url, preset: preset, format: format, title: title, source: .browser, observe: { watched = $0 })
            } else {
                rec = try await ops.convert(url: url, preset: preset, format: format, title: title, source: .browser, observe: { watched = $0 })
            }
            update { $0.documentID = rec.id; $0.title = rec.title }
            switch flow {
            case .pdf, .open:
                if flow == .open { _ = try? ops.requestOpen(rec.id); NSApp.activate() }
                update { $0.message = "Saved to your ezpdf library" }
            case .epub:
                let path = try ops.export(rec.id, format: rec.hasEPUB ? .epub : .pdf)
                update { $0.savedPath = path.path; $0.message = rec.hasEPUB ? "EPUB saved to Downloads" : "No article text, so saved a PDF" }
            case .kindle:
                update { $0.detail = "Sending to Kindle" }
                let r = try await ops.sendToKindle(rec.id)
                update { $0.message = "Sent to \(r.address)" }
            case .extract:
                update { $0.detail = "Reading the data" }
                let result = try await ops.extract(rec.id, source: .browser)
                let path = try ops.saveExtraction(result, for: rec.id, format: .xlsx)
                let count = result.statement?.transactions.count ?? result.invoice?.lineItems.count ?? result.tables?.count ?? 0
                let noun = result.kind == .statement ? "transactions" : result.kind == .invoice ? "line items" : "tables"
                update { $0.savedPath = path.path; $0.message = "\(count) \(noun) saved to \(path.lastPathComponent)" }
            }
            update { $0.state = "done"; $0.detail = "Done" }
        } catch {
            update { $0.state = "failed"; $0.detail = error.localizedDescription; $0.message = error.localizedDescription }
        }
    }

    /// Keeps the job table small: finished jobs go first, oldest first; running jobs are never dropped.
    static func prune() {
        guard jobs.count > maxJobs else { return }
        let finished = jobs.filter { $0.value.state != "running" }.sorted { $0.value.started < $1.value.started }
        for (k, _) in finished.prefix(jobs.count - maxJobs) { jobs[k] = nil }
    }
}
