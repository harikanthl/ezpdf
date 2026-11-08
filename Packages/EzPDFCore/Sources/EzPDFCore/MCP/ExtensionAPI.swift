import Foundation
import AppKit

/// REST endpoints for the ezpdf browser extension (Safari and Chrome share one codebase).
///   GET  /ext/health                 → {app, version, kindle, preset}
///   POST /ext/run {url, flow, preset?, html?, title?} → {job}
///   GET  /ext/status?job=…           → {state, detail, title, document}
///   POST /ext/open {id}              → shows the document in ezpdf
///   POST /ext/reveal {path}          → shows a saved file in Finder
@MainActor
enum ExtensionAPI {
    enum Flow: String { case pdf, epub, kindle, extract, open }

    struct ExtJob { var state = "running"; var detail = "Starting"; var title = ""; var documentID: String?; var savedPath: String?; var message: String? }
    static var jobs: [String: ExtJob] = [:]

    static func handle(_ req: HTTPRequest) async -> HTTPResponse {
        let body = req.json() as? [String: Any] ?? [:]
        switch (req.method, req.path) {
        case ("GET", "/ext/health"):
            let k = KindleSender.Settings.load()
            return .json(200, ["app": "ezpdf", "version": "0.1.0", "kindle": !k.address.isEmpty,
                               "preset": EzPDF.shared.defaultPreset.rawValue,
                               "presets": PagePreset.allCases.map { ["id": $0.rawValue, "name": $0.displayName] }])
        case ("POST", "/ext/run"):
            guard let raw = body.str("url"), let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else {
                return .json(400, ["error": "That tab has no web address ezpdf can open."])
            }
            let flow = Flow(rawValue: body.str("flow") ?? "pdf") ?? .pdf
            let id = UUID().uuidString
            jobs[id] = ExtJob(title: body.str("title") ?? url.host() ?? "")
            let preset = PagePreset.parse(body.str("preset"))
            let html = body["html"] as? String
            Task { await run(id, url: url, flow: flow, preset: preset, html: html, title: body.str("title")) }
            pruneJobs()
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
            guard let p = body.str("path"), FileManager.default.fileExists(atPath: p),
                  p.hasPrefix(EzPDF.shared.exportFolder.path) || p.hasPrefix(Library.shared.root.path) else {
                return .json(404, ["error": "Not found"])
            }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
            return .json(200, ["ok": true])
        default:
            return .json(404, ["error": "Not found"])
        }
    }

    static func run(_ id: String, url: URL, flow: Flow, preset: PagePreset?, html: String?, title: String?) async {
        let ops = EzPDF.shared
        func update(_ change: (inout ExtJob) -> Void) { if var j = jobs[id] { change(&j); jobs[id] = j } }
        // Mirror the shared job's progress text into the extension's job.
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                if let j = ops.jobs.first(where: { $0.state == .running }) { update { $0.detail = j.detail } }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        defer { watcher.cancel() }
        do {
            let format: OutputFormat = flow == .epub ? .both : (flow == .kindle ? .both : (flow == .extract ? .pdf : ops.defaultFormat))
            let rec: DocumentRecord
            if let html, !html.isEmpty {
                rec = try await ops.convert(html: html, url: url, preset: preset, format: format, title: title, source: .browser)
            } else {
                rec = try await ops.convert(url: url, preset: preset, format: format, title: title, source: .browser)
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
                let r = try ops.sendToKindle(rec.id)
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

    static func pruneJobs() {
        if jobs.count > 50 { jobs = jobs.filter { $0.value.state == "running" } }
    }
}
