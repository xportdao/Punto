import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let monitor = KeyboardMonitor()
    private let speechController = SpeechDictationController()
    private var statusItem: NSStatusItem!
    private var stateItem: NSMenuItem!
    private var toggleItem: NSMenuItem!
    private var voiceStateItem: NSMenuItem!
    private var voiceToggleItem: NSMenuItem!
    private var automaticLanguageItem: NSMenuItem!
    private var russianLanguageItem: NSMenuItem!
    private var englishLanguageItem: NSMenuItem!
    private var accessibilityPermissionItem: NSMenuItem!
    private var speechPermissionItem: NSMenuItem!
    private var microphonePermissionItem: NSMenuItem!
    private var shortcutItems: [NSMenuItem] = []
    private var voiceShortcut = VoiceShortcut.load()
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor.voiceShortcut = voiceShortcut
        configureMenu()
        monitor.onVoiceShortcut = { [weak self] in self?.toggleVoiceInput() }
        monitor.isVoiceListening = { [weak self] in self?.speechController.state.isListening == true }
        monitor.onStopVoiceBySpace = { [weak self] in self?.speechController.stop() }
        speechController.onText = { [weak self] text in self?.monitor.insertText(text) }
        speechController.onStateChange = { [weak self] state in self?.refreshVoiceState(state) }
        requestAccessibilityPermissionIfNeeded()
        refreshState()
        refreshVoiceState(speechController.state)
    }

    func applicationWillTerminate(_ notification: Notification) {
        speechController.cancel()
        monitor.stop()
    }

    private func configureMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = PuntoIcon.menuBarImage(.idle)
        statusItem.button?.toolTip = "Punto — автокоррекция раскладки"

        let menu = NSMenu()
        stateItem = NSMenuItem(title: "Запуск…", action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(.separator())

        toggleItem = NSMenuItem(
            title: "Приостановить",
            action: #selector(toggleMonitoring),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())
        voiceStateItem = NSMenuItem(title: "Голосовой ввод готов", action: nil, keyEquivalent: "")
        voiceStateItem.isEnabled = false
        menu.addItem(voiceStateItem)

        voiceToggleItem = NSMenuItem(
            title: "Начать голосовой ввод",
            action: #selector(toggleVoiceInput),
            keyEquivalent: ""
        )
        voiceToggleItem.target = self
        menu.addItem(voiceToggleItem)

        let languageItem = NSMenuItem(title: "Язык речи", action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        automaticLanguageItem = NSMenuItem(
            title: "Авто: Русский + English",
            action: #selector(selectAutomaticSpeech),
            keyEquivalent: ""
        )
        automaticLanguageItem.target = self
        languageMenu.addItem(automaticLanguageItem)
        languageMenu.addItem(.separator())
        russianLanguageItem = NSMenuItem(
            title: "Русский",
            action: #selector(selectRussianSpeech),
            keyEquivalent: ""
        )
        russianLanguageItem.target = self
        languageMenu.addItem(russianLanguageItem)
        englishLanguageItem = NSMenuItem(
            title: "English",
            action: #selector(selectEnglishSpeech),
            keyEquivalent: ""
        )
        englishLanguageItem.target = self
        languageMenu.addItem(englishLanguageItem)
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)
        refreshLanguageChecks()

        let shortcutItem = NSMenuItem(title: "Сочетание клавиш", action: nil, keyEquivalent: "")
        let shortcutMenu = NSMenu()
        shortcutMenu.autoenablesItems = false
        shortcutMenu.delegate = self
        shortcutItems = VoiceShortcut.presets.map { preset in
            let item = NSMenuItem(
                title: preset.title,
                action: #selector(selectVoiceShortcut(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = preset.id
            shortcutMenu.addItem(item)
            return item
        }
        shortcutItem.submenu = shortcutMenu
        menu.addItem(shortcutItem)
        refreshShortcutChecks()

        accessibilityPermissionItem = NSMenuItem(
            title: "Настройки Универсального доступа…",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        accessibilityPermissionItem.target = self
        menu.addItem(accessibilityPermissionItem)
        speechPermissionItem = NSMenuItem(
            title: "Настройки распознавания речи…",
            action: #selector(openSpeechRecognitionSettings),
            keyEquivalent: ""
        )
        speechPermissionItem.target = self
        menu.addItem(speechPermissionItem)
        microphonePermissionItem = NSMenuItem(
            title: "Настройки микрофона…",
            action: #selector(openMicrophoneSettings),
            keyEquivalent: ""
        )
        microphonePermissionItem.target = self
        menu.addItem(microphonePermissionItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Завершить Punto", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func requestAccessibilityPermissionIfNeeded() {
        guard !AXIsProcessTrusted() else {
            startMonitoring()
            return
        }

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard AXIsProcessTrusted() else { return }
            self?.permissionTimer?.invalidate()
            self?.permissionTimer = nil
            self?.startMonitoring()
        }
    }

    private func startMonitoring() {
        do {
            try monitor.start()
        } catch {
            stateItem.title = "Не удалось запустить перехват клавиатуры"
        }
        refreshState()
    }

    private func refreshState() {
        if !AXIsProcessTrusted() {
            stateItem.title = "Нужен доступ к управлению компьютером"
            toggleItem.isEnabled = false
            voiceToggleItem.isEnabled = false
            statusItem.button?.appearsDisabled = true
        } else if monitor.isRunning {
            stateItem.title = "Автокоррекция включена"
            toggleItem.title = "Приостановить"
            toggleItem.isEnabled = true
            voiceToggleItem.isEnabled = true
            statusItem.button?.appearsDisabled = false
        } else {
            stateItem.title = "Автокоррекция приостановлена"
            toggleItem.title = "Продолжить"
            toggleItem.isEnabled = true
            voiceToggleItem.isEnabled = false
            statusItem.button?.appearsDisabled = true
        }
    }

    @objc private func toggleMonitoring() {
        if monitor.isRunning {
            if speechController.isActive {
                speechController.cancel()
            }
            monitor.stop()
        } else {
            startMonitoring()
        }
        refreshState()
    }

    @objc private func toggleVoiceInput() {
        guard AXIsProcessTrusted(), monitor.isRunning else {
            openAccessibilitySettings()
            return
        }
        speechController.toggle()
    }

    @objc private func selectRussianSpeech() {
        speechController.language = .russian
        refreshLanguageChecks()
    }

    @objc private func selectAutomaticSpeech() {
        speechController.language = .automatic
        refreshLanguageChecks()
    }

    @objc private func selectEnglishSpeech() {
        speechController.language = .english
        refreshLanguageChecks()
    }

    @objc private func selectVoiceShortcut(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let shortcut = VoiceShortcut.preset(id: id) else { return }
        voiceShortcut = shortcut
        shortcut.save()
        monitor.voiceShortcut = shortcut
        refreshShortcutChecks()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshShortcutChecks()
    }

    private func refreshShortcutChecks() {
        let hotkeys = SystemHotkey.current()
        for item in shortcutItems {
            guard let id = item.representedObject as? String,
                  let preset = VoiceShortcut.preset(id: id) else { continue }
            let isSelected = id == voiceShortcut.id
            item.state = isSelected ? .on : .off
            if let conflict = preset.systemConflict(in: hotkeys) {
                // Занятое macOS сочетание не предлагаем: Punto перехватил бы,
                // например, переключение раскладки.
                item.title = "\(preset.title) — занято macOS: \(conflict.title)"
                item.isEnabled = isSelected
            } else {
                item.title = preset.title
                item.isEnabled = true
            }
        }
        // Пункт меню только показывает сочетание; сам перехват выполняет KeyboardMonitor.
        voiceToggleItem.keyEquivalent = voiceShortcut.keyEquivalent
        voiceToggleItem.keyEquivalentModifierMask = voiceShortcut.keyEquivalentModifierMask
    }

    private func refreshLanguageChecks() {
        automaticLanguageItem.state = speechController.language == .automatic ? .on : .off
        russianLanguageItem.state = speechController.language == .russian ? .on : .off
        englishLanguageItem.state = speechController.language == .english ? .on : .off
    }

    private func refreshVoiceState(_ state: SpeechDictationState) {
        guard voiceStateItem != nil else { return }
        switch state {
        case .idle:
            voiceStateItem.title = "Голосовой ввод готов"
            voiceToggleItem.title = "Начать голосовой ввод"
            statusItem.button?.image = PuntoIcon.menuBarImage(.idle)
            statusItem.button?.toolTip = "Punto — автокоррекция и голосовой ввод"
        case .requestingPermission:
            voiceStateItem.title = "Ожидание разрешений…"
            voiceToggleItem.title = "Отменить голосовой ввод"
            statusItem.button?.image = PuntoIcon.menuBarImage(.busy)
        case .listening:
            voiceStateItem.title = "Слушаю — пробел для завершения"
            voiceToggleItem.title = "Остановить и вставить текст"
            statusItem.button?.image = PuntoIcon.menuBarImage(.listening)
            statusItem.button?.toolTip = "Punto записывает речь — пробел для завершения"
        case .listeningDegraded(let availableLanguage):
            voiceStateItem.title = "Слушаю только: \(availableLanguage.title)"
            voiceToggleItem.title = "Остановить и вставить текст"
            statusItem.button?.image = PuntoIcon.menuBarImage(.listening)
            statusItem.button?.toolTip = "В авто-режиме доступен только \(availableLanguage.title)"
        case .processing:
            voiceStateItem.title = "Обрабатываю речь…"
            voiceToggleItem.title = "Завершение…"
            statusItem.button?.image = PuntoIcon.menuBarImage(.busy)
        case .failed(let message):
            voiceStateItem.title = message
            voiceToggleItem.title = "Повторить голосовой ввод"
            statusItem.button?.image = PuntoIcon.menuBarImage(.failed)
            statusItem.button?.toolTip = message
        }
        voiceToggleItem.isEnabled = AXIsProcessTrusted() && monitor.isRunning && state != .processing
        automaticLanguageItem.isEnabled = !speechController.isActive
        russianLanguageItem.isEnabled = !speechController.isActive
        englishLanguageItem.isEnabled = !speechController.isActive
    }

    @objc private func openAccessibilitySettings() {
        openPrivacySettings("Privacy_Accessibility")
    }

    @objc private func openSpeechRecognitionSettings() {
        openPrivacySettings("Privacy_SpeechRecognition")
    }

    @objc private func openMicrophoneSettings() {
        openPrivacySettings("Privacy_Microphone")
    }

    private func openPrivacySettings(_ anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
