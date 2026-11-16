// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Group 1c, the recorder's own guard (A.12, B.2, B.3): a call that is started while it runs, a call started twice at
// the same instant (bouncing shortcut), call German then call English right away, room plus call through the
// recorder. The recorder is the one place that knows which recordings run; the pill, the menu and the shortcuts
// ask it. These tests use the real `Recorder` with synthetic capture sources and an after-run that never sends.
//
// ASSUMPTION: the recorder's live side reaches the speech model inventory of the Mac (no microphone, no permission);
// a missing model falls back to "Live-Erkennung aus" and the recording goes on (review M4). Where that is not wanted
// in a test run, the recorder needs an injectable live recognizer (open point in README.md).
import Foundation
import Testing
@testable import FlowIQ
@testable import FlowIQAudio
@testable import FlowIQCloud
@testable import FlowIQCore
@testable import FlowIQRecording
@testable import FlowIQStore

private struct EmptyKeychain: KeychainPort {
    func read(service: String, account: String) throws -> String? { nil }
    func write(_ secret: String, service: String, account: String) throws {}
    func delete(service: String, account: String) throws {}
}

private final class RecorderRig: Sendable {
    let post: PostRig
    let clock = ManualClock()
    let sources: SourceBox
    let recorder: Recorder

    init() throws {
        post = try PostRig.make()
        sources = SourceBox(clock: clock, plan: .init())
        let sources = sources, log = post.log, fs = post.fs
        let conductor = AudioConductor(microphone: { sources.makeMic($0) }, desktop: { sources.makeDesktop() },
                                       devices: DeviceSetup(standard: Dev.builtIn, fallback: Dev.builtIn), log: log)
        let cloudFolder = post.paths.support.appending(path: "cloud", directoryHint: .isDirectory)
        try fs.makeFolder(cloudFolder)
        let keys = CloudKeys(keychain: EmptyKeychain(), profile: .development)
        let cloud = CloudParts(keys: keys, usage: MonthUsage(meter: UsageMeter(folder: cloudFolder, fs: fs), limitMinutes: nil),  // ASSUMPTION: CloudParts(keys:usage:badge:live:post:profile:log:policy:)
                               badge: CloudBadge(), live: false, post: nil, profile: .development, log: log,
                               policy: { CloudPolicy(settings: .defaults(for: .development), hasKey: false) })
        recorder = Recorder(paths: post.paths, conductor: conductor, log: log,  // ASSUMPTION: Recorder(paths:conductor:log:filing:cloud:busy:terms:)
                            filing: Filing(fs: fs, store: post.store, aftercare: post.aftercare), cloud: cloud,
                            busy: BusyState(paths: post.paths, fs: fs), terms: { [] })
    }

    /// Both ends of the real world gone: nothing may still run when the test is over.
    func finish() async {
        await recorder.stopAll()
        await post.aftercare.settle()  // ASSUMPTION: the after-run of the stop may still write; the test waits for it
        post.remove()
    }

    var sessionFolders: [String] { names(in: post.paths.laufend).filter { $0.hasSuffix(" Call") || $0.hasSuffix(" Raum") } }  // the live journals live there too
}

@Suite(.timeLimit(.minutes(2)))
struct RecorderStartTests {
    /// B.2 point 1, A.12: a start for a kind that runs is not a second recording. The shortcut toggles (the app turns
    /// the second press into the stop); the menu has no start row for it (see AnzeigeTests).
    @Test func startingARunningKindAgainIsNotASecondRecording() async throws {
        let rig = try RecorderRig()
        try await rig.recorder.start(.call, language: .de, engine: .appleLocal)
        try await rig.recorder.start(.call, language: .en, engine: .appleLocal)
        let running = await rig.recorder.snapshot()
        #expect(running.map(\.kind) == [.call])
        #expect(running.first?.language == .de, "the second start must not change the language of the running call")
        #expect(rig.sources.allMics.count == 1 && rig.sources.allDesktops.count == 1)
        #expect(rig.sessionFolders.count == 1)
        await rig.finish()
    }

    /// Two starts at the same instant (a bouncing shortcut: both read "nothing runs" before the first one is
    /// visible): exactly one recording comes out, neither start reports a failure, no orphan keeps recording.
    /// `Recorder.start` awaits before it records the session, so the guard at its top can pass twice (actor
    /// re-entrancy); this test is the proof or the counter proof.
    @Test(arguments: [SessionKind.call, .room])
    func twoStartsAtTheSameInstantAreOneRecording(_ kind: SessionKind) async throws {
        let rig = try RecorderRig()
        let failures = await withTaskGroup(of: Bool.self) { group -> Int in
            for language in [RecordingLanguage.de, .en] {
                group.addTask {
                    do { try await rig.recorder.start(kind, language: language, engine: .appleLocal) } catch { return true }
                    return false
                }
            }
            var failed = 0
            for await bad in group where bad { failed += 1 }
            return failed
        }
        #expect(failures == 0, "a double press must not show \"nicht gestartet\" while the recording runs")
        #expect(await rig.recorder.snapshot().count == 1)
        #expect(rig.sessionFolders.count == 1, "a second session folder means a second, orphaned recording")
        #expect(rig.sources.allMics.count == 1)
        await rig.finish()
        let mic = try #require(rig.sources.allMics.first)
        #expect(mic.counts.stopsBegun == 1, "after the stop nothing may still hold the microphone")
    }

    /// Call German, then call English right away: one call, German, and the English one never changes it
    /// (R-056: the language is fixed for the whole recording).
    @Test(arguments: [false, true])
    func callGermanThenCallEnglishRightAwayStaysOneGermanCall(concurrent: Bool) async throws {
        let rig = try RecorderRig()
        if concurrent {
            async let german: Void = rig.recorder.start(.call, language: .de, engine: .appleLocal)
            try await Task.sleep(for: .milliseconds(1))  // "right away": the second press follows after a heartbeat
            async let english: Void = rig.recorder.start(.call, language: .en, engine: .appleLocal)
            _ = try await (german, english)
        } else {
            try await rig.recorder.start(.call, language: .de, engine: .appleLocal)
            try await rig.recorder.start(.call, language: .en, engine: .appleLocal)
        }
        let running = await rig.recorder.snapshot()
        #expect(running.count == 1 && running.first?.language == .de)
        #expect(rig.sessionFolders.count == 1)
        await rig.finish()
    }

    /// E6 through the recorder: room and call at once share one microphone; each stops on its own.
    @Test func roomAndCallThroughTheRecorderShareOneMicrophone() async throws {
        let rig = try RecorderRig()
        try await rig.recorder.start(.room, language: .de, engine: .appleLocal)
        try await rig.recorder.start(.call, language: .de, engine: .appleLocal)
        #expect(Set(await rig.recorder.snapshot().map(\.kind)) == [.room, .call])
        #expect(rig.sources.allMics.count == 1)
        let mic = try #require(rig.sources.currentMic)
        await rig.recorder.stop(.room)
        #expect(mic.phase != .stopped && mic.counts.stopsBegun == 0, "the call lost its microphone with the room")
        #expect(await rig.recorder.snapshot().map(\.kind) == [.call])
        await rig.finish()
        #expect(mic.counts.stopsBegun == 1)
    }
}
