// Integration check of the real dictation recognizer (G.1): German speech made with `say` at run time, fed as
// 10 ms chunks of mono Float at 48 kHz, exactly like the microphone path. Runs only with FLOWIQ_SPEECH_IT=1 (it
// loads Apple's speech model); no microphone, no network, no permission.
import AVFoundation
import FlowIQAudio
import Foundation
import Testing
@testable import FlowIQSpeech

struct AppleDictationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FLOWIQ_SPEECH_IT"] == "1"))
    func syntheticGermanSpeechIsRecognizedFromChunks() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "flowiq-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: folder) } catch { Issue.record("cleanup failed: \(error)") }
        }
        let aiff = folder.appending(path: "satz.aiff")
        let say = Process()
        say.executableURL = URL(filePath: "/usr/bin/say")
        say.arguments = ["-v", "Anna", "-o", aiff.path, "Heute ist ein schöner Tag und wir gehen spazieren."]
        try say.run()
        say.waitUntilExit()

        let file = try AVAudioFile(forReading: aiff)
        let target = try #require(AVAudioFormat(standardFormatWithSampleRate: AudioChunk.channelRate, channels: 1))
        let source = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                   frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: source)
        let converter = try #require(AVAudioConverter(from: file.processingFormat, to: target))
        let out = try #require(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(
            Double(file.length) * AudioChunk.channelRate / file.processingFormat.sampleRate) + 4_096))
        var fed = false
        _ = converter.convert(to: out, error: nil) { _, state in
            state.pointee = fed ? .endOfStream : .haveData
            defer { fed = true }
            return fed ? nil : source
        }
        let samples = Array(UnsafeBufferPointer(start: out.floatChannelData?[0], count: Int(out.frameLength)))
        let (chunks, input) = AsyncStream.makeStream(of: AudioChunk.self)
        for start in stride(from: 0, to: samples.count, by: 480) {
            input.yield(AudioChunk(hostTime: UInt64(start) * 1_000_000_000 / 48_000,
                                   sampleRate: AudioChunk.channelRate,
                                   samples: Array(samples[start..<min(start + 480, samples.count)])))
        }
        input.finish()

        let run = await AppleDictation().dictate(chunks)
        let text = try #require(run.recognition?.text, "failure: \(run.failure ?? "none")").lowercased()
        #expect(text.contains("heute"))
        #expect(text.contains("spazieren"))
        #expect(run.recognition?.tokens.isEmpty == false)
    }
}
