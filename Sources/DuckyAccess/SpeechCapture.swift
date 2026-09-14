import AVFoundation
import FluidAudio
import Foundation

final class SpeechCapture {
    typealias Completion = (Result<(text: String, audioURL: URL?, duration: TimeInterval), Error>) -> Void

    private let manager = StreamingEouAsrManager(chunkSize: .ms160, eouDebounceMs: 1280)
    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var temporaryAudioURL: URL?
    private var startedAt: Date?
    private var active = false
    private var processingTail: Task<Void, Never>?
    private let processingLock = NSLock()

    var modelReady = false
    var onModelState: ((String) -> Void)?

    func warm() {
        Task {
            do {
                onModelState?("Loading Parakeet EOU 120M…")
                try await manager.loadModels()
                modelReady = true
                onModelState?("Parakeet ready")
            } catch {
                onModelState?("Parakeet unavailable: \(error.localizedDescription)")
            }
        }
    }

    func start(onPartial: @escaping (String) -> Void) async throws {
        guard !active else { return }
        guard modelReady else { throw NSError(domain: "DuckyAccess", code: 1, userInfo: [NSLocalizedDescriptionKey: "Parakeet is still loading"]) }
        await manager.reset()
        processingLock.withLock { processingTail = nil }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ducky-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000
        ]
        audioFile = try? AVAudioFile(forWriting: url, settings: settings)
        temporaryAudioURL = url
        startedAt = Date()
        input.installTap(onBus: 0, bufferSize: 2560, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            if let audioFile = self.audioFile { try? audioFile.write(from: buffer) }
            let previous = self.processingLock.withLock { self.processingTail }
            let current = Task { [weak self] in
                await previous?.value
                guard let self else { return }
                _ = try? await self.manager.process(audioBuffer: buffer)
                let partial = await self.manager.getPartialTranscript()
                DispatchQueue.main.async { onPartial(partial) }
            }
            self.processingLock.withLock { self.processingTail = current }
        }
        engine.prepare()
        try engine.start()
        active = true
    }

    func stop(completion: @escaping Completion) {
        guard active else { completion(.success(("", nil, 0))); return }
        active = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let duration = Date().timeIntervalSince(startedAt ?? Date())
        let processing = processingLock.withLock {
            let task = processingTail
            processingTail = nil
            return task
        }
        Task {
            do {
                await processing?.value
                let text = try await manager.finish()
                let savedURL = temporaryAudioURL
                audioFile = nil
                temporaryAudioURL = nil
                completion(.success((text, savedURL, duration)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func cancel() {
        guard active else { return }
        active = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        processingLock.withLock { processingTail?.cancel(); processingTail = nil }
        audioFile = nil
        if let url = temporaryAudioURL { try? FileManager.default.removeItem(at: url) }
        temporaryAudioURL = nil
        Task { await manager.reset() }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
