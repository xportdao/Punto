import AVFoundation
import Foundation
import Speech

struct RecognitionUpdate {
    let transcript: String
    let segments: [TimedSpeechSegment]
    let isFinal: Bool
}

extension RecognitionUpdate {
    init(_ result: SFSpeechRecognitionResult) {
        transcript = result.bestTranscription.formattedString
        segments = result.bestTranscription.segments.map {
            TimedSpeechSegment(
                text: $0.substring,
                timestamp: $0.timestamp,
                duration: $0.duration,
                confidence: Double($0.confidence),
                pitch: VoiceAnalyticsReader.pitch(of: $0),
                voicing: VoiceAnalyticsReader.voicing(of: $0)
            )
        }
        isFinal = result.isFinal
    }
}

/// Высота тона и вокализация слова. Покадровые значения доступны с macOS 14;
/// на macOS 13 возвращаются пустые массивы, и вопрос по интонации не ищется.
enum VoiceAnalyticsReader {
    static func pitch(of segment: SFTranscriptionSegment) -> [Double] {
        guard #available(macOS 14.0, *), let analytics = segment.voiceAnalytics else { return [] }
        return analytics.pitch.acousticFeatureValuePerFrame
    }

    static func voicing(of segment: SFTranscriptionSegment) -> [Double] {
        guard #available(macOS 14.0, *), let analytics = segment.voiceAnalytics else { return [] }
        return analytics.voicing.acousticFeatureValuePerFrame
    }
}

struct RecognitionBackendError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Один распознаватель одного языка. macOS 26 допускает только одну активную
/// `SFSpeechRecognitionTask` на процесс: вторая отменяет первую. Поэтому
/// второй язык работает во вспомогательном процессе, а звук передаётся по pipe.
protocol RecognitionBackend: AnyObject {
    typealias Handler = (RecognitionUpdate?, Error?) -> Void
    var description: String { get }
    func start(format: AVAudioFormat, handler: @escaping Handler)
    func append(_ buffer: AVAudioPCMBuffer)
    func endAudio()
    func cancel()
}

enum RecognitionRequestSettings {
    static func configure(_ request: SFSpeechAudioBufferRecognitionRequest) {
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
    }
}

final class InProcessRecognitionBackend: RecognitionBackend {
    private let recognizer: SFSpeechRecognizer
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private var task: SFSpeechRecognitionTask?

    let description = "in-process"

    init?(locale: Locale) {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else { return nil }
        self.recognizer = recognizer
        RecognitionRequestSettings.configure(request)
    }

    func start(format: AVAudioFormat, handler: @escaping Handler) {
        task = recognizer.recognitionTask(with: request) { result, error in
            handler(result.map(RecognitionUpdate.init), error)
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request.append(buffer)
    }

    func endAudio() {
        request.endAudio()
    }

    func cancel() {
        request.endAudio()
        task?.cancel()
        task = nil
    }
}

struct HelperHeader: Codable {
    let sampleRate: Double
}

struct HelperSegment: Codable {
    let text: String
    let timestamp: Double
    let duration: Double
    let confidence: Double
    var pitch: [Double]?
    var voicing: [Double]?
}

struct HelperMessage: Codable {
    var type: String
    var isFinal: Bool?
    var transcript: String?
    var segments: [HelperSegment]?
    var message: String?
}

final class HelperProcessRecognitionBackend: RecognitionBackend {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let writeQueue = DispatchQueue(label: "local.punto.recognizer-helper.write")
    private let lock = NSLock()
    private var pending = Data()
    private var handler: Handler?
    private var finished = false
    private var inputClosed = false
    private var converter: AVAudioConverter?
    private var monoFormat: AVAudioFormat?

    let description = "helper process"

    init?(locale: Locale) {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable,
              let executable = Bundle.main.executableURL else { return nil }
        process.executableURL = executable
        process.arguments = ["--recognizer-helper", locale.identifier]
        process.standardInput = input
        process.standardOutput = output
    }

    func start(format: AVAudioFormat, handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        lock.unlock()
        signal(SIGPIPE, SIG_IGN)

        monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: 1,
            interleaved: false
        )
        if format.commonFormat != .pcmFormatFloat32 || format.isInterleaved,
           let monoFormat {
            converter = AVAudioConverter(from: format, to: monoFormat)
        }

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        process.terminationHandler = { [weak self] process in
            self?.finish(error: RecognitionBackendError(
                message: "Вспомогательный распознаватель завершился (код \(process.terminationStatus))"
            ))
        }
        do {
            try process.run()
        } catch {
            finish(error: RecognitionBackendError(
                message: "Не удалось запустить вспомогательный распознаватель: \(error.localizedDescription)"
            ))
            return
        }
        write(Data("{\"sampleRate\":\(format.sampleRate)}\n".utf8))
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let data = monoFloatData(from: buffer) else { return }
        write(data)
    }

    func endAudio() {
        writeQueue.async { [self] in closeInput() }
    }

    func cancel() {
        finish(error: nil)
    }

    private func monoFloatData(from buffer: AVAudioPCMBuffer) -> Data? {
        var source = buffer
        if let converter, let monoFormat {
            guard let converted = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength) else {
                return nil
            }
            do {
                try converter.convert(to: converted, from: buffer)
            } catch {
                return nil
            }
            source = converted
        }
        guard let channels = source.floatChannelData, source.frameLength > 0 else { return nil }
        return Data(bytes: channels[0], count: Int(source.frameLength) * MemoryLayout<Float>.size)
    }

    private func write(_ data: Data) {
        writeQueue.async { [self] in
            guard !inputClosed, !isFinished else { return }
            let descriptor = input.fileHandleForWriting.fileDescriptor
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(descriptor, base + offset, raw.count - offset)
                    guard written > 0 else { return }
                    offset += written
                }
            }
        }
    }

    /// Только на writeQueue.
    private func closeInput() {
        guard !inputClosed else { return }
        inputClosed = true
        try? input.fileHandleForWriting.close()
    }

    private var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else {
            output.fileHandleForReading.readabilityHandler = nil
            return
        }
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = Data(pending[pending.startIndex..<newline])
            pending.removeSubrange(pending.startIndex...newline)
            guard let message = try? JSONDecoder().decode(HelperMessage.self, from: line) else { continue }
            deliver(message)
        }
    }

    private func deliver(_ message: HelperMessage) {
        switch message.type {
        case "result":
            let update = RecognitionUpdate(
                transcript: message.transcript ?? "",
                segments: (message.segments ?? []).map {
                    TimedSpeechSegment(
                        text: $0.text,
                        timestamp: $0.timestamp,
                        duration: $0.duration,
                        confidence: $0.confidence,
                        pitch: $0.pitch ?? [],
                        voicing: $0.voicing ?? []
                    )
                },
                isFinal: message.isFinal ?? false
            )
            lock.lock()
            let handler = finished ? nil : self.handler
            if update.isFinal { finished = true }
            lock.unlock()
            handler?(update, nil)
        case "error":
            finish(error: RecognitionBackendError(message: message.message ?? "Ошибка вспомогательного распознавателя"))
        default:
            break
        }
    }

    private func finish(error: Error?) {
        lock.lock()
        let handler = finished ? nil : self.handler
        finished = true
        self.handler = nil
        lock.unlock()
        writeQueue.async { [self] in closeInput() }
        if process.isRunning { process.terminate() }
        if let error { handler?(nil, error) }
    }
}
