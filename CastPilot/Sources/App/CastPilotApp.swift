import SwiftUI

@main
struct CastPilotApp: App {
    @State private var app = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            BrowserView()
                .environment(app)
                .task {
                    app.devices.startBrowsing()
                    await app.devices.scan()
                }
                .onChange(of: scenePhase) { _, phase in
                    app.handleScenePhase(phase)
                }
        }
    }
}
