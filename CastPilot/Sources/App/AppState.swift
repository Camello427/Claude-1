import Foundation
import Observation
import SwiftUI

enum AppSheet: String, Identifiable {
    case media, devices, remote, library, settings, localFiles
    var id: String { rawValue }
}

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

@MainActor
@Observable
final class AppState {
    let settings: AppSettings
    let library: Library
    let devices: DeviceManager
    let localMedia: LocalMediaLibrary
    let browser: BrowserModel

    var session: CastSession?
    var sheet: AppSheet?
    var phonePlayback: PhonePlayback?
    var alert: AppAlert?
    var pendingItem: MediaItem?
    var isStartingCast = false
    var castingStatusText = ""

    private let server = LocalMediaServer.shared

    init() {
        let settings = AppSettings()
        let library = Library()
        self.settings = settings
        self.library = library
        self.devices = DeviceManager()
        self.localMedia = LocalMediaLibrary()
        self.browser = BrowserModel(settings: settings, library: library)
    }

    // MARK: Casting

    /// Cast to the chosen device, or ask which device to use first.
    func cast(_ item: MediaItem) {
        guard let device = devices.selectedDevice else {
            pendingItem = item
            sheet = .devices
            Task { await devices.scan() }
            return
        }
        Task { await startCast(item, on: device, forceRelay: false) }
    }

    /// Called from the device picker.
    func choose(_ device: CastDevice) {
        devices.selectedDeviceID = device.id
        if let item = pendingItem {
            pendingItem = nil
            Task { await startCast(item, on: device, forceRelay: false) }
        } else if let current = session, current.device.id != device.id {
            // Move what's playing to the new device.
            let item = current.item
            let resumeAt = current.status.position
            Task { await startCast(item, on: device, forceRelay: current.media.viaRelay, startAt: resumeAt) }
        } else {
            sheet = nil
        }
    }

    func retryThroughRelay() {
        guard let current = session else { return }
        Task { await startCast(current.item, on: current.device, forceRelay: true, startAt: current.status.position) }
    }

    func startCast(_ item: MediaItem, on device: CastDevice, forceRelay: Bool, startAt: Double = 0) async {
        isStartingCast = true
        castingStatusText = "Connecting to \(device.name)…"
        sheet = .remote
        defer { isStartingCast = false }

        do {
            let media = try await prepare(item, for: device, forceRelay: forceRelay)

            let controller: any CastSessionController
            if let existing = session, existing.device.id == device.id, existing.isConnected {
                existing.stopPolling()
                controller = existing.controller
            } else {
                session?.end()
                session = nil
                controller = try await makeController(for: device)
            }

            let newSession = CastSession(controller: controller, item: item, media: media)
            newSession.status.state = .loading
            session = newSession
            castingStatusText = "Sending video to \(device.name)…"
            try await controller.load(media, startAt: startAt)
            newSession.startPolling()

            if (media.viaRelay || item.isLocal) && settings.keepAliveInBackground {
                BackgroundKeeper.shared.start()
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if let session {
                session.lastError = message
                session.startPolling()
            } else {
                sheet = nil
                alert = AppAlert(title: "Couldn't cast to \(device.name)", message: message)
            }
        }
    }

    func endSession() {
        session?.end()
        session = nil
        BackgroundKeeper.shared.stop()
        if sheet == .remote { sheet = nil }
    }

    func stopAndEndSession() {
        guard let session else { return }
        let controller = session.controller
        Task {
            try? await controller.stop()
            endSession()
        }
    }

    private func makeController(for device: CastDevice) async throws -> any CastSessionController {
        let controller: any CastSessionController
        switch device.kind {
        case .chromecast: controller = ChromecastController(device: device)
        case .dlna: controller = try DLNAController(device: device)
        case .roku: controller = RokuController(device: device)
        }
        try await controller.connect()
        return controller
    }

    private func shouldRelay(_ item: MediaItem) -> Bool {
        if item.kind == .dash { return false }   // DASH manifests aren't rewritten; send them straight.
        switch settings.relayMode {
        case .always: return true
        case .never: return false
        case .auto: return item.kind == .hls
        }
    }

    private func prepare(_ item: MediaItem, for device: CastDevice, forceRelay: Bool) async throws -> CastMedia {
        var media = CastMedia(url: item.url, title: item.title, kind: item.kind,
                              mimeType: item.isLocal ? MediaKind.mimeType(forFile: item.url) : item.kind.mimeType,
                              poster: item.poster)

        if item.isLocal {
            let base = try await server.ensureRunning()
            let id = server.registerFile(item.url)
            media.url = server.fileURL(base: base, id: id, file: item.url)
            media.viaRelay = true
            return media
        }

        if forceRelay || shouldRelay(item) {
            let base = try await server.ensureRunning()
            let userAgent = await browser.userAgent()
            let cookies = await browser.cookies()
            let profile = HeaderProfile(referer: item.referer?.absoluteString, userAgent: userAgent, cookies: cookies)
            let profileID = server.register(profile)
            let name: String? = (item.kind == .hls && item.url.pathExtension.lowercased() != "m3u8") ? "index.m3u8" : nil
            media.url = server.relayURL(base: base, upstream: item.url, profileID: profileID, fileName: name)
            media.viaRelay = true
        }
        return media
    }

    // MARK: Playing on the phone (and AirPlay)

    func playOnPhone(_ item: MediaItem) {
        if item.isLocal {
            phonePlayback = PhonePlayback(url: item.url, title: item.title)
            return
        }
        Task {
            let userAgent = await browser.userAgent()
            var headers: [String: String] = ["User-Agent": userAgent]
            if let referer = item.referer { headers["Referer"] = referer.absoluteString }
            let cookies = await browser.cookies().filter { $0.applies(to: item.url) }
            sheet = nil
            phonePlayback = PhonePlayback(url: item.url, title: item.title, headers: headers, cookies: cookies)
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        if phase == .active {
            devices.startBrowsing()
        }
    }
}
