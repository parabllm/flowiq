// Group F3-6: dictation recognition stays local (ARCHITEKTUR M.1, M.9, Anhang I addition to `DuringCallTests`;
// R-102, R-067 new wording). The Cloud policy never allows live recognition for a dictation, whatever the settings
// say; the dictation after-run (upload after the insertion) exists only with its switch on; while a call is
// recognized by the cloud, 10 dictations are recognized locally and inserted (10 of 10) and not one dictation chunk
// enters the cloud stream. Nothing here opens a connection: the "cloud" is a recognizer that counts what it is fed.
import Foundation
import Testing
@testable import FlowIQAudio
@testable import FlowIQCloud
@testable import FlowIQCore
@testable import FlowIQInsert
@testable import FlowIQSpeech

@Suite(.timeLimit(.minutes(3)))
struct DictationStaysLocalTests {
    private func config(live: LiveEngine, post: PostEngine) -> ModeConfig {
        ModeConfig(live: live, post: post, language: .de)  // ASSUMPTION: ModeConfig(live:post:language:) memberwise, public
    }

    @Test(arguments: [true, false].flatMap { k in [LiveEngine.appleLocal, .elevenLabsRealtime].flatMap { l in [PostEngine.off, .elevenLabs].map { (k, l, $0) } } })  // COMPILE-FIX (P5 build): Swift Testing takes at most two argument collections; the same 8 combinations as one collection
    func theCloudPolicyNeverAllowsLiveRecognitionForADictation(_ hasKey: Bool, _ live: LiveEngine, _ post: PostEngine) {  // ASSUMPTION: assumed API, see the Support header
        var settings = Settings.defaults(for: .production)
        settings[.dictation] = config(live: live, post: post)  // ASSUMPTION: Settings[mode] subscript get and set
        let policy = CloudPolicy(settings: settings, hasKey: hasKey)  // ASSUMPTION: CloudPolicy(settings:hasKey:)
        #expect(!policy.allows(.live, for: .dictation), "live=\(live) post=\(post) key=\(hasKey)")  // ASSUMPTION: CloudPolicy.allows(_:for:) with CloudUse { live, post } and RecordingMode
    }

    @Test(arguments: [true, false], [PostEngine.off, .elevenLabs])
    func theDictationAfterRunIsAllowedOnlyWithItsSwitchOnAndAKey(_ hasKey: Bool, _ post: PostEngine) {
        var settings = Settings.defaults(for: .production)
        settings[.dictation] = config(live: .appleLocal, post: post)  // ASSUMPTION: assumed API, see the Support header
        let policy = CloudPolicy(settings: settings, hasKey: hasKey)  // ASSUMPTION: assumed API, see the Support header
        #expect(policy.allows(.post, for: .dictation) == (post == .elevenLabs && hasKey))
    }

    @Test func callAndRoomMayUseTheCloudLiveOnlyByChoiceAndWithAKey() {
        var settings = Settings.defaults(for: .production)
        settings[.call] = config(live: .elevenLabsRealtime, post: .off)  // ASSUMPTION: assumed API, see the Support header
        settings[.room] = config(live: .appleLocal, post: .off)  // ASSUMPTION: assumed API, see the Support header
        #expect(CloudPolicy(settings: settings, hasKey: true).allows(.live, for: .call))  // ASSUMPTION: assumed API, see the Support header
        #expect(!CloudPolicy(settings: settings, hasKey: false).allows(.live, for: .call))  // ASSUMPTION: assumed API, see the Support header
        #expect(!CloudPolicy(settings: settings, hasKey: true).allows(.live, for: .room))  // ASSUMPTION: assumed API, see the Support header
    }

    @Test func aHandEditedSettingsFileCannotMakeTheDictationLiveCloud() async throws {
        let scratch = try F3Scratch()
        defer { scratch.remove() }
        let json = #"{"version":1,"launchAtLogin":false,"modes":{"dictation":{"live":"elevenLabsRealtime","post":"off","language":"de-DE"}}}"#  // ASSUMPTION: key names modes/dictation/live/post/language and the raw values of the enums (M.1, M.2)
        try Data(json.utf8).write(to: scratch.paths.settingsFile)
        let loaded = await SettingsStore(paths: scratch.paths, fs: scratch.fs).load()
        let effective = loaded.settings.effective(.dictation, hasKey: true)  // ASSUMPTION: Settings.effective(_:hasKey:) -> ModeConfig after the rules of M.1
        #expect(effective.live == .appleLocal)
        #expect(effective.post == .off, "the file's own post choice stays")
        #expect(effective.language == .de)
    }

    @Test func tenDictationsDuringACloudCallSendNothingOfThemToTheCloud() async throws {
        let scratch = try F3Scratch()
        let insert = try InsertRig(field: "")
        defer {
            scratch.remove()
            insert.remove()
        }
        let device = InputDevice(uid: "f3-builtin", isBuiltIn: true)
        let mic = ToneMic(device: device)
        let conductor = AudioConductor(microphone: { _ in mic }, desktop: { ToneMic(device: device) },
                                       devices: DeviceSetup(standard: device, fallback: device), log: scratch.log)
        let callLease = try await conductor.acquireMic(for: .call)
        let cloud = CountingLive(engine: .elevenLabsRealtime)
        let feed = CallLiveFeed(track: .microphone, chunks: callLease.chunks, live: [cloud])  // ASSUMPTION: CallLiveFeed(track:chunks:live:) pumps a call lease into the recognizers; suppresses chunks inside dictation windows
        feed.start()  // ASSUMPTION: CallLiveFeed.start()

        var now: UInt64 = 1_000_000_000
        let step: UInt64 = 50_000_000
        func tick(_ count: Int) {
            for _ in 0..<count {
                mic.emit(at: now)
                now += step
            }
        }
        var windows: [Range<UInt64>] = []
        var outside = 0
        var dictationChunks = Array(repeating: 0, count: 10)
        tick(20)
        outside += 20
        for i in 0..<10 {
            let begin = now
            feed.dictationStarted(at: begin)  // ASSUMPTION: CallLiveFeed.dictationStarted(at:) with the host time of the key press
            let lease = try await conductor.acquireMic(for: .dictation)
            let counter = Task { () -> Int in
                var n = 0
                for await _ in lease.chunks { n += 1 }
                return n
            }
            tick(10)
            let end = now
            feed.dictationEnded(at: end)  // ASSUMPTION: CallLiveFeed.dictationEnded(at:) with the host time of the end of the tail
            windows.append(begin..<end)
            await lease.release()
            dictationChunks[i] = await counter.value
            tick(6)
            outside += 6
            _ = await insert.insert("Diktat Nummer \(i)")  // the local recognizer's text lands in the field
            await insert.settle()
        }
        let settled = await eventually { cloud.hostTimes.count >= outside }
        #expect(settled, "the call audio outside the dictations did not arrive: \(cloud.hostTimes.count) of \(outside)")
        for (i, window) in windows.enumerated() {
            let leaked = cloud.hostTimes.filter { window.contains($0) }
            #expect(leaked.isEmpty, "dictation \(i): \(leaked.count) chunks in the cloud stream")
            #expect(dictationChunks[i] == 10, "dictation \(i): the local recognizer got \(dictationChunks[i]) of 10 chunks")
        }
        #expect(cloud.hostTimes.count == outside, "more chunks than call audio outside the dictations")
        #expect(insert.target.field.components(separatedBy: "Diktat Nummer").count == 11, "10 of 10 dictations must land in the field")
        await callLease.release()
    }
}
