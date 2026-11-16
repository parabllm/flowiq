import AVFoundation

/// Microphone through `AVCaptureSession` (A.4, R-044): converts to Float32 mono 48 kHz itself, runs on its own
/// serial queue (never main or pool), never sets a device property. Not in tests.
public actor MicrophoneSource: CaptureSource {
    public nonisolated let kind: SourceKind
    private nonisolated let control = DispatchSerialQueue(label: "flowiq.mic.control", qos: .userInitiated)
    private let device: InputDevice
    private var session: AVCaptureSession? = nil, sink: CaptureSink? = nil, observers: [any NSObjectProtocol] = []
    public nonisolated var unownedExecutor: UnownedSerialExecutor { control.asUnownedSerialExecutor() }
    public init(device: InputDevice) {
        self.device = device
        kind = .microphone(device)
    }
    public func start(deliver: @escaping @Sendable (AudioChunk) -> Void,
                      onEnd: @escaping @Sendable (CaptureEnd) -> Void) async throws {
        guard let capture = AVCaptureDevice(uniqueID: device.uid) else { throw AudioError.deviceMissing }
        let session = AVCaptureSession(), input = try AVCaptureDeviceInput(device: capture)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: AudioChunk.channelRate,
                                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                                AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false]
        guard session.canAddInput(input), session.canAddOutput(output) else { throw AudioError.rejected }
        session.addInput(input)
        session.addOutput(output)
        let sink = CaptureSink(label: "flowiq.mic.buffers", deliver: deliver, onEnd: onEnd)
        output.setSampleBufferDelegate(sink, queue: sink.queue)
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { _ in
                sink.end("capture runtime error")
            },
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: capture, queue: nil) { _ in
                sink.end("device disconnected")
            },
        ]
        self.session = session
        self.sink = sink
        session.startRunning()
        guard session.isRunning else {
            await stop()
            throw AudioError.notRunning
        }
    }
    public func stop() async {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        session?.stopRunning()
        session = nil
        await sink?.silence()
        sink = nil
    }
}
