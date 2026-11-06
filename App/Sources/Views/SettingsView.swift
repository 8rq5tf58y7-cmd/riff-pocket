import SwiftUI
import RiffCore

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var account: PlaudAccount
    @ObservedObject private var local = MLXModelStore.shared
    @State private var showConnect = false
    @State private var riffadoKey = Keychain.string("riffado.key") ?? ""
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                plaudSection
                modelsSection
                summariesSection
                namingSection
                deskSection
                backgroundSection
                Section {
                    Toggle("Use Plaud's transcript & summary when available", isOn: $settings.settings.preferPlaudContent)
                    TextField("Language (blank = auto, e.g. en)", text: $settings.settings.language)
                        .textInputAutocapitalization(.never)
                } header: { SectionLabel("Transcription") }
                riffadoSection
                if let message { Section { Text(message).font(.footnote).foregroundStyle(Theme.secondary) } }
                Section {
                    Text("Riff Pocket is an independent project, not affiliated with Plaud. Plaud sign-in and sync logic is ported from Riffado (AGPL-3.0).")
                        .font(.footnote).foregroundStyle(Theme.secondary)
                }
            }
            .themedList()
            .navigationTitle("Settings")
            .sheet(isPresented: $showConnect) { PlaudConnectView() }
            .task { await account.refreshDevices() }
        }
    }

    // MARK: Plaud

    private var plaudSection: some View {
        Section {
            if let creds = account.credentials {
                LabeledContent("Server", value: account.region?.label ?? creds.apiBase)
                if let exp = creds.expiresAt {
                    LabeledContent("Signed in until", value: exp.formatted(date: .abbreviated, time: .omitted))
                }
                ForEach(Array(account.devices.enumerated()), id: \.offset) { _, d in
                    LabeledContent(d.name ?? d.model ?? "Device") {
                        Text(d.sn ?? "").font(Theme.mono)
                    }
                }
                if let warning = account.expiryWarning { Text(warning).foregroundStyle(Theme.warning) }
                Button("Reconnect") { showConnect = true }
                Button("Disconnect", role: .destructive) { account.disconnect() }
            } else {
                Button { showConnect = true } label: {
                    Label("Connect Plaud account", systemImage: "person.crop.circle.badge.plus")
                }
            }
        } header: { SectionLabel("Plaud account") }
    }

    // MARK: Models

    private var modelsSection: some View {
        Section {
            ForEach(AITask.allCases) { task in
                NavigationLink {
                    ModelPickerView(config: binding(for: task), task: task)
                } label: {
                    LabeledContent {
                        Text(settings.settings.config(for: task).chipLabel).font(Theme.mono).lineLimit(1)
                    } label: {
                        Label(task.label, systemImage: icon(task))
                    }
                }
            }
            NavigationLink {
                LocalModelsView()
            } label: {
                LabeledContent {
                    Text("\(local.downloaded.count) on device").font(Theme.mono)
                } label: {
                    Label("Local models", systemImage: "cpu")
                }
            }
        } header: { SectionLabel("AI models") } footer: {
            Text("Defaults for new chats. Every chat also has a model chip under the message box, so you can switch source and model on the fly.")
        }
    }

    private func binding(for task: AITask) -> Binding<ProviderConfig> {
        Binding(get: { settings.settings.config(for: task) }, set: { settings.settings.setConfig($0, for: task) })
    }

    private func icon(_ task: AITask) -> String {
        switch task {
        case .transcribe: return "waveform"
        case .summarize: return "sparkles"
        case .chat: return "bubble.left.and.text.bubble.right"
        }
    }

    // MARK: Summaries

    private var summariesSection: some View {
        Section {
            NavigationLink {
                SummaryTemplatesView()
            } label: {
                LabeledContent {
                    Text(settings.settings.defaultStyle.name).font(Theme.mono)
                } label: {
                    Label("Summary templates", systemImage: "doc.text")
                }
            }
        } header: { SectionLabel("Summaries") } footer: {
            Text("Pick the default format, length and sections for new notes, or make your own templates.")
        }
    }

    // MARK: Naming

    private var namingSection: some View {
        Section {
            Toggle("Name notes from their content", isOn: $settings.settings.autoTitle)
            if settings.settings.autoTitle {
                Toggle("Also replace existing names", isOn: $settings.settings.retitleNamedNotes)
                Toggle("Rename in Plaud too", isOn: $settings.settings.renameInPlaud)
            }
        } header: { SectionLabel("Naming") } footer: {
            Text("After summarizing, the note gets a short, specific title like Plaud's (e.g. “Sprint Planning Q4 Roadmap”). Names you type yourself are never replaced.")
        }
    }

    // MARK: Desktop

    private var deskSection: some View {
        Section {
            NavigationLink {
                DeskSettingsView()
            } label: {
                LabeledContent {
                    Text(DeskSync.shared.isPaired ? "Paired" : "Not paired").font(Theme.mono)
                } label: {
                    Label("Desktop companion", systemImage: "desktopcomputer")
                }
            }
        } footer: {
            Text("Riff Desk syncs your notes with your computer and processes new recordings there — even while your phone is locked.")
        }
    }

    // MARK: Background

    private var backgroundSection: some View {
        Section {
            Toggle("Check Plaud for new recordings", isOn: $settings.settings.backgroundSync)
            Toggle("Transcribe new notes automatically", isOn: $settings.settings.autoTranscribe)
            Toggle("Summarize new notes automatically", isOn: $settings.settings.autoSummarize)
            if settings.settings.autoTranscribe || settings.settings.autoSummarize {
                Toggle("Only while charging", isOn: $settings.settings.processOnlyWhileCharging)
            }
            Toggle("Notify me", isOn: $settings.settings.notifications)
                .onChange(of: settings.settings.notifications) { _, on in
                    if on { Task { _ = await Notifier.requestPermission() } }
                }
        } header: { SectionLabel("While you're away") } footer: {
            Text("iOS decides exactly when background work runs — usually while the phone is idle, and more often for apps you use regularly. Work you start keeps going briefly after you leave the app, and anything left over finishes when you come back. On-iPhone models need the screen on (iOS doesn't allow GPU work in the background), so pick Apple, Ollama or an API model for summaries that should finish while you're away. Keep Background App Refresh on for Riff Pocket in iOS Settings.")
        }
        .onChange(of: settings.settings.backgroundSync) { _, _ in BackgroundWork.scheduleRefresh() }
    }

    // MARK: Riffado

    private var riffadoSection: some View {
        Section {
            TextField("https://riffado.example.com", text: $settings.settings.riffadoURL)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("Riffado API key / session token", text: $riffadoKey)
                .onChange(of: riffadoKey) { _, v in Keychain.setString(v, for: "riffado.key") }
            Button("Test connection") {
                Task {
                    do {
                        _ = try await RiffadoClient(baseURL: settings.settings.riffadoURL).health()
                        message = "Riffado is reachable."
                    } catch { message = errorMessage(error) }
                }
            }
            .disabled(settings.settings.riffadoURL.isEmpty)
            Button("Send my Plaud sign-in to Riffado") {
                Task {
                    guard let creds = account.credentials else { message = "Connect Plaud first."; return }
                    do {
                        let ok = try await RiffadoClient(baseURL: settings.settings.riffadoURL, bearer: riffadoKey).connectPlaud(creds)
                        message = ok ? "Riffado is now connected to your Plaud account." : "Riffado didn't confirm the connection."
                    } catch { message = errorMessage(error) }
                }
            }
            .disabled(settings.settings.riffadoURL.isEmpty || !account.isConnected)
        } header: { SectionLabel("Riffado server (optional)") } footer: {
            Text("Shares the Plaud token captured here with your self-hosted Riffado, so its dashboard, scheduled sync and webhooks work on desktop too.")
        }
    }
}
