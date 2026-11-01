import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Everything you can do with one video: pick quality and subtitles, cast it, queue it,
/// play it on the phone or download it.
struct MediaDetailView: View {
    @Environment(AppState.self) private var app
    @State var item: MediaItem
    @State private var variants: [HLSVariant] = []
    @State private var loadingVariants = false
    @State private var showSubtitleImporter = false
    @State private var note: String?

    var body: some View {
        List {
            Section {
                MediaRow(item: item)
                if let d = item.duration, d > 0 {
                    LabeledContent("Length", value: d.clockString)
                }
                if let resume = app.history.resumePosition(for: item.url), app.settings.resumePlayback {
                    LabeledContent("Resumes at", value: resume.clockString)
                }
            }

            if item.kind == .hls && !item.isLocal {
                Section {
                    if loadingVariants {
                        HStack(spacing: 10) { ProgressView(); Text("Checking available qualities…").foregroundStyle(.secondary) }
                    } else if variants.isEmpty {
                        Text("This stream has one quality.").foregroundStyle(.secondary)
                    } else {
                        Picker("Quality", selection: $item.variant) {
                            Text("Automatic").tag(HLSVariant?.none)
                            ForEach(variants) { v in
                                Text(v.label).tag(Optional(v))
                            }
                        }
                    }
                } header: {
                    Text("Quality")
                } footer: {
                    Text("Automatic lets the TV pick based on your Wi-Fi. Choose a lower quality if playback keeps stopping to buffer.")
                }
            }

            if !item.kind.isStream || item.kind == .hls {
                Section {
                    Picker("Subtitles", selection: $item.subtitle) {
                        Text("Off").tag(SubtitleTrack?.none)
                        if !app.browser.detectedSubtitles.isEmpty && !item.isLocal {
                            Section("On this page") {
                                ForEach(app.browser.detectedSubtitles) { sub in
                                    Text(sub.label).tag(Optional(sub))
                                }
                            }
                        }
                        if !app.localMedia.subtitles.isEmpty {
                            Section("On this iPhone") {
                                ForEach(app.localMedia.subtitles) { sub in
                                    Text(sub.label).tag(Optional(sub))
                                }
                            }
                        }
                        if let sub = item.subtitle, !allSubtitles.contains(sub) {
                            Text(sub.label).tag(Optional(sub))
                        }
                    }
                    Button { showSubtitleImporter = true } label: {
                        Label("Load subtitle file (.srt or .vtt)…", systemImage: "doc.badge.plus")
                    }
                } header: {
                    Text("Subtitles")
                } footer: {
                    Text("Subtitles show on Chromecast and Google TV, and on many Samsung and LG TVs.")
                }
            }

            Section {
                if let device = app.devices.selectedDevice {
                    actionButton("Cast to \(device.name)", "play.tv.fill", prominent: true) { app.cast(item) }
                    actionButton("Cast to another device…", "tv") {
                        app.pendingItem = item
                        app.sheet = .devices
                    }
                } else {
                    actionButton("Cast to TV…", "play.tv.fill", prominent: true) { app.cast(item) }
                }
                actionButton("Play next", "text.line.first.and.arrowtriangle.forward") {
                    app.addToQueue(item, next: true)
                    note = app.session == nil ? nil : "Will play after the current video."
                }
                actionButton("Add to Up Next", "text.badge.plus") {
                    app.addToQueue(item)
                    note = app.session == nil ? nil : "Added to Up Next (\(app.queue.upNext.count) waiting)."
                }
                actionButton("Play on iPhone / AirPlay", "iphone") { app.playOnPhone(item) }
                if item.isDownloadable {
                    actionButton("Download to iPhone", "arrow.down.circle") {
                        app.download(item)
                        note = "Downloading. Find it under ••• › Videos on this iPhone."
                    }
                }
                if !item.isLocal {
                    actionButton("Copy video link", "doc.on.doc") {
                        UIPasteboard.general.url = item.url
                        note = "Link copied."
                    }
                }
            } footer: {
                if let note { Text(note).foregroundStyle(Color.accentColor) }
            }
        }
        .navigationTitle(item.kind.label)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard item.kind == .hls, !item.isLocal, variants.isEmpty else { return }
            loadingVariants = true
            variants = await app.loadVariants(for: item)
            loadingVariants = false
        }
        .fileImporter(isPresented: $showSubtitleImporter, allowedContentTypes: [.data, .plainText]) { result in
            switch result {
            case .success(let url):
                do {
                    item.subtitle = try app.localMedia.importSubtitle(from: url)
                    note = nil
                } catch {
                    note = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            case .failure(let error):
                note = error.localizedDescription
            }
        }
    }

    private var allSubtitles: [SubtitleTrack] {
        (item.isLocal ? [] : app.browser.detectedSubtitles) + app.localMedia.subtitles
    }

    @ViewBuilder
    private func actionButton(_ title: String, _ symbol: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(prominent ? .body.weight(.semibold) : .body)
        }
    }
}
