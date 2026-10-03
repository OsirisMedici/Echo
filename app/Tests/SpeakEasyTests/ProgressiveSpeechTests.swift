import XCTest
@testable import SpeakEasy

final class ProgressiveSpeechTests: XCTestCase {
    private func audio(in directory: URL, name: String, text: String, seconds: Double = 0.2) throws -> URL {
        let url = directory.appendingPathComponent(name + ".wav")
        let pcm = Data(repeating: 0, count: Int(seconds * 24_000) * 2)
        let wav = try ConfiguredResponseNarrator.pcmWAV(audio: pcm, mimeType: "audio/L16;rate=24000")
        try wav.write(to: url)
        try JSONEncoder().encode([SpeechSentence(text: text, start: 0, end: seconds)])
            .write(to: SpeechSentences.metadataURL(for: url))
        return url
    }

    private func item(_ url: URL) -> PlaybackItem {
        let id = UUID()
        return PlaybackItem(id: id, audioPath: url.path, title: "Progressive test", text: "First. Second.",
                            provider: "karen", createdAt: "2026-10-03T00:00:00Z", synthesisRateWPM: 180,
                            sourceThreadId: nil, cleanupAfterPlayback: true, channel: .completions,
                            completionActivityID: id)
    }

    @MainActor
    func testBufferingDoesNotAnnounceReplyAndPauseSurvivesNewAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let engine = PlaybackEngine.shared
        engine.stop(); engine.clearQueue(); engine.setInteractiveBusy(false); engine.setVolume(0)
        defer { engine.stop(); engine.clearQueue(); engine.setVolume(0.8); try? FileManager.default.removeItem(at: directory) }
        let first = try audio(in: directory, name: "first", text: "First.")
        let second = try audio(in: directory, name: "second", text: "Second.")
        let reply = item(first)
        try engine.beginProgressiveAudio(reply)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(engine.currentItem?.id, reply.id)
        XCTAssertEqual(engine.state, .loading)
        XCTAssertNotEqual(engine.lastFinishedItemID, reply.id)
        engine.pause()
        try engine.appendProgressiveAudio(itemID: reply.id, url: second)
        XCTAssertEqual(engine.state, .paused)
        XCTAssertEqual(engine.sentences.map(\.text), ["First.", "Second."])
        let full = try audio(in: directory, name: "full", text: "First. Second.", seconds: 0.4)
        try engine.completeProgressiveAudio(itemID: reply.id, finalURL: full)
        XCTAssertNotEqual(engine.lastFinishedItemID, reply.id)
        try engine.resume()
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(engine.lastFinishedItemID, reply.id)
        XCTAssertNil(engine.currentItem)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: full.path))
    }

    @MainActor
    func testSeekingBackAcrossSegmentsAndStopRejectsLateAudio() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let engine = PlaybackEngine.shared
        engine.stop(); engine.clearQueue(); engine.setInteractiveBusy(false); engine.setVolume(0)
        defer { engine.stop(); engine.clearQueue(); engine.setVolume(0.8); try? FileManager.default.removeItem(at: directory) }
        let first = try audio(in: directory, name: "first", text: "First.", seconds: 1)
        let second = try audio(in: directory, name: "second", text: "Second.", seconds: 1)
        let reply = item(first)
        try engine.beginProgressiveAudio(reply)
        engine.pause()
        try engine.appendProgressiveAudio(itemID: reply.id, url: second)
        engine.nextSentence()
        XCTAssertEqual(engine.sentenceIndex, 1)
        XCTAssertEqual(engine.currentTime, 1, accuracy: 0.01)
        engine.previousSentence()
        XCTAssertEqual(engine.sentenceIndex, 0)
        XCTAssertEqual(engine.state, .paused)
        engine.stop()
        XCTAssertEqual(engine.lastStoppedItemID, reply.id)
        XCTAssertThrowsError(try engine.appendProgressiveAudio(itemID: reply.id, url: second))
        XCTAssertNotEqual(engine.lastFinishedItemID, reply.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    @MainActor
    func testCompletedAudioCanWaitBehindAnInteractiveTurn() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let engine = PlaybackEngine.shared
        engine.stop(); engine.clearQueue(); engine.setInteractiveBusy(true); engine.setVolume(0)
        defer { engine.stop(); engine.clearQueue(); engine.setInteractiveBusy(false); engine.setVolume(0.8); try? FileManager.default.removeItem(at: directory) }
        let first = try audio(in: directory, name: "first", text: "First.", seconds: 1)
        let second = try audio(in: directory, name: "second", text: "Second.", seconds: 1)
        let reply = item(first)
        try engine.beginProgressiveAudio(reply)
        try engine.appendProgressiveAudio(itemID: reply.id, url: second)
        let full = try audio(in: directory, name: "full", text: "First. Second.", seconds: 2)
        try engine.completeProgressiveAudio(itemID: reply.id, finalURL: full)
        XCTAssertNil(engine.currentItem)
        engine.setInteractiveBusy(false)
        XCTAssertEqual(engine.currentItem?.id, reply.id)
        XCTAssertEqual(engine.duration, 2, accuracy: 0.01)
        XCTAssertFalse(engine.isReceivingAudio)
        engine.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: full.path))
    }
}
