import Foundation
import NaturalLanguage

struct SpeechSentence: Codable, Equatable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

enum SpeechSentences {
    static func split(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
            return true
        }
        return sentences.isEmpty ? [text] : sentences
    }

    static func metadataURL(for audio: URL) -> URL {
        URL(fileURLWithPath: audio.path + ".sentences.json")
    }

    static func load(for audio: URL, duration: TimeInterval) -> [SpeechSentence] {
        guard let data = try? Data(contentsOf: metadataURL(for: audio)),
              let marks = try? JSONDecoder().decode([SpeechSentence].self, from: data),
              !marks.isEmpty else { return [] }
        var previousEnd: TimeInterval = 0
        for mark in marks {
            guard mark.start.isFinite, mark.end.isFinite,
                  abs(mark.start - previousEnd) < 0.01,
                  mark.end > mark.start, mark.end <= duration + 0.01 else { return [] }
            previousEnd = mark.end
        }
        guard abs(previousEnd - duration) < 0.01 else { return [] }
        return marks
    }

    static func index(at time: TimeInterval, in marks: [SpeechSentence]) -> Int? {
        marks.lastIndex { $0.start <= time + 0.0001 }
    }
}
