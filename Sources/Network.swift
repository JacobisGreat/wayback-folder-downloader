import Foundation

struct HTTPReply {
    let data: Data
    let response: HTTPURLResponse

    var finalURL: URL { response.url! }
    var capture: Capture? { Capture(url: finalURL) }
}

private final class Redirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let host = request.url?.host?.lowercased()
        let firstHost = task.originalRequest?.url?.host?.lowercased()
        let sameHost = host == firstHost
        let safeURL = request.url?.scheme?.lowercased() == "https"
            && request.url?.user == nil && request.url?.password == nil && request.url?.port == nil
        completionHandler(sameHost && safeURL ? request : nil)
    }
}

final class Network: Sendable {
    private let session: URLSession

    init() {
        let options = URLSessionConfiguration.ephemeral
        options.timeoutIntervalForRequest = 16
        options.timeoutIntervalForResource = 40
        options.urlCache = nil
        options.httpAdditionalHeaders = ["User-Agent": "WaybackFolderDownloader/1.0"]
        session = URLSession(configuration: options, delegate: Redirects(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func get(_ url: URL, accept: String? = nil) async throws -> HTTPReply {
        var request = URLRequest(url: url)
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        for attempt in 0...1 {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.url != nil else {
                throw DownloadError("The server returned an unreadable response.")
            }
            if http.statusCode == 200 { return HTTPReply(data: data, response: http) }
            if attempt == 0 && [502, 503, 504].contains(http.statusCode) {
                try await Task.sleep(for: .milliseconds(600))
                continue
            }
            throw DownloadError("\(url.host ?? "The server") returned HTTP \(http.statusCode).")
        }
        throw DownloadError("The server is temporarily unavailable.")
    }
}
