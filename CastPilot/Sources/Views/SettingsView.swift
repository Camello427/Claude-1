import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var clearedData = false

    var body: some View {
        @Bindable var settings = app.settings
        NavigationStack {
            Form {
                Section("Browser") {
                    Picker("Search with", selection: $settings.searchEngine) {
                        ForEach(SearchEngine.allCases) { Text($0.name).tag($0) }
                    }
                    TextField("Home page (optional)", text: $settings.homePage)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Block ads", isOn: $settings.adBlockEnabled)
                    Toggle("Block pop-ups", isOn: $settings.blockPopups)
                    Toggle("Request desktop websites", isOn: $settings.desktopMode)
                    Picker("Browse as", selection: $settings.browserIdentity) {
                        ForEach(BrowserIdentity.allCases) { Text($0.name).tag($0) }
                    }
                }

                Section {
                    Toggle("Hide short clips (likely ads)", isOn: $settings.hideShortClips)
                    Toggle("Auto-cast videos", isOn: $settings.autoCast)
                } header: {
                    Text("Finding videos")
                } footer: {
                    Text("Auto-cast sends the main video on a page to your chosen TV by itself, a few seconds after it's found. It won't interrupt something that's already playing.")
                }

                Section {
                    Picker("Send video through iPhone", selection: $settings.relayMode) {
                        ForEach(RelayMode.allCases) { Text($0.name).tag($0) }
                    }
                    Toggle("Resume where I left off", isOn: $settings.resumePlayback)
                    Toggle("Play Up Next automatically", isOn: $settings.autoAdvanceQueue)
                    Toggle("Lock screen & Control Center controls", isOn: $settings.lockScreenControls)
                    Toggle("Keep running in background", isOn: $settings.keepAliveInBackground)
                } header: {
                    Text("Casting")
                } footer: {
                    Text(settings.relayMode.detail + " Lock screen controls let you pause and skip on the TV without unlocking your phone; while they're on, other audio on your iPhone pauses during a cast.")
                }

                Section {
                    Toggle("Require Face ID", isOn: $settings.requireFaceID)
                    Button("Clear browsing history", role: .destructive) { app.library.clearHistory() }
                    Button("Clear recently cast", role: .destructive) { app.history.clear() }
                    Button(clearedData ? "Cookies and website data cleared" : "Clear cookies and website data", role: .destructive) {
                        Task {
                            await app.browser.clearWebsiteData()
                            clearedData = true
                        }
                    }
                    .disabled(clearedData)
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("With Face ID on, CastPilot locks whenever you leave it. Private tabs never save history or cookies.")
                }

                Section {
                    NavigationLink("Shortcuts & other apps") { ShortcutsHelpView() }
                } footer: {
                    Text("Send links to CastPilot from Safari or the Shortcuts app.")
                }

                Section("Supported devices") {
                    Label("Chromecast, Google TV, Android TV and TVs with Chromecast built-in", systemImage: "tv.badge.wifi")
                    Label("Smart TVs with DLNA: most Samsung, LG, Sony, Panasonic, Philips, Hisense, TCL. Also Xbox, Kodi and more", systemImage: "tv")
                    Label("Roku players and Roku TVs, with a full Roku remote", systemImage: "appletvremote.gen1")
                    Label("Apple TV and AirPlay TVs, through “Play on iPhone / AirPlay”", systemImage: "airplayvideo")
                }
                .font(.subheadline)

                Section {
                    Text("Videos protected with DRM (Netflix, Disney+, Prime Video and similar) can't be cast by any third-party app. Use those services' own apps or cast buttons.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onChange(of: settings.adBlockEnabled) { _, _ in app.applyAdBlockToAllTabs() }
            .onChange(of: settings.desktopMode) { _, _ in app.reloadAllTabsForDesktopMode() }
            .onChange(of: settings.browserIdentity) { _, _ in app.applyIdentityToAllTabs() }
            .onChange(of: settings.lockScreenControls) { _, _ in app.lockScreenSettingChanged() }
        }
    }
}

struct ShortcutsHelpView: View {
    var body: some View {
        List {
            Section {
                Text("Other apps and the Shortcuts app can open these links:")
                example("castpilot://open?url=https://example.com", "Open a page in a new tab")
                example("castpilot://cast?url=https://example.com/video.mp4&title=My%20video", "Cast a video to your chosen TV")
                example("castpilot://queue?url=https://example.com/video.mp4", "Add a video to Up Next")
            } header: {
                Text("CastPilot links")
            }

            Section {
                Text("1. In the Shortcuts app, create a new shortcut.")
                Text("2. Turn on “Show in Share Sheet” and accept URLs.")
                Text("3. Add a “Text” action: castpilot://open?url= followed by the Shortcut Input.")
                Text("4. Add an “Open URLs” action with that text.")
                Text("Now in Safari, tap Share › your shortcut to open the page in CastPilot.")
            } header: {
                Text("Send pages from Safari")
            }
            .font(.subheadline)
        }
        .navigationTitle("Shortcuts & other apps")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func example(_ link: String, _ what: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(what).font(.subheadline.weight(.semibold))
            Text(link)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
