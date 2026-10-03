// Compile with production KarenVoice.swift and SpeechSentences.swift, then place
// in a minimal .app with the packaged karen-qwen.py resource. No speech playback.
import Foundation

enum SpeakEasyEdition { static let isDevelopment = true }
extension Bundle { static var module: Bundle { .main } }
enum ConfiguredResponseNarratorError: LocalizedError {
    case generationFailed(String)
    var errorDescription: String? { if case .generationFailed(let message) = self { message } else { nil } }
}

actor ReceivedSegment {
    var url: URL?
    func save(_ url: URL) { self.url = url }
    func get() -> URL? { url }
}

@main struct QwenCancellationCheck {
    static func main() async throws {
        let received = ReceivedSegment()
        let started = Date()
        do {
            _ = try await KarenVoiceRenderer.render(text: "A quiet room helps me focus. Music can also help me focus. I prefer silence after all.", voice: "201", rate: 180) { url in
                let output = String(url.path.dropLast(".segment-0.wav".count))
                guard !FileManager.default.fileExists(atPath: output + ".sentences.json"),
                      !FileManager.default.fileExists(atPath: output + ".segment-1.wav") else {
                    fatalError("First callback was held until later audio was ready")
                }
                print("First Swift callback at \(Date().timeIntervalSince(started)) seconds, before the next sentence or completed reply")
                await received.save(url)
                throw CancellationError()
            }
            fatalError("Cancellation must stop generation")
        } catch is CancellationError {}
        guard let segment = await received.get() else { fatalError("First sentence was never delivered") }
        let output = String(segment.path.dropLast(".segment-0.wav".count))
        for index in 0..<3 {
            let path = output + ".segment-\(index).wav"
            guard !FileManager.default.fileExists(atPath: path),
                  !FileManager.default.fileExists(atPath: path + ".sentences.json") else {
                fatalError("Cancelled sentence audio was retained")
            }
        }
        guard !FileManager.default.fileExists(atPath: output),
              !FileManager.default.fileExists(atPath: output + ".sentences.json") else {
            fatalError("Cancelled reply audio was retained")
        }
        print("PASS: production Swift renderer delivered the first sentence, cancelled the process, and removed reply and segment files")
    }
}
