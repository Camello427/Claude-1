import SwiftUI

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

                HStack(spacing: 28) {
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

                Button(role: .destructive) { session.stop() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)

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
