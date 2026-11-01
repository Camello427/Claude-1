import Foundation
import Network

enum DeviceKind: String, Codable, CaseIterable, Identifiable {
    case chromecast, dlna, roku
    var id: String { rawValue }

    var label: String {
        switch self {
        case .chromecast: return "Chromecast / Google TV"
        case .dlna: return "Smart TV (DLNA)"
        case .roku: return "Roku"
        }
    }

    var symbol: String {
        switch self {
        case .chromecast: return "tv.badge.wifi"
        case .dlna: return "tv"
        case .roku: return "appletvremote.gen1"
        }
    }
}

struct CastDevice: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var kind: DeviceKind
    var host: String
    var port: Int
    var model: String?
    var isManual = false

    // DLNA / UPnP
    var avTransportURL: URL?
    var avTransportService: String?
    var renderingControlURL: URL?
    var renderingControlService: String?

    // Chromecast found with Bonjour: connect straight to the service.
    var bonjourEndpoint: NWEndpoint? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, kind, host, port, model, isManual
        case avTransportURL, avTransportService, renderingControlURL, renderingControlService
    }

    var subtitle: String {
        var parts = [kind.label]
        if let model, !model.isEmpty { parts.append(model) }
        if !host.isEmpty { parts.append(host) }
        return parts.joined(separator: " · ")
    }
}

struct CastCapabilities {
    var seek: Bool
    var volume: Bool
    var speed: Bool = false
    var subtitleToggle: Bool = false
}

enum PlaybackState: Equatable {
    case unknown, idle, loading, buffering, playing, paused, stopped, disconnected

    var label: String {
        switch self {
        case .unknown: return "Connecting…"
        case .idle: return "Ready"
        case .loading: return "Loading…"
        case .buffering: return "Buffering…"
        case .playing: return "Playing"
        case .paused: return "Paused"
        case .stopped: return "Stopped"
        case .disconnected: return "Disconnected"
        }
    }
}

struct PlaybackStatus: Equatable {
    var state: PlaybackState = .unknown
    var position: Double = 0
    var duration: Double = 0
    var volume: Double?
    var message: String?
    var rate: Double = 1
    /// The TV reported the video played to the end on its own.
    var finished = false
}

enum CastError: LocalizedError {
    case notConnected
    case timeout
    case unsupported(String)
    case receiver(String)
    case http(Int)
    case noWiFi
    case badResponse
    case notFound

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Lost the connection to the TV."
        case .timeout: return "The TV didn't answer in time."
        case .unsupported(let what): return "This device doesn't support \(what)."
        case .receiver(let why): return "The TV reported an error: \(why)"
        case .http(let code): return "The TV answered with error \(code). It may not support this video format."
        case .noWiFi: return "Connect your iPhone to the same Wi-Fi network as your TV."
        case .badResponse: return "The TV sent a reply CastPilot couldn't understand."
        case .notFound: return "No compatible device answered at that address."
        }
    }
}

/// One way of talking to a TV. Each device type has its own implementation.
@MainActor
protocol CastSessionController: AnyObject {
    var device: CastDevice { get }
    var capabilities: CastCapabilities { get }
    func connect() async throws
    func load(_ media: CastMedia, startAt: Double) async throws
    func play() async throws
    func pause() async throws
    func seek(to seconds: Double) async throws
    func setVolume(_ level: Double) async throws
    func stop() async throws
    func status() async throws -> PlaybackStatus
    func disconnect()
    func setRate(_ rate: Double) async throws
    func setSubtitlesEnabled(_ enabled: Bool) async throws
}

extension CastSessionController {
    func setRate(_ rate: Double) async throws { throw CastError.unsupported("playback speed") }
    func setSubtitlesEnabled(_ enabled: Bool) async throws { throw CastError.unsupported("turning subtitles on and off") }
}
