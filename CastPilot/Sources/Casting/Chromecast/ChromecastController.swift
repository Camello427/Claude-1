import Foundation
import Network

/// Plays video on Chromecast, Google TV, Android TV and TVs with Chromecast built-in, using
/// Google's Default Media Receiver. Speaks the Cast v2 protocol directly (no Google SDK).
@MainActor
final class ChromecastController: CastSessionController {
    let device: CastDevice
    var capabilities: CastCapabilities { CastCapabilities(seek: true, volume: true, speed: true, subtitleToggle: true) }

    private enum NS {
        static let connection = "urn:x-cast:com.google.cast.tp.connection"
        static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
        static let receiver = "urn:x-cast:com.google.cast.receiver"
        static let media = "urn:x-cast:com.google.cast.media"
    }

    static let defaultMediaReceiver = "CC1AD845"

    private let senderId = "sender-0"
    private var channel: ChromecastChannel?
    private var nextRequestId = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var heartbeat: Task<Void, Never>?
    private var transportId: String?
    private var connectedTransport: String?
    private var appSessionId: String?
    private var mediaSessionId: Int?
    private var current = PlaybackStatus()
    private var knownDuration: Double = 0

    init(device: CastDevice) {
        self.device = device
    }

    func connect() async throws {
        let ch: ChromecastChannel
        if let endpoint = device.bonjourEndpoint {
            ch = ChromecastChannel(endpoint: endpoint)
        } else {
            ch = ChromecastChannel(host: device.host, port: device.port)
        }
        ch.onMessage = { [weak self] msg in
            Task { @MainActor in self?.handle(msg) }
        }
        ch.onClose = { [weak self] _ in
            Task { @MainActor in self?.handleClose() }
        }
        try await ch.start()
        channel = ch
        send(NS.connection, to: "receiver-0", ["type": "CONNECT"])
        startHeartbeat()
        let status = try await request(NS.receiver, to: "receiver-0", ["type": "GET_STATUS"])
        updateReceiver(status)
    }

    func load(_ media: CastMedia, startAt: Double) async throws {
        let transport = try await ensureMediaApp()
        var metadata: [String: Any] = ["metadataType": 0, "title": media.title]
        if let poster = media.poster { metadata["images"] = [["url": poster.absoluteString]] }

        var contentType = media.mimeType
        if media.kind == .mov || media.kind == .mkv || media.kind == .unknown { contentType = "video/mp4" }
        if media.kind == .hls { contentType = "application/x-mpegURL" }

        var info: [String: Any] = [
            "contentId": media.url.absoluteString,
            "contentUrl": media.url.absoluteString,
            "contentType": contentType,
            "streamType": media.isLive ? "LIVE" : "BUFFERED",
            "metadata": metadata,
        ]
        var load: [String: Any] = ["type": "LOAD", "autoplay": true, "currentTime": startAt]
        if let vtt = media.subtitleVTT {
            info["tracks"] = [[
                "trackId": 1,
                "type": "TEXT",
                "subtype": "SUBTITLES",
                "trackContentId": vtt.absoluteString,
                "trackContentType": "text/vtt",
                "name": media.subtitleLabel ?? "Subtitles",
                "language": media.subtitleLanguage ?? "en",
            ] as [String: Any]]
            info["textTrackStyle"] = ["backgroundColor": "#00000099", "foregroundColor": "#FFFFFFFF", "fontScale": 1.0] as [String: Any]
            load["activeTrackIds"] = [1]
        }
        load["media"] = info
        knownDuration = 0
        current = PlaybackStatus(state: .loading)
        let reply = try await request(NS.media, to: transport, load, timeout: 30)
        updateMedia(reply)
    }

    func play() async throws { try await mediaCommand("PLAY") }
    func pause() async throws { try await mediaCommand("PAUSE") }

    func seek(to seconds: Double) async throws {
        try await mediaCommand("SEEK", ["currentTime": max(0, seconds)])
    }

    func setRate(_ rate: Double) async throws {
        try await mediaCommand("SET_PLAYBACK_RATE", ["playbackRate": rate])
        current.rate = rate
    }

    func setSubtitlesEnabled(_ enabled: Bool) async throws {
        try await mediaCommand("EDIT_TRACKS_INFO", ["activeTrackIds": enabled ? [1] : [Int]()])
    }

    func setVolume(_ level: Double) async throws {
        let reply = try await request(NS.receiver, to: "receiver-0",
                                      ["type": "SET_VOLUME", "volume": ["level": max(0, min(1, level))]])
        updateReceiver(reply)
    }

    func stop() async throws {
        if mediaSessionId != nil { try? await mediaCommand("STOP") }
        if let appSessionId {
            _ = try? await request(NS.receiver, to: "receiver-0", ["type": "STOP", "sessionId": appSessionId])
        }
        current.state = .stopped
    }

    func status() async throws -> PlaybackStatus {
        guard channel != nil else { throw CastError.notConnected }
        if let transport = transportId, connectedTransport == transport {
            var payload: [String: Any] = ["type": "GET_STATUS"]
            if let mediaSessionId { payload["mediaSessionId"] = mediaSessionId }
            if let reply = try? await request(NS.media, to: transport, payload, timeout: 5) {
                updateMedia(reply)
            }
        }
        return current
    }

    func disconnect() {
        heartbeat?.cancel()
        if let connectedTransport { send(NS.connection, to: connectedTransport, ["type": "CLOSE"]) }
        send(NS.connection, to: "receiver-0", ["type": "CLOSE"])
        channel?.close()
        channel = nil
        failPending(CastError.notConnected)
    }

    // MARK: - Internals

    private func ensureMediaApp() async throws -> String {
        if transportId == nil {
            let reply = try await request(NS.receiver, to: "receiver-0",
                                          ["type": "LAUNCH", "appId": Self.defaultMediaReceiver], timeout: 25)
            updateReceiver(reply)
            var tries = 0
            while transportId == nil && tries < 10 {
                try await Task.sleep(nanoseconds: 500_000_000)
                updateReceiver(try await request(NS.receiver, to: "receiver-0", ["type": "GET_STATUS"]))
                tries += 1
            }
        }
        guard let transport = transportId else { throw CastError.receiver("the TV didn't open its video player") }
        if connectedTransport != transport {
            send(NS.connection, to: transport, ["type": "CONNECT"])
            connectedTransport = transport
        }
        return transport
    }

    private func mediaCommand(_ type: String, _ extra: [String: Any] = [:]) async throws {
        guard let transport = transportId, let mediaSessionId else { throw CastError.notConnected }
        var payload = extra
        payload["type"] = type
        payload["mediaSessionId"] = mediaSessionId
        let reply = try await request(NS.media, to: transport, payload)
        updateMedia(reply)
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.send(NS.heartbeat, to: "receiver-0", ["type": "PING"])
            }
        }
    }

    private func send(_ namespace: String, to destination: String, _ payload: [String: Any]) {
        guard let channel,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        channel.send(CastMessage(sourceId: senderId, destinationId: destination, namespace: namespace, payload: json))
    }

    private func request(_ namespace: String, to destination: String, _ payload: [String: Any],
                         timeout: Double = 10) async throws -> [String: Any] {
        guard channel != nil else { throw CastError.notConnected }
        let id = nextRequestId
        nextRequestId += 1
        var body = payload
        body["requestId"] = id
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            send(namespace, to: destination, body)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let waiting = self?.pending.removeValue(forKey: id) {
                    waiting.resume(throwing: CastError.timeout)
                }
            }
        }
    }

    private func handle(_ msg: CastMessage) {
        guard let data = msg.payload.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let type = json["type"] as? String ?? ""

        if msg.namespace == NS.heartbeat {
            if type == "PING" { send(NS.heartbeat, to: msg.sourceId, ["type": "PONG"]) }
            return
        }
        if msg.namespace == NS.connection {
            if type == "CLOSE", msg.sourceId == connectedTransport {
                connectedTransport = nil
                transportId = nil
                mediaSessionId = nil
                current.state = .idle
            }
            return
        }

        if type == "RECEIVER_STATUS" { updateReceiver(json) }
        if type == "MEDIA_STATUS" { updateMedia(json) }

        if let rid = (json["requestId"] as? NSNumber)?.intValue, rid != 0, let cont = pending.removeValue(forKey: rid) {
            switch type {
            case "LOAD_FAILED", "LOAD_CANCELLED", "INVALID_REQUEST", "LAUNCH_ERROR", "INVALID_PLAYER_STATE", "ERROR":
                var reason = type.replacingOccurrences(of: "_", with: " ").lowercased()
                if let detail = json["reason"] as? String { reason += " (\(detail))" }
                if type == "LOAD_FAILED" { reason = "it couldn't load this video. Try turning on the iPhone relay." }
                cont.resume(throwing: CastError.receiver(reason))
            default:
                cont.resume(returning: json)
            }
        }
    }

    private func updateReceiver(_ json: [String: Any]) {
        guard let status = json["status"] as? [String: Any] else { return }
        if let volume = status["volume"] as? [String: Any], let level = (volume["level"] as? NSNumber)?.doubleValue {
            current.volume = level
        }
        let apps = status["applications"] as? [[String: Any]] ?? []
        if let app = apps.first(where: { ($0["appId"] as? String) == Self.defaultMediaReceiver }) {
            transportId = app["transportId"] as? String
            appSessionId = app["sessionId"] as? String
        } else {
            // Another app (or none) is on screen now.
            transportId = nil
            connectedTransport = nil
            appSessionId = nil
            mediaSessionId = nil
        }
    }

    private func updateMedia(_ json: [String: Any]) {
        guard let list = json["status"] as? [[String: Any]] else { return }
        guard let s = list.first else {
            if current.state != .loading { current.state = .idle }
            return
        }
        if let id = (s["mediaSessionId"] as? NSNumber)?.intValue { mediaSessionId = id }
        if let t = (s["currentTime"] as? NSNumber)?.doubleValue { current.position = t }
        if let r = (s["playbackRate"] as? NSNumber)?.doubleValue, r > 0 { current.rate = r }
        if let media = s["media"] as? [String: Any], let d = (media["duration"] as? NSNumber)?.doubleValue, d > 0 {
            knownDuration = d
        }
        current.duration = knownDuration
        switch s["playerState"] as? String ?? "" {
        case "PLAYING": current.state = .playing; current.message = nil; current.finished = false
        case "PAUSED": current.state = .paused
        case "BUFFERING", "LOADING": current.state = .buffering
        case "IDLE":
            current.state = .idle
            if (s["idleReason"] as? String) == "FINISHED" { current.finished = true }
            if (s["idleReason"] as? String) == "ERROR" {
                current.message = "The TV couldn't play this video. Try turning on the iPhone relay in Settings, or pick another video."
            }
        default: break
        }
    }

    private func handleClose() {
        heartbeat?.cancel()
        channel = nil
        transportId = nil
        connectedTransport = nil
        current.state = .disconnected
        failPending(CastError.notConnected)
    }

    private func failPending(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        waiting.values.forEach { $0.resume(throwing: error) }
    }
}
