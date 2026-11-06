import SwiftUI
import SwiftData
import RiffCore

/// Chat with all your notes at once, or only one folder.
struct LibraryChatView: View {
    @EnvironmentObject private var settings: SettingsStore
    @Query(sort: \Folder.name) private var folders: [Folder]
    @Query(sort: \RecordingItem.createdAt, order: .reverse) private var recordings: [RecordingItem]

    @State private var scope: NoteScope
    @State private var modelOverride: ProviderConfig?
    @State private var chat: [ChatMessage] = []
    @State private var draft = ""
    @State private var thinking = false
    @State private var errorText: String?

    init(scope: NoteScope = .all) {
        _scope = State(initialValue: scope)
    }

    private var scoped: [RecordingItem] { recordings.filter(scope.includes) }
    private var readable: Int { scoped.filter { $0.noteSource.hasContent }.count }

    private var model: Binding<ProviderConfig> {
        Binding(get: { modelOverride ?? settings.settings.chat }, set: { modelOverride = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            ChatTranscriptView(
                messages: chat,
                isThinking: thinking,
                thinkingLabel: "Reading \(readable) note\(readable == 1 ? "" : "s")",
                greeting: scope == .all ? "Ask across all your notes" : "Ask about \(scope.title(folders: folders))",
                subtitle: "\(readable) of \(scoped.count) notes have a transcript or summary.",
                suggestions: [
                    "What were the key decisions this week?",
                    "List every action item assigned to me",
                    "Which notes mention the budget?",
                ],
                onSuggestion: { draft = $0; send() }
            )
            if let errorText {
                Text(errorText).font(.footnote).foregroundStyle(.red).padding(.horizontal, 18).padding(.bottom, 4)
            }
            Composer(text: $draft, placeholder: "Ask your notes…", isBusy: thinking, isEnabled: readable > 0, onSend: send) {
                ModelChip(config: model, task: .chat) { settings.settings.chat = $0 }
            }
        }
        .background(Theme.background)
        .navigationTitle(scope.title(folders: folders))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { scopeMenu }
            ToolbarItem(placement: .topBarTrailing) {
                Button { chat = []; errorText = nil } label: { Image(systemName: "square.and.pencil") }
                    .disabled(chat.isEmpty)
                    .accessibilityLabel("New chat")
            }
        }
    }

    private var scopeMenu: some View {
        Menu {
            Picker("Scope", selection: Binding(get: { scope.tag }, set: { scope = NoteScope(tag: $0); chat = [] })) {
                Label("All notes", systemImage: "tray.full").tag(NoteScope.all.tag)
                Label("Unfiled", systemImage: "tray").tag(NoteScope.unfiled.tag)
                ForEach(folders) { f in
                    Label(f.name, systemImage: "folder").tag(NoteScope.folder(f.id).tag)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(scope.title(folders: folders)).font(Theme.serif(17, .semibold)).foregroundStyle(Theme.text)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.secondary)
            }
        }
    }

    private func send() {
        let q = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !thinking else { return }
        draft = ""
        errorText = nil
        let history = chat
        chat.append(.user(q))
        thinking = true
        let notes = scoped.map(\.noteSource)
        Task {
            defer { thinking = false }
            do {
                let m = try AIRouter.chatModel(for: model.wrappedValue, task: .chat)
                let answer = try await Summarizer(model: m, options: ChatOptions(temperature: 0.3, maxTokens: 1200))
                    .answer(q, library: notes, history: history)
                chat.append(.assistant(answer))
            } catch {
                chat.removeLast()
                draft = q
                errorText = errorMessage(error)
            }
        }
    }
}
