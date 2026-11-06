import Foundation
import SwiftData
import PDFKit
import Vision
import UIKit
import UniformTypeIdentifiers
import RiffCore

/// A file attached to a note. Its extracted text is used by Ask and Library chat.
@Model
final class NoteAttachment {
    @Attribute(.unique) var id: String
    var name: String
    var contentType: String
    var size: Int
    var fileName: String
    var addedAt: Date
    /// Text pulled out of the file (PDF text, document text, OCR for photos). nil = not extractable.
    var extractedText: String?
    var note: RecordingItem?

    init(id: String = UUID().uuidString, name: String, contentType: String, size: Int, fileName: String) {
        self.id = id
        self.name = name
        self.contentType = contentType
        self.size = size
        self.fileName = fileName
        self.addedAt = .now
    }

    /// Never the folder itself: attachments synced from the desktop may have no local file yet.
    var fileURL: URL { AttachmentStorage.directory.appendingPathComponent(fileName.isEmpty ? "missing-\(id)" : fileName) }
    var hasLocalFile: Bool { !fileName.isEmpty && FileManager.default.fileExists(atPath: fileURL.path) }

    var symbol: String {
        guard let type = UTType(contentType) else { return "doc" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .spreadsheet) || type.conforms(to: .commaSeparatedText) { return "tablecells" }
        return "doc.text"
    }

    var document: NoteDocument? {
        guard let t = extractedText, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return NoteDocument(name: name, text: t)
    }
}

enum AttachmentStorage {
    static var directory: URL {
        let dir = URL.documentsDirectory.appendingPathComponent("Attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Copies a picked file into app storage and extracts its text.
    static func importFile(from url: URL, into note: RecordingItem, context: ModelContext) async throws -> NoteAttachment {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let id = UUID().uuidString
        let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension
        let dest = directory.appendingPathComponent("\(id).\(ext)")
        try FileManager.default.copyItem(at: url, to: dest)
        let type = UTType(filenameExtension: ext) ?? .data
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
        let att = NoteAttachment(id: id, name: url.lastPathComponent, contentType: type.identifier, size: size,
                                 fileName: dest.lastPathComponent)
        att.extractedText = await TextExtractor.text(from: dest, type: type)
        att.note = note
        context.insert(att)
        try context.save()
        return att
    }

    /// Saves image data (from the photo picker) as an attachment.
    static func importImage(_ data: Data, into note: RecordingItem, context: ModelContext) async throws -> NoteAttachment {
        let id = UUID().uuidString
        let dest = directory.appendingPathComponent("\(id).jpg")
        try data.write(to: dest)
        let att = NoteAttachment(id: id, name: "Photo \(Date.now.formatted(date: .abbreviated, time: .shortened)).jpg",
                                 contentType: UTType.jpeg.identifier, size: data.count, fileName: dest.lastPathComponent)
        att.extractedText = await TextExtractor.text(from: dest, type: .jpeg)
        att.note = note
        context.insert(att)
        try context.save()
        return att
    }

    static func delete(_ att: NoteAttachment, context: ModelContext) {
        if att.hasLocalFile { try? FileManager.default.removeItem(at: att.fileURL) }
        context.delete(att)
        try? context.save()
    }
}

/// Pulls readable text out of common file types, entirely on device.
enum TextExtractor {
    static let maxCharacters = 200_000

    static func text(from url: URL, type: UTType) async -> String? {
        let raw: String?
        if type.conforms(to: .pdf) {
            raw = pdfText(url)
        } else if type.conforms(to: .image) {
            raw = await ocr(url)
        } else if type.conforms(to: .rtf) || type.conforms(to: .html) || type.conforms(to: .rtfd) {
            raw = attributedText(url, type: type)
        } else if type.conforms(to: .text) || type.conforms(to: .json) || type.conforms(to: .commaSeparatedText)
                    || ["md", "markdown", "txt", "csv", "tsv", "log", "srt", "vtt"].contains(url.pathExtension.lowercased()) {
            raw = try? String(contentsOf: url, encoding: .utf8)
        } else {
            raw = nil // e.g. .docx/.pages: export to PDF to include the text
        }
        guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return String(t.prefix(maxCharacters))
    }

    private static func pdfText(_ url: URL) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        var pages: [String] = []
        for i in 0..<doc.pageCount {
            if let s = doc.page(at: i)?.string, !s.isEmpty { pages.append(s) }
        }
        return pages.joined(separator: "\n\n")
    }

    private static func attributedText(_ url: URL, type: UTType) -> String? {
        let docType: NSAttributedString.DocumentType = type.conforms(to: .html) ? .html : .rtf
        return try? NSAttributedString(url: url, options: [.documentType: docType], documentAttributes: nil).string
    }

    /// On-device text recognition (photos of whiteboards, slides, receipts…).
    private static func ocr(_ url: URL) async -> String? {
        guard let image = UIImage(contentsOfFile: url.path)?.cgImage else { return nil }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                // perform(_:) is synchronous: the handler has run by the time it returns.
                var lines: [String] = []
                let request = VNRecognizeTextRequest { req, _ in
                    lines = (req.results as? [VNRecognizedTextObservation])?
                        .compactMap { $0.topCandidates(1).first?.string } ?? []
                }
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                try? VNImageRequestHandler(cgImage: image).perform([request])
                cont.resume(returning: lines.isEmpty ? nil : lines.joined(separator: "\n"))
            }
        }
    }
}
