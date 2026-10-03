import AVFoundation
import Foundation
import Speech

/// Вспомогательный процесс: `Punto --recognizer-helper <locale>`.
/// Читает из stdin заголовок JSON и поток Float32 mono PCM, пишет в stdout
/// JSON-строки с результатами распознавания. EOF на stdin завершает звук.
enum RecognitionHelper {
    static func run(localeIdentifier: String) -> Never {
        let outputQueue = DispatchQueue(label: "local.punto.recognizer-helper.output")
        let encoder = JSONEncoder()
        func send(_ message: HelperMessage) {
            outputQueue.sync {
                guard var data = try? encoder.encode(message) else { return }
                data.append(0x0A)
                FileHandle.standardOutput.write(data)
            }
        }
        func fail(_ text: String) -> Never {
            send(HelperMessage(type: "error", message: text))
            exit(EXIT_FAILURE)
        }

        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            fail("Нет доступа к распознаванию речи для вспомогательного процесса")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable else {
            fail("Распознавание \(localeIdentifier) недоступно")
        }

        var headerBytes: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let count = read(STDIN_FILENO, &byte, 1)
            guard count == 1 else { fail("Не получен заголовок аудио") }
            if byte == 0x0A { break }
            headerBytes.append(byte)
            if headerBytes.count > 512 { fail("Слишком длинный заголовок аудио") }
        }
        guard let header = try? JSONDecoder().decode(HelperHeader.self, from: Data(headerBytes)),
              header.sampleRate > 0,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: header.sampleRate,
                  channels: 1,
                  interleaved: false
              ) else {
            fail("Некорректный заголовок аудио")
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        RecognitionRequestSettings.configure(request)
        let stateLock = NSLock()
        var finished = false
        var endedAt: Date?
        func markFinished() {
            stateLock.lock()
            finished = true
            stateLock.unlock()
        }

        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                send(HelperMessage(
                    type: "result",
                    isFinal: result.isFinal,
                    transcript: result.bestTranscription.formattedString,
                    segments: result.bestTranscription.segments.map {
                        HelperSegment(
                            text: $0.substring,
                            timestamp: $0.timestamp,
                            duration: $0.duration,
                            confidence: Double($0.confidence),
                            pitch: result.isFinal ? VoiceAnalyticsReader.pitch(of: $0) : nil,
                            voicing: result.isFinal ? VoiceAnalyticsReader.voicing(of: $0) : nil
                        )
                    }
                ))
                if result.isFinal { markFinished() }
            }
            if let error {
                send(HelperMessage(type: "error", message: "\(error)"))
                markFinished()
            }
        }

        let reader = Thread {
            let bytesPerFrame = MemoryLayout<Float>.size
            let chunkBytes = 4_096 * bytesPerFrame
            var raw = [UInt8](repeating: 0, count: chunkBytes)
            var carry = Data()
            while true {
                let count = read(STDIN_FILENO, &raw, chunkBytes)
                guard count > 0 else { break }
                carry.append(raw, count: count)
                let frames = carry.count / bytesPerFrame
                guard frames > 0,
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                      let channel = buffer.floatChannelData?[0] else { continue }
                buffer.frameLength = AVAudioFrameCount(frames)
                carry.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress else { return }
                    memcpy(channel, base, frames * bytesPerFrame)
                }
                carry.removeSubrange(carry.startIndex..<(carry.startIndex + frames * bytesPerFrame))
                request.append(buffer)
            }
            request.endAudio()
            stateLock.lock()
            endedAt = Date()
            stateLock.unlock()
        }
        reader.start()

        while true {
            stateLock.lock()
            let done = finished
            let ended = endedAt
            stateLock.unlock()
            if done { break }
            if let ended, Date().timeIntervalSince(ended) > 60 {
                send(HelperMessage(type: "error", message: "Финальный результат не получен за 60 с"))
                break
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        task.cancel()
        exit(EXIT_SUCCESS)
    }
}
