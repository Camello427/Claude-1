import Foundation
import Network
import Observation

/// Finds TVs and keeps the list of devices up to date.
@MainActor
@Observable
final class DeviceManager {
    private(set) var devices: [CastDevice] = []
    private(set) var isScanning = false
    private(set) var lastScan: Date?

    var selectedDeviceID: String? {
        didSet { UserDefaults.standard.set(selectedDeviceID, forKey: "selectedDeviceID") }
    }

    var selectedDevice: CastDevice? {
        guard let selectedDeviceID else { return nil }
        return devices.first { $0.id == selectedDeviceID }
    }

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var chromecasts: [String: CastDevice] = [:]
    @ObservationIgnored private var ssdpDevices: [String: CastDevice] = [:]
    @ObservationIgnored private var manualDevices: [CastDevice] = []

    init() {
        selectedDeviceID = UserDefaults.standard.string(forKey: "selectedDeviceID")
        if let data = UserDefaults.standard.data(forKey: "manualDevices"),
           let saved = try? JSONDecoder().decode([CastDevice].self, from: data) {
            manualDevices = saved
        }
        rebuild()
    }

    // MARK: Chromecast (Bonjour)

    func startBrowsing() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.updateChromecasts(results) }
        }
        b.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { @MainActor in
                    self?.browser?.cancel()
                    self?.browser = nil
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    self?.startBrowsing()
                }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    private func updateChromecasts(_ results: Set<NWBrowser.Result>) {
        var found: [String: CastDevice] = [:]
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            var txt: [String: String] = [:]
            if case let .bonjour(record) = result.metadata { txt = record.dictionary }
            let id = "cc:" + (txt["id"] ?? name)
            var d = CastDevice(id: id, name: txt["fn"] ?? name, kind: .chromecast, host: "", port: 8009)
            d.model = txt["md"]
            d.bonjourEndpoint = result.endpoint
            found[id] = d
        }
        chromecasts = found
        rebuild()
    }

    // MARK: DLNA + Roku (SSDP)

    func scan() async {
        startBrowsing()
        guard !isScanning else { return }
        isScanning = true
        defer {
            isScanning = false
            lastScan = Date()
        }
        var hosts: [String] = []
        if let ip = NetworkUtils.wifiIPv4() { hosts = NetworkUtils.subnetHosts(around: ip) }
        let responses = await SSDPSearcher.search(targets: SSDPTargets.all, unicastHosts: hosts, timeout: 3)
        let found = await Self.resolve(responses)
        for d in found { ssdpDevices[d.id] = d }
        rebuild()
    }

    nonisolated static func resolve(_ responses: [SSDPResponse]) async -> [CastDevice] {
        var byLocation: [URL: SSDPResponse] = [:]
        for r in responses where byLocation[r.location] == nil || r.searchTarget == SSDPTargets.roku {
            byLocation[r.location] = r
        }
        return await withTaskGroup(of: CastDevice?.self) { group in
            for r in byLocation.values {
                group.addTask {
                    let isRoku = r.searchTarget == SSDPTargets.roku
                        || (r.location.port == 8060 && r.server.lowercased().contains("roku"))
                    if isRoku {
                        return await RokuController.describe(location: r.location)
                    }
                    return await DLNAController.describe(location: r.location)
                }
            }
            var out: [CastDevice] = []
            for await d in group { if let d { out.append(d) } }
            return out
        }
    }

    // MARK: Manual devices

    func addManual(kind: DeviceKind, address: String) async throws -> CastDevice {
        let ip = address.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "http://", with: "")
            .split(separator: "/").first.map(String.init) ?? ""
        guard !ip.isEmpty else { throw CastError.notFound }
        let hostOnly = ip.split(separator: ":").first.map(String.init) ?? ip

        var device: CastDevice
        switch kind {
        case .chromecast:
            device = CastDevice(id: "cc-manual:\(hostOnly)", name: "Chromecast at \(hostOnly)", kind: .chromecast, host: hostOnly, port: 8009)
            let probe = ChromecastController(device: device)
            try await probe.connect()
            probe.disconnect()
        case .roku:
            guard let url = URL(string: "http://\(hostOnly):8060/"),
                  let d = await RokuController.describe(location: url) else { throw CastError.notFound }
            device = d
        case .dlna:
            let responses = await SSDPSearcher.search(targets: SSDPTargets.all, unicastHosts: [hostOnly], timeout: 2)
            guard let d = await Self.resolve(responses).first(where: { $0.kind == .dlna }) else { throw CastError.notFound }
            device = d
        }
        device.isManual = true
        manualDevices.removeAll { $0.id == device.id }
        manualDevices.append(device)
        saveManual()
        rebuild()
        selectedDeviceID = device.id
        return device
    }

    func removeManual(_ device: CastDevice) {
        manualDevices.removeAll { $0.id == device.id }
        saveManual()
        rebuild()
    }

    private func saveManual() {
        UserDefaults.standard.set(try? JSONEncoder().encode(manualDevices), forKey: "manualDevices")
    }

    private func rebuild() {
        var merged: [String: CastDevice] = [:]
        for d in manualDevices { merged[d.id] = d }
        for d in ssdpDevices.values { merged[d.id] = d }
        for d in chromecasts.values { merged[d.id] = d }
        devices = merged.values.sorted {
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
