import SwiftUI
import RiffCore

struct PlaudConnectView: View {
    @EnvironmentObject private var account: PlaudAccount
    @Environment(\.dismiss) private var dismiss

    enum Method: String, CaseIterable, Identifiable {
        case web = "Apple / web"
        case email = "Email code"
        case paste = "Paste token"
        var id: String { rawValue }
    }

    @State private var method: Method = .web
    @State private var region: PlaudRegion = .global
    @State private var desktopMode = false
    @State private var showWeb = false
    @State private var email = ""
    @State private var code = ""
    @State private var pending: PlaudEmailLogin.Pending?
    @State private var pasted = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Method", selection: $method) {
                        ForEach(Method.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                switch method {
                case .web: webSection
                case .email: emailSection
                case .paste: pasteSection
                }

                Section("Server region") {
                    Picker("Region", selection: $region) {
                        ForEach(PlaudRegion.allCases) { Text($0.label).tag($0) }
                    }
                    Text("If sign-in works but no recordings appear, try another region. Riff Pocket also tries each region automatically.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .themedList()
            .disabled(working)
            .overlay { if working { ProgressView("Connecting…").padding().background(.regularMaterial, in: .rect(cornerRadius: 12)) } }
            .navigationTitle("Connect Plaud")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .fullScreenCover(isPresented: $showWeb) { webSheet }
        }
    }

    // MARK: Sections

    private var webSection: some View {
        Section {
            Button {
                error = nil
                showWeb = true
            } label: {
                Label("Sign in on Plaud's website", systemImage: "apple.logo")
            }
            Toggle("Desktop site", isOn: $desktopMode)
        } header: {
            Text("Apple accounts (recommended)")
        } footer: {
            Text("Opens web.plaud.ai inside the app. Tap \"Continue with Apple\" and sign in as usual — Apple handles your password. Riff Pocket then captures your Plaud account token, the same one Riffado's Connector uses, and keeps it in the Keychain. Turn on Desktop site if the page only offers an app download. Google accounts: Google blocks in-app sign-in, so use Paste token.")
        }
    }

    private var emailSection: some View {
        Section {
            if pending == nil {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                Button("Send code") { Task { await sendCode() } }.disabled(!email.contains("@"))
            } else {
                TextField("6-digit code", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode)
                Button("Verify") { Task { await verifyCode() } }.disabled(code.count < 4)
                Button("Use a different email", role: .cancel) { pending = nil; code = "" }
            }
        } header: {
            Text("Email accounts only")
        } footer: {
            Text("Only for Plaud accounts created with email + password. If you signed up with Apple or Google this signs into a separate, empty account — use Apple / web instead.")
        }
    }

    private var pasteSection: some View {
        Section {
            TextField("eyJ…", text: $pasted, axis: .vertical)
                .lineLimit(3...6).font(.footnote.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Connect") { Task { await finish(pasted) } }.disabled(pasted.count < 20)
        } header: {
            Text("Paste account token")
        } footer: {
            Text("On a computer: sign in at web.plaud.ai → Developer Tools → Application → Local Storage → copy the value of pld_tokenstr. Don't copy the Authorization header from /device/list or /file requests — that's a workspace token that expires in about a day.")
        }
    }

    private var webSheet: some View {
        NavigationStack {
            PlaudWebLoginView(
                startURL: URL(string: region == .china ? "https://web.plaud.cn" : "https://web.plaud.ai")!,
                desktopMode: desktopMode
            ) { token in
                showWeb = false
                Task { await finish(token) }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Sign in to Plaud")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showWeb = false } } }
        }
    }

    // MARK: Actions

    private func finish(_ token: String) async {
        working = true
        defer { working = false }
        error = nil
        do {
            try await account.connect(token: token, preferred: region)
            dismiss()
        } catch {
            self.error = errorMessage(error)
        }
    }

    private func sendCode() async {
        working = true
        defer { working = false }
        error = nil
        do {
            pending = try await PlaudEmailLogin().sendCode(email: email.trimmingCharacters(in: .whitespaces), apiBase: region.apiBase)
        } catch {
            self.error = errorMessage(error)
        }
    }

    private func verifyCode() async {
        guard let pending else { return }
        working = true
        defer { working = false }
        error = nil
        do {
            let token = try await PlaudEmailLogin().verify(code: code.trimmingCharacters(in: .whitespaces), pending: pending)
            try await account.connect(token: token, apiBase: pending.apiBase)
            dismiss()
        } catch {
            self.error = errorMessage(error)
        }
    }
}
