import Foundation

struct TimedSpeechSegment: Equatable {
    let text: String
    let timestamp: TimeInterval
    let duration: TimeInterval
    let confidence: Double
    /// Нормированная логарифмическая высота тона по кадрам (SFVoiceAnalytics).
    let pitch: [Double]
    /// Вероятность вокализации по тем же кадрам.
    let voicing: [Double]

    init(
        text: String,
        timestamp: TimeInterval,
        duration: TimeInterval,
        confidence: Double = 0.5,
        pitch: [Double] = [],
        voicing: [Double] = []
    ) {
        self.text = text
        self.timestamp = timestamp
        self.duration = duration
        self.confidence = confidence
        self.pitch = pitch
        self.voicing = voicing
    }

    func with(text: String, timestamp: TimeInterval, duration: TimeInterval, confidence: Double) -> TimedSpeechSegment {
        TimedSpeechSegment(
            text: text,
            timestamp: timestamp,
            duration: duration,
            confidence: confidence,
            pitch: pitch,
            voicing: voicing
        )
    }
}

/// Пунктуация для распознанной речи. Русские модели Apple (SFSpeechRecognizer и
/// DictationTranscriber) знаков не ставят даже с `addsPunctuation`, поэтому для
/// текста без знаков Punto расставляет их сам: по паузам, по точным
/// грамматическим правилам и по продиктованным словам («запятая»,
/// «вопросительный знак»). Текст, который распознаватель уже пунктуировал
/// (английский), сохраняется как есть.
enum AutomaticPunctuation {
    private static let commaPause: TimeInterval = 0.55
    private static let sentencePause: TimeInterval = 1.10
    /// «точка» считается командой только в конце или перед паузой: иначе это
    /// слово («точка зрения»).
    private static let spokenPeriodPause: TimeInterval = 0.30
    private static let terminalMarks = CharacterSet(charactersIn: ".!?…")
    private static let boundaryMarks = CharacterSet(charactersIn: ",.;:!?…")
    private static let trailingClosers = CharacterSet(charactersIn: "\"'»”’)]}")

    private static let russianQuestionWords: Set<String> = [
        "кто", "что", "где", "куда", "откуда", "когда", "почему", "зачем",
        "как", "какой", "какая", "какое", "какие", "чей", "чья", "чьё",
        "чьи", "сколько"
    ]
    private static let englishQuestionWords: Set<String> = [
        "who", "what", "where", "when", "why", "how", "which", "whose", "whom",
        "am", "is", "are", "was", "were", "do", "does", "did", "can", "could",
        "will", "would", "should", "have", "has", "had", "may", "might"
    ]
    /// Слова в начале фразы, после которых нужна запятая («Привет, ты где?»).
    private static let openingWords: Set<String> = [
        "привет", "приветик", "здравствуй", "здравствуйте", "слушай", "слушайте",
        "кстати", "короче", "окей", "ок", "hi", "hello", "hey", "okay", "ok"
    ]
    private static let openingPhrases: Set<String> = [
        "доброе утро", "добрый день", "добрый вечер", "good morning", "good evening"
    ]
    /// Сказуемые, с которыми фраза с «ты»/«вы» в конце почти всегда вопрос:
    /// «ты меня слышишь», «вы готовы», «ты дома».
    private static let secondPersonQuestionEndings: Set<String> = [
        "слышишь", "слышите", "видишь", "видите", "понимаешь", "понимаете",
        "знаешь", "знаете", "помнишь", "помните", "хочешь", "хотите",
        "можешь", "можете", "готов", "готова", "готовы", "согласен", "согласна",
        "согласны", "свободен", "свободна", "свободны", "занят", "занята", "заняты",
        "тут", "здесь", "дома"
    ]
    /// Слова, после которых союз не отделяется запятой: «а если», «только когда»,
    /// «потому что», «так что», «в котором» (запятая стоит перед предлогом).
    private static let conjunctionBlockers: Set<String> = [
        "и", "а", "но", "или", "что", "даже", "только", "лишь", "именно", "вот",
        "тогда", "как", "для", "того", "не", "ни", "так", "потому", "чем",
        "в", "во", "на", "с", "со", "о", "об", "обо", "по", "за", "из", "у", "к", "ко",
        "от", "без", "при", "про", "через", "над", "под", "перед", "между"
    ]
    /// Союзные слова придаточного в середине фразы: «знаю, где», «думаю, что».
    private static let subordinateWords: Set<String> = [
        "что", "кто", "где", "куда", "откуда", "почему", "зачем", "сколько",
        "какой", "какая", "какое", "какие", "чей", "чья", "чьё", "чьи",
        "который", "которая", "которое", "которые", "которого", "которой",
        "которому", "которым", "которых", "которую"
    ]
    private static let spokenMarks: [(words: [String], mark: String, needsPause: Bool)] = [
        (["точка", "с", "запятой"], ";", false),
        (["вопросительный", "знак"], "?", false),
        (["знак", "вопроса"], "?", false),
        (["восклицательный", "знак"], "!", false),
        (["знак", "восклицания"], "!", false),
        (["question", "mark"], "?", false),
        (["exclamation", "mark"], "!", false),
        (["exclamation", "point"], "!", false),
        (["full", "stop"], ".", false),
        (["запятая"], ",", false),
        (["двоеточие"], ":", false),
        (["многоточие"], "…", false),
        (["comma"], ",", false),
        (["точка"], ".", true)
    ]

    static func restore(
        formattedTranscript: String,
        segments: [TimedSpeechSegment],
        language: SpeechLanguage,
        preserveFormattedTranscript: Bool = false
    ) -> String {
        let usableSegments = segments.compactMap { segment -> TimedSpeechSegment? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return segment.with(
                text: text,
                timestamp: segment.timestamp,
                duration: segment.duration,
                confidence: segment.confidence
            )
        }

        var result: String
        let formatted = formattedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        // Текст распознавателя сохраняется, только если в нём уже есть знаки.
        // Русская модель отдаёт текст без знаков, и тогда работают паузы и правила.
        if preserveFormattedTranscript, !formatted.isEmpty,
           usableSegments.isEmpty || containsPunctuation(formatted) {
            result = formatted
        } else if usableSegments.isEmpty {
            result = formatted
        } else {
            result = buildFromSegments(applySpokenMarks(usableSegments), language: language)
        }

        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }
        if !endsWithTerminalMark(result) {
            result += looksLikeQuestion(lastSentence(of: result), language: language) ? "?" : "."
        }
        return result
    }

    // MARK: - Сборка по словам

    private static func buildFromSegments(
        _ segments: [TimedSpeechSegment],
        language: SpeechLanguage
    ) -> String {
        var result = ""
        var capitalizeNext = true
        var sentenceStart = result.endIndex
        var sentenceWords: [String] = []

        for index in segments.indices {
            var text = segments[index].text
            if capitalizeNext {
                text = uppercaseFirstLetter(in: text, language: language)
                capitalizeNext = false
                sentenceStart = result.endIndex
                sentenceWords = []
            }
            result += text
            if let word = normalizedWord(text) { sentenceWords.append(word) }

            guard index < segments.index(before: segments.endIndex) else { continue }
            let nextText = segments[index + 1].text
            if isCloserOnly(nextText) {
                capitalizeNext = false
                continue
            }
            if endsWithBoundaryMark(text) {
                result += " "
                capitalizeNext = endsWithTerminalMark(text)
                continue
            }

            let currentEnd = segments[index].timestamp + segments[index].duration
            let pause = max(0, segments[index + 1].timestamp - currentEnd)
            if pause >= sentencePause {
                let sentence = String(result[sentenceStart...])
                result += looksLikeQuestion(sentence, language: language) ? "? " : ". "
                capitalizeNext = true
            } else if pause >= commaPause
                        || needsComma(
                            sentenceWords: sentenceWords,
                            next: normalizedWord(nextText),
                            following: segments.indices.contains(index + 2) ? normalizedWord(segments[index + 2].text) : nil
                        ) {
                result += ", "
            } else {
                result += " "
            }
        }
        return result
    }

    /// Запятая по точным правилам: после приветствия в начале фразы и перед
    /// союзами «но», «а», «однако», «зато», «чтобы», «если», «когда»,
    /// «потому что». Сам союз в начале фразы запятой не отделяется.
    private static func needsComma(sentenceWords: [String], next: String?, following: String?) -> Bool {
        guard let current = sentenceWords.last, let next else { return false }
        if sentenceWords.count == 1, openingWords.contains(current) { return true }
        if sentenceWords.count == 2, openingPhrases.contains(sentenceWords.joined(separator: " ")) { return true }
        guard !conjunctionBlockers.contains(current) else { return false }
        switch next {
        case "но", "а", "однако", "зато", "чтобы", "если", "когда":
            return true
        case "потому":
            return following == "что"
        default:
            return subordinateWords.contains(next)
        }
    }

    // MARK: - Продиктованные знаки

    private static func applySpokenMarks(_ segments: [TimedSpeechSegment]) -> [TimedSpeechSegment] {
        var output: [TimedSpeechSegment] = []
        var index = 0
        while index < segments.count {
            if let match = spokenMark(at: index, in: segments) {
                if let previous = output.popLast() {
                    let stripped = stripTrailingMarks(previous.text)
                    output.append(previous.with(
                        text: stripped + match.mark,
                        timestamp: previous.timestamp,
                        duration: previous.duration,
                        confidence: previous.confidence
                    ))
                }
                index += match.length
                continue
            }
            output.append(segments[index])
            index += 1
        }
        return output
    }

    private static func spokenMark(at index: Int, in segments: [TimedSpeechSegment]) -> (mark: String, length: Int)? {
        for candidate in spokenMarks {
            let end = index + candidate.words.count
            guard end <= segments.count else { continue }
            let words = segments[index..<end].map { normalizedWord($0.text) ?? "" }
            guard words == candidate.words else { continue }
            if candidate.needsPause, end < segments.count {
                let last = segments[end - 1]
                let pause = segments[end].timestamp - (last.timestamp + last.duration)
                guard pause >= spokenPeriodPause else { continue }
            }
            return (candidate.mark, candidate.words.count)
        }
        return nil
    }

    // MARK: - Вопрос

    /// Вопрос определяется по тексту: вопросительное слово в начале фразы или
    /// после обращения («Привет, как дела»), частица «ли», либо «ты»/«вы» и
    /// сказуемое вроде «слышишь», «готовы» в конце.
    private static func looksLikeQuestion(_ text: String, language: SpeechLanguage) -> Bool {
        let clauses = text
            .lowercased(with: language.locale ?? .current)
            .components(separatedBy: CharacterSet(charactersIn: ",;:—"))
            .map { clause in
                clause.components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "-")).inverted)
                    .filter { !$0.isEmpty }
            }
            .filter { !$0.isEmpty }
        guard let words = Optional(clauses.flatMap { $0 }), let first = words.first,
              let lastClause = clauses.last, let lastClauseFirst = lastClause.first else { return false }

        let russian = language != .english
        let english = language != .russian
        if russian, russianQuestionWords.contains(first) || words.prefix(4).contains("ли") { return true }
        if english, englishQuestionWords.contains(first) { return true }

        // После приветствия: «Привет, как дела». Произвольная первая часть не
        // годится: «Знаю, что ты прав» — не вопрос.
        let leading = clauses.dropLast().flatMap { $0 }
        let leadingText = leading.joined(separator: " ")
        let afterGreeting = clauses.count > 1
            && (openingPhrases.contains(leadingText) || (leading.count == 1 && openingWords.contains(leadingText)))
        if afterGreeting {
            if russian, russianQuestionWords.contains(lastClauseFirst) || lastClause.prefix(4).contains("ли") { return true }
            if english, englishQuestionWords.contains(lastClauseFirst) { return true }
        }

        if russian, let last = lastClause.last,
           secondPersonQuestionEndings.contains(last),
           lastClause.contains("ты") || lastClause.contains("вы") {
            return true
        }
        return false
    }

    private static func lastSentence(of text: String) -> String {
        var trimmed = Substring(text)
        while let last = trimmed.last, last.unicodeScalars.allSatisfy(terminalMarks.contains) {
            trimmed = trimmed.dropLast()
        }
        guard let boundary = trimmed.lastIndex(where: { $0.unicodeScalars.allSatisfy(terminalMarks.contains) }) else {
            return String(trimmed)
        }
        return String(trimmed[trimmed.index(after: boundary)...])
    }

    // MARK: - Помощники

    private static func normalizedWord(_ text: String) -> String? {
        let word = text.lowercased()
            .trimmingCharacters(in: CharacterSet.letters.union(CharacterSet(charactersIn: "-")).inverted)
        return word.isEmpty ? nil : word
    }

    private static func containsPunctuation(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: boundaryMarks.contains)
    }

    private static func stripTrailingMarks(_ text: String) -> String {
        var result = text
        while let last = result.unicodeScalars.last, boundaryMarks.contains(last) {
            result.unicodeScalars.removeLast()
        }
        return result
    }

    private static func uppercaseFirstLetter(in text: String, language: SpeechLanguage) -> String {
        guard let letterIndex = text.firstIndex(where: { $0.isLetter }) else { return text }
        let letter = String(text[letterIndex]).uppercased(with: language.locale ?? .current)
        return String(text[..<letterIndex]) + letter + text[text.index(after: letterIndex)...]
    }

    private static func endsWithTerminalMark(_ text: String) -> Bool {
        guard let scalar = lastSignificantScalar(in: text) else { return false }
        return terminalMarks.contains(scalar)
    }

    private static func endsWithBoundaryMark(_ text: String) -> Bool {
        guard let scalar = lastSignificantScalar(in: text) else { return false }
        return boundaryMarks.contains(scalar)
    }

    private static func isCloserOnly(_ text: String) -> Bool {
        let scalars = text.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        return !scalars.isEmpty && scalars.allSatisfy(trailingClosers.contains)
    }

    private static func lastSignificantScalar(in text: String) -> UnicodeScalar? {
        for scalar in text.unicodeScalars.reversed() {
            if CharacterSet.whitespacesAndNewlines.contains(scalar)
                || trailingClosers.contains(scalar) {
                continue
            }
            return scalar
        }
        return nil
    }
}
