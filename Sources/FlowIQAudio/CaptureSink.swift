import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Callback end of the real sources on one serial queue; after `silence()` no callback delivers (stop contract).
final class CaptureSink: NSObject, Sendable {
    private struct Hooks {
        var deliver: (@Sendable (AudioChunk) -> Void)?
        var onEnd: (@Sendable (CaptureEnd) -> Void)?
    }
    let queue: DispatchQueue
    private let hooks: Mutex<Hooks>
    init(label: String, deliver: @escaping @Sendable (AudioChunk) -> Void,
         onEnd: @escaping @Sendable (CaptureEnd) -> Void) {
        queue = DispatchQueue(label: label, qos: .userInteractive)
        hooks = Mutex(Hooks(deliver: deliver, onEnd: onEnd))
    }
    func receive(_ buffer: CMSampleBuffer) {
        guard let deliver = hooks.withLock({ $0.deliver }) else { return }
        guard let chunk = Self.chunk(buffer) else { return end("unsupported sample format") }
        deliver(chunk)
    }
    /// Reports the end once.
    func end(_ reason: String) {
        let onEnd = hooks.withLock { hooks -> (@Sendable (CaptureEnd) -> Void)? in
            defer { hooks = Hooks() }
            return hooks.onEnd
        }
        onEnd?(.failed(reason))
    }
    func silence() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                self.hooks.withLock { $0 = Hooks() }
                done.resume()
            }
        }
    }
    /// Linear PCM Float32 of any channel layout, mixed down to mono.
    static func chunk(_ buffer: CMSampleBuffer) -> AudioChunk? {
        guard let format = buffer.formatDescription?.audioStreamBasicDescription,
              format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else { return nil }
        let frames = buffer.numSamples
        let time = CMTimeConvertScale(buffer.presentationTimeStamp, timescale: 1_000_000_000, method: .default)
        var mono = [Float](repeating: 0, count: frames)
        do {
            try buffer.withAudioBufferList { list, _ in
                let channels = list.reduce(0) { $0 + Int($1.mNumberChannels) }
                guard channels > 0 else { return }
                for audio in list {
                    guard let data = audio.mData else { continue }
                    let step = Int(audio.mNumberChannels), values = data.assumingMemoryBound(to: Float.self)
                    for frame in 0..<min(frames, Int(audio.mDataByteSize) / 4 / max(step, 1)) {
                        for channel in 0..<step { mono[frame] += values[frame * step + channel] / Float(channels) }
                    }
                }
            }
        } catch {
            return nil
        }
        return AudioChunk(hostTime: UInt64(max(time.value, 0)), sampleRate: format.mSampleRate, samples: mono)
    }
}

extension CaptureSink: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        receive(sampleBuffer)
    }
}

extension CaptureSink: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio { receive(sampleBuffer) }
    }
    func stream(_ stream: SCStream, didStopWithError error: any Error) { end("desktop stream stopped") }
}
