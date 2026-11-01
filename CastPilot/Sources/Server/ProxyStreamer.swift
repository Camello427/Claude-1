import Foundation
import Network

/// Streams one upstream response to one TV connection, pausing the download when the TV
/// reads slowly so memory stays low. Playlists are buffered and rewritten instead.
final class ProxyStreamer: NSObject, URLSessionDataDelegate {
    private let conn: NWConnection
    private let isHead: Bool
    private let forcePlaylist: Bool
    private let rewrite: (String, URL) -> String
    private let extraHeaders: [(String, String)]

    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var buffering = false
    private var buffer = Data()
    private var headerSent = false
    private var inFlight = 0
    private var suspended = false
    private var finished = false

    private static let highWater = 6 * 1024 * 1024
    private static let lowWater = 2 * 1024 * 1024
    private static let maxPlaylist = 16 * 1024 * 1024

    init(connection: NWConnection, isHead: Bool, forcePlaylist: Bool, extraHeaders: [(String, String)] = [],
         rewrite: @escaping (String, URL) -> String) {
        self.extraHeaders = extraHeaders
        self.conn = connection
        self.isHead = isHead
        self.forcePlaylist = forcePlaylist
        self.rewrite = rewrite
    }

    func start(_ request: URLRequest) {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        self.session = session
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.cancelUpstream()
            default: break
            }
        }
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    private func cancelUpstream() {
        lock.lock()
        let t = finished ? nil : task
        lock.unlock()
        t?.cancel()
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        self.response = http
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let ext = http.url?.pathExtension.lowercased() ?? ""
        let isPlaylist = forcePlaylist || type.contains("mpegurl") || ext == "m3u8"
        if isPlaylist && (200..<300).contains(http.statusCode) {
            buffering = true
            completionHandler(.allow)
            return
        }
        var headers: [(String, String)] = []
        for name in ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "Last-Modified", "ETag"] {
            if let v = http.value(forHTTPHeaderField: name) { headers.append((name, v)) }
        }
        if http.value(forHTTPHeaderField: "Accept-Ranges") == nil, http.statusCode == 206 {
            headers.append(("Accept-Ranges", "bytes"))
        }
        headers += extraHeaders
        conn.send(content: LocalMediaServer.head(status: http.statusCode, headers: headers), completion: .contentProcessed { _ in })
        headerSent = true
        completionHandler(isHead ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if buffering {
            buffer.append(data)
            if buffer.count > Self.maxPlaylist { dataTask.cancel() }
            return
        }
        lock.lock()
        inFlight += data.count
        let shouldSuspend = inFlight > Self.highWater && !suspended
        if shouldSuspend { suspended = true }
        lock.unlock()
        if shouldSuspend { dataTask.suspend() }

        let count = data.count
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.cancelUpstream()
                return
            }
            self.lock.lock()
            self.inFlight -= count
            let shouldResume = self.suspended && self.inFlight < Self.lowWater
            if shouldResume { self.suspended = false }
            let t = self.task
            self.lock.unlock()
            if shouldResume { t?.resume() }
        })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        finished = true
        lock.unlock()
        defer { session.finishTasksAndInvalidate() }

        if buffering, let http = response, error == nil {
            let text = String(decoding: buffer, as: UTF8.self)
            let base = http.url ?? task.originalRequest?.url ?? URL(string: "http://localhost/")!
            let body = Data(rewrite(text, base).utf8)
            let head = LocalMediaServer.head(status: 200, headers: [
                ("Content-Type", "application/vnd.apple.mpegurl"),
                ("Content-Length", String(body.count)),
                ("Cache-Control", "no-cache"),
            ])
            conn.send(content: head, completion: .contentProcessed { _ in })
            if !isHead { conn.send(content: body, completion: .contentProcessed { _ in }) }
            LocalMediaServer.finish(conn)
            return
        }
        if !headerSent {
            let message = Data("Upstream error: \(error?.localizedDescription ?? "unknown")".utf8)
            LocalMediaServer.respond(conn, status: 502, headers: [("Content-Type", "text/plain")], body: message)
            return
        }
        if let error, (error as? URLError)?.code != .cancelled {
            conn.cancel()   // Cut the response short so the TV knows it's incomplete.
            return
        }
        LocalMediaServer.finish(conn)
    }
}
