import SwiftUI
import SwiftData
import RiffCore

/// Settings → Desktop companion.
struct DeskSettingsView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var account: PlaudAccount
    @ObservedObject private var desk = DeskSync.shared
    @State private var link = ""
    @State private var working = false
    @State private var message: String?

    var body: some View {
        Form {
            if desk.isPaired {
                Section {
                    LabeledContent("Computer", value: desk.info?.name ?? "—")
                    LabeledContent("Address") { Text(settings.settings.deskURL).font(Theme.mono) }
                    if let last = desk.lastSync {
                        LabeledContent("Last sync", value: last.formatted(date: .omitted, time: .shortened))
                    }
                    if desk.info?.processing == true { ThinkingIndicator(label: "Riff Desk is processing") }
                    if let err = desk.lastError { Text(err).font(.footnote).foregroundStyle(.red) }
                    Button("Sync now", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await desk.sync(context: context) }
                    }
                    .disabled(desk.isSyncing)
                } header: { SectionLabel("Paired") }

                Section {
                    if desk.info?.plaudConnected == true {
                        Label("Riff Desk is syncing your Plaud recordings", systemImage: "checkmark.seal")
                            .foregroundStyle(Theme.success)
                    } else {
                        Button("Let the desktop sync Plaud", systemImage: "icloud.and.arrow.down") {
                            Task { await sharePlaud() }
                        }
                        .disabled(!account.isConnected || working)
                    }
                } header: { SectionLabel("Process while your phone sleeps") } footer: {
                    Text("Riff Desk pulls new Plaud recordings itself and transcribes, summarizes and names them on your computer. Your iPhone then only downloads the results — even in the background. The Plaud sign-in is sent to your computer only.")
                }

                Section {
                    Button("Send my summary format & automation settings") {
                        Task {
                            do { try await desk.pushSettings(); message = "Riff Desk now uses your default template and automation settings." }
                            catch { message = errorMessage(error) }
                        }
                    }
                    Button("Unpair", role: .destructive) { desk.unpair() }
                } footer: {
                    if let message { Text(message) }
                }
            } else {
                Section {
                    Text("1. On your computer, run Riff Desk and open **Settings & pairing**.\n2. Point the iPhone **Camera** at the QR code and tap the link — or copy the pairing link and paste it below.\n3. Keep the phone and computer on the same Wi-Fi (or both on Tailscale).")
                        .font(.subheadline)
                    TextField("riffpocket://pair?url=…", text: $link, axis: .vertical)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Pair") { Task { await pair() } }
                        .disabled(working || DeskPairing.parse(link) == nil)
                    if let message { Text(message).font(.footnote).foregroundStyle(.red) }
                } header: { SectionLabel("Pair with Riff Desk") } footer: {
                    Text("Riff Desk is the free desktop companion in this project's desktop/ folder. It runs on Windows, macOS or Linux with Python 3.10+.")
                }
            }
        }
        .themedList()
        .navigationTitle("Desktop companion")
        .disabled(working)
        .task { if desk.isPaired { await desk.sync(context: context) } }
    }

    private func pair() async {
        working = true
        defer { working = false }
        message = nil
        do {
            let info = try await desk.pair(link: link)
            link = ""
            message = nil
            _ = info
            await desk.sync(context: context)
        } catch {
            message = errorMessage(error)
        }
    }

    private func sharePlaud() async {
        guard let creds = account.credentials else { return }
        working = true
        defer { working = false }
        do {
            try await desk.shareAccount(creds)
            message = "Riff Desk will now check Plaud for new recordings."
        } catch {
            message = errorMessage(error)
        }
    }
}
