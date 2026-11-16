// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Group F3-2: the key lives in the keychain only (ARCHITEKTUR M.7, R-100, R-066). An artificial keychain stands in for
// the real one and a canary string for the key: it must appear in the keychain, in the connection header and nowhere
// else, no matter what happens (success, refused connection, service errors that echo the key, aftercare, logs).
// The real keychain and a real key are never used in these tests.
import Foundation
import Testing
@testable import FlowIQAudio  // COMPILE-FIX (P5 build): LiveSetup sits next to AudioChunk in FlowIQAudio (Core cannot see AudioChunk)
@testable import FlowIQCloud
@testable import FlowIQCore
@testable import FlowIQSpeech
@testable import FlowIQStore

@Suite(.timeLimit(.minutes(3)))
struct SecretStorageTests {
    private func canary() -> String { "sk_test_CANARY_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") }

    private func setup(_ language: RecordingLanguage = .de) -> LiveSetup {
        LiveSetup(language: language, terms: [], track: .microphone, anchor: 0, previousText: nil, backlog: [])  // ASSUMPTION: LiveSetup(language:terms:track:anchor:previousText:backlog:)
    }

    @Test func theKeyGoesToTheKeychainUnderAProfileSpecificServiceName() throws {
        let keychain = FakeKeychain()
        let secret = canary()
        let dev = CloudKeys(keychain: keychain, profile: .development)  // ASSUMPTION: CloudKeys(keychain:profile:) is the only reader and writer of the key
        let prod = CloudKeys(keychain: keychain, profile: .production)  // ASSUMPTION: assumed API, see the Support header
        #expect(!dev.hasKey)  // ASSUMPTION: assumed API, see the Support header
        try dev.store(secret)  // ASSUMPTION: CloudKeys.store(_:) throws
        #expect(dev.hasKey)  // ASSUMPTION: assumed API, see the Support header
        #expect(!prod.hasKey, "the development key must not unlock the production profile")  // ASSUMPTION: assumed API, see the Support header
        #expect(dev.service != prod.service)  // ASSUMPTION: CloudKeys.service is the keychain service name
        #expect(keychain.services == [dev.service])  // ASSUMPTION: assumed API, see the Support header
    }

    @Test func theKeyAppearsInNoFileOfTheDataFolderAfterAWholeSession() async throws {
        let rig = try await StoreRig.make()
        defer { rig.remove() }
        let secret = canary()
        let keychain = FakeKeychain()
        let keys = CloudKeys(keychain: keychain, profile: .development)  // ASSUMPTION: assumed API, see the Support header
        try keys.store(secret)  // ASSUMPTION: assumed API, see the Support header

        var settings = Settings.defaults(for: .development)
        try settings.set(.call, live: .elevenLabsRealtime, hasKey: keys.hasKey)  // ASSUMPTION: assumed API, see the Support header
        try await SettingsStore(paths: rig.paths, fs: rig.fs).save(settings)

        // A live session that connects, hears, is refused by the service (the service echoes the key) and falls over.
        let clock = ManualClock()
        let transport = FakeTransport()
        let recognizer = ElevenLabsLiveRecognizer(transport: transport, keys: keys, clock: clock, log: rig.log)  // ASSUMPTION: ElevenLabsLiveRecognizer(transport:keys:clock:log:)
        try await recognizer.start(setup())
        recognizer.feed(audio(at: 1_000_000_000, seconds: 1.0))  // ASSUMPTION: assumed API, see the Support header
        await clock.run(for: .seconds(1))
        transport.last?.serve(#"{"message_type":"auth_error","error":"Invalid API key \#(secret)"}"#)
        await clock.run(for: .seconds(1))

        // A recording with aftercare around it.
        let when = localDate(2026, 11, 13, 10, 45)
        let file = try await rig.begin(.call, at: when, live: .elevenLabsRealtime)  // ASSUMPTION: assumed API, see the Support header
        await rig.add(file, Line(seconds: 1, speaker: "Mara", text: "Ein Satz."))
        try await rig.finish(file, seconds: 60, raw: try rig.makeRaw(.call, at: when, seconds: 60))

        #expect(!rig.everythingAsText().contains(secret), "the key was written somewhere below the data folder (settings, protocol, journal, transcript, queue)")
        #expect(!(await rig.logText()).contains(secret))
        #expect(!String(decoding: (try Data(contentsOf: rig.paths.settingsFile)), as: UTF8.self).contains(secret))
        #expect(!String(decoding: (try Data(contentsOf: file.url)), as: UTF8.self).contains(secret))
    }

    @Test func everyConnectionCarriesTheKeyOnlyAsAHeader() async throws {
        let rig = try await StoreRig.make()
        defer { rig.remove() }
        let secret = canary()
        let keys = CloudKeys(keychain: FakeKeychain(), profile: .development)  // ASSUMPTION: assumed API, see the Support header
        try keys.store(secret)  // ASSUMPTION: assumed API, see the Support header
        let clock = ManualClock()
        let transport = FakeTransport()
        let recognizer = ElevenLabsLiveRecognizer(transport: transport, keys: keys, clock: clock, log: rig.log)  // ASSUMPTION: assumed API, see the Support header
        try await recognizer.start(setup())
        for _ in 0..<3 {  // three reconnects after drops: every new request is checked
            transport.last?.drop()
            await clock.run(for: .seconds(2))
        }
        #expect(transport.connections.count >= 2)
        for connection in transport.connections {
            let request = connection.request
            #expect(request.value(forHTTPHeaderField: "xi-api-key") == secret)
            let address = request.url?.absoluteString ?? ""  // COMPILE-FIX (P5 build): #expect cannot expand `?? ""` after optional chaining
            #expect(!address.contains(secret), "the key is in a URL")  // COMPILE-FIX (P5 build): the same expectation on the bound value
            #expect(request.url?.query?.contains(secret) != true)
            #expect(request.url?.scheme == "wss")
            #expect(request.url?.host == "api.elevenlabs.io")
            for (name, value) in request.allHTTPHeaderFields ?? [:] where name.lowercased() != "xi-api-key" {
                #expect(!value.contains(secret), "the key is in header \(name)")
            }
        }
    }

    @Test(arguments: Wire.errorTypes.map(\.0))
    func aServiceErrorThatEchoesTheKeyNeverReachesEventsOrProtocol(_ type: String) async throws {
        let rig = try await StoreRig.make()
        defer { rig.remove() }
        let secret = canary()
        let keys = CloudKeys(keychain: FakeKeychain(), profile: .development)  // ASSUMPTION: assumed API, see the Support header
        try keys.store(secret)  // ASSUMPTION: assumed API, see the Support header
        let clock = ManualClock()
        let transport = FakeTransport()
        let recognizer = ElevenLabsLiveRecognizer(transport: transport, keys: keys, clock: clock, log: rig.log)  // ASSUMPTION: assumed API, see the Support header
        try await recognizer.start(setup())
        transport.last?.serve(#"{"message_type":"\#(type)","error":"detail with key \#(secret)"}"#)
        var described = ""
        for await event in recognizer.events {
            if case .failure(let failure) = event {  // ASSUMPTION: assumed API, see the Support header
                described = String(describing: failure)
                break
            }
        }
        #expect(!described.isEmpty, "\(type) produced no failure event")
        #expect(!described.contains(secret))
        #expect(!(await rig.logText()).contains(secret))
    }

    @Test func withoutAKeyNothingConnects() async throws {
        let rig = try await StoreRig.make()
        defer { rig.remove() }
        let keys = CloudKeys(keychain: FakeKeychain(), profile: .development)  // ASSUMPTION: assumed API, see the Support header
        let transport = FakeTransport()
        let recognizer = ElevenLabsLiveRecognizer(transport: transport, keys: keys, clock: ManualClock(), log: rig.log)  // ASSUMPTION: assumed API, see the Support header
        await #expect(throws: LiveFailure.self) { try await recognizer.start(self.setup()) }  // ASSUMPTION: LiveFailure is an Error; .keyMissing is what start throws without a key
        #expect(transport.connections.isEmpty)
    }

    @Test func withoutAKeyThePolicyForbidsEveryCloudUse() {
        var settings = Settings.defaults(for: .production)
        settings[.call] = ModeConfig(live: .elevenLabsRealtime, post: .elevenLabs, language: .de)  // ASSUMPTION: assumed API, see the Support header
        settings[.dictation] = ModeConfig(live: .appleLocal, post: .elevenLabs, language: .de)  // ASSUMPTION: assumed API, see the Support header
        let policy = CloudPolicy(settings: settings, hasKey: false)  // ASSUMPTION: assumed API, see the Support header
        for mode in [RecordingMode.dictation, .call, .room, .device] {
            #expect(!policy.allows(.live, for: mode))
            #expect(!policy.allows(.post, for: mode))
        }
    }

    @Test func theEnvImportHappensOnlyOnAClick() throws {
        let secret = canary()
        let keychain = FakeKeychain()
        let keys = CloudKeys(keychain: keychain, profile: .development)  // ASSUMPTION: assumed API, see the Support header
        let env = "OTHER=1\nELEVENLABS_API_KEY=\(secret)\n"
        #expect(try keys.importFromEnv(env, userClicked: false) == false)  // ASSUMPTION: importFromEnv(_:userClicked:) throws -> Bool (R-066: only on a click)
        #expect(!keys.hasKey && keychain.isEmpty)  // ASSUMPTION: assumed API, see the Support header
        #expect(try keys.importFromEnv(env, userClicked: true))  // ASSUMPTION: assumed API, see the Support header
        #expect(keys.hasKey)  // ASSUMPTION: assumed API, see the Support header
    }

    @Test func removingTheKeyLocksElevenLabsAgain() throws {
        let keys = CloudKeys(keychain: FakeKeychain(), profile: .development)  // ASSUMPTION: assumed API, see the Support header
        try keys.store(canary())  // ASSUMPTION: assumed API, see the Support header
        #expect(Settings.defaults(for: .production).choices(for: .call, hasKey: keys.hasKey).live.contains(.elevenLabsRealtime))  // ASSUMPTION: assumed API, see the Support header
        try keys.remove()  // ASSUMPTION: CloudKeys.remove() throws
        #expect(!keys.hasKey)  // ASSUMPTION: assumed API, see the Support header
        #expect(!Settings.defaults(for: .production).choices(for: .call, hasKey: keys.hasKey).live.contains(.elevenLabsRealtime))  // ASSUMPTION: assumed API, see the Support header
    }
}
