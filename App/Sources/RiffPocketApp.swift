import SwiftUI
import SwiftData

@main
struct RiffPocketApp: App {
    @StateObject private var settings = SettingsStore()
    @StateObject private var account = PlaudAccount()
    @StateObject private var sync = SyncService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(account)
                .environmentObject(sync)
        }
        .modelContainer(for: RecordingItem.self)
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            Tab("Recordings", systemImage: "waveform") { RecordingsView() }
            Tab("Record", systemImage: "mic.circle") { RecordView() }
            Tab("Settings", systemImage: "gearshape") { SettingsView() }
        }
    }
}

func errorMessage(_ error: Error) -> String {
    if let e = error as? LocalizedError, let d = e.errorDescription { return d }
    return String(describing: error)
}
