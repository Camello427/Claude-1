import Foundation
import Network

/// What the relay sends upstream so a site serves the video to the TV the same way it did
/// to the in-app browser.
struct HeaderProfile {
    var referer: String?
    var userAgent: String?
    var cookies: [HTTPCookie]
}

struct HTTPRequestHead {
    let method: String
    let path: String
    let headers: [String: String]

    init?(_ text: String) {
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        method = String(requestLine[0]).uppercased()
        path = String(requestLine[1])
        var h: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            h[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        headers = h
    }
}

/// A small HTTP server on the phone, reachable by TVs on the same Wi-Fi.
///
/// - `/r/<profile>/<base64 url>/<name>` relays a web video, adding the browser's Referer,
///   User-Agent and cookies, plus CORS headers (which Chromecast needs for HLS). HLS playlists
///   are rewritten so every segment also goes through the relay.
/// - `/f/<id>/<name>` serves an imported file, with byte-range support for seeking.
final class LocalMediaServer {
    static let shared = LocalMediaServer()

    private let queue = DispatchQueue(label: "castpilot.server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var profiles: [String: HeaderProfile] = [:]
    private var files: [String: URL] = [:]

    static let preferredPort: UInt16 = 8975

    // MARK: - Public API

    /// Starts the server if needed and returns its base URL, e.g. http://192.168.1.23:8975
    func ensureRunning() async throws -> URL {
        guard let ip = NetworkUtils.wifiIPv4() else { throw CastError.noWiFi }
        let port = try await startIfNeeded()
        guard let url = URL(string: "http://\(ip):\(port)") else { throw CastError.noWiFi }
        return url
    }

    func register(_ profile: HeaderProfile) -> String {
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        lock.lock(); profiles[id] = profile; lock.unlock()
        return id
    }

    func registerFile(_ url: URL) -> String {
        lock.lock(); defer { lock.unlock() }
        if let existing = files.first(where: { $0.value == url })?.key { return existing }
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        files[id] = url
        return id
    }

    func relayURL(base: URL, upstream: URL, profileID: String, fileName: String? = nil) -> URL {
        Self.relayURL(base: base.absoluteString, upstream: upstream, profileID: profileID, fileName: fileName)
    }

    func fileURL(base: URL, id: String, file: URL) -> URL {
        URL(string: "\(base.absoluteString)/f/\(id)/\(NetworkUtils.strictEncode(file.lastPathComponent))")!
    }

    // MARK: - Listener

    private func startIfNeeded() async throws -> UInt16 {
        let existing = lock.withLock { listener }
        if let existing, existing.state == .ready, let port = existing.port?.rawValue { return port }
        existing?.cancel()
        do {
            return try await startListener(on: NWEndpoint.Port(rawValue: Self.preferredPort) ?? .any)
        } catch {
            return try await startListener(on: .any)
        }
    }

    private func startListener(on port: NWEndpoint.Port) async throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: port)
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        let once = OnceFlag()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            l.stateUpdateHandler = { [weak l] state in
                switch state {
                case .ready:
                    if once.claim() { cont.resume(returning: l?.port?.rawValue ?? port.rawValue) }
                case .failed(let error):
                    if once.claim() { cont.resume(throwing: error) }
                    l?.cancel()
                case .cancelled:
                    if once.claim() { cont.resume(throwing: CastError.notConnected) }
                default:
                    break
                }
            }
            lock.lock(); listener = l; lock.unlock()
            l.start(queue: queue)
        }
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        readHead(conn, buffer: Data())
    }

    private func readHead(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                let text = String(decoding: buf[buf.startIndex..<end.lowerBound], as: UTF8.self)
                if let req = HTTPRequestHead(text) {
                    self.route(req, conn)
                } else {
                    Self.respond(conn, status: 400)
                }
            } else if complete || error != nil || buf.count > 64 * 1024 {
                conn.cancel()
            } else {
                self.readHead(conn, buffer: buf)
            }
        }
    }

    // MARK: - Routing

    private func route(_ req: HTTPRequestHead, _ conn: NWConnection) {
        if req.method == "OPTIONS" { Self.respond(conn, status: 204); return }
        guard req.method == "GET" || req.method == "HEAD" else { Self.respond(conn, status: 405); return }

        let pathOnly = req.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        let parts = pathOnly.split(separator: "/").map(String.init)

        lock.lock()
        let profile = parts.count >= 3 && parts[0] == "r" ? profiles[parts[1]] : nil
        let file = parts.count >= 2 && parts[0] == "f" ? files[parts[1]] : nil
        lock.unlock()

        if let profile, let decoded = NetworkUtils.base64URLDecode(parts[2]), let upstream = URL(string: decoded) {
            relay(req, upstream: upstream, profileID: parts[1], profile: profile, conn: conn)
        } else if let file {
            serveFile(file, req, conn)
        } else {
            Self.respond(conn, status: 404, body: Data("Not found".utf8))
        }
    }

    // MARK: - Relay

    private func relay(_ req: HTTPRequestHead, upstream: URL, profileID: String, profile: HeaderProfile, conn: NWConnection) {
        let ext = upstream.pathExtension.lowercased()
        let looksLikePlaylist = ext == "m3u8" || ext == "m3u"

        var r = URLRequest(url: upstream, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        r.httpMethod = (req.method == "HEAD" && !looksLikePlaylist) ? "HEAD" : "GET"
        r.httpShouldHandleCookies = false
        if let ua = profile.userAgent { r.setValue(ua, forHTTPHeaderField: "User-Agent") }
        if let referer = profile.referer { r.setValue(referer, forHTTPHeaderField: "Referer") }
        r.setValue("*/*", forHTTPHeaderField: "Accept")
        r.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let range = req.headers["range"], !looksLikePlaylist { r.setValue(range, forHTTPHeaderField: "Range") }
        let cookies = profile.cookies.filter { $0.applies(to: upstream) }
        if !cookies.isEmpty {
            for (k, v) in HTTPCookie.requestHeaderFields(with: cookies) { r.setValue(v, forHTTPHeaderField: k) }
        }

        let serverBase: String
        if let host = req.headers["host"], !host.isEmpty {
            serverBase = "http://\(host)"
        } else {
            serverBase = "http://\(NetworkUtils.wifiIPv4() ?? "127.0.0.1"):\(listener?.port?.rawValue ?? Self.preferredPort)"
        }

        let streamer = ProxyStreamer(connection: conn, isHead: req.method == "HEAD", forcePlaylist: looksLikePlaylist) { text, finalURL in
            Self.rewritePlaylist(text, base: finalURL, serverBase: serverBase, profileID: profileID)
        }
        streamer.start(r)
    }

    static func relayURL(base: String, upstream: URL, profileID: String, fileName: String?) -> URL {
        var name = fileName ?? upstream.lastPathComponent
        if name.isEmpty || name == "/" { name = "media" }
        let encoded = NetworkUtils.base64URLEncode(upstream.absoluteString)
        return URL(string: "\(base)/r/\(profileID)/\(encoded)/\(NetworkUtils.strictEncode(name))")!
    }

    /// Points every URL in an HLS playlist back at the relay.
    static func rewritePlaylist(_ text: String, base: URL, serverBase: String, profileID: String) -> String {
        guard text.contains("#EXT") else { return text }
        var out: [String] = []
        var nextIsPlaylist = false
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                out.append("")
            } else if line.hasPrefix("#") {
                if line.hasPrefix("#EXT-X-STREAM-INF") { nextIsPlaylist = true }
                out.append(rewriteURIAttributes(line, base: base, serverBase: serverBase, profileID: profileID))
            } else if let abs = URL(string: line, relativeTo: base)?.absoluteURL {
                var name: String? = nil
                if nextIsPlaylist && abs.pathExtension.isEmpty { name = "index.m3u8" }
                out.append(relayURL(base: serverBase, upstream: abs, profileID: profileID, fileName: name).absoluteString)
                nextIsPlaylist = false
            } else {
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }

    private static let uriAttribute = try! NSRegularExpression(pattern: "URI=\"([^\"]+)\"")

    private static func rewriteURIAttributes(_ line: String, base: URL, serverBase: String, profileID: String) -> String {
        guard line.contains("URI=\"") else { return line }
        let result = NSMutableString(string: line)
        let matches = uriAttribute.matches(in: line, range: NSRange(location: 0, length: (line as NSString).length))
        for m in matches.reversed() {
            let value = (line as NSString).substring(with: m.range(at: 1))
            // Leave data: URIs and DRM key schemes (skd://, etc.) alone.
            guard let abs = URL(string: value, relativeTo: base)?.absoluteURL,
                  abs.scheme == "http" || abs.scheme == "https" else { continue }
            var name: String? = nil
            if line.hasPrefix("#EXT-X-MEDIA") || line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF"), abs.pathExtension.isEmpty { name = "index.m3u8" }
            let relayed = relayURL(base: serverBase, upstream: abs, profileID: profileID, fileName: name).absoluteString
            result.replaceCharacters(in: m.range(at: 1), with: relayed)
        }
        return result as String
    }

    // MARK: - Local files

    private func serveFile(_ url: URL, _ req: HTTPRequestHead, _ conn: NWConnection) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value, size > 0,
              let handle = try? FileHandle(forReadingFrom: url) else {
            Self.respond(conn, status: 404)
            return
        }
        var start: Int64 = 0
        var end: Int64 = size - 1
        var status = 200
        if let range = req.headers["range"] {
            guard let parsed = Self.parseRange(range, size: size) else {
                try? handle.close()
                Self.respond(conn, status: 416, headers: [("Content-Range", "bytes */\(size)")])
                return
            }
            (start, end) = parsed
            status = 206
        }
        var headers: [(String, String)] = [
            ("Content-Type", MediaKind.mimeType(forFile: url)),
            ("Content-Length", String(end - start + 1)),
            ("Accept-Ranges", "bytes"),
        ]
        if status == 206 { headers.append(("Content-Range", "bytes \(start)-\(end)/\(size)")) }
        conn.send(content: Self.head(status: status, headers: headers), completion: .contentProcessed { _ in })
        if req.method == "HEAD" {
            try? handle.close()
            Self.finish(conn)
            return
        }
        streamFile(handle, conn: conn, offset: start, remaining: end - start + 1)
    }

    private func streamFile(_ handle: FileHandle, conn: NWConnection, offset: Int64, remaining: Int64) {
        guard remaining > 0 else {
            try? handle.close()
            Self.finish(conn)
            return
        }
        let chunk = Int(min(remaining, 512 * 1024))
        let data: Data
        do {
            try handle.seek(toOffset: UInt64(offset))
            data = try handle.read(upToCount: chunk) ?? Data()
        } catch {
            try? handle.close()
            conn.cancel()
            return
        }
        guard !data.isEmpty else {
            try? handle.close()
            Self.finish(conn)
            return
        }
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil {
                try? handle.close()
                conn.cancel()
                return
            }
            self?.streamFile(handle, conn: conn, offset: offset + Int64(data.count), remaining: remaining - Int64(data.count))
        })
    }

    static func parseRange(_ header: String, size: Int64) -> (Int64, Int64)? {
        guard header.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
        let bounds = spec.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard bounds.count == 2 else { return nil }
        if bounds[0].isEmpty {
            guard let suffix = Int64(bounds[1]), suffix > 0 else { return nil }
            return (max(0, size - suffix), size - 1)
        }
        guard let start = Int64(bounds[0]), start < size else { return nil }
        let end = bounds[1].isEmpty ? size - 1 : min(Int64(bounds[1]) ?? (size - 1), size - 1)
        guard end >= start else { return nil }
        return (start, end)
    }

    // MARK: - HTTP helpers

    static let commonHeaders = [
        "Access-Control-Allow-Origin: *",
        "Access-Control-Allow-Headers: *",
        "Access-Control-Allow-Methods: GET, HEAD, OPTIONS",
        "Access-Control-Expose-Headers: Content-Length, Content-Range, Accept-Ranges",
        "transferMode.dlna.org: Streaming",
        "contentFeatures.dlna.org: DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000",
        "Server: CastPilot/1.0",
        "Connection: close",
    ]

    static func head(status: Int, headers: [(String, String)]) -> Data {
        var lines = ["HTTP/1.1 \(status) \(reason(status))"]
        lines += headers.map { "\($0.0): \($0.1)" }
        lines += commonHeaders
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    static func respond(_ conn: NWConnection, status: Int, headers: [(String, String)] = [], body: Data? = nil) {
        var all = headers
        all.append(("Content-Length", String(body?.count ?? 0)))
        var payload = head(status: status, headers: all)
        if let body { payload.append(body) }
        conn.send(content: payload, completion: .contentProcessed { _ in })
        finish(conn)
    }

    static func finish(_ conn: NWConnection) {
        conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 416: return "Range Not Satisfiable"
        case 502: return "Bad Gateway"
        default: return "Status"
        }
    }
}
