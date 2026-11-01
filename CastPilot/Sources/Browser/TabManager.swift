import Foundation
import Observation

/// All open browser tabs.
@MainActor
@Observable
final class TabManager {
    private(set) var tabs: [BrowserModel] = []
    var currentID: UUID

    let settings: AppSettings
    private let library: Library
    /// Forwarded from every tab: (tab, newly found video).
    @ObservationIgnored var onMediaDetected: ((BrowserModel, MediaItem) -> Void)?

    init(settings: AppSettings, library: Library) {
        self.settings = settings
        self.library = library
        let first = BrowserModel(settings: settings, library: library)
        currentID = first.id
        tabs = [first]
        attach(first)
    }

    var current: BrowserModel {
        tabs.first { $0.id == currentID } ?? tabs[0]
    }

    @discardableResult
    func newTab(url: URL? = nil, isPrivate: Bool = false) -> BrowserModel {
        current.captureSnapshot()
        let tab = BrowserModel(settings: settings, library: library, isPrivate: isPrivate, loadHomePage: url == nil)
        attach(tab)
        tabs.append(tab)
        currentID = tab.id
        if let url { tab.load(url) }
        return tab
    }

    func select(_ tab: BrowserModel) {
        currentID = tab.id
    }

    func close(_ tab: BrowserModel) {
        tab.tearDown()
        tabs.removeAll { $0.id == tab.id }
        if tabs.isEmpty {
            let fresh = BrowserModel(settings: settings, library: library)
            attach(fresh)
            tabs = [fresh]
        }
        if !tabs.contains(where: { $0.id == currentID }) {
            currentID = tabs[tabs.count - 1].id
        }
    }

    func closeAllPrivate() {
        tabs.filter(\.isPrivate).forEach(close)
    }

    func forEachTab(_ body: (BrowserModel) -> Void) {
        tabs.forEach(body)
    }

    private func attach(_ tab: BrowserModel) {
        tab.onMediaDetected = { [weak self, weak tab] item in
            guard let self, let tab else { return }
            self.onMediaDetected?(tab, item)
        }
    }
}
