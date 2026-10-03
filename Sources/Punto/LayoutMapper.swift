import Foundation

enum KeyboardLanguage {
    case english
    case russian
}

enum LayoutMapper {
    // Apple Russian-PC and U.S. layouts share these physical key positions.
    private static let english = "`qwertyuiop[]asdfghjkl;'zxcvbnm,./"
    private static let russian = "ёйцукенгшщзхъфывапролджэячсмитьбю."
    private static let shiftedEnglish = "~QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>?"
    private static let shiftedRussian = "ЁЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ,"

    private static let englishToRussian = makeMap(
        pairs: [(english, russian), (shiftedEnglish, shiftedRussian)]
    )
    private static let russianToEnglish = makeMap(
        pairs: [(russian, english), (shiftedRussian, shiftedEnglish)]
    )

    static func convert(_ text: String, to language: KeyboardLanguage) -> String? {
        let map = language == .russian ? englishToRussian : russianToEnglish
        var result = ""
        result.reserveCapacity(text.count)

        for character in text {
            if let replacement = map[character] {
                result.append(replacement)
                continue
            }

            let lowered = Character(String(character).lowercased())
            guard let replacement = map[lowered] else { return nil }
            let replacementText = String(replacement)
            result += character.isUppercase ? replacementText.uppercased() : replacementText
        }
        return result
    }

    static func detectedLanguage(of text: String) -> KeyboardLanguage? {
        var sawEnglish = false
        var sawRussian = false

        for scalar in text.unicodeScalars {
            if CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ").contains(scalar) {
                sawEnglish = true
            } else if CharacterSet(charactersIn: "абвгдеёжзийклмнопрстуфхцчшщъыьэюяАБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ").contains(scalar) {
                sawRussian = true
            }
        }

        guard sawEnglish != sawRussian else { return nil }
        return sawEnglish ? .english : .russian
    }

    private static func makeMap(pairs: [(String, String)]) -> [Character: Character] {
        var result: [Character: Character] = [:]
        for (source, destination) in pairs {
            for (key, value) in zip(source, destination) {
                result[key] = value
            }
        }
        return result
    }
}

private extension Character {
    var isUppercase: Bool {
        let value = String(self)
        return value != value.lowercased() && value == value.uppercased()
    }
}
