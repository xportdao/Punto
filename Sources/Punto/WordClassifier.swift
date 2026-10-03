import AppKit
import Foundation

struct Correction: Equatable {
    let replacement: String
    let targetLanguage: KeyboardLanguage
}

/// Исправление слова на экране: удалить `deleteCount` видимых символов и
/// вставить `replacement`, затем включить раскладку `targetLanguage`.
struct LayoutCorrection: Equatable {
    let replacement: String
    let deleteCount: Int
    let targetLanguage: KeyboardLanguage
}

final class WordClassifier {
    private let spellChecker: NSSpellChecker
    private let documentTag: Int
    private let knownWordOverride: ((String, KeyboardLanguage) -> Bool)?
    private let trailingPunctuation = CharacterSet(charactersIn: ".,!?;:)]}\"»”’…")
    /// Знаки, на которых слово исправляется сразу, не дожидаясь пробела.
    private static let boundaryPunctuation: Set<Character> = [".", ",", "!", "?", ";", ":", ")", "…"]
    private static let unsafeCharacters = CharacterSet.decimalDigits.union(CharacterSet(charactersIn: "@#\\=:"))

    init(
        spellChecker: NSSpellChecker = .shared,
        knownWordOverride: ((String, KeyboardLanguage) -> Bool)? = nil
    ) {
        self.spellChecker = spellChecker
        self.documentTag = NSSpellChecker.uniqueSpellDocumentTag()
        self.knownWordOverride = knownWordOverride
    }

    deinit {
        spellChecker.closeSpellDocument(withTag: documentTag)
    }

    // MARK: - Нажатия

    /// Исправление после пробела, Enter или Tab. Знаки в конце слова
    /// сохраняются: сначала как знак целевой раскладки на той же клавише,
    /// иначе как набранный символ (`ghbdtn.` → `привет.`).
    func delimiterCorrection(
        strokes: [KeyStroke],
        source: KeyboardLayout,
        target: KeyboardLayout
    ) -> LayoutCorrection? {
        guard !strokes.isEmpty,
              let targetLanguage = target.language,
              let sourceLanguage = source.language,
              sourceLanguage != targetLanguage else { return nil }
        let visible = source.render(strokes)
        // Пробел после мёртвой клавиши лишь завершает символ в приложении.
        guard !visible.hasPendingDeadKey else { return nil }
        let deleteCount = visible.text.count

        if let candidate = convertedWord(strokes, source: source, target: target) {
            return LayoutCorrection(replacement: candidate, deleteCount: deleteCount, targetLanguage: targetLanguage)
        }

        // `1...0` для слова из одной буквы аварийно завершает программу,
        // поэтому длина хвоста перебирается через stride.
        for suffixLength in stride(from: 1, through: min(3, strokes.count - 1), by: 1) {
            let core = Array(strokes.dropLast(suffixLength))
            let suffix = Array(strokes.suffix(suffixLength))
            guard let candidate = convertedWord(core, source: source, target: target) else { continue }
            let targetSuffix = target.renderFlushed(suffix)
            if isPunctuation(targetSuffix) {
                return LayoutCorrection(
                    replacement: candidate + targetSuffix,
                    deleteCount: deleteCount,
                    targetLanguage: targetLanguage
                )
            }
            let typedSuffix = String(visible.text.dropFirst(source.render(core).text.count))
            if isPunctuation(typedSuffix) {
                return LayoutCorrection(
                    replacement: candidate + typedSuffix,
                    deleteCount: deleteCount,
                    targetLanguage: targetLanguage
                )
            }
        }
        return nil
    }

    /// Исправление в момент нажатия знака препинания. Срабатывает только когда
    /// клавиша однозначно не буква: в исходной раскладке это символ или мёртвая
    /// клавиша, а в целевой — знак препинания (`ghbdtn` + Shift+6 → `привет,`).
    func boundaryCorrection(
        word: [KeyStroke],
        boundary: KeyStroke,
        source: KeyboardLayout,
        target: KeyboardLayout
    ) -> LayoutCorrection? {
        guard !word.isEmpty,
              let targetLanguage = target.language,
              let sourceLanguage = source.language,
              sourceLanguage != targetLanguage,
              isBoundaryCandidate(boundary, in: source),
              !target.isDeadKey(boundary) else { return nil }
        let targetCharacter = target.character(for: boundary)
        guard targetCharacter.count == 1,
              let mark = targetCharacter.first,
              Self.boundaryPunctuation.contains(mark) else { return nil }
        let visible = source.render(word)
        guard !visible.hasPendingDeadKey,
              let candidate = convertedWord(word, source: source, target: target) else { return nil }
        return LayoutCorrection(
            replacement: candidate + targetCharacter,
            deleteCount: visible.text.count,
            targetLanguage: targetLanguage
        )
    }

    /// Клавиша не печатает букву в исходной раскладке.
    func isBoundaryCandidate(_ stroke: KeyStroke, in source: KeyboardLayout) -> Bool {
        if source.isDeadKey(stroke) { return true }
        let character = source.character(for: stroke)
        return !character.isEmpty && !character.contains(where: \.isLetter)
    }

    private func convertedWord(
        _ strokes: [KeyStroke],
        source: KeyboardLayout,
        target: KeyboardLayout
    ) -> String? {
        guard let sourceLanguage = source.language,
              let targetLanguage = target.language,
              strokes.allSatisfy({ isSafe($0, source: source, target: target) }) else { return nil }
        let original = source.render(strokes)
        guard !original.hasPendingDeadKey,
              original.text.count >= 3,
              original.text.count <= 40,
              !original.text.dropLast().contains("/") else { return nil }
        let candidate = target.renderFlushed(strokes)
        guard isLexicalWord(candidate, language: targetLanguage),
              shouldReplace(
                  original: original.text,
                  candidate: candidate,
                  source: sourceLanguage,
                  target: targetLanguage
              ) else { return nil }
        return candidate
    }

    /// Цифры, `@`, `#`, `=`, `\` и `:` обычно означают адрес, путь или код.
    /// Исключение — клавиша, которая в целевой раскладке печатает букву:
    /// `\` это `ё`, а `:` это `Ж` в русской раскладке Apple.
    private func isSafe(_ stroke: KeyStroke, source: KeyboardLayout, target: KeyboardLayout) -> Bool {
        let typed = source.isDeadKey(stroke) ? source.renderFlushed([stroke]) : source.character(for: stroke)
        guard typed.unicodeScalars.contains(where: Self.unsafeCharacters.contains) else { return true }
        let converted = target.character(for: stroke)
        return !converted.isEmpty && converted.allSatisfy(\.isLetter)
    }

    private func isPunctuation(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy(trailingPunctuation.contains)
    }

    // MARK: - Текст

    /// Проверка готового текста по паре раскладок; по умолчанию U.S. и
    /// Russian-PC. Используется в диагностике и тестах.
    func correction(
        for token: String,
        english: KeyboardLayout? = KeyboardLayout.installed(identifier: "com.apple.keylayout.US"),
        russian: KeyboardLayout? = KeyboardLayout.installed(identifier: "com.apple.keylayout.RussianWin")
    ) -> Correction? {
        guard let english, let russian,
              let sourceLanguage = LayoutMapper.detectedLanguage(of: token) else { return nil }
        let source = sourceLanguage == .english ? english : russian
        let target = sourceLanguage == .english ? russian : english
        guard let strokes = source.strokes(for: token) else { return nil }
        if let last = strokes.last, strokes.count > 1,
           let boundary = boundaryCorrection(
               word: Array(strokes.dropLast()),
               boundary: last,
               source: source,
               target: target
           ) {
            return Correction(replacement: boundary.replacement, targetLanguage: boundary.targetLanguage)
        }
        return delimiterCorrection(strokes: strokes, source: source, target: target).map {
            Correction(replacement: $0.replacement, targetLanguage: $0.targetLanguage)
        }
    }

    // MARK: - Словарь

    private func shouldReplace(
        original: String,
        candidate: String,
        source: KeyboardLanguage,
        target: KeyboardLanguage
    ) -> Bool {
        // Conservative rule: replace only an unknown source word with a known target word.
        // Spell checkers tokenize `e;t` as two one-letter words and may call it valid.
        // It is not a lexical English word, while its key-for-key candidate `уже` is.
        let sourceIsKnown = isLexicalWord(original, language: source) && isKnown(original, language: source)
        return !sourceIsKnown && isKnown(candidate, language: target)
    }

    private func isLexicalWord(_ word: String, language: KeyboardLanguage) -> Bool {
        guard word.count >= 2,
              LayoutMapper.detectedLanguage(of: word) == language,
              let first = word.unicodeScalars.first,
              let last = word.unicodeScalars.last,
              CharacterSet.letters.contains(first),
              CharacterSet.letters.contains(last) else { return false }

        let joiners = CharacterSet(charactersIn: "-'’")
        return word.unicodeScalars.allSatisfy {
            CharacterSet.letters.contains($0) || joiners.contains($0)
        }
    }

    private func isKnown(_ word: String, language: KeyboardLanguage) -> Bool {
        if let knownWordOverride {
            return knownWordOverride(word, language)
        }
        let languageCode = language == .russian ? "ru_RU" : "en_US"
        let range = spellChecker.checkSpelling(
            of: word,
            startingAt: 0,
            language: languageCode,
            wrap: false,
            inSpellDocumentWithTag: documentTag,
            wordCount: nil
        )
        return range.location == NSNotFound
    }
}
