import Foundation
import Observation

enum RepeatMode: String, CaseIterable {
    case off, all, one

    var symbol: String {
        switch self {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    var label: String {
        switch self {
        case .off: return "Repeat off"
        case .all: return "Repeat all"
        case .one: return "Repeat this video"
        }
    }

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

struct QueueEntry: Identifiable, Hashable {
    let id = UUID()
    var item: MediaItem
}

/// Videos waiting to play after the current one.
@MainActor
@Observable
final class PlayQueue {
    private(set) var upNext: [QueueEntry] = []
    var repeatMode: RepeatMode = .off
    var shuffle = false

    var isEmpty: Bool { upNext.isEmpty }

    func add(_ item: MediaItem) {
        upNext.append(QueueEntry(item: item))
    }

    func playNext(_ item: MediaItem) {
        upNext.insert(QueueEntry(item: item), at: 0)
    }

    func remove(atOffsets offsets: IndexSet) {
        upNext.remove(atOffsets: offsets)
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        upNext.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    func remove(_ entry: QueueEntry) {
        upNext.removeAll { $0.id == entry.id }
    }

    func clear() {
        upNext.removeAll()
    }

    /// Picks what plays after `current`, honouring repeat and shuffle.
    /// `finished` is true when the current video ended on its own (repeat-one only applies then).
    func dequeueNext(after current: MediaItem?, finished: Bool) -> MediaItem? {
        if finished, repeatMode == .one, let current { return current }
        if repeatMode == .all, let current { upNext.append(QueueEntry(item: current)) }
        guard !upNext.isEmpty else { return nil }
        let index = shuffle ? Int.random(in: 0..<upNext.count) : 0
        return upNext.remove(at: index).item
    }
}
