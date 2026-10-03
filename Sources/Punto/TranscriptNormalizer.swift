import Foundation

enum TranscriptNormalizer {
    static func normalize(_ transcript: String, language: SpeechLanguage) -> String {
        var result = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }

        result = result.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\s+([,.;:!?])"#,
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"([«(\[])\s+"#,
            with: "$1",
            options: .regularExpression
        )

        if language == .english || language == .automatic {
            result = result.replacingOccurrences(
                of: #"\bi\b"#,
                with: "I",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        guard let first = result.first else { return result }
        let uppercasedFirst = String(first).uppercased(with: language.locale ?? .current)
        return uppercasedFirst + result.dropFirst()
    }
}
