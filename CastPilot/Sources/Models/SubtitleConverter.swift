import Foundation

/// Converts between SRT and WebVTT. Chromecast needs WebVTT; many smart TVs want SRT.
enum SubtitleConverter {
    static func decode(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    static func normalize(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
        return t
    }

    static func isVTT(_ text: String) -> Bool {
        normalize(text).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("WEBVTT")
    }

    static func toVTT(_ text: String) -> String {
        let t = normalize(text)
        if isVTT(t) { return t }
        let lines = t.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let s = String(line)
            return s.contains("-->") ? s.replacingOccurrences(of: ",", with: ".") : s
        }
        return "WEBVTT\n\n" + lines.joined(separator: "\n")
    }

    static func toSRT(_ text: String) -> String {
        let t = normalize(text)
        guard isVTT(t) else { return t }
        var cues: [String] = []
        for block in t.components(separatedBy: "\n\n") {
            var lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            lines.removeFirst(timingIndex)   // drop cue ids / headers
            let parts = lines[0].components(separatedBy: "-->")
            guard parts.count == 2 else { continue }
            let start = srtTime(parts[0])
            let end = srtTime(String(parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? ""))
            let body = lines.dropFirst().map { $0.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) }
            cues.append("\(cues.count + 1)\n\(start) --> \(end)\n" + body.joined(separator: "\n"))
        }
        return cues.joined(separator: "\n\n") + "\n"
    }

    private static func srtTime(_ vtt: String) -> String {
        var t = vtt.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: ",")
        if t.split(separator: ":").count == 2 { t = "00:" + t }
        return t
    }
}
