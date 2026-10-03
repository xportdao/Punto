import Carbon
import Foundation

final class InputSourceController {
    func currentLayout() -> KeyboardLayout? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        return KeyboardLayout.layout(for: source)
    }

    /// Включённая пользователем раскладка языка; именно на неё Punto переключает.
    func layout(for language: KeyboardLanguage) -> KeyboardLayout? {
        inputSource(for: language).flatMap(KeyboardLayout.layout(for:))
    }

    func select(_ language: KeyboardLanguage) {
        guard let source = inputSource(for: language) else { return }
        TISSelectInputSource(source)
    }

    private func inputSource(for language: KeyboardLanguage) -> TISInputSource? {
        guard let sources = TISCreateInputSourceList(
            [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource!,
             kTISPropertyInputSourceIsSelectCapable: true] as CFDictionary,
            false
        )?.takeRetainedValue() as? [TISInputSource] else { return nil }

        let wantedCode = language == .russian ? "ru" : "en"
        return sources.first(where: { languageCodes(for: $0).first == wantedCode })
            ?? sources.first(where: { languageCodes(for: $0).contains(wantedCode) })
    }

    private func languageCodes(for source: TISInputSource) -> [String] {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else {
            return []
        }
        let languages = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue()
        return (languages as? [String]) ?? []
    }
}
