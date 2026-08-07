import SwiftUI

@main
struct CameraStreamerApp: App {
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1000, minHeight: 680)
                .environmentObject(settings)
        }

        Settings {
            SettingsView(settings: settings)
                .frame(minWidth: 420, minHeight: 360)
        }
    }
}
