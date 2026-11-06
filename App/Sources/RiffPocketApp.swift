import SwiftUI
import SwiftData

@main
struct RiffPocketApp: App {
    @StateObject private var settings = SettingsStore()
    @StateObject private var account = PlaudAccount()
    @StateObject private var sync = SyncService()

    init() {
        Theme.applyAppearance()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(account)
                .environmentObject(sync)
                .tint(Theme.accent)
                .foregroundStyle(Theme.text)
        }
        .modelContainer(for: [RecordingItem.self, Folder.self])
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            Tab("Notes", systemImage: "waveform") { RecordingsView() }
            Tab("Chat", systemImage: "bubble.left.and.text.bubble.right") {
                NavigationStack { LibraryChatView() }
            }
            Tab("Record", systemImage: "mic") { RecordView() }
            Tab("Settings", systemImage: "slider.horizontal.3") { SettingsView() }
        }
        .background(Theme.background)
    }
}

func errorMessage(_ error: Error) -> String {
    if let e = error as? LocalizedError, let d = e.errorDescription { return d }
    return String(describing: error)
}
