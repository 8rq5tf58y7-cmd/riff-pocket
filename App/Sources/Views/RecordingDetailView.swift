import SwiftUI
import SwiftData
import AVFoundation
import PhotosUI
import QuickLook
import RiffCore

struct RecordingDetailView: View {
    @Bindable var recording: RecordingItem
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var account: PlaudAccount
    @Query(sort: \Folder.name) private var folders: [Folder]
    @StateObject private var player = AudioPlayer()
    @ObservedObject private var pipeline = Pipeline.shared
    @State private var importingFile = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var previewURL: URL?
    @State private var addingFile = false

    enum DetailTab: String, CaseIterable { case summary = "Summary", transcript = "Transcript", ask = "Ask", files = "Files" }

    @State private var tab: DetailTab = .summary
    @State private var busy: String?
    @State private var errorText: String?
    @State private var style: SummaryStyle = .meeting
    @State private var showStyleEditor = false
    @State private var draft = ""
    @State private var chat: [ChatMessage] = []
    @State private var summaryModel: ProviderConfig?
    @State private var askModel: ProviderConfig?

    /// What's happening to this note right now (pipeline step, queued, or a local action).
    private var activity: String? {
        if let busy { return busy }
        if pipeline.activeNoteId == recording.id { return pipeline.stepLabel ?? "Processing" }
        if pipeline.queued.contains(recording.id) { return "Queued" }
        return nil
    }

    private var summaryConfig: Binding<ProviderConfig> {
        Binding(get: { summaryModel ?? settings.settings.summarize }, set: { summaryModel = $0 })
    }
    private var askConfig: Binding<ProviderConfig> {
        Binding(get: { askModel ?? settings.settings.chat }, set: { askModel = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            Group {
                switch tab {
                case .summary: summaryView
                case .transcript: transcriptView
                case .ask: askView
                case .files: filesView
                }
            }
            .frame(maxHeight: .infinity)
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .onAppear {
            player.load(recording.audioURL)
            style = recording.summaryStyle ?? settings.settings.defaultStyle
        }
        .sheet(isPresented: $showStyleEditor, onDismiss: { recording.summaryStyle = style; try? context.save() }) {
            NavigationStack {
                SummaryStyleEditor(style: $style, title: "Style for this note")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showStyleEditor = false } } }
            }
            .presentationBackground(Theme.background)
        }
        .onDisappear { player.stop() }
        .alert("Something went wrong", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    // MARK: Header + player

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Typing a name locks it: automatic (AI) titles won't replace it.
            TextField("Title", text: Binding(get: { recording.title },
                                             set: { recording.title = $0; recording.titleLocked = true }),
                      axis: .vertical)
                .font(Theme.serif(24, .medium))
                .lineLimit(1...3)
            HStack(spacing: 8) {
                Text(recording.createdAt, format: .dateTime.weekday(.abbreviated).month().day().hour().minute())
                if let f = recording.folder { StatusPill(text: f.name, systemImage: "folder") }
                if recording.source == "plaud" { StatusPill(text: "Plaud", systemImage: "icloud") }
            }
            .font(Theme.mono).foregroundStyle(Theme.secondary)
            playerBar
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
    }

    private var playerBar: some View {
        HStack(spacing: 12) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Theme.accent, in: .circle)
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            VStack(spacing: 2) {
                Slider(value: Binding(get: { player.currentTime }, set: { player.seek($0) }), in: 0...max(player.duration, 1))
                HStack {
                    Text(Transcript.clock(player.currentTime))
                    Spacer()
                    Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                    Button { player.skip(15) } label: { Image(systemName: "goforward.15") }
                    Spacer()
                    Text(Transcript.clock(player.duration))
                }
                .font(Theme.monoSmall).foregroundStyle(Theme.secondary).monospacedDigit()
            }
        }
        .card(padding: 10)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(DetailTab.allCases, id: \.self) { t in
                Button { withAnimation(.snappy) { tab = t } } label: {
                    Text(t.rawValue)
                        .font(.subheadline.weight(tab == t ? .semibold : .regular))
                        .foregroundStyle(tab == t ? Theme.text : Theme.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(tab == t ? Theme.raised : .clear, in: .rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Theme.surface, in: .rect(cornerRadius: 13))
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    // MARK: Summary

    private var summaryView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(settings.settings.allStyles) { s in
                            Button { style = s; recording.summaryStyle = s } label: {
                                if s.id == style.id { Label(s.name, systemImage: "checkmark") } else { Text(s.name) }
                            }
                        }
                        Divider()
                        Button("Customize format & length…", systemImage: "slider.horizontal.3") { showStyleEditor = true }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "doc.text").font(.system(size: 11, weight: .semibold))
                            Text("\(style.name) · \(style.length.label)").lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                        }
                        .font(Theme.mono).foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.surface, in: .capsule)
                    }
                    ModelChip(config: summaryConfig, task: .summarize) { settings.settings.summarize = $0 }
                    Spacer()
                }
                if let b = activity, b != "Thinking" {
                    ThinkingIndicator(label: b)
                } else if let summary = recording.summary {
                    if let source = recording.summarySource {
                        SectionLabel(source == "plaud" ? "From Plaud" : "By \(source)")
                    }
                    MarkdownText(summary)
                    Button { summarize() } label: {
                        Label("Regenerate", systemImage: "arrow.clockwise").font(.subheadline)
                    }
                    .disabled(recording.transcript == nil)
                    .padding(.top, 6)
                } else {
                    emptyCard(
                        title: recording.transcript == nil ? "Transcribe first" : "No summary yet",
                        body: recording.transcript == nil
                            ? "Transcribe, summarize and name this note in one go. It keeps running if you leave the app."
                            : "Summarize with \(summaryConfig.wrappedValue.chipLabel), then name the note from its content.",
                        action: recording.transcript == nil ? ("Transcribe & summarize", processAll) : ("Summarize", summarize)
                    )
                }
            }
            .padding(.horizontal, 18).padding(.bottom, 24)
        }
    }

    // MARK: Transcript

    @ViewBuilder
    private var transcriptView: some View {
        if let b = activity, b != "Thinking", recording.transcript == nil {
            VStack { ThinkingIndicator(label: b).padding(.top, 40); Spacer() }
        } else if let t = recording.transcript, !t.segments.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let source = recording.transcriptSource {
                        SectionLabel(source == "plaud" ? "From Plaud" : "By \(source)")
                    }
                    ForEach(Array(t.segments.enumerated()), id: \.offset) { _, seg in
                        Button { player.seek(seg.start); player.play() } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(Transcript.clock(seg.start)).foregroundStyle(Theme.accent)
                                    if let s = seg.speaker { Text(s).foregroundStyle(Theme.secondary) }
                                }
                                .font(Theme.monoSmall)
                                Text(seg.text.trimmingCharacters(in: .whitespaces))
                                    .foregroundStyle(Theme.text)
                                    .multilineTextAlignment(.leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 24)
            }
        } else {
            ScrollView {
                emptyCard(
                    title: "No transcript",
                    body: "Transcribe with \(settings.settings.transcribe.chipLabel)\(recording.plaudId != nil ? ", or fetch Plaud's own" : "").",
                    action: ("Transcribe & summarize", processAll)
                )
                .padding(.horizontal, 18)
            }
        }
    }

    // MARK: Ask

    private var askView: some View {
        VStack(spacing: 0) {
            ChatTranscriptView(
                messages: chat,
                isThinking: busy == "Thinking",
                greeting: "Ask about this note",
                subtitle: canAsk
                    ? (recording.attachments.isEmpty ? nil : "Reads the recording and \(recording.attachments.count) attached file\(recording.attachments.count == 1 ? "" : "s").")
                    : "Transcribe it or attach a file first so there's something to read.",
                suggestions: !canAsk ? [] : [
                    "What were the decisions?", "List the action items with owners", "What questions were left open?",
                ],
                onSuggestion: { draft = $0; Task { await ask() } }
            )
            Composer(text: $draft, placeholder: "Ask about this note…", isBusy: busy != nil,
                     isEnabled: canAsk, onSend: { Task { await ask() } }) {
                ModelChip(config: askConfig, task: .chat) { settings.settings.chat = $0 }
            }
        }
    }

    // MARK: Files

    private var filesView: some View {
        List {
            Section {
                ForEach(recording.attachments.sorted { $0.addedAt < $1.addedAt }) { att in
                    Button { previewURL = att.hasLocalFile ? att.fileURL : nil } label: {
                        HStack(spacing: 12) {
                            Image(systemName: att.symbol).font(.title3).foregroundStyle(Theme.accent).frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(att.name).foregroundStyle(Theme.text).lineLimit(1)
                                HStack(spacing: 6) {
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(att.size), countStyle: .file))
                                    if att.extractedText != nil {
                                        StatusPill(text: "used by Ask", systemImage: "text.magnifyingglass", color: Theme.success)
                                    } else {
                                        StatusPill(text: "no readable text", color: Theme.secondary)
                                    }
                                }
                                .font(Theme.monoSmall).foregroundStyle(Theme.secondary)
                            }
                        }
                    }
                    .listRowBackground(Theme.background)
                    .swipeActions {
                        Button("Delete", role: .destructive) { AttachmentStorage.delete(att, context: context) }
                    }
                }
                if addingFile { ThinkingIndicator(label: "Reading file").listRowBackground(Theme.background) }
            } footer: {
                Text("PDFs, text, Markdown, CSV, RTF/HTML and photos (text is read on-device) are included when you Ask about this note and in Library chat. For Word or Pages files, export to PDF first.")
            }
        }
        .listStyle(.plain)
        .themedList()
        .overlay {
            if recording.attachments.isEmpty && !addingFile {
                VStack(spacing: 10) {
                    Image(systemName: "paperclip").font(.system(size: 28)).foregroundStyle(Theme.accent)
                    Text("Attach files to this note").font(Theme.serif(20))
                    Text("Slides, agendas, contracts, photos of a whiteboard — Ask reads them alongside the recording.")
                        .font(.subheadline).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                }
                .padding(32)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                Button { importingFile = true } label: { Label("Add file", systemImage: "doc.badge.plus") }
                PhotosPicker(selection: $photoItems, maxSelectionCount: 10, matching: .images) {
                    Label("Add photo", systemImage: "photo.badge.plus")
                }
            }
            .buttonStyle(.bordered)
            .padding(10)
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            Task { await addFiles(result) }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await addPhotos(items) }
        }
        .quickLookPreview($previewURL)
    }

    private func addFiles(_ result: Result<[URL], Error>) async {
        addingFile = true
        defer { addingFile = false }
        do {
            for url in try result.get() {
                _ = try await AttachmentStorage.importFile(from: url, into: recording, context: context)
            }
        } catch {
            errorText = errorMessage(error)
        }
    }

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        addingFile = true
        defer { addingFile = false; photoItems = [] }
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                _ = try? await AttachmentStorage.importImage(data, into: recording, context: context)
            }
        }
    }

    private func emptyCard(title: String, body: String, action: (String, () -> Void)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Theme.serif(19, .semibold))
            Text(body).font(.subheadline).foregroundStyle(Theme.secondary)
            Button(action: action.1) {
                Text(action.0).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Theme.accent, in: .capsule)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Menu("Folder", systemImage: "folder") {
                    Button { recording.folder = nil } label: {
                        if recording.folder == nil { Label("None", systemImage: "checkmark") } else { Text("None") }
                    }
                    ForEach(folders) { f in
                        Button { recording.folder = f } label: {
                            if recording.folder?.id == f.id { Label(f.name, systemImage: "checkmark") } else { Text(f.name) }
                        }
                    }
                }
                if recording.plaudId != nil {
                    Button("Get Plaud's transcript & summary", systemImage: "icloud.and.arrow.down") { Task { await fetchPlaudContent() } }
                }
                Button("Transcribe again", systemImage: "waveform.badge.mic") { retranscribe() }
                Button("Rename from content", systemImage: "character.cursor.ibeam") { renameFromContent() }
                    .disabled(recording.transcript == nil && recording.summary == nil)
                Divider()
                ShareLink(item: recording.audioURL) { Label("Share audio", systemImage: "square.and.arrow.up") }
                if let t = recording.transcript {
                    ShareLink(item: t.timestampedLines.joined(separator: "\n")) { Label("Share transcript", systemImage: "doc.text") }
                }
                if let s = recording.summary {
                    ShareLink(item: s) { Label("Share summary", systemImage: "sparkles") }
                }
            } label: { Image(systemName: "ellipsis.circle") }
        }
    }

    // MARK: Actions

    private var canAsk: Bool { recording.transcript != nil || !recording.documents.isEmpty }

    /// Everything that's missing: transcript → summary → title. Continues in the background.
    private func processAll() {
        recording.summaryStyle = style
        Pipeline.shared.start([.init(noteId: recording.id, steps: .all, style: style, summaryConfig: summaryConfig.wrappedValue)])
    }

    private func retranscribe() {
        tab = .transcript
        Pipeline.shared.start([.init(noteId: recording.id, steps: [.transcribe], force: [.transcribe])])
    }

    private func summarize() {
        recording.summaryStyle = style
        Pipeline.shared.start([.init(noteId: recording.id, steps: [.summarize, .title], force: [.summarize],
                                     style: style, summaryConfig: summaryConfig.wrappedValue)])
    }

    private func renameFromContent() {
        recording.titleLocked = false
        Pipeline.shared.start([.init(noteId: recording.id, steps: [.title], force: [.title],
                                     summaryConfig: summaryConfig.wrappedValue)])
    }

    private func ask() async {
        guard canAsk else { return }
        let q = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, busy == nil else { return }
        draft = ""
        let history = chat
        chat.append(.user(q))
        busy = "Thinking"
        defer { busy = nil }
        do {
            let model = try AIRouter.chatModel(for: askConfig.wrappedValue, task: .chat)
            let answer = try await Summarizer(model: model)
                .answer(q, transcript: recording.transcript, documents: recording.documents, history: history)
            chat.append(.assistant(answer))
        } catch {
            chat.removeLast()
            draft = q
            errorText = errorMessage(error)
        }
    }

    private func fetchPlaudContent() async {
        guard let client = account.makeClient() else { errorText = "Connect your Plaud account first."; return }
        busy = "Asking Plaud"
        defer { busy = nil }
        await SyncService().importPlaudContent(for: recording, client: client)
        try? context.save()
        if recording.transcript == nil && recording.summary == nil {
            errorText = "Plaud has no transcript or summary for this recording yet."
        }
    }
}

// MARK: - Audio player

@MainActor
final class AudioPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(_ url: URL) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        duration = player?.duration ?? 0
    }

    func play() {
        guard let player else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
    }

    func toggle() { isPlaying ? pause() : play() }

    func seek(_ t: Double) {
        player?.currentTime = max(0, min(t, duration))
        currentTime = player?.currentTime ?? 0
    }

    func skip(_ delta: Double) { seek(currentTime + delta) }

    func stop() {
        pause()
        player = nil
    }

    private func tick() {
        currentTime = player?.currentTime ?? 0
        if player?.isPlaying == false { pause() }
    }
}
