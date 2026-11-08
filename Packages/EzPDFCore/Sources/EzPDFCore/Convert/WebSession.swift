import Foundation
import WebKit

/// One offscreen WKWebView with navigation guarded by `URLGuard`. Owns load/settle/JS so the
/// converters above it only describe what to capture. Adapted from MuseDrop's WebPageRenderer.
@MainActor
final class WebSession: NSObject, WKNavigationDelegate {
    enum SessionError: LocalizedError {
        case blocked(String), loadFailed(String), timedOut
        var errorDescription: String? {
            switch self {
            case .blocked(let u): return "ezpdf won't open \(u) (local-network and non-web addresses are blocked)."
            case .loadFailed(let d): return "The page didn't load: \(d)"
            case .timedOut: return "The page took too long to load."
            }
        }
    }

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    let webView: WKWebView
    private let allowLocal: Bool
    private var loadContinuation: CheckedContinuation<Void, Error>?
    /// While false, the main frame may not navigate anywhere (layout documents, finished pages).
    private var navigationOpen = true
    private var committed = false

    init(width: CGFloat, height: CGFloat, javaScript: Bool, allowLocal: Bool = false) {
        self.allowLocal = allowLocal
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = javaScript
        config.websiteDataStore = .nonPersistent()      // never reuse the user's sessions or cookies
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.suppressesIncrementalRendering = false
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: height), configuration: config)
        webView.customUserAgent = Self.userAgent
        super.init()
        webView.navigationDelegate = self
    }

    /// Stops loading and breaks the delegate cycle. Call when done with the session.
    func close() {
        resumeLoad(SessionError.loadFailed("cancelled"))
        webView.stopLoading()
        webView.navigationDelegate = nil
    }

    var currentURL: URL? { webView.url }

    // MARK: Loading

    func load(_ url: URL, timeout: TimeInterval = 30) async throws {
        guard URLGuard.isAllowed(url, allowLocal: allowLocal) else { throw SessionError.blocked(url.absoluteString) }
        var request = URLRequest(url: url)
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        navigationOpen = true
        committed = false
        try await waitForLoad(timeout: timeout) { self.webView.load(request) }
    }

    /// Loads an HTML string whose main frame is then frozen: later navigations are refused.
    func loadHTML(_ html: String, baseURL: URL?, timeout: TimeInterval = 20) async throws {
        navigationOpen = true
        committed = false
        try await waitForLoad(timeout: timeout) { self.webView.loadHTMLString(html, baseURL: baseURL) }
        navigationOpen = false
    }

    private func waitForLoad(timeout: TimeInterval, start: @escaping () -> Void) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            loadContinuation = c
            start()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, self.loadContinuation != nil else { return }
                // A page that never fires didFinish (long polling, endless trackers) is still
                // usable once it has committed; only a page that never arrived is an error.
                if self.committed { self.resumeLoad(nil) } else { self.resumeLoad(SessionError.timedOut) }
            }
        }
    }

    private func resumeLoad(_ error: Error?) {
        guard let c = loadContinuation else { return }
        loadContinuation = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if let frame = action.targetFrame, !frame.isMainFrame {
            // Sub-frames load freely, except local-network addresses.
            if let u = action.request.url, u.scheme?.hasPrefix("http") == true,
               !URLGuard.isAllowed(u, allowLocal: allowLocal) {
                decisionHandler(.cancel); return
            }
            decisionHandler(.allow); return
        }
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if !navigationOpen { decisionHandler(.cancel); return }
        if url.scheme == "about" || url.scheme == "data" { decisionHandler(.allow); return }
        if URLGuard.isAllowed(url, allowLocal: allowLocal) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            resumeLoad(SessionError.blocked(url.absoluteString))
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { committed = true }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { resumeLoad(nil) }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        if committed { resumeLoad(nil) } else { resumeLoad(SessionError.loadFailed(error.localizedDescription)) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        resumeLoad(SessionError.loadFailed(error.localizedDescription))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        resumeLoad(SessionError.loadFailed("the page crashed"))
    }

    // MARK: Settle

    /// Waits until client-side rendering stops changing the text (two equal, non-zero polls),
    /// with a short floor so SPAs get a moment to start.
    func settle(minWait: TimeInterval = 0.8, maxWait: TimeInterval = 15) async {
        let deadline = Date().addingTimeInterval(maxWait)
        try? await Task.sleep(for: .seconds(minWait))
        var tracker = SettleTracker()
        while Date() < deadline {
            let length = (try? await js("return document.body ? document.body.innerText.length : 0")) as? Int ?? 0
            if tracker.record(length) { return }
            try? await Task.sleep(for: .milliseconds(450))
        }
    }

    /// Waits for images still downloading, up to `maxWait`.
    func waitForImages(maxWait: TimeInterval = 8) async {
        let deadline = Date().addingTimeInterval(maxWait)
        while Date() < deadline {
            let pending = (try? await js("return Array.from(document.images).filter(i => !i.complete).length")) as? Int ?? 0
            if pending == 0 { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    // MARK: JavaScript

    /// Runs `body` as an async function in an isolated world (page scripts can't tamper with it).
    /// A JS call that doesn't answer within `timeout` (a page busy in its own scripts) throws
    /// instead of hanging the conversion.
    @discardableResult
    func js(_ body: String, _ arguments: [String: Any] = [:], timeout: TimeInterval = 20) async throws -> Any? {
        let box = JSResultBox()
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Any?, Error>) in
            box.continuation = c
            webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .defaultClient) { result in
                switch result {
                case .success(let v): box.resume(.success(v))
                case .failure(let e): box.resume(.failure(e))
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                box.resume(.failure(EzPDFError.failed("The page stopped responding.")))
            }
        }
    }

    func jsString(_ body: String, _ arguments: [String: Any] = [:], timeout: TimeInterval = 20) async throws -> String {
        (try await js(body, arguments, timeout: timeout) as? String) ?? ""
    }

    /// A vector PDF of `rect` (document coordinates), or a throw if the page doesn't answer.
    func pdf(rect: CGRect, timeout: TimeInterval = 20) async throws -> Data {
        let box = PDFResultBox()
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            box.continuation = c
            let config = WKPDFConfiguration()
            config.rect = rect
            webView.createPDF(configuration: config) { result in box.resume(result) }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                box.resume(.failure(EzPDFError.failed("The page stopped responding.")))
            }
        }
    }
}

@MainActor
private final class JSResultBox {
    var continuation: CheckedContinuation<Any?, Error>?
    func resume(_ r: Result<Any?, Error>) {
        guard let c = continuation else { return }
        continuation = nil
        c.resume(with: r)
    }
}

@MainActor
private final class PDFResultBox {
    var continuation: CheckedContinuation<Data, Error>?
    func resume(_ r: Result<Data, Error>) {
        guard let c = continuation else { return }
        continuation = nil
        c.resume(with: r)
    }
}

/// Settle decision: two consecutive non-zero polls with the same text length.
struct SettleTracker {
    private var previous: Int?
    mutating func record(_ length: Int) -> Bool {
        defer { previous = length }
        return length > 0 && previous == length
    }
}
