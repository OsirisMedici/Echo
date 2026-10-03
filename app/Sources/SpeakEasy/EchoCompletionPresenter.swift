import Foundation

/// Echo reads the completed reply locally, without requesting a model summary.
struct EchoCompletionPresenter: CompletionPresenting {
    func present(_ request: CompletionPresentationRequest) async -> CompletionPresentationResult {
        CompletionPresentationResult(
            spokenText: Self.project(request.response),
            source: .deterministic,
            model: nil,
            fallbackReason: nil
        )
    }

    static func project(_ response: String) -> String {
        var text = response
        let replacements: [(String, String)] = [
            ("(?s)<oai-mem-citation>.*?</oai-mem-citation>", " "),
            ("!\\[([^]]*)\\]\\([^)]*\\)", "$1"),
            ("\\[([^]]+)\\]\\([^)]*\\)", "$1"),
            ("(?m)^\\s{0,3}#{1,6}\\s*", ""),
            ("(?m)^\\s*```[^\\n]*$", ""),
        ]
        for (pattern, replacement) in replacements {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = expression.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
        }
        for marker in ["`", "**", "__", "~~"] {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        // The local renderer chunks long replies, so there is no character cap.
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
