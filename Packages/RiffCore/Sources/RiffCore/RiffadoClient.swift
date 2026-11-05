import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Optional: hand the Plaud token captured on the phone to a self-hosted Riffado server,
/// so its web UI, scheduled sync and webhooks work for desktop too.
///
/// Both endpoints below exist in Riffado's source:
/// - `GET  /api/health`
/// - `POST /api/plaud/auth/connect-token` `{ accessToken, apiBase, source }`
///
/// connect-token requires a Riffado session (`requireApiSession`). Pass either the
/// session cookie (from signing in to Riffado in a web view) or, if your Riffado
/// version accepts API keys there, a bearer key.
public struct RiffadoClient: Sendable {
    public var baseURL: String
    public var bearer: String?
    public var cookieHeader: String?
    private let http: HTTPClient

    public init(baseURL: String, bearer: String? = nil, cookieHeader: String? = nil, http: HTTPClient = HTTPClient()) {
        self.baseURL = baseURL
        self.bearer = bearer
        self.cookieHeader = cookieHeader
        self.http = http
    }

    private func request(_ path: String, method: String = "GET") throws -> URLRequest {
        var req = URLRequest(url: try makeURL(baseURL, path))
        req.httpMethod = method
        if let b = bearer, !b.isEmpty { req.setValue("Bearer \(b)", forHTTPHeaderField: "Authorization") }
        if let c = cookieHeader, !c.isEmpty { req.setValue(c, forHTTPHeaderField: "Cookie") }
        return req
    }

    public func health() async throws -> Bool {
        _ = try await http.send(try request("api/health"))
        return true
    }

    public struct ConnectResult: Decodable, Sendable {
        public var success: Bool?
    }

    public func connectPlaud(_ credentials: PlaudCredentials) async throws -> Bool {
        var req = try request("api/plaud/auth/connect-token", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "accessToken": credentials.userToken,
            "apiBase": credentials.apiBase,
            "source": "connector",
        ])
        return try await http.sendJSON(req, as: ConnectResult.self).success ?? false
    }
}
