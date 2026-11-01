import Foundation

/// Plays video on Roku players and Roku TVs through Roku's External Control Protocol (port 8060).
///
/// Uses Roku's built-in "Play on Roku" channel (id 15985). Roku doesn't allow jumping to an exact
/// time from outside, so this has play/pause and stop but no seek bar. Newer Roku TVs also
/// support AirPlay, which gives full controls.
@MainActor
final class RokuController: CastSessionController {
    let device: CastDevice
    var capabilities: CastCapabilities { CastCapabilities(seek: false, volume: false) }
    private var lastState: PlaybackState = .unknown

    init(device: CastDevice) {
        self.device = device
    }

    private var base: URL { URL(string: "http://\(device.host):\(device.port)/")! }

    func connect() async throws {
        _ = try await request("query/device-info", method: "GET")
    }

    func load(_ media: CastMedia, startAt: Double) async throws {
        let format = media.kind == .hls ? "hls" : (media.kind == .audio ? "mp3" : "mp4")
        let query = [
            ("t", media.kind == .audio ? "a" : "v"),
            ("u", media.url.absoluteString),
            ("k", "(null)"),
            ("videoName", media.title),
            ("videoFormat", format),
        ].map { "\($0.0)=\(NetworkUtils.strictEncode($0.1))" }.joined(separator: "&")
        _ = try await request("input/15985?\(query)", method: "POST")
        lastState = .loading
    }

    func play() async throws {
        if lastState != .playing { try await key("Play") }
    }

    func pause() async throws {
        if lastState == .playing { try await key("Play") }
    }

    func seek(to seconds: Double) async throws {
        throw CastError.unsupported("seeking")
    }

    func setVolume(_ level: Double) async throws {
        throw CastError.unsupported("volume control")
    }

    func stop() async throws {
        try await key("Back")
    }

    func status() async throws -> PlaybackStatus {
        let xml = try await request("query/media-player", method: "GET")
        var s = PlaybackStatus()
        switch XMLText.attribute("state", in: xml) ?? "" {
        case "play": s.state = .playing
        case "pause": s.state = .paused
        case "buffer", "startup": s.state = .buffering
        case "stop", "close": s.state = .stopped
        case "none": s.state = .idle
        default: s.state = .unknown
        }
        if XMLText.attribute("error", in: xml) == "true" {
            s.message = "Roku couldn't play this video. Try the iPhone relay, or AirPlay if your Roku supports it."
        }
        s.position = Self.ms(XMLText.value(of: "position", in: xml))
        s.duration = Self.ms(XMLText.value(of: "duration", in: xml))
        lastState = s.state
        return s
    }

    func disconnect() {}

    private func key(_ name: String) async throws {
        _ = try await request("keypress/\(name)", method: "POST")
    }

    /// Presses a button on the Roku remote, e.g. "Home", "Select", "Up", "VolumeUp".
    nonisolated static func press(_ key: String, on device: CastDevice) async throws {
        guard let url = URL(string: "http://\(device.host):\(device.port)/keypress/\(key)") else { return }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        req.httpMethod = "POST"
        req.httpBody = Data()
        let (_, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CastError.http(http.statusCode)
        }
    }

    /// Types text into the Roku's on-screen keyboard (search boxes and so on).
    nonisolated static func type(_ text: String, on device: CastDevice) async throws {
        for scalar in text.unicodeScalars {
            try await press("Lit_" + NetworkUtils.strictEncode(String(scalar)), on: device)
        }
    }

    private func request(_ path: String, method: String) async throws -> String {
        guard let url = URL(string: path, relativeTo: base) else { throw CastError.badResponse }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        req.httpMethod = method
        if method == "POST" { req.httpBody = Data() }
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CastError.http(http.statusCode)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func ms(_ text: String?) -> Double {
        guard let text else { return 0 }
        let digits = text.prefix { $0.isNumber }
        return (Double(String(digits)) ?? 0) / 1000
    }

    nonisolated static func describe(location: URL) async -> CastDevice? {
        guard let host = location.host else { return nil }
        let port = location.port ?? 8060
        guard let url = URL(string: "http://\(host):\(port)/query/device-info") else { return nil }
        let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        let xml = String(decoding: data, as: UTF8.self)
        guard xml.contains("<device-info") else { return nil }
        let name = XMLText.value(of: "user-device-name", in: xml)
            ?? XMLText.value(of: "friendly-device-name", in: xml)
            ?? XMLText.value(of: "default-device-name", in: xml)
            ?? "Roku"
        let serial = XMLText.value(of: "serial-number", in: xml) ?? host
        var d = CastDevice(id: "roku:" + serial, name: name, kind: .roku, host: host, port: port)
        d.model = XMLText.value(of: "model-name", in: xml)
        return d
    }
}
