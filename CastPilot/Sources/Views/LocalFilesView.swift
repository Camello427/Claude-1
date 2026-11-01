import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Cast videos stored on the iPhone (from Photos or the Files app).
struct LocalFilesView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var photoSelection: PhotosPickerItem?
    @State private var showImporter = false
    @State private var importing = false
    @State private var errorText: String?
    @State private var chosen: MediaItem?

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

                Section("On this iPhone") {
                    if app.localMedia.items.isEmpty {
                        Text("No videos added yet.").foregroundStyle(.secondary)
                    }
                    ForEach(app.localMedia.items) { item in
                        Button { chosen = item } label: { MediaRow(item: item) }
                            .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        offsets.map { app.localMedia.items[$0] }.forEach(app.localMedia.delete)
                    }
                }
            }
            .navigationTitle("Videos on this iPhone")
            .navigationBarTitleDisplayMode(.inline)
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
            .confirmationDialog(chosen?.title ?? "Video",
                                isPresented: Binding(get: { chosen != nil }, set: { if !$0 { chosen = nil } }),
                                titleVisibility: .visible,
                                presenting: chosen) { item in
                MediaActions(item: item)
            }
        }
    }
}
