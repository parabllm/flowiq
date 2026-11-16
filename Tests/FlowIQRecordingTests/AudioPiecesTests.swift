import AVFoundation
import FlowIQCore
import Foundation
import Testing
@testable import FlowIQRecording

/// The OpenRouter after-run's pieces (16.11.), offline over a generated file.
struct AudioPiecesTests {
    /// The real cut over a generated file: a window as FLAC or AAC through SafeFS, the piece file gone afterwards.
    @Test func theCutWritesOneWindowAndCleansUp() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "flowiq-cut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) } catch { Issue.record("cleanup: \(error)") }
        }
        let wav = root.appending(path: "ton.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        do {
            let file = try AVAudioFile(forWriting: wav, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
            buffer.frameLength = 48_000
            for i in 0..<48_000 { buffer.floatChannelData?[0][i] = sin(Float(i) / 10) * 0.3 }
            try file.write(from: buffer)
        }
        let pieces = root.appending(path: "stuecke"), fs = SafeFS(confinedTo: root)
        let flac = try AudioPieces.cut(wav, 1..<2, "flac", fs: fs, folder: pieces)
        #expect(abs(flac.seconds - 3) < 0.01 && flac.data.prefix(4) == Data("fLaC".utf8))
        let aac = try AudioPieces.cut(wav, 1..<2, "m4a", fs: fs, folder: pieces)
        #expect(aac.data.count > 100)
        #expect(try FileManager.default.contentsOfDirectory(atPath: pieces.path).isEmpty)
    }
}
