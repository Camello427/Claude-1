import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Cast videos stored on the iPhone (from Photos, the Files app or downloads).
struct LocalFilesView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var photoSelection: PhotosPickerItem?
    @State private var showImporter = false
    @State private var importing = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PhotosPicker(selection: $photoSelection, matching: .videos) {
                        Label("Add from Photos", systemImage: "photo.on.rectangle")
                    }
                    Button { showImporter = true } label: {
                        Label("Add from Files", systemImage: "folder")
                    }
                } footer: {
                    Text("Videos are copied into CastPilot so your TV can play them from the iPhone. Swipe to delete them when you're done.")
                }

                if importing {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Importing… big videos can take a moment.").foregroundStyle(.secondary)
                    }
                }
                if let errorText {
                    Text(errorText).foregroundStyle(.red)
                }

                if !app.downloads.downloads.isEmpty {
                    Section {
                        ForEach(app.downloads.downloads) { download in
                            DownloadRow(download: download)
                                .swipeActions {
                                    Button(role: .destructive) { app.downloads.remove(download) } label: {
                                        Label(download.state == .running ? "Cancel" : "Remove", systemImage: "xmark")
                                    }
                                }
                        }
                    } header: {
                        HStack {
                            Text("Downloads")
                            Spacer()
                            if app.downloads.downloads.contains(where: { $0.state != .running }) {
                                Button("Clear") { app.downloads.clearFinished() }.font(.caption)
                            }
                        }
                    }
                }

                Section("On this iPhone") {
                    if app.localMedia.items.isEmpty {
                        Text("No videos added yet.").foregroundStyle(.secondary)
                    }
                    ForEach(app.localMedia.items) { item in
                        NavigationLink(value: item) { MediaRow(item: item) }
                    }
                    .onDelete { offsets in
                        offsets.map { app.localMedia.items[$0] }.forEach(app.localMedia.delete)
                    }
                }
            }
            .navigationTitle("Videos on this iPhone")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: MediaItem.self) { item in
                MediaDetailView(item: item)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audiovisualContent], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    importing = true
                    Task {
                        defer { importing = false }
                        for url in urls {
                            do { try app.localMedia.importFile(from: url) } catch { errorText = error.localizedDescription }
                        }
                    }
                case .failure(let error):
                    errorText = error.localizedDescription
                }
            }
            .onChange(of: photoSelection) { _, newValue in
                guard let newValue else { return }
                importing = true
                errorText = nil
                Task {
                    defer {
                        importing = false
                        photoSelection = nil
                    }
                    do {
                        if try await newValue.loadTransferable(type: PickedMovie.self) != nil {
                            app.localMedia.reload()
                        } else {
                            errorText = "That item couldn't be loaded as a video."
                        }
                    } catch {
                        errorText = "Couldn't import the video: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
}

private struct DownloadRow: View {
    let download: DownloadManager.Download

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(download.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            switch download.state {
            case .running:
                if download.expected > 0 {
                    ProgressView(value: download.progress)
                } else {
                    ProgressView()
                }
                Text(sizeText).font(.caption).foregroundStyle(.secondary)
            case .finished:
                Label("Downloaded · \(ByteCountFormatter.string(fromByteCount: download.received, countStyle: .file))",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .cancelled:
                Text("Cancelled").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var sizeText: String {
        let got = ByteCountFormatter.string(fromByteCount: download.received, countStyle: .file)
        guard download.expected > 0 else { return got }
        return "\(got) of \(ByteCountFormatter.string(fromByteCount: download.expected, countStyle: .file))"
    }
}
