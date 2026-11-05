import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import RiffCore

struct RecordingsView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var account: PlaudAccount
    @EnvironmentObject private var sync: SyncService
    @EnvironmentObject private var settings: SettingsStore
    @Query(sort: \RecordingItem.createdAt, order: .reverse) private var recordings: [RecordingItem]
    @State private var showConnect = false
    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            List {
                banners
                ForEach(recordings) { rec in
                    NavigationLink(value: rec) { RecordingRow(recording: rec) }
                }
                .onDelete(perform: delete)
            }
            .overlay {
                if recordings.isEmpty && !sync.isSyncing {
                    ContentUnavailableView(
                        "No recordings yet",
                        systemImage: "waveform",
                        description: Text(account.isConnected
                            ? "Pull to sync from your Plaud account. New Note Pro recordings show up after the Plaud app uploads them."
                            : "Connect your Plaud account, record with the mic, or import an audio file.")
                    )
                }
            }
            .navigationTitle("Recordings")
            .navigationDestination(for: RecordingItem.self) { RecordingDetailView(recording: $0) }
            .refreshable { await sync.sync(account: account, context: context, usePlaudContent: settings.settings.preferPlaudContent) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Sync now", systemImage: "arrow.triangle.2.circlepath") {
                            Task { await sync.sync(account: account, context: context, usePlaudContent: settings.settings.preferPlaudContent) }
                        }
                        .disabled(!account.isConnected || sync.isSyncing)
                        Button("Import audio…", systemImage: "square.and.arrow.down") { importing = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                Task { await importFiles(result) }
            }
            .sheet(isPresented: $showConnect) { PlaudConnectView() }
            .task {
                if account.isConnected && sync.lastSync == nil {
                    await sync.sync(account: account, context: context, usePlaudContent: settings.settings.preferPlaudContent)
                }
            }
        }
    }

    @ViewBuilder
    private var banners: some View {
        if !account.isConnected {
            Section {
                Button { showConnect = true } label: {
                    Label("Connect your Plaud account", systemImage: "person.crop.circle.badge.plus")
                }
            } footer: {
                Text("Sign in with Apple through Plaud's website — the same token Riffado uses.")
            }
        } else if account.needsReconnect || account.expiryWarning != nil {
            Section {
                Button { showConnect = true } label: {
                    Label(account.expiryWarning ?? "Plaud sign-in is no longer valid. Reconnect.",
                          systemImage: "exclamationmark.triangle")
                }
                .tint(.orange)
            }
        }
        if let status = sync.status {
            Section { HStack { ProgressView(); Text(status).foregroundStyle(.secondary) } }
        }
        if let err = sync.lastError ?? importError {
            Section { Text(err).foregroundStyle(.red).font(.footnote) }
        }
    }

    private func delete(at offsets: IndexSet) {
        for i in offsets {
            let rec = recordings[i]
            try? FileManager.default.removeItem(at: rec.audioURL)
            context.delete(rec)
        }
        try? context.save()
    }

    private func importFiles(_ result: Result<[URL], Error>) async {
        importError = nil
        do {
            for url in try result.get() {
                let dest = try RecordingStorage.importFile(from: url)
                let item = RecordingItem(
                    title: url.deletingPathExtension().lastPathComponent,
                    duration: await RecordingStorage.duration(of: dest),
                    audioFileName: dest.lastPathComponent,
                    source: "import"
                )
                context.insert(item)
            }
            try context.save()
        } catch {
            importError = errorMessage(error)
        }
    }
}

struct RecordingRow: View {
    let recording: RecordingItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(recording.title).font(.headline).lineLimit(2)
            HStack(spacing: 8) {
                Text(recording.createdAt, format: .dateTime.month().day().hour().minute())
                Text(Duration.seconds(recording.duration), format: .time(pattern: .hourMinuteSecond))
                if recording.transcriptData != nil { Image(systemName: "text.alignleft") }
                if recording.summary != nil { Image(systemName: "sparkles") }
                if recording.source == "plaud" { Image(systemName: "icloud") }
                if recording.goneRemotely { Image(systemName: "icloud.slash").foregroundStyle(.orange) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
