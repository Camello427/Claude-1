import Foundation
import Observation

struct Bookmark: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var url: URL
}

struct HistoryEntry: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var url: URL
    var date: Date
}

/// Bookmarks and history, saved on the phone.
@MainActor
@Observable
final class Library {
    private(set) var bookmarks: [Bookmark] = []
    private(set) var history: [HistoryEntry] = []

    private let defaults = UserDefaults.standard

    static let starterBookmarks: [Bookmark] = [
        Bookmark(title: "Internet Archive – Movies", url: URL(string: "https://archive.org/details/movies")!),
        Bookmark(title: "Apple HLS examples", url: URL(string: "https://developer.apple.com/streaming/examples/")!),
        Bookmark(title: "Test videos (Big Buck Bunny)", url: URL(string: "https://test-videos.co.uk/bigbuckbunny/mp4-h264")!),
        Bookmark(title: "NASA TV & videos", url: URL(string: "https://plus.nasa.gov/")!),
        Bookmark(title: "Vimeo", url: URL(string: "https://vimeo.com/watch")!),
    ]

    init() {
        if let data = defaults.data(forKey: "bookmarks"), let saved = try? JSONDecoder().decode([Bookmark].self, from: data) {
            bookmarks = saved
        } else {
            bookmarks = Self.starterBookmarks
        }
        if let data = defaults.data(forKey: "history"), let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            history = saved
        }
    }

    func isBookmarked(_ url: URL?) -> Bool {
        guard let url else { return false }
        return bookmarks.contains { $0.url == url }
    }

    func toggleBookmark(title: String, url: URL) {
        if let i = bookmarks.firstIndex(where: { $0.url == url }) {
            bookmarks.remove(at: i)
        } else {
            bookmarks.insert(Bookmark(title: title.isEmpty ? (url.host ?? url.absoluteString) : title, url: url), at: 0)
        }
        saveBookmarks()
    }

    func deleteBookmarks(at offsets: IndexSet) {
        bookmarks.remove(atOffsets: offsets)
        saveBookmarks()
    }

    func moveBookmarks(from: IndexSet, to: Int) {
        bookmarks.move(fromOffsets: from, toOffset: to)
        saveBookmarks()
    }

    func recordVisit(title: String, url: URL) {
        guard url.scheme == "http" || url.scheme == "https" else { return }
        if let first = history.first, first.url == url {
            history[0].title = title
        } else {
            history.insert(HistoryEntry(title: title, url: url, date: Date()), at: 0)
        }
        if history.count > 300 { history.removeLast(history.count - 300) }
        saveHistory()
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    private func saveBookmarks() {
        defaults.set(try? JSONEncoder().encode(bookmarks), forKey: "bookmarks")
    }

    private func saveHistory() {
        defaults.set(try? JSONEncoder().encode(history), forKey: "history")
    }
}
