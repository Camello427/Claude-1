import Foundation
import Observation

/// The video currently playing on a TV, plus the remote-control actions for it.
@MainActor
@Observable
final class CastSession {
    let device: CastDevice
    let controller: any CastSessionController
    var item: MediaItem
    var media: CastMedia
    var status = PlaybackStatus()
    var lastError: String?
    var isScrubbing = false
    var isBusy = false
    var subtitlesOn: Bool
    /// Set when playback picked up from a saved position, so the remote can offer "Start over".
    var resumedFrom: Double?

    /// Called after every status update (lock screen, history, sleep timer).
    @ObservationIgnored var onStatus: ((CastSession) -> Void)?
    /// Called once when the video plays to the end by itself.
    @ObservationIgnored var onFinished: ((CastSession) -> Void)?

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var userStopped = false
    @ObservationIgnored private var finishReported = false
    @ObservationIgnored private var lastActivePosition: Double = 0

    init(controller: any CastSessionController, item: MediaItem, media: CastMedia) {
        self.device = controller.device
        self.controller = controller
        self.item = item
        self.media = media
        self.subtitlesOn = media.subtitleVTT != nil
    }

    var capabilities: CastCapabilities { controller.capabilities }
    var isConnected: Bool { status.state != .disconnected }
    var isActive: Bool { status.state == .playing || status.state == .buffering || status.state == .loading }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func refresh() async {
        do {
            let s = try await controller.status()
            failures = 0
            let previous = status
            if !isScrubbing {
                var merged = s
                if merged.volume == nil { merged.volume = status.volume }
                status = merged
            }
            if let message = s.message { lastError = message }
            if s.state == .playing || s.state == .paused { lastActivePosition = s.position }
            detectFinish(previous: previous, now: s)
            onStatus?(self)
        } catch {
            failures += 1
            if failures >= 5 {
                status.state = .disconnected
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func detectFinish(previous: PlaybackStatus, now: PlaybackStatus) {
        guard !finishReported, !userStopped else { return }
        let wasActive = previous.state == .playing || previous.state == .buffering || previous.state == .paused
        let ended = now.state == .idle || now.state == .stopped
        let duration = max(now.duration, previous.duration)
        let nearEnd = duration > 0 && lastActivePosition >= duration - 15
        if now.finished || (wasActive && ended && nearEnd) {
            finishReported = true
            onFinished?(self)
        }
    }

    func play() {
        status.state = .playing
        perform { [controller] in try await controller.play() }
    }

    func pause() {
        status.state = .paused
        perform { [controller] in try await controller.pause() }
    }

    func togglePlayPause() {
        if status.state == .playing || status.state == .buffering { pause() } else { play() }
    }

    func seek(to seconds: Double) {
        status.position = seconds
        perform { [controller] in try await controller.seek(to: seconds) }
    }

    func skip(by delta: Double) {
        var target = status.position + delta
        if status.duration > 0 { target = min(target, status.duration - 1) }
        seek(to: max(0, target))
    }

    func setVolume(_ level: Double) {
        status.volume = level
        perform { [controller] in try await controller.setVolume(level) }
    }

    func setRate(_ rate: Double) {
        status.rate = rate
        perform { [controller] in try await controller.setRate(rate) }
    }

    func setSubtitles(_ on: Bool) {
        subtitlesOn = on
        perform { [controller] in try await controller.setSubtitlesEnabled(on) }
    }

    func stop() {
        userStopped = true
        perform { [controller] in try await controller.stop() }
        status.state = .stopped
    }

    func end() {
        stopPolling()
        controller.disconnect()
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                try await action()
                lastError = nil
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
