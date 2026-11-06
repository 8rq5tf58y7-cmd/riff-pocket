import SwiftUI
import SwiftData

@main
struct RiffPocketApp: App {
    @StateObject private var settings = SettingsStore.shared
    @StateObject private var account = PlaudAccount()
    @StateObject private var sync = SyncService()
    @Environment(\.scenePhase) private var scenePhase
    private let container: ModelContainer

    init() {
        Theme.applyAppearance()
        do {
            container = try ModelContainer(for: RecordingItem.self, Folder.self)
        } catch {
            fatalError("Couldn't open the notes database: \(error)")
        }
        // Background tasks must be registered before launch finishes.
        BackgroundWork.register(container: container)
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
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            let context = container.mainContext
            switch phase {
            case .background:
                BackgroundWork.scheduleAll(context: context)
            case .active:
                // Catch up on anything the background couldn't finish (e.g. on-iPhone MLX summaries).
                Task { await BackgroundWork.processPending(context: context, inBackground: false) }
            default:
                break
            }
        }
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
