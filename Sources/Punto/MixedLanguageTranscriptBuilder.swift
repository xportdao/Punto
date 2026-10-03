import Foundation

struct SpeechTranscriptCandidate {
    let language: SpeechLanguage
    let segments: [TimedSpeechSegment]
    let formattedTranscript: String

    init(
        language: SpeechLanguage,
        segments: [TimedSpeechSegment],
        formattedTranscript: String = ""
    ) {
        self.language = language
        self.segments = segments
        self.formattedTranscript = formattedTranscript
    }
}

struct MixedLanguageSelection {
    let formattedTranscript: String
    let segments: [TimedSpeechSegment]
    let languages: Set<SpeechLanguage>
}

/// Смешивание результатов двух распознавателей.
///
/// Базовый язык выбирается по всему тексту (обычно это язык, на котором
/// говорили). Слова второго языка попадают в результат только локально:
/// они заменяют перекрывающиеся по времени слова базового языка или
/// заполняют паузу, когда есть сильные признаки термина (известный термин,
/// аббревиатура, CamelCase, слово базового языка вне словаря) и достаточная
/// акустическая уверенность. Решения независимы, поэтому пропуски и склейки
/// слов в одном из распознавателей не ломают весь результат.
enum MixedLanguageTranscriptBuilder {
    typealias ScoreProvider = (_ text: String, _ language: SpeechLanguage, _ confidence: Double) -> Double

    private static let minimumSegmentOverlapRatio = 0.15
    private static let maximumSpanExcess: TimeInterval = 0.45
    private static let substitutionMargin = 0.10
    private static let providedFillMinimumScore = 0.85
    private static let minimumPlainSubstitutionConfidence = 0.5
    private static let minimumTermFillConfidence = 0.08
    private static let minimumPlainFillConfidence = 0.6
    private static let comparisonEpsilon = 0.000_000_1
    private static let terminalMarks = CharacterSet(charactersIn: ".!?…")
    private static let trailingClosers = CharacterSet(charactersIn: "\"'»”’)]}")

    static func select(
        from candidates: [SpeechTranscriptCandidate],
        scoreProvider: ScoreProvider? = nil
    ) -> MixedLanguageSelection? {
        let normalized = canonicalCandidates(from: candidates)
        guard !normalized.isEmpty else { return nil }
        guard normalized.count > 1 else { return wholeCandidateSelection(normalized[0]) }
        guard normalized.allSatisfy({ !$0.segments.isEmpty }),
              let base = bestWholeCandidate(from: normalized, scoreProvider: scoreProvider),
              let other = normalized.first(where: { $0.language != base.language }) else {
            return selectWholeCandidate(from: normalized, scoreProvider: scoreProvider)
        }

        let merged = merge(base: base, other: other, scoreProvider: scoreProvider)
        let selectedLanguages = Set(merged.map(\.language))
        if selectedLanguages.count == 1,
           let language = selectedLanguages.first,
           let candidate = normalized.first(where: { $0.language == language }) {
            return wholeCandidateSelection(candidate)
        }

        let selectedSegments = merged.map(\.segment)
        var formattedTranscript = selectedSegments.map(\.text).joined(separator: " ")
        if let mark = preferredTerminalMark(
            lastLanguage: merged.last?.language,
            candidates: normalized,
            scoreProvider: scoreProvider
        ), terminalMark(in: formattedTranscript) == nil {
            formattedTranscript += String(mark)
        }
        return MixedLanguageSelection(
            formattedTranscript: formattedTranscript,
            segments: selectedSegments,
            languages: selectedLanguages
        )
    }

    // MARK: - Merge

    private struct PlacedSegment {
        let language: SpeechLanguage
        let segment: TimedSpeechSegment
    }

    private enum Placement {
        case substitute(ClosedRange<Int>)
        case fill
        case skip
    }

    private static func merge(
        base: SpeechTranscriptCandidate,
        other: SpeechTranscriptCandidate,
        scoreProvider: ScoreProvider?
    ) -> [PlacedSegment] {
        var removed = Set<Int>()
        var inserted: [PlacedSegment] = []
        var skipped: [(index: Int, range: ClosedRange<Int>)] = []

        // Каждое слово второго языка решается независимо: так пропуски и
        // склейки слов в одной из моделей не тянут за собой соседей.
        for (index, segment) in other.segments.enumerated() {
            let range = baseRange(overlapping: segment, in: base.segments)
            switch placement(
                for: [segment], range: range, base: base, other: other,
                removed: removed, scoreProvider: scoreProvider
            ) {
            case .substitute(let range):
                range.forEach { removed.insert($0) }
                inserted.append(PlacedSegment(language: other.language, segment: segment))
            case .fill:
                inserted.append(PlacedSegment(language: other.language, segment: segment))
            case .skip:
                if let range { skipped.append((index, range)) }
            }
        }

        // Термин, разбитый второй моделью на две части над одним словом
        // базового языка, оценивается как пара.
        var pairIndex = 0
        while pairIndex + 1 < skipped.count {
            let first = skipped[pairIndex]
            let second = skipped[pairIndex + 1]
            if second.index == first.index + 1,
               first.range == second.range,
               first.range.count == 1,
               !first.range.contains(where: removed.contains) {
                let pair = [other.segments[first.index], other.segments[second.index]]
                let baseRun = Array(base.segments[first.range])
                if isCompact(pair, against: baseRun),
                   shouldSubstitute(
                       other: pair, otherLanguage: other.language,
                       base: baseRun, baseLanguage: base.language,
                       scoreProvider: scoreProvider
                   ) {
                    first.range.forEach { removed.insert($0) }
                    inserted += pair.map { PlacedSegment(language: other.language, segment: $0) }
                    pairIndex += 2
                    continue
                }
            }
            pairIndex += 1
        }

        let kept = base.segments.indices
            .filter { !removed.contains($0) }
            .map { PlacedSegment(language: base.language, segment: base.segments[$0]) }
        return (kept + inserted).enumerated().sorted { left, right in
            if left.element.segment.timestamp != right.element.segment.timestamp {
                return left.element.segment.timestamp < right.element.segment.timestamp
            }
            return left.offset < right.offset
        }.map(\.element)
    }

    private static func baseRange(
        overlapping segment: TimedSpeechSegment,
        in base: [TimedSpeechSegment]
    ) -> ClosedRange<Int>? {
        let span = timeSpan([segment])
        let overlapping = base.indices.filter { index in
            meaningfullyOverlaps(base[index], span: span)
                || meaningfullyOverlaps(segment, span: timeSpan([base[index]]))
        }
        guard let lower = overlapping.min(), let upper = overlapping.max() else { return nil }
        return lower...upper
    }

    private static func placement(
        for segments: [TimedSpeechSegment],
        range: ClosedRange<Int>?,
        base: SpeechTranscriptCandidate,
        other: SpeechTranscriptCandidate,
        removed: Set<Int>,
        scoreProvider: ScoreProvider?
    ) -> Placement {
        if let range {
            guard !range.contains(where: removed.contains) else { return .skip }
            let baseRun = Array(base.segments[range])
            if isCompact(segments, against: baseRun) {
                let substitute = shouldSubstitute(
                    other: segments, otherLanguage: other.language,
                    base: baseRun, baseLanguage: base.language,
                    scoreProvider: scoreProvider
                )
                return substitute ? .substitute(range) : .skip
            }
            // Фрагмент задевает соседнее слово лишь краем, а по сути лежит в
            // паузе базовой модели: рассматриваем его как заполнение паузы.
            guard liesInBaseGap(segments, base: base.segments) else { return .skip }
        }
        let fill = shouldFillGap(other: segments, otherLanguage: other.language, scoreProvider: scoreProvider)
        return fill ? .fill : .skip
    }

    private static func liesInBaseGap(_ other: [TimedSpeechSegment], base: [TimedSpeechSegment]) -> Bool {
        let span = timeSpan(other)
        let midpoint = (span.lowerBound + span.upperBound) / 2
        return !base.contains { $0.timestamp <= midpoint && midpoint <= $0.timestamp + $0.duration }
    }

    /// Замена допустима только когда оба фрагмента описывают один и тот же
    /// участок речи. Иначе короткий термин стёр бы длинную склеенную фразу
    /// базового языка или наоборот.
    private static func isCompact(_ other: [TimedSpeechSegment], against base: [TimedSpeechSegment]) -> Bool {
        let otherSpan = timeSpan(other)
        let baseSpan = timeSpan(base)
        return abs(otherSpan.lowerBound - baseSpan.lowerBound) <= maximumSpanExcess
            && abs(otherSpan.upperBound - baseSpan.upperBound) <= maximumSpanExcess
    }

    private static func shouldSubstitute(
        other: [TimedSpeechSegment],
        otherLanguage: SpeechLanguage,
        base: [TimedSpeechSegment],
        baseLanguage: SpeechLanguage,
        scoreProvider: ScoreProvider?
    ) -> Bool {
        let otherText = joinedText(other)
        let otherScore = localScore(text: otherText, language: otherLanguage, segments: other, scoreProvider: scoreProvider)
        let baseScore = localScore(text: joinedText(base), language: baseLanguage, segments: base, scoreProvider: scoreProvider)
        guard otherScore >= baseScore + substitutionMargin - comparisonEpsilon else { return false }
        guard scoreProvider == nil else { return true }
        return SpeechCandidateScorer.isStrongTerm(otherText)
            || weightedConfidence(other) >= minimumPlainSubstitutionConfidence
    }

    private static func shouldFillGap(
        other: [TimedSpeechSegment],
        otherLanguage: SpeechLanguage,
        scoreProvider: ScoreProvider?
    ) -> Bool {
        let text = joinedText(other)
        let confidence = weightedConfidence(other)
        if let scoreProvider {
            return scoreProvider(text, otherLanguage, confidence) >= providedFillMinimumScore - comparisonEpsilon
        }
        if SpeechCandidateScorer.isStrongTerm(text) {
            return confidence >= minimumTermFillConfidence
        }
        return SpeechCandidateScorer.knownWordRatio(text, language: otherLanguage) >= 1 - comparisonEpsilon
            && confidence >= minimumPlainFillConfidence
    }

    private static func localScore(
        text: String,
        language: SpeechLanguage,
        segments: [TimedSpeechSegment],
        scoreProvider: ScoreProvider?
    ) -> Double {
        let confidence = weightedConfidence(segments)
        if let scoreProvider { return scoreProvider(text, language, confidence) }
        let known = SpeechCandidateScorer.knownWordRatio(text, language: language)
        let strongTerm = SpeechCandidateScorer.isStrongTerm(text) ? 1.0 : 0.0
        return 0.45 * known + 0.35 * confidence + 0.20 * strongTerm
    }

    private static func joinedText(_ segments: [TimedSpeechSegment]) -> String {
        segments.map(\.text).joined(separator: " ")
    }

    // MARK: - Candidates

    private static func canonicalCandidates(
        from candidates: [SpeechTranscriptCandidate]
    ) -> [SpeechTranscriptCandidate] {
        let normalized = candidates.compactMap { candidate -> SpeechTranscriptCandidate? in
            guard candidate.language != .automatic else { return nil }
            let segments = normalizedSegments(candidate.segments)
            let formatted = candidate.formattedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !segments.isEmpty || !formatted.isEmpty else { return nil }
            return SpeechTranscriptCandidate(
                language: candidate.language,
                segments: segments,
                formattedTranscript: formatted.isEmpty
                    ? segments.map(\.text).joined(separator: " ")
                    : formatted
            )
        }
        let grouped = Dictionary(grouping: normalized, by: \.language)
        return grouped.compactMap { _, alternatives in
            alternatives.max { candidatePrecedes($0, $1) }
        }.sorted { languageRank($0.language) < languageRank($1.language) }
    }

    private static func candidatePrecedes(
        _ left: SpeechTranscriptCandidate,
        _ right: SpeechTranscriptCandidate
    ) -> Bool {
        let leftConfidence = weightedConfidence(left.segments)
        let rightConfidence = weightedConfidence(right.segments)
        if abs(leftConfidence - rightConfidence) > comparisonEpsilon {
            return leftConfidence < rightConfidence
        }
        if left.segments.count != right.segments.count {
            return left.segments.count < right.segments.count
        }
        return left.formattedTranscript > right.formattedTranscript
    }

    private static func normalizedSegments(_ segments: [TimedSpeechSegment]) -> [TimedSpeechSegment] {
        segments.enumerated().compactMap { index, segment -> (Int, TimedSpeechSegment)? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, segment.timestamp.isFinite else { return nil }
            let timestamp = max(0, segment.timestamp)
            let duration = segment.duration.isFinite ? max(segment.duration, 0.05) : 0.05
            let confidence = segment.confidence.isFinite ? min(max(segment.confidence, 0), 1) : 0
            return (
                index,
                segment.with(
                    text: text,
                    timestamp: timestamp,
                    duration: duration,
                    confidence: confidence
                )
            )
        }.sorted { left, right in
            if left.1.timestamp != right.1.timestamp { return left.1.timestamp < right.1.timestamp }
            return left.0 < right.0
        }.map(\.1)
    }

    private static func meaningfullyOverlaps(
        _ segment: TimedSpeechSegment,
        span: ClosedRange<TimeInterval>
    ) -> Bool {
        let segmentEnd = segment.timestamp + segment.duration
        let overlap = max(0, min(segmentEnd, span.upperBound) - max(segment.timestamp, span.lowerBound))
        return overlap / max(segment.duration, 0.05) >= minimumSegmentOverlapRatio
    }

    private static func timeSpan(_ segments: [TimedSpeechSegment]) -> ClosedRange<TimeInterval> {
        guard let first = segments.first, let last = segments.last else { return 0...0 }
        return first.timestamp...max(first.timestamp, last.timestamp + last.duration)
    }

    // MARK: - Whole candidates

    /// Базовый язык должен объяснять большую часть речи: балл текста
    /// взвешивается долей аудио, покрытой словами кандидата, иначе один
    /// уверенный термин перевесил бы целую фразу другого языка.
    private static func bestWholeCandidate(
        from candidates: [SpeechTranscriptCandidate],
        scoreProvider: ScoreProvider?
    ) -> SpeechTranscriptCandidate? {
        let spokenDurations = candidates.map { $0.segments.reduce(0.0) { $0 + $1.duration } }
        let longestDuration = spokenDurations.max() ?? 0
        let options = zip(candidates, spokenDurations).map { candidate, spokenDuration -> WholeCandidateOption in
            let confidence = weightedConfidence(candidate.segments)
            let coverage = candidate.segments.isEmpty || longestDuration <= 0
                ? 1.0
                : spokenDuration / longestDuration
            let score = providedScore(
                text: candidate.formattedTranscript,
                language: candidate.language,
                confidence: confidence,
                scoreProvider: scoreProvider
            )
            return WholeCandidateOption(
                candidate: candidate,
                score: score * (0.5 + 0.5 * coverage),
                confidence: confidence
            )
        }
        return options.max(by: wholeCandidatePrecedes)?.candidate
    }

    private static func selectWholeCandidate(
        from candidates: [SpeechTranscriptCandidate],
        scoreProvider: ScoreProvider?
    ) -> MixedLanguageSelection? {
        bestWholeCandidate(from: candidates, scoreProvider: scoreProvider).map(wholeCandidateSelection)
    }

    private static func wholeCandidatePrecedes(
        _ left: WholeCandidateOption,
        _ right: WholeCandidateOption
    ) -> Bool {
        if abs(left.score - right.score) > comparisonEpsilon { return left.score < right.score }
        if abs(left.confidence - right.confidence) > comparisonEpsilon {
            return left.confidence < right.confidence
        }
        if left.candidate.formattedTranscript != right.candidate.formattedTranscript {
            return left.candidate.formattedTranscript > right.candidate.formattedTranscript
        }
        return languageRank(left.candidate.language) > languageRank(right.candidate.language)
    }

    private static func wholeCandidateSelection(
        _ candidate: SpeechTranscriptCandidate
    ) -> MixedLanguageSelection {
        MixedLanguageSelection(
            formattedTranscript: candidate.formattedTranscript,
            segments: candidate.segments,
            languages: [candidate.language]
        )
    }

    // MARK: - Punctuation

    private static func preferredTerminalMark(
        lastLanguage: SpeechLanguage?,
        candidates: [SpeechTranscriptCandidate],
        scoreProvider: ScoreProvider?
    ) -> UnicodeScalar? {
        if let lastLanguage,
           let candidate = candidates.first(where: { $0.language == lastLanguage }),
           let mark = terminalMark(in: candidate.formattedTranscript) {
            return mark
        }
        let ranked = candidates.compactMap { candidate -> TerminalOption? in
            guard let mark = terminalMark(in: candidate.formattedTranscript) else { return nil }
            let confidence = weightedConfidence(candidate.segments)
            return TerminalOption(
                mark: mark,
                language: candidate.language,
                score: providedScore(
                    text: candidate.formattedTranscript,
                    language: candidate.language,
                    confidence: confidence,
                    scoreProvider: scoreProvider
                )
            )
        }
        return ranked.max { left, right in
            if abs(left.score - right.score) > comparisonEpsilon { return left.score < right.score }
            return languageRank(left.language) > languageRank(right.language)
        }?.mark
    }

    private static func terminalMark(in text: String) -> UnicodeScalar? {
        for scalar in text.unicodeScalars.reversed() {
            if CharacterSet.whitespacesAndNewlines.contains(scalar)
                || trailingClosers.contains(scalar) {
                continue
            }
            return terminalMarks.contains(scalar) ? scalar : nil
        }
        return nil
    }

    // MARK: - Helpers

    private static func providedScore(
        text: String,
        language: SpeechLanguage,
        confidence: Double,
        scoreProvider: ScoreProvider?
    ) -> Double {
        scoreProvider?(text, language, confidence)
            ?? SpeechCandidateScorer.score(
                transcript: text,
                language: language,
                acousticConfidence: confidence
            )
    }

    private static func weightedConfidence(_ segments: [TimedSpeechSegment]) -> Double {
        let totalWeight = segments.reduce(0) { $0 + max($1.text.count, 1) }
        guard totalWeight > 0 else { return 0 }
        return segments.reduce(0.0) { partial, segment in
            partial + segment.confidence * Double(max(segment.text.count, 1))
        } / Double(totalWeight)
    }

    private static func languageRank(_ language: SpeechLanguage) -> Int {
        switch language {
        case .english: return 0
        case .russian: return 1
        case .automatic: return 2
        }
    }
}

private struct WholeCandidateOption {
    let candidate: SpeechTranscriptCandidate
    let score: Double
    let confidence: Double
}

private struct TerminalOption {
    let mark: UnicodeScalar
    let language: SpeechLanguage
    let score: Double
}
