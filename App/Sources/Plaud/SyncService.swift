import Foundation
import SwiftData
import RiffCore

/// Pulls recordings from the Plaud cloud onto the phone.
/// Note Pro → official Plaud app → Plaud cloud → here.
@MainActor
final class SyncService: ObservableObject {
    @Published private(set) var isSyncing = false
    @Published private(set) var status: String?
    @Published var lastError: String?
    @Published private(set) var lastSync: Date?

    func sync(account: PlaudAccount, context: ModelContext, usePlaudContent: Bool = true) async {
        guard !isSyncing, let client = account.makeClient() else { return }
        isSyncing = true
        lastError = nil
        status = "Checking Plaud…"
        defer {
            isSyncing = false
            status = nil
        }

        do {
            let remote = try await client.listAllRecordings()
            let all = try context.fetch(FetchDescriptor<RecordingItem>())
            let byPlaudId = Dictionary(all.compactMap { item in item.plaudId.map { ($0, item) } },
                                       uniquingKeysWith: { a, _ in a })
            let plan = PlaudSync.plan(
                remote: remote,
                local: byPlaudId.map { PlaudSync.LocalState(plaudId: $0.key, version: $0.value.plaudVersion) }
            )

            for (i, listed) in plan.new.enumerated() {
                status = "Downloading \(i + 1) of \(plan.new.count)…"
                // Plaud 4.0 listings lack transcript/summary flags; the detail fills them in.
                let rec = (try? await client.hydrate(listed)) ?? listed
                let file = try await client.downloadAudio(fileId: rec.id, into: RecordingStorage.directory)
                var duration = rec.durationSeconds
                if duration <= 0 { duration = await RecordingStorage.duration(of: file) }
                let item = RecordingItem(
                    title: rec.filename?.isEmpty == false ? rec.filename! : "Recording",
                    createdAt: rec.startedAt ?? .now,
                    duration: duration,
                    audioFileName: file.lastPathComponent,
                    source: "plaud",
                    id: UUID(uuidString: NoteID.forPlaud(rec.id)) ?? UUID()
                )
                item.plaudId = rec.id
                item.plaudVersion = rec.versionMarker
                context.insert(item)
                if usePlaudContent && (rec.is_trans == true || rec.is_summary == true) {
                    await importPlaudContent(for: item, client: client)
                }
                try context.save()
            }

            for rec in plan.updated {
                guard let item = byPlaudId[rec.id] else { continue }
                status = "Updating \(item.title)…"
                if let name = rec.filename, !name.isEmpty { item.title = name }
                item.plaudVersion = rec.versionMarker
                item.goneRemotely = false
                if usePlaudContent {
                    let hydrated = (try? await client.hydrate(rec)) ?? rec
                    if hydrated.is_trans != false || hydrated.is_summary != false {
                        await importPlaudContent(for: item, client: client)
                    }
                }
            }

            for id in plan.goneRemotely {
                byPlaudId[id]?.goneRemotely = true
            }

            try context.save()
            lastSync = .now
        } catch PlaudError.invalidToken {
            account.needsReconnect = true
            lastError = PlaudError.invalidToken.description
        } catch {
            lastError = errorMessage(error)
        }
    }

    /// Uses Plaud's own transcript/summary when Plaud has made them; never overwrites a user's local result.
    func importPlaudContent(for item: RecordingItem, client: PlaudClient) async {
        guard let id = item.plaudId else { return }
        guard let parsed = try? await client.plaudContent(fileId: id) else { return }
        if let t = parsed.transcript, !t.segments.isEmpty, item.transcript == nil || item.transcriptSource == "plaud" {
            item.transcript = t
            item.transcriptSource = "plaud"
        }
        if let s = parsed.summary, !s.isEmpty, item.summary == nil || item.summarySource == "plaud" {
            item.summary = s
            item.summarySource = "plaud"
        }
    }
}
