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
                }

                Section {
                    Picker("Send video through iPhone", selection: $settings.relayMode) {
                        ForEach(RelayMode.allCases) { Text($0.name).tag($0) }
                    }
                    Toggle("Keep running in background", isOn: $settings.keepAliveInBackground)
                } header: {
                    Text("Casting")
                } footer: {
                    Text(settings.relayMode.detail + " While video goes through your iPhone, keeping CastPilot running in the background stops playback from cutting out when you lock the phone.")
                }

                Section("Privacy") {
                    Button("Clear browsing history", role: .destructive) { app.library.clearHistory() }
                    Button(clearedData ? "Cookies and website data cleared" : "Clear cookies and website data", role: .destructive) {
                        Task {
                            await app.browser.clearWebsiteData()
                            clearedData = true
                        }
                    }
                    .disabled(clearedData)
                }

                Section("Supported devices") {
                    Label("Chromecast, Google TV, Android TV and TVs with Chromecast built-in", systemImage: "tv.badge.wifi")
                    Label("Smart TVs with DLNA: most Samsung, LG, Sony, Panasonic, Philips, Hisense, TCL. Also Xbox, Kodi and more", systemImage: "tv")
                    Label("Roku players and Roku TVs (play, pause, stop)", systemImage: "appletvremote.gen1")
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
            .onChange(of: settings.adBlockEnabled) { _, _ in app.browser.applyAdBlock() }
            .onChange(of: settings.desktopMode) { _, _ in app.browser.reloadForDesktopModeChange() }
        }
    }
}
