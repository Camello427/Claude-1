import Foundation
import MediaPlayer
import UIKit

/// Shows what's on the TV on the lock screen and in Control Center, and turns those buttons
/// into TV remote buttons.
@MainActor
final class NowPlayingController {
    static let shared = NowPlayingController()

    weak var app: AppState?
    private var configured = false
    private var artworkURL: URL?
    private var artwork: MPMediaItemArtwork?

    func configureCommands() {
        guard !configured else { return }
        configured = true
        let center = MPRemoteCommandCenter.shared()

        _ = center.playCommand.addTarget(handler: handler { $0.play() })
        _ = center.pauseCommand.addTarget(handler: handler { $0.pause() })
        _ = center.togglePlayPauseCommand.addTarget(handler: handler { $0.togglePlayPause() })
        _ = center.stopCommand.addTarget(handler: handler { _ in self.app?.stopAndEndSession() })

        center.skipForwardCommand.preferredIntervals = [30]
        _ = center.skipForwardCommand.addTarget(handler: handler { $0.skip(by: 30) })
        center.skipBackwardCommand.preferredIntervals = [10]
        _ = center.skipBackwardCommand.addTarget(handler: handler { $0.skip(by: -10) })
        _ = center.nextTrackCommand.addTarget(handler: handler { _ in self.app?.playNextInQueue() })

        _ = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = event.positionTime
            Task { @MainActor in self?.app?.session?.seek(to: time) }
            return .success
        }
        update(nil)
    }

    private func handler(_ action: @escaping @MainActor (CastSession) -> Void) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        return { [weak self] _ in
            Task { @MainActor in
                if let session = self?.app?.session { action(session) }
            }
            return .success
        }
    }

    func update(_ session: CastSession?) {
        let center = MPRemoteCommandCenter.shared()
        guard let session, app?.settings.lockScreenControls == true else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.stopCommand,
             center.skipForwardCommand, center.skipBackwardCommand, center.nextTrackCommand,
             center.changePlaybackPositionCommand].forEach { $0.isEnabled = false }
            return
        }
        let seek = session.capabilities.seek
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.stopCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = seek
        center.skipBackwardCommand.isEnabled = seek
        center.changePlaybackPositionCommand.isEnabled = seek
        center.nextTrackCommand.isEnabled = !(app?.queue.isEmpty ?? true)

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: session.item.title,
            MPMediaItemPropertyArtist: "On \(session.device.name)",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: session.status.position,
            MPNowPlayingInfoPropertyPlaybackRate: session.status.state == .playing ? session.status.rate : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if session.status.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = session.status.duration }
        if let poster = session.item.poster {
            if poster == artworkURL, let artwork {
                info[MPMediaItemPropertyArtwork] = artwork
            } else if poster != artworkURL {
                loadArtwork(poster)
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(_ url: URL) {
        artworkURL = url
        artwork = nil
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) else { return }
            guard artworkURL == url else { return }
            artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
    }
}
