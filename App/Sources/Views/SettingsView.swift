import SwiftUI
import AuthenticationServices
import RiffCore

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var account: PlaudAccount
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var showConnect = false
    @State private var keys: [AITask: String] = [:]
    @State private var openRouterConnected = Keychain.string(AIRouter.openRouterKey) != nil
    @State private var riffadoKey = Keychain.string("riffado.key") ?? ""
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                plaudSection
                ForEach(AITask.allCases) { providerSection(for: $0) }
                openRouterSection
                Section("Transcription") {
                    Toggle("Prefer Plaud's own transcript & summary", isOn: $settings.settings.preferPlaudContent)
                    TextField("Language (blank = auto, e.g. en)", text: $settings.settings.language)
                        .textInputAutocapitalization(.never)
                }
                riffadoSection
                if let message { Section { Text(message).font(.footnote) } }
                Section {
                    Text("Riff Pocket is an independent project, not affiliated with Plaud. Plaud sign-in logic is ported from Riffado (AGPL-3.0).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showConnect) { PlaudConnectView() }
            .onAppear {
                for t in AITask.allCases { keys[t] = Keychain.string(t.keychainKey) ?? "" }
            }
            .task { await account.refreshDevices() }
        }
    }

    // MARK: Plaud

    private var plaudSection: some View {
        Section("Plaud account") {
            if let creds = account.credentials {
                LabeledContent("Server", value: account.region?.label ?? creds.apiBase)
                if let exp = creds.expiresAt {
                    LabeledContent("Sign-in valid until", value: exp.formatted(date: .abbreviated, time: .omitted))
                }
                ForEach(Array(account.devices.enumerated()), id: \.offset) { _, d in
                    LabeledContent(d.name ?? d.model ?? "Device", value: d.sn ?? "")
                }
                if let warning = account.expiryWarning { Text(warning).foregroundStyle(.orange) }
                Button("Reconnect") { showConnect = true }
                Button("Disconnect", role: .destructive) { account.disconnect() }
            } else {
                Button("Connect Plaud account") { showConnect = true }
            }
        }
    }

    // MARK: Providers

    private func providerSection(for task: AITask) -> some View {
        let binding = Binding<ProviderConfig>(
            get: { settings.settings.config(for: task) },
            set: { settings.settings.setConfig($0, for: task) }
        )
        let kinds = ProviderKind.allCases.filter { task == .transcribe ? $0.canTranscribe : $0.canChat }
            .filter { $0 != .riffado && !(task == .transcribe && $0 == .appleOnDevice) }
        return Section(task.label) {
            Picker("Provider", selection: Binding(
                get: { binding.wrappedValue.kind },
                set: { binding.wrappedValue = .preset($0, forTranscription: task == .transcribe) }
            )) {
                ForEach(kinds) { Text($0.label).tag($0) }
            }
            if binding.wrappedValue.kind.needsBaseURL {
                TextField("Base URL", text: binding.baseURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            if binding.wrappedValue.kind != .appleOnDevice {
                TextField(binding.wrappedValue.kind == .whisperKit ? "Model (tiny, base, small, large-v3-turbo)" : "Model",
                          text: binding.model)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            if binding.wrappedValue.kind.needsAPIKey && binding.wrappedValue.kind != .openRouter {
                SecureField("API key", text: Binding(
                    get: { keys[task] ?? "" },
                    set: { keys[task] = $0; Keychain.setString($0, for: task.keychainKey) }
                ))
            }
            if binding.wrappedValue.kind == .ollama {
                Text("Run Ollama on your PC or Mac and reach it over Tailscale (e.g. https://my-pc.tailnet.ts.net/v1). Set OLLAMA_HOST=0.0.0.0 on that machine.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var openRouterSection: some View {
        Section {
            if openRouterConnected {
                Label("Signed in to OpenRouter", systemImage: "checkmark.seal")
                Button("Sign out of OpenRouter", role: .destructive) {
                    Keychain.delete(AIRouter.openRouterKey)
                    openRouterConnected = false
                }
            } else {
                Button("Sign in with OpenRouter") {
                    Task {
                        do {
                            let key = try await OpenRouterSignIn.signIn(using: webAuth)
                            Keychain.setString(key, for: AIRouter.openRouterKey)
                            openRouterConnected = true
                        } catch {
                            message = errorMessage(error)
                        }
                    }
                }
            }
        } header: {
            Text("Sign in instead of an API key")
        } footer: {
            Text("Gives access to hundreds of models billed to your OpenRouter account. Pick \"OpenRouter (sign in)\" as a provider above.")
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
                        let ok = try await RiffadoClient(baseURL: settings.settings.riffadoURL, bearer: riffadoKey)
                            .connectPlaud(creds)
                        message = ok ? "Riffado is now connected to your Plaud account." : "Riffado didn't confirm the connection."
                    } catch { message = errorMessage(error) }
                }
            }
            .disabled(settings.settings.riffadoURL.isEmpty || !account.isConnected)
        } header: {
            Text("Riffado server (optional)")
        } footer: {
            Text("Shares the token you captured here with your self-hosted Riffado, so its web dashboard, scheduled sync and webhooks work on desktop too.")
        }
    }
}
