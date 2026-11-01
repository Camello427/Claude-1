import Foundation
import Observation

struct CastHistoryEntry: Codable, Identifiable, Hashable {
    var id: String { url.absoluteString }
    var url: URL
    var title: String
    var kind: MediaKind
    var page: URL?
    var frame: URL?
    var poster: URL?
    var isLocal: Bool
    var position: Double
    var duration: Double
    var date: Date
    var deviceName: String

    var item: MediaItem {
        var item = MediaItem(url: url, title: title, kind: kind, source: isLocal ? .local : .web(page: page, frame: frame), poster: poster)
        if duration > 0 { item.duration = duration }
        return item
    }

    var progress: Double { duration > 0 ? min(1, position / duration) : 0 }
    var isFinished: Bool { duration > 0 && position >= duration - 30 }
}

/// Everything cast recently, with how far it got, so it can be resumed.
@MainActor
@Observable
final class CastHistory {
    private(set) var entries: [CastHistoryEntry] = []
    private var unsavedChanges = 0

    init() {
        if let data = UserDefaults.standard.data(forKey: "castHistory"),
           let saved = try? JSONDecoder().decode([CastHistoryEntry].self, from: data) {
            entries = saved.filter { !$0.isLocal || FileManager.default.fileExists(atPath: $0.url.path) }
        }
    }

    func record(_ item: MediaItem, deviceName: String) {
        var page: URL?, frame: URL?
        if case let .web(p, f) = item.source { page = p; frame = f }
        let old = entries.first { $0.url == item.url }
        let entry = CastHistoryEntry(url: item.url, title: item.title, kind: item.kind, page: page, frame: frame,
                                     poster: item.poster, isLocal: item.isLocal,
                                     position: old?.position ?? 0, duration: old?.duration ?? (item.duration ?? 0),
                                     date: Date(), deviceName: deviceName)
        entries.removeAll { $0.url == item.url }
        entries.insert(entry, at: 0)
        if entries.count > 100 { entries.removeLast(entries.count - 100) }
        save()
    }

    func updateProgress(url: URL, position: Double, duration: Double) {
        guard position > 0, let i = entries.firstIndex(where: { $0.url == url }) else { return }
        entries[i].position = position
        if duration > 0 { entries[i].duration = duration }
        unsavedChanges += 1
        if unsavedChanges >= 10 { save() }
    }

    /// Where to resume `url`, if it was left part-way through.
    func resumePosition(for url: URL) -> Double? {
        guard let e = entries.first(where: { $0.url == url }), e.position > 30, !e.isFinished else { return nil }
        return e.position
    }

    func remove(atOffsets offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    func save() {
        unsavedChanges = 0
        UserDefaults.standard.set(try? JSONEncoder().encode(entries), forKey: "castHistory")
    }
}
