import Carbon
import Foundation

/// Физическое нажатие: код клавиши и состояние Shift/Caps Lock. Текст нажатия
/// зависит от раскладки, поэтому слово хранится как последовательность
/// нажатий, а оба варианта текста строятся по реальным раскладкам системы.
struct KeyStroke: Hashable {
    let keyCode: UInt16
    let shift: Bool
    let capsLock: Bool

    init(keyCode: UInt16, shift: Bool = false, capsLock: Bool = false) {
        self.keyCode = keyCode
        self.shift = shift
        self.capsLock = capsLock
    }

    /// Модификаторы в формате UCKeyTranslate: (EventRecord.modifiers >> 8) & 0xFF.
    var modifierKeyState: UInt32 {
        (shift ? UInt32(shiftKey >> 8) & 0xFF : 0) | (capsLock ? UInt32(alphaLock >> 8) & 0xFF : 0)
    }
}

struct LayoutRendering: Equatable {
    let text: String
    /// Последнее нажатие было мёртвой клавишей и ждёт следующей.
    let hasPendingDeadKey: Bool
}

extension KeyboardLanguage {
    var other: KeyboardLanguage { self == .english ? .russian : .english }
}

/// Раскладка клавиатуры macOS (`uchr`). Перевод нажатий в текст выполняет
/// UCKeyTranslate, включая мёртвые клавиши, точно так же, как это делает
/// система ввода приложения.
final class KeyboardLayout {
    let identifier: String
    let language: KeyboardLanguage?
    private let layoutData: Data
    private lazy var reverseMap: [Character: KeyStroke] = buildReverseMap()

    private static var cache: [String: KeyboardLayout] = [:]
    private static let spaceKeyCode: UInt16 = 49

    /// После сложения символа UCKeyTranslate переносит прежнее состояние в
    /// старшие 16 бит; ожидание следующей клавиши означают только младшие.
    private static func isPending(_ deadKeyState: UInt32) -> Bool {
        deadKeyState & 0xFFFF != 0
    }

    private init(identifier: String, language: KeyboardLanguage?, layoutData: Data) {
        self.identifier = identifier
        self.language = language
        self.layoutData = layoutData
    }

    static func layout(for source: TISInputSource) -> KeyboardLayout? {
        guard let identifier = stringProperty(source, kTISPropertyInputSourceID) else { return nil }
        if let cached = cache[identifier] { return cached }
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let layout = KeyboardLayout(
            identifier: identifier,
            language: primaryLanguage(of: source),
            layoutData: data
        )
        cache[identifier] = layout
        return layout
    }

    /// Любая установленная раскладка по идентификатору, включая неактивные.
    static func installed(identifier: String) -> KeyboardLayout? {
        let filter = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = sources.first else { return nil }
        return layout(for: source)
    }

    func render(_ strokes: [KeyStroke]) -> LayoutRendering {
        var deadKeyState: UInt32 = 0
        var text = ""
        for stroke in strokes {
            text += translate(stroke, deadKeyState: &deadKeyState, allowDeadKeys: true)
        }
        return LayoutRendering(text: text, hasPendingDeadKey: Self.isPending(deadKeyState))
    }

    /// Текст с закрытой пробелом незавершённой мёртвой клавишей (`^` вместо ожидания).
    func renderFlushed(_ strokes: [KeyStroke]) -> String {
        var deadKeyState: UInt32 = 0
        var text = ""
        for stroke in strokes {
            text += translate(stroke, deadKeyState: &deadKeyState, allowDeadKeys: true)
        }
        if Self.isPending(deadKeyState) {
            text += translate(KeyStroke(keyCode: Self.spaceKeyCode), deadKeyState: &deadKeyState, allowDeadKeys: true)
        }
        return text
    }

    /// Символ клавиши без учёта мёртвых клавиш.
    func character(for stroke: KeyStroke) -> String {
        var deadKeyState: UInt32 = 0
        return translate(stroke, deadKeyState: &deadKeyState, allowDeadKeys: false)
    }

    func isDeadKey(_ stroke: KeyStroke) -> Bool {
        var deadKeyState: UInt32 = 0
        _ = translate(stroke, deadKeyState: &deadKeyState, allowDeadKeys: true)
        return Self.isPending(deadKeyState)
    }

    /// Нажатия, которыми текст набирается в этой раскладке; nil, если символ недоступен.
    func strokes(for text: String) -> [KeyStroke]? {
        var result: [KeyStroke] = []
        for character in text {
            guard let stroke = reverseMap[character] else { return nil }
            result.append(stroke)
        }
        return result
    }

    private func translate(_ stroke: KeyStroke, deadKeyState: inout UInt32, allowDeadKeys: Bool) -> String {
        layoutData.withUnsafeBytes { raw -> String in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return "" }
            var characters = [UniChar](repeating: 0, count: 8)
            var length = 0
            let options: OptionBits = allowDeadKeys ? 0 : OptionBits(kUCKeyTranslateNoDeadKeysMask)
            let status = UCKeyTranslate(
                layout,
                stroke.keyCode,
                UInt16(kUCKeyActionDown),
                stroke.modifierKeyState,
                UInt32(LMGetKbdType()),
                options,
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
            guard status == noErr else { return "" }
            return String(utf16CodeUnits: characters, count: length)
        }
    }

    private func buildReverseMap() -> [Character: KeyStroke] {
        var map: [Character: KeyStroke] = [:]
        // Сначала основной блок клавиш, затем цифровая клавиатура и прочие.
        let ranges: [ClosedRange<UInt16>] = [0...50, 51...127]
        for range in ranges {
            for shift in [false, true] {
                for keyCode in range {
                    let stroke = KeyStroke(keyCode: keyCode, shift: shift)
                    let outputs = isDeadKey(stroke) ? [renderFlushed([stroke])] : [character(for: stroke)]
                    for output in outputs where output.count == 1 {
                        guard let character = output.first,
                              !output.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                              map[character] == nil else { continue }
                        map[character] = stroke
                    }
                }
            }
        }
        return map
    }

    private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func primaryLanguage(of source: TISInputSource) -> KeyboardLanguage? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
              let languages = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String],
              let first = languages.first else { return nil }
        switch first {
        case "en": return .english
        case "ru": return .russian
        default: return nil
        }
    }
}

/// Текущее слово как последовательность нажатий в одной раскладке.
struct KeystrokeToken {
    static let maximumLength = 48

    private(set) var strokes: [KeyStroke] = []
    private(set) var layout: KeyboardLayout?

    mutating func reset() {
        strokes = []
        layout = nil
    }

    /// Нажатия слова, если оно набрано в указанной раскладке.
    func strokes(in layout: KeyboardLayout) -> [KeyStroke] {
        self.layout?.identifier == layout.identifier ? strokes : []
    }

    mutating func append(_ stroke: KeyStroke, layout: KeyboardLayout) {
        if self.layout?.identifier != layout.identifier {
            reset()
            self.layout = layout
        }
        strokes.append(stroke)
        if strokes.count > Self.maximumLength { reset() }
    }

    /// Delete удаляет один видимый символ; ожидающая мёртвая клавиша
    /// отменяется целиком. Если состояние экрана нельзя восстановить по
    /// нажатиям, слово сбрасывается, чтобы не удалить лишнее.
    mutating func deleteBackward() {
        guard let layout, !strokes.isEmpty else { return }
        let current = layout.render(strokes)
        if current.hasPendingDeadKey {
            strokes.removeLast()
            return
        }
        let expectedCount = current.text.count - 1
        while !strokes.isEmpty {
            strokes.removeLast()
            let rendering = layout.render(strokes)
            if rendering.hasPendingDeadKey { continue }
            if rendering.text.count == expectedCount { return }
            if rendering.text.count < expectedCount { break }
        }
        reset()
    }
}
