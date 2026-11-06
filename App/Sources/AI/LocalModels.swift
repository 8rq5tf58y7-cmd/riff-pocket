import Foundation
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers
import RiffCore

/// Open-weight models that run comfortably on an iPhone 16 (8 GB RAM), 4-bit MLX builds.
struct LocalModelInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let size: String
    let note: String
}

enum LocalModelCatalog {
    static let curated: [LocalModelInfo] = [
        .init(id: "mlx-community/Qwen3-1.7B-4bit", name: "Qwen3 1.7B", size: "≈1.0 GB", note: "Fast, good default"),
        .init(id: "mlx-community/gemma-3-1b-it-qat-4bit", name: "Gemma 3 1B", size: "≈0.8 GB", note: "Smallest and quickest"),
        .init(id: "mlx-community/Llama-3.2-3B-Instruct-4bit", name: "Llama 3.2 3B", size: "≈1.8 GB", note: "Balanced"),
        .init(id: "mlx-community/Phi-3.5-mini-instruct-4bit", name: "Phi-3.5 mini", size: "≈2.2 GB", note: "Strong reasoning"),
        .init(id: "mlx-community/Qwen3-4B-4bit", name: "Qwen3 4B", size: "≈2.3 GB", note: "Best quality that fits well"),
    ]

    static func name(for id: String) -> String {
        curated.first { $0.id == id }?.name ?? String(id.split(separator: "/").last ?? Substring(id))
    }
}

/// Keeps at most one MLX model in memory (an iPhone can't hold several).
actor MLXRuntime {
    static let shared = MLXRuntime()
    private var loadedId: String?
    private var container: ModelContainer?

    func container(for id: String, progress: @Sendable @escaping (Double) -> Void = { _ in }) async throws -> ModelContainer {
        if loadedId == id, let c = container { return c }
        container = nil
        loadedId = nil
        let c = try await #huggingFaceLoadModelContainer(
            configuration: ModelConfiguration(id: id),
            progressHandler: { p in progress(p.fractionCompleted) }
        )
        container = c
        loadedId = id
        return c
    }

    func unload() {
        container = nil
        loadedId = nil
    }
}

struct MLXChatModel: ChatModel {
    let modelId: String
    var displayName: String { LocalModelCatalog.name(for: modelId) }
    /// Generous for small models with 32k+ windows, but bounded by phone memory.
    var contextCharacterBudget: Int { 12_000 }

    func complete(_ messages: [ChatMessage], options: ChatOptions) async throws -> String {
        let container = try await MLXRuntime.shared.container(for: modelId)
        let instructions = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        let prompt = messages.filter { $0.role != .system }.map { m in
            m.role == .assistant ? "Assistant: \(m.content)" : m.content
        }.joined(separator: "\n\n")
        let session = ChatSession(
            container,
            instructions: instructions.isEmpty ? nil : instructions,
            generateParameters: GenerateParameters(maxTokens: options.maxTokens, temperature: Float(options.temperature ?? 0.6))
        )
        return Self.stripThinking(try await session.respond(to: prompt))
    }

    /// Qwen3 and similar models emit `<think>…</think>` reasoning before the answer.
    static func stripThinking(_ s: String) -> String {
        var out = s
        while let open = out.range(of: "<think>") {
            if let close = out.range(of: "</think>", range: open.upperBound..<out.endIndex) {
                out.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                out.removeSubrange(open.lowerBound..<out.endIndex)
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Which local models are on the phone, plus download progress for the UI.
@MainActor
final class MLXModelStore: ObservableObject {
    static let shared = MLXModelStore()
    private static let key = "mlx.downloaded"

    @Published private(set) var downloaded: Set<String>
    @Published private(set) var progress: [String: Double] = [:]
    @Published var lastError: String?

    private init() {
        downloaded = Set(UserDefaults.standard.stringArray(forKey: Self.key) ?? [])
    }

    func isDownloaded(_ id: String) -> Bool { downloaded.contains(id) }

    func download(_ id: String) async {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, progress[id] == nil else { return }
        progress[id] = 0
        lastError = nil
        do {
            _ = try await MLXRuntime.shared.container(for: id) { fraction in
                Task { @MainActor in MLXModelStore.shared.progress[id] = fraction }
            }
            downloaded.insert(id)
            save()
        } catch {
            lastError = "Couldn't load \(id): \(errorMessage(error))"
        }
        progress[id] = nil
    }

    /// Unloads and deletes the model's files (best effort: searches the app's cache/support folders).
    func delete(_ id: String) async {
        await MLXRuntime.shared.unload()
        let fm = FileManager.default
        let hfStyle = "models--" + id.replacingOccurrences(of: "/", with: "--")
        let roots = [URL.cachesDirectory, URL.applicationSupportDirectory, URL.documentsDirectory]
        for root in roots {
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for case let url as URL in walker {
                let path = url.path
                if url.lastPathComponent == hfStyle || path.hasSuffix("/" + id) {
                    try? fm.removeItem(at: url)
                    walker.skipDescendants()
                }
            }
        }
        downloaded.remove(id)
        save()
    }

    private func save() {
        UserDefaults.standard.set(Array(downloaded), forKey: Self.key)
    }
}
