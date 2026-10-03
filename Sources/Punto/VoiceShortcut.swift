import AppKit
import CoreGraphics
import Foundation

/// Сочетание клавиш, которое запускает и останавливает голосовой ввод.
/// Хранится в UserDefaults по идентификатору пресета.
struct VoiceShortcut: Equatable {
    let id: String
    let title: String
    /// nil — сочетание только из модификаторов (например, Control–Fn).
    let keyCode: Int64?
    let modifiers: CGEventFlags
    let keyEquivalent: String
    let keyEquivalentModifierMask: NSEvent.ModifierFlags

    static let standardModifiers: CGEventFlags = [
        .maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn
    ]
    private static let defaultsKey = "voiceShortcut"

    static let presets: [VoiceShortcut] = [
        // Двухклавишные сочетания, свободные в стандартной настройке macOS.
        VoiceShortcut(
            id: "option-space",
            title: "Option–Space",
            keyCode: 49,
            modifiers: [.maskAlternate],
            keyEquivalent: " ",
            keyEquivalentModifierMask: [.option]
        ),
        VoiceShortcut(
            id: "control-fn",
            title: "Control–Fn (🌐), только клавиатура Apple",
            keyCode: nil,
            modifiers: [.maskControl, .maskSecondaryFn],
            keyEquivalent: "",
            keyEquivalentModifierMask: []
        ),
        VoiceShortcut(
            id: "fn-space",
            title: "Fn (🌐)–Space, только клавиатура Apple",
            keyCode: 49,
            modifiers: [.maskSecondaryFn],
            keyEquivalent: " ",
            keyEquivalentModifierMask: [.function]
        ),
        VoiceShortcut(
            id: "control-space",
            title: "Control–Space",
            keyCode: 49,
            modifiers: [.maskControl],
            keyEquivalent: " ",
            keyEquivalentModifierMask: [.control]
        ),
        VoiceShortcut(
            id: "control-option-space",
            title: "Control–Option–Space",
            keyCode: 49,
            modifiers: [.maskControl, .maskAlternate],
            keyEquivalent: " ",
            keyEquivalentModifierMask: [.control, .option]
        ),
        VoiceShortcut(
            id: "control-shift-space",
            title: "Control–Shift–Space",
            keyCode: 49,
            modifiers: [.maskControl, .maskShift],
            keyEquivalent: " ",
            keyEquivalentModifierMask: [.control, .shift]
        ),
        VoiceShortcut(
            id: "command-shift-space",
            title: "Command–Shift–Space",
            keyCode: 49,
            modifiers: [.maskCommand, .maskShift],
            keyEquivalent: " ",
            keyEquivalentModifierMask: [.command, .shift]
        ),
        VoiceShortcut(
            id: "control-option-d",
            title: "Control–Option–D",
            keyCode: 2,
            modifiers: [.maskControl, .maskAlternate],
            keyEquivalent: "d",
            keyEquivalentModifierMask: [.control, .option]
        ),
        VoiceShortcut(
            id: "control-option-v",
            title: "Control–Option–V",
            keyCode: 9,
            modifiers: [.maskControl, .maskAlternate],
            keyEquivalent: "v",
            keyEquivalentModifierMask: [.control, .option]
        )
    ]

    static let `default` = presets[0]

    /// Включённое системное сочетание macOS с теми же клавишами, если есть.
    /// Перехват Punto срабатывает раньше системы и отнял бы эту функцию.
    var isModifierOnly: Bool { keyCode == nil }

    func systemConflict(in hotkeys: [SystemHotkey]) -> SystemHotkey? {
        guard let keyCode else { return nil }
        return hotkeys.first { hotkey in
            hotkey.isEnabled
                && hotkey.keyCode == keyCode
                && hotkey.modifiers.intersection(Self.standardModifiers) == modifiers
        }
    }

    static func preset(id: String) -> VoiceShortcut? {
        presets.first { $0.id == id }
    }

    static func load(from defaults: UserDefaults = .standard) -> VoiceShortcut {
        guard let id = defaults.string(forKey: defaultsKey),
              let shortcut = preset(id: id) else { return .default }
        return shortcut
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(id, forKey: Self.defaultsKey)
    }

    /// Точное совпадение: требуемые модификаторы нажаты, остальные стандартные
    /// (Command, Control, Option, Shift) — нет. Caps Lock и Fn не учитываются.
    func matches(keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard let ownKeyCode = self.keyCode else { return false }
        return ownKeyCode == keyCode && flags.intersection(Self.standardModifiers) == modifiers
    }
}

struct SystemHotkey: Equatable {
    let id: Int
    let keyCode: Int64
    let modifiers: CGEventFlags
    let isEnabled: Bool

    var title: String {
        switch id {
        case 60: return "предыдущий источник ввода"
        case 61: return "следующий источник ввода"
        case 64: return "Spotlight"
        case 65: return "поиск Finder"
        default: return "системное сочетание"
        }
    }

    /// Сочетания из Системных настроек → Клавиатура → Сочетания клавиш.
    /// Маска модификаторов там совпадает с битами CGEventFlags.
    static func current() -> [SystemHotkey] {
        guard let value = CFPreferencesCopyAppValue(
            "AppleSymbolicHotKeys" as CFString,
            "com.apple.symbolichotkeys" as CFString
        ) as? [String: Any] else { return [] }
        return value.compactMap { key, entry -> SystemHotkey? in
            guard let id = Int(key),
                  let entry = entry as? [String: Any],
                  let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [NSNumber],
                  parameters.count == 3,
                  parameters[1].int64Value != 65_535 else { return nil }
            return SystemHotkey(
                id: id,
                keyCode: parameters[1].int64Value,
                modifiers: CGEventFlags(rawValue: parameters[2].uint64Value),
                isEnabled: (entry["enabled"] as? NSNumber)?.boolValue ?? false
            )
        }
    }
}

/// Распознаёт сочетание из одних модификаторов. Срабатывает при отпускании,
/// если были нажаты ровно нужные модификаторы, между ними не нажималась
/// обычная клавиша и всё уложилось в `maximumDuration`. Срабатывание на
/// отпускании сохраняет системные Fn–Control–F2, Control–Fn–стрелки и т. п.
struct ModifierChordDetector {
    static let maximumDuration: TimeInterval = 1.0

    private var peak: CGEventFlags = []
    private var startedAt: TimeInterval?
    private var interrupted = false

    mutating func flagsChanged(_ flags: CGEventFlags, target: CGEventFlags, at time: TimeInterval) -> Bool {
        let current = flags.intersection(VoiceShortcut.standardModifiers)
        guard current.isEmpty else {
            if startedAt == nil { startedAt = time }
            peak.formUnion(current)
            return false
        }
        defer { reset() }
        guard let startedAt, !interrupted, !target.isEmpty, peak == target else { return false }
        return time - startedAt <= Self.maximumDuration
    }

    mutating func keyDown() {
        if startedAt != nil { interrupted = true }
    }

    mutating func reset() {
        peak = []
        startedAt = nil
        interrupted = false
    }
}

/// Диагностика: отправляет синтетические нажатия сочетания, чтобы проверить
/// работающий Punto без физической клавиатуры. Требует Универсального доступа,
/// поэтому запускается как Punto.app: `open -n -a Punto --args --post-test-shortcut <id>`.
enum VoiceShortcutSimulator {
    private static let modifierKeys: [(CGEventFlags, CGKeyCode)] = [
        (.maskControl, 59), (.maskAlternate, 58), (.maskShift, 56), (.maskCommand, 55), (.maskSecondaryFn, 63)
    ]

    static func post(_ shortcut: VoiceShortcut) {
        var held: CGEventFlags = []
        let pressed = modifierKeys.filter { shortcut.modifiers.contains($0.0) }
        for (flag, keyCode) in pressed {
            held.insert(flag)
            postFlagsChanged(keyCode: keyCode, flags: held)
        }
        if let keyCode = shortcut.keyCode {
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: keyDown) else { continue }
                event.flags = held
                event.post(tap: .cghidEventTap)
                usleep(30_000)
            }
        }
        for (flag, keyCode) in pressed.reversed() {
            held.remove(flag)
            postFlagsChanged(keyCode: keyCode, flags: held)
        }
    }

    private static func postFlagsChanged(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else { return }
        event.type = .flagsChanged
        event.flags = flags
        event.post(tap: .cghidEventTap)
        usleep(30_000)
    }
}
