import Foundation

/// Pure diffing logic for sync, so it is testable without network or SwiftData.
public enum PlaudSync {
    public struct LocalState: Hashable, Sendable {
        public var plaudId: String
        public var version: Double
        public init(plaudId: String, version: Double) {
            self.plaudId = plaudId
            self.version = version
        }
    }

    public struct Plan: Sendable {
        /// Not on the phone yet: download audio (+ Plaud transcript/summary if present).
        public var new: [PlaudRecording] = []
        /// Changed on Plaud's side (renamed, transcribed, summarized): refresh metadata/content.
        public var updated: [PlaudRecording] = []
        /// On the phone but no longer on Plaud (deleted/trashed there). The app keeps them, flagged.
        public var goneRemotely: [String] = []
    }

    public static func plan(remote: [PlaudRecording], local: [LocalState]) -> Plan {
        let localById = Dictionary(local.map { ($0.plaudId, $0.version) }, uniquingKeysWith: { a, _ in a })
        let remoteIds = Set(remote.map(\.id))
        var plan = Plan()
        for r in remote where r.is_trash != true {
            if let v = localById[r.id] {
                if r.versionMarker > v { plan.updated.append(r) }
            } else {
                plan.new.append(r)
            }
        }
        plan.goneRemotely = local.map(\.plaudId).filter { !remoteIds.contains($0) }
        // Oldest first so the list fills in chronological order during a long first sync.
        plan.new.sort { ($0.start_time ?? 0) < ($1.start_time ?? 0) }
        return plan
    }
}
