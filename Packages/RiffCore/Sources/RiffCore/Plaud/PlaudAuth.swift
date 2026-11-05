// Swift port of Riffado's src/lib/plaud/auth.ts (AGPL-3.0).
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Unverified JWT claim reading — UX hints only, never for authorization (Plaud verifies).
public enum PlaudJWT {
    public static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    public static func expiry(_ token: String) -> Date? {
        guard let exp = jsonNumber(claims(token)?["exp"]) else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// Workspace tokens (WT) carry `ut_ref` / `wid`; long-lived user tokens (UT) don't. (Riffado #203)
    public static func isWorkspaceToken(_ token: String) -> Bool {
        guard let c = claims(token) else { return false }
        return c["ut_ref"] is String || c["wid"] is String
    }

    /// Normalises a pasted/captured token and rejects the known-bad shapes before any network call.
    public static func validateShape(_ raw: String, now: Date = Date()) throws -> String {
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.lowercased().hasPrefix("bearer ") { token = String(token.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        // localStorage values are sometimes JSON-quoted.
        if token.hasPrefix("\""), token.hasSuffix("\""), token.count > 2 { token = String(token.dropFirst().dropLast()) }
        guard token.split(separator: ".", omittingEmptySubsequences: false).count == 3 else { throw PlaudError.notAToken }
        if isWorkspaceToken(token) { throw PlaudError.workspaceTokenPasted }
        if let exp = expiry(token), exp < now { throw PlaudError.expired(exp) }
        return token
    }
}

/// Email one-time-code sign-in. Only for accounts created with email —
/// Apple/Google accounts get an empty shadow account this way (Riffado #65); use the web login instead.
public struct PlaudEmailLogin: Sendable {
    private let http: HTTPClient

    public init(http: HTTPClient = HTTPClient()) {
        self.http = http
    }

    public struct Pending: Sendable, Hashable {
        public let otpToken: String
        public let apiBase: String
    }

    private struct SendCodeResponse: Decodable {
        struct DataField: Decodable {
            struct Domains: Decodable { var api: String? }
            var domains: Domains?
        }
        var status: Int?
        var msg: String?
        var token: String?
        var data: DataField?
    }

    private struct LoginResponse: Decodable {
        struct DataField: Decodable { var access_token: String? }
        var status: Int?
        var msg: String?
        var access_token: String?
        var data: DataField?
    }

    private func post(_ base: String, _ path: String, json: [String: String]) throws -> URLRequest {
        var req = URLRequest(url: try makeURL(base, path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(PlaudClient.userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: json)
        return req
    }

    /// Follows Plaud's regional redirect (`status == -302` → `data.domains.api`).
    public func sendCode(email: String, apiBase: String = PlaudRegion.global.apiBase) async throws -> Pending {
        var base = apiBase
        for _ in 0..<4 {
            let resp = try await http.sendJSON(try post(base, "auth/otp-send-code", json: ["username": email]),
                                               as: SendCodeResponse.self)
            if resp.status == -302, let next = resp.data?.domains?.api {
                let nextBase = next.trimmingTrailingSlashes()
                guard PlaudRegion.isValidAPIBase(nextBase) else { throw PlaudError.invalidAPIBase(nextBase) }
                base = nextBase
                continue
            }
            guard resp.status == 0, let token = resp.token else {
                throw PlaudError.api(status: resp.status ?? -1, message: resp.msg ?? "Failed to send verification code")
            }
            return Pending(otpToken: token, apiBase: base)
        }
        throw PlaudError.upstream("Too many region redirects")
    }

    public func verify(code: String, pending: Pending) async throws -> String {
        let resp = try await http.sendJSON(
            try post(pending.apiBase, "auth/otp-login", json: ["code": code, "token": pending.otpToken]),
            as: LoginResponse.self)
        guard let token = resp.access_token ?? resp.data?.access_token else {
            throw PlaudError.api(status: resp.status ?? -1, message: resp.msg ?? "Invalid verification code")
        }
        return token
    }
}
