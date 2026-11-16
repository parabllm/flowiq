import AVFoundation
import ScreenCaptureKit

/// Desktop sound through `SCStream`, audio only (A.4), without FlowIQ's own; its end reaches `onEnd`. Not in tests.
public actor DesktopSource: CaptureSource {
    public nonisolated let kind = SourceKind.desktop
    private var stream: SCStream? = nil, sink: CaptureSink? = nil
    public init() {}
    public func start(deliver: @escaping @Sendable (AudioChunk) -> Void,
                      onEnd: @escaping @Sendable (CaptureEnd) -> Void) async throws {
        guard CGPreflightScreenCaptureAccess() else { throw AudioError.permission }  // never asks by itself
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw AudioError.deviceMissing }
        let filter = SCContentFilter(display: display, excludingWindows: [])  // as Panotti's working path
        let config = SCStreamConfiguration()
        (config.width, config.height) = (2, 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(AudioChunk.channelRate)
        config.channelCount = 2  // as Panotti; the sink mixes down to mono
        let sink = CaptureSink(label: "flowiq.desktop.buffers", deliver: deliver, onEnd: onEnd)
        let stream = SCStream(filter: filter, configuration: config, delegate: sink)
        try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)  // takes the 2 x 2 frames
        self.stream = stream
        self.sink = sink
        try await stream.startCapture()
    }
    public func stop() async {
        do { try await stream?.stopCapture() } catch {
            stream = nil  // a stream that already ended by itself throws here; its end went through onEnd
        }
        stream = nil
        await sink?.silence()
        sink = nil
    }
}
