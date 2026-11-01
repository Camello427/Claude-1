import SwiftUI

struct LibraryView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0

    var body: some View {
        NavigationStack {
            List {
                switch tab {
                case 0:
                    if app.library.bookmarks.isEmpty {
                        ContentUnavailableView("No bookmarks", systemImage: "bookmark",
                                               description: Text("Use ••• › Bookmark this page to save sites you watch often."))
                    }
                    ForEach(app.library.bookmarks) { bookmark in
                        row(title: bookmark.title, url: bookmark.url, detail: bookmark.url.host ?? "")
                    }
                    .onDelete { app.library.deleteBookmarks(at: $0) }
                    .onMove { app.library.moveBookmarks(from: $0, to: $1) }
                case 1:
                    if app.history.entries.isEmpty {
                        ContentUnavailableView("Nothing cast yet", systemImage: "tv",
                                               description: Text("Videos you cast show up here, so you can pick up where you left off."))
                    }
                    ForEach(app.history.entries) { entry in
                        NavigationLink(value: entry.item) {
                            RecentRow(entry: entry)
                        }
                    }
                    .onDelete { app.history.remove(atOffsets: $0) }
                default:
                    if app.library.history.isEmpty {
                        ContentUnavailableView("No history yet", systemImage: "clock")
                    }
                    ForEach(app.library.history) { entry in
                        row(title: entry.title, url: entry.url,
                            detail: entry.date.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                Picker("Show", selection: $tab) {
                    Text("Bookmarks").tag(0)
                    Text("Recently cast").tag(1)
                    Text("History").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 6)
                .background(.bar)
            }
            .navigationTitle(["Bookmarks", "Recently cast", "History"][tab])
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: MediaItem.self) { item in
                MediaDetailView(item: item)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    if tab == 0 {
                        EditButton()
                    } else if tab == 1 && !app.history.entries.isEmpty {
                        Button("Clear", role: .destructive) { app.history.clear() }
                    } else if tab == 2 && !app.library.history.isEmpty {
                        Button("Clear", role: .destructive) { app.library.clearHistory() }
                    }
                }
            }
        }
    }

    private func row(title: String, url: URL, detail: String) -> some View {
        Button {
            app.browser.load(url)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title.isEmpty ? url.absoluteString : title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct RecentRow: View {
    let entry: CastHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: entry.isLocal ? "iphone" : entry.kind.symbol)
                    .foregroundStyle(Color.accentColor)
                Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            if entry.duration > 0 {
                ProgressView(value: entry.progress)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        var parts = [entry.date.formatted(.relative(presentation: .named)), entry.deviceName]
        if entry.isFinished {
            parts.append("Watched")
        } else if entry.position > 30 {
            parts.append("\(entry.position.clockString) of \(entry.duration.clockString)")
        }
        return parts.joined(separator: " · ")
    }
}
