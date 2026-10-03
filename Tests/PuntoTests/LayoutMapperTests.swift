import XCTest
@testable import Punto

final class LayoutMapperTests: XCTestCase {
    func testEnglishKeysBecomeRussianText() {
        XCTAssertEqual(LayoutMapper.convert("ghbdtn", to: .russian), "привет")
        XCTAssertEqual(LayoutMapper.convert("Vbh", to: .russian), "Мир")
        XCTAssertEqual(LayoutMapper.convert(";bpym", to: .russian), "жизнь")
        XCTAssertEqual(LayoutMapper.convert("\"nj", to: .russian), "Это")
    }

    func testRussianKeysBecomeEnglishText() {
        XCTAssertEqual(LayoutMapper.convert("руддщ", to: .english), "hello")
        XCTAssertEqual(LayoutMapper.convert("Цщкдв", to: .english), "World")
        XCTAssertEqual(LayoutMapper.convert("Этаж", to: .english), "\"nf;")
    }

    func testMixedScriptsAreNotClassified() {
        XCTAssertNil(LayoutMapper.detectedLanguage(of: "helло"))
    }
}

final class MixedLanguageTranscriptBuilderTests: XCTestCase {
    func testSelectsRussianEnglishRussianWithDifferentSegmentation() {
        let russian = candidate(.russian, [
            segment("открой", 0.00, 0.42, 0.92), segment("Клод", 0.46, 0.34, 0.30),
            segment("сейчас", 0.84, 0.40, 0.91)
        ])
        let english = candidate(.english, [
            segment("open", 0.03, 0.21, 0.25), segment("it", 0.26, 0.18, 0.24),
            segment("Claude", 0.49, 0.31, 0.97), segment("now", 0.88, 0.39, 0.28)
        ])
        let selection = MixedLanguageTranscriptBuilder.select(from: [english, russian]) { text, language, _ in
            if language == .russian, ["открой", "сейчас"].contains(text) { return 0.94 }
            if language == .english, text == "Claude" { return 0.99 }
            return 0.10
        }
        XCTAssertEqual(selection?.segments.map(\.text), ["открой", "Claude", "сейчас"])
    }

    func testSwitchPenaltyAvoidsActualMarginalOscillation() {
        let russian = candidate(.russian, [
            segment("раз", 0, 0.3), segment("два", 0.35, 0.3), segment("три", 0.70, 0.3)
        ])
        let english = candidate(.english, [
            segment("one", 0, 0.3), segment("two", 0.35, 0.3), segment("three", 0.70, 0.3)
        ])
        let selection = MixedLanguageTranscriptBuilder.select(from: [russian, english]) { text, language, _ in
            if language == .english { return text == "two" ? 0.50 : 0.53 }
            return text == "два" ? 0.54 : 0.50
        }
        XCTAssertEqual(selection?.segments.map(\.text), ["one", "two", "three"])
    }

    func testDisjointAlternativesFallBackToOneWholeCandidate() {
        let english = candidate(.english, [segment("hello", 0, 0.3, 0.9)])
        let russian = candidate(.russian, [segment("хэлло", 0.76, 0.3, 0.7)])
        let selection = MixedLanguageTranscriptBuilder.select(from: [russian, english]) { _, language, _ in
            language == .english ? 0.9 : 0.6
        }
        XCTAssertEqual(selection?.segments.map(\.text), ["hello"])
    }

    func testOneVersusManyNoiseFallsBackWithoutSwallowingOrAppending() {
        let english = candidate(.english, [segment("hello", 0, 0.3, 0.9)])
        let russian = candidate(.russian, [
            segment("хэлло", 0, 0.3), segment("noise1", 0.35, 0.2),
            segment("noise2", 0.60, 0.2), segment("noise3", 0.85, 0.2)
        ])
        let selection = MixedLanguageTranscriptBuilder.select(from: [english, russian]) { _, language, _ in
            language == .english ? 0.9 : 0.4
        }
        XCTAssertEqual(selection?.segments.map(\.text), ["hello"])
    }

    func testEndpointDriftKeepsSafeMixedAPIAndTerminalPunctuation() {
        let russian = candidate(.russian, [
            segment("привет", 0, 0.30), segment("апи", 0.35, 0.30),
            segment("сейчас", 0.70, 0.30)
        ], formatted: "Привет, апи!")
        let english = candidate(.english, [
            segment("hello", 0.02, 0.28), segment("API", 0.36, 0.28),
            segment("now", 0.72, 0.51)
        ], formatted: "Hello, API!")
        let selection = MixedLanguageTranscriptBuilder.select(from: [russian, english]) { text, language, _ in
            if language == .russian, ["привет", "сейчас"].contains(text) { return 0.95 }
            if language == .english, text == "API" { return 0.99 }
            return 0.10
        }
        XCTAssertEqual(selection?.segments.map(\.text), ["привет", "API", "сейчас"])
        XCTAssertEqual(selection?.formattedTranscript, "привет API сейчас!")
    }

    func testWholeCandidateFallbackTieDoesNotDependOnInputOrder() {
        let english = candidate(.english, [segment("hello", 0, 0.3, 0.7)])
        let russian = candidate(.russian, [segment("привет", 0.8, 0.3, 0.7)])
        let first = MixedLanguageTranscriptBuilder.select(from: [russian, english]) { _, _, _ in 0.5 }
        let second = MixedLanguageTranscriptBuilder.select(from: [english, russian]) { _, _, _ in 0.5 }
        XCTAssertEqual(first?.formattedTranscript, second?.formattedTranscript)
    }

    func testMalformedAndEmptySegmentsHaveExplicitFallback() {
        let russian = candidate(.russian, [segment("", 0, 0.2), segment("привет", -.infinity, 0.2)])
        let english = candidate(.english, [segment("hello", 0, .nan)])
        XCTAssertEqual(MixedLanguageTranscriptBuilder.select(from: [russian, english])?.segments.map(\.text), ["hello"])
        XCTAssertNil(MixedLanguageTranscriptBuilder.select(from: []))
    }

    private func candidate(
        _ language: SpeechLanguage,
        _ segments: [TimedSpeechSegment],
        formatted: String = ""
    ) -> SpeechTranscriptCandidate {
        SpeechTranscriptCandidate(language: language, segments: segments, formattedTranscript: formatted)
    }

    private func segment(
        _ text: String,
        _ timestamp: TimeInterval,
        _ duration: TimeInterval,
        _ confidence: Double = 0.5
    ) -> TimedSpeechSegment {
        TimedSpeechSegment(text: text, timestamp: timestamp, duration: duration, confidence: confidence)
    }
}

final class SpeechCandidateScorerTests: XCTestCase {
    func testKnownProductSignalsRemainSupported() {
        for term in ["Claude", "OpenAI", "GitHub", "API"] {
            let score = SpeechCandidateScorer.score(
                transcript: term,
                language: .english,
                acousticConfidence: 0.90,
                languageProbabilityOverride: 0.10,
                spellingRatioOverride: 0,
                scriptCompatibilityOverride: 1
            )
            XCTAssertGreaterThan(score, 0.60, term)
        }
    }

    func testGenericLatinTransliterationDoesNotBeatCorrectRussian() {
        let russian = SpeechCandidateScorer.score(
            transcript: "привет",
            language: .russian,
            acousticConfidence: 0.65,
            languageProbabilityOverride: 0.98,
            spellingRatioOverride: 1,
            scriptCompatibilityOverride: 1
        )
        let privet = SpeechCandidateScorer.score(
            transcript: "Privet",
            language: .english,
            acousticConfidence: 0.95,
            languageProbabilityOverride: 0.05,
            spellingRatioOverride: 0,
            scriptCompatibilityOverride: 1
        )
        XCTAssertGreaterThan(russian, privet)
    }

    func testDictionaryDoesNotOverrideWrongScript() {
        let score = SpeechCandidateScorer.score(
            transcript: "слово",
            language: .english,
            acousticConfidence: 0.65,
            languageProbabilityOverride: 0.05,
            spellingRatioOverride: 1,
            scriptCompatibilityOverride: 0
        )
        XCTAssertLessThan(score, 0.45)
    }
}

final class RecognitionPolicyTests: XCTestCase {
    func testListeningNeverDeliversTerminalResults() {
        XCTAssertEqual(
            RecognitionCompletionPolicy.decision(
                phase: .listening,
                statuses: [.final, .final],
                hasEligibleText: true
            ),
            .wait
        )
        XCTAssertEqual(
            RecognitionCompletionPolicy.decision(
                phase: .listening,
                statuses: [.failed, .final],
                hasEligibleText: true
            ),
            .wait
        )
    }

    func testListeningFailsOnlyWhenAllFailedWithoutText() {
        XCTAssertEqual(
            RecognitionCompletionPolicy.decision(
                phase: .listening,
                statuses: [.failed, .failed],
                hasEligibleText: false
            ),
            .failNoText
        )
    }

    func testProcessingFinalAndTimedOutPartialPolicies() {
        XCTAssertEqual(
            RecognitionCompletionPolicy.decision(
                phase: .processing,
                statuses: [.failed, .final],
                hasEligibleText: true
            ),
            .deliver
        )
        XCTAssertEqual(
            RecognitionCompletionPolicy.decision(
                phase: .processing,
                statuses: [.partial, .waiting],
                hasEligibleText: true,
                timedOut: true
            ),
            .deliver
        )
    }

    func testResultAndErrorPreservesResultStatus() {
        XCTAssertEqual(
            RecognitionCallbackPolicy.status(
                previous: .waiting,
                receivedResult: true,
                resultIsFinal: true,
                receivedError: true
            ),
            .final
        )
        XCTAssertEqual(
            RecognitionCallbackPolicy.status(
                previous: .partial,
                receivedResult: false,
                resultIsFinal: false,
                receivedError: true
            ),
            .failedWithPartial
        )
    }

    func testNonFinalResultAndErrorIsRecoverableTerminal() {
        XCTAssertEqual(
            RecognitionCallbackPolicy.status(
                previous: .partial,
                receivedResult: true,
                resultIsFinal: false,
                receivedError: true
            ),
            .failedWithPartial
        )
    }

    func testOutOfOrderPartialCannotDowngradeOrOverwriteFinal() {
        XCTAssertEqual(
            RecognitionCallbackPolicy.status(
                previous: .final,
                receivedResult: true,
                resultIsFinal: false,
                receivedError: false
            ),
            .final
        )
        XCTAssertFalse(
            RecognitionCallbackPolicy.shouldReplaceData(
                previous: .final,
                receivedResult: true
            )
        )
    }

    func testFailedCandidateCannotCompeteAgainstHealthyFinal() {
        let failed = snapshot(.english, "wrong", .failed, 0.99)
        let healthy = snapshot(.russian, "правильно", .final, 0.5)
        let selected = RecognitionFinalizationSelector.select(
            from: [failed, healthy],
            requestedLanguage: .automatic,
            timedOut: false,
            scoreProvider: { _, language, _ in language == .english ? 1 : 0 }
        )
        XCTAssertEqual(selected?.formattedTranscript, "правильно")
    }

    func testAllUsablePartialsAreEligibleAfterTimeout() {
        let english = snapshot(.english, "API", .partial, 0.8)
        let russian = snapshot(.russian, "привет", .partial, 0.7)
        XCTAssertTrue(
            RecognitionFinalizationSelector.eligibleSnapshots(
                from: [english, russian],
                timedOut: false
            ).isEmpty
        )
        XCTAssertEqual(
            RecognitionFinalizationSelector.eligibleSnapshots(
                from: [english, russian],
                timedOut: true
            ).count,
            2
        )
    }

    func testFinalAndPartialAreBothEligibleAtTimeout() {
        let final = snapshot(.russian, "привет", .final, 0.8)
        let partial = snapshot(.english, "API", .partial, 0.7)
        XCTAssertEqual(
            RecognitionFinalizationSelector.eligibleSnapshots(
                from: [final, partial],
                timedOut: true
            ).count,
            2
        )
    }

    func testFailedWithPartialIsTerminalAndRecoverableButFailedIsNot() {
        let recoverable = snapshot(.english, "API", .failedWithPartial, 0.8)
        let failed = snapshot(.russian, "stale", .failed, 0.99)
        XCTAssertTrue(RecognitionCandidateStatus.failedWithPartial.isTerminal)
        XCTAssertEqual(
            RecognitionFinalizationSelector.eligibleSnapshots(
                from: [recoverable, failed],
                timedOut: false
            ).map(\.transcript),
            ["API"]
        )
    }

    func testSegmentlessCandidateForcesWholeCandidateScoring() {
        let english = RecognitionCandidateSnapshot(
            language: .english,
            transcript: "hello",
            segments: [],
            confidence: 0.8,
            status: .final
        )
        let russian = snapshot(.russian, "хэлло", .final, 0.8)
        let selected = RecognitionFinalizationSelector.select(
            from: [russian, english],
            requestedLanguage: .automatic,
            timedOut: false,
            scoreProvider: { _, language, _ in language == .english ? 1 : 0 }
        )
        XCTAssertEqual(selected?.formattedTranscript, "hello")
    }

    private func snapshot(
        _ language: SpeechLanguage,
        _ text: String,
        _ status: RecognitionCandidateStatus,
        _ confidence: Double
    ) -> RecognitionCandidateSnapshot {
        RecognitionCandidateSnapshot(
            language: language,
            transcript: text,
            segments: [TimedSpeechSegment(text: text, timestamp: 0, duration: 0.3)],
            confidence: confidence,
            status: status
        )
    }
}

final class AutomaticPunctuationTests: XCTestCase {
    func testPreservesRichFormattedMonolingualTranscript() {
        XCTAssertEqual(
            AutomaticPunctuation.restore(
                formattedTranscript: "Hello, world!",
                segments: [
                    TimedSpeechSegment(text: "Hello", timestamp: 0, duration: 0.3),
                    TimedSpeechSegment(text: "world", timestamp: 0.35, duration: 0.3)
                ],
                language: .english,
                preserveFormattedTranscript: true
            ),
            "Hello, world!"
        )
    }

    func testSeparateCloserSegmentDoesNotGainSpace() {
        XCTAssertEqual(
            AutomaticPunctuation.restore(
                formattedTranscript: "hello )",
                segments: [
                    TimedSpeechSegment(text: "hello!", timestamp: 0, duration: 0.3),
                    TimedSpeechSegment(text: ")", timestamp: 0.3, duration: 0.05)
                ],
                language: .english
            ),
            "Hello!)"
        )
    }

    func testUnicodeEllipsisIsTerminal() {
        XCTAssertEqual(
            AutomaticPunctuation.restore(
                formattedTranscript: "подожди…",
                segments: [],
                language: .russian
            ),
            "подожди…"
        )
    }

    func testTerminalMarksBeforeTrailingClosersArePreserved() {
        XCTAssertEqual(
            AutomaticPunctuation.restore(
                formattedTranscript: "Он спросил: «почему?»",
                segments: [],
                language: .russian
            ),
            "Он спросил: «почему?»"
        )
    }
}
