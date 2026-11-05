import SwiftUI
import AVFoundation
import RiffCore

struct RecordingDetailView: View {
    @Bindable var recording: RecordingItem
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var account: PlaudAccount
    @StateObject private var player = AudioPlayer()

    enum DetailTab: String, CaseIterable { case transcript = "Transcript", summary = "Summary", ask = "Ask" }

    @State private var tab: DetailTab = .transcript
    @State private var busy: String?
    @State private var errorText: String?
    @State private var template: SummaryTemplate = .meeting
    @State private var question = ""
    @State private var chat: [ChatMessage] = []

    var body: some View {
        VStack(spacing: 0) {
            playerBar
            Picker("View", selection: $tab) {
                ForEach(DetailTab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            Group {
                switch tab {
                case .transcript: transcriptView
                case .summary: summaryView
                case .ask: askView
                }
            }
            .frame(maxHeight: .infinity)
        }
        .navigationTitle(recording.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if recording.plaudId != nil {
                        Button("Get Plaud's transcript & summary", systemImage: "icloud.and.arrow.down") {
                            Task { await fetchPlaudContent() }
                        }
                    }
                    Button("Transcribe on this phone", systemImage: "waveform.badge.mic") { Task { await transcribe() } }
                    ShareLink(item: recording.audioURL) { Label("Share audio", systemImage: "square.and.arrow.up") }
                    if let t = recording.transcript {
                        ShareLink(item: t.timestampedLines.joined(separator: "\n")) { Label("Share transcript", systemImage: "doc.text") }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onAppear { player.load(recording.audioURL) }
        .onDisappear { player.stop() }
        .overlay {
            if let busy {
                ProgressView(busy).padding().background(.regularMaterial, in: .rect(cornerRadius: 12))
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    // MARK: Player

    private var playerBar: some View {
        VStack(spacing: 6) {
            Slider(value: Binding(get: { player.currentTime }, set: { player.seek($0) }),
                   in: 0...max(player.duration, 1))
            HStack {
                Text(Transcript.clock(player.currentTime)).monospacedDigit()
                Spacer()
                Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.largeTitle)
                }
                Button { player.skip(15) } label: { Image(systemName: "goforward.15") }
                Spacer()
                Text(Transcript.clock(player.duration)).monospacedDigit()
            }
            .font(.caption)
        }
        .padding()
    }

    // MARK: Transcript

    @ViewBuilder
    private var transcriptView: some View {
        if let t = recording.transcript, !t.segments.isEmpty {
            List {
                if let source = recording.transcriptSource {
                    Text("Source: \(source == "plaud" ? "Plaud" : source)").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(t.segments.enumerated()), id: \.offset) { _, seg in
                    Button { player.seek(seg.start); player.play() } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(Transcript.clock(seg.start)).monospacedDigit()
                                if let s = seg.speaker { Text(s).bold() }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                            Text(seg.text.trimmingCharacters(in: .whitespaces)).foregroundStyle(.primary)
                        }
                    }
                }
            }
            .listStyle(.plain)
        } else {
            ContentUnavailableView {
                Label("No transcript", systemImage: "text.alignleft")
            } description: {
                Text("Using \(settings.settings.transcribe.kind.label). Change it in Settings.")
            } actions: {
                Button("Transcribe") { Task { await transcribe() } }.buttonStyle(.borderedProminent)
                if recording.plaudId != nil {
                    Button("Check Plaud for a transcript") { Task { await fetchPlaudContent() } }
                }
            }
        }
    }

    // MARK: Summary

    private var summaryView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("Template", selection: $template) {
                        ForEach(SummaryTemplate.allCases) { Text($0.label).tag($0) }
                    }
                    Spacer()
                    Button(recording.summary == nil ? "Summarize" : "Regenerate") { Task { await summarize() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(recording.transcript == nil)
                }
                if let summary = recording.summary {
                    if let source = recording.summarySource {
                        Text("Source: \(source == "plaud" ? "Plaud" : source)").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(markdown(summary)).textSelection(.enabled)
                } else if recording.transcript == nil {
                    Text("Transcribe first, then summarize.").foregroundStyle(.secondary)
                }
            }
            .padding()
        }
    }

    // MARK: Ask

    private var askView: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if chat.isEmpty {
                        Text("Ask anything about this recording — \"What did we decide about pricing?\"")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(chat.enumerated()), id: \.offset) { _, m in
                        Text(markdown(m.content))
                            .padding(10)
                            .background(m.role == .user ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1),
                                        in: .rect(cornerRadius: 10))
                            .frame(maxWidth: .infinity, alignment: m.role == .user ? .trailing : .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding()
            }
            HStack {
                TextField("Ask about this recording", text: $question, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Button { Task { await ask() } } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || recording.transcript == nil)
            }
            .padding()
        }
    }

    // MARK: Actions

    private func transcribe() async {
        busy = "Transcribing… (first run downloads the model)"
        defer { busy = nil }
        do {
            let config = settings.settings.transcribe
            let transcriber = try AIRouter.transcriber(for: config)
            let lang = settings.settings.language.isEmpty ? nil : settings.settings.language
            recording.transcript = try await transcriber.transcribe(fileURL: recording.audioURL, language: lang)
            recording.transcriptSource = transcriber.displayName
        } catch {
            errorText = errorMessage(error)
        }
    }

    private func summarize() async {
        guard let t = recording.transcript else { return }
        busy = "Summarizing…"
        defer { busy = nil }
        do {
            let model = try AIRouter.chatModel(for: settings.settings.summarize, task: .summarize)
            recording.summary = try await Summarizer(model: model).summarize(t, template: template)
            recording.summarySource = model.displayName
        } catch {
            errorText = errorMessage(error)
        }
    }

    private func ask() async {
        guard let t = recording.transcript else { return }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        question = ""
        let history = chat
        chat.append(.user(q))
        busy = "Thinking…"
        defer { busy = nil }
        do {
            let model = try AIRouter.chatModel(for: settings.settings.chat, task: .chat)
            let answer = try await Summarizer(model: model).answer(q, transcript: t, history: history)
            chat.append(.assistant(answer))
        } catch {
            chat.removeLast()
            question = q
            errorText = errorMessage(error)
        }
    }

    private func fetchPlaudContent() async {
        guard let client = account.makeClient() else {
            errorText = "Connect your Plaud account first."
            return
        }
        busy = "Asking Plaud…"
        defer { busy = nil }
        await SyncService().importPlaudContent(for: recording, client: client)
        if recording.transcript == nil && recording.summary == nil {
            errorText = "Plaud has no transcript or summary for this recording yet."
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
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
