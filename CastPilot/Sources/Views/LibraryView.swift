import SwiftUI

struct LibraryView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0

    var body: some View {
        NavigationStack {
            List {
                if tab == 0 {
                    if app.library.bookmarks.isEmpty {
                        ContentUnavailableView("No bookmarks", systemImage: "bookmark",
                                               description: Text("Use ••• › Bookmark this page to save sites you watch often."))
                    }
                    ForEach(app.library.bookmarks) { bookmark in
                        row(title: bookmark.title, url: bookmark.url, detail: bookmark.url.host ?? "")
                    }
                    .onDelete { app.library.deleteBookmarks(at: $0) }
                    .onMove { app.library.moveBookmarks(from: $0, to: $1) }
                } else {
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
                    Text("History").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 6)
                .background(.bar)
            }
            .navigationTitle(tab == 0 ? "Bookmarks" : "History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    if tab == 0 {
                        EditButton()
                    } else if !app.library.history.isEmpty {
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
