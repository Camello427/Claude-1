import Foundation
import Observation

enum SearchEngine: String, CaseIterable, Identifiable {
    case google, duckDuckGo, bing
    var id: String { rawValue }

    var name: String {
        switch self {
        case .google: return "Google"
        case .duckDuckGo: return "DuckDuckGo"
        case .bing: return "Bing"
        }
    }

    func searchURL(for query: String) -> URL? {
        var c: URLComponents
        switch self {
        case .google: c = URLComponents(string: "https://www.google.com/search")!
        case .duckDuckGo: c = URLComponents(string: "https://duckduckgo.com/")!
        case .bing: c = URLComponents(string: "https://www.bing.com/search")!
        }
        c.queryItems = [URLQueryItem(name: "q", value: query)]
        return c.url
    }
}

/// How the browser introduces itself to websites. Some sites only offer a good video player
/// (or any video at all) to certain browsers.
enum BrowserIdentity: String, CaseIterable, Identifiable {
    case iPhone, iPad, mac, android, windows
    var id: String { rawValue }

    var name: String {
        switch self {
        case .iPhone: return "iPhone Safari (default)"
        case .iPad: return "iPad Safari"
        case .mac: return "Mac Safari"
        case .android: return "Android Chrome"
        case .windows: return "Windows Chrome"
        }
    }

    var userAgent: String? {
        switch self {
        case .iPhone: return nil
        case .iPad: return "Mozilla/5.0 (iPad; CPU OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
        case .mac: return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
        case .android: return "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36"
        case .windows: return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
        }
    }

    var isDesktop: Bool { self == .mac || self == .windows }
}

/// When to pass video through the phone ("relay") instead of letting the TV fetch it directly.
enum RelayMode: String, CaseIterable, Identifiable {
    case auto, always, never
    var id: String { rawValue }

    var name: String {
        switch self {
        case .auto: return "Automatic"
        case .always: return "Always"
        case .never: return "Never"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "Streams (HLS) go through your iPhone so the TV gets the right headers. Plain video files go straight to the TV."
        case .always: return "Everything goes through your iPhone. Helps with sites that block TVs, but keep the app open."
        case .never: return "The TV always fetches the video itself."
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    var searchEngine: SearchEngine { didSet { defaults.set(searchEngine.rawValue, forKey: "searchEngine") } }
    var homePage: String { didSet { defaults.set(homePage, forKey: "homePage") } }
    var adBlockEnabled: Bool { didSet { defaults.set(adBlockEnabled, forKey: "adBlockEnabled") } }
    var blockPopups: Bool { didSet { defaults.set(blockPopups, forKey: "blockPopups") } }
    var desktopMode: Bool { didSet { defaults.set(desktopMode, forKey: "desktopMode") } }
    var relayMode: RelayMode { didSet { defaults.set(relayMode.rawValue, forKey: "relayMode") } }
    var keepAliveInBackground: Bool { didSet { defaults.set(keepAliveInBackground, forKey: "keepAliveInBackground") } }
    var browserIdentity: BrowserIdentity { didSet { defaults.set(browserIdentity.rawValue, forKey: "browserIdentity") } }
    var hideShortClips: Bool { didSet { defaults.set(hideShortClips, forKey: "hideShortClips") } }
    var autoCast: Bool { didSet { defaults.set(autoCast, forKey: "autoCast") } }
    var resumePlayback: Bool { didSet { defaults.set(resumePlayback, forKey: "resumePlayback") } }
    var autoAdvanceQueue: Bool { didSet { defaults.set(autoAdvanceQueue, forKey: "autoAdvanceQueue") } }
    var lockScreenControls: Bool { didSet { defaults.set(lockScreenControls, forKey: "lockScreenControls") } }
    var requireFaceID: Bool { didSet { defaults.set(requireFaceID, forKey: "requireFaceID") } }
    /// Sites (e.g. "example.com") the user lets open pop-ups and redirect.
    var popupAllowedSites: [String] { didSet { defaults.set(popupAllowedSites, forKey: "popupAllowedSites") } }

    func popupsAllowed(on url: URL?) -> Bool {
        guard let site = SiteKey.site(for: url) else { return false }
        return popupAllowedSites.contains(site)
    }

    func setPopupsAllowed(_ allowed: Bool, on url: URL?) {
        guard let site = SiteKey.site(for: url) else { return }
        if allowed {
            if !popupAllowedSites.contains(site) { popupAllowedSites.append(site) }
        } else {
            popupAllowedSites.removeAll { $0 == site }
        }
    }

    /// Videos shorter than this are treated as ads when "hide short clips" is on.
    let shortClipSeconds: Double = 30

    var effectiveDesktopMode: Bool { desktopMode || browserIdentity.isDesktop }

    private let defaults = UserDefaults.standard

    init() {
        let d = UserDefaults.standard
        searchEngine = SearchEngine(rawValue: d.string(forKey: "searchEngine") ?? "") ?? .google
        homePage = d.string(forKey: "homePage") ?? ""
        adBlockEnabled = d.object(forKey: "adBlockEnabled") as? Bool ?? true
        blockPopups = d.object(forKey: "blockPopups") as? Bool ?? true
        desktopMode = d.object(forKey: "desktopMode") as? Bool ?? false
        relayMode = RelayMode(rawValue: d.string(forKey: "relayMode") ?? "") ?? .auto
        keepAliveInBackground = d.object(forKey: "keepAliveInBackground") as? Bool ?? true
        browserIdentity = BrowserIdentity(rawValue: d.string(forKey: "browserIdentity") ?? "") ?? .iPhone
        hideShortClips = d.object(forKey: "hideShortClips") as? Bool ?? true
        autoCast = d.object(forKey: "autoCast") as? Bool ?? false
        resumePlayback = d.object(forKey: "resumePlayback") as? Bool ?? true
        autoAdvanceQueue = d.object(forKey: "autoAdvanceQueue") as? Bool ?? true
        lockScreenControls = d.object(forKey: "lockScreenControls") as? Bool ?? true
        requireFaceID = d.object(forKey: "requireFaceID") as? Bool ?? false
        popupAllowedSites = d.stringArray(forKey: "popupAllowedSites") ?? []
    }
}
