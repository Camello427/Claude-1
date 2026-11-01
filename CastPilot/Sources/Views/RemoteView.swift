import SwiftUI
import UIKit

/// The remote control for whatever is playing on the TV.
struct RemoteView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let session = app.session {
                    RemoteControls(session: session)
                } else if app.isStartingCast {
                    VStack(spacing: 16) {
                        ProgressView().controlSize(.large)
                        Text(app.castingStatusText).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("Nothing is casting", systemImage: "tv")
                    } description: {
                        Text("Find a video on a website, then tap the blue “videos found” button.")
                    }
                }
            }
            .navigationTitle("Now casting")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { route in
                if route == "queue" { QueueView() }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if app.session != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button { app.sheet = .devices } label: {
                                Label("Move to another device", systemImage: "arrow.left.arrow.right")
                            }
                            Button(role: .destructive) { app.stopAndEndSession() } label: {
                                Label("Stop and disconnect", systemImage: "xmark.circle")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
        }
    }
}

struct RemoteControls: View {
    @Environment(AppState.self) private var app
    @Bindable var session: CastSession
    @State private var scrub: Double = 0
    @State private var volume: Double = 0.5

    private static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        let status = session.status
        let caps = session.capabilities
        ScrollView {
            VStack(spacing: 22) {
                artwork

                VStack(spacing: 6) {
                    Text(session.item.title)
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                    Label(session.device.name, systemImage: session.device.kind.symbol)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(app.isStartingCast ? app.castingStatusText : status.state.label)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(status.state == .playing ? Color.green : Color.secondary)
                }

                if let resumed = session.resumedFrom {
                    HStack {
                        Label("Resumed at \(resumed.clockString)", systemImage: "clock.arrow.circlepath")
                            .font(.footnote)
                        Spacer()
                        Button("Start over") { app.restartFromBeginning() }
                            .font(.footnote.weight(.semibold))
                    }
                    .padding(10)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }

                if caps.seek {
                    VStack(spacing: 4) {
                        Slider(value: $scrub, in: 0...max(status.duration, max(scrub, 1)), onEditingChanged: { editing in
                            session.isScrubbing = editing
                            if !editing { session.seek(to: scrub) }
                        })
                        .disabled(status.duration <= 0)
                        HStack {
                            Text(scrub.clockString)
                            Spacer()
                            Text(status.duration > 0 ? status.duration.clockString : "Live")
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                } else if status.duration > 0 {
                    ProgressView(value: min(status.position, status.duration), total: status.duration)
                }

                HStack(spacing: 26) {
                    if caps.seek {
                        controlButton("gobackward.30", "Back 30 seconds") { session.skip(by: -30) }
                        controlButton("gobackward.10", "Back 10 seconds") { session.skip(by: -10) }
                    }
                    Button { session.togglePlayPause() } label: {
                        Image(systemName: status.state == .playing || status.state == .buffering ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 64))
                            .symbolRenderingMode(.hierarchical)
                    }
                    .accessibilityLabel(status.state == .playing ? "Pause" : "Play")
                    if caps.seek {
                        controlButton("goforward.10", "Forward 10 seconds") { session.skip(by: 10) }
                        controlButton("goforward.30", "Forward 30 seconds") { session.skip(by: 30) }
                    }
                }

                HStack(spacing: 12) {
                    Button(role: .destructive) { session.stop() } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    if !app.queue.isEmpty {
                        Button { app.playNextInQueue() } label: {
                            Label("Next", systemImage: "forward.end.fill")
                        }
                    }
                }
                .buttonStyle(.bordered)

                extrasRow(caps: caps)

                if caps.volume {
                    HStack(spacing: 12) {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $volume, in: 0...1, onEditingChanged: { editing in
                            if !editing { session.setVolume(volume) }
                        })
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("TV volume")
                }

                if session.device.kind == .roku {
                    RokuRemotePad(device: session.device)
                }

                if let error = session.lastError {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.subheadline)
                        if !session.media.viaRelay && !session.item.isLocal {
                            Button("Try again through iPhone relay") { app.retryThroughRelay() }
                                .buttonStyle(.borderedProminent)
                        }
                        Button("Play on iPhone / AirPlay instead") { app.playOnPhone(session.item) }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                }

                if session.media.viaRelay {
                    Label("This video passes through your iPhone. Keep CastPilot open or in the background (don't swipe it away) while it plays.",
                          systemImage: "iphone.radiowaves.left.and.right")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            scrub = session.status.position
            volume = session.status.volume ?? 0.5
        }
        .onChange(of: session.status.position) { _, newValue in
            if !session.isScrubbing { scrub = newValue }
        }
        .onChange(of: session.status.volume) { _, newValue in
            if let newValue { volume = newValue }
        }
    }

    /// Up Next, speed, subtitles and sleep timer.
    @ViewBuilder
    private func extrasRow(caps: CastCapabilities) -> some View {
        HStack(spacing: 10) {
            NavigationLink(value: "queue") {
                chip("list.bullet", app.queue.isEmpty ? "Up Next" : "Up Next (\(app.queue.upNext.count))")
            }

            if caps.speed {
                Menu {
                    ForEach(Self.speeds, id: \.self) { speed in
                        Button {
                            session.setRate(speed)
                        } label: {
                            if speed == session.status.rate {
                                Label(speedLabel(speed), systemImage: "checkmark")
                            } else {
                                Text(speedLabel(speed))
                            }
                        }
                    }
                } label: {
                    chip("gauge.with.dots.needle.67percent", speedLabel(session.status.rate))
                }
            }

            if caps.subtitleToggle && session.media.subtitleVTT != nil {
                Button { session.setSubtitles(!session.subtitlesOn) } label: {
                    chip(session.subtitlesOn ? "captions.bubble.fill" : "captions.bubble", session.subtitlesOn ? "CC on" : "CC off")
                }
            }

            Menu {
                Button("Off") { app.setSleepTimer(nil) }
                ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                    Button("\(minutes) minutes") { app.setSleepTimer(.minutes(minutes)) }
                }
                Button("End of this video") { app.setSleepTimer(.endOfVideo) }
            } label: {
                if let deadline = app.sleepDeadline {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        chip("moon.fill", max(0, deadline.timeIntervalSince(context.date)).clockString)
                    }
                } else {
                    chip(app.sleepAtEndOfVideo ? "moon.fill" : "moon", app.sleepAtEndOfVideo ? "End of video" : "Sleep")
                }
            }
        }
        .font(.footnote)
    }

    private func chip(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(.secondarySystemBackground), in: Capsule())
    }

    private func speedLabel(_ rate: Double) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : "\(rate.formatted(.number.precision(.fractionLength(0...2))))×"
    }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.1)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            if let poster = session.item.poster {
                AsyncImage(url: poster) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "play.tv").font(.system(size: 48)).foregroundStyle(Color.accentColor)
                }
            } else {
                Image(systemName: session.device.kind.symbol)
                    .font(.system(size: 56))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func controlButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title2)
        }
        .accessibilityLabel(label)
        .disabled(session.status.duration <= 0 && session.status.position <= 0)
    }
}

/// The videos waiting to play after the current one.
struct QueueView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var queue = app.queue
        List {
            Section {
                Toggle(isOn: $queue.shuffle) { Label("Shuffle", systemImage: "shuffle") }
                Picker(selection: $queue.repeatMode) {
                    ForEach(RepeatMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                } label: {
                    Label("Repeat", systemImage: queue.repeatMode.symbol)
                }
                Toggle(isOn: Binding(get: { app.settings.autoAdvanceQueue }, set: { app.settings.autoAdvanceQueue = $0 })) {
                    Label("Play the next video automatically", systemImage: "forward.end")
                }
            }

            Section {
                if queue.upNext.isEmpty {
                    Text("Nothing queued. On any video, tap “Add to Up Next” or “Play next”.")
                        .foregroundStyle(.secondary)
                }
                ForEach(queue.upNext) { entry in
                    HStack {
                        MediaRow(item: entry.item)
                        Button {
                            app.playQueued(entry)
                        } label: {
                            Image(systemName: "play.fill")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Play now")
                    }
                }
                .onDelete { queue.remove(atOffsets: $0) }
                .onMove { queue.move(fromOffsets: $0, toOffset: $1) }
            } header: {
                Text("Up Next")
            }
        }
        .navigationTitle("Up Next")
        .toolbar {
            if !queue.upNext.isEmpty {
                ToolbarItem(placement: .primaryAction) { EditButton() }
                ToolbarItem(placement: .bottomBar) {
                    Button("Clear Up Next", role: .destructive) { queue.clear() }
                }
            }
        }
    }
}

/// Buttons for a Roku: arrows, OK, Back, Home, playback and (on Roku TVs) volume.
struct RokuRemotePad: View {
    let device: CastDevice
    @State private var typed = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                key("arrow.uturn.backward", "Back", "Back")
                Spacer()
                key("house.fill", "Home", "Home")
                Spacer()
                key("asterisk", "Options", "Info")
            }
            VStack(spacing: 8) {
                key("chevron.up", "Up", "Up")
                HStack(spacing: 8) {
                    key("chevron.left", "Left", "Left")
                    Button { press("Select") } label: {
                        Text("OK").font(.headline).frame(width: 64, height: 64)
                            .background(Color.accentColor, in: Circle())
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel("OK")
                    key("chevron.right", "Right", "Right")
                }
                key("chevron.down", "Down", "Down")
            }
            HStack {
                key("backward.fill", "Rewind", "Rev")
                Spacer()
                key("playpause.fill", "Play or pause", "Play")
                Spacer()
                key("forward.fill", "Fast forward", "Fwd")
                Spacer()
                key("arrow.counterclockwise", "Instant replay", "InstantReplay")
            }
            HStack {
                key("speaker.minus.fill", "Volume down", "VolumeDown")
                Spacer()
                key("speaker.slash.fill", "Mute", "VolumeMute")
                Spacer()
                key("speaker.plus.fill", "Volume up", "VolumeUp")
            }
            HStack {
                TextField("Type on TV (search boxes)", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .onSubmit(sendText)
                Button("Send", action: sendText).disabled(typed.isEmpty)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func key(_ symbol: String, _ label: String, _ code: String) -> some View {
        Button { press(code) } label: {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 48, height: 48)
                .background(Color(.tertiarySystemBackground), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func press(_ code: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            do {
                try await RokuController.press(code, on: device)
                error = nil
            } catch {
                self.error = "The Roku didn't respond."
            }
        }
    }

    private func sendText() {
        let text = typed
        typed = ""
        Task {
            do { try await RokuController.type(text, on: device) } catch { self.error = "The Roku didn't respond." }
        }
    }
}
