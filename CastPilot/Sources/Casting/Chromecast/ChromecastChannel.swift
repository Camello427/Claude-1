import Foundation
import Network

/// Fires a continuation at most once, even if several network callbacks race.
final class OnceFlag {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// A TLS connection to a Chromecast on port 8009, framed as 4-byte length + CastMessage.
final class ChromecastChannel {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let closedFlag = OnceFlag()

    var onMessage: ((CastMessage) -> Void)?
    var onClose: ((Error?) -> Void)?

    convenience init(host: String, port: Int) {
        let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? 8009
        self.init(endpoint: .hostPort(host: NWEndpoint.Host(host), port: p))
    }

    init(endpoint: NWEndpoint) {
        let queue = DispatchQueue(label: "castpilot.chromecast")
        self.queue = queue
        let tls = NWProtocolTLS.Options()
        // Chromecasts use self-signed certificates.
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.connectionTimeout = 8
        connection = NWConnection(to: endpoint, using: NWParameters(tls: tls, tcp: tcp))
    }

    func start() async throws {
        let once = OnceFlag()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.claim() {
                        cont.resume()
                        self?.receiveHeader()
                    }
                case .failed(let error):
                    if once.claim() { cont.resume(throwing: error) } else { self?.finish(error) }
                case .waiting(let error):
                    if once.claim() {
                        cont.resume(throwing: error)
                        self?.connection.cancel()
                    }
                case .cancelled:
                    if once.claim() { cont.resume(throwing: CastError.notConnected) } else { self?.finish(nil) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ message: CastMessage) {
        let body = message.encoded()
        var frame = Data()
        let length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: length) { frame.append(contentsOf: $0) }
        frame.append(body)
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(error) }
        })
    }

    func close() {
        queue.async { [weak self] in self?.finish(nil) }
    }

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error { self.finish(error); return }
            guard let data, data.count == 4 else {
                self.finish(isComplete ? nil : CastError.badResponse)
                return
            }
            let length = data.reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length < 2_000_000 else { self.finish(CastError.badResponse); return }
            self.receiveBody(length)
        }
    }

    private func receiveBody(_ length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error { self.finish(error); return }
            guard let data, data.count == length else { self.finish(CastError.badResponse); return }
            if let msg = CastMessage.decode(data) { self.onMessage?(msg) }
            self.receiveHeader()
        }
    }

    private func finish(_ error: Error?) {
        guard closedFlag.claim() else { return }
        connection.cancel()
        onClose?(error)
    }
}
