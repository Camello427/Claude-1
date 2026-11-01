import Foundation
import Darwin

enum NetworkUtils {
    /// The phone's IPv4 address on Wi-Fi (interface en0), e.g. "192.168.1.23".
    static func wifiIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var fallback: String?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            let iface = entry.pointee
            cursor = iface.ifa_next
            guard let addr = iface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: iface.ifa_name)
            guard name == "en0" || name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if ip.hasPrefix("169.254.") { continue }
            if name == "en0" { return ip }
            if fallback == nil { fallback = ip }
        }
        return fallback
    }

    /// Every other address in the phone's /24 network (x.y.z.1 – x.y.z.254).
    static func subnetHosts(around ip: String) -> [String] {
        let parts = ip.split(separator: ".")
        guard parts.count == 4, let me = Int(parts[3]) else { return [] }
        let prefix = parts[0...2].joined(separator: ".")
        return (1...254).filter { $0 != me }.map { "\(prefix).\($0)" }
    }

    /// Percent-encodes everything except unreserved characters, so a whole URL can be a query value.
    static func strictEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func base64URLEncode(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ s: String) -> String? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let data = Data(base64Encoded: b) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Tiny helpers for pulling values out of XML replies without a full parser.
enum XMLText {
    static func value(of tag: String, in xml: String) -> String? {
        let pattern = "<(?:[A-Za-z0-9_]+:)?\(NSRegularExpression.escapedPattern(for: tag))(?:\\s[^>]*)?>(.*?)</(?:[A-Za-z0-9_]+:)?\(NSRegularExpression.escapedPattern(for: tag))>"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let ns = xml as NSString
        guard let m = re.firstMatch(in: xml, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        return unescape(ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func attribute(_ name: String, in xml: String) -> String? {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: name))=\"([^\"]*)\""
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = xml as NSString
        guard let m = re.firstMatch(in: xml, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

extension HTTPCookie {
    /// Whether this cookie would be sent with a request to `url`.
    func applies(to url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        var d = domain.lowercased()
        if d.hasPrefix(".") { d.removeFirst() }
        let domainOK = host == d || host.hasSuffix("." + d)
        let path = url.path.isEmpty ? "/" : url.path
        let pathOK = path.hasPrefix(self.path)
        let secureOK = !isSecure || url.scheme == "https"
        let fresh = expiresDate.map { $0 > Date() } ?? true
        return domainOK && pathOK && secureOK && fresh
    }
}

extension Double {
    /// 75 -> "1:15", 3725 -> "1:02:05"
    var clockString: String {
        guard isFinite, self >= 0 else { return "--:--" }
        let total = Int(self.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
