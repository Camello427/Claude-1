import Foundation

/// Plays video on UPnP/DLNA media renderers — most Samsung, LG, Sony, Panasonic and Philips
/// smart TVs, plus many streaming boxes, game consoles and apps like Kodi or BubbleUPnP.
@MainActor
final class DLNAController: CastSessionController {
    let device: CastDevice
    var capabilities: CastCapabilities { CastCapabilities(seek: true, volume: device.renderingControlURL != nil) }

    private let avURL: URL
    private let avService: String
    private var lastVolume: Double?
    private var pollCount = 0

    init(device: CastDevice) throws {
        guard let url = device.avTransportURL else { throw CastError.unsupported("video playback (no AVTransport service)") }
        self.device = device
        self.avURL = url
        self.avService = device.avTransportService ?? SSDPTargets.avTransport
    }

    func connect() async throws {
        _ = try await soap(avURL, avService, "GetTransportInfo", [("InstanceID", "0")])
    }

    func load(_ media: CastMedia, startAt: Double) async throws {
        _ = try? await soap(avURL, avService, "Stop", [("InstanceID", "0")])
        let metadata = Self.didl(for: media)
        do {
            _ = try await soap(avURL, avService, "SetAVTransportURI",
                               [("InstanceID", "0"), ("CurrentURI", media.url.absoluteString), ("CurrentURIMetaData", metadata)])
        } catch {
            // Some renderers reject metadata they don't like; try once more without it.
            _ = try await soap(avURL, avService, "SetAVTransportURI",
                               [("InstanceID", "0"), ("CurrentURI", media.url.absoluteString), ("CurrentURIMetaData", "")])
        }
        try await play()
        if startAt > 1 {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            try? await seek(to: startAt)
        }
    }

    func play() async throws {
        _ = try await soap(avURL, avService, "Play", [("InstanceID", "0"), ("Speed", "1")])
    }

    func pause() async throws {
        _ = try await soap(avURL, avService, "Pause", [("InstanceID", "0")])
    }

    func seek(to seconds: Double) async throws {
        _ = try await soap(avURL, avService, "Seek", [("InstanceID", "0"), ("Unit", "REL_TIME"), ("Target", Self.hms(seconds))])
    }

    func setVolume(_ level: Double) async throws {
        guard let rc = device.renderingControlURL else { throw CastError.unsupported("volume control") }
        let v = Int((max(0, min(1, level)) * 100).rounded())
        _ = try await soap(rc, device.renderingControlService ?? "urn:schemas-upnp-org:service:RenderingControl:1", "SetVolume",
                           [("InstanceID", "0"), ("Channel", "Master"), ("DesiredVolume", String(v))])
        lastVolume = Double(v) / 100
    }

    func stop() async throws {
        _ = try await soap(avURL, avService, "Stop", [("InstanceID", "0")])
    }

    func status() async throws -> PlaybackStatus {
        var s = PlaybackStatus()
        let transport = try await soap(avURL, avService, "GetTransportInfo", [("InstanceID", "0")])
        switch XMLText.value(of: "CurrentTransportState", in: transport) ?? "" {
        case "PLAYING": s.state = .playing
        case "PAUSED_PLAYBACK", "PAUSED_RECORDING": s.state = .paused
        case "TRANSITIONING": s.state = .buffering
        case "STOPPED": s.state = .stopped
        case "NO_MEDIA_PRESENT": s.state = .idle
        default: s.state = .unknown
        }
        if XMLText.value(of: "CurrentTransportStatus", in: transport) == "ERROR_OCCURRED" {
            s.message = "The TV couldn't play this video. Try turning on the iPhone relay, or another video."
        }
        if let pos = try? await soap(avURL, avService, "GetPositionInfo", [("InstanceID", "0")]) {
            s.position = Self.seconds(XMLText.value(of: "RelTime", in: pos))
            s.duration = Self.seconds(XMLText.value(of: "TrackDuration", in: pos))
        }
        // Volume changes rarely; ask every few polls.
        if let rc = device.renderingControlURL, pollCount % 5 == 0 || lastVolume == nil {
            if let vol = try? await soap(rc, device.renderingControlService ?? "urn:schemas-upnp-org:service:RenderingControl:1", "GetVolume",
                                         [("InstanceID", "0"), ("Channel", "Master")]),
               let v = XMLText.value(of: "CurrentVolume", in: vol).flatMap({ Double($0) }) {
                lastVolume = v / 100
            }
        }
        pollCount += 1
        s.volume = lastVolume
        return s
    }

    func disconnect() {}

    // MARK: - Discovery

    nonisolated static func describe(location: URL) async -> CastDevice? {
        let request = URLRequest(url: location, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let info = UPnPDescriptionParser.parse(data),
              let av = info.services.first(where: { $0.type.contains(":service:AVTransport:") }) else { return nil }
        let base = info.urlBase.flatMap { URL(string: $0) } ?? location
        guard let avURL = URL(string: av.controlURL, relativeTo: base)?.absoluteURL else { return nil }
        let rc = info.services.first(where: { $0.type.contains(":service:RenderingControl:") })

        let host = location.host ?? ""
        var d = CastDevice(id: "dlna:" + (info.udn.isEmpty ? location.absoluteString : info.udn),
                           name: info.friendlyName.isEmpty ? "TV (\(host))" : info.friendlyName,
                           kind: .dlna, host: host, port: location.port ?? 80)
        let model = [info.manufacturer, info.modelName].filter { !$0.isEmpty }.joined(separator: " ")
        d.model = model.isEmpty ? nil : model
        d.avTransportURL = avURL
        d.avTransportService = av.type
        if let rc, let rcURL = URL(string: rc.controlURL, relativeTo: base)?.absoluteURL {
            d.renderingControlURL = rcURL
            d.renderingControlService = rc.type
        }
        return d
    }

    // MARK: - SOAP

    private func soap(_ url: URL, _ service: String, _ action: String, _ args: [(String, String)]) async throws -> String {
        let argXML = args.map { "<\($0.0)>\(XMLText.escape($0.1))</\($0.0)>" }.joined()
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:\(action) xmlns:u="\(service)">\(argXML)</u:\(action)></s:Body></s:Envelope>
        """
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let text = String(decoding: data, as: UTF8.self)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if let desc = XMLText.value(of: "errorDescription", in: text) { throw CastError.receiver(desc) }
            throw CastError.http(http.statusCode)
        }
        return text
    }

    private static func didl(for media: CastMedia) -> String {
        let upnpClass = media.kind == .audio ? "object.item.audioItem.musicTrack" : "object.item.videoItem"
        let flags = media.kind == .hls ? "*" : "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"
        var art = ""
        if let poster = media.poster { art = "<upnp:albumArtURI>\(XMLText.escape(poster.absoluteString))</upnp:albumArtURI>" }
        return """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/"><item id="castpilot-1" parentID="0" restricted="1"><dc:title>\(XMLText.escape(media.title))</dc:title><upnp:class>\(upnpClass)</upnp:class>\(art)<res protocolInfo="http-get:*:\(media.mimeType):\(flags)">\(XMLText.escape(media.url.absoluteString))</res></item></DIDL-Lite>
        """
    }

    static func hms(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }

    static func seconds(_ hms: String?) -> Double {
        guard let hms, !hms.isEmpty, hms != "NOT_IMPLEMENTED" else { return 0 }
        var total = 0.0
        for part in hms.split(separator: ":") {
            total = total * 60 + (Double(part) ?? 0)
        }
        return total
    }
}
