import Foundation

/// URLSession downloads that re-check every redirect hop against URLGuard (and DNS), stream the
/// body, and stop at a size cap instead of buffering whatever the server sends.
final class GuardedDownload: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let allowLocal: Bool
    init(allowLocal: Bool = false) { self.allowLocal = allowLocal }

    lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 180
        config.httpAdditionalHeaders = ["User-Agent": WebSession.userAgent]
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, await URLGuard.resolvesPublic(url, allowLocal: allowLocal) else { return nil }
        return request
    }

    enum Outcome { case data(Data, HTTPURLResponse), skipped, tooLarge }

    /// Fetches `url`. `accept` sees the response headers first and can skip the body.
    func fetch(_ url: URL, maxBytes: Int, accept: (HTTPURLResponse) -> Bool = { _ in true }) async throws -> Outcome {
        guard await URLGuard.resolvesPublic(url, allowLocal: allowLocal) else {
            throw EzPDFError.invalidInput("ezpdf doesn't open addresses on your local network.")
        }
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { bytes.task.cancel(); return .skipped }
        guard accept(http) else { bytes.task.cancel(); return .skipped }
        if http.expectedContentLength > Int64(maxBytes) { bytes.task.cancel(); return .tooLarge }
        var data = Data()
        data.reserveCapacity(Int(min(max(http.expectedContentLength, 0), Int64(maxBytes))))
        var chunk = [UInt8]()
        chunk.reserveCapacity(64 * 1024)
        for try await b in bytes {
            chunk.append(b)
            if chunk.count == 64 * 1024 {
                data.append(contentsOf: chunk); chunk.removeAll(keepingCapacity: true)
                if data.count > maxBytes { bytes.task.cancel(); return .tooLarge }
            }
        }
        data.append(contentsOf: chunk)
        if data.count > maxBytes { return .tooLarge }
        return .data(data, http)
    }

    func finish() { session.finishTasksAndInvalidate() }
}
