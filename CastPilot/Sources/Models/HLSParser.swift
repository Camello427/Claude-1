import Foundation

/// Reads the list of qualities out of an HLS master playlist.
enum HLSParser {
    static func variants(in text: String, base: URL) -> [HLSVariant] {
        var result: [HLSVariant] = []
        var pending: [String: String]?
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            } else if let attrs = pending, !line.isEmpty, !line.hasPrefix("#") {
                pending = nil
                guard let url = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
                let bandwidth = Int(attrs["AVERAGE-BANDWIDTH"] ?? attrs["BANDWIDTH"] ?? "") ?? 0
                var width: Int?, height: Int?
                if let res = attrs["RESOLUTION"] {
                    let parts = res.lowercased().split(separator: "x")
                    if parts.count == 2 { width = Int(parts[0]); height = Int(parts[1]) }
                }
                if !result.contains(where: { $0.url == url }) {
                    result.append(HLSVariant(url: url, bandwidth: bandwidth, width: width, height: height))
                }
            }
        }
        return result.sorted { ($0.height ?? 0, $0.bandwidth) > ($1.height ?? 0, $1.bandwidth) }
    }

    /// Parses `KEY=VALUE,KEY="quoted, value"` attribute lists.
    static func attributes(_ s: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var inKey = true
        var inQuotes = false
        for ch in s {
            if inKey {
                if ch == "=" { inKey = false } else if ch != "," { key.append(ch) }
            } else if ch == "\"" {
                inQuotes.toggle()
            } else if ch == "," && !inQuotes {
                result[key.trimmingCharacters(in: .whitespaces).uppercased()] = value
                key = ""; value = ""; inKey = true
            } else {
                value.append(ch)
            }
        }
        if !key.isEmpty { result[key.trimmingCharacters(in: .whitespaces).uppercased()] = value }
        return result
    }

    /// True when every variant URL in the playlist can be matched (used to filter to one quality).
    static func matches(_ a: URL, _ b: URL) -> Bool {
        if a.absoluteString == b.absoluteString { return true }
        return a.path == b.path && a.query == b.query
    }
}
