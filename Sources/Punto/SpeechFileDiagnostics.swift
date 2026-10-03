import AVFoundation
import Foundation
import Speech

/// Диагностика конвейера распознавания на аудиофайле без микрофона:
/// `Punto --transcribe-file <audio> [--out <report>] [--fast] [--only ru-RU|en-US]`.
/// Использует те же бэкенды, что и голосовой ввод (первый язык в процессе,
/// второй во вспомогательном процессе), показывает время финальных
/// результатов, уверенность и выбор MixedLanguageTranscriptBuilder сразу и по
/// таймауту приложения.
enum SpeechFileDiagnostics {
    private struct Event {
        let at: TimeInterval
        let isFinal: Bool
        let transcript: String
        let segments: [TimedSpeechSegment]
    }

    private final class Candidate {
        let language: SpeechLanguage
        let backend: RecognitionBackend
        var events: [Event] = []
        var errorDescription: String?
        var errorAt: TimeInterval?

        init(language: SpeechLanguage, backend: RecognitionBackend) {
            self.language = language
            self.backend = backend
        }

        func snapshot(at limit: TimeInterval?, timedOut: Bool) -> RecognitionCandidateSnapshot {
            let visible = events.filter { event in
                guard let limit else { return true }
                return event.at <= limit
            }
            let errorVisible: Bool = {
                guard let errorAt else { return false }
                guard let limit else { return true }
                return errorAt <= limit
            }()
            let last = visible.last
            let status: RecognitionCandidateStatus
            if let last, last.isFinal {
                status = .final
            } else if last != nil {
                status = errorVisible ? .failedWithPartial : .partial
            } else if errorVisible {
                status = .failed
            } else {
                status = timedOut ? .timedOut : .waiting
            }
            let segments = last?.segments ?? []
            var totalWeight = 0
            var weightedSum = 0.0
            for segment in segments {
                let weight = max(segment.text.count, 1)
                totalWeight += weight
                weightedSum += segment.confidence * Double(weight)
            }
            return RecognitionCandidateSnapshot(
                language: language,
                transcript: last?.transcript ?? "",
                segments: segments,
                confidence: totalWeight == 0 ? 0 : weightedSum / Double(totalWeight),
                status: status
            )
        }
    }

    static func run(
        audioPath: String,
        outputPath: String?,
        realtime: Bool,
        onlyLanguage: SpeechLanguage? = nil
    ) {
        var lines: [String] = []
        func emit(_ line: String) {
            lines.append(line)
            print(line)
        }
        func flush() {
            guard let outputPath else { return }
            try? (lines.joined(separator: "\n") + "\n").write(
                toFile: outputPath, atomically: true, encoding: .utf8
            )
        }
        defer { flush() }

        emit("Punto speech diagnostics")
        emit("audio: \(audioPath)")
        emit("pace: \(realtime ? "realtime" : "fast"), only: \(onlyLanguage?.rawValue ?? "both")")

        var authorization = SFSpeechRecognizer.authorizationStatus()
        if authorization == .notDetermined {
            let semaphore = DispatchSemaphore(value: 0)
            SFSpeechRecognizer.requestAuthorization { status in
                authorization = status
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 60)
        }
        emit("speech authorization: \(authorization.rawValue) (3 = authorized)")
        guard authorization == .authorized else {
            emit("DONE: not authorized")
            return
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: URL(fileURLWithPath: audioPath))
        } catch {
            emit("DONE: cannot open audio: \(error)")
            return
        }
        let format = file.processingFormat
        let audioDuration = Double(file.length) / format.sampleRate
        emit(String(format: "format: %.0f Hz, %d ch, %.1f s", format.sampleRate, format.channelCount, audioDuration))

        let requestedLanguages = onlyLanguage.map { [$0] } ?? [SpeechLanguage.russian, .english]
        let candidates: [Candidate] = requestedLanguages.enumerated().compactMap { index, language in
            guard let locale = language.locale else { return nil }
            let backend: RecognitionBackend? = index == 0
                ? InProcessRecognitionBackend(locale: locale)
                : HelperProcessRecognitionBackend(locale: locale)
            guard let backend else {
                emit("\(language.rawValue): backend unavailable")
                return nil
            }
            emit("\(language.rawValue): \(backend.description)")
            return Candidate(language: language, backend: backend)
        }
        guard candidates.count == requestedLanguages.count else {
            emit("DONE: recognizer missing")
            return
        }

        let clock = Date()
        let stateQueue = DispatchQueue(label: "local.punto.diagnostics")
        for candidate in candidates {
            candidate.backend.start(format: format) { update, error in
                let at = Date().timeIntervalSince(clock)
                stateQueue.sync {
                    if let update {
                        candidate.events.append(Event(
                            at: at,
                            isFinal: update.isFinal,
                            transcript: update.transcript,
                            segments: update.segments
                        ))
                    }
                    if let error, candidate.errorDescription == nil {
                        candidate.errorDescription = "\(error)"
                        candidate.errorAt = at
                    }
                }
            }
        }

        let chunkFrames = AVAudioFrameCount(format.sampleRate / 10)
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { break }
            do {
                try file.read(into: buffer, frameCount: chunkFrames)
            } catch {
                emit("read error: \(error)")
                break
            }
            guard buffer.frameLength > 0 else { break }
            candidates.forEach { $0.backend.append(buffer) }
            if realtime {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: Double(buffer.frameLength) / format.sampleRate))
            }
        }
        let endAudioAt = Date().timeIntervalSince(clock)
        candidates.forEach { $0.backend.endAudio() }
        emit(String(format: "endAudio at %.2f s", endAudioAt))

        func allTerminal() -> Bool {
            stateQueue.sync {
                candidates.allSatisfy { ($0.events.last?.isFinal ?? false) || $0.errorDescription != nil }
            }
        }
        let waitDeadline = Date(timeIntervalSinceNow: 30)
        while !allTerminal() && Date() < waitDeadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        candidates.forEach { $0.backend.cancel() }

        stateQueue.sync {
            for candidate in candidates {
                emit("")
                emit("== \(candidate.language.rawValue) (\(candidate.backend.description)) ==")
                emit("events: \(candidate.events.count), error: \(candidate.errorDescription ?? "none")"
                    + (candidate.errorAt.map { String(format: " at %.2f s", $0) } ?? ""))
                for (index, event) in candidate.events.enumerated()
                where index < 2 || index >= candidate.events.count - 2 || event.isFinal {
                    let zero = event.segments.filter { $0.confidence == 0 }.count
                    let average = event.segments.isEmpty
                        ? 0
                        : event.segments.map(\.confidence).reduce(0, +) / Double(event.segments.count)
                    emit(String(
                        format: "  [%d] t=%.2f final=%@ words=%d zeroConf=%d avgConf=%.2f text=\"%@\"",
                        index, event.at, event.isFinal ? "yes" : "no", event.segments.count, zero, average,
                        event.transcript.count > 100 ? String(event.transcript.prefix(100)) + "…" : event.transcript
                    ))
                }
                if let final = candidate.events.last(where: \.isFinal) {
                    emit(String(format: "final latency after endAudio: %.2f s", final.at - endAudioAt))
                    emit("final transcript: \(final.transcript)")
                    emit("final segments: " + final.segments.map {
                        String(format: "%@(%.2f-%.2f c%.2f)", $0.text, $0.timestamp, $0.timestamp + $0.duration, $0.confidence)
                    }.joined(separator: " "))
                    for segment in final.segments {
                        let voiced = zip(segment.pitch, segment.voicing).filter { $0.1 >= 0.5 }.map(\.0)
                        let contour = stride(from: 0, to: segment.pitch.count, by: max(1, segment.pitch.count / 8)).map {
                            String(format: "%.2f", segment.pitch[$0])
                        }.joined(separator: " ")
                        let voicingText = segment.voicing.map { String(format: "%.2f", $0) }.joined(separator: " ")
                        emit(String(
                            format: "  pitch %@: frames=%d voiced=%d mean=%.3f max=%.3f contour=[%@] voicing=[%@]",
                            segment.text, segment.pitch.count, voiced.count,
                            voiced.isEmpty ? 0 : voiced.reduce(0, +) / Double(voiced.count),
                            voiced.max() ?? 0, contour, voicingText
                        ))
                    }
                } else {
                    emit("no final result within 30 s")
                }
            }

            func report(_ title: String, timedOut: Bool, limit: TimeInterval?) {
                emit("")
                emit("== selection: \(title) ==")
                let snapshots = candidates.map { $0.snapshot(at: limit, timedOut: timedOut) }
                for snapshot in snapshots {
                    emit(String(
                        format: "  %@ status=%@ conf=%.2f words=%d score=%.4f",
                        snapshot.language.rawValue, "\(snapshot.status)", snapshot.confidence, snapshot.segments.count,
                        SpeechCandidateScorer.score(
                            transcript: snapshot.transcript,
                            language: snapshot.language,
                            acousticConfidence: snapshot.confidence
                        )
                    ))
                }
                guard let selected = RecognitionFinalizationSelector.select(
                    from: snapshots,
                    requestedLanguage: .automatic,
                    timedOut: timedOut
                ) else {
                    emit("  selected: nil")
                    return
                }
                let punctuated = AutomaticPunctuation.restore(
                    formattedTranscript: selected.formattedTranscript,
                    segments: selected.segments,
                    language: selected.language,
                    preserveFormattedTranscript: selected.language != .automatic
                )
                let text = TranscriptNormalizer.normalize(punctuated, language: selected.language)
                emit("  selected language: \(selected.language.rawValue)")
                emit("  output: \(text)")
            }
            report("all final results", timedOut: false, limit: nil)
            let timeout = SpeechDictationController.processingTimeout(forAudioDuration: audioDuration)
            report(String(format: "app timeout %.1f s after endAudio", timeout), timedOut: true, limit: endAudioAt + timeout)
        }
        emit("")
        emit("DONE")
    }
}
