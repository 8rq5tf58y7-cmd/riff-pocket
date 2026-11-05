import SwiftUI
import SwiftData
import AVFoundation

/// Fallback capture with the iPhone mic for when the recorder isn't with you.
struct RecordView: View {
    @Environment(\.modelContext) private var context
    @StateObject private var recorder = MicRecorder()
    @State private var error: String?
    @State private var savedTitle: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()
                Text(Duration.seconds(recorder.elapsed), format: .time(pattern: .hourMinuteSecond))
                    .font(.system(size: 56, weight: .light, design: .rounded))
                    .monospacedDigit()
                Button {
                    Task { await toggle() }
                } label: {
                    Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                        .font(.system(size: 96))
                        .foregroundStyle(.red)
                }
                .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start recording")
                if let savedTitle { Text("Saved \"\(savedTitle)\" to Recordings").foregroundStyle(.secondary) }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                Spacer()
            }
            .padding()
            .navigationTitle("Record")
        }
    }

    private func toggle() async {
        error = nil
        if recorder.isRecording {
            guard let result = recorder.stop() else { return }
            let (url, duration) = result
            let title = "Phone recording " + Date.now.formatted(date: .abbreviated, time: .shortened)
            context.insert(RecordingItem(title: title, duration: duration, audioFileName: url.lastPathComponent, source: "mic"))
            try? context.save()
            savedTitle = title
        } else {
            savedTitle = nil
            do { try await recorder.start() } catch { self.error = errorMessage(error) }
        }
    }
}

@MainActor
final class MicRecorder: ObservableObject {
    enum Failure: LocalizedError {
        case denied
        var errorDescription: String? { "Microphone access is off. Enable it in Settings → Riff Pocket." }
    }

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    private var recorder: AVAudioRecorder?
    private var timer: Timer?

    func start() async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw Failure.denied }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
        try session.setActive(true)
        let url = RecordingStorage.newFileURL(ext: "m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000, // Whisper's native rate
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let r = try AVAudioRecorder(url: url, settings: settings)
        guard r.record() else { throw CocoaError(.fileWriteUnknown) }
        recorder = r
        isRecording = true
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsed = self?.recorder?.currentTime ?? 0 }
        }
    }

    func stop() -> (URL, TimeInterval)? {
        guard let r = recorder else { return nil }
        let duration = r.currentTime
        r.stop()
        timer?.invalidate()
        recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return (r.url, duration)
    }
}
