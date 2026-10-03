import AppKit
import ApplicationServices

if let helperIndex = CommandLine.arguments.firstIndex(of: "--recognizer-helper"),
   CommandLine.arguments.indices.contains(helperIndex + 1) {
    RecognitionHelper.run(localeIdentifier: CommandLine.arguments[helperIndex + 1])
}

if let iconIndex = CommandLine.arguments.firstIndex(of: "--write-iconset"),
   CommandLine.arguments.indices.contains(iconIndex + 1) {
    // Используется build-app.sh: PNG для `iconutil -c icns`.
    do {
        try PuntoIcon.writeIconset(to: URL(fileURLWithPath: CommandLine.arguments[iconIndex + 1]))
        exit(EXIT_SUCCESS)
    } catch {
        FileHandle.standardError.write(Data("iconset: \(error)\n".utf8))
        exit(EXIT_FAILURE)
    }
}

if let postIndex = CommandLine.arguments.firstIndex(of: "--post-test-shortcut"),
   CommandLine.arguments.indices.contains(postIndex + 1) {
    let id = CommandLine.arguments[postIndex + 1]
    let output = CommandLine.arguments.firstIndex(of: "--out").flatMap { index -> String? in
        CommandLine.arguments.indices.contains(index + 1) ? CommandLine.arguments[index + 1] : nil
    }
    var report = "accessibility trusted: \(AXIsProcessTrusted())\n"
    if let shortcut = VoiceShortcut.preset(id: id) {
        VoiceShortcutSimulator.post(shortcut)
        report += "posted: \(shortcut.id)\n"
    } else {
        report += "unknown shortcut: \(id)\n"
    }
    if let output { try? report.write(toFile: output, atomically: true, encoding: .utf8) }
    print(report, terminator: "")
    exit(EXIT_SUCCESS)
}

if CommandLine.arguments.contains("--self-test") {
    PuntoSelfTest.run()
    exit(EXIT_SUCCESS)
}

if let checkIndex = CommandLine.arguments.firstIndex(of: "--check-word"),
   CommandLine.arguments.indices.contains(checkIndex + 1) {
    // Проверка по включённым у пользователя раскладкам, как при наборе.
    let word = CommandLine.arguments[checkIndex + 1]
    let inputSources = InputSourceController()
    let english = inputSources.layout(for: .english)
    let russian = inputSources.layout(for: .russian)
    print("layouts: \(english?.identifier ?? "no English layout") / \(russian?.identifier ?? "no Russian layout")")
    if let correction = WordClassifier().correction(for: word, english: english, russian: russian) {
        print("\(word) -> \(correction.replacement)")
    } else {
        print("\(word) -> no correction")
    }
    exit(EXIT_SUCCESS)
}

if let scoreIndex = CommandLine.arguments.firstIndex(of: "--score-speech"),
   CommandLine.arguments.indices.contains(scoreIndex + 2),
   let language = SpeechLanguage(rawValue: CommandLine.arguments[scoreIndex + 1]) {
    let transcript = CommandLine.arguments[scoreIndex + 2]
    let score = SpeechCandidateScorer.score(
        transcript: transcript,
        language: language,
        acousticConfidence: 0.75
    )
    print(String(format: "%.4f", score))
    exit(EXIT_SUCCESS)
}

if let fileIndex = CommandLine.arguments.firstIndex(of: "--transcribe-file"),
   CommandLine.arguments.indices.contains(fileIndex + 1) {
    let outputPath = CommandLine.arguments.firstIndex(of: "--out").flatMap { index -> String? in
        CommandLine.arguments.indices.contains(index + 1) ? CommandLine.arguments[index + 1] : nil
    }
    SpeechFileDiagnostics.run(
        audioPath: CommandLine.arguments[fileIndex + 1],
        outputPath: outputPath,
        realtime: !CommandLine.arguments.contains("--fast"),
        onlyLanguage: CommandLine.arguments.firstIndex(of: "--only").flatMap { index -> SpeechLanguage? in
            CommandLine.arguments.indices.contains(index + 1) ? SpeechLanguage(rawValue: CommandLine.arguments[index + 1]) : nil
        }
    )
    exit(EXIT_SUCCESS)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.setActivationPolicy(.accessory)
application.delegate = delegate
application.run()
