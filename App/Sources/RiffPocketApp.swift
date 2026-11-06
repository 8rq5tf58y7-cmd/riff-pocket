import SwiftUI
import SwiftData
import RiffCore

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
            container = try ModelContainer(for: RecordingItem.self, Folder.self, NoteAttachment.self)
        } catch {
            fatalError("Couldn't open the notes database: \(error)")
        }
        // Background tasks must be registered before launch finishes.
        BackgroundWork.register(container: container)
        Pipeline.shared.register(container: container)
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
    @State private var pairLink: String?
    @State private var pairError: String?

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
        .onOpenURL { url in
            if url.scheme == "riffpocket", url.host == "pair" { pairLink = url.absoluteString }
        }
        .alert("Pair with Riff Desk?", isPresented: Binding(get: { pairLink != nil }, set: { if !$0 { pairLink = nil } })) {
            Button("Pair") {
                let link = pairLink ?? ""
                Task {
                    do { _ = try await DeskSync.shared.pair(link: link) } catch { pairError = errorMessage(error) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your notes will sync with the computer at \(DeskPairing.parse(pairLink ?? "")?.baseURL ?? "an unknown address"). Only pair with a Riff Desk you run yourself.")
        }
        .alert("Couldn't pair", isPresented: Binding(get: { pairError != nil }, set: { if !$0 { pairError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(pairError ?? "") }
    }
}

func errorMessage(_ error: Error) -> String {
    if let e = error as? LocalizedError, let d = e.errorDescription { return d }
    return String(describing: error)
}
