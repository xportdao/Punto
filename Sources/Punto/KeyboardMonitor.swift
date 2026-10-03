import AppKit
import ApplicationServices
import Foundation
import os

enum KeyboardMonitorError: Error {
    case eventTapUnavailable
}

final class KeyboardMonitor {
    private static let injectedEventMarker: Int64 = 0x50554E544F
    private let classifier = WordClassifier()
    private let inputSources = InputSourceController()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var token = KeystrokeToken()
    private var modifierChord = ModifierChordDetector()
    private static let log = Logger(subsystem: "local.punto.autolayout", category: "shortcut")
    /// Пробел, Return, Enter на цифровой клавиатуре, Tab.
    private static let delimiterKeyCodes: Set<Int64> = [49, 36, 76, 48]

    var onVoiceShortcut: (() -> Void)?
    var isVoiceListening: (() -> Bool)?
    var onStopVoiceBySpace: (() -> Void)?
    var voiceShortcut: VoiceShortcut = .default {
        didSet { modifierChord.reset() }
    }

    var isRunning: Bool { eventTap != nil }

    func start() throws {
        guard eventTap == nil else { return }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: KeyboardMonitor.eventCallback,
            userInfo: pointer
        ) else {
            throw KeyboardMonitorError.eventTapUnavailable
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        token.reset()
    }

    private static let eventCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        return monitor.handle(type: type, event: event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged {
            // Модификаторы не задерживаем: приложения должны видеть их как обычно.
            let shortcut = voiceShortcut
            if shortcut.isModifierOnly {
                // Только модификаторы, без набранного текста: для проверки сочетания.
                let modifiers = event.flags.intersection(VoiceShortcut.standardModifiers).rawValue
                let changedKey = event.getIntegerValueField(.keyboardEventKeycode)
                Self.log.notice("flagsChanged key=\(changedKey, privacy: .public) modifiers=0x\(String(modifiers, radix: 16), privacy: .public)")
            }
            if shortcut.isModifierOnly,
               modifierChord.flagsChanged(
                   event.flags,
                   target: shortcut.modifiers,
                   at: TimeInterval(event.timestamp) / 1_000_000_000
               ) {
                token.reset()
                Self.log.notice("voice shortcut fired: \(shortcut.id, privacy: .public)")
                DispatchQueue.main.async { [weak self] in self?.onVoiceShortcut?() }
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown,
              event.getIntegerValueField(.eventSourceUserData) != Self.injectedEventMarker else {
            return Unmanaged.passUnretained(event)
        }
        modifierChord.keyDown()

        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isPlainSpace = keyCode == 49
            && flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
        if isPlainSpace, isVoiceListening?() == true {
            token.reset()
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                DispatchQueue.main.async { [weak self] in self?.onStopVoiceBySpace?() }
            }
            return nil
        }

        if voiceShortcut.matches(keyCode: keyCode, flags: flags) {
            token.reset()
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                Self.log.notice("voice shortcut fired: \(self.voiceShortcut.id, privacy: .public)")
            }
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                DispatchQueue.main.async { [weak self] in self?.onVoiceShortcut?() }
            }
            return nil
        }

        if !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty {
            token.reset()
            return Unmanaged.passUnretained(event)
        }

        if keyCode == 51 { // Delete
            token.deleteBackward()
            return Unmanaged.passUnretained(event)
        }
        if keyCode == 53 { // Escape
            token.reset()
            return Unmanaged.passUnretained(event)
        }

        // Текст нажатия определяется текущей раскладкой пользователя, а не
        // фиксированной таблицей: так учитываются раскладка Apple «Русская»,
        // «США международная» с мёртвыми клавишами и любые другие пары.
        guard let layout = inputSources.currentLayout(), let sourceLanguage = layout.language else {
            token.reset()
            return Unmanaged.passUnretained(event)
        }
        let stroke = KeyStroke(
            keyCode: UInt16(clamping: keyCode),
            shift: flags.contains(.maskShift),
            capsLock: flags.contains(.maskAlphaShift)
        )

        if Self.delimiterKeyCodes.contains(keyCode) {
            let completed = token.strokes(in: layout)
            token.reset()
            guard !completed.isEmpty,
                  let target = inputSources.layout(for: sourceLanguage.other),
                  let correction = classifier.delimiterCorrection(
                      strokes: completed,
                      source: layout,
                      target: target
                  ) else {
                return Unmanaged.passUnretained(event)
            }
            replacePreviousText(with: correction, followedBy: event)
            return nil // Our corrected word and the original delimiter are posted below.
        }

        let character = layout.character(for: stroke)
        let printable = !character.isEmpty
            && !character.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && !character.unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains)
        guard printable || layout.isDeadKey(stroke) else {
            token.reset()
            return Unmanaged.passUnretained(event)
        }

        let word = token.strokes(in: layout)
        if !word.isEmpty,
           classifier.isBoundaryCandidate(stroke, in: layout),
           let target = inputSources.layout(for: sourceLanguage.other),
           let correction = classifier.boundaryCorrection(
               word: word,
               boundary: stroke,
               source: layout,
               target: target
           ) {
            token.reset()
            // Знак уже входит в замену; само нажатие (в том числе мёртвую
            // клавишу) приложение не получает.
            replacePreviousText(with: correction, followedBy: nil)
            return nil
        }

        token.append(stroke, layout: layout)
        return Unmanaged.passUnretained(event)
    }

    private func replacePreviousText(with correction: LayoutCorrection, followedBy delimiterEvent: CGEvent?) {
        for _ in 0..<correction.deleteCount {
            postKey(code: 51, down: true)
            postKey(code: 51, down: false)
        }
        inputSources.select(correction.targetLanguage)
        postUnicode(correction.replacement)
        guard let delimiterEvent, let copiedDelimiter = delimiterEvent.copy() else { return }
        copiedDelimiter.setIntegerValueField(.eventSourceUserData, value: Self.injectedEventMarker)
        copiedDelimiter.post(tap: .cgSessionEventTap)
    }

    private func postKey(code: CGKeyCode, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { return }
        event.flags = []
        event.setIntegerValueField(.eventSourceUserData, value: Self.injectedEventMarker)
        event.post(tap: .cgSessionEventTap)
    }

    private func postUnicode(_ text: String) {
        let utf16 = Array(text.utf16)
        for codeUnit in utf16 {
            var unit = codeUnit
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { continue }
            down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            down.flags = []
            up.flags = []
            down.setIntegerValueField(.eventSourceUserData, value: Self.injectedEventMarker)
            up.setIntegerValueField(.eventSourceUserData, value: Self.injectedEventMarker)
            down.post(tap: .cgSessionEventTap)
            up.post(tap: .cgSessionEventTap)
        }
    }

    func insertText(_ text: String) {
        guard isRunning, !text.isEmpty else { return }
        token.reset()
        pasteTextPreservingClipboard(text)
    }

    private func pasteTextPreservingClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            snapshot.restore(to: pasteboard)
            postUnicode(text)
            return
        }
        let temporaryChangeCount = pasteboard.changeCount

        // Embedded Chromium/Electron editors reliably process a real paste
        // shortcut, while many of them ignore CGEvent Unicode payloads.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.postCommandV()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            // Do not overwrite a new clipboard value copied by the user while
            // the paste was in flight.
            guard pasteboard.changeCount == temporaryChangeCount else { return }
            snapshot.restore(to: pasteboard)
        }
    }

    private func postCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: Self.injectedEventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: Self.injectedEventMarker)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

private struct PasteboardSnapshot {
    private struct Item {
        let values: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    private let items: [Item]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { pasteboardItem in
            Item(values: pasteboardItem.types.compactMap { type in
                pasteboardItem.data(forType: type).map { (type, $0) }
            })
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restoredItems: [NSPasteboardItem] = items.map { savedItem in
            let item = NSPasteboardItem()
            for value in savedItem.values {
                item.setData(value.data, forType: value.type)
            }
            return item
        }
        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems)
        }
    }
}
