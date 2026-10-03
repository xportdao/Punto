import CoreGraphics
import Foundation

enum PuntoSelfTest {
    static func run() {
        var checkCount = 0
        func check(
            _ condition: @autoclosure () -> Bool,
            _ message: @autoclosure () -> String = "self-test check failed",
            line: UInt = #line
        ) {
            checkCount += 1
            precondition(condition(), "line \(line): \(message())")
        }

        let layoutCases: [(String, KeyboardLanguage, String)] = [
            ("ghbdtn", .russian, "привет"),
            ("Vbh", .russian, "Мир"),
            (";bpym", .russian, "жизнь"),
            ("\"nj", .russian, "Это"),
            ("руддщ", .english, "hello"),
            ("Цщкдв", .english, "World"),
            ("Этаж", .english, "\"nf;")
        ]

        for (input, language, expected) in layoutCases {
            let actual = LayoutMapper.convert(input, to: language)
            check(actual == expected, "\(input): expected \(expected), got \(actual ?? "nil")")
        }
        check(LayoutMapper.detectedLanguage(of: "helло") == nil)

        let classifier = WordClassifier { word, language in
            switch language {
            case .english: return ["hello", "example", "it's", "e;t"].contains(word.lowercased())
            case .russian: return ["привет", "уже", "почему"].contains(word.lowercased())
            }
        }
        check(classifier.correction(for: "ghbdtn")?.replacement == "привет")
        check(classifier.correction(for: "руддщ")?.replacement == "hello")
        check(classifier.correction(for: "ghbdtn/")?.replacement == "привет.")
        check(classifier.correction(for: "руддщю")?.replacement == "hello.")
        check(classifier.correction(for: "e;t")?.replacement == "уже")
        check(classifier.correction(for: "gjxtve")?.replacement == "почему")
        check(classifier.correction(for: "шеэы")?.replacement == "it's")
        check(classifier.correction(for: "example.com") == nil)
        check(classifier.correction(for: "ghbdtn?")?.replacement == "привет,")
        check(classifier.correction(for: "ghbdtn&")?.replacement == "привет?")

        // Раскладки пользователя: «США международная (PC)» с мёртвыми
        // клавишами и «Русская» Apple, где знаки стоят на цифровом ряду.
        let layoutWords: Set<String> = ["привет", "это", "ёлка", "энергия", "эскиз", "жизнь", "hello"]
        let layoutClassifier = WordClassifier { word, _ in layoutWords.contains(word.lowercased()) }
        let usInternational = KeyboardLayout.installed(identifier: "com.apple.keylayout.USInternational-PC")
        let appleRussian = KeyboardLayout.installed(identifier: "com.apple.keylayout.Russian")
        let usLayout = KeyboardLayout.installed(identifier: "com.apple.keylayout.US")
        let russianPC = KeyboardLayout.installed(identifier: "com.apple.keylayout.RussianWin")
        check(usInternational != nil && appleRussian != nil && usLayout != nil && russianPC != nil, "system layouts missing")
        if let english = usInternational, let russian = appleRussian, let us = usLayout, let ruPC = russianPC {
            check(english.language == .english && russian.language == .russian)
            check(us.language == .english && ruPC.language == .russian)
            let shift6 = KeyStroke(keyCode: 22, shift: true)
            let shift7 = KeyStroke(keyCode: 26, shift: true)
            check(english.isDeadKey(shift6))
            check(russian.character(for: shift6) == ",")
            check(english.render([shift6, KeyStroke(keyCode: 49)]).text == "^")
            check(english.render([KeyStroke(keyCode: 39), KeyStroke(keyCode: 14)])
                == LayoutRendering(text: "é", hasPendingDeadKey: false))
            check(english.render([KeyStroke(keyCode: 39)]) == LayoutRendering(text: "", hasPendingDeadKey: true))

            let privet = english.strokes(for: "ghbdtn") ?? []
            check(privet.count == 6)
            let boundaryCases: [(KeyStroke, String)] = [
                (shift6, "привет,"),
                (shift7, "привет."),
                (KeyStroke(keyCode: 18, shift: true), "привет!"),
                (KeyStroke(keyCode: 44, shift: true), "привет?"),
                (KeyStroke(keyCode: 23, shift: true), "привет:")
            ]
            for (boundary, expected) in boundaryCases {
                let correction = layoutClassifier.boundaryCorrection(
                    word: privet, boundary: boundary, source: english, target: russian
                )
                check(correction == LayoutCorrection(replacement: expected, deleteCount: 6, targetLanguage: .russian),
                      "boundary \(boundary): \(String(describing: correction))")
            }
            // `.` и `,` в русской раскладке — буквы `ю` и `б`: ждём пробела.
            check(layoutClassifier.boundaryCorrection(
                word: privet, boundary: KeyStroke(keyCode: 47), source: english, target: russian
            ) == nil)
            check(layoutClassifier.delimiterCorrection(strokes: privet, source: english, target: russian)
                == LayoutCorrection(replacement: "привет", deleteCount: 6, targetLanguage: .russian))
            check(layoutClassifier.delimiterCorrection(
                strokes: privet + [KeyStroke(keyCode: 47)], source: english, target: russian
            )?.replacement == "привет.")
            check(layoutClassifier.delimiterCorrection(
                strokes: privet + [KeyStroke(keyCode: 43)], source: english, target: russian
            )?.replacement == "привет,")
            check(layoutClassifier.delimiterCorrection(
                strokes: privet + [shift7], source: english, target: russian
            )?.replacement == "привет.")
            // Пробел после мёртвой клавиши завершает `^` в приложении: не трогаем.
            check(layoutClassifier.delimiterCorrection(
                strokes: privet + [shift6], source: english, target: russian
            ) == nil)
            check(layoutClassifier.delimiterCorrection(
                strokes: privet + [KeyStroke(keyCode: 18)], source: english, target: russian
            ) == nil)
            // `э` на мёртвой клавише `'`: на экране `'nj`, удаляем три символа.
            check(layoutClassifier.delimiterCorrection(
                strokes: [KeyStroke(keyCode: 39), KeyStroke(keyCode: 45), KeyStroke(keyCode: 38)],
                source: english, target: russian
            ) == LayoutCorrection(replacement: "это", deleteCount: 3, targetLanguage: .russian))
            // `'` + `y` не складываются: на экране `'ythubz`, семь символов.
            check(layoutClassifier.delimiterCorrection(
                strokes: [39, 16, 17, 4, 32, 11, 6].map { KeyStroke(keyCode: $0) },
                source: english, target: russian
            ) == LayoutCorrection(replacement: "энергия", deleteCount: 7, targetLanguage: .russian))
            // `'` + `c` складываются в `ç`: на экране `çrbp`, четыре символа.
            check(english.render([39, 8, 15, 11, 35].map { KeyStroke(keyCode: $0) }).text == "çrbp")
            check(layoutClassifier.delimiterCorrection(
                strokes: [39, 8, 15, 11, 35].map { KeyStroke(keyCode: $0) },
                source: english, target: russian
            ) == LayoutCorrection(replacement: "эскиз", deleteCount: 4, targetLanguage: .russian))
            // `ё` на клавише `\`, `Ж` на Shift+`;`.
            check(layoutClassifier.delimiterCorrection(
                strokes: [42, 40, 15, 3].map { KeyStroke(keyCode: $0) }, source: english, target: russian
            )?.replacement == "ёлка")
            check(layoutClassifier.delimiterCorrection(
                strokes: [KeyStroke(keyCode: 41, shift: true)] + [11, 35, 16, 46].map { KeyStroke(keyCode: $0) },
                source: english, target: russian
            )?.replacement == "Жизнь")
            check(layoutClassifier.delimiterCorrection(
                strokes: english.strokes(for: "ghbdtq") ?? [], source: english, target: russian
            ) == nil)
            check(layoutClassifier.boundaryCorrection(
                word: english.strokes(for: "hello") ?? [], boundary: shift6, source: english, target: russian
            ) == nil)
            check(layoutClassifier.delimiterCorrection(
                strokes: english.strokes(for: "ghbdtn1") ?? [], source: english, target: russian
            ) == nil)

            let hello = russian.strokes(for: "руддщ") ?? []
            check(hello.count == 5)
            check(layoutClassifier.boundaryCorrection(
                word: hello, boundary: KeyStroke(keyCode: 18, shift: true), source: russian, target: english
            )?.replacement == "hello!")
            check(layoutClassifier.delimiterCorrection(
                strokes: hello + [shift7], source: russian, target: english
            )?.replacement == "hello.")
            check(layoutClassifier.delimiterCorrection(
                strokes: hello + [KeyStroke(keyCode: 47)], source: russian, target: english
            )?.replacement == "hello.")

            let privetPC = us.strokes(for: "ghbdtn") ?? []
            check(layoutClassifier.boundaryCorrection(
                word: privetPC, boundary: shift7, source: us, target: ruPC
            )?.replacement == "привет?")
            check(layoutClassifier.delimiterCorrection(
                strokes: privetPC + [KeyStroke(keyCode: 44)], source: us, target: ruPC
            )?.replacement == "привет.")

            // Слова любой длины, включая однобуквенные «я», «в», «a», не должны
            // аварийно завершать перехват: прогоняем оба пути по всем клавишам.
            let probeStrokes = (0...50).flatMap { code in
                [KeyStroke(keyCode: UInt16(code)), KeyStroke(keyCode: UInt16(code), shift: true)]
            }
            var probeCount = 0
            for (source, target) in [(english, russian), (russian, english), (us, ruPC), (ruPC, us)] {
                for first in probeStrokes {
                    _ = layoutClassifier.delimiterCorrection(strokes: [first], source: source, target: target)
                    _ = layoutClassifier.boundaryCorrection(word: [first], boundary: shift6, source: source, target: target)
                    _ = layoutClassifier.delimiterCorrection(strokes: [first, shift6], source: source, target: target)
                    probeCount += 1
                }
            }
            check(probeCount == probeStrokes.count * 4)
            check(layoutClassifier.delimiterCorrection(strokes: [], source: english, target: russian) == nil)
            check(layoutClassifier.delimiterCorrection(
                strokes: english.strokes(for: "z") ?? [], source: english, target: russian
            ) == nil)
            check(layoutClassifier.delimiterCorrection(
                strokes: english.strokes(for: "fn") ?? [], source: english, target: russian
            ) == nil)
            check(layoutClassifier.delimiterCorrection(
                strokes: english.strokes(for: "lf.") ?? [], source: english, target: russian
            ) == nil)

            var token = KeystrokeToken()
            token.append(KeyStroke(keyCode: 39), layout: english)
            token.append(KeyStroke(keyCode: 14), layout: english)
            token.deleteBackward()
            check(token.strokes.isEmpty)
            token.reset()
            for stroke in english.strokes(for: "gh") ?? [] { token.append(stroke, layout: english) }
            token.append(KeyStroke(keyCode: 39), layout: english)
            token.deleteBackward()
            check(token.strokes == english.strokes(for: "gh"))
            token.deleteBackward()
            check(token.strokes == english.strokes(for: "g"))
            token.reset()
            token.append(KeyStroke(keyCode: 5), layout: english)
            token.append(KeyStroke(keyCode: 39), layout: english)
            token.append(KeyStroke(keyCode: 45), layout: english)
            token.deleteBackward()
            check(token.strokes.isEmpty, "unrecoverable delete must reset the word")
            token.append(KeyStroke(keyCode: 5), layout: english)
            token.append(KeyStroke(keyCode: 5), layout: russian)
            check(token.strokes(in: russian).count == 1 && token.strokes(in: english).isEmpty)
        }
        check(
            TranscriptNormalizer.normalize("  привет   мир , как дела?  ", language: .russian)
                == "Привет мир, как дела?"
        )
        check(
            TranscriptNormalizer.normalize("i think i can", language: .english)
                == "I think I can"
        )

        let pauseSegments = [
            TimedSpeechSegment(text: "сегодня", timestamp: 0.0, duration: 0.4),
            TimedSpeechSegment(text: "хорошая", timestamp: 0.5, duration: 0.4),
            TimedSpeechSegment(text: "погода", timestamp: 1.0, duration: 0.5),
            TimedSpeechSegment(text: "пойдём", timestamp: 2.8, duration: 0.4),
            TimedSpeechSegment(text: "гулять", timestamp: 3.3, duration: 0.4)
        ]
        check(
            AutomaticPunctuation.restore(
                formattedTranscript: "сегодня хорошая погода пойдём гулять",
                segments: pauseSegments,
                language: .russian
            ) == "Сегодня хорошая погода. Пойдём гулять."
        )
        check(
            AutomaticPunctuation.restore(
                formattedTranscript: "do you speak English",
                segments: [],
                language: .english
            ) == "do you speak English?"
        )
        check(
            AutomaticPunctuation.restore(
                formattedTranscript: "почему это не работает",
                segments: [],
                language: .russian
            ) == "почему это не работает?"
        )
        check(
            AutomaticPunctuation.restore(
                formattedTranscript: "Он спросил: «почему?»",
                segments: [],
                language: .russian
            ) == "Он спросил: «почему?»"
        )
        check(
            AutomaticPunctuation.restore(
                formattedTranscript: "Done (!)",
                segments: [],
                language: .english
            ) == "Done (!)"
        )
        check(
            AutomaticPunctuation.restore(
                formattedTranscript: "Hello, world!",
                segments: [
                    TimedSpeechSegment(text: "Hello", timestamp: 0, duration: 0.3),
                    TimedSpeechSegment(text: "world", timestamp: 0.35, duration: 0.3)
                ],
                language: .english,
                preserveFormattedTranscript: true
            ) == "Hello, world!"
        )
        check(
            AutomaticPunctuation.restore(
                formattedTranscript: "подожди…",
                segments: [],
                language: .russian
            ) == "подожди…"
        )
        check(
            AutomaticPunctuation.restore(
                formattedTranscript: "hello )",
                segments: [
                    TimedSpeechSegment(text: "hello!", timestamp: 0, duration: 0.3),
                    TimedSpeechSegment(text: ")", timestamp: 0.3, duration: 0.05)
                ],
                language: .english
            ) == "Hello!)"
        )

        // Русская модель Apple возвращает текст без знаков: Punto ставит их сам.
        func spoken(_ text: String, pauses: [Int: TimeInterval] = [:]) -> [TimedSpeechSegment] {
            var time: TimeInterval = 0
            return text.split(separator: " ").enumerated().map { index, word in
                time += pauses[index] ?? 0.05
                defer { time += 0.3 }
                return TimedSpeechSegment(text: String(word), timestamp: time, duration: 0.3, confidence: 0.9)
            }
        }
        func punctuate(_ text: String, pauses: [Int: TimeInterval] = [:], language: SpeechLanguage = .russian) -> String {
            TranscriptNormalizer.normalize(
                AutomaticPunctuation.restore(
                    formattedTranscript: text,
                    segments: spoken(text, pauses: pauses),
                    language: language,
                    preserveFormattedTranscript: language != .automatic
                ),
                language: language
            )
        }
        let punctuationCases: [(String, [Int: TimeInterval], String)] = [
            // Ваша запись: пауза 0,75 с после «Привет».
            ("Привет ты меня слышишь", [1: 0.75], "Привет, ты меня слышишь?"),
            ("Привет ты меня слышишь", [:], "Привет, ты меня слышишь?"),
            ("вы меня слышите", [:], "Вы меня слышите?"),
            ("ты дома", [:], "Ты дома?"),
            ("привет как дела", [:], "Привет, как дела?"),
            ("знаю что ты прав", [:], "Знаю, что ты прав."),
            ("это тот файл который я искал", [:], "Это тот файл, который я искал."),
            ("дом в котором я живу", [:], "Дом в котором я живу."),
            ("я опоздал так что извини", [:], "Я опоздал так что извини."),
            ("привет что делаешь", [:], "Привет, что делаешь?"),
            ("добрый день как у вас дела", [:], "Добрый день, как у вас дела?"),
            ("ты справишься", [:], "Ты справишься."),
            ("я знаю где он живёт", [:], "Я знаю, где он живёт."),
            ("я хотел но не успел", [:], "Я хотел, но не успел."),
            ("сделай это чтобы проверить", [:], "Сделай это, чтобы проверить."),
            ("я пришёл потому что ты звал", [:], "Я пришёл, потому что ты звал."),
            ("я позвоню когда приеду", [:], "Я позвоню, когда приеду."),
            ("а если не получится", [:], "А если не получится."),
            ("но я не знаю", [:], "Но я не знаю."),
            ("у меня другая точка зрения", [:], "У меня другая точка зрения."),
            ("это всё точка", [:], "Это всё."),
            ("привет запятая ты меня слышишь вопросительный знак", [:], "Привет, ты меня слышишь?"),
            ("отлично восклицательный знак", [:], "Отлично!"),
            ("как дела я дома", [2: 1.3], "Как дела? Я дома."),
            ("сегодня тепло пойдём гулять", [2: 1.3], "Сегодня тепло. Пойдём гулять.")
        ]
        for (text, pauses, expected) in punctuationCases {
            let actual = punctuate(text, pauses: pauses)
            check(actual == expected, "punctuation: \(text) -> \(actual), expected \(expected)")
        }
        // Английский распознаватель сам ставит знаки: текст сохраняется.
        check(
            AutomaticPunctuation.restore(
                formattedTranscript: "Hello, can you hear me",
                segments: spoken("Hello can you hear me"),
                language: .english,
                preserveFormattedTranscript: true
            ) == "Hello, can you hear me?"
        )
        check(
            AutomaticPunctuation.restore(
                formattedTranscript: "Thanks, have a nice day",
                segments: spoken("Thanks have a nice day"),
                language: .english,
                preserveFormattedTranscript: true
            ) == "Thanks, have a nice day."
        )
        check(punctuate("hello how are you", language: .english) == "Hello, how are you?")
        check(punctuate("открой Claude чтобы проверить", language: .automatic) == "Открой Claude, чтобы проверить.")

        let correctRussianScore = SpeechCandidateScorer.score(
            transcript: "транскрибирует мой текст прямо в окне ввода",
            language: .russian,
            acousticConfidence: 0.68,
            languageProbabilityOverride: 0.98,
            spellingRatioOverride: 0.92,
            scriptCompatibilityOverride: 1
        )
        let wrongEnglishScore = SpeechCandidateScorer.score(
            transcript: "Prima Wakia Voda",
            language: .english,
            acousticConfidence: 0.91,
            languageProbabilityOverride: 0.08,
            spellingRatioOverride: 0.30,
            scriptCompatibilityOverride: 1
        )
        check(correctRussianScore > wrongEnglishScore)

        let unknownTermScore = SpeechCandidateScorer.score(
            transcript: "OpenAI",
            language: .english,
            acousticConfidence: 0.90,
            languageProbabilityOverride: 0.10,
            spellingRatioOverride: 0,
            scriptCompatibilityOverride: 1
        )
        let wrongScriptScore = SpeechCandidateScorer.score(
            transcript: "опенай",
            language: .english,
            acousticConfidence: 0.90,
            languageProbabilityOverride: 0.10,
            spellingRatioOverride: 0,
            scriptCompatibilityOverride: 0
        )
        check(unknownTermScore > wrongScriptScore)
        let genericPrivetScore = SpeechCandidateScorer.score(
            transcript: "Privet",
            language: .english,
            acousticConfidence: 0.95,
            languageProbabilityOverride: 0.05,
            spellingRatioOverride: 0,
            scriptCompatibilityOverride: 1
        )
        let correctPrivetScore = SpeechCandidateScorer.score(
            transcript: "привет",
            language: .russian,
            acousticConfidence: 0.65,
            languageProbabilityOverride: 0.98,
            spellingRatioOverride: 1,
            scriptCompatibilityOverride: 1
        )
        check(correctPrivetScore > genericPrivetScore)
        for term in ["Claude", "OpenAI", "GitHub", "API"] {
            let score = SpeechCandidateScorer.score(
                transcript: term,
                language: .english,
                acousticConfidence: 0.90,
                languageProbabilityOverride: 0.10,
                spellingRatioOverride: 0,
                scriptCompatibilityOverride: 1
            )
            check(score > genericPrivetScore, "expected term support for \(term)")
        }

        let russianMixedCandidate = SpeechTranscriptCandidate(language: .russian, segments: [
            TimedSpeechSegment(text: "транскрибирует", timestamp: 0.0, duration: 0.4, confidence: 0.94),
            TimedSpeechSegment(text: "мой", timestamp: 0.55, duration: 0.3, confidence: 0.91),
            TimedSpeechSegment(text: "клауд", timestamp: 1.30, duration: 0.4, confidence: 0.22),
            TimedSpeechSegment(text: "панель", timestamp: 1.85, duration: 0.4, confidence: 0.30)
        ])
        let englishMixedCandidate = SpeechTranscriptCandidate(language: .english, segments: [
            TimedSpeechSegment(text: "transcribes", timestamp: 0.0, duration: 0.4, confidence: 0.25),
            TimedSpeechSegment(text: "mine", timestamp: 0.55, duration: 0.3, confidence: 0.28),
            TimedSpeechSegment(text: "Claude", timestamp: 1.30, duration: 0.4, confidence: 0.96),
            TimedSpeechSegment(text: "panel", timestamp: 1.85, duration: 0.4, confidence: 0.92)
        ])
        let mixedSelection = MixedLanguageTranscriptBuilder.select(
            from: [russianMixedCandidate, englishMixedCandidate]
        ) { text, language, _ in
            if language == .russian, ["транскрибирует", "мой"].contains(text) { return 0.95 }
            if language == .english, ["Claude", "panel"].contains(text) { return 0.96 }
            return 0.15
        }
        check(mixedSelection?.segments.map(\.text) == ["транскрибирует", "мой", "Claude", "panel"])
        check(mixedSelection?.languages == [.russian, .english])

        let shiftedRussian = SpeechTranscriptCandidate(language: .russian, segments: [
            TimedSpeechSegment(text: "открой", timestamp: 0.00, duration: 0.42, confidence: 0.92),
            TimedSpeechSegment(text: "Клод", timestamp: 0.46, duration: 0.34, confidence: 0.30),
            TimedSpeechSegment(text: "сейчас", timestamp: 0.84, duration: 0.40, confidence: 0.91)
        ])
        let splitEnglish = SpeechTranscriptCandidate(language: .english, segments: [
            TimedSpeechSegment(text: "open", timestamp: 0.03, duration: 0.21, confidence: 0.25),
            TimedSpeechSegment(text: "it", timestamp: 0.26, duration: 0.18, confidence: 0.24),
            TimedSpeechSegment(text: "Claude", timestamp: 0.49, duration: 0.31, confidence: 0.97),
            TimedSpeechSegment(text: "now", timestamp: 0.88, duration: 0.39, confidence: 0.28)
        ])
        let alignedSelection = MixedLanguageTranscriptBuilder.select(
            from: [splitEnglish, shiftedRussian]
        ) { text, language, _ in
            if language == .russian, ["открой", "сейчас"].contains(text) { return 0.94 }
            if language == .english, text == "Claude" { return 0.99 }
            return 0.10
        }
        check(alignedSelection?.segments.map(\.text) == ["открой", "Claude", "сейчас"])

        let alternatingRussian = SpeechTranscriptCandidate(language: .russian, segments: [
            TimedSpeechSegment(text: "русский", timestamp: 0, duration: 0.3, confidence: 0.8),
            TimedSpeechSegment(text: "термин", timestamp: 0.35, duration: 0.3, confidence: 0.8),
            TimedSpeechSegment(text: "снова", timestamp: 0.70, duration: 0.3, confidence: 0.8)
        ])
        let alternatingEnglish = SpeechTranscriptCandidate(language: .english, segments: [
            TimedSpeechSegment(text: "Russian", timestamp: 0, duration: 0.3, confidence: 0.8),
            TimedSpeechSegment(text: "API", timestamp: 0.35, duration: 0.3, confidence: 0.8),
            TimedSpeechSegment(text: "again", timestamp: 0.70, duration: 0.3, confidence: 0.8)
        ])
        let decodedSelection = MixedLanguageTranscriptBuilder.select(
            from: [alternatingRussian, alternatingEnglish]
        ) { text, language, _ in
            if language == .russian, ["русский", "снова"].contains(text) { return 0.90 }
            if language == .english, text == "API" { return 0.90 }
            return 0.20
        }
        check(decodedSelection?.segments.map(\.text) == ["русский", "API", "снова"])

        let tiedSelection = MixedLanguageTranscriptBuilder.select(
            from: [alternatingRussian, alternatingEnglish]
        ) { _, _, _ in 0.5 }
        check(tiedSelection?.segments.map(\.text) == ["Russian", "API", "again"])
        let reversedTiedSelection = MixedLanguageTranscriptBuilder.select(
            from: [alternatingEnglish, alternatingRussian]
        ) { _, _, _ in 0.5 }
        check(reversedTiedSelection?.segments.map(\.text) == tiedSelection?.segments.map(\.text))

        let malformedSelection = MixedLanguageTranscriptBuilder.select(from: [
            SpeechTranscriptCandidate(language: .russian, segments: [
                TimedSpeechSegment(text: "", timestamp: 0, duration: 0.2),
                TimedSpeechSegment(text: "привет", timestamp: -.infinity, duration: 0.2)
            ]),
            SpeechTranscriptCandidate(language: .english, segments: [
                TimedSpeechSegment(text: "hello", timestamp: 0, duration: .nan)
            ])
        ])
        check(malformedSelection?.segments.map(\.text) == ["hello"])
        check(MixedLanguageTranscriptBuilder.select(from: []) == nil)

        let disjointSelection = MixedLanguageTranscriptBuilder.select(from: [
            SpeechTranscriptCandidate(language: .english, segments: [
                TimedSpeechSegment(text: "hello", timestamp: 0, duration: 0.3, confidence: 0.9)
            ]),
            SpeechTranscriptCandidate(language: .russian, segments: [
                TimedSpeechSegment(text: "хэлло", timestamp: 0.76, duration: 0.3, confidence: 0.7)
            ])
        ]) { _, language, _ in language == .english ? 0.9 : 0.6 }
        check(disjointSelection?.segments.map(\.text) == ["hello"])

        let noisySelection = MixedLanguageTranscriptBuilder.select(from: [
            SpeechTranscriptCandidate(language: .english, segments: [
                TimedSpeechSegment(text: "hello", timestamp: 0, duration: 0.3, confidence: 0.9)
            ]),
            SpeechTranscriptCandidate(language: .russian, segments: [
                TimedSpeechSegment(text: "хэлло", timestamp: 0, duration: 0.3),
                TimedSpeechSegment(text: "шум1", timestamp: 0.35, duration: 0.2),
                TimedSpeechSegment(text: "шум2", timestamp: 0.60, duration: 0.2),
                TimedSpeechSegment(text: "шум3", timestamp: 0.85, duration: 0.2)
            ])
        ]) { _, language, _ in language == .english ? 0.9 : 0.4 }
        check(noisySelection?.segments.map(\.text) == ["hello"])

        let driftRussian = SpeechTranscriptCandidate(
            language: .russian,
            segments: [
                TimedSpeechSegment(text: "привет", timestamp: 0, duration: 0.30),
                TimedSpeechSegment(text: "апи", timestamp: 0.35, duration: 0.30),
                TimedSpeechSegment(text: "сейчас", timestamp: 0.70, duration: 0.30)
            ],
            formattedTranscript: "Привет, апи!"
        )
        let driftEnglish = SpeechTranscriptCandidate(
            language: .english,
            segments: [
                TimedSpeechSegment(text: "hello", timestamp: 0.02, duration: 0.28),
                TimedSpeechSegment(text: "API", timestamp: 0.36, duration: 0.28),
                TimedSpeechSegment(text: "now", timestamp: 0.72, duration: 0.51)
            ],
            formattedTranscript: "Hello, API!"
        )
        let driftSelection = MixedLanguageTranscriptBuilder.select(
            from: [driftRussian, driftEnglish]
        ) { text, language, _ in
            if language == .russian, ["привет", "сейчас"].contains(text) { return 0.95 }
            if language == .english, text == "API" { return 0.99 }
            return 0.10
        }
        check(driftSelection?.segments.map(\.text) == ["привет", "API", "сейчас"])
        check(driftSelection?.formattedTranscript == "привет API сейчас!")

        let gapFilledSelection = MixedLanguageTranscriptBuilder.select(from: [
            SpeechTranscriptCandidate(language: .russian, segments: [
                TimedSpeechSegment(text: "открой", timestamp: 0, duration: 0.4, confidence: 0.9),
                TimedSpeechSegment(text: "сейчас", timestamp: 1.3, duration: 0.4, confidence: 0.9)
            ]),
            SpeechTranscriptCandidate(language: .english, segments: [
                TimedSpeechSegment(text: "a crow", timestamp: 0, duration: 0.4, confidence: 0.2),
                TimedSpeechSegment(text: "Claude", timestamp: 0.6, duration: 0.5, confidence: 0.6),
                TimedSpeechSegment(text: "say chess", timestamp: 1.3, duration: 0.4, confidence: 0.2)
            ])
        ]) { text, language, _ in
            if language == .russian { return 0.9 }
            return text == "Claude" ? 0.95 : 0.1
        }
        check(gapFilledSelection?.segments.map(\.text) == ["открой", "Claude", "сейчас"])

        let weakGapSelection = MixedLanguageTranscriptBuilder.select(from: [
            SpeechTranscriptCandidate(language: .russian, segments: [
                TimedSpeechSegment(text: "открой", timestamp: 0, duration: 0.4, confidence: 0.9),
                TimedSpeechSegment(text: "сейчас", timestamp: 1.3, duration: 0.4, confidence: 0.9)
            ]),
            SpeechTranscriptCandidate(language: .english, segments: [
                TimedSpeechSegment(text: "the", timestamp: 0.6, duration: 0.5, confidence: 0.3)
            ])
        ]) { _, language, _ in language == .russian ? 0.9 : 0.6 }
        check(weakGapSelection?.segments.map(\.text) == ["открой", "сейчас"])

        let mergedBaseSelection = MixedLanguageTranscriptBuilder.select(from: [
            SpeechTranscriptCandidate(language: .russian, segments: [
                TimedSpeechSegment(text: "проверь код на гитхабе", timestamp: 0, duration: 2.0, confidence: 0.8)
            ]),
            SpeechTranscriptCandidate(language: .english, segments: [
                TimedSpeechSegment(text: "GitHub", timestamp: 1.4, duration: 0.5, confidence: 0.9)
            ])
        ]) { text, language, _ in
            if language == .russian { return 0.7 }
            return text == "GitHub" ? 0.99 : 0.1
        }
        check(mergedBaseSelection?.segments.map(\.text) == ["проверь код на гитхабе"])

        let edgeTermSelection = MixedLanguageTranscriptBuilder.select(from: [
            SpeechTranscriptCandidate(language: .russian, segments: [
                TimedSpeechSegment(text: "я", timestamp: 0.39, duration: 0.21, confidence: 0.95),
                TimedSpeechSegment(text: "открыл", timestamp: 0.60, duration: 1.02, confidence: 0.85),
                TimedSpeechSegment(text: "чтобы", timestamp: 2.31, duration: 0.48, confidence: 0.98)
            ]),
            SpeechTranscriptCandidate(language: .english, segments: [
                TimedSpeechSegment(text: "add", timestamp: 0.45, duration: 0.24, confidence: 0.49),
                TimedSpeechSegment(text: "grill", timestamp: 0.69, duration: 0.36, confidence: 0.33),
                TimedSpeechSegment(text: "Claude,", timestamp: 1.20, duration: 1.11, confidence: 0.09),
                TimedSpeechSegment(text: "stubborn cleaner", timestamp: 2.31, duration: 3.69, confidence: 0.08)
            ])
        ]) { text, language, _ in
            if language == .russian { return 0.9 }
            return text == "Claude," ? 0.95 : 0.1
        }
        check(edgeTermSelection?.segments.map(\.text) == ["я", "открыл", "Claude,", "чтобы"])

        let splitTermSelection = MixedLanguageTranscriptBuilder.select(from: [
            SpeechTranscriptCandidate(language: .russian, segments: [
                TimedSpeechSegment(text: "открой", timestamp: 0, duration: 0.4, confidence: 0.9),
                TimedSpeechSegment(text: "гитхаб", timestamp: 0.5, duration: 0.6, confidence: 0.2)
            ]),
            SpeechTranscriptCandidate(language: .english, segments: [
                TimedSpeechSegment(text: "a crow", timestamp: 0, duration: 0.4, confidence: 0.2),
                TimedSpeechSegment(text: "get", timestamp: 0.5, duration: 0.3, confidence: 0.6),
                TimedSpeechSegment(text: "hub", timestamp: 0.8, duration: 0.3, confidence: 0.6)
            ])
        ]) { text, language, _ in
            if language == .russian { return text == "гитхаб" ? 0.2 : 0.9 }
            return text == "get hub" ? 0.95 : 0.25
        }
        check(splitTermSelection?.segments.map(\.text) == ["открой", "get", "hub"])

        check(SpeechCandidateScorer.isStrongTerm("Claude,"))
        check(SpeechCandidateScorer.isStrongTerm("Kubernetes"))
        check(SpeechCandidateScorer.isStrongTerm("OpenAI"))
        check(SpeechCandidateScorer.isStrongTerm("HTTP2"))
        check(!SpeechCandidateScorer.isStrongTerm("stubborn cleaner"))
        check(!SpeechCandidateScorer.isStrongTerm("клауд"))
        check(!SpeechCandidateScorer.isStrongTerm(","))

        let segmentlessSelection = RecognitionFinalizationSelector.select(
            from: [
                RecognitionCandidateSnapshot(
                    language: .english,
                    transcript: "hello",
                    segments: [],
                    confidence: 0.8,
                    status: .final
                ),
                RecognitionCandidateSnapshot(
                    language: .russian,
                    transcript: "хэлло",
                    segments: [TimedSpeechSegment(text: "хэлло", timestamp: 0, duration: 0.3)],
                    confidence: 0.8,
                    status: .final
                )
            ],
            requestedLanguage: .automatic,
            timedOut: false,
            scoreProvider: { _, language, _ in language == .english ? 1 : 0 }
        )
        check(segmentlessSelection?.formattedTranscript == "hello")

        check(
            RecognitionCallbackPolicy.status(
                previous: .waiting,
                receivedResult: true,
                resultIsFinal: true,
                receivedError: true
            ) == .final
        )
        check(
            RecognitionCallbackPolicy.status(
                previous: .partial,
                receivedResult: false,
                resultIsFinal: false,
                receivedError: true
            ) == .failedWithPartial
        )
        check(
            RecognitionCallbackPolicy.status(
                previous: .partial,
                receivedResult: true,
                resultIsFinal: false,
                receivedError: true
            ) == .failedWithPartial
        )
        check(
            RecognitionCallbackPolicy.status(
                previous: .final,
                receivedResult: true,
                resultIsFinal: false,
                receivedError: false
            ) == .final
        )
        check(
            !RecognitionCallbackPolicy.shouldReplaceData(
                previous: .final,
                receivedResult: true
            )
        )

        let failedSnapshot = RecognitionCandidateSnapshot(
            language: .english,
            transcript: "wrong",
            segments: [TimedSpeechSegment(text: "wrong", timestamp: 0, duration: 0.3)],
            confidence: 0.99,
            status: .failed
        )
        let healthySnapshot = RecognitionCandidateSnapshot(
            language: .russian,
            transcript: "правильно",
            segments: [TimedSpeechSegment(text: "правильно", timestamp: 0, duration: 0.3)],
            confidence: 0.5,
            status: .final
        )
        check(
            RecognitionFinalizationSelector.select(
                from: [failedSnapshot, healthySnapshot],
                requestedLanguage: .automatic,
                timedOut: false,
                scoreProvider: { _, language, _ in language == .english ? 1 : 0 }
            )?.formattedTranscript == "правильно"
        )
        let partialSnapshot = RecognitionCandidateSnapshot(
            language: .english,
            transcript: "recoverable",
            segments: [TimedSpeechSegment(text: "recoverable", timestamp: 0, duration: 0.3)],
            confidence: 0.7,
            status: .partial
        )
        check(
            RecognitionFinalizationSelector.eligibleSnapshots(
                from: [failedSnapshot, partialSnapshot],
                timedOut: true
            ).map(\.transcript) == ["recoverable"]
        )
        let secondPartialSnapshot = RecognitionCandidateSnapshot(
            language: .russian,
            transcript: "частичный",
            segments: [TimedSpeechSegment(text: "частичный", timestamp: 0, duration: 0.3)],
            confidence: 0.6,
            status: .partial
        )
        check(
            RecognitionFinalizationSelector.eligibleSnapshots(
                from: [partialSnapshot, secondPartialSnapshot],
                timedOut: true
            ).count == 2
        )
        check(
            RecognitionFinalizationSelector.eligibleSnapshots(
                from: [healthySnapshot, partialSnapshot],
                timedOut: true
            ).count == 2
        )
        let terminalPartialSnapshot = RecognitionCandidateSnapshot(
            language: .english,
            transcript: "API",
            segments: [TimedSpeechSegment(text: "API", timestamp: 0, duration: 0.3)],
            confidence: 0.8,
            status: .failedWithPartial
        )
        check(
            RecognitionFinalizationSelector.eligibleSnapshots(
                from: [healthySnapshot, terminalPartialSnapshot],
                timedOut: false
            ).count == 2
        )
        check(
            RecognitionFinalizationSelector.eligibleSnapshots(
                from: [failedSnapshot, partialSnapshot],
                timedOut: false
            ).isEmpty
        )
        let tiedEnglish = RecognitionCandidateSnapshot(
            language: .english,
            transcript: "same",
            segments: [TimedSpeechSegment(text: "same", timestamp: 0, duration: 0.3)],
            confidence: 0.7,
            status: .final
        )
        let tiedRussian = RecognitionCandidateSnapshot(
            language: .russian,
            transcript: "то же",
            segments: [TimedSpeechSegment(text: "то же", timestamp: 0, duration: 0.3)],
            confidence: 0.7,
            status: .final
        )
        let tieA = RecognitionFinalizationSelector.select(
            from: [tiedRussian, tiedEnglish],
            requestedLanguage: .automatic,
            timedOut: false,
            scoreProvider: { _, _, _ in 0.5 }
        )
        let tieB = RecognitionFinalizationSelector.select(
            from: [tiedEnglish, tiedRussian],
            requestedLanguage: .automatic,
            timedOut: false,
            scoreProvider: { _, _, _ in 0.5 }
        )
        check(tieA?.formattedTranscript == tieB?.formattedTranscript)

        check(
            RecognitionCompletionPolicy.decision(
                phase: .listening,
                statuses: [.final, .final],
                hasEligibleText: true
            ) == .wait
        )
        check(
            RecognitionCompletionPolicy.decision(
                phase: .listening,
                statuses: [.failed, .failed],
                hasEligibleText: false
            ) == .failNoText
        )
        check(
            RecognitionCompletionPolicy.decision(
                phase: .processing,
                statuses: [.final, .final],
                hasEligibleText: true
            ) == .deliver
        )
        check(
            RecognitionCompletionPolicy.decision(
                phase: .processing,
                statuses: [.failed, .final],
                hasEligibleText: true
            ) == .deliver
        )
        check(
            RecognitionCompletionPolicy.decision(
                phase: .processing,
                statuses: [.partial, .waiting],
                hasEligibleText: false
            ) == .wait
        )
        check(
            RecognitionCompletionPolicy.decision(
                phase: .processing,
                statuses: [.partial, .waiting],
                hasEligibleText: true,
                timedOut: true
            ) == .deliver
        )
        check(
            RecognitionCompletionPolicy.decision(
                phase: .processing,
                statuses: [.partial, .waiting],
                hasEligibleText: false,
                timedOut: true
            ) == .failNoText
        )
        check(SpeechDictationState.listeningDegraded(.english).isListening)
        check(!SpeechDictationState.processing.isListening)

        let shortcutIDs = VoiceShortcut.presets.map(\.id)
        check(Set(shortcutIDs).count == shortcutIDs.count, "voice shortcut ids must be unique")
        let defaultShortcut = VoiceShortcut.default
        check(defaultShortcut.id == "option-space")
        check(defaultShortcut.matches(keyCode: 49, flags: [.maskAlternate]))
        check(defaultShortcut.matches(keyCode: 49, flags: [.maskAlternate, .maskAlphaShift]))
        check(!defaultShortcut.matches(keyCode: 49, flags: [.maskAlternate, .maskCommand]))
        check(!defaultShortcut.matches(keyCode: 49, flags: [.maskAlternate, .maskShift]))
        check(!defaultShortcut.matches(keyCode: 49, flags: []))
        check(!defaultShortcut.matches(keyCode: 2, flags: [.maskAlternate]))
        let fnShortcut = VoiceShortcut.preset(id: "fn-space")
        check(fnShortcut?.matches(keyCode: 49, flags: [.maskSecondaryFn]) == true)
        check(fnShortcut?.matches(keyCode: 49, flags: [.maskSecondaryFn, .maskAlternate]) == false)
        check(defaultShortcut.matches(keyCode: 49, flags: [.maskAlternate, .maskSecondaryFn]) == false)
        let threeKeyShortcut = VoiceShortcut.preset(id: "control-option-space")
        check(threeKeyShortcut?.matches(keyCode: 49, flags: [.maskControl, .maskAlternate]) == true)
        check(threeKeyShortcut?.matches(keyCode: 49, flags: [.maskControl]) == false)

        let controlFn = VoiceShortcut.preset(id: "control-fn")
        check(controlFn?.isModifierOnly == true)
        check(controlFn?.matches(keyCode: 49, flags: [.maskControl, .maskSecondaryFn]) == false)
        let chordTarget: CGEventFlags = [.maskControl, .maskSecondaryFn]
        func chord(_ steps: [(CGEventFlags?, TimeInterval)]) -> [Bool] {
            var detector = ModifierChordDetector()
            return steps.map { flags, time in
                guard let flags else {
                    detector.keyDown()
                    return false
                }
                return detector.flagsChanged(flags, target: chordTarget, at: time)
            }
        }
        // Control, затем Fn; отпускаем Fn, затем Control.
        check(chord([([.maskControl], 0), (chordTarget, 0.1), ([.maskControl], 0.2), ([], 0.25)])
            == [false, false, false, true])
        // Fn, затем Control; Caps Lock не мешает.
        check(chord([([.maskSecondaryFn, .maskAlphaShift], 0), ([.maskSecondaryFn, .maskControl, .maskAlphaShift], 0.1),
                     ([.maskAlphaShift], 0.2)]) == [false, false, true])
        // Fn–Control–F2 и подобные: между ними нажата клавиша.
        check(chord([([.maskControl], 0), (chordTarget, 0.1), (nil, 0.15), ([], 0.3)]).last == false)
        // Лишний модификатор, один Control, слишком долго.
        check(chord([([.maskControl], 0), (chordTarget.union(.maskShift), 0.1), ([], 0.2)]).last == false)
        check(chord([([.maskControl], 0), ([], 0.1)]).last == false)
        check(chord([([.maskControl], 0), (chordTarget, 0.1), ([], 1.5)]).last == false)
        // После срабатывания детектор готов к следующему аккорду.
        check(chord([([.maskControl], 0), (chordTarget, 0.1), ([], 0.2),
                     ([.maskSecondaryFn], 1.0), (chordTarget, 1.1), ([], 1.2)]) == [false, false, true, false, false, true])

        let systemHotkeys = [
            SystemHotkey(id: 60, keyCode: 49, modifiers: [.maskControl], isEnabled: true),
            SystemHotkey(id: 61, keyCode: 49, modifiers: [.maskControl, .maskAlternate], isEnabled: true),
            SystemHotkey(id: 64, keyCode: 49, modifiers: [.maskCommand], isEnabled: true),
            SystemHotkey(id: 65, keyCode: 49, modifiers: [.maskCommand, .maskAlternate], isEnabled: false)
        ]
        check(VoiceShortcut.preset(id: "control-space")?.systemConflict(in: systemHotkeys)?.id == 60)
        check(threeKeyShortcut?.systemConflict(in: systemHotkeys)?.id == 61)
        check(defaultShortcut.systemConflict(in: systemHotkeys) == nil)
        check(fnShortcut?.systemConflict(in: systemHotkeys) == nil)
        check(controlFn?.systemConflict(in: systemHotkeys) == nil)
        check(VoiceShortcut.preset(id: "control-space")?.systemConflict(in: []) == nil)
        let letterShortcut = VoiceShortcut.preset(id: "control-option-d")
        check(letterShortcut?.matches(keyCode: 2, flags: [.maskControl, .maskAlternate]) == true)
        check(letterShortcut?.matches(keyCode: 49, flags: [.maskControl, .maskAlternate]) == false)
        check(VoiceShortcut.preset(id: "unknown") == nil)
        let shortcutDefaults = UserDefaults(suiteName: "local.punto.selftest")!
        shortcutDefaults.removePersistentDomain(forName: "local.punto.selftest")
        check(VoiceShortcut.load(from: shortcutDefaults) == .default)
        VoiceShortcut.preset(id: "command-shift-space")?.save(to: shortcutDefaults)
        check(VoiceShortcut.load(from: shortcutDefaults).id == "command-shift-space")
        shortcutDefaults.set("unknown", forKey: "voiceShortcut")
        check(VoiceShortcut.load(from: shortcutDefaults) == .default)
        shortcutDefaults.removePersistentDomain(forName: "local.punto.selftest")

        // Значок: контур знака разбирается в квадрат и букву с отверстием.
        check(PuntoIcon.subpaths.count == 3)
        let signBox = PuntoIcon.signBounds
        check(abs(signBox.minX) < 0.01 && abs(signBox.minY - 32) < 0.01
            && abs(signBox.width - 448) < 0.01 && abs(signBox.height - 448) < 0.01)
        let letterBox = PuntoIcon.subpaths[1].boundingBoxOfPath
        check(abs(letterBox.minX - 128) < 0.01 && abs(letterBox.maxX - 336) < 0.01
            && abs(letterBox.minY - 128) < 0.01 && abs(letterBox.maxY - 384) < 0.01)
        let holeBox = PuntoIcon.subpaths[2].boundingBoxOfPath
        check(abs(holeBox.minX - 192) < 0.01 && abs(holeBox.maxX - 272) < 0.01
            && abs(holeBox.minY - 192) < 0.01 && abs(holeBox.maxY - 256) < 0.01)
        check(SVGPathParser.subpaths(from: "M0 0L10 0l0 10z")?.first?.boundingBoxOfPath
            == CGRect(x: 0, y: 0, width: 10, height: 10))
        check(SVGPathParser.subpaths(from: "") == nil)
        check(PuntoIcon.menuBarImage(.idle).isTemplate)
        check(!PuntoIcon.menuBarImage(.listening).isTemplate)
        check(PuntoIcon.appIcon(pixels: 64)?.width == 64)

        print("Punto self-test: OK (\(checkCount) checks)")
    }
}
