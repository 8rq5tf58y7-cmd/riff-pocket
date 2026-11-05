import Foundation
import AuthenticationServices
import CryptoKit
import SwiftUI

/// "Sign in" instead of pasting a key: OpenRouter's OAuth PKCE flow returns a user-owned API key.
enum OpenRouterSignIn {
    enum Failure: LocalizedError {
        case noCode, noKey
        var errorDescription: String? {
            switch self {
            case .noCode: return "OpenRouter didn't return an authorization code."
            case .noKey: return "OpenRouter didn't return an API key."
            }
        }
    }

    @MainActor
    static func signIn(using session: WebAuthenticationSession) async throws -> String {
        let verifier = randomVerifier()
        let challenge = base64url(Data(SHA256.hash(data: Data(verifier.utf8))))

        var comps = URLComponents(string: "https://openrouter.ai/auth")!
        comps.queryItems = [
            URLQueryItem(name: "callback_url", value: "riffpocket://openrouter"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        let callback = try await session.authenticate(using: comps.url!, callbackURLScheme: "riffpocket")
        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else { throw Failure.noCode }

        var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/auth/keys")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": code, "code_verifier": verifier, "code_challenge_method": "S256",
        ])
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = obj["key"] as? String else { throw Failure.noKey }
        return key
    }

    private static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64url(Data(bytes))
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
