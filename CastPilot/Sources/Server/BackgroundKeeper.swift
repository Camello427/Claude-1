import AVFoundation

/// Keeps the app running while the screen is locked or another app is open, so the relay can
/// keep feeding the TV. It plays silence through the audio session.
///
/// With `mixWithOthers: false` the app also becomes the "now playing" app, which is what makes
/// the TV controls appear on the lock screen and in Control Center.
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var mixing = true

    var isRunning: Bool { engine != nil }

    func start(mixWithOthers: Bool = true) {
        if engine != nil, mixing == mixWithOthers { return }
        if engine != nil { stop() }
        mixing = mixWithOthers
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: mixWithOthers ? [.mixWithOthers] : [])
            try session.setActive(true)

            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else { return }
            buffer.frameLength = buffer.frameCapacity
            if let channels = buffer.floatChannelData {
                for c in 0..<Int(format.channelCount) {
                    memset(channels[c], 0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
                }
            }
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            self.engine = engine
            self.player = player
        } catch {
            stop()
        }
    }

    func stop() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
