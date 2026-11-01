import Foundation
import Darwin

/// A reply to an SSDP "M-SEARCH" — how DLNA TVs and Rokus announce themselves.
struct SSDPResponse: Hashable {
    let location: URL
    let searchTarget: String
    let usn: String
    let server: String
    let fromIP: String
}

enum SSDPTargets {
    static let avTransport = "urn:schemas-upnp-org:service:AVTransport:1"
    static let mediaRenderer = "urn:schemas-upnp-org:device:MediaRenderer:1"
    static let roku = "roku:ecp"
    static let all = [avTransport, mediaRenderer, roku]
}

/// Finds UPnP/DLNA devices and Rokus.
///
/// Sends the usual multicast search, and also asks every address on the local /24 network
/// directly (unicast). iOS only allows multicast for apps Apple has granted the multicast
/// entitlement, so the unicast sweep is what makes discovery work for a self-built app.
enum SSDPSearcher {
    static func search(targets: [String], unicastHosts: [String], timeout: TimeInterval = 3) async -> [SSDPResponse] {
        await Task.detached(priority: .userInitiated) {
            run(targets: targets, unicastHosts: unicastHosts, timeout: timeout)
        }.value
    }

    private static func run(targets: [String], unicastHosts: [String], timeout: TimeInterval) -> [SSDPResponse] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var rcvBuf: Int32 = 512 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvBuf, socklen_t(MemoryLayout<Int32>.size))
        var ttl: UInt8 = 4
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = 0
        local.sin_addr.s_addr = in_addr_t(0)
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return [] }

        // Multicast (works if the app has the entitlement; harmless otherwise).
        for target in targets {
            let msg = message(host: "239.255.255.250:1900", target: target, mx: true)
            send(fd, msg, to: "239.255.255.250")
            send(fd, msg, to: "239.255.255.250")
        }
        // Unicast sweep of the local network.
        for host in unicastHosts {
            for target in targets {
                send(fd, message(host: "\(host):1900", target: target, mx: false), to: host)
            }
            usleep(1_500)
        }

        var results: [SSDPResponse] = []
        var seen = Set<String>()
        var buffer = [UInt8](repeating: 0, count: 8192)
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32(remaining * 1000))
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { break }

            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buffer.withUnsafeMutableBytes { buf in
                withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, buf.baseAddress, buf.count, 0, $0, &fromLen)
                    }
                }
            }
            guard n > 0 else { continue }

            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var addr = from.sin_addr
            inet_ntop(AF_INET, &addr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: ipBuf)

            let text = String(decoding: buffer[0..<n], as: UTF8.self)
            if let r = parse(text, fromIP: ip) {
                let key = r.location.absoluteString + "|" + r.searchTarget
                if seen.insert(key).inserted { results.append(r) }
            }
        }
        return results
    }

    private static func message(host: String, target: String, mx: Bool) -> String {
        var lines = [
            "M-SEARCH * HTTP/1.1",
            "HOST: \(host)",
            "MAN: \"ssdp:discover\"",
            "ST: \(target)",
            "USER-AGENT: iOS/17 UPnP/1.1 CastPilot/1.0",
        ]
        if mx { lines.append("MX: 2") }
        return lines.joined(separator: "\r\n") + "\r\n\r\n"
    }

    private static func send(_ fd: Int32, _ message: String, to ip: String) {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(1900).bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return }
        let bytes = Array(message.utf8)
        _ = bytes.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    static func parse(_ text: String, fromIP: String) -> SSDPResponse? {
        let lines = text.split(whereSeparator: { $0 == "\r\n" || $0 == "\n" || $0 == "\r" }).map(String.init)
        guard let first = lines.first, first.uppercased().hasPrefix("HTTP/"), first.contains(" 200") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        guard let loc = headers["LOCATION"], let url = URL(string: loc), url.host != nil else { return nil }
        return SSDPResponse(location: url,
                            searchTarget: headers["ST"] ?? "",
                            usn: headers["USN"] ?? "",
                            server: headers["SERVER"] ?? "",
                            fromIP: fromIP)
    }
}
