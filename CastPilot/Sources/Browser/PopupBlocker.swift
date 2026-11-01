import Foundation

/// Groups hosts into "sites", so links within one website (www.example.com and
/// video.example.com) aren't treated as pop-ups to somewhere else.
enum SiteKey {
    private static let secondLevel: Set<String> = ["co", "com", "net", "org", "gov", "ac", "edu", "ne", "or", "go"]

    static func site(forHost host: String) -> String {
        let lower = host.lowercased()
        if lower.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) { return lower }   // IP address
        var labels = lower.split(separator: ".").map(String.init)
        if labels.first == "www" { labels.removeFirst() }
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let tld = labels[labels.count - 1]
        let sld = labels[labels.count - 2]
        let take = (tld.count == 2 && secondLevel.contains(sld)) ? 3 : 2
        return labels.suffix(take).joined(separator: ".")
    }

    static func site(for url: URL?) -> String? {
        guard let host = url?.host, !host.isEmpty else { return nil }
        return site(forHost: host)
    }

    static func sameSite(_ a: URL?, _ b: URL?) -> Bool {
        guard let sa = site(for: a), let sb = site(for: b) else { return false }
        return sa == sb
    }
}

/// Something the browser stopped from opening.
struct BlockedPopup: Identifiable, Equatable {
    enum Kind { case popup, redirect }
    let id = UUID()
    var url: URL?
    var kind: Kind

    var siteName: String { SiteKey.site(for: url) ?? "a blank page" }

    var message: String {
        switch kind {
        case .popup: return "Blocked a pop-up from \(siteName)"
        case .redirect: return "Blocked a redirect to \(siteName)"
        }
    }
}
