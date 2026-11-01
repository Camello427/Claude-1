import Foundation
import UniformTypeIdentifiers

/// What kind of media a URL points to. Decides the MIME type we tell the TV and whether the relay is used.
enum MediaKind: String, Codable, Hashable {
    case hls, dash, mp4, webm, mov, mkv, audio, unknown

    static func detect(url: URL, mime: String?) -> MediaKind {
        switch url.pathExtension.lowercased() {
        case "m3u8", "m3u": return .hls
        case "mpd": return .dash
        case "mp4", "m4v": return .mp4
        case "webm": return .webm
        case "mov": return .mov
        case "mkv": return .mkv
        case "mp3", "m4a", "aac", "ogg", "oga", "wav", "flac", "opus": return .audio
        default: break
        }
        let type = (mime ?? "").lowercased()
        if type.contains("mpegurl") { return .hls }
        if type.contains("dash+xml") { return .dash }
        if type.contains("webm") { return .webm }
        if type.contains("quicktime") { return .mov }
        if type.contains("matroska") { return .mkv }
        if type.hasPrefix("audio/") { return .audio }
        if type.hasPrefix("video/") { return .mp4 }
        let s = url.absoluteString.lowercased()
        if s.contains(".m3u8") { return .hls }
        if s.contains(".mpd") { return .dash }
        if s.contains(".mp4") { return .mp4 }
        return .unknown
    }

    var mimeType: String {
        switch self {
        case .hls: return "application/vnd.apple.mpegurl"
        case .dash: return "application/dash+xml"
        case .mp4, .unknown: return "video/mp4"
        case .webm: return "video/webm"
        case .mov: return "video/quicktime"
        case .mkv: return "video/x-matroska"
        case .audio: return "audio/mpeg"
        }
    }

    var label: String {
        switch self {
        case .hls: return "Stream (HLS)"
        case .dash: return "Stream (DASH)"
        case .mp4: return "MP4 video"
        case .webm: return "WebM video"
        case .mov: return "QuickTime video"
        case .mkv: return "MKV video"
        case .audio: return "Audio"
        case .unknown: return "Video"
        }
    }

    var symbol: String {
        switch self {
        case .hls, .dash: return "dot.radiowaves.left.and.right"
        case .audio: return "music.note"
        default: return "film"
        }
    }

    var isStream: Bool { self == .hls || self == .dash }

    static func mimeType(forFile url: URL) -> String {
        let kind = detect(url: url, mime: nil)
        if kind == .audio, let t = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType { return t }
        if kind != .unknown { return kind.mimeType }
        return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}

/// A video found on a web page, or a file the user imported from Photos/Files.
struct MediaItem: Identifiable, Hashable {
    enum Source: Hashable {
        case web(page: URL?, frame: URL?)
        case local
    }

    var id: String { url.absoluteString }
    var url: URL
    var title: String
    var kind: MediaKind
    var source: Source
    var poster: URL?
    var foundBy: String = ""
    var detectedAt = Date()
    /// Length in seconds, when the page reported it.
    var duration: Double?
    /// A specific quality picked from an HLS master playlist (nil = automatic).
    var variant: HLSVariant?
    /// Subtitles to show with the video.
    var subtitle: SubtitleTrack?

    var isDownloadable: Bool { !isLocal && !kind.isStream }

    var isLocal: Bool {
        if case .local = source { return true }
        return false
    }

    /// The page (or embedded frame) the video came from: sent as the Referer when relaying.
    var referer: URL? {
        if case let .web(page, frame) = source { return frame ?? page }
        return nil
    }

    var displayHost: String {
        if isLocal { return "On this iPhone" }
        return url.host ?? url.absoluteString
    }
}

/// Media in the exact form a TV will fetch it.
struct CastMedia {
    var url: URL
    var title: String
    var kind: MediaKind
    var mimeType: String
    var poster: URL?
    var isLive: Bool = false
    var viaRelay: Bool = false
    /// WebVTT and SRT copies of the chosen subtitles, served by the iPhone relay.
    var subtitleVTT: URL?
    var subtitleSRT: URL?
    var subtitleLabel: String?
    var subtitleLanguage: String?
}

/// Something to play on the phone itself (and from there, over AirPlay).
struct PhonePlayback: Identifiable {
    let id = UUID()
    var url: URL
    var title: String
    var headers: [String: String] = [:]
    var cookies: [HTTPCookie] = []
    /// Caps quality when the user picked a specific HLS variant.
    var peakBitRate: Double = 0
}

/// One subtitle file, found on a page or imported from Files.
struct SubtitleTrack: Hashable, Codable, Identifiable {
    var id: String { url.absoluteString }
    var url: URL
    var label: String
    var language: String?

    var isLocal: Bool { url.isFileURL }
}

/// One quality level in an HLS master playlist.
struct HLSVariant: Hashable, Identifiable {
    var id: String { url.absoluteString }
    var url: URL
    var bandwidth: Int
    var width: Int?
    var height: Int?

    var label: String {
        let rate = bandwidth > 0 ? String(format: "%.1f Mbps", Double(bandwidth) / 1_000_000) : ""
        guard let height else { return rate.isEmpty ? "Unknown quality" : rate }
        let name: String
        switch height {
        case 2000...: name = "4K"
        case 1400...: name = "1440p"
        default: name = "\(height)p"
        }
        return rate.isEmpty ? name : "\(name) · \(rate)"
    }
}
