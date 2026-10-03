import AVFoundation
import Foundation
import Speech

enum SpeechLanguage: String, CaseIterable, Hashable {
    case automatic = "auto"
    case russian = "ru-RU"
    case english = "en-US"

    var locale: Locale? {
        switch self {
        case .automatic: return nil
        case .russian, .english: return Locale(identifier: rawValue)
        }
    }

    var title: String {
        switch self {
        case .automatic: return "Авто: Русский + English"
        case .russian: return "Русский"
        case .english: return "English"
        }
    }
}

enum SpeechDictationState: Equatable {
    case idle
    case requestingPermission
    case listening
    case listeningDegraded(SpeechLanguage)
    case processing
    case failed(String)

    var isListening: Bool {
        switch self {
        case .listening, .listeningDegraded: return true
        default: return false
        }
    }
}

enum RecognitionCandidateStatus: Equatable {
    case waiting
    case partial
    case final
    case failedWithPartial
    case failed
    case timedOut

    var isTerminal: Bool {
        switch self {
        case .final, .failedWithPartial, .failed, .timedOut: return true
        case .waiting, .partial: return false
        }
    }
}

enum RecognitionSessionPhase: Equatable {
    case listening
    case processing
}

enum RecognitionCompletionDecision: Equatable {
    case wait
    case deliver
    case failNoText
}

enum RecognitionCompletionPolicy {
    static func decision(
        phase: RecognitionSessionPhase,
        statuses: [RecognitionCandidateStatus],
        hasEligibleText: Bool,
        timedOut: Bool = false
    ) -> RecognitionCompletionDecision {
        guard !statuses.isEmpty else { return .failNoText }
        if phase == .listening {
            return statuses.allSatisfy({ $0 == .failed }) && !hasEligibleText
                ? .failNoText
                : .wait
        }
        if timedOut || statuses.allSatisfy(\.isTerminal) {
            return hasEligibleText ? .deliver : .failNoText
        }
        return .wait
    }
}

enum RecognitionCallbackPolicy {
    static func shouldReplaceData(
        previous: RecognitionCandidateStatus,
        receivedResult: Bool
    ) -> Bool {
        receivedResult && previous != .final
    }

    static func status(
        previous: RecognitionCandidateStatus,
        receivedResult: Bool,
        resultIsFinal: Bool,
        receivedError: Bool
    ) -> RecognitionCandidateStatus {
        if previous == .final { return .final }
        if receivedResult {
            if resultIsFinal { return .final }
            return receivedError ? .failedWithPartial : .partial
        }
        if receivedError {
            switch previous {
            case .final:
                return .final
            case .partial, .failedWithPartial:
                return .failedWithPartial
            case .timedOut:
                return .timedOut
            case .waiting, .failed:
                return .failed
            }
        }
        return previous
    }
}

struct RecognitionCandidateSnapshot: Equatable {
    let language: SpeechLanguage
    let transcript: String
    let segments: [TimedSpeechSegment]
    let confidence: Double
    let status: RecognitionCandidateStatus

    var hasText: Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || segments.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

struct FinalizedSpeechSelection: Equatable {
    let formattedTranscript: String
    let segments: [TimedSpeechSegment]
    let language: SpeechLanguage
}

enum RecognitionFinalizationSelector {
    typealias ScoreProvider = (_ text: String, _ language: SpeechLanguage, _ confidence: Double) -> Double

    static func eligibleSnapshots(
        from snapshots: [RecognitionCandidateSnapshot],
        timedOut: Bool
    ) -> [RecognitionCandidateSnapshot] {
        if timedOut {
            return snapshots.filter {
                $0.hasText && [
                    RecognitionCandidateStatus.final,
                    .partial,
                    .failedWithPartial,
                    .timedOut
                ].contains($0.status)
            }
        }

        let terminalRecoverable = snapshots.filter {
            $0.hasText && ($0.status == .final || $0.status == .failedWithPartial)
        }
        if !terminalRecoverable.isEmpty { return terminalRecoverable }
        return []
    }

    static func select(
        from snapshots: [RecognitionCandidateSnapshot],
        requestedLanguage: SpeechLanguage,
        timedOut: Bool,
        scoreProvider: ScoreProvider? = nil
    ) -> FinalizedSpeechSelection? {
        let eligible = eligibleSnapshots(from: snapshots, timedOut: timedOut)
        guard !eligible.isEmpty else { return nil }

        if requestedLanguage == .automatic,
           eligible.allSatisfy({ !$0.segments.isEmpty }),
           let mixed = MixedLanguageTranscriptBuilder.select(
               from: eligible.map {
                   SpeechTranscriptCandidate(
                       language: $0.language,
                       segments: $0.segments,
                       formattedTranscript: $0.transcript
                   )
               },
               scoreProvider: scoreProvider
           ) {
            return FinalizedSpeechSelection(
                formattedTranscript: mixed.formattedTranscript,
                segments: mixed.segments,
                language: mixed.languages.count == 1
                    ? mixed.languages.first ?? .automatic
                    : .automatic
            )
        }

        guard let best = eligible.max(by: { snapshotPrecedes($0, $1, scoreProvider: scoreProvider) }) else {
            return nil
        }
        return FinalizedSpeechSelection(
            formattedTranscript: best.transcript,
            segments: best.segments,
            language: best.language
        )
    }

    private static func snapshotPrecedes(
        _ left: RecognitionCandidateSnapshot,
        _ right: RecognitionCandidateSnapshot,
        scoreProvider: ScoreProvider?
    ) -> Bool {
        let leftScore = score(left, scoreProvider: scoreProvider)
        let rightScore = score(right, scoreProvider: scoreProvider)
        if abs(leftScore - rightScore) > 0.000_000_1 {
            return leftScore < rightScore
        }
        if abs(left.confidence - right.confidence) > 0.000_000_1 {
            return left.confidence < right.confidence
        }
        if left.transcript != right.transcript {
            return left.transcript > right.transcript
        }
        return languageRank(left.language) > languageRank(right.language)
    }

    private static func score(
        _ snapshot: RecognitionCandidateSnapshot,
        scoreProvider: ScoreProvider?
    ) -> Double {
        scoreProvider?(snapshot.transcript, snapshot.language, snapshot.confidence)
            ?? SpeechCandidateScorer.score(
                transcript: snapshot.transcript,
                language: snapshot.language,
                acousticConfidence: snapshot.confidence
            )
    }

    private static func languageRank(_ language: SpeechLanguage) -> Int {
        switch language {
        case .english: return 0
        case .russian: return 1
        case .automatic: return 2
        }
    }
}

private final class RecognitionCandidate {
    let language: SpeechLanguage
    let backend: RecognitionBackend
    var transcript = ""
    var segments: [TimedSpeechSegment] = []
    var confidence: Double = 0
    var status: RecognitionCandidateStatus = .waiting

    var snapshot: RecognitionCandidateSnapshot {
        RecognitionCandidateSnapshot(
            language: language,
            transcript: transcript,
            segments: segments,
            confidence: confidence,
            status: status
        )
    }

    init(language: SpeechLanguage, backend: RecognitionBackend) {
        self.language = language
        self.backend = backend
    }

    func update(with update: RecognitionUpdate, error: Error?) {
        guard RecognitionCallbackPolicy.shouldReplaceData(
            previous: status,
            receivedResult: true
        ) else { return }
        transcript = update.transcript
        segments = update.segments
        status = RecognitionCallbackPolicy.status(
            previous: status,
            receivedResult: true,
            resultIsFinal: update.isFinal,
            receivedError: error != nil
        )
        let totalWeight = segments.reduce(0) { $0 + max($1.text.count, 1) }
        guard totalWeight > 0 else {
            confidence = 0
            return
        }
        confidence = segments.reduce(0.0) { partial, segment in
            partial + segment.confidence * Double(max(segment.text.count, 1))
        } / Double(totalWeight)
    }
}

final class SpeechDictationController {
    private let audioEngine = AVAudioEngine()
    private var candidates: [RecognitionCandidate] = []
    private var sessionID: UUID?
    private var hasInputTap = false
    private var unavailableAutomaticLanguages: Set<SpeechLanguage> = []
    private var didProcessingTimeout = false
    private var listeningStartedAt: Date?
    private var recordingFile: AVAudioFile?

    /// Последняя запись голосового ввода для диагностики:
    /// `Punto --transcribe-file <этот файл>`.
    static let lastDictationURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Punto/last-dictation.caf")

    var onStateChange: ((SpeechDictationState) -> Void)?
    var onText: ((String) -> Void)?

    private(set) var state: SpeechDictationState = .idle {
        didSet { onStateChange?(state) }
    }

    var language: SpeechLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "speechLanguage") }
    }

    init() {
        let defaults = UserDefaults.standard
        if defaults.integer(forKey: "speechLanguageModeVersion") < 2 {
            language = .automatic
            defaults.set(SpeechLanguage.automatic.rawValue, forKey: "speechLanguage")
            defaults.set(2, forKey: "speechLanguageModeVersion")
        } else {
            language = SpeechLanguage(
                rawValue: defaults.string(forKey: "speechLanguage") ?? ""
            ) ?? .automatic
        }
    }

    var isActive: Bool {
        switch state {
        case .requestingPermission, .listening, .listeningDegraded, .processing: return true
        case .idle, .failed: return false
        }
    }

    func toggle() {
        isActive ? stop() : start()
    }

    func start() {
        guard !isActive else { return }
        let newSessionID = UUID()
        sessionID = newSessionID
        candidates = []
        unavailableAutomaticLanguages = []
        didProcessingTimeout = false
        state = .requestingPermission
        requestSpeechPermission(sessionID: newSessionID)
    }

    func stop() {
        guard let activeSessionID = sessionID else {
            state = .idle
            return
        }
        if state == .requestingPermission {
            finish(sessionID: activeSessionID, deliverText: false)
            return
        }
        guard state.isListening else { return }

        stopAudioCapture()
        candidates.forEach { $0.backend.endAudio() }
        state = .processing
        evaluateCompletion(sessionID: activeSessionID)
        guard sessionID == activeSessionID else { return }

        let audioDuration = listeningStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let timeout = Self.processingTimeout(forAudioDuration: audioDuration)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.sessionID == activeSessionID else { return }
            self.didProcessingTimeout = true
            self.candidates.forEach {
                if $0.status == .waiting { $0.status = .timedOut }
            }
            self.evaluateCompletion(sessionID: activeSessionID, timedOut: true)
        }
    }

    func cancel() {
        finish(sessionID: sessionID, deliverText: false)
    }

    /// Финальный результат локальной модели приходит тем позже, чем длиннее
    /// запись; частичные результаты не несут уверенности, поэтому ждём дольше.
    static func processingTimeout(forAudioDuration duration: TimeInterval) -> TimeInterval {
        min(8.0, 2.0 + 0.05 * max(duration, 0))
    }

    private func requestSpeechPermission(sessionID: UUID) {
        let proceed: (SFSpeechRecognizerAuthorizationStatus) -> Void = { [weak self] status in
            DispatchQueue.main.async {
                guard self?.sessionID == sessionID else { return }
                guard status == .authorized else {
                    self?.fail("Нет доступа к распознаванию речи — откройте настройки", sessionID: sessionID)
                    return
                }
                self?.requestMicrophonePermission(sessionID: sessionID)
            }
        }
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            SFSpeechRecognizer.requestAuthorization(proceed)
        } else {
            proceed(SFSpeechRecognizer.authorizationStatus())
        }
    }

    private func requestMicrophonePermission(sessionID: UUID) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginRecognition(sessionID: sessionID)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard self?.sessionID == sessionID else { return }
                    granted
                        ? self?.beginRecognition(sessionID: sessionID)
                        : self?.fail("Нет доступа к микрофону — откройте настройки", sessionID: sessionID)
                }
            }
        default:
            fail("Нет доступа к микрофону — откройте настройки", sessionID: sessionID)
        }
    }

    private func beginRecognition(sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        let requestedLanguages: [SpeechLanguage] = language == .automatic
            ? [.russian, .english]
            : [language]
        candidates = requestedLanguages.enumerated().compactMap { index, language in
            guard let locale = language.locale else { return nil }
            // Только первая задача может жить в этом процессе; остальные
            // языки распознаёт вспомогательный процесс.
            let backend: RecognitionBackend? = index == 0
                ? InProcessRecognitionBackend(locale: locale)
                : HelperProcessRecognitionBackend(locale: locale)
            return backend.map { RecognitionCandidate(language: language, backend: $0) }
        }
        if language == .automatic {
            unavailableAutomaticLanguages = Set(requestedLanguages).subtracting(candidates.map(\.language))
        }
        guard !candidates.isEmpty else {
            fail("Распознавание для выбранных языков недоступно", sessionID: sessionID)
            return
        }

        let inputNode = audioEngine.inputNode
        if hasInputTap {
            inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            fail("Микрофон не предоставляет аудиопоток", sessionID: sessionID)
            return
        }

        for candidate in candidates {
            candidate.backend.start(format: format) { [weak self, weak candidate] update, error in
                DispatchQueue.main.async {
                    guard let self,
                          let candidate,
                          self.sessionID == sessionID,
                          self.candidates.contains(where: { $0 === candidate }) else { return }
                    if let update {
                        candidate.update(with: update, error: error)
                    } else if error != nil {
                        candidate.status = RecognitionCallbackPolicy.status(
                            previous: candidate.status,
                            receivedResult: false,
                            resultIsFinal: false,
                            receivedError: true
                        )
                    }
                    self.handleCandidateUpdate(sessionID: sessionID)
                }
            }
        }

        let activeCandidates = candidates
        let recording = Self.makeRecordingFile(format: format)
        recordingFile = recording
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            activeCandidates.forEach { $0.backend.append(buffer) }
            try? recording?.write(from: buffer)
        }
        hasInputTap = true

        do {
            audioEngine.prepare()
            try audioEngine.start()
            listeningStartedAt = Date()
            refreshListeningState()
        } catch {
            fail("Не удалось запустить микрофон: \(error.localizedDescription)", sessionID: sessionID)
        }
    }

    private func handleCandidateUpdate(sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        if state == .processing {
            evaluateCompletion(sessionID: sessionID)
            return
        }
        guard state.isListening else { return }

        let snapshots = candidates.map(\.snapshot)
        let hasPreservedText = snapshots.contains { $0.hasText && $0.status != .failed }
        let decision = RecognitionCompletionPolicy.decision(
            phase: .listening,
            statuses: snapshots.map(\.status),
            hasEligibleText: hasPreservedText
        )
        if decision == .failNoText {
            fail("Не удалось распознать речь", sessionID: sessionID)
        } else {
            refreshListeningState()
        }
    }

    private func refreshListeningState() {
        guard language == .automatic else {
            state = .listening
            return
        }
        let unusableLanguages = Set(candidates.filter {
            $0.status == .failed || $0.status == .failedWithPartial
        }.map(\.language))
            .union(unavailableAutomaticLanguages)
        let activeLanguages = Set([SpeechLanguage.russian, .english]).subtracting(unusableLanguages)
        if activeLanguages.count == 1, let availableLanguage = activeLanguages.first {
            state = .listeningDegraded(availableLanguage)
        } else {
            state = .listening
        }
    }

    private func evaluateCompletion(sessionID: UUID, timedOut: Bool = false) {
        guard self.sessionID == sessionID else { return }
        let snapshots = candidates.map(\.snapshot)
        let eligible = RecognitionFinalizationSelector.eligibleSnapshots(
            from: snapshots,
            timedOut: timedOut
        )
        let decision = RecognitionCompletionPolicy.decision(
            phase: .processing,
            statuses: snapshots.map(\.status),
            hasEligibleText: !eligible.isEmpty,
            timedOut: timedOut
        )
        switch decision {
        case .wait:
            return
        case .deliver:
            finish(sessionID: sessionID, deliverText: true)
        case .failNoText:
            fail("Речь не распознана", sessionID: sessionID)
        }
    }

    private func finish(sessionID: UUID?, deliverText: Bool) {
        guard sessionID == self.sessionID else { return }
        stopAudioCapture()
        candidates.forEach { $0.backend.cancel() }
        let selected = RecognitionFinalizationSelector.select(
            from: candidates.map(\.snapshot),
            requestedLanguage: language,
            timedOut: didProcessingTimeout
        )
        candidates = []
        unavailableAutomaticLanguages = []
        self.sessionID = nil

        guard deliverText else {
            state = .idle
            return
        }
        guard let selected else {
            state = .failed("Речь не распознана")
            return
        }
        let punctuated = AutomaticPunctuation.restore(
            formattedTranscript: selected.formattedTranscript,
            segments: selected.segments,
            language: selected.language,
            preserveFormattedTranscript: selected.language != .automatic
        )
        let text = TranscriptNormalizer.normalize(punctuated, language: selected.language)
        guard !text.isEmpty else {
            state = .failed("Речь не распознана")
            return
        }
        state = .idle
        onText?(text)
    }

    private func fail(_ message: String, sessionID: UUID? = nil) {
        if let sessionID, sessionID != self.sessionID { return }
        stopAudioCapture()
        candidates.forEach { $0.backend.cancel() }
        candidates = []
        unavailableAutomaticLanguages = []
        self.sessionID = nil
        state = .failed(message)
    }

    private func stopAudioCapture() {
        if audioEngine.isRunning { audioEngine.stop() }
        if hasInputTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }
        recordingFile = nil
    }

    private static func makeRecordingFile(format: AVAudioFormat) -> AVAudioFile? {
        let url = lastDictationURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: url)
        return try? AVAudioFile(forWriting: url, settings: format.settings)
    }
}
