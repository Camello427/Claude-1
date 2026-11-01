import SwiftUI
import UIKit

/// Cast a video by pasting its address, e.g. an .mp4 or .m3u8 link.
struct CastLinkView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var title = ""
    @FocusState private var focused: Bool

    private var url: URL? {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    private var item: MediaItem? {
        guard let url else { return nil }
        let name = title.trimmingCharacters(in: .whitespaces)
        return MediaItem(url: url, title: name.isEmpty ? url.deletingPathExtension().lastPathComponent : name,
                         kind: MediaKind.detect(url: url, mime: nil), source: .web(page: nil, frame: nil))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com/video.mp4", text: $link, axis: .vertical)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                    Button {
                        if let s = UIPasteboard.general.url?.absoluteString ?? UIPasteboard.general.string { link = s }
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                    TextField("Title (optional)", text: $title)
                } header: {
                    Text("Video link")
                } footer: {
                    if !link.isEmpty && url == nil {
                        Text("That doesn't look like a web address.").foregroundStyle(.red)
                    } else if let item {
                        Text("Detected: \(item.kind.label)")
                    } else {
                        Text("Works with direct links to video files (.mp4, .webm, .mov, …) and streams (.m3u8). For a normal web page, use “Open page in browser”.")
                    }
                }

                if let item {
                    Section {
                        NavigationLink {
                            MediaDetailView(item: item)
                        } label: {
                            Label("Cast…", systemImage: "play.tv.fill")
                        }
                        Button { app.playOnPhone(item) } label: {
                            Label("Play on iPhone / AirPlay", systemImage: "iphone")
                        }
                        Button {
                            if let url { app.tabs.newTab(url: url) }
                            dismiss()
                        } label: {
                            Label("Open page in browser", systemImage: "safari")
                        }
                    }
                }
            }
            .navigationTitle("Cast a link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .onAppear {
                if link.isEmpty, UIPasteboard.general.hasURLs {
                    focused = false
                } else {
                    focused = true
                }
            }
        }
    }
}
