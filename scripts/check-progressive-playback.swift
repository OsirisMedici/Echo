// Standalone macOS acceptance check when only Command Line Tools are installed.
// Compile with the production PlaybackEngine, PlayerProtocol, SpeechSentences,
// and ProgressiveSpeechBuffer sources. Only unrelated HUD/config adapters are stubs.
import Foundation
import Combine
import AVFoundation

enum SpeakEasyEdition { static let playerSocket = "/tmp/echo-acceptance.sock" }
enum VoiceLane {
    static func normalizedPlaybackRate(_ rate: Float?) -> Float? { rate }
}
@MainActor final class HUDWindowManager {
    static let shared = HUDWindowManager()
    func showPlayback(_ item: PlaybackItem) {}
    func playbackDidFinish() {}
    func updatePlayback(audioLevel: Float, currentTime: Double, duration: Double) {}
}

@main struct ProgressivePlaybackCheck {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("echo-check-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func audio(_ name: String, _ sentence: String, _ duration: Double) throws -> URL {
            let url = directory.appendingPathComponent(name + ".wav")
            let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(duration * 24_000))!
            buffer.frameLength = buffer.frameCapacity
            memset(buffer.int16ChannelData![0], 0, Int(buffer.frameLength) * 2)
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            try file.write(from: buffer)
            try JSONEncoder().encode([SpeechSentence(text: sentence, start: 0, end: duration)])
                .write(to: SpeechSentences.metadataURL(for: url))
            return url
        }
        func require(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
        }
        func item(_ url: URL) -> PlaybackItem {
            let id = UUID()
            return PlaybackItem(id: id, audioPath: url.path, title: "Acceptance check", text: "First. Second.", provider: "karen",
                                createdAt: "2026-10-03T00:00:00Z", synthesisRateWPM: 180, sourceThreadId: nil,
                                cleanupAfterPlayback: true, channel: .completions, completionActivityID: id)
        }
        let engine = PlaybackEngine.shared
        engine.setVolume(0)
        defer { engine.stop(); engine.clearQueue() }
        let first = try audio("first", "First.", 0.2)
        let second = try audio("second", "Second.", 0.2)
        let final = try audio("final", "First. Second.", 0.4)
        let reply = item(first)
        try engine.beginProgressiveAudio(reply)
        try await Task.sleep(for: .milliseconds(500))
        require(engine.state == .loading && engine.currentItem?.id == reply.id, "Exhausted audio should buffer under the same reply")
        require(engine.lastFinishedItemID != reply.id, "A partial reply must not be announced")
        engine.pause()
        try engine.appendProgressiveAudio(itemID: reply.id, url: second)
        require(engine.state == .paused, "New audio must preserve Pause")
        try engine.completeProgressiveAudio(itemID: reply.id, finalURL: final)
        require(engine.lastFinishedItemID != reply.id, "Finishing generation must not finish playback")
        try engine.resume()
        try await Task.sleep(for: .milliseconds(500))
        require(engine.lastFinishedItemID == reply.id && engine.currentItem == nil, "The complete reply should finish exactly once")
        require(!FileManager.default.fileExists(atPath: first.path) && !FileManager.default.fileExists(atPath: final.path), "Finished audio must be removed")
        print("PASS: buffering, whole-reply completion, pause/resume, cleanup")

        let a = try audio("a", "First.", 1)
        let b = try audio("b", "Second.", 1)
        let next = item(a)
        try engine.beginProgressiveAudio(next)
        engine.pause()
        try engine.appendProgressiveAudio(itemID: next.id, url: b)
        engine.nextSentence()
        require(engine.sentenceIndex == 1 && abs(engine.currentTime - 1) < 0.01, "Next must cross segment boundaries")
        engine.previousSentence()
        require(engine.sentenceIndex == 0 && engine.state == .paused, "Previous must replay retained audio without resuming")
        engine.stop()
        do {
            try engine.appendProgressiveAudio(itemID: next.id, url: b)
            fatalError("Stopped audio must reject later segments")
        } catch is CancellationError {}
        require(engine.lastFinishedItemID != next.id, "Stopped replies must not be announced")
        print("PASS: sentence navigation, seek, stop, late audio rejection")

        let queuedFirst = try audio("queued-first", "First.", 1)
        let queuedSecond = try audio("queued-second", "Second.", 1)
        let queuedFinal = try audio("queued-final", "First. Second.", 2)
        let queued = item(queuedFirst)
        engine.setInteractiveBusy(true)
        try engine.beginProgressiveAudio(queued)
        try engine.appendProgressiveAudio(itemID: queued.id, url: queuedSecond)
        try engine.completeProgressiveAudio(itemID: queued.id, finalURL: queuedFinal)
        require(engine.currentItem == nil, "Interactive work must retain priority")
        engine.setInteractiveBusy(false)
        require(engine.currentItem?.id == queued.id && abs(engine.duration - 2) < 0.01 && !engine.isReceivingAudio, "Queued replies must retain all prepared sentences")
        engine.stop()
        require(!FileManager.default.fileExists(atPath: queuedFinal.path), "Queued final audio must be removed on Stop")
        print("PASS: interactive priority and queued progressive audio")
    }
}
