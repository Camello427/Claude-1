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

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var failures = 0

    init(controller: any CastSessionController, item: MediaItem, media: CastMedia) {
        self.device = controller.device
        self.controller = controller
        self.item = item
        self.media = media
    }

    var capabilities: CastCapabilities { controller.capabilities }
    var isConnected: Bool { status.state != .disconnected }

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
            if !isScrubbing {
                var merged = s
                if merged.volume == nil { merged.volume = status.volume }
                status = merged
            }
            if let message = s.message { lastError = message }
        } catch {
            failures += 1
            if failures >= 5 {
                status.state = .disconnected
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func togglePlayPause() {
        perform { [controller, status] in
            if status.state == .playing || status.state == .buffering {
                try await controller.pause()
            } else {
                try await controller.play()
            }
        }
        status.state = (status.state == .playing) ? .paused : .playing
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

    func stop() {
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
