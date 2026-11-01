import SwiftUI
import WebKit

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// The main screen: address bar, web page, "videos found" button, now-casting bar and toolbar.
struct BrowserView: View {
    @Environment(AppState.self) private var app
    @FocusState private var addressFocused: Bool

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            AddressBar(focused: $addressFocused)
            ZStack(alignment: .bottom) {
                WebViewContainer(webView: app.browser.webView)
                if app.browser.currentURL == nil && !app.browser.isLoading {
                    StartPageView()
                        .transition(.opacity)
                }
                VStack(spacing: 10) {
                    if !app.browser.detectedMedia.isEmpty && !addressFocused {
                        FoundVideosButton(count: app.browser.detectedMedia.count) { app.sheet = .media }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if let session = app.session, !addressFocused {
                        NowCastingBar(session: session) { app.sheet = .remote }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .animation(.spring(duration: 0.3), value: app.browser.detectedMedia.count)
                .animation(.spring(duration: 0.3), value: app.session == nil)
            }
            if !addressFocused {
                BottomToolbar()
            }
        }
        .sheet(item: $app.sheet) { sheet in
            Group {
                switch sheet {
                case .media: MediaListView()
                case .devices: DevicePickerView()
                case .remote: RemoteView()
                case .library: LibraryView()
                case .settings: SettingsView()
                case .localFiles: LocalFilesView()
                }
            }
            .environment(app)
        }
        .fullScreenCover(item: $app.phonePlayback) { playback in
            PhonePlayerScreen(playback: playback)
        }
        .alert(app.alert?.title ?? "", isPresented: Binding(
            get: { app.alert != nil },
            set: { if !$0 { app.alert = nil } }
        ), presenting: app.alert) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
    }
}

struct AddressBar: View {
    @Environment(AppState.self) private var app
    var focused: FocusState<Bool>.Binding

    var body: some View {
        @Bindable var browser = app.browser
        let isFocused = focused.wrappedValue
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: browser.currentURL?.scheme == "https" && !isFocused ? "lock.fill" : "magnifyingglass")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextField("Search or enter website", text: $browser.addressText)
                        .focused(focused)
                        .keyboardType(.webSearch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit {
                            browser.navigate(browser.addressText)
                            focused.wrappedValue = false
                        }
                    if isFocused && !browser.addressText.isEmpty {
                        Button { browser.addressText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Clear")
                    } else if !isFocused && browser.currentURL != nil {
                        Button { browser.reloadOrStop() } label: {
                            Image(systemName: browser.isLoading ? "xmark" : "arrow.clockwise")
                                .font(.footnote.weight(.semibold))
                        }
                        .accessibilityLabel(browser.isLoading ? "Stop loading" : "Reload")
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                if isFocused {
                    Button("Cancel") { focused.wrappedValue = false }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ProgressView(value: browser.progress)
                .progressViewStyle(.linear)
                .frame(height: 2)
                .opacity(browser.isLoading ? 1 : 0)
        }
        .background(.bar)
        .onChange(of: isFocused) { _, nowFocused in
            browser.isEditingAddress = nowFocused
            if !nowFocused { browser.addressText = browser.currentURL?.absoluteString ?? "" }
        }
    }
}

struct BottomToolbar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let browser = app.browser
        HStack {
            toolbarButton("chevron.backward", "Back", enabled: browser.canGoBack) { browser.goBack() }
            toolbarButton("chevron.forward", "Forward", enabled: browser.canGoForward) { browser.goForward() }

            Button { app.sheet = .media } label: {
                Image(systemName: "film.stack")
                    .font(.title3)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .overlay(alignment: .topTrailing) {
                        if !browser.detectedMedia.isEmpty {
                            Text("\(browser.detectedMedia.count)")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.red, in: Capsule())
                                .offset(x: -14, y: 2)
                        }
                    }
            }
            .accessibilityLabel("Videos found: \(browser.detectedMedia.count)")

            Button {
                app.sheet = app.session != nil ? .remote : .devices
                if app.session == nil { Task { await app.devices.scan() } }
            } label: {
                Image(systemName: app.session != nil ? "tv.inset.filled" : "tv")
                    .font(.title3)
                    .foregroundStyle(app.devices.selectedDevice != nil || app.session != nil ? Color.accentColor : Color.primary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityLabel(app.session != nil ? "Remote control" : "Choose a TV")

            toolbarButton("book", "Bookmarks and history", enabled: true) { app.sheet = .library }

            Menu {
                if let url = browser.currentURL {
                    Button {
                        app.library.toggleBookmark(title: browser.pageTitle, url: url)
                    } label: {
                        Label(app.library.isBookmarked(url) ? "Remove bookmark" : "Bookmark this page",
                              systemImage: app.library.isBookmarked(url) ? "bookmark.slash" : "bookmark")
                    }
                    ShareLink(item: url) { Label("Share page", systemImage: "square.and.arrow.up") }
                }
                Button { app.sheet = .localFiles } label: {
                    Label("Videos on this iPhone", systemImage: "iphone")
                }
                Button { browser.goHome() } label: { Label("Home", systemImage: "house") }
                Divider()
                Button { app.sheet = .settings } label: { Label("Settings", systemImage: "gearshape") }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .background(.bar)
    }

    private func toolbarButton(_ symbol: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

struct FoundVideosButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "play.tv.fill")
                Text(count == 1 ? "1 video found — tap to cast" : "\(count) videos found — tap to cast")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color.accentColor, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        }
    }
}

struct NowCastingBar: View {
    @Bindable var session: CastSession
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: session.device.kind.symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(session.item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(session.status.state.label) on \(session.device.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { session.togglePlayPause() } label: {
                Image(systemName: session.status.state == .playing ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(session.status.state == .playing ? "Pause" : "Play")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }
}

struct StartPageView: View {
    @Environment(AppState.self) private var app
    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("CastPilot", systemImage: "play.tv.fill")
                        .font(.largeTitle.bold())
                        .foregroundStyle(Color.accentColor)
                    Text("Find a video on any website and play it on your TV.")
                        .foregroundStyle(.secondary)
                }

                if !app.library.bookmarks.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Bookmarks").font(.headline)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                            ForEach(app.library.bookmarks.prefix(12)) { bookmark in
                                Button { app.browser.load(bookmark.url) } label: {
                                    VStack(spacing: 6) {
                                        Text(String(bookmark.title.prefix(1)).uppercased())
                                            .font(.title2.bold())
                                            .foregroundStyle(.white)
                                            .frame(width: 56, height: 56)
                                            .background(color(for: bookmark.title), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                        Text(bookmark.title)
                                            .font(.caption)
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.center)
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                            }
                        }
                    }
                }

                Button { app.sheet = .localFiles } label: {
                    Label("Cast a video from this iPhone", systemImage: "iphone.and.arrow.forward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                VStack(alignment: .leading, spacing: 14) {
                    Text("How it works").font(.headline)
                    tip("1.circle.fill", "Open a website and start playing the video.")
                    tip("2.circle.fill", "Tap the blue “videos found” button.")
                    tip("3.circle.fill", "Pick your TV: Chromecast, Google TV, smart TVs (DLNA), Roku or AirPlay.")
                    tip("4.circle.fill", "Control playback from the remote. You can keep browsing while it plays.")
                }
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemBackground))
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Color.accentColor)
        }
    }

    private func color(for title: String) -> Color {
        let palette: [Color] = [.blue, .indigo, .purple, .pink, .orange, .teal, .green, .red]
        let sum = title.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count]
    }
}
