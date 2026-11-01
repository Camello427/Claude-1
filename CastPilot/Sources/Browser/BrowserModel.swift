import Foundation
import Observation
import UIKit
import WebKit

/// One browser tab and the videos it has found on its current page.
@MainActor
@Observable
final class BrowserModel: Identifiable {
    let id = UUID()
    let isPrivate: Bool
    let webView: WKWebView

    var addressText = ""
    var isEditingAddress = false
    private(set) var pageTitle = ""
    private(set) var currentURL: URL?
    private(set) var progress: Double = 0
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var detectedMedia: [MediaItem] = []
    private(set) var detectedSubtitles: [SubtitleTrack] = []
    /// Changes on every page load; used so auto-cast fires at most once per page.
    private(set) var pageToken = UUID()
    var snapshot: UIImage?

    let settings: AppSettings
    private let library: Library
    @ObservationIgnored var onMediaDetected: ((MediaItem) -> Void)?
    @ObservationIgnored private var coordinator: WebCoordinator?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var cachedUserAgent: String?

    init(settings: AppSettings, library: Library, isPrivate: Bool = false, loadHomePage: Bool = true) {
        self.settings = settings
        self.library = library
        self.isPrivate = isPrivate

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        if isPrivate { config.websiteDataStore = .nonPersistent() }
        config.userContentController.addUserScript(
            WKUserScript(source: MediaSniffer.script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.isFindInteractionEnabled = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.customUserAgent = settings.browserIdentity.userAgent

        let coordinator = WebCoordinator()
        coordinator.owner = self
        self.coordinator = coordinator
        webView.configuration.userContentController.add(coordinator, name: MediaSniffer.handlerName)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator

        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.syncState() } },
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.syncState() } },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.syncState() } },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.syncState() } },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.syncState() } },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.syncState() } },
        ]

        applyAdBlock()
        if loadHomePage, let home = URL(string: settings.homePage), home.scheme != nil {
            load(home)
        }
    }

    var displayTitle: String {
        if !pageTitle.isEmpty { return pageTitle }
        return currentURL?.host ?? (isPrivate ? "Private tab" : "New tab")
    }

    /// Detected videos minus short clips (likely ads) when that setting is on.
    var visibleMedia: [MediaItem] {
        guard settings.hideShortClips else { return detectedMedia }
        return detectedMedia.filter { ($0.duration ?? .infinity) >= settings.shortClipSeconds }
    }

    var hiddenClipCount: Int { detectedMedia.count - visibleMedia.count }

    // MARK: Navigation

    func navigate(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let target: URL?
        if text.contains("://"), let url = URL(string: text) {
            target = url
        } else if !text.contains(" "), text.contains("."), let url = URL(string: "https://" + text) {
            target = url
        } else {
            target = settings.searchEngine.searchURL(for: text)
        }
        if let target { load(target) }
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    func reloadOrStop() {
        if webView.isLoading { webView.stopLoading() } else { webView.reload() }
    }

    func goHome() {
        if let home = URL(string: settings.homePage), home.scheme != nil {
            load(home)
        } else {
            webView.stopLoading()
            webView.loadHTMLString("", baseURL: nil)
            detectedMedia = []
            detectedSubtitles = []
            currentURL = nil
            addressText = ""
            pageTitle = ""
        }
    }

    func showFindOnPage() {
        webView.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    func applyAdBlock() {
        let controller = webView.configuration.userContentController
        let enabled = settings.adBlockEnabled
        Task { await AdBlocker.apply(to: controller, enabled: enabled) }
    }

    func applyIdentity() {
        webView.customUserAgent = settings.browserIdentity.userAgent
        cachedUserAgent = nil
        if webView.url != nil { webView.reload() }
    }

    func reloadForDesktopModeChange() {
        if webView.url != nil { webView.reload() }
    }

    func clearMedia() {
        detectedMedia = []
    }

    func captureSnapshot() {
        guard webView.url != nil, webView.bounds.width > 0 else { return }
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = false
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            Task { @MainActor in
                if let image { self?.snapshot = image }
            }
        }
    }

    func tearDown() {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: MediaSniffer.handlerName)
        observations.removeAll()
    }

    // MARK: Info used by the relay, downloads and the phone player

    func userAgent() async -> String {
        if let cachedUserAgent { return cachedUserAgent }
        let ua = (try? await webView.evaluateJavaScript("navigator.userAgent")) as? String
        let value = ua ?? "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        cachedUserAgent = value
        return value
    }

    func cookies() async -> [HTTPCookie] {
        await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
    }

    /// Fetches a URL the way this tab would (same User-Agent, cookies and Referer).
    func fetch(_ url: URL, referer: URL?) async throws -> (Data, URL) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        request.setValue(await userAgent(), forHTTPHeaderField: "User-Agent")
        if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        let matching = await cookies().filter { $0.applies(to: url) }
        for (k, v) in HTTPCookie.requestHeaderFields(with: matching) { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CastError.http(http.statusCode)
        }
        return (data, response.url ?? url)
    }

    func clearWebsiteData() async {
        let store = WKWebsiteDataStore.default()
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    // MARK: Callbacks from the web view

    fileprivate func syncState() {
        let url = webView.url
        currentURL = (url?.absoluteString == "about:blank") ? nil : url
        if !isEditingAddress { addressText = currentURL?.absoluteString ?? "" }
        pageTitle = webView.title ?? ""
        progress = webView.estimatedProgress
        isLoading = webView.isLoading
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    fileprivate func didStartMainFrameNavigation() {
        detectedMedia = []
        detectedSubtitles = []
        pageToken = UUID()
    }

    fileprivate func didFinishNavigation() {
        syncState()
        if let url = currentURL, !isPrivate { library.recordVisit(title: pageTitle, url: url) }
    }

    fileprivate func subtitleFound(_ body: [String: Any]) {
        guard let string = body["url"] as? String, let url = URL(string: string),
              !detectedSubtitles.contains(where: { $0.url == url }) else { return }
        let lang = (body["lang"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var label = (body["label"] as? String) ?? ""
        if label.isEmpty { label = lang.map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 } ?? url.deletingPathExtension().lastPathComponent }
        detectedSubtitles.append(SubtitleTrack(url: url, label: label, language: lang))
    }

    fileprivate func mediaFound(_ body: [String: Any], frameURL: URL?) {
        guard let string = body["url"] as? String, let url = URL(string: string) else { return }
        let duration = (body["duration"] as? NSNumber)?.doubleValue

        if let i = detectedMedia.firstIndex(where: { $0.url == url }) {
            if let duration, duration > 0 { detectedMedia[i].duration = duration }
            return
        }
        if (body["how"] as? String) == "update" { return }

        let mime = body["mime"] as? String
        let kind = MediaKind.detect(url: url, mime: mime)
        let pageTitle = (body["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? self.pageTitle
        let fileName = url.deletingPathExtension().lastPathComponent
        let title = pageTitle.isEmpty ? (fileName.isEmpty ? (url.host ?? "Video") : fileName) : pageTitle
        let page = (body["page"] as? String).flatMap { URL(string: $0) } ?? currentURL
        var item = MediaItem(url: url, title: title, kind: kind, source: .web(page: page, frame: frameURL))
        item.poster = (body["poster"] as? String).flatMap { URL(string: $0) }
        item.foundBy = body["how"] as? String ?? ""
        if let duration, duration > 0 { item.duration = duration }

        // Streams and playing videos are the most useful, so they go first.
        if kind.isStream || item.foundBy == "element" {
            detectedMedia.insert(item, at: 0)
        } else {
            detectedMedia.append(item)
        }
        if detectedMedia.count > 60 { detectedMedia.removeLast(detectedMedia.count - 60) }
        onMediaDetected?(item)
    }

    fileprivate var blocksPopups: Bool { settings.blockPopups }
    fileprivate var desktopMode: Bool { settings.effectiveDesktopMode }
}

/// Receives WebKit delegate callbacks and forwards them to the tab.
@MainActor
final class WebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    weak var owner: BrowserModel?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == MediaSniffer.handlerName, let body = message.body as? [String: Any] else { return }
        if (body["kind"] as? String) == "subtitle" {
            owner?.subtitleFound(body)
            return
        }
        let frameURL = message.frameInfo.isMainFrame ? nil : message.frameInfo.request.url
        owner?.mediaFound(body, frameURL: frameURL)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        preferences.preferredContentMode = (owner?.desktopMode ?? false) ? .desktop : .mobile
        if let scheme = navigationAction.request.url?.scheme?.lowercased(),
           !["http", "https", "about", "blob", "data", "file", "javascript"].contains(scheme) {
            // App-store and other app links are a common pop-up ad trick.
            return (.cancel, preferences)
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        owner?.didStartMainFrameNavigation()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        owner?.didFinishNavigation()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Open "new window" links in the same tab. With pop-up blocking on, only links the
        // user actually tapped are followed; script-opened windows are dropped.
        if navigationAction.targetFrame == nil {
            let userTapped = navigationAction.navigationType == .linkActivated
            if userTapped || !(owner?.blocksPopups ?? true) {
                webView.load(navigationAction.request)
            }
        }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}
