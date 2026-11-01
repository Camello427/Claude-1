import SwiftUI
import UIKit

/// Every video the browser found on the current page.
struct MediaListView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var showHidden = false

    var body: some View {
        let browser = app.browser
        let items = showHidden ? browser.detectedMedia : browser.visibleMedia
        NavigationStack {
            List {
                if items.isEmpty {
                    ContentUnavailableView {
                        Label("No videos found yet", systemImage: "film")
                    } description: {
                        Text("Start playing the video on the page. CastPilot picks it up as soon as it starts loading.")
                    }
                } else {
                    Section {
                        ForEach(items) { item in
                            NavigationLink(value: item) { MediaRow(item: item) }
                        }
                    } footer: {
                        Text("Seeing several? The first one, or a “Stream (HLS)” one, is usually the main video.")
                    }
                }
                if browser.hiddenClipCount > 0 {
                    Section {
                        Toggle("Show \(browser.hiddenClipCount) short clip\(browser.hiddenClipCount == 1 ? "" : "s")", isOn: $showHidden)
                    } footer: {
                        Text("Videos shorter than \(Int(app.settings.shortClipSeconds)) seconds are usually ads, so they're hidden. You can turn this off in Settings.")
                    }
                }
                if !browser.detectedSubtitles.isEmpty {
                    Section("Subtitles found on this page") {
                        ForEach(browser.detectedSubtitles) { sub in
                            Label(sub.label, systemImage: "captions.bubble")
                        }
                    }
                }
            }
            .navigationTitle("Videos on this page")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: MediaItem.self) { item in
                MediaDetailView(item: item)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if !browser.detectedMedia.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Clear") { browser.clearMedia() }
                    }
                }
            }
        }
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
            .overlay(alignment: .bottomTrailing) {
                if let d = item.duration, d > 0 {
                    Text(d.clockString)
                        .font(.caption2.monospacedDigit().bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                        .padding(3)
                }
            }

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
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
