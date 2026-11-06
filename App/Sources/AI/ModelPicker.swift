import SwiftUI
import AuthenticationServices
import RiffCore

/// Compact "model chip" shown under every chat composer. Tapping it opens the picker.
struct ModelChip: View {
    @Binding var config: ProviderConfig
    let task: AITask
    var onMakeDefault: ((ProviderConfig) -> Void)? = nil
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: 5) {
                Image(systemName: config.kind.symbol).font(.system(size: 11, weight: .semibold))
                Text(config.chipLabel).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .font(Theme.mono)
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.surface, in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Model: \(config.chipLabel)")
        .sheet(isPresented: $showing) {
            NavigationStack {
                ModelPickerView(config: $config, task: task, onMakeDefault: onMakeDefault)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showing = false } } }
            }
            .presentationDetents([.medium, .large])
            .presentationBackground(Theme.background)
        }
    }
}

/// Pick a source (Apple, on-device MLX, Ollama, API key, Anthropic, OpenRouter) and a model.
struct ModelPickerView: View {
    @Binding var config: ProviderConfig
    let task: AITask
    var onMakeDefault: ((ProviderConfig) -> Void)? = nil

    @ObservedObject private var local = MLXModelStore.shared
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var apiKey = ""
    @State private var remoteModels: [String] = []
    @State private var fetching = false
    @State private var note: String?
    @State private var customLocalId = ""
    @State private var openRouterSignedIn = false

    private var kinds: [ProviderKind] {
        ProviderKind.allCases.filter { kind in
            guard kind != .riffado else { return false }
            if task == .transcribe { return kind.canTranscribe && kind != .appleOnDevice }
            return kind.canChat
        }
    }

    var body: some View {
        Form {
            Section {
                ForEach(kinds) { kind in
                    Button { select(kind) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: kind.symbol).frame(width: 22).foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.label).foregroundStyle(Theme.text)
                                Text(kind.blurb).font(.caption).foregroundStyle(Theme.secondary)
                            }
                            Spacer()
                            if config.kind == kind { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                        }
                    }
                }
            } header: { SectionLabel("Source") }

            if config.kind.needsBaseURL {
                Section {
                    TextField("Base URL", text: $config.baseURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                } header: { SectionLabel("Server") } footer: {
                    if config.kind == .ollama {
                        Text("Run Ollama on your PC or Mac and reach it over Tailscale, e.g. https://my-pc.tailnet.ts.net:11434. Set OLLAMA_HOST=0.0.0.0 there. For hosted models without a computer, pick Ollama Cloud.")
                    }
                }
            }

            if config.kind.needsAPIKey {
                Section {
                    SecureField("API key", text: $apiKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: apiKey) { _, v in AIRouter.setAPIKey(v, for: config.kind) }
                } header: { SectionLabel("\(config.kind.shortName) API key") } footer: {
                    Text([config.kind.keyHelp, "Stored in the iOS Keychain on this device and shared by all chats."]
                        .compactMap { $0 }.joined(separator: " "))
                }
            }

            if config.kind == .openRouter { openRouterSection }

            modelSection

            if let onMakeDefault {
                Section {
                    Button("Use this as the default for \(task.label.lowercased())") { onMakeDefault(config) }
                }
            }
            if let note { Section { Text(note).font(.footnote).foregroundStyle(Theme.secondary) } }
        }
        .themedList()
        .navigationTitle(task == .transcribe ? "Transcription model" : "Model")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadKey)
        .onChange(of: config.kind) { _, _ in loadKey() }
    }

    // MARK: Model section per source

    @ViewBuilder
    private var modelSection: some View {
        switch config.kind {
        case .appleOnDevice:
            Section {
                Label("Apple Foundation Model — built in, private, free", systemImage: "apple.logo")
                    .foregroundStyle(Theme.text)
            } header: { SectionLabel("Model") } footer: {
                Text("Requires Apple Intelligence to be on. Small context window, so long notes are chunked.")
            }
        case .mlx:
            localModelsSection
        case .whisperKit:
            Section {
                ForEach(["tiny", "base", "small", "large-v3-v20240930_turbo"], id: \.self) { m in
                    modelRow(m, subtitle: m == "base" ? "Good default" : m.hasPrefix("large") ? "Best quality, slower" : nil)
                }
                TextField("Other WhisperKit model", text: $config.model)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { SectionLabel("Model") }
        default:
            Section {
                TextField("Model name", text: $config.model)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                Button {
                    Task { await fetchModels() }
                } label: {
                    HStack {
                        Text(fetching ? "Loading models…" : "Show available models")
                        if fetching { Spacer(); ProgressView() }
                    }
                }
                .disabled(fetching)
                ForEach(remoteModels, id: \.self) { modelRow($0) }
            } header: { SectionLabel("Model") }
        }
    }

    private var localModelsSection: some View {
        Section {
            ForEach(LocalModelCatalog.curated) { info in
                localRow(id: info.id, name: info.name, detail: "\(info.size) · \(info.note)")
            }
            ForEach(local.downloaded.filter { id in !LocalModelCatalog.curated.contains { $0.id == id } }.sorted(), id: \.self) { id in
                localRow(id: id, name: LocalModelCatalog.name(for: id), detail: id)
            }
            HStack {
                TextField("mlx-community/…", text: $customLocalId)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.system(.footnote, design: .monospaced))
                Button("Get") {
                    let id = customLocalId
                    Task { await local.download(id); if local.isDownloaded(id) { config.model = id } }
                }
                .disabled(!customLocalId.contains("/"))
            }
            if let err = local.lastError { Text(err).font(.footnote).foregroundStyle(.red) }
        } header: { SectionLabel("Model on this iPhone") } footer: {
            Text("Runs entirely on your iPhone with MLX — nothing leaves the device. Downloads come from Hugging Face. Models up to ~4B parameters work well on iPhone 16.")
        }
    }

    private func localRow(id: String, name: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Button {
                if local.isDownloaded(id) { config.model = id }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).foregroundStyle(Theme.text)
                    Text(detail).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            if let p = local.progress[id] {
                ProgressView(value: p).frame(width: 60)
            } else if local.isDownloaded(id) {
                if config.model == id { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                else { StatusPill(text: "on device", color: Theme.success) }
            } else {
                Button { Task { await local.download(id); if local.isDownloaded(id) { config.model = id } } } label: {
                    Image(systemName: "arrow.down.circle").font(.title3).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Download \(name)")
            }
        }
        .contentShape(Rectangle())
        .swipeActions {
            if local.isDownloaded(id) {
                Button("Delete", role: .destructive) { Task { await local.delete(id) } }
            }
        }
    }

    private func modelRow(_ m: String, subtitle: String? = nil) -> some View {
        Button { config.model = m } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(m).font(.system(.callout, design: .monospaced)).foregroundStyle(Theme.text)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(Theme.secondary) }
                }
                Spacer()
                if config.model == m { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
            }
        }
    }

    private var openRouterSection: some View {
        Section {
            if openRouterSignedIn {
                Label("OpenRouter key saved", systemImage: "checkmark.seal").foregroundStyle(Theme.success)
                Button("Remove key", role: .destructive) {
                    AIRouter.setAPIKey(nil, for: .openRouter); apiKey = ""
                    openRouterSignedIn = false
                }
            } else {
                Button("Or sign in with OpenRouter instead") {
                    Task {
                        do {
                            let key = try await OpenRouterSignIn.signIn(using: webAuth)
                            AIRouter.setAPIKey(key, for: .openRouter); apiKey = key
                            openRouterSignedIn = true
                        } catch { note = errorMessage(error) }
                    }
                }
            }
        } header: { SectionLabel("Account") } footer: { Text("Signing in creates a key for you. Usage is billed to your OpenRouter account.") }
    }

    // MARK: Actions

    private func select(_ kind: ProviderKind) {
        guard kind != config.kind else { return }
        var next = ProviderConfig.preset(kind, forTranscription: task == .transcribe)
        if kind == .mlx, let first = local.downloaded.sorted().first { next.model = first }
        config = next
        remoteModels = []
        note = nil
    }

    private func loadKey() {
        apiKey = AIRouter.apiKey(for: config.kind, task: task) ?? ""
        openRouterSignedIn = AIRouter.apiKey(for: .openRouter, task: task) != nil
    }

    private func fetchModels() async {
        fetching = true
        defer { fetching = false }
        do {
            remoteModels = try await AIRouter.listModels(for: config, task: task)
            note = remoteModels.isEmpty ? "No models reported by this server." : nil
        } catch {
            note = errorMessage(error)
        }
    }
}

/// Settings → Local models: manage what's stored on the phone.
struct LocalModelsView: View {
    @ObservedObject private var local = MLXModelStore.shared

    var body: some View {
        List {
            Section {
                ForEach(LocalModelCatalog.curated) { info in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(info.name)
                            Text("\(info.size) · \(info.note)").font(.caption).foregroundStyle(Theme.secondary)
                        }
                        Spacer()
                        trailing(info.id, name: info.name)
                    }
                }
            } header: { SectionLabel("Recommended") }
            let custom = local.downloaded.filter { id in !LocalModelCatalog.curated.contains { $0.id == id } }.sorted()
            if !custom.isEmpty {
                Section {
                    ForEach(custom, id: \.self) { id in
                        HStack { Text(id).font(.system(.footnote, design: .monospaced)); Spacer(); trailing(id, name: id) }
                    }
                } header: { SectionLabel("Other") }
            }
            if let err = local.lastError { Section { Text(err).foregroundStyle(.red).font(.footnote) } }
        }
        .themedList()
        .navigationTitle("Local models")
    }

    @ViewBuilder
    private func trailing(_ id: String, name: String) -> some View {
        if let p = local.progress[id] {
            ProgressView(value: p).frame(width: 70)
        } else if local.isDownloaded(id) {
            Button("Delete", role: .destructive) { Task { await local.delete(id) } }.buttonStyle(.borderless)
        } else {
            Button("Download") { Task { await local.download(id) } }.buttonStyle(.borderless).tint(Theme.accent)
        }
    }
}
