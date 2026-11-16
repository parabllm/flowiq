import AVFoundation
import AudioToolbox

/// AAC-LC as ADTS frames (A.5): every frame stands alone, a cut file stays readable to its last whole frame.
final class ADTSEncoder {
    static let rates: [Double] = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000,
                                  11_025, 8_000]
    static let packetFrames = 1_024
    let rate: Double
    /// Input frames whose packets were emitted, without the encoder's priming.
    private(set) var encodedFrames = 0, failed = false
    private let converter: AVAudioConverter, input: AVAudioFormat, rateIndex: UInt8
    private var packets = 0, finished = false
    init(sampleRate: Double, bitRate: Int) throws {
        var aac = ADTSFrame.format(rate: sampleRate, channels: 1)
        guard let index = Self.rates.firstIndex(of: sampleRate),
              let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
                                        interleaved: false),
              let output = AVAudioFormat(streamDescription: &aac),
              let converter = AVAudioConverter(from: input, to: output) else { throw RecordingError.noAudio }
        converter.bitRate = bitRate
        converter.bitRateStrategy = AVAudioBitRateStrategy_Constant
        (rate, rateIndex, self.input, self.converter) = (sampleRate, UInt8(index), input, converter)
    }
    func encode(_ samples: [Float]) -> Data {
        guard !samples.isEmpty, !finished,
              let pcm = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = pcm.floatChannelData else { return Data() }
        pcm.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel[0].update(from: $0.baseAddress!, count: samples.count) }
        return drain(pcm)
    }
    /// Flushes the encoder; afterwards it encodes nothing more.
    func finish() -> Data {
        guard !finished else { return Data() }
        defer { finished = true }
        return drain(nil)
    }
    private func drain(_ pcm: AVAudioPCMBuffer?) -> Data {
        var out = Data(), fed = false
        while true {
            let buffer = AVAudioCompressedBuffer(format: converter.outputFormat, packetCapacity: 32,
                                                 maximumPacketSize: converter.maximumOutputPacketSize)
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { _, state in
                defer { fed = true }
                state.pointee = pcm == nil ? .endOfStream : fed ? .noDataNow : .haveData
                return fed ? nil : pcm
            }
            for index in 0..<Int(buffer.packetCount) {
                guard let packet = buffer.packetDescriptions?[index] else { continue }
                let size = Int(packet.mDataByteSize), length = size + 7
                out.append(contentsOf: [0xFF, 0xF1, (1 << 6) | (rateIndex << 2), (1 << 6) | UInt8(length >> 11),
                                        UInt8((length >> 3) & 0xFF), UInt8((length & 7) << 5) | 0x1F, 0xFC])
                out.append(buffer.data.advanced(by: Int(packet.mStartOffset)).assumingMemoryBound(to: UInt8.self),
                           count: size)
                packets += 1
            }
            if status == .error { failed = true }
            if status != .haveData { break }
        }
        encodedFrames = max(0, packets * Self.packetFrames - Int(converter.primeInfo.leadingFrames))
        return out
    }
}

/// One ADTS frame header: sync word, layer 0, a length that fits the data.
struct ADTSFrame {
    let header: Int, length: Int, rate: Double, channels: UInt32
    init?(_ raw: UnsafeRawBufferPointer, at offset: Int) {
        guard offset + 7 <= raw.count, raw[offset] == 0xFF, raw[offset + 1] & 0xF6 == 0xF0 else { return nil }
        let index = Int((raw[offset + 2] >> 2) & 0x0F)
        header = raw[offset + 1] & 1 == 1 ? 7 : 9
        length = Int(raw[offset + 3] & 3) << 11 | Int(raw[offset + 4]) << 3 | Int(raw[offset + 5]) >> 5
        channels = UInt32((raw[offset + 2] & 1) << 2 | raw[offset + 3] >> 6)
        guard index < ADTSEncoder.rates.count, channels > 0, length > header, offset + length <= raw.count else {
            return nil
        }
        rate = ADTSEncoder.rates[index]
    }
    var format: AudioStreamBasicDescription { Self.format(rate: rate, channels: channels) }
    static func format(rate: Double, channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
                                    mBytesPerPacket: 0, mFramesPerPacket: UInt32(ADTSEncoder.packetFrames),
                                    mBytesPerFrame: 0, mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
    }
    /// Decoder configuration for a container, taken from a fresh encoder of the same format.
    static func magicCookie(for aac: AudioStreamBasicDescription) throws -> [UInt8] {
        var output = aac
        let width = 4 * aac.mChannelsPerFrame
        var pcm = AudioStreamBasicDescription(mSampleRate: aac.mSampleRate, mFormatID: kAudioFormatLinearPCM,
                                              mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                              mBytesPerPacket: width, mFramesPerPacket: 1, mBytesPerFrame: width,
                                              mChannelsPerFrame: aac.mChannelsPerFrame, mBitsPerChannel: 32,
                                              mReserved: 0)
        var converter: AudioConverterRef?
        try check(AudioConverterNew(&pcm, &output, &converter))
        guard let converter else { throw RecordingError.noAudio }
        defer { AudioConverterDispose(converter) }
        var size: UInt32 = 0
        try check(AudioConverterGetPropertyInfo(converter, kAudioConverterCompressionMagicCookie, &size, nil))
        var cookie = [UInt8](repeating: 0, count: Int(size))
        try check(AudioConverterGetProperty(converter, kAudioConverterCompressionMagicCookie, &size, &cookie))
        return cookie
    }
    static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw RecordingError.coreAudio(status) }
    }
}
