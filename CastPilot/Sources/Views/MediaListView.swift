import SwiftUI
import UIKit

/// Every video the browser found on the current page.
struct MediaListView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: MediaItem?

    var body: some View {
        NavigationStack {
            List {
                if app.browser.detectedMedia.isEmpty {
                    ContentUnavailableView {
                        Label("No videos found yet", systemImage: "film")
                    } description: {
                        Text("Start playing the video on the page. CastPilot picks it up as soon as it starts loading.")
                    }
                } else {
                    Section {
                        ForEach(app.browser.detectedMedia) { item in
                            Button { chosen = item } label: { MediaRow(item: item) }
                                .buttonStyle(.plain)
                        }
                    } footer: {
                        Text("Seeing several? The first one, or a “Stream (HLS)” one, is usually the main video. Short clips are often ads.")
                    }
                }
            }
            .navigationTitle("Videos on this page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if !app.browser.detectedMedia.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Clear") { app.browser.clearMedia() }
                    }
                }
            }
            .confirmationDialog(chosen?.title ?? "Video",
                                isPresented: Binding(get: { chosen != nil }, set: { if !$0 { chosen = nil } }),
                                titleVisibility: .visible,
                                presenting: chosen) { item in
                MediaActions(item: item)
            } message: { item in
                Text(item.url.absoluteString).font(.caption)
            }
        }
    }
}

/// The choices shown after tapping a video. Used for web videos and imported files.
struct MediaActions: View {
    @Environment(AppState.self) private var app
    let item: MediaItem

    var body: some View {
        if let device = app.devices.selectedDevice {
            Button("Cast to \(device.name)") { app.cast(item) }
            Button("Cast to another device…") {
                app.pendingItem = item
                app.sheet = .devices
            }
        } else {
            Button("Cast to TV…") { app.cast(item) }
        }
        Button("Play on iPhone / AirPlay") { app.playOnPhone(item) }
        if !item.isLocal {
            Button("Copy video link") { UIPasteboard.general.url = item.url }
        }
        Button("Cancel", role: .cancel) {}
    }
}

struct MediaRow: View {
    let item: MediaItem

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                if let poster = item.poster {
                    AsyncImage(url: poster) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: item.kind.symbol).foregroundStyle(Color.accentColor)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Image(systemName: item.kind.symbol)
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 72, height: 46)
            .clipped()

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text("\(item.kind.label) · \(item.displayHost)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(item.url.lastPathComponent)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
