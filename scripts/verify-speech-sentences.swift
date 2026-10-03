import Foundation

@main
struct VerifySpeechSentences {
    static func main() throws {
        let sample = "Dr. Smith uses version 1.25. This is the next sentence! A final question?"
        let parts = SpeechSentences.split(sample)
        precondition(parts.count == 3, "Unexpected sentence boundaries: \(parts)")
        precondition(parts[0] == "Dr. Smith uses version 1.25.")
        precondition(parts.joined(separator: " ") == sample)
        let marks = [SpeechSentence(text: parts[0], start: 0, end: 2), SpeechSentence(text: parts[1], start: 2, end: 4)]
        precondition(SpeechSentences.index(at: 1.9, in: marks) == 0)
        precondition(SpeechSentences.index(at: 2, in: marks) == 1)
        let audio = URL(fileURLWithPath: "/tmp/echo-timeline-check.wav")
        let metadata = SpeechSentences.metadataURL(for: audio)
        try JSONEncoder().encode(marks).write(to: metadata)
        precondition(SpeechSentences.load(for: audio, duration: 4) == marks)
        precondition(SpeechSentences.load(for: audio, duration: 5).isEmpty)
        try FileManager.default.removeItem(at: metadata)
        print("Sentence preservation, abbreviations, decimals, timing lookup and invalid timeline checks passed.")
    }
}
