import AVFoundation
import FluidAudio
import Foundation

@main
struct ParakeetProbe {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else {
                throw NSError(domain: "ParakeetProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "Usage: ParakeetProbe path/to/audio.wav"])
            }
            let manager = StreamingEouAsrManager(chunkSize: .ms160, eouDebounceMs: 1280)
            try await manager.loadModels()
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[1]))
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            var transcript = try await manager.process(audioBuffer: buffer)
            transcript += try await manager.finish()
            print(transcript)
        } catch {
            fputs("Parakeet probe failed: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

}
