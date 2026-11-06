import SwiftUI
import SwiftData
import RiffCore

/// Settings → Claude connector (claude.ai and the Claude iPhone app).
struct CloudSettingsView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var account: PlaudAccount
    @ObservedObject private var mirror = CloudMirror.shared
    @State private var url = ""
    @State private var key = ""
    @State private var working = false
    @State private var message: String?
    @State private var copied = false

    var body: some View {
        Form {
            if mirror.isConfigured {
                Section {
                    LabeledContent("Notes in Claude", value: "\(mirror.info.map { _ in "" } ?? "")\(mirror.lastPush != nil ? "Up to date" : "Not pushed yet")")
                    if let last = mirror.lastPush {
                        LabeledContent("Last update", value: last.formatted(date: .omitted, time: .shortened))
                    }
                    if let err = mirror.lastError { Text(err).font(.footnote).foregroundStyle(.red) }
                    Button("Update now", systemImage: "arrow.up.circle") {
                        Task { let n = await mirror.push(context: context); message = n == 0 ? "Everything was already up to date." : "Sent \(n) note\(n == 1 ? "" : "s")." }
                    }
                    .disabled(mirror.isPushing)
                } header: { SectionLabel("Mirror") } footer: {
                    Text("Titles, summaries, transcripts, folders and attachment text are sent after each sync. Audio stays on your iPhone.")
                }

                Section {
                    Text(mirror.connectorURL).font(Theme.mono).textSelection(.enabled)
                    Button(copied ? "Copied ✓" : "Copy connector URL", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = mirror.connectorURL
                        copied = true
                    }
                } header: { SectionLabel("Add to Claude") } footer: {
                    Text("On claude.ai: Customize → Connectors → Add custom connector → paste this URL → Connect, and enter your connector password. It then appears in the Claude iPhone app too. Turn on the Notion connector as well to save notes to Notion.")
                }

                Section {
                    if mirror.info?.plaudConnected == true {
                        Label("Claude can also read Plaud directly", systemImage: "checkmark.seal").foregroundStyle(Theme.success)
                    } else {
                        Button("Share Plaud sign-in with the connector", systemImage: "icloud.and.arrow.down") {
                            Task { await sharePlaud() }
                        }
                        .disabled(!account.isConnected || working)
                    }
                } header: { SectionLabel("Plaud (optional)") } footer: {
                    Text("Lets Claude list recordings that haven't reached your phone yet. Plaud may block cloud servers; your mirrored notes work either way. The sign-in is stored in your own Cloudflare account.")
                }

                Section {
                    Button("Disconnect", role: .destructive) { mirror.disconnect(context: context) }
                } footer: { if let message { Text(message) } }
            } else {
                Section {
                    Text("Deploy the connector to your free Cloudflare account once (see connector/README.md in the project), then enter its address and sync key here.")
                        .font(.subheadline)
                    TextField("https://riff-pocket-connector.you.workers.dev", text: $url)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.system(.footnote, design: .monospaced))
                    SecureField("Sync key (SYNC_KEY)", text: $key)
                    Button("Connect") { Task { await connect() } }
                        .disabled(working || url.isEmpty || key.count < 16)
                    if let message { Text(message).font(.footnote).foregroundStyle(.red) }
                } header: { SectionLabel("Your Claude connector") }
            }
        }
        .themedList()
        .navigationTitle("Claude connector")
        .disabled(working)
        .onAppear { url = settings.settings.cloudURL }
    }

    private func connect() async {
        working = true
        defer { working = false }
        message = nil
        do {
            try await mirror.configure(url: url, key: key)
            key = ""
            let n = await mirror.push(context: context)
            message = "Connected. Sent \(n) note\(n == 1 ? "" : "s")."
        } catch {
            message = errorMessage(error)
        }
    }

    private func sharePlaud() async {
        guard let creds = account.credentials else { return }
        working = true
        defer { working = false }
        do {
            try await mirror.sharePlaud(creds)
            message = "Shared. Claude can now list your Plaud recordings directly."
        } catch {
            message = errorMessage(error)
        }
    }
}
