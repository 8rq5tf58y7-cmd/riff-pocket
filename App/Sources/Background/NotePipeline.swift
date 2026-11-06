import Foundation
import SwiftData
import BackgroundTasks
import UIKit
import RiffCore

/// One note's journey: transcribe → summarize (in its style) → AI title (Plaud-style) → optional rename in Plaud.
@MainActor
enum NotePipeline {
    struct Steps: OptionSet, Hashable {
        let rawValue: Int
        static let transcribe = Steps(rawValue: 1)
        static let summarize = Steps(rawValue: 2)
        static let title = Steps(rawValue: 4)
        static let all: Steps = [.transcribe, .summarize, .title]
    }

    struct Outcome {
        var transcribed = false
        var summarized = false
        var renamed = false
        var waitingForForeground = false
        var didAnything: Bool { transcribed || summarized || renamed }
    }

    /// - Parameters:
    ///   - force: redo steps even if the note already has a transcript/summary.
    ///   - inBackground: skip work iOS forbids in the background (GPU-bound on-iPhone LLMs).
    static func process(_ rec: RecordingItem, steps: Steps = .all, force: Steps = [],
                        style: SummaryStyle? = nil, summaryConfig: ProviderConfig? = nil,
                        context: ModelContext, inBackground: Bool,
                        onStep: (String) -> Void = { _ in }) async throws -> Outcome {
        let s = SettingsStore.shared.settings
        var out = Outcome()

        // 1. Transcribe
        if steps.contains(.transcribe), rec.transcript == nil || force.contains(.transcribe), rec.hasAudioFile {
            onStep("Transcribing")
            let transcriber = try AIRouter.transcriber(for: s.transcribe)
            let url = rec.audioURL
            rec.transcript = try await transcriber.transcribe(fileURL: url, language: s.language.isEmpty ? nil : s.language)
            rec.transcriptSource = transcriber.displayName
            out.transcribed = true
            try? context.save()
        }

        let chatConfig = summaryConfig ?? s.summarize
        let gpuBlocked = inBackground && chatConfig.kind == .mlx
        guard let transcript = rec.transcript, !transcript.segments.isEmpty else { return out }

        // 2. Summarize
        if steps.contains(.summarize), rec.summary == nil || force.contains(.summarize) {
            if gpuBlocked { out.waitingForForeground = true; return out }
            onStep("Summarizing")
            let chosen = style ?? rec.summaryStyle ?? s.defaultStyle
            let model = try AIRouter.chatModel(for: chatConfig, task: .summarize)
            rec.summary = try await Summarizer(model: model).summarize(transcript, style: chosen)
            rec.summarySource = model.displayName
            rec.summaryStyle = chosen
            out.summarized = true
            try? context.save()
        }

        // 3. Title (only when allowed: not hand-named; placeholders always, others if "always rename")
        let wantsTitle = steps.contains(.title) && s.autoTitle && !rec.titleLocked
            && (out.summarized || force.contains(.title) || NoteTitle.isPlaceholder(rec.title))
            && (s.retitleNamedNotes || NoteTitle.isPlaceholder(rec.title) || force.contains(.title) || rec.source != "plaud")
        if wantsTitle, !gpuBlocked {
            onStep("Naming")
            let model = try AIRouter.chatModel(for: chatConfig, task: .summarize)
            if let title = try await Summarizer(model: model).title(summary: rec.summary, transcript: transcript),
               title != rec.title {
                rec.title = title
                out.renamed = true
                try? context.save()
                // 4. Mirror the name in Plaud if asked.
                if s.renameInPlaud, let pid = rec.plaudId, let client = PlaudAccount().makeClient() {
                    try? await client.rename(fileId: pid, to: title)
                }
            }
        }
        return out
    }
}

/// Queue of notes to process, run as an iOS 26 "continued processing" task:
/// started by a tap, it keeps going after you leave the app (with a system progress Live Activity).
@MainActor
final class Pipeline: ObservableObject {
    static let shared = Pipeline()
    static let taskId = "io.github.riffpocket.app.pipeline"

    struct Job: Hashable {
        let noteId: UUID
        var steps: NotePipeline.Steps = .all
        var force: NotePipeline.Steps = []
        var style: SummaryStyle?
        var summaryConfig: ProviderConfig?

        static func == (a: Job, b: Job) -> Bool { a.noteId == b.noteId }
        func hash(into h: inout Hasher) { h.combine(noteId) }
    }

    @Published private(set) var activeNoteId: UUID?
    @Published private(set) var stepLabel: String?
    @Published private(set) var queued: [UUID] = []
    @Published var lastError: String?

    private var jobs: [Job] = []
    private var running = false
    private var container: ModelContainer?

    func register(container: ModelContainer) {
        self.container = container
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskId, using: nil) { task in
            Task { @MainActor in await Pipeline.shared.runAsSystemTask(task as? BGContinuedProcessingTask) }
        }
    }

    func isBusy(_ id: UUID) -> Bool { activeNoteId == id || queued.contains(id) }
    var isRunning: Bool { running }

    /// Call from a user action (button, pull-to-refresh). Keeps running if the app is backgrounded.
    func start(_ newJobs: [Job]) {
        for j in newJobs where !jobs.contains(j) && activeNoteId != j.noteId { jobs.append(j) }
        queued = jobs.map(\.noteId)
        guard !running, !jobs.isEmpty else { return }
        running = true
        let req = BGContinuedProcessingTaskRequest(
            identifier: Self.taskId,
            title: "Processing notes",
            subtitle: "\(jobs.count) note\(jobs.count == 1 ? "" : "s") queued"
        )
        req.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(req)
        } catch {
            // Not available (or refused): run now, with the usual extra time if you leave the app.
            Task { _ = await BackgroundWork.withExtendedTime("Process notes") { await self.runLoop(task: nil) } }
        }
    }

    func start(ids: [UUID]) { start(ids.map { Job(noteId: $0) }) }

    private func runAsSystemTask(_ task: BGContinuedProcessingTask?) async {
        guard let task else { return }
        let work = Task { @MainActor in await self.runLoop(task: task) }
        task.expirationHandler = { work.cancel() }
        let ok = await work.value
        task.setTaskCompleted(success: ok)
    }

    private func runLoop(task: BGContinuedProcessingTask?) async -> Bool {
        defer {
            running = false
            activeNoteId = nil
            stepLabel = nil
        }
        guard let context = container?.mainContext else { return false }
        var total = jobs.count, done = 0, ready = 0, waiting = 0
        task?.progress.totalUnitCount = Int64(max(total, 1) * 3)

        while !jobs.isEmpty {
            if Task.isCancelled { break }
            let job = jobs.removeFirst()
            queued = jobs.map(\.noteId)
            total = max(total, done + jobs.count + 1)
            task?.progress.totalUnitCount = Int64(total * 3)
            let id = job.noteId
            guard let rec = try? context.fetch(FetchDescriptor<RecordingItem>(predicate: #Predicate { $0.id == id })).first else {
                done += 1
                continue
            }
            activeNoteId = rec.id
            task?.updateTitle("Processing “\(rec.title)”", subtitle: "\(done + 1) of \(total)")
            let inBackground = UIApplication.shared.applicationState == .background
            do {
                let out = try await NotePipeline.process(
                    rec, steps: job.steps, force: job.force, style: job.style, summaryConfig: job.summaryConfig,
                    context: context, inBackground: inBackground
                ) { [weak self] step in
                    self?.stepLabel = step
                    task?.progress.completedUnitCount += 1
                }
                if out.didAnything { ready += 1 }
                if out.waitingForForeground { waiting += 1 }
                rec.autoProcessFailures = 0
            } catch {
                if Task.isCancelled { break }
                rec.autoProcessFailures += 1
                lastError = "“\(rec.title)”: \(errorMessage(error))"
            }
            try? context.save()
            done += 1
            task?.progress.completedUnitCount = Int64(done * 3)
        }

        if ready > 0 { await CloudMirror.shared.push(context: context) } // new summaries/titles → Claude
        if UIApplication.shared.applicationState != .active, ready + waiting > 0 {
            let body = waiting > 0
                ? "\(ready) ready. \(waiting) waiting for you to open the app (on-iPhone model)."
                : "Transcripts, summaries and titles are ready."
            await Notifier.post(title: ready == 1 ? "Your note is ready" : "\(ready) notes are ready", body: body)
        }
        return !Task.isCancelled
    }
}
