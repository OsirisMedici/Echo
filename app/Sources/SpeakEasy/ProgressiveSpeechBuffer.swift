import Foundation

/// One reply remains one playback item while completed sentences arrive.
/// Positions always refer to the whole reply, including sentences already heard.
struct ProgressiveSpeechBuffer {
    struct Segment {
        let url: URL
        let duration: TimeInterval
        let sentences: [SpeechSentence]
    }

    private(set) var segments: [Segment] = []
    var isComplete = false
    var finalAudioURL: URL?

    var duration: TimeInterval { segments.reduce(0) { $0 + $1.duration } }
    var sentences: [SpeechSentence] {
        var offset: TimeInterval = 0
        return segments.flatMap { segment in
            defer { offset += segment.duration }
            return segment.sentences.map {
                SpeechSentence(text: $0.text, start: $0.start + offset, end: $0.end + offset)
            }
        }
    }

    mutating func append(url: URL, duration: TimeInterval, sentences: [SpeechSentence]) throws {
        guard !isComplete, duration.isFinite, duration > 0, !sentences.isEmpty,
              abs((sentences.first?.start ?? -1)) < 0.01,
              abs((sentences.last?.end ?? -1) - duration) < 0.01 else {
            throw PlayerEngineError.couldNotOpenAudio("Invalid progressive sentence audio")
        }
        segments.append(Segment(url: url, duration: duration, sentences: sentences))
    }

    func offset(for index: Int) -> TimeInterval {
        segments.prefix(index).reduce(0) { $0 + $1.duration }
    }

    func position(at time: TimeInterval) -> (index: Int, localTime: TimeInterval)? {
        guard !segments.isEmpty else { return nil }
        let target = min(max(time, 0), duration)
        var offset: TimeInterval = 0
        for (index, segment) in segments.enumerated() {
            if target < offset + segment.duration || index == segments.count - 1 {
                return (index, target - offset)
            }
            offset += segment.duration
        }
        return nil
    }

    func removeFiles() {
        for url in segments.map(\.url) + [finalAudioURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: SpeechSentences.metadataURL(for: url))
        }
    }
}
