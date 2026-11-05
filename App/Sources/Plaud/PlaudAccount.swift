import Foundation
import RiffCore

/// The connected Plaud account: credentials in the Keychain, devices, expiry state.
@MainActor
final class PlaudAccount: ObservableObject {
    private static let keychainKey = "plaud.credentials"

    @Published private(set) var credentials: PlaudCredentials?
    @Published var devices: [PlaudDevice] = []
    /// Set when Plaud returns 401 — the UI shows a Reconnect banner.
    @Published var needsReconnect = false

    init() {
        if let data = Keychain.data(Self.keychainKey) {
            credentials = try? JSONDecoder().decode(PlaudCredentials.self, from: data)
        }
    }

    var isConnected: Bool { credentials != nil }

    var region: PlaudRegion? { credentials.flatMap { PlaudRegion.from(apiBase: $0.apiBase) } }

    /// Warn two weeks ahead: Plaud user tokens last ~300 days and have no refresh token.
    var expiryWarning: String? {
        guard let exp = credentials?.expiresAt else { return nil }
        let days = Calendar.current.dateComponents([.day], from: .now, to: exp).day ?? 0
        if days < 0 { return "Your Plaud sign-in expired. Reconnect to keep syncing." }
        if days <= 14 { return "Your Plaud sign-in expires in \(days) day\(days == 1 ? "" : "s")." }
        return nil
    }

    func makeClient() -> PlaudClient? {
        credentials.map { PlaudClient(credentials: $0) }
    }

    /// Validates (rejects workspace tokens, checks /device/list) and stores the token.
    func connect(token: String, preferred region: PlaudRegion?) async throws {
        let (creds, devices) = try await PlaudClient.connectDetectingRegion(token: token, preferred: region)
        store(creds)
        self.devices = devices
    }

    /// Email-code accounts already know their regional API base from the -302 redirect.
    func connect(token: String, apiBase: String) async throws {
        let (creds, devices) = try await PlaudClient.connect(token: token, apiBase: apiBase)
        store(creds)
        self.devices = devices
    }

    func refreshDevices() async {
        guard let client = makeClient() else { return }
        do {
            devices = try await client.listDevices()
        } catch PlaudError.invalidToken {
            needsReconnect = true
        } catch {}
    }

    func disconnect() {
        Keychain.delete(Self.keychainKey)
        credentials = nil
        devices = []
        needsReconnect = false
    }

    private func store(_ creds: PlaudCredentials) {
        if let data = try? JSONEncoder().encode(creds) { Keychain.set(data, for: Self.keychainKey) }
        credentials = creds
        needsReconnect = false
    }
}
