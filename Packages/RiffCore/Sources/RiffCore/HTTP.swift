import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum HTTPError: Error, CustomStringConvertible {
    case invalidURL(String)
    case invalidResponse
    case status(Int, String)
    case decoding(String)

    public var description: String {
        switch self {
        case .invalidURL(let u): return "Invalid URL: \(u)"
        case .invalidResponse: return "No HTTP response"
        case .status(let code, let body): return "HTTP \(code): \(body)"
        case .decoding(let why): return "Could not read response: \(why)"
        }
    }
}

/// Tiny URLSession wrapper using completion handlers so it works on every
/// Foundation implementation (Apple, Windows, Linux).
public struct HTTPClient: @unchecked Sendable {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let task = session.dataTask(with: request) { data, response, error in
                if let error = error {
                    cont.resume(throwing: error)
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    cont.resume(throwing: HTTPError.invalidResponse)
                    return
                }
                let body = data ?? Data()
                guard (200..<300).contains(http.statusCode) else {
                    let text = String(decoding: body.prefix(2000), as: UTF8.self)
                    cont.resume(throwing: HTTPError.status(http.statusCode, text))
                    return
                }
                cont.resume(returning: body)
            }
            task.resume()
        }
    }

    public func sendJSON<T: Decodable>(_ request: URLRequest, as type: T.Type, decoder: JSONDecoder = JSONDecoder()) async throws -> T {
        let data = try await send(request)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            let preview = String(decoding: data.prefix(500), as: UTF8.self)
            throw HTTPError.decoding("\(error) — \(preview)")
        }
    }
}

public func makeURL(_ base: String, _ path: String) throws -> URL {
    var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
    while b.hasSuffix("/") { b.removeLast() }
    let p = path.hasPrefix("/") ? String(path.dropFirst()) : path
    guard let url = URL(string: p.isEmpty ? b : "\(b)/\(p)") else { throw HTTPError.invalidURL("\(b)/\(p)") }
    return url
}

/// multipart/form-data builder for audio uploads.
public struct MultipartForm {
    public let boundary: String
    private var body = Data()

    public init(boundary: String = "riff-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public mutating func addField(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data("\(value)\r\n".utf8))
    }

    public mutating func addFile(_ name: String, filename: String, mimeType: String, data: Data) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    public func finalized() -> Data {
        var out = body
        out.append(Data("--\(boundary)--\r\n".utf8))
        return out
    }
}

public func audioMimeType(forExtension ext: String) -> String {
    switch ext.lowercased() {
    case "mp3": return "audio/mpeg"
    case "m4a", "mp4", "aac": return "audio/mp4"
    case "wav": return "audio/wav"
    case "ogg", "opus": return "audio/ogg"
    case "webm": return "audio/webm"
    case "flac": return "audio/flac"
    default: return "application/octet-stream"
    }
}
