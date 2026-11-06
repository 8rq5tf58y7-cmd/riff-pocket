import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import RiffCore

struct RecordingsView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var account: PlaudAccount
    @EnvironmentObject private var sync: SyncService
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var pipeline = Pipeline.shared
    @Query(sort: \RecordingItem.createdAt, order: .reverse) private var recordings: [RecordingItem]
    @Query(sort: \Folder.name) private var folders: [Folder]

    @State private var scopeTag = NoteScope.all.tag
    @State private var search = ""
    @State private var showConnect = false
    @State private var showFolders = false
    @State private var importing = false
    @State private var importError: String?
    @State private var newFolderName = ""
    @State private var newFolderFor: RecordingItem?
    @State private var showNewFolder = false

    private var scope: NoteScope { NoteScope(tag: scopeTag) }

    private var visible: [RecordingItem] {
        recordings.filter(scope.includes).filter { r in
            search.isEmpty
                || r.title.localizedCaseInsensitiveContains(search)
                || (r.summary ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                banners
                folderStrip
                ForEach(groupedByDay, id: \.day) { group in
                    Section {
                        ForEach(group.items) { rec in
                            NavigationLink(value: rec) { RecordingRow(recording: rec) }
                                .listRowBackground(Theme.background)
                                .contextMenu { moveMenu(rec) }
                                .swipeActions(edge: .trailing) {
                                    Button("Delete", role: .destructive) { delete(rec) }
                                }
                        }
                    } header: {
                        SectionLabel(group.day)
                    }
                }
            }
            .listStyle(.plain)
            .themedList()
            .searchable(text: $search, prompt: "Search notes")
            .overlay { emptyState }
            .navigationTitle("Notes")
            .navigationDestination(for: RecordingItem.self) { RecordingDetailView(recording: $0) }
            .refreshable { await runSync() }
            .toolbar { toolbar }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                Task { await importFiles(result) }
            }
            .sheet(isPresented: $showConnect) { PlaudConnectView() }
            .sheet(isPresented: $showFolders) { FoldersView() }
            .alert("New folder", isPresented: $showNewFolder) {
                TextField("Name", text: $newFolderName)
                Button("Create") { createFolder() }
                Button("Cancel", role: .cancel) { newFolderFor = nil }
            }
            .task {
                if account.isConnected && sync.lastSync == nil { await runSync() }
            }
        }
    }

    /// Notes with audio but no transcript, or a transcript but no summary.
    private var waiting: [RecordingItem] {
        recordings.filter { r in
            r.autoProcessFailures < 2 && ((r.transcriptData == nil && r.hasAudioFile) || (r.transcriptData != nil && r.summary == nil))
        }
    }

    // MARK: Sections

    private struct DayGroup { let day: String; let items: [RecordingItem] }

    private var groupedByDay: [DayGroup] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: visible) { cal.startOfDay(for: $0.createdAt) }
        return groups.keys.sorted(by: >).map { day in
            let label: String
            if cal.isDateInToday(day) { label = "Today" }
            else if cal.isDateInYesterday(day) { label = "Yesterday" }
            else { label = day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) }
            return DayGroup(day: label, items: groups[day]!.sorted { $0.createdAt > $1.createdAt })
        }
    }

    @ViewBuilder
    private var banners: some View {
        if !account.isConnected {
            Button { showConnect = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.plus").font(.title2).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connect your Plaud account").font(Theme.serif(17, .semibold)).foregroundStyle(Theme.text)
                        Text("Sign in with Apple to sync your Note Pro recordings.").font(.caption).foregroundStyle(Theme.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }
            .buttonStyle(.plain)
            .listRowSeparator(.hidden)
            .listRowBackground(Theme.background)
        } else if account.needsReconnect || account.expiryWarning != nil {
            Button { showConnect = true } label: {
                Label(account.expiryWarning ?? "Plaud sign-in is no longer valid — reconnect.", systemImage: "exclamationmark.triangle")
                    .font(.subheadline).foregroundStyle(Theme.warning)
                    .frame(maxWidth: .infinity, alignment: .leading).card()
            }
            .buttonStyle(.plain)
            .listRowSeparator(.hidden)
            .listRowBackground(Theme.background)
        }
        if let active = pipeline.activeNoteId, let rec = recordings.first(where: { $0.id == active }) {
            HStack {
                ThinkingIndicator(label: "\(pipeline.stepLabel ?? "Processing") “\(rec.title)”")
                if !pipeline.queued.isEmpty { Text("+\(pipeline.queued.count)").font(Theme.mono).foregroundStyle(Theme.secondary) }
            }
            .listRowSeparator(.hidden).listRowBackground(Theme.background)
        } else if !waiting.isEmpty {
            Button { Pipeline.shared.start(ids: waiting.map(\.id)) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles").font(.title3).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(waiting.count) note\(waiting.count == 1 ? "" : "s") waiting").font(Theme.serif(17, .semibold))
                            .foregroundStyle(Theme.text)
                        Text("Transcribe, summarize and name them. Keeps going if you leave the app.")
                            .font(.caption).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    Text("Process").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6).background(Theme.accent, in: .capsule)
                }
                .card()
            }
            .buttonStyle(.plain)
            .listRowSeparator(.hidden)
            .listRowBackground(Theme.background)
        }
        if let err = pipeline.lastError {
            Text(err).font(.footnote).foregroundStyle(.red).listRowBackground(Theme.background)
                .onTapGesture { pipeline.lastError = nil }
        }
        if let status = sync.status {
            ThinkingIndicator(label: status.replacingOccurrences(of: "…", with: ""))
                .listRowSeparator(.hidden).listRowBackground(Theme.background)
        }
        if let err = sync.lastError ?? importError {
            Text(err).font(.footnote).foregroundStyle(.red).listRowBackground(Theme.background)
        }
    }

    private var folderStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", tag: NoteScope.all.tag, icon: "tray.full")
                chip("Unfiled", tag: NoteScope.unfiled.tag, icon: "tray")
                ForEach(folders) { f in chip(f.name, tag: NoteScope.folder(f.id).tag, icon: "folder") }
                Button { newFolderFor = nil; newFolderName = ""; showNewFolder = true } label: {
                    Image(systemName: "plus").font(.caption.bold()).padding(8).background(Theme.surface, in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New folder")
            }
            .padding(.vertical, 2)
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Theme.background)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }

    private func chip(_ title: String, tag: String, icon: String) -> some View {
        let selected = scopeTag == tag
        return Button { withAnimation(.snappy) { scopeTag = tag } } label: {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .foregroundStyle(selected ? Theme.accent : Theme.text)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(selected ? Theme.accentSoft : Theme.surface, in: .capsule)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var emptyState: some View {
        if visible.isEmpty && sync.status == nil {
            VStack(spacing: 12) {
                Text("✻").font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.accent)
                Text(search.isEmpty ? "No notes here yet" : "No matches").font(Theme.serif(22))
                Text(account.isConnected
                     ? "Pull to sync from Plaud, record with the mic, or move notes into this folder."
                     : "Connect Plaud, record with the mic, or import an audio file.")
                    .font(.subheadline).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            }
            .padding(32)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            NavigationLink { LibraryChatView(scope: scope) } label: {
                Label("Chat with \(scope == .all ? "all notes" : "this folder")", systemImage: "bubble.left.and.text.bubble.right")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Sync now", systemImage: "arrow.triangle.2.circlepath") { Task { await runSync() } }
                    .disabled((!account.isConnected && !settings.settings.deskEnabled) || sync.isSyncing)
                Button("Import audio…", systemImage: "square.and.arrow.down") { importing = true }
                Button("Manage folders…", systemImage: "folder.badge.gearshape") { showFolders = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    @ViewBuilder
    private func moveMenu(_ rec: RecordingItem) -> some View {
        Menu("Move to folder", systemImage: "folder") {
            Button("None") { rec.folder = nil; try? context.save() }
            ForEach(folders) { f in
                Button(f.name) { rec.folder = f; try? context.save() }
            }
            Divider()
            Button("New folder…", systemImage: "plus") { newFolderFor = rec; newFolderName = ""; showNewFolder = true }
        }
        Button("Delete", systemImage: "trash", role: .destructive) { delete(rec) }
    }

    // MARK: Actions

    private func runSync() async {
        await BackgroundWork.withExtendedTime("Sync") {
            if account.isConnected {
                await sync.sync(account: account, context: context, usePlaudContent: settings.settings.preferPlaudContent)
            }
            await DeskSync.shared.sync(context: context)
            await CloudMirror.shared.push(context: context)
        }
        // A pull-to-refresh is a user action, so new work can run as a continued task.
        let s = settings.settings
        if s.autoTranscribe || s.autoSummarize {
            let ids = BackgroundWork.candidates(context: context).map(\.id)
            if !ids.isEmpty { Pipeline.shared.start(ids: ids) }
        }
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let folder = Folder(name: name)
        context.insert(folder)
        newFolderFor?.folder = folder
        newFolderFor = nil
        try? context.save()
        scopeTag = NoteScope.folder(folder.id).tag
    }

    private func delete(_ rec: RecordingItem) {
        try? FileManager.default.removeItem(at: rec.audioURL)
        context.delete(rec)
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
                context.insert(item)  // insert first, then link to the folder
                if case .folder(let id) = scope { item.folder = folders.first { $0.id == id } }
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
        VStack(alignment: .leading, spacing: 6) {
            Text(recording.title).font(Theme.serif(17, .medium)).lineLimit(2)
            if let summary = recording.summary, !summary.isEmpty {
                Text(preview(summary)).font(.subheadline).foregroundStyle(Theme.secondary).lineLimit(2)
            }
            HStack(spacing: 8) {
                Text(recording.createdAt, format: .dateTime.hour().minute())
                Text("·")
                Text(Duration.seconds(recording.duration), format: .time(pattern: .hourMinuteSecond))
                if let f = recording.folder { StatusPill(text: f.name, systemImage: "folder") }
                if recording.transcriptData != nil { Image(systemName: "text.alignleft") }
                if recording.summary != nil { Image(systemName: "sparkles").foregroundStyle(Theme.accent) }
                if recording.goneRemotely { Image(systemName: "icloud.slash").foregroundStyle(Theme.warning) }
            }
            .font(Theme.mono)
            .foregroundStyle(Theme.secondary)
        }
        .padding(.vertical, 4)
    }

    private func preview(_ s: String) -> String {
        s.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#-* ")) }
            .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("summary") }
            .prefix(2).joined(separator: " ")
    }
}

/// Rename / delete folders.
struct FoldersView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Folder.name) private var folders: [Folder]
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("New folder name", text: $newName)
                        Button("Add") {
                            let n = newName.trimmingCharacters(in: .whitespaces)
                            guard !n.isEmpty else { return }
                            context.insert(Folder(name: n))
                            newName = ""
                            try? context.save()
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section {
                    ForEach(folders) { folder in
                        FolderRow(folder: folder)
                    }
                    .onDelete { offsets in
                        offsets.map { folders[$0] }.forEach(context.delete)
                        try? context.save()
                    }
                } header: { SectionLabel("Folders") } footer: {
                    Text("Deleting a folder keeps its notes — they become unfiled.")
                }
            }
            .themedList()
            .navigationTitle("Folders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct FolderRow: View {
    @Bindable var folder: Folder

    var body: some View {
        HStack {
            Image(systemName: "folder").foregroundStyle(Theme.accent)
            TextField("Name", text: $folder.name)
            Spacer()
            Text("\(folder.recordings.count)").font(Theme.mono).foregroundStyle(Theme.secondary)
        }
    }
}
