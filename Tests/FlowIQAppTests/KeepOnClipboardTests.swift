// R-117 in the app: with the setting on the coordinator leaves the finished dictation on the clipboard in every case,
// also when no text field takes it; off, the inserter's give-back stands. Real coordinator, artificial ports.
import FlowIQAudio
import FlowIQCore
import FlowIQInput
import FlowIQInsert
import FlowIQSpeech
import FlowIQStore
import FlowIQText
import Foundation
import Synchronization
import Testing
@testable import FlowIQ

private final class Board: PasteboardPort, KeyPosting, FocusProbing, FrontAppProbing, Sendable {
    let state = Mutex<(text: String, count: Int)>(("alt", 1))
    let focus: FocusState
    init(focus: FocusState) { self.focus = focus }
    var text: String { state.withLock { $0.text } }
    var changeCount: Int { state.withLock { $0.count } }
    func snapshot() throws -> PasteboardSnapshot { PasteboardSnapshot(items: [["t": Data(text.utf8)]]) }
    func writePromise(_ text: String, onFetch: @escaping @Sendable () -> Void) throws -> Int { try writePlain(text) }
    func writePlain(_ text: String) throws -> Int { state.withLock { $0 = (text, $0.count + 1); return $0.count } }
    func restore(_ snapshot: PasteboardSnapshot) throws {
        let old = String(decoding: snapshot.items.first?["t"] ?? Data(), as: UTF8.self)
        state.withLock { $0 = (old, $0.count + 1) }
    }
    func paste() throws {}
    func undo() throws {}
    func probe() async -> FocusState { focus }
    func frontmost() -> String? { "pid-1" }
    func frontmostName() -> String? { "Notizen" }
    var secureInputActive: Bool { false }
}

private final class Tone: CaptureSource, Sendable {
    let kind = SourceKind.microphone(InputDevice(uid: "test", isBuiltIn: true))
    let task = Mutex<Task<Void, Never>?>(nil)
    func start(deliver: @escaping @Sendable (AudioChunk) -> Void,
        onEnd: @escaping @Sendable (CaptureEnd) -> Void) async throws {
        task.withLock { $0 = Task {
            var t: UInt64 = 0
            while !Task.isCancelled {
                deliver(AudioChunk(hostTime: t, sampleRate: AudioChunk.channelRate, samples: [Float](repeating: 0.1,
                    count: 480)))
                t += 10_000_000
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            }
        } }
    }
    func stop() async { task.withLock { $0?.cancel() } }
}

private struct Words: DictationRecognizer {
    func dictate(_ chunks: AsyncStream<AudioChunk>) async -> DictationRun {
        for await _ in chunks {}
        return DictationRun(recognition: Recognition(text: "Hallo Welt"), failure: nil)
    }
}

private struct Same: TextProcessing {
    func process(_ r: Recognition) async -> ProcessedText { ProcessedText(text: r.text, interventions: []) }
}

private final class Keys: KeyEventSource, Sendable {
    let handler = Mutex<(@Sendable (KeyEvent) -> Void)?>(nil)
    func start(_ handler: @escaping @Sendable (KeyEvent) -> Void) throws { self.handler.withLock { $0 = handler } }
    func stop() {}
    func send(_ down: Bool) {
        handler.withLock { $0 }?(KeyEvent(.trigger, down: down, at: MachTime.nanos(ticks: MachTime.now())))
    }
}

private struct NoPill: PillSink { func set(_ state: PillState) {} }

@Suite(.serialized) struct KeepOnClipboardTests {
    private func dictate(focus: FocusState, keep: Bool) async throws -> String {
        try await run(focus: focus, keep: keep).text
    }
    /// The clipboard afterwards and the target app the journal names for the dictation.
    private func run(focus: FocusState, keep: Bool) async throws -> (text: String, app: String?) {
        let root = FileManager.default.temporaryDirectory.appending(path: "flowiq-keep-\(UUID().uuidString)")
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let paths = Paths(profile: .development, applicationSupport: root), fs = SafeFS(paths: paths)
        try paths.prepare(using: fs)
        let log = EventLog(directory: paths.log, fs: fs), board = Board(focus: focus), clock = ContinuousClock()
        let keys = Keys(), input = InputService(source: keys, profile: .development, clock: clock, pill: NoPill(),
            log: log)
        let conductor = AudioConductor(microphone: { _ in Tone() }, desktop: { Tone() },
                                       devices: DeviceSetup(standard: InputDevice(uid: "test", isBuiltIn: true),
                                                            fallback: nil), log: log)
        let inserter = Inserter(focus: board, pasteboard: board, keys: board, front: board, clock: clock, log: log)
        let journal = DictationJournal(paths: paths, fs: fs, log: log)
        let coordinator = FlowCoordinator(paths: paths, fs: fs, conductor: conductor, recognizer: Words(), text: Same(),
                                          inserter: inserter, journal: journal,
                                          busy: BusyState(paths: paths, fs: fs), input: input, pill: NoPill(), log: log,
                                          clock: clock)
        await coordinator.keep(on: { keep }, pasteboard: board)
        try input.start()
        let pump = Task { for await e in input.stream { await coordinator.handle(e) } }
        defer { pump.cancel() }
        keys.send(true)
        try await Task.sleep(for: .milliseconds(400))
        keys.send(false)
        for _ in 0..<100 where !(await coordinator.isIdle) { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(100))
        return (board.text, await journal.history(limit: 1).first?.app)
    }

    @Test func noTextFieldSettingOnLeavesTheDictation() async throws {
        #expect(try await dictate(focus: .notTextField, keep: true) == "Hallo Welt")
    }

    @Test func noTextFieldSettingOffKeepsTheOldClipboard() async throws {
        #expect(try await dictate(focus: .notTextField, keep: false) == "alt")
    }

    @Test func landedSettingOnLeavesTheDictationAfterTheGiveBack() async throws {
        #expect(try await dictate(focus: .textField(preceding: nil), keep: true).hasSuffix("Hallo Welt"))
    }

    /// 16.11.: the journal names the target app (its name, not "pid-1"), also when no text field took it.
    @Test func journalNamesTheTargetApp() async throws {
        #expect(try await run(focus: .textField(preceding: nil), keep: false).app == "Notizen")
        #expect(try await run(focus: .notTextField, keep: false).app == "Notizen")
    }
}
