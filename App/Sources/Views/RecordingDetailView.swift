import SwiftUI
import SwiftData
import AVFoundation
import RiffCore

struct RecordingDetailView: View {
    @Bindable var recording: RecordingItem
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var account: PlaudAccount
    @Query(sort: \Folder.name) private var folders: [Folder]
    @StateObject private var player = AudioPlayer()

    enum DetailTab: String, CaseIterable { case summary = "Summary", transcript = "Transcript", ask = "Ask" }

    @State private var tab: DetailTab = .summary
    @State private var busy: String?
    @State private var errorText: String?
    @State private var template: SummaryTemplate = .meeting
    @State private var draft = ""
    @State private var chat: [ChatMessage] = []
    @State private var summaryModel: ProviderConfig?
    @State private var askModel: ProviderConfig?

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
                }
            }
            .frame(maxHeight: .infinity)
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .onAppear { player.load(recording.audioURL) }
        .onDisappear { player.stop() }
        .alert("Something went wrong", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    // MARK: Header + player

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: $recording.title, axis: .vertical)
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
                        Picker("Template", selection: $template) {
                            ForEach(SummaryTemplate.allCases) { Text($0.label).tag($0) }
                        }
                    } label: {
                        Label(template.label, systemImage: "doc.text").font(Theme.mono)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Theme.surface, in: .capsule)
                    }
                    ModelChip(config: summaryConfig, task: .summarize) { settings.settings.summarize = $0 }
                    Spacer()
                }
                if let b = busy, tab == .summary {
                    ThinkingIndicator(label: b)
                } else if let summary = recording.summary {
                    if let source = recording.summarySource {
                        SectionLabel(source == "plaud" ? "From Plaud" : "By \(source)")
                    }
                    MarkdownText(summary)
                    Button { Task { await summarize() } } label: {
                        Label("Regenerate", systemImage: "arrow.clockwise").font(.subheadline)
                    }
                    .disabled(recording.transcript == nil)
                    .padding(.top, 6)
                } else {
                    emptyCard(
                        title: recording.transcript == nil ? "Transcribe first" : "No summary yet",
                        body: recording.transcript == nil
                            ? "A summary needs a transcript. Transcribe this recording, or fetch Plaud's."
                            : "Summarize with \(summaryConfig.wrappedValue.chipLabel).",
                        action: recording.transcript == nil ? ("Transcribe", startTranscribe) : ("Summarize", startSummarize)
                    )
                }
            }
            .padding(.horizontal, 18).padding(.bottom, 24)
        }
    }

    // MARK: Transcript

    @ViewBuilder
    private var transcriptView: some View {
        if let b = busy, tab == .transcript {
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
                    action: ("Transcribe", startTranscribe)
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
                isThinking: busy != nil && tab == .ask,
                greeting: "Ask about this note",
                subtitle: recording.transcript == nil ? "Transcribe it first so there's something to read." : nil,
                suggestions: recording.transcript == nil ? [] : [
                    "What were the decisions?", "List the action items with owners", "What questions were left open?",
                ],
                onSuggestion: { draft = $0; Task { await ask() } }
            )
            Composer(text: $draft, placeholder: "Ask about this note…", isBusy: busy != nil,
                     isEnabled: recording.transcript != nil, onSend: { Task { await ask() } }) {
                ModelChip(config: askConfig, task: .chat) { settings.settings.chat = $0 }
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
                Button("Transcribe on this iPhone", systemImage: "waveform.badge.mic") { Task { await transcribe() } }
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

    private func startTranscribe() { Task { await transcribe() } }
    private func startSummarize() { Task { await summarize() } }

    private func transcribe() async {
        tab = .transcript
        busy = "Transcribing"
        defer { busy = nil }
        do {
            let transcriber = try AIRouter.transcriber(for: settings.settings.transcribe)
            let lang = settings.settings.language.isEmpty ? nil : settings.settings.language
            recording.transcript = try await transcriber.transcribe(fileURL: recording.audioURL, language: lang)
            recording.transcriptSource = transcriber.displayName
            try? context.save()
        } catch {
            errorText = errorMessage(error)
        }
    }

    private func summarize() async {
        guard let t = recording.transcript else { return }
        busy = "Summarizing"
        defer { busy = nil }
        do {
            let model = try AIRouter.chatModel(for: summaryConfig.wrappedValue, task: .summarize)
            recording.summary = try await Summarizer(model: model).summarize(t, template: template)
            recording.summarySource = model.displayName
            try? context.save()
        } catch {
            errorText = errorMessage(error)
        }
    }

    private func ask() async {
        guard let t = recording.transcript else { return }
        let q = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, busy == nil else { return }
        draft = ""
        let history = chat
        chat.append(.user(q))
        busy = "Thinking"
        defer { busy = nil }
        do {
            let model = try AIRouter.chatModel(for: askConfig.wrappedValue, task: .chat)
            chat.append(.assistant(try await Summarizer(model: model).answer(q, transcript: t, history: history)))
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
