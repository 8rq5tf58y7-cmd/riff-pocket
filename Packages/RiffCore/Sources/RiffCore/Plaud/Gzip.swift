import Foundation
#if canImport(Compression)
import Compression
#endif

/// Minimal gzip reader for Plaud's presigned content (`trans_result.json.gz`).
/// Uses Apple's Compression framework (raw DEFLATE) — available on iOS/macOS.
enum Gzip {
    enum Failure: Error { case unsupportedPlatform, malformed }

    static func isGzip(_ d: Data) -> Bool {
        d.count > 18 && d[d.startIndex] == 0x1F && d[d.startIndex + 1] == 0x8B
    }

    static func decompress(_ data: Data) throws -> Data {
        #if canImport(Compression)
        let b = [UInt8](data)
        guard b.count > 18, b[2] == 8 else { throw Failure.malformed } // 8 = DEFLATE
        let flags = b[3]
        var i = 10
        if flags & 0x04 != 0 { i += 2 + (Int(b[i]) | Int(b[i + 1]) << 8) }      // FEXTRA
        if flags & 0x08 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 } // FNAME
        if flags & 0x10 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 } // FCOMMENT
        if flags & 0x02 != 0 { i += 2 }                                          // FHCRC
        guard i < b.count - 8 else { throw Failure.malformed }
        let deflate = Array(b[i..<(b.count - 8)])
        let n = b.count
        let isize = Int(b[n - 4]) | Int(b[n - 3]) << 8 | Int(b[n - 2]) << 16 | Int(b[n - 1]) << 24
        var capacity = max(isize + 1, deflate.count * 4, 64 * 1024)
        for _ in 0..<6 {
            var dst = [UInt8](repeating: 0, count: capacity)
            let written = compression_decode_buffer(&dst, capacity, deflate, deflate.count, nil, COMPRESSION_ZLIB)
            if written == 0 { throw Failure.malformed }
            if written < capacity { return Data(dst[0..<written]) }
            capacity *= 4
        }
        throw Failure.malformed
        #else
        throw Failure.unsupportedPlatform
        #endif
    }
}
