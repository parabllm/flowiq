import FlowIQCore
import FlowIQLog
import Foundation
import Synchronization
import Testing
@testable import FlowIQCloud

/// Review 15.11. (b): `CloudPolicy` gates every cloud start, live and after-run, over the real factory path.
struct PolicyGateTests {
    final class Keychain: KeychainPort, Sendable {
        let items = Mutex<[String: String]>([:])
        func read(service: String, account: String) throws -> String? { items.withLock { $0[service + account] } }
        func write(_ secret: String, service: String, account: String) throws {
            items.withLock { $0[service + account] = secret }
        }
        func delete(service: String, account: String) throws {
            _ = items.withLock { $0.removeValue(forKey: service + account) }
        }
    }

    final class Transport: RealtimeTransport, Sendable {
        let connects = Mutex(0)
        struct Connection: RealtimeConnection {
            let incoming = AsyncThrowingStream<String, any Error> { nil }
            func send(_ text: String) async throws {}
            func close() async {}
        }
        func connect(_ request: URLRequest) async throws -> any RealtimeConnection {
            connects.withLock { $0 += 1 }
            return Connection()
        }
    }

    static func policy(hasKey: Bool, live: LiveEngine, post: PostEngine) -> CloudPolicy {
        var settings = Settings.defaults(for: .production)
        settings[.call] = ModeConfig(live: live, post: post, language: .de)
        return CloudPolicy(settings: settings, hasKey: hasKey)
    }

    static func log() throws -> (EventLog, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "flowiq-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (EventLog(directory: root), root)
    }

    @Test func noLiveConnectionWithoutKeyOrSwitch() async throws {
        let (log, root) = try Self.log()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record("\(error)") } }
        let keychain = Keychain(), keys = CloudKeys(keychain: keychain, profile: .production)
        try keys.store("sk_test_GATE")
        for (hasKey, live, connects) in [(true, LiveEngine.appleLocal, 0), (false, .elevenLabsRealtime, 0),
                                         (true, .elevenLabsRealtime, 1)] {
            let transport = Transport(), policy = Self.policy(hasKey: hasKey, live: live, post: .off)
            let recognizer = try CloudGate.liveRecognizer(mode: .call, policy: { policy }, profile: .production,
                                                          order: .artificial(transport), keys: keys, log: log)
            let setup = LiveSetup(language: .de, terms: [], track: .microphone, anchor: 0, previousText: nil,
                                  backlog: [])
            if connects == 0 {
                await #expect(throws: LiveFailure.notAllowed) { try await recognizer.start(setup) }
            } else {
                try await recognizer.start(setup)
                await recognizer.finish()
            }
            let made = transport.connects.withLock { $0 }  // an ended fake stream reconnects, so "at least one"
            #expect(connects == 0 ? made == 0 : made >= 1, "key \(hasKey), live \(live)")
        }
    }

    @Test func noUploadWithoutKeySwitchOrOrder() async throws {
        let keychain = Keychain()
        try CloudKeys(keychain: keychain, profile: .production).store("sk_test_GATE")
        let job = PostJob(audio: [URL(filePath: "/nonexistent/flowiq-gate.m4a")], language: "de", terms: [],
                          mode: .call)
        for policy in [Self.policy(hasKey: true, live: .appleLocal, post: .off),
                       Self.policy(hasKey: false, live: .appleLocal, post: .elevenLabs)] {
            let batch = try CloudGate.batchService(profile: .production, order: nil, keychain: keychain,
                                                   policy: { policy })
            await #expect(throws: PostFailure.notAllowed) { try await batch.process(job) }
        }
        let unset = try CloudGate.batchService(profile: .production, order: nil, keychain: keychain)
        await #expect(throws: PostFailure.notAllowed, "no policy, nothing sent") { try await unset.process(job) }
        #expect(throws: CloudGateError.self) { try CloudGate.batchService(profile: .development, order: nil) }
        #expect(throws: CloudGateError.self) {
            try CloudGate.liveRecognizer(mode: .call, policy: { Self.policy(hasKey: true, live: .elevenLabsRealtime,
                                                                             post: .off) },
                                         profile: .development, order: nil,
                                         keys: CloudKeys(keychain: keychain, profile: .development),
                                         log: EventLog(directory: FileManager.default.temporaryDirectory))
        }
    }
}
