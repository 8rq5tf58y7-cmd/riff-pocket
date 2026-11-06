import Foundation
import SwiftData
import BackgroundTasks
import UserNotifications
import UIKit
import RiffCore

/// Work the app does while you're not using it.
///
/// iOS never lets an app run continuously in the background. Instead:
/// - **Refresh** (`BGAppRefreshTask`): iOS wakes the app every so often (it decides when, based on
///   how you use the app) to sync new Plaud recordings and notify you.
/// - **Processing** (`BGProcessingTask`): when the phone is idle — optionally only while charging —
///   new notes are transcribed and summarized automatically.
/// - **Extra time**: work you started (transcribe, summarize, sync) keeps going for a while after
///   you leave the app.
/// - **Catch-up**: anything left over runs when you open the app again.
///
/// iOS doesn't allow GPU work in the background, so on-iPhone MLX summaries wait for the foreground.
@MainActor
enum BackgroundWork {
    static let refreshId = "io.github.riffpocket.app.refresh"
    static let processId = "io.github.riffpocket.app.process"
    private static var processing = false

    // MARK: Registration & scheduling

    /// Must run before the app finishes launching (called from the App initializer).
    static func register(container: ModelContainer) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshId, using: nil) { task in
            Task { @MainActor in
                scheduleRefresh()
                let work = Task { @MainActor in await runRefresh(container: container) }
                task.expirationHandler = { work.cancel() }
                await work.value
                task.setTaskCompleted(success: !work.isCancelled)
            }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processId, using: nil) { task in
            Task { @MainActor in
                let work = Task { @MainActor in
                    await processPending(context: container.mainContext, inBackground: true)
                }
                task.expirationHandler = { work.cancel() }
                await work.value
                task.setTaskCompleted(success: !work.isCancelled)
            }
        }
    }

    /// Called when the app goes to the background.
    static func scheduleAll(context: ModelContext) {
        scheduleRefresh()
        if hasPendingWork(context: context) { scheduleProcessing() }
    }

    static func scheduleRefresh() {
        guard SettingsStore.shared.settings.backgroundSync else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshId)
            return
        }
        let req = BGAppRefreshTaskRequest(identifier: refreshId)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    static func scheduleProcessing() {
        let s = SettingsStore.shared.settings
        guard s.autoTranscribe || s.autoSummarize else { return }
        let req = BGProcessingTaskRequest(identifier: processId)
        req.requiresExternalPower = s.processOnlyWhileCharging
        req.requiresNetworkConnectivity = true
        req.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    // MARK: Refresh: sync from Plaud

    private static func runRefresh(container: ModelContainer) async {
        let context = container.mainContext
        let account = PlaudAccount()
        guard SettingsStore.shared.settings.backgroundSync else { return }
        let before = (try? context.fetchCount(FetchDescriptor<RecordingItem>())) ?? 0
        if account.isConnected {
            await SyncService().sync(account: account, context: context,
                                     usePlaudContent: SettingsStore.shared.settings.preferPlaudContent)
        }
        // The desktop companion may have transcribed, summarized and named notes while we slept.
        let updatedByDesk = await DeskSync.shared.sync(context: context)
        let added = ((try? context.fetchCount(FetchDescriptor<RecordingItem>())) ?? 0) - before
        if updatedByDesk > max(added, 0) {
            await Notifier.post(title: "Your notes are ready",
                                body: "Riff Desk finished \(updatedByDesk - max(added, 0)) note\(updatedByDesk - max(added, 0) == 1 ? "" : "s") while you were away.")
        }
        if added > 0 {
            await Notifier.post(title: "\(added) new recording\(added == 1 ? "" : "s")",
                                body: "Synced from your Plaud account.")
            if hasPendingWork(context: context) { scheduleProcessing() }
        }
        if account.needsReconnect {
            await Notifier.post(title: "Reconnect Plaud", body: "Your Plaud sign-in expired, so new recordings can't sync.")
        }
    }

    // MARK: Processing: auto-transcribe and summarize

    static func candidates(context: ModelContext) -> [RecordingItem] {
        let s = SettingsStore.shared.settings
        let all = (try? context.fetch(FetchDescriptor<RecordingItem>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        return all.filter { r in
            guard r.autoProcessFailures < 2 else { return false }
            return (s.autoTranscribe && r.transcriptData == nil && r.hasAudioFile)
                || (s.autoSummarize && r.transcriptData != nil && r.summary == nil)
        }
    }

    static func hasPendingWork(context: ModelContext) -> Bool {
        !candidates(context: context).isEmpty
    }

    /// Transcribes, summarizes and names notes that need it. Safe to call repeatedly; one run at a time.
    static func processPending(context: ModelContext, inBackground: Bool) async {
        guard !processing, !Pipeline.shared.isRunning else { return }
        processing = true
        defer { processing = false }
        let s = SettingsStore.shared.settings
        var steps: NotePipeline.Steps = [.title]
        if s.autoTranscribe { steps.insert(.transcribe) }
        if s.autoSummarize { steps.insert(.summarize) }
        var ready = 0

        for rec in candidates(context: context) {
            if Task.isCancelled { break }
            do {
                let out = try await NotePipeline.process(rec, steps: steps, context: context, inBackground: inBackground)
                if out.didAnything { ready += 1 }
            } catch {
                if Task.isCancelled { break }
                rec.autoProcessFailures += 1
                try? context.save()
            }
        }

        if inBackground && ready > 0 {
            await Notifier.post(title: ready == 1 ? "Your note is ready" : "\(ready) notes are ready",
                                body: "Transcripts, summaries and titles were added while you were away.")
        }
        if hasPendingWork(context: context) && inBackground { scheduleProcessing() }
    }

    // MARK: Extra time for work started in the foreground

    /// Keeps `work` running for a while if the user leaves the app mid-task.
    static func withExtendedTime<T>(_ name: String, _ work: () async throws -> T) async rethrows -> T {
        var id: UIBackgroundTaskIdentifier = .invalid
        id = UIApplication.shared.beginBackgroundTask(withName: name) {
            if id != .invalid { UIApplication.shared.endBackgroundTask(id); id = .invalid }
        }
        defer { if id != .invalid { UIApplication.shared.endBackgroundTask(id); id = .invalid } }
        return try await work()
    }
}

enum Notifier {
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    @MainActor
    static func post(title: String, body: String) async {
        guard SettingsStore.shared.settings.notifications else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }
}

