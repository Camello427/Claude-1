import Foundation
import Observation
import SwiftUI
import UIKit

enum AppSheet: String, Identifiable {
    case media, devices, remote, library, settings, localFiles, tabs, castLink
    var id: String { rawValue }
}

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

enum SleepTimerOption: Hashable {
    case minutes(Int)
    case endOfVideo
}

@MainActor
@Observable
final class AppState {
    let settings: AppSettings
    let library: Library
    let devices: DeviceManager
    let localMedia: LocalMediaLibrary
    let tabs: TabManager
    let queue: PlayQueue
    let history: CastHistory
    let downloads: DownloadManager
    let privacyLock: PrivacyLock

    var session: CastSession?
    var sheet: AppSheet?
    var phonePlayback: PhonePlayback?
    var alert: AppAlert?
    var pendingItem: MediaItem?
    var isStartingCast = false
    var castingStatusText = ""
    var sleepDeadline: Date?
    var sleepAtEndOfVideo = false

    @ObservationIgnored private let server = LocalMediaServer.shared
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    @ObservationIgnored private var autoCastTask: Task<Void, Never>?
    @ObservationIgnored private var autoCastToken: UUID?

    init() {
        let settings = AppSettings()
        let library = Library()
        self.settings = settings
        self.library = library
        self.devices = DeviceManager()
        self.localMedia = LocalMediaLibrary()
        self.tabs = TabManager(settings: settings, library: library)
        self.queue = PlayQueue()
        self.history = CastHistory()
        self.downloads = DownloadManager()
        self.privacyLock = PrivacyLock()

        tabs.onMediaDetected = { [weak self] tab, item in self?.mediaDetected(in: tab, item: item) }
        downloads.onFinished = { [weak self] in self?.localMedia.reload() }
        NowPlayingController.shared.app = self
        NowPlayingController.shared.configureCommands()
    }

    /// The tab on screen.
    var browser: BrowserModel { tabs.current }

    // MARK: - Casting

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

    func restartFromBeginning() {
        guard let current = session else { return }
        current.resumedFrom = nil
        current.seek(to: 0)
    }

    /// - Parameter startAt: where to start; nil means "resume if this was watched before".
    func startCast(_ item: MediaItem, on device: CastDevice, forceRelay: Bool, startAt: Double? = nil) async {
        isStartingCast = true
        castingStatusText = "Connecting to \(device.name)…"
        sheet = .remote
        defer { isStartingCast = false }

        var resumeAt = startAt ?? 0
        var resumed: Double?
        if startAt == nil, settings.resumePlayback, let saved = history.resumePosition(for: item.url) {
            resumeAt = saved
            resumed = saved
        }

        do {
            castingStatusText = "Getting the video ready…"
            let media = try await prepare(item, for: device, forceRelay: forceRelay)

            let controller: any CastSessionController
            if let existing = session, existing.device.id == device.id, existing.isConnected {
                existing.stopPolling()
                controller = existing.controller
            } else {
                session?.end()
                session = nil
                castingStatusText = "Connecting to \(device.name)…"
                controller = try await makeController(for: device)
            }

            let newSession = CastSession(controller: controller, item: item, media: media)
            newSession.status.state = .loading
            newSession.resumedFrom = resumed
            newSession.onStatus = { [weak self] s in self?.sessionUpdated(s) }
            newSession.onFinished = { [weak self] s in self?.sessionFinished(s) }
            session = newSession
            castingStatusText = "Sending video to \(device.name)…"
            try await controller.load(media, startAt: resumeAt)
            history.record(item, deviceName: device.name)
            newSession.startPolling()
            updateBackgroundKeeper()
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
        setSleepTimer(nil)
        server.setCaptionURL(nil)
        history.save()
        NowPlayingController.shared.update(nil)
        updateBackgroundKeeper()
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

    private func sessionUpdated(_ s: CastSession) {
        history.updateProgress(url: s.item.url, position: s.status.position, duration: s.status.duration)
        NowPlayingController.shared.update(s)
    }

    private func sessionFinished(_ s: CastSession) {
        if s.status.duration > 0 {
            history.updateProgress(url: s.item.url, position: s.status.duration, duration: s.status.duration)
        }
        if sleepAtEndOfVideo {
            sleepTimerFired()
            return
        }
        guard settings.autoAdvanceQueue else { return }
        if let next = queue.dequeueNext(after: s.item, finished: true) {
            let isRepeat = next.url == s.item.url
            Task { await startCast(next, on: s.device, forceRelay: false, startAt: isRepeat ? 0 : nil) }
        }
    }

    /// Skip to the next video in Up Next.
    func playNextInQueue() {
        guard let next = queue.dequeueNext(after: session?.item, finished: false) else { return }
        if let device = session?.device ?? devices.selectedDevice {
            Task { await startCast(next, on: device, forceRelay: false) }
        } else {
            cast(next)
        }
    }

    /// Plays one queued video right now.
    func playQueued(_ entry: QueueEntry) {
        queue.remove(entry)
        if let device = session?.device ?? devices.selectedDevice {
            Task { await startCast(entry.item, on: device, forceRelay: false) }
        } else {
            cast(entry.item)
        }
    }

    /// Adds to Up Next, or starts playing straight away if nothing is casting.
    func addToQueue(_ item: MediaItem, next: Bool = false) {
        if session == nil, devices.selectedDevice != nil {
            cast(item)
            return
        }
        if next { queue.playNext(item) } else { queue.add(item) }
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
        if item.variant != nil { return true }   // Picking a quality needs a trimmed playlist.
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
        } else if forceRelay || shouldRelay(item) {
            let base = try await server.ensureRunning()
            let userAgent = await browser.userAgent()
            let cookies = await browser.cookies()
            var profile = HeaderProfile(referer: item.referer?.absoluteString, userAgent: userAgent, cookies: cookies)
            profile.keepVariant = item.variant?.url
            let profileID = server.register(profile)
            let name: String? = (item.kind == .hls && item.url.pathExtension.lowercased() != "m3u8") ? "index.m3u8" : nil
            media.url = server.relayURL(base: base, upstream: item.url, profileID: profileID, fileName: name)
            media.viaRelay = true
        }

        server.setCaptionURL(nil)
        if let track = item.subtitle {
            do {
                let text = try await subtitleText(track, for: item)
                let base = try await server.ensureRunning()
                let id = server.registerSubtitle(vtt: SubtitleConverter.toVTT(text))
                let urls = server.subtitleURLs(base: base, id: id)
                media.subtitleVTT = urls.vtt
                media.subtitleSRT = urls.srt
                media.subtitleLabel = track.label
                media.subtitleLanguage = track.language
                server.setCaptionURL(urls.srt)
            } catch {
                // Still play the video; just without subtitles.
            }
        }
        return media
    }

    private func subtitleText(_ track: SubtitleTrack, for item: MediaItem) async throws -> String {
        let data: Data
        if track.isLocal {
            data = try Data(contentsOf: track.url)
        } else {
            data = try await browser.fetch(track.url, referer: item.referer).0
        }
        return SubtitleConverter.decode(data)
    }

    private func updateBackgroundKeeper() {
        guard let session else {
            BackgroundKeeper.shared.stop()
            return
        }
        if settings.lockScreenControls {
            BackgroundKeeper.shared.start(mixWithOthers: false)
        } else if (session.media.viaRelay || session.item.isLocal) && settings.keepAliveInBackground {
            BackgroundKeeper.shared.start(mixWithOthers: true)
        } else {
            BackgroundKeeper.shared.stop()
        }
    }

    // MARK: - Quality

    /// The qualities offered by an HLS stream (empty if it only has one).
    func loadVariants(for item: MediaItem) async -> [HLSVariant] {
        guard item.kind == .hls, !item.isLocal else { return [] }
        do {
            let (data, finalURL) = try await browser.fetch(item.url, referer: item.referer)
            return HLSParser.variants(in: String(decoding: data, as: UTF8.self), base: finalURL)
        } catch {
            return []
        }
    }

    // MARK: - Sleep timer

    func setSleepTimer(_ option: SleepTimerOption?) {
        sleepTask?.cancel()
        sleepTask = nil
        sleepDeadline = nil
        sleepAtEndOfVideo = false
        switch option {
        case .none:
            break
        case .endOfVideo:
            sleepAtEndOfVideo = true
        case .minutes(let minutes):
            let seconds = Double(minutes) * 60
            sleepDeadline = Date().addingTimeInterval(seconds)
            sleepTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.sleepTimerFired()
            }
        }
    }

    private func sleepTimerFired() {
        sleepDeadline = nil
        sleepAtEndOfVideo = false
        sleepTask = nil
        session?.stop()
    }

    // MARK: - Playing on the phone (and AirPlay)

    func playOnPhone(_ item: MediaItem) {
        if item.isLocal {
            sheet = nil
            phonePlayback = PhonePlayback(url: item.url, title: item.title)
            return
        }
        Task {
            let userAgent = await browser.userAgent()
            var headers: [String: String] = ["User-Agent": userAgent]
            if let referer = item.referer { headers["Referer"] = referer.absoluteString }
            let cookies = await browser.cookies().filter { $0.applies(to: item.url) }
            sheet = nil
            var playback = PhonePlayback(url: item.url, title: item.title, headers: headers, cookies: cookies)
            if let variant = item.variant { playback.peakBitRate = Double(variant.bandwidth) }
            phonePlayback = playback
        }
    }

    // MARK: - Downloads

    func download(_ item: MediaItem) {
        Task {
            let userAgent = await browser.userAgent()
            var headers: [String: String] = ["User-Agent": userAgent]
            if let referer = item.referer { headers["Referer"] = referer.absoluteString }
            let cookies = await browser.cookies()
            downloads.start(item, headers: headers, cookies: cookies)
        }
    }

    // MARK: - Auto-cast

    private func mediaDetected(in tab: BrowserModel, item: MediaItem) {
        guard settings.autoCast, tab.id == tabs.currentID, devices.selectedDevice != nil,
              autoCastToken != tab.pageToken else { return }
        let token = tab.pageToken
        autoCastTask?.cancel()
        // Wait a moment so the page can reveal its main video (and ad clips their length).
        autoCastTask = Task { [weak self, weak tab] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, let self, let tab, tab.pageToken == token, !self.isStartingCast else { return }
            if let s = self.session, s.isActive { return }
            guard let best = Self.bestCandidate(tab.visibleMedia) else { return }
            self.autoCastToken = token
            self.cast(best)
        }
    }

    static func bestCandidate(_ items: [MediaItem]) -> MediaItem? {
        if let hls = items.first(where: { $0.kind == .hls }) { return hls }
        let elements = items.filter { $0.foundBy == "element" && $0.kind != .audio }
        if let longest = elements.max(by: { ($0.duration ?? 0) < ($1.duration ?? 0) }) { return longest }
        return items.first { $0.kind != .audio }
    }

    // MARK: - Links from other apps

    /// Handles `castpilot://open?url=…`, `castpilot://cast?url=…&title=…` and `castpilot://queue?url=…`.
    func handleIncoming(_ url: URL) {
        if url.scheme == "http" || url.scheme == "https" {
            tabs.newTab(url: url)
            return
        }
        guard url.scheme?.lowercased() == "castpilot" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let target = items.first { $0.name == "url" }?.value.flatMap { URL(string: $0) }
        let title = items.first { $0.name == "title" }?.value
        sheet = nil

        switch url.host?.lowercased() {
        case "cast", "queue":
            guard let target else { return }
            let item = MediaItem(url: target, title: title ?? target.lastPathComponent,
                                 kind: MediaKind.detect(url: target, mime: nil), source: .web(page: nil, frame: nil))
            if url.host?.lowercased() == "queue" { addToQueue(item) } else { cast(item) }
        default:
            if let target { tabs.newTab(url: target) }
        }
    }

    // MARK: - Settings changes

    func applyIdentityToAllTabs() {
        tabs.forEachTab { $0.applyIdentity() }
    }

    func applyAdBlockToAllTabs() {
        tabs.forEachTab { $0.applyAdBlock() }
    }

    func reloadAllTabsForDesktopMode() {
        tabs.forEachTab { $0.reloadForDesktopModeChange() }
    }

    func lockScreenSettingChanged() {
        updateBackgroundKeeper()
        NowPlayingController.shared.update(session)
    }

    // MARK: - App lifecycle

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            devices.startBrowsing()
            privacyLock.appBecameActive(enabled: settings.requireFaceID)
        case .background:
            history.save()
            privacyLock.appEnteredBackground(enabled: settings.requireFaceID)
        default:
            break
        }
    }
}
