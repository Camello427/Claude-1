import SwiftUI
import AVKit

/// Plays a video on the phone. The AirPlay button in the player sends it to an Apple TV or
/// AirPlay TV.
struct PhonePlayerScreen: View {
    let playback: PhonePlayback
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            PhonePlayerView(playback: playback)
                .ignoresSafeArea()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(.leading, 16)
            .padding(.top, 8)
            .accessibilityLabel("Close player")
        }
    }
}

struct PhonePlayerView: UIViewControllerRepresentable {
    let playback: PhonePlayback

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        var options: [String: Any] = [:]
        if !playback.headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = playback.headers }
        if !playback.cookies.isEmpty { options[AVURLAssetHTTPCookiesKey] = playback.cookies }
        let asset = AVURLAsset(url: playback.url, options: options)
        let item = AVPlayerItem(asset: asset)
        if playback.peakBitRate > 0 { item.preferredPeakBitRate = playback.peakBitRate }
        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = playback.title as NSString
        item.externalMetadata = [title]

        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true

        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        player.play()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player?.pause()
        controller.player = nil
    }
}
