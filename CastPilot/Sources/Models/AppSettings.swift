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
    }
}
