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
            VStack(spacing: 28) {
                Spacer()
                Text(recorder.isRecording ? "Recording" : "Ready when you are")
                    .font(Theme.mono).foregroundStyle(recorder.isRecording ? Theme.accent : Theme.secondary)
                Text(Duration.seconds(recorder.elapsed), format: .time(pattern: .hourMinuteSecond))
                    .font(Theme.serif(60, .light))
                    .monospacedDigit()
                Button {
                    Task { await toggle() }
                } label: {
                    ZStack {
                        Circle().fill(Theme.accentSoft).frame(width: 132, height: 132)
                            .scaleEffect(recorder.isRecording ? 1.08 : 1)
                            .animation(recorder.isRecording ? .easeInOut(duration: 0.9).repeatForever() : .default,
                                       value: recorder.isRecording)
                        Group {
                            if recorder.isRecording {
                                RoundedRectangle(cornerRadius: 8).fill(.white).frame(width: 30, height: 30)
                            } else {
                                Image(systemName: "mic.fill").font(.system(size: 34, weight: .semibold)).foregroundStyle(.white)
                            }
                        }
                        .frame(width: 92, height: 92)
                        .background(Theme.accent, in: .circle)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start recording")
                if let savedTitle {
                    Label("Saved “\(savedTitle)”", systemImage: "checkmark.circle")
                        .font(.subheadline).foregroundStyle(Theme.success)
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                Spacer()
                Text("For when your recorder isn't with you. Notes appear in Notes, ready to transcribe.")
                    .font(.caption).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(Theme.background)
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
