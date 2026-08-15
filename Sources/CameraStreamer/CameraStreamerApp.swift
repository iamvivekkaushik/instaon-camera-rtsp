import SwiftUI

@main
struct CameraStreamerApp: App {
    @StateObject private var settings = AppSettings.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1000, minHeight: 680)
                .environmentObject(settings)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About CameraStreamer") {
                    openWindow(id: "about")
                }
            }
        }

        Window("About CameraStreamer", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            SettingsView(settings: settings)
                .frame(minWidth: 420, minHeight: 360)
        }
    }
}
