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
