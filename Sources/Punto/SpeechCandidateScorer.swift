import AppKit
import Foundation
import NaturalLanguage

enum SpeechCandidateScorer {
    private static let recognizedTerms: Set<String> = [
        "android", "angular", "api", "apple", "aws", "azure", "bash", "bitbucket",
        "chatgpt", "chrome", "claude", "copilot", "css", "cursor", "django", "docker",
        "excel", "figma", "firebase", "flask", "gemini", "git", "github", "gitlab",
        "gmail", "google", "gpt", "html", "http", "https", "ios", "java", "javascript",
        "jira", "json", "kafka", "kotlin", "kubernetes", "linux", "macos", "mongodb",
        "mysql", "nginx", "node", "notion", "npm", "openai", "php", "postgres",
        "postgresql", "python", "react", "redis", "ruby", "rust", "safari", "slack",
        "sql", "ssh", "swift", "telegram", "terminal", "typescript", "url", "vscode",
        "vue", "webpack", "whatsapp", "windows", "xcode", "youtube", "zoom"
    ]

    /// Пользовательский список терминов: по одному слову в строке, строки с `#`
    /// игнорируются. Термины подставляются латиницей внутри русской речи.
    static let userTermsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Punto/terms.txt")

    private static let userTerms: Set<String> = {
        guard let content = try? String(contentsOf: userTermsURL, encoding: .utf8) else { return [] }
        return Set(content.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            return trimmed.lowercased()
        })
    }()

    static func isRecognizedTerm(_ token: String) -> Bool {
        let key = token.lowercased()
        return recognizedTerms.contains(key) || userTerms.contains(key)
    }

    /// Короткий латинский фрагмент с явными признаками термина: известный или
    /// пользовательский термин, аббревиатура, CamelCase или цифры.
    static func isStrongTerm(_ transcript: String) -> Bool {
        isShortLatinTerm(transcript)
    }

    static func score(
        transcript: String,
        language: SpeechLanguage,
        acousticConfidence: Double,
        languageProbabilityOverride: Double? = nil,
        spellingRatioOverride: Double? = nil,
        scriptCompatibilityOverride: Double? = nil
    ) -> Double {
        guard language != .automatic else { return 0 }
        let languageProbability = languageProbabilityOverride
            ?? detectedLanguageProbability(transcript, expected: language)
        let spellingRatio = spellingRatioOverride
            ?? knownWordRatio(transcript, language: language)
        let scriptCompatibility = scriptCompatibilityOverride
            ?? expectedScriptRatio(transcript, language: language)

        if language == .english, isShortLatinTerm(transcript) {
            // NaturalLanguage and the system dictionary are weak evidence for
            // short product names and acronyms. Keep acoustic evidence and the
            // actual Latin script decisive without treating every dictionary
            // miss as a valid term.
            return clamped(acousticConfidence) * 0.42
                + clamped(languageProbability) * 0.22
                + clamped(spellingRatio) * 0.08
                + clamped(scriptCompatibility) * 0.28
        }

        // Textual plausibility deliberately outweighs acoustic confidence:
        // the wrong recognizer can be very confident about plausible-sounding
        // pseudowords such as "Prima Wakia Voda".
        return clamped(acousticConfidence) * 0.25
            + clamped(languageProbability) * 0.42
            + clamped(spellingRatio) * 0.20
            + clamped(scriptCompatibility) * 0.13
    }

    private static func detectedLanguageProbability(
        _ transcript: String,
        expected language: SpeechLanguage
    ) -> Double {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(transcript)
        let expectedLanguage: NLLanguage = language == .russian ? .russian : .english
        return recognizer.languageHypotheses(withMaximum: 6)[expectedLanguage] ?? 0
    }

    static func knownWordRatio(_ transcript: String, language: SpeechLanguage) -> Double {
        let words = transcript
            .lowercased(with: language.locale ?? .current)
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return 0 }

        let spellChecker = NSSpellChecker.shared
        let documentTag = NSSpellChecker.uniqueSpellDocumentTag()
        defer { spellChecker.closeSpellDocument(withTag: documentTag) }
        let languageCode = language == .russian ? "ru_RU" : "en_US"

        var knownWeight = 0
        var totalWeight = 0
        for word in words {
            let weight = max(word.count, 1)
            totalWeight += weight
            let misspelledRange = spellChecker.checkSpelling(
                of: word,
                startingAt: 0,
                language: languageCode,
                wrap: false,
                inSpellDocumentWithTag: documentTag,
                wordCount: nil
            )
            if misspelledRange.location == NSNotFound {
                knownWeight += weight
            }
        }
        return totalWeight == 0 ? 0 : Double(knownWeight) / Double(totalWeight)
    }

    private static func expectedScriptRatio(
        _ transcript: String,
        language: SpeechLanguage
    ) -> Double {
        let letters = transcript.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return 0 }
        let matchingCount = letters.filter { scalar in
            switch language {
            case .english:
                return isLatin(scalar)
            case .russian:
                return isCyrillic(scalar)
            case .automatic:
                return false
            }
        }.count
        return Double(matchingCount) / Double(letters.count)
    }

    private static func isShortLatinTerm(_ transcript: String) -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace })
        guard !tokens.isEmpty, tokens.count <= 3, trimmed.count <= 24 else { return false }

        let scalars = trimmed.unicodeScalars
        let letters = scalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty, letters.allSatisfy(isLatin) else { return false }
        guard scalars.allSatisfy({
            isLatin($0)
                || CharacterSet.decimalDigits.contains($0)
                || CharacterSet.whitespaces.contains($0)
                || CharacterSet(charactersIn: ".+-#,;:!?\"'“”‘’").contains($0)
        }) else { return false }

        let normalizedTokens = tokens.map {
            String($0).trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        }.filter { !$0.isEmpty }
        guard !normalizedTokens.isEmpty else { return false }
        if normalizedTokens.contains(where: isRecognizedTerm) {
            return true
        }
        return normalizedTokens.contains { token in
            let tokenLetters = token.filter(\.isLetter)
            let uppercaseCount = tokenLetters.filter(\.isUppercase).count
            let hasInternalUppercase = tokenLetters.dropFirst().contains(where: \.isUppercase)
            let hasDigit = token.contains(where: \.isNumber)
            return tokenLetters.count >= 2
                && (uppercaseCount == tokenLetters.count
                    || hasInternalUppercase
                    || hasDigit)
        }
    }

    private static func isLatin(_ scalar: UnicodeScalar) -> Bool {
        (0x0041...0x005A).contains(scalar.value)
            || (0x0061...0x007A).contains(scalar.value)
            || (0x00C0...0x024F).contains(scalar.value)
    }

    private static func isCyrillic(_ scalar: UnicodeScalar) -> Bool {
        (0x0400...0x052F).contains(scalar.value)
            || (0x2DE0...0x2DFF).contains(scalar.value)
            || (0xA640...0xA69F).contains(scalar.value)
    }

    private static func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
